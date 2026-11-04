#!/usr/bin/env bash
# migrate-channel-identity.sh — Re-bake de la identidad git en canales EXISTENTES (TAL-3473).
#
# Los canales provisionados antes del esquema por-canal portan la identidad del HOST (heredada
# por el golden viejo) o NINGUNA. Este script escribe en cada canal la identidad canónica
# expandiendo {channel} sobre TF_CHANNEL_GIT_{NAME,EMAIL}_TMPL (manifiesto de la fábrica) y
# VERIFICA la escritura leyendo de vuelta como $CUSER. Idempotente: re-ejecutar = refresh.
#
# IMPORTANTE (rollout de flota, plan de la ola): cambiar el config NO reescribe commits ya
# creados — la reconciliación del trabajo VIVO (WIP/commits con identidad anterior) es un paso
# SEPARADO del rollout del parent, bajo PARO, y NO lo hace este script.
#
# Uso:
#   bash migrate-channel-identity.sh all            # todos los canales RUNNING de la fábrica
#   bash migrate-channel-identity.sh <canal> [...]  # canales concretos
# Salida: una línea literal por canal (OK/FAIL con antes→después). rc 0 solo si TODOS OK.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

[ -n "${TF_CHANNEL_GIT_NAME_TMPL:-}" ] && [ -n "${TF_CHANNEL_GIT_EMAIL_TMPL:-}" ] \
  || tc_die "TF_CHANNEL_GIT_NAME_TMPL/TF_CHANNEL_GIT_EMAIL_TMPL sin definir (manifiesto de la fábrica) — nada que migrar sin el esquema (fail-closed)."

targets=()
if [ "${1:-}" = all ]; then
  # La rama `all` SOLO migra canales que COMMITEAN (perfiles produccion/mergeador del mapa
  # declarado): los runners sellados conservan su invariante LIMPIO y un perfil no resoluble
  # se EXCLUYE con traza (fail-closed hacia no-tocar; migrarlo exige nombrarlo explícito).
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    prof="$(tc_expected_profile "$c" 2>/dev/null || echo unresolved)"
    case "$prof" in
      produccion|mergeador) targets+=("$c") ;;
      *) echo "SKIP $c: perfil '$prof' fuera de la migración all (solo produccion/mergeador; explícito si procede)" ;;
    esac
  done < <(incus list -c ns -f csv | awk -F, '$2=="RUNNING" && $1 ~ /^'"$PREFIX"'/ {print $1}')
else
  [ $# -ge 1 ] || tc_die "uso: migrate-channel-identity.sh all | <canal> [...]"
  targets=("$@")
fi
[ ${#targets[@]} -ge 1 ] || tc_die "cero canales objetivo."

fails=0
for ch in "${targets[@]}"; do
  want_name="${TF_CHANNEL_GIT_NAME_TMPL//\{channel\}/$ch}"
  want_mail="${TF_CHANNEL_GIT_EMAIL_TMPL//\{channel\}/$ch}"
  case "$want_name$want_mail" in *"{"*"}"*) echo "FAIL $ch: placeholder sin resolver"; fails=$((fails+1)); continue;; esac
  before="$(incus exec "$ch" -- su - "$CUSER" -c 'printf "%s <%s>" "$(git config --global user.name 2>/dev/null)" "$(git config --global user.email 2>/dev/null)"' 2>/dev/null || echo '?')"
  if ! incus exec "$ch" -- su - "$CUSER" -c 'git config --global user.name "$1"; git config --global user.email "$2"' _ "$want_name" "$want_mail" 2>/dev/null; then
    echo "FAIL $ch: escritura del git config falló (antes: $before)"; fails=$((fails+1)); continue
  fi
  if tc_verify_git_identity "$ch"; then
    echo "OK   $ch: $before -> $want_name <$want_mail>"
  else
    echo "FAIL $ch: verificación post-escritura no coincide (antes: $before)"; fails=$((fails+1))
  fi
done
[ "$fails" -eq 0 ] || { echo "MIGRACIÓN INCOMPLETA: $fails canal(es) FAIL"; exit 1; }
echo "MIGRACIÓN OK: ${#targets[@]} canal(es) con identidad canónica verificada."
