#!/usr/bin/env bash
# refresh-claude-auth.sh — Propaga las credenciales Claude del host (~/.claude/.credentials.json) a
# los canales cuando la cuenta rota o se agota (rate-limit). Verificado en producción: cambio de
# cuenta de la flota completa a una cuenta Max nueva, 0 stalls. Idempotente. La PROPAGACIÓN es el
# método canónico de acreditación/re-auth (TAL-2279); el login per-carril queda como excepción de
# último recurso. Esto propaga la cuenta que el host tenga activa tal cual (HOST-ONLY: no cosecha
# de un hermano/canal — para eso ver la receta manual de references/05-credenciales-por-carril.md).
#
# Uso: refresh-claude-auth.sh [canal|all] [--restart]
#   (sin flags)  NO destructivo: solo propaga las credenciales + VERIFICA el fingerprint (md5) en
#                ambos lados. No toca procesos ni el repo del carril.
#   --restart    Además RECICLA el proceso claude para que la cuenta nueva tome efecto: mata claude
#                por PID host-side (bash -c, NO su -c — su -c devuelve exit 137 al matar y aborta el
#                comando) y relanza el alias en el pane. RESETEA el contexto de conversación pero NO
#                el repo (working tree + commits se preservan). Los carriles con trabajo en vuelo
#                necesitan RE-BRIEFEO de reanudación → lo orquesta el coordinador (talent-channel-
#                operation, PROC de rotación de cuenta en references/11-modelo-effort-y-recycle.md).
#
# Fan-out ESCALONADO (doctrina SKILL.md §Sizing): con >1 canal en el fan-out, este script espera
# TC_FANOUT_STAGGER_SEC (rango "min-max" o un valor fijo; default "30-60") ANTES de cada canal salvo
# el primero — nunca en burst, para no disparar rate-limit de la API del proveedor por N clientes
# refrescando/reconectando a la vez. Desactivar (tests/CI): TC_FANOUT_STAGGER_SEC=0.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"
# sudo conserva al propietario del host; el registro pertenece a ese usuario.
: "${TCO_MODELOS_REGISTRO:=$HOST_HOME/.config/talent-channel-operation/modelos.conf}"
# shellcheck source=/dev/null
. "$HERE/../../talent-channel-operation/scripts/lib-modelos.sh"

SRC="$HOST_HOME/.claude/.credentials.json"
[ -f "$SRC" ] || tc_die "El host no tiene $SRC — materializa la cred en el HOST primero (login, o propágala/coséchala ahí) antes de propagar a los carriles."

# --- args: [canal|all] y --restart en cualquier orden ---
arg=all; RESTART=no
for a in "$@"; do
  case "$a" in
    --restart) RESTART=yes ;;
    -*)        tc_die "flag desconocido: $a (uso: refresh-claude-auth.sh [canal|all] [--restart])" ;;
    *)         arg="$a" ;;
  esac
done

targets=()
if [ "$arg" = all ]; then for y in $(seq 1 "${COUNT:?}"); do targets+=("$(tc_channel_name "$y")"); done; else targets=("$arg"); fi

src_md5="$(md5sum "$SRC" | awk '{print $1}')"
[ "$RESTART" = yes ] && restart_note=" con --restart" || restart_note=""
tc_info "Cuenta del host: fingerprint ${src_md5:0:8} -> propagando a ${#targets[@]} canal(es)${restart_note}."

