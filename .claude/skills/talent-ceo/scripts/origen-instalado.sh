#!/usr/bin/env bash
# origen-instalado.sh — ¿Qué versión del paquete hay instalada en una carpeta? (talent-ceo)
#
# Repo-agnóstico, token-only, sin MCP. SOLO LECTURA: no escribe, no sigue enlaces, no usa red ni sudo,
# no lee `.env.local` ni ejecuta nada del árbol que inspecciona.
#
# Uso:
#   origen-instalado.sh [--tabla FICHERO] CARPETA_DEL_PAQUETE_INSTALADO
#
# Salida (UNA línea en stdout):
#   ORIGEN <etiqueta> nucleo=<12 hex|-> manifiesto=<12 hex|-> declarada=<x.y.z|-> integridad=<integra|distinta:N|no-medida> nota=<código>
#
#   etiqueta     1.7.2 | 1.7.3 | 1.7.4 | 1.7.5 | 2.0 | desconocida
#   nucleo       primeros 12 hex del sha256 de instalacion/NUCLEO.sha256 de la carpeta
#   manifiesto   primeros 12 hex del sha256 del manifiesto del paquete de la carpeta
#   declarada    la línea `version=` del manifiesto; es INFORMATIVA y NUNCA decide la etiqueta
#   integridad   cada fichero que declara el NUCLEO contra su sha256: integra | distinta:N (ausentes, distintos
#                o tras un enlace) | no-medida (NUCLEO ilegible o mal formado). No cambia la etiqueta.
#   nota         ok · pista-<versión> (solo casa UNA de las dos huellas) · sin-nucleo · sin-manifiesto ·
#                tabla-invalida · mano (hay NUCLEO y manifiesto y no casan con nada)
#
# La etiqueta sale de la HUELLA DEL CONTENIDO: casan A LA VEZ el sha256 del NUCLEO y el del manifiesto con una fila
# de la tabla (por defecto `doctor-origenes.tsv`, al lado de este script). Si el NUCLEO es byte a byte el del
# paquete que ejecuta este script, la etiqueta es `2.0`. «desconocida» (instancia tocada a mano, versión sin huella
# publicada, manifiesto ausente) NO es un fallo: rc 0.
#
# Huellas (se miden con git sobre el taller; el comando va también en la cabecera de la tabla):
#   git show <commit>:talent-factory/instalacion/NUCLEO.sha256 | sha256sum
#   git show <commit>:talent-factory/skills/skill-creator/assets/package.manifest | sha256sum
#
# rc: 0 siempre que se pueda leer la carpeta (con cualquier etiqueta) · 2 uso incorrecto o precondición
# (argumento mal formado, carpeta inexistente, no directorio o enlace, biblioteca no cargable). Con rc 2
# no se imprime nada en stdout.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-desvio.sh
. "$HERE/lib-desvio.sh" 2>/dev/null || { printf 'origen-instalado: biblioteca lib-desvio.sh no cargable\n' >&2; exit 2; }

uso() { printf 'uso: origen-instalado.sh [--tabla FICHERO] CARPETA\n' >&2; exit 2; }

TABLA="$HERE/doctor-origenes.tsv"
while [ $# -gt 0 ]; do
  case "$1" in
    --tabla) [ $# -ge 2 ] || uso; TABLA="$2"; shift 2 ;;
    --) shift; break ;;
    -*) uso ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] || uso
DIR="$1"
while [ "${#DIR}" -gt 1 ] && [ "${DIR%/}" != "$DIR" ]; do DIR="${DIR%/}"; done
[ -n "$DIR" ] && [ -d "$DIR" ] && [ ! -L "$DIR" ] || { printf 'origen-instalado: carpeta inválida\n' >&2; exit 2; }

# Fichero regular, sin enlace, legible y de tamaño acotado (el tope va en bytes).
archivo_ok() { [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ] && [ "$(stat -c %s -- "$1" 2>/dev/null || echo 99999999999)" -le "$2" ]; }
digest() { local s; s="$(sha256sum -- "$1" 2>/dev/null)" || return 1; printf '%s' "${s%% *}"; }

