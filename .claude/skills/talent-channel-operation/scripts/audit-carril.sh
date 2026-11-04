#!/usr/bin/env bash
# audit-carril.sh — Lanza un carril de AUDITORÍA (5=ciberseguridad, 6=playwright). SOLO reporta.
# NO crea issues en Linear: deja un reporte de findings para que el coordinador lo presente al lead,
# que autoriza la creación (con label vertical/* + project). Uso: audit-carril.sh <carril> ciber|playwright
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"; . "$HERE/lib.sh"
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  tco_require_agents
  CARRIL_IN="${1:?carril}"; KIND="${2:?ciber|playwright}"; A="$HERE/../assets"
  rp="$(tco_repo_path)"
  # [CR] Contrato carril↔tipo (01-modelo-y-roles: 05=ciberseguridad, 06=playwright): un rol en
  # el carril equivocado produce un reporte confiado pero incorrecto. Fail-closed en el par.
  # El case ademas NORMALIZA el alias (5->05) ANTES del contenedor y del lock: '5' y '05'
  # concurrentes deben compartir exactamente el mismo lock, no dos distintos.
  case "$CARRIL_IN:$KIND" in
    05:ciber|5:ciber)           CARRIL=05; role="$A/audit-role-ciberseguridad.txt";;
    06:playwright|6:playwright) CARRIL=06; role="$A/audit-role-playwright.txt";;
    *) tco_die "carril/tipo inválido: $CARRIL_IN/$KIND (contrato: 05 ciber | 06 playwright)";;
  esac
  c="$(tco_container "$CARRIL")"
  tco_say "audit-carril $KIND -> $CARRIL"
  # [CR] Lock por carril: serializa TODO el bloque libre→kill→new (dos ejecuciones concurrentes
  # ya no pueden pisarse la sesión). Se libera al terminar el lanzamiento (abajo).
  tco_lock_acquire "audit-carril-$CARRIL" || tco_die "carril $CARRIL con lanzamiento de auditoría en curso (lock) — no se duplica."
  trap 'tco_lock_release "audit-carril-$CARRIL"' EXIT
  # [CR] Mismos guards que dispatch.sh: no clobbear trabajo en curso (carril ocupado → abortar)
  # y esperar la MUERTE real de la sesión vieja antes de crear la nueva (kill-session es
  # asíncrono; un new-session encima de una sesión moribunda deja panes zombis).
  if ! tco_carril_libre "$CARRIL"; then
    tco_die "carril $CARRIL OCUPADO (sesión activa con trabajo) — no se lanza auditoría encima."
  fi
  sess_res="$(incus exec "$c" -- su - "$TCO_CUSER" -c "
    tmux kill-session -t '$TCO_TMUX' 2>/dev/null || true
    for _k in 1 2 3 4 5 6 7 8 9 10; do tmux has-session -t '$TCO_TMUX' 2>/dev/null || break; sleep 0.3; done
    if tmux has-session -t '$TCO_TMUX' 2>/dev/null; then echo OLD-ALIVE; exit 0; fi
    tmux new-session -d -s '$TCO_TMUX' -x 220 -y 50 -c '$rp' && tmux split-window -h -t '$TCO_TMUX' -c '$rp' && echo NEW-OK || echo NEW-FAIL" 2>/dev/null || echo EXEC-FAIL)"
  # [CR] split-window: misma topologia de 2 panes que launcher/dispatch — sin el pane .1,
  # el siguiente tco_carril_libre (fail-closed en captura) marcaria el carril OCUPADO para siempre.
  [ "$sess_res" = NEW-OK ] || tco_die "$CARRIL: sesión tmux no creada limpia (estado=$sess_res) — ESCALAR"
  # [CR] carril de AUDITORÍA → CLI/flags de AUDITORÍA (como el pane .1 de dispatch.sh), no el de
  # desarrollo: si difieren, la auditoría correría con el modelo/config de dev (no la auditada).
  # [v5/A4] con MODEL_ARGS explícitos (el alias pelado no pasa --model → default de la cuenta,
  # que puede estar agotado).
  # COMPROBACIÓN PREVIA fail-closed: respawn-pane ejecuta con `bash -c` sin .bashrc; un alias no arranca el CLI de auditoría.
  # remain-on-exit primero (la sonda deja el pane muerto); la sonda es un respawn-pane en el pane de destino con el -c del
  # clon, y el lanzamiento ejecuta la ruta que ella acreditó, con el mismo -c. Destino ESTABLE: el `%N` del pane, leído UNA
  # vez aquí (sonda, lanzamiento, remain-on-exit, vida e identidad); después, la identidad del proceso lanzado (J5-04). Desde
  # aquí ese `%N` es el ÚNICO destino: el effort, la espera del TUI, el relay del rol y el ACK van por él (R9011j6 N-04).
  tco_pane_id_fijar "$CARRIL" "$(tco_pane_dev)" || tco_die "$CARRIL: no pude leer el id estable del pane de auditoría — no se lanza"
  P_AUD="$(tco_pane_destino "$(tco_pane_dev)")"
  tco_remain_preparar "$CARRIL" "$P_AUD" || tco_die "$CARRIL: no pude preparar remain-on-exit antes de lanzar — no se lanza"
  tco_launchers_ready "$CARRIL" "$rp" TCO_AUDIT_CLI "$P_AUD" "$TCO_AUDIT_CLI" \
    || tco_die "$CARRIL: lanzador de auditoría sin ejecutable en el canal — no se lanza (fail-closed; el error de arriba nombra el CLI y el remedio)"
  case "$TCO_AUDIT_CLI" in *claude*) tco_modelos_config || tco_die "$CARRIL: registro inválido antes de lanzar el auditor" ;; esac
  LANZ_AUD="$(tco_orden_acreditada TCO_AUDIT_CLI "$P_AUD" "$TCO_AUDIT_FLAGS ${TCO_AUDIT_MODEL_ARGS:-}")" \
    || tco_die "$CARRIL: sin ruta acreditada del lanzador de auditoría — no se lanza"
  incus exec "$c" -- su - "$TCO_CUSER" -c "tmux respawn-pane -k -t '$P_AUD' -c '$rp' '$LANZ_AUD'" \
    || tco_die "$CARRIL: no pude iniciar el proceso de auditoría"
  tco_panes_vivos "$CARRIL" TCO_AUDIT_CLI "$P_AUD" "$TCO_AUDIT_CLI" \
    || tco_die "$CARRIL: el pane de auditoría murió o no existe tras lanzarlo, o no se pudo restaurar remain-on-exit (el error de arriba nombra el CLI, el pane y el rc) — no se lanza"
  tco_pane_identidad_lanzada "$CARRIL" TCO_AUDIT_CLI "$P_AUD" "$TCO_AUDIT_CLI" \
    || tco_die "$CARRIL: el proceso de auditoría lanzado no es el agente acreditado por la sonda (identidad por dispositivo:inodo) — no se lanza"
  sleep 9
  # [Regla 0] /effort max PROHIBIDO; el carril de auditoría corre en high (plan v4). Al lanzar el
  # CLI de AUDITORÍA, el effort se fija con TCO_AUDIT_EFFORT_CMD (agente-agnóstico, mismo patrón
  # que dispatch.sh para el pane .1); vacío = no-op.
  if [ -n "${TCO_AUDIT_EFFORT_CMD:-}" ]; then
    # [CR] Fail-closed: si el effort configurado no se pudo fijar, la auditoría NO se da por
    # lanzada (degradar en silencio dejaría un gate corriendo con effort sin garantizar).
    _tco_send_text_submit "$CARRIL" "$P_AUD" "$TCO_AUDIT_EFFORT_CMD" C-m yes \
      || tco_die "$CARRIL: TCO_AUDIT_EFFORT_CMD configurado pero FALLÓ al enviar — effort del auditor sin garantizar"
    sleep 2
  fi
  # [CR/M1/M2] paste del rol + CONFIRMAR por la RESPUESTA del auditor (token al final de su línea, vía
  # tco_role_ack — no el eco del paste). Sin confirmación tras reintentos → FALLAR: un carril de auditoría
  # SIN rol cargado NO audita (haría trabajo genérico en silencio); mejor ESCALAR que devolver éxito falso.
  # [TAL-1623] esperar TUI listo antes de pegar (mismo caso que dispatch)
  tco_wait_tui_ready "$CARRIL" "$P_AUD" 90 \
    || tco_die "$CARRIL: el CLI de auditoría no llegó a estado LISTO en 90s — ESCALAR"
  # [v5] rol por la vía canónica file+`lee` (paste-buffer DEPRECADO — batch v14) + nudge con las
  # SUBMIT-KEYS del CLI del auditor (codex: 'Enter Enter'; C-m no envía). ACK ampliado
  # (TCO_ROLE_ACK_MAX ×5s): un panel fresco tarda ~40s+ en empezar a procesar tras el `lee`.
  ROLE_OK=no
  tco_wait_config 5 "${TCO_ROLE_ACK_MAX:-24}" || tco_die 'máximo de sondeos de rol inválido'
  ROLE_PENDING="$(mktemp)" || tco_die 'no pude crear el recibo del texto de rol'
  # El mensaje del relay NO lleva el token: su eco en el pane no puede acabar en él (el ACK es la RESPUESTA del auditor, no el
  # eco del `lee`; references/03). La línea que debe responder la pide el fichero del rol.
  for _ra in 1 2 3; do
    tco_relay_file "$CARRIL" "$P_AUD" "$role" "rol" \
      "— es tu ROL de auditoría: cárgalo y responde SOLO con la línea de confirmación de carga que pide el fichero" "${TCO_RELAY_VERIFY_MAX:-90}" "" "$ROLE_PENDING" || true
    for (( _w=1; _w<=${TCO_ROLE_ACK_MAX:-24}; _w++ )); do
      sleep 5 || tco_die 'espera de rol fallida'
      # nudge en el 2º ciclo: diálogo del TUI intercepta el submit — Escape lo descarta y las
      # submit-keys del CLI envían. El gate real sigue siendo el ACK.
      if [ "$_w" = 2 ]; then
        tco_escape_stuck_input "$CARRIL" "$P_AUD" || true
        sleep 1 || tco_die 'espera antes de submit fallida'
        tco_send_submit "$CARRIL" "$P_AUD" --expected "$(cat "$ROLE_PENDING")" || true
      fi
      if tco_cap_pane "$CARRIL" "$P_AUD" 2>/dev/null | tco_role_ack 'ROL-AUDITORIA-LISTO'; then ROLE_OK=yes; break; fi
    done
    [ "$ROLE_OK" = yes ] && break
    tco_err "$CARRIL: rol $KIND no confirmado por la RESPUESTA del auditor (intento $_ra) — reintento"
  done
  rm -f "$ROLE_PENDING"
  [ "$ROLE_OK" = yes ] || tco_die "no pude confirmar la carga del rol $KIND en $CARRIL (sin respuesta real 'ROL-AUDITORIA-LISTO' del auditor) — ESCALAR (auditor sin rol no audita)"
  tco_info "$KIND lanzado en $CARRIL (rol confirmado, solo reporta). Recoge findings y preséntalos al lead ANTES de crear issues."
fi