# Fan-out ESCALONADO: segundos de espera antes del SIGUIENTE canal (nunca antes del primero).
# Acepta un rango "min-max" o un valor fijo; "0"/"no"/"off" desactiva (tests/CI).
# VALIDACIÓN FAIL-CLOSED del override (Bash puro, sin grep): un valor fuera de la gramática
# ABORTA ANTES de escribir/reiniciar el primer canal — jamás degrada en silencio a "sin espera",
# porque eso convertiría el fan-out en burst (la invariante del skill es NUNCA en burst).
# Gramática admitida: 0|no|off · entero N (>=0) · rango N-M con N<=M.
tc_fanout_validate_spec() {
  local spec="${TC_FANOUT_STAGGER_SEC:-30-60}" lo hi
  case "$spec" in
    0|no|off) return 0 ;;
    *[!0-9-]*|-*|*-|*-*-*) tc_die "TC_FANOUT_STAGGER_SEC inválido ('$spec') — fail-closed: no se propaga nada (gramática: 0|no|off, entero N, o rango N-M con N<=M, máx 86400; vacía = default 30-60)" ;;
    *-*) lo="${spec%-*}"; hi="${spec#*-}" ;;
    *)   lo="$spec"; hi="$spec" ;;
  esac
  # DOMINIO NUMÉRICO ÚNICO con la derivación: base-10 explícita (10#) y magnitud acotada.
  # Sin 10#, "08" sería octal inválido en $(( )) y reventaría DESPUÉS del primer canal (burst
  # parcial con flota a medias); sin el cap, un entero desbordado pasaría la forma y haría
  # fallar el [ -gt ] del sleep en silencio. Todo valor que la validación acepta es derivable.
  [ "${#lo}" -le 5 ] && [ "${#hi}" -le 5 ] || tc_die "TC_FANOUT_STAGGER_SEC inválido ('$spec'): magnitud fuera de rango (máx 5 dígitos / 86400 s) — fail-closed, no se propaga nada"
  [ $((10#$hi)) -le 86400 ] || tc_die "TC_FANOUT_STAGGER_SEC inválido ('$spec'): supera 86400 s (1 día) — fail-closed, no se propaga nada"
  [ $((10#$lo)) -le $((10#$hi)) ] || tc_die "TC_FANOUT_STAGGER_SEC inválido ('$spec'): rango con min>max — fail-closed, no se propaga nada"
  return 0
}
tc_fanout_stagger_sec() {
  local spec="${TC_FANOUT_STAGGER_SEC:-30-60}" lo hi
  case "$spec" in
    0|no|off) echo 0; return ;;
    *-*) lo=$((10#${spec%-*})); hi=$((10#${spec#*-})); echo $(( lo + RANDOM % (hi - lo + 1) )) ;;
    *)   echo $((10#$spec)) ;;
  esac
}
# La validación corre AQUÍ, antes del loop: con >0 canales ningún side-effect ocurre con un
# override roto (el abort deja la flota intacta).
tc_fanout_validate_spec

fail=0
first=1
for ch in "${targets[@]}"; do
  if [ "$first" -eq 1 ]; then
    first=0
  else
    stagger="$(tc_fanout_stagger_sec)"
    if [ "$stagger" -gt 0 ]; then
      tc_info "  … esperando ${stagger}s antes del siguiente canal (fan-out escalonado, evita burst de rate-limit)"
      sleep "$stagger"
    fi
  fi
  incus info "$ch" >/dev/null 2>&1 || { tc_info "$ch no existe (saltado)"; continue; }
  # [TAL-2294] Si un MOVE tiene congelado este canal para Claude, NO tocar su auth (el MOVE es dueño).
  if incus exec "$ch" -- test -f "/home/$CUSER/.claude/.move-freeze" 2>/dev/null; then
    tc_err "$ch: CONGELADO por un MOVE de credenciales en curso — no propago (auth-move.sh resume <tx>)"
    fail=1; continue
  fi
  # Asegurar el directorio del usuario (mismo riesgo latente que .codex en goldens viejos: dir ausente o root-owned).
  incus exec "$ch" -- mkdir -p "/home/$CUSER/.claude"
  incus exec "$ch" -- chown -R "$CUSER:$CUSER" "/home/$CUSER/.claude"
  tc_push_secret_file "$SRC" "$ch" "/home/$CUSER/.claude/.credentials.json" 600
  # VERIFICAR fingerprint idéntico en ambos lados (una propagación silenciosamente truncada dejaría
  # el carril con credenciales corruptas y colgado — el md5 lo caza).
  dst_md5="$(incus exec "$ch" -- md5sum "/home/$CUSER/.claude/.credentials.json" 2>/dev/null | awk '{print $1}')"
  if [ "$dst_md5" != "$src_md5" ]; then
    tc_err "$ch: fingerprint NO coincide (host=${src_md5:0:8} carril=${dst_md5:0:8}) — credenciales mal propagadas"
    fail=1; continue
  fi
  echo "  ✓ Claude refrescado en $ch (fingerprint ${src_md5:0:8} verificado)"
  if [ "$RESTART" = yes ]; then
    # La fase se recupera del panel o su configuración; el entorno permite anularla.
    restart_pane="$(tco_modelo_panel_instancia)" || { tc_err "$ch: selección de panel inválida"; fail=1; continue; }
    incus exec "$ch" -- su - "$CUSER" -c "tmux display-message -p -t '$restart_pane' '#{pane_id}'" >/dev/null 2>&1 \
      || { tc_err "$ch: panel '$restart_pane' ausente; agente preservado"; fail=1; continue; }
    restart_cli="${TC_CLAUDE_RELAUNCH:-claude-root}"
    restart_cmd="$restart_cli"
    restart_exe="${restart_cli%% *}"; restart_exe="${restart_exe##*/}"
    case "$restart_exe" in
      claude|claude-root)
        restart_phase="$(tco_modelo_fase_canal "$ch" "$CUSER" "$restart_pane")" || { fail=1; continue; }
        restart_model="$(tco_modelo_read "$restart_phase")" && [ -n "$restart_model" ] || { fail=1; continue; }
        restart_cmd="$restart_cli --model $restart_model" ;;
    esac
    # Matar TODOS los PID de claude del usuario (no solo el primero: otros seguirían con la cuenta
    # vieja) y ESPERAR a que no quede ninguno antes de relanzar (CR #549). Kill host-side dentro del
    # helper (bash -c, no su -c: el exit 137 abortaría el bucle). Casa el EJECUTABLE `claude` (TAL-8042),
    # no la línea de comandos. Si algún proceso sobrevive → NO relanzar (el alias entraría en la TUI vieja).
    if tc_kill_wait "$ch" claude "$CUSER"; then
      # Mantener la autoridad vigente en el punto de uso, también si el registro cambia durante el kill.
      case "$restart_exe" in
        claude|claude-root)
          restart_phase="$(tco_modelo_fase_canal "$ch" "$CUSER" "$restart_pane")" || { fail=1; continue; }
          restart_model="$(tco_modelo_read "$restart_phase")" && [ -n "$restart_model" ] || { fail=1; continue; }
          restart_cmd="$restart_cli --model $restart_model" ;;
      esac
      # Relanzar el alias en el pane de claude (default v:.0; configurable). El working tree y los
      # commits se preservan — kill+relaunch NO toca el repo.
      incus exec "$ch" -- su - "$CUSER" -c \
        "tmux send-keys -t '$restart_pane' '$restart_cmd' C-m" 2>/dev/null \
        || { tc_err "    $ch: no pude relanzar en '$restart_pane' — relanza a mano"; fail=1; continue; }
      echo "    (reciclado: contexto reseteado, repo intacto) — RE-BRIEFEAR si tenia trabajo en vuelo"
    else
      tc_err "$ch: quedan procesos claude vivos tras el kill — NO relanzo (evitaria meter el alias en la TUI vieja); revisar a mano"
      fail=1
    fi
  fi
done

if [ "$RESTART" != yes ]; then
  tc_info "Propagacion hecha (no destructiva). Para que la cuenta nueva TOME EFECTO: re-corre con --restart, o en cada carril cierra claude y relanza."
fi
[ "$fail" -eq 0 ] || tc_die "alguna propagación o relanzamiento falló — revisar los carriles marcados arriba."