# Tabla estricta: cuatro campos separados por TAB, huellas de 64 hex y versión x.y.z; # y vacías se permiten.
TV=(); TN=(); TM=()
leer_tabla() {
  local linea t v r n m nota
  archivo_ok "$TABLA" 65536 || return 1
  while IFS= read -r linea || [ -n "$linea" ]; do
    case "$linea" in ''|'#'*) continue ;; esac
    t="${linea//[^$'\t']/}"
    [ "${#t}" -eq 3 ] || return 1
    v="${linea%%$'\t'*}"; r="${linea#*$'\t'}"
    n="${r%%$'\t'*}"; r="${r#*$'\t'}"
    m="${r%%$'\t'*}"; r="${r#*$'\t'}"
    nota="${r%%$'\t'*}"
    [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ $n =~ ^[0-9a-f]{64}$ ]] && [[ $m =~ ^[0-9a-f]{64}$ ]] &&
      [[ $nota =~ ^[a-z0-9._-]+$ ]] || return 1
    TV+=("$v"); TN+=("$n"); TM+=("$m")
  done < "$TABLA"
  [ "${#TV[@]}" -gt 0 ]
}

# ¿Algún componente de la ruta relativa es un enlace? (no se sigue ningún enlace al medir la integridad)
tiene_enlace() {
  local resto="$1" p="$DIR" parte
  while [ -n "$resto" ]; do
    parte="${resto%%/*}"
    if [ "$parte" = "$resto" ]; then resto=''; else resto="${resto#*/}"; fi
    p="$p/$parte"
    [ ! -L "$p" ] || return 0
  done
  return 1
}

NUC=''; MAN=''; MANF=''; DECLARADA='-'; INTEGRIDAD=no-medida; NOTA=mano; ETIQUETA=desconocida
NUCF="$DIR/instalacion/NUCLEO.sha256"
if archivo_ok "$NUCF" 1048576; then NUC="$(digest "$NUCF")" || NUC=''; fi
for c in skills/skill-creator/assets/package.manifest scripts/paquete/package.manifest; do
  if archivo_ok "$DIR/$c" 65536; then MANF="$DIR/$c"; MAN="$(digest "$MANF")" || MAN=''; break; fi
done
if [ -n "$MAN" ]; then
  d="$(grep -a -m1 -E '^version=[0-9]+\.[0-9]+\.[0-9]+$' -- "$MANF" 2>/dev/null || true)"
  [ -z "$d" ] || DECLARADA="${d#version=}"
fi

PROPIO="$HERE/../../../instalacion/NUCLEO.sha256"
if [ -n "$NUC" ] && archivo_ok "$PROPIO" 1048576 && [ "$(digest "$PROPIO")" = "$NUC" ]; then
  ETIQUETA=2.0; NOTA=ok
elif leer_tabla; then
  pista=''
  for i in "${!TV[@]}"; do
    if [ -n "$NUC" ] && [ -n "$MAN" ] && [ "$NUC" = "${TN[$i]}" ] && [ "$MAN" = "${TM[$i]}" ]; then
      ETIQUETA="${TV[$i]}"; NOTA=ok; break
    fi
    if [ -z "$pista" ] && { { [ -n "$NUC" ] && [ "$NUC" = "${TN[$i]}" ]; } || { [ -n "$MAN" ] && [ "$MAN" = "${TM[$i]}" ]; }; }; then
      pista="${TV[$i]}"
    fi
  done
  if [ "$ETIQUETA" = desconocida ]; then
    if [ -n "$pista" ]; then NOTA="pista-$pista"
    elif [ -z "$NUC" ]; then NOTA=sin-nucleo
    elif [ -z "$MAN" ]; then NOTA=sin-manifiesto
    fi
  fi
else
  NOTA=tabla-invalida
fi

# Integridad: informativa, no decide la etiqueta.
declare -A D_SHA=()
if [ -n "$NUC" ] && desvio_sha "$NUCF"; then
  desvio_contadores
  for rel in "${!D_SHA[@]}"; do
    if tiene_enlace "$rel"; then D_DIST=$((D_DIST+1)); else desvio_compara "$DIR/$rel" "$rel"; fi
  done
  n=$((D_DIST+D_AUS+D_NO))
  if [ "$n" -eq 0 ]; then INTEGRIDAD=integra; else INTEGRIDAD="distinta:$n"; fi
fi

# fin-de-decision
n12="${NUC:0:12}"; m12="${MAN:0:12}"
printf 'ORIGEN %s nucleo=%s manifiesto=%s declarada=%s integridad=%s nota=%s\n' \
  "$ETIQUETA" "${n12:--}" "${m12:--}" "$DECLARADA" "$INTEGRIDAD" "$NOTA"
exit 0
