#!/usr/bin/env bash
# relay.sh — Entrega una orden a un pane tmux del coordinador y VERIFICA el acuse de forma causal.
#
# Cierra el agujero de TAL-5141: teclear texto+Enter en la misma invocación (o sin verificar) dejaba
# la orden a la vista SIN enviar mientras el sweep la daba por ociosa. Aquí el envío es fail-loud:
#   - solo se teclea sobre un pane RELAY-READY (idle estable instantáneo);
#   - TEXTO y SUBMIT van en invocaciones SEPARADAS (el Enter en la misma llamada se pierde en un TUI);
#   - el acuse NUNCA se declara por "actividad": exige que el composer se VACÍE (texto consumido) Y una
#     transición idle->busy comprobada — nunca una señal aislada, nunca el scrollback, nunca contar viñetas;
#   - un mensaje ENCOLADO (Press up to edit queued messages) es un estado propio (rc 5), jamás un OK;
#   - SIN reintento ciego (duplicaría una orden no idempotente): al vencer el deadline, rc 1 fail-loud.
#
# Uso:
#   relay.sh <target> [-f|--file <ruta>]      # texto por stdin (por defecto) o por fichero
#   echo 'orden' | relay.sh <target>
#   relay.sh <target> 'orden simple'          # 3er argv como texto (evítalo si lleva comillas: usa stdin)
#
# <target>: canal-NN | ch-NN | chNN | torre-<actor> | host:<sesion>[.<pane>]  (ver idle-check.sh)
#
# rc: 0 acuse causal · 1 sin acuse (deadline con capturas válidas) ·
#     2 uso/multilínea/no-llegó/NO-MEDIDO (no localicé el composer o sin captura — NUNCA "ocupado") ·
#     3 menú abierto (no tecleó) · 4 composer con texto ajeno (no clobbear) · 5 ENCOLADO (no reintentado) ·
#     6 NO-READY al enviar (composer LOCALIZADO y positivamente no idle).
#
# Invariantes: el script solo ENTREGA y VERIFICA (no decide contenido); nunca inyecta '--continue';
# el texto viaja SIEMPRE como posicional literal (inmune a comillas/$/backticks).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=idle-check.sh disable=SC1091
. "$HERE/idle-check.sh"

: "${TC_SUBMIT_SEQ:=C-m}"        # teclas de submit (allowlist por tecla; algunos TUI pierden C-m y
                                 # requieren 'Enter Enter' — calibrar por CLI vía override, ver README)
: "${TC_SUBMIT_GAP:=2}"          # segundos entre el send-keys del TEXTO y el del SUBMIT (Enter separado)
: "${TC_ACUSE_TIMEOUT:=20}"      # ventana (s) de espera del acuse tras el submit (reloj real, poll ~1s)
: "${TC_WAIT_READY:=0}"          # s máximos a esperar RELAY-READY antes de teclear (0 = no esperar)

relay_err() { printf 'relay: %s\n' "$1" >&2; }

# --- Envío por transporte (host tmux vs incus), texto SIEMPRE posicional ---
_tc_send_text() { # <text>
  # En la rama incus, $1/$2 dentro de las comillas simples son posicionales del shell REMOTO (su -c),
  # no expansión local: es el patrón anti-inyección (el texto viaja como posicional, nunca interpolado).
  # shellcheck disable=SC2016
  case "$TC_MODE" in
    host)  "${TC_TMUX_CMD[@]}" send-keys -t "$TC_SESSPANE" -l -- "$1" ;;
    incus) incus exec "$TC_CONTAINER" -- su - "$TC_CUSER" -c \
             'tmux send-keys -t "$1" -l -- "$2"' _ "$TC_SESSPANE" "$1" ;;
  esac
}
# shellcheck disable=SC2016
_tc_send_key() { # <key de la allowlist>
  local key="$1"
  case "$key" in Enter|C-m|Escape|Tab) ;; *) relay_err "tecla de submit no permitida: $key"; return 2 ;; esac
  case "$TC_MODE" in
    host)  "${TC_TMUX_CMD[@]}" send-keys -t "$TC_SESSPANE" "$key" ;;
    incus) incus exec "$TC_CONTAINER" -- su - "$TC_CUSER" -c \
             'tmux send-keys -t "$1" "$2"' _ "$TC_SESSPANE" "$key" ;;
  esac
}
# Emite la secuencia de submit (una invocación de send-keys por tecla; allowlist estricta, sin eval).
_tc_submit() {
  local k
  for k in $TC_SUBMIT_SEQ; do _tc_send_key "$k" || return $?; done
}

