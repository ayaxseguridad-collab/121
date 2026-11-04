#!/usr/bin/env bash
# refresh-codex-auth.sh — Propaga el login de Codex del host (~/.codex/auth.json) a UN canal.
#
# ⚠️ [TAL-2294] Codex rota el refresh token EN CADA USO (de un solo uso). COPIAR el mismo auth.json a
# varios destinos (o dejarlo vivo en el host Y en un canal) re-arma la CASCADA de deslogueos: el
# primer uso en cualquier copia invalida el refresh de las demás → "refresh token revoked" en toda la
# flota. Por eso el gotcha 8 se INVIERTE: Codex NO sobrevive al clonado. La vía correcta para MOVER un
# login de Codex es 'auth-move.sh move <cuenta> <from> <to>' (MOVE transaccional: un-login-un-lugar,
# freeze + journal + commit atómico). Este script queda SOLO para el arranque puntual de UN canal a
# partir del host y RECHAZA el fan-out 'all'.
#
# Uso: refresh-codex-auth.sh <canal> [--restart]
#   (sin flags)  NO destructivo: propaga a UN canal + VERIFICA el fingerprint (md5) en ambos lados.
#   --restart    Además recicla codex (kill por PID host-side con bash -c, NO su -c; relaunch del
#                alias). RESETEA el contexto pero NO el repo. Trabajo en vuelo → RE-BRIEFEO por el
#                coordinador (talent-channel-operation ref 11). El relaunch RESPETA el freeze de MOVE.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

SRC="$HOST_HOME/.codex/auth.json"
[ -f "$SRC" ] || tc_die "El host no tiene $SRC (haz 'codex login' en el host con la cuenta destino primero)."

arg=""; RESTART=no
for a in "$@"; do
  case "$a" in
    --restart) RESTART=yes ;;
    -*)        tc_die "flag desconocido: $a (uso: refresh-codex-auth.sh <canal> [--restart])" ;;
    *)         arg="$a" ;;
  esac
done

# [TAL-2294] Fan-out PROHIBIDO para Codex: 'all' (o vacío) clonaría el mismo refresh token a N canales
# y re-armaría la cascada. Exige UN destino explícito; para mover entre endpoints usa el MOVE.
[ -n "$arg" ] || tc_die "falta el canal destino. Codex NO se propaga en fan-out (re-arma la cascada de rotación). Uso: refresh-codex-auth.sh <canal> [--restart]. Para MOVER un login entre endpoints: auth-move.sh move <cuenta> <from> <to>."
[ "$arg" != all ] || tc_die "'all' PROHIBIDO para Codex (fan-out del mismo refresh token de un solo uso = cascada de deslogueos). Propaga a UN canal, o usa 'auth-move.sh' para un MOVE transaccional."
targets=("$arg")

src_md5="$(md5sum "$SRC" | awk '{print $1}')"
[ "$RESTART" = yes ] && restart_note=" con --restart" || restart_note=""
tc_info "Login Codex del host: fingerprint ${src_md5:0:8} -> propagando a ${#targets[@]} canal(es)${restart_note}."

fail=0
for ch in "${targets[@]}"; do
  incus info "$ch" >/dev/null 2>&1 || { tc_info "$ch no existe (saltado)"; continue; }
  # [TAL-2294] Si un MOVE tiene congelado este canal, NO tocar su auth (el MOVE es dueño de la
  # transacción). El freeze se retira al cerrar el MOVE (auth-move.sh resume <tx>).
  if incus exec "$ch" -- test -f "/home/$CUSER/.codex/.move-freeze" 2>/dev/null; then
    tc_err "$ch: CONGELADO por un MOVE de credenciales en curso — no propago (deja que el MOVE cierre; auth-move.sh resume <tx>)"
    fail=1; continue
  fi
  # Asegurar el directorio del usuario (cubre el bug de golden viejos: dir root-owned o ausente).
  # Rutas hardcodeadas bajo /home/$CUSER y entre comillas (no se acepta path externo parametrizable).
  incus exec "$ch" -- mkdir -p "/home/$CUSER/.codex"
  incus exec "$ch" -- chown -R "$CUSER:$CUSER" "/home/$CUSER/.codex"
  tc_push_secret_file "$SRC" "$ch" "/home/$CUSER/.codex/auth.json" 600
  dst_md5="$(incus exec "$ch" -- md5sum "/home/$CUSER/.codex/auth.json" 2>/dev/null | awk '{print $1}')"
  if [ "$dst_md5" != "$src_md5" ]; then
    tc_err "$ch: fingerprint NO coincide (host=${src_md5:0:8} carril=${dst_md5:0:8}) — login mal propagado"
    fail=1; continue
  fi
  echo "  ✓ Codex refrescado en $ch (fingerprint ${src_md5:0:8} verificado)"
  if [ "$RESTART" = yes ]; then
    # Matar TODOS los PID de codex del usuario + ESPERAR a que no quede ninguno antes de relanzar
    # (CR #549): pgrep|head -1 dejaría vivo el correcto si hay más de un match, y el relaunch entraría
    # en un Codex activo. Helper con kill host-side (bash -c) que casa el EJECUTABLE `codex` (TAL-8042).
    if tc_kill_wait "$ch" codex "$CUSER"; then
      incus exec "$ch" -- su - "$CUSER" -c \
        "tmux send-keys -t '${TC_CODEX_PANE:-v:.1}' '${TC_CODEX_RELAUNCH:-codex-root}' C-m" 2>/dev/null \
        || tc_info "    $ch: no pude relanzar el alias en '${TC_CODEX_PANE:-v:.1}' (sesion tmux distinta?) — relanza a mano"
      echo "    (reciclado: contexto reseteado, repo intacto) — RE-BRIEFEAR si tenia trabajo en vuelo"
    else
      tc_err "$ch: quedan procesos codex vivos tras el kill — NO relanzo (evitaria meter el alias en un Codex activo); revisar a mano"
      fail=1
    fi
  fi
done

if [ "$RESTART" != yes ]; then
  tc_info "Propagacion hecha (no destructiva). Verifica con 'codex login status' en el carril (debe decir 'Logged in'); para que tome efecto, re-corre con --restart o cierra codex y relanza."
fi
[ "$fail" -eq 0 ] || tc_die "alguna propagacion fallo el check de fingerprint — revisar los carriles marcados arriba."
