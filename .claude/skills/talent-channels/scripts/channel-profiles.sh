#!/usr/bin/env bash
# channel-profiles.sh — [TAL-2630] Gestiona la GROUND-TRUTH declarada del perfil por canal:
# el mapa de escrow `$SECRET_DIR/channel-profiles.list` (líneas `canal=perfil`), contra el que
# verify.sh valida la credencial efectiva. IDEMPOTENTE. NO toca credenciales ni prod.
#
#   channel-profiles.sh set   <canal> <produccion|mergeador|piloto|runner>   # alta/actualización idempotente
#   channel-profiles.sh unset <canal>                                 # quita la declaración
#   channel-profiles.sh list                                          # muestra el mapa
#
# [TAL-5142] `piloto` = canal de LABORATORIO (A2A): MISMAS reglas que `mergeador` (porta CODERABBIT_API_KEY
# y sbp_ efectiva; identidad env/git verificada contra escrow). Se separa por NOMBRE para no confundir un
# canal de LAB con una estación de merge real.
# El perfil es DECLARACIÓN, no inferencia: se declara por NOMBRE de canal (p. ej. 91-94 = mergeador,
# 85-88 = runner), independiente de qué credencial porte hoy. Ver references/05 §Perfiles.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TC_INVOKE_CWD="${TC_INVOKE_CWD:-$PWD}"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

MAP="$(tc_channel_profiles_file)"

_valid_channel() { printf '%s' "$1" | grep -qE '^[A-Za-z][A-Za-z0-9._-]*$'; }
_valid_profile() { case "$1" in produccion|mergeador|piloto|runner) return 0;; *) return 1;; esac; }

_ensure_map() {
  tc_secret_dir
  if [ ! -e "$MAP" ]; then ( umask 077; : > "$MAP" ); chmod 600 "$MAP"; fi
}

# Reescribe el mapa quitando la línea de <canal> (idempotente). Escritura atómica temp+mv.
_map_without() {
  local ch="$1" tmp line
  tmp="$(mktemp "$MAP.XXXXXX")"; chmod 600 "$tmp"
  if [ -f "$MAP" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|\#*) printf '%s\n' "$line" >> "$tmp"; continue;; esac
      [ "${line%%=*}" = "$ch" ] && continue
      printf '%s\n' "$line" >> "$tmp"
    done < "$MAP"
  fi
  mv -f "$tmp" "$MAP"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  set)
    ch="${1:-}"; prof="${2:-}"
    _valid_channel "$ch" || tc_die "canal inválido: '$ch'"
    _valid_profile "$prof" || tc_die "perfil inválido: '$prof' (usa produccion|mergeador|piloto|runner)"
    _ensure_map
    _map_without "$ch"                              # idempotente: quita cualquier declaración previa
    ( umask 077; printf '%s=%s\n' "$ch" "$prof" >> "$MAP" )
    tc_info "perfil declarado: $ch=$prof"
    ;;
  unset)
    ch="${1:-}"
    _valid_channel "$ch" || tc_die "canal inválido: '$ch'"
    [ -f "$MAP" ] || { tc_info "mapa vacío (nada que quitar)"; exit 0; }
    _map_without "$ch"
    tc_info "perfil retirado: $ch (sin declaración → verify.sh lo FALLA fail-closed; vuelve a declararlo)"
    ;;
  list)
    if [ -s "$MAP" ]; then cat "$MAP"; else tc_info "mapa vacío ($MAP): ningún canal declarado → verify.sh los FALLA a todos (fail-closed). Declara cada canal con 'set'."; fi
    ;;
  ""|-h|--help)
    echo "uso: channel-profiles.sh set <canal> <produccion|mergeador|piloto|runner> | unset <canal> | list"
    ;;
  *) tc_die "subcomando desconocido: '$cmd' (set|unset|list)";;
esac
