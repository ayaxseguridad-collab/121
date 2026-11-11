#!/usr/bin/env bash
# run-state-write.sh — ÚNICO escritor de $TCO_RUNS_DIR/<ISSUE>/state.json (<ISSUE> = <CLAVE>-<n>, p. ej. ABC-12).
#
# Uso:  run-state-write.sh <ISSUE> <carril> <phase>
#   phase al EMPEZAR un tramo: active · al CERRARLO: done | cancelled | superseded | bounced | delivered.
#   Lo llama el COORDINADOR en su helper de tramo; el detector (behavior-watch.sh) NUNCA escribe aquí.
#
# Escribe EXACTAMENTE {"carril": …, "phase": …, "ts": "<ISO-8601 UTC>"} de forma atómica:
#   (1) temporal con mktemp en el MISMO directorio · (2) escritura con $TCO_RSW_WRITE_CMD (costura del
#   selftest; por defecto printf) comprobando su rc · (3) el temporal se VALIDA con jq -e (claves exactas y
#   phase del conjunto cerrado) · (4) solo entonces mv (rename). El rename da al lector el fichero viejo o el
#   nuevo; que el nuevo esté COMPLETO lo garantiza (3), no el rename. Una issue NUEVA se construye entera en un staging
#   oculto (runs/.stg.*) y se publica con un solo rename de directorio: el censo nunca ve un directorio vacío.
#
# FAIL-SOFT: cualquier fallo (argumento inválido, phase fuera del conjunto, directorio no escribible, enlace,
# escritura fallida, temporal que no valida, mv fallido) avisa por stderr y sale 0 SIN tocar el state.json
# anterior: nunca rompe un tramo ni un relay. Sin fsync (decisión declarada: tras un corte de
# energía P2 lee un fichero vacío como state_unreadable, y el siguiente tramo lo reescribe).
# Solo toca la issue que recibe: no recorre runs/*.
set -u
trap '' XFSZ   # un límite de tamaño es un fallo de escritura de (2), no una muerte con rc != 0

_rsw_aviso() { printf 'run-state-write: %s (no se escribe; el state.json anterior queda intacto)\n' "$*" >&2; exit 0; }   # C:W-FAILSOFT

tal="${1:-}"; carril="${2:-}"; phase="${3:-}"
[ "$#" -eq 3 ] || _rsw_aviso "uso: run-state-write.sh <ISSUE> <carril> <phase>"
printf '%s' "$tal" | grep -qE '^[A-Z][A-Z0-9]{0,9}-[0-9]+$' || _rsw_aviso "issue inválida: $(printf '%q' "$tal")"
printf '%s' "$carril" | grep -qE '^[A-Za-z0-9_-]{1,32}$' || _rsw_aviso "carril inválido: $(printf '%q' "$carril")"
case "$phase" in active|done|cancelled|superseded|bounced|delivered) : ;;   # C:W-ENUM
  *) _rsw_aviso "phase fuera del conjunto cerrado: $(printf '%q' "$phase")" ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 00-config.sh puede salir 1 ante una identidad rota: se resuelve en un subshell para seguir fail-soft.
runs="$( # shellcheck source=/dev/null
  . "$HERE/00-config.sh" >/dev/null 2>&1 && printf '%s' "${TCO_RUNS_DIR:-}")"
[ -n "$runs" ] || _rsw_aviso "no se pudo resolver TCO_RUNS_DIR"

d="$runs/$tal"                                                                                  # C:W-SOLO-TAL
sj="$d/state.json"
if [ -L "$runs" ] || [ -L "$d" ]; then _rsw_aviso "la raíz de runs o el directorio de la issue es un enlace"; fi
if [ -e "$d" ] && [ ! -d "$d" ]; then _rsw_aviso "el directorio de la issue no es un directorio"; fi
mkdir -p -- "$runs" 2>/dev/null || _rsw_aviso "no se pudo crear $runs"
if [ -L "$sj" ]; then _rsw_aviso "state.json es un enlace simbólico"; fi
if [ -e "$sj" ] && [ ! -f "$sj" ]; then _rsw_aviso "state.json no es un fichero regular"; fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
json="$(jq -nc --arg c "$carril" --arg p "$phase" --arg t "$ts" '{carril: $c, phase: $p, ts: $t}')" || _rsw_aviso "no se pudo construir el JSON"   # C:W-KEYS C:W-CLOSE

# Publicación ATÓMICA. Si el directorio de la issue ya existe, el temporal vive en él y el rename del fichero basta. Si NO existe
# (primera escritura), el directorio nunca se crea a la vista: se construye COMPLETO en un staging oculto del MISMO sistema de
# ficheros (runs/.stg.*, fuera del glob */ del censo y de P2) y se publica con UN rename de directorio. Así un censo concurrente
# ve la issue entera o no la ve, y un fallo no deja un directorio vacío.
stg=''; dest="$d"
if [ ! -d "$d" ]; then
  stg="$(mktemp -d "$runs/.stg.XXXXXX" 2>/dev/null)" || _rsw_aviso "no se pudo crear el staging en $runs"   # C:W-STAGING
  dest="$stg"
fi
tmp="$(mktemp "$dest/.state.json.XXXXXX" 2>/dev/null)" || { [ -z "$stg" ] || rm -rf -- "${stg:?}"; _rsw_aviso "no se pudo crear el temporal en $dest"; }   # C:W-TMP
_rsw_fallo() { rm -f -- "${tmp:?}"; [ -z "$stg" ] || rm -rf -- "${stg:?}"; _rsw_aviso "$*"; }
# shellcheck disable=SC2086  # TCO_RSW_WRITE_CMD es un comando con sus argumentos (costura del selftest)
${TCO_RSW_WRITE_CMD:-printf %s\\n} "$json" > "$tmp" || _rsw_fallo "falló la escritura del temporal"    # C:W-WRITE-RC
# (3) El temporal se valida ANTES del rename: claves EXACTAS y phase del conjunto cerrado.
jq -e 'keys == ["carril","phase","ts"] and (.phase | IN("active","done","cancelled","superseded","bounced","delivered"))' "$tmp" >/dev/null 2>&1 || _rsw_fallo "el temporal no valida (JSON incompleto o claves inesperadas)"   # C:W-VALIDA C:W-KEYS-EXACTAS C:W-ENUM
if [ -n "$stg" ]; then
  mv -f -- "$tmp" "$stg/state.json" 2>/dev/null || _rsw_fallo "falló el rename del temporal"
  chmod "$(printf '%03o' $(( 0777 & ~8#$(umask) )))" "$stg" 2>/dev/null || true   # mktemp -d crea 0700: se respeta el umask como mkdir -p
  if ! mv -T -- "$stg" "$d" 2>/dev/null; then   # C:W-RENAME-DIR
    # Otro escritor publicó la issue entre medias: se publica por fichero sobre su directorio.
    if [ -d "$d" ] && [ ! -L "$d" ] && mv -f -- "$stg/state.json" "$sj" 2>/dev/null; then rm -rf -- "${stg:?}"
    else _rsw_fallo "falló el rename del directorio"; fi
  fi
else
  mv -f -- "$tmp" "$sj" 2>/dev/null || _rsw_fallo "falló el rename del temporal"
fi
exit 0