# --- Lectura del texto (precedencia: --file > stdin > argv) ---
main() {
  local target="" file="" text="" got_text=0
  local -a rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--file) file="${2:-}"; shift 2 ;;
      -h|--help) grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; return 2 ;;
      --) shift; while [ $# -gt 0 ]; do rest+=("$1"); shift; done ;;
      -*) relay_err "opción desconocida: $1"; return 2 ;;
      *) if [ -z "$target" ]; then target="$1"; else rest+=("$1"); fi; shift ;;
    esac
  done
  [ -n "$target" ] || { relay_err "falta <target>"; return 2; }

  if [ -n "$file" ]; then
    [ -f "$file" ] || { relay_err "fichero no encontrado: $file"; return 2; }
    text="$(cat -- "$file")"; got_text=1
  elif [ "${#rest[@]}" -gt 0 ]; then
    text="${rest[*]}"; got_text=1
  elif [ ! -t 0 ]; then
    text="$(cat)"; got_text=1
  fi
  [ "$got_text" -eq 1 ] || { relay_err "falta el texto (stdin, --file o argv)"; return 2; }

  text="${text%$'\n'}"                                   # tolera un único salto final
  [ -n "$text" ] || { relay_err "texto vacío"; return 2; }
  case "$text" in *$'\n'*) relay_err "texto multilínea no soportado (usa el mecanismo file+lee del canal)"; return 2 ;; esac

  _tc_resolve "$target" || return 2

  # 1. Precondición: RELAY-READY (idle estable instantáneo). Espera acotada opcional.
  local ready=1 waited=0
  while :; do
    ready=0; ic_relay_ready "$target" >/dev/null || ready=$?
    [ "$ready" -eq 0 ] && break
    [ "$ready" -eq 2 ] && { relay_err "$target: NO-MEDIDO (no localicé el composer o sin captura) — no tecleo"; return 2; }
    [ "$waited" -ge "$TC_WAIT_READY" ] && break
    sleep 1; waited=$(( waited + 1 ))
  done
  if [ "$ready" -ne 0 ]; then
    # Traduce el motivo a un rc específico y NO teclea. ic_menu_open/ic_queue_pending son la FUENTE
    # ÚNICA del límite anti-scrollback (nunca detectores sobre texto crudo ni una ventana absoluta).
    local cap_plain
    cap_plain="$(_tc_cap_e | ic_strip_ansi || true)"
    if printf '%s\n' "$cap_plain" | ic_menu_open;    then relay_err "$target: menú abierto — no tecleo"; return 3; fi
    if printf '%s\n' "$cap_plain" | ic_queue_pending; then relay_err "$target: cola pendiente (encolado previo)"; return 5; fi
    # ¿texto ajeno en el composer? -> no clobbear
    local anchor top bot
    if anchor="$(printf '%s\n' "$cap_plain" | ic_anchor)"; then
      top="${anchor%% *}"; bot="${anchor##* }"
      if _tc_cap_e | ic_detect_pending_region "$top" "$bot"; then
        relay_err "$target: composer con texto ajeno — no clobbear"; return 4
      fi
    fi
    relay_err "$target: NO-READY al enviar (no idle estable)"; return 6
  fi

  # 2. Enviar el TEXTO (posicional) y verificar que el LITERAL exacto llegó al composer (no "algún
  #    texto" — un envío truncado/alterado no puede colarse como si hubiera llegado intacto).
  _tc_send_text "$text" || { relay_err "$target: fallo al enviar el texto"; return 2; }
  sleep 1
  local pre_rc=0
  _tc_cap_e | ic_composer_contains "$text" || pre_rc=$?
  if [ "$pre_rc" -ne 0 ]; then
    relay_err "$target: el texto (literal) no aparece en el composer — no someto"; return 2
  fi

  # 3. SUBMIT en invocación SEPARADA (Enter separado real).
  sleep "$TC_SUBMIT_GAP"
  _tc_submit || { relay_err "$target: fallo al enviar el submit"; return 2; }

  # 4. BUCLE de verificación del acuse hasta el deadline (reloj real). Actividad != envío: el acuse
  #    exige la CONJUNCIÓN composer VACÍO estructural (nunca AMBIGUO/sin-CORNER — eso NO prueba que el
  #    texto se consumió) Y una transición idle->busy comprobada.
  local deadline start now cap_e cap_plain cs_rc saw_busy=0 got_valid=0
  start="$(date +%s)"; deadline=$(( start + TC_ACUSE_TIMEOUT ))
  while :; do
    now="$(date +%s)"; [ "$now" -ge "$deadline" ] && break
    cap_e="$(_tc_cap_e || true)"
    if [ -z "$cap_e" ]; then sleep 1; continue; fi         # captura fallida != composer vacío
    got_valid=1
    cap_plain="$(printf '%s' "$cap_e" | ic_strip_ansi)"
    # ENCOLADO primero (vía ic_queue_pending — mismo límite anti-scrollback que ic_classify): estado
    # propio, jamás OK.
    if printf '%s\n' "$cap_plain" | ic_queue_pending; then relay_err "$target: ENCOLADO — orden sin enviar"; return 5; fi
    # Menú aparecido tras el submit.
    if printf '%s\n' "$cap_plain" | ic_menu_open; then relay_err "$target: menú abierto tras el submit"; return 3; fi
    # Transición idle->busy (actividad causada por mi envío, ya que partí de RELAY-READY).
    if printf '%s\n' "$cap_plain" | ic_detect_busy_from; then saw_busy=1; fi
    # ACUSE causal: composer VACÍO estructural (rc1, NUNCA rc2 AMBIGUO) Y transición busy observada.
    cs_rc=0; printf '%s' "$cap_e" | ic_composer_state >/dev/null || cs_rc=$?
    if [ "$saw_busy" -eq 1 ] && [ "$cs_rc" -eq 1 ]; then
      return 0
    fi
    sleep 1
  done

  # Deadline sin acuse.
  if [ "$got_valid" -eq 0 ]; then relay_err "$target: ninguna captura válida en la ventana (UNKNOWN)"; return 2; fi
  relay_err "$target: sin acuse tras ${TC_ACUSE_TIMEOUT}s (texto puede seguir en el composer):"
  _tc_cap_e | ic_strip_ansi | tail -n "$TC_STATUS_TAIL" >&2 || true
  return 1
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
