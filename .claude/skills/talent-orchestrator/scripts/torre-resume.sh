#!/usr/bin/env bash
# torre-resume.sh — Resume CANONICO de un actor bajo la Torre (TAL-2278): el "lanzador torre-*".
# Uso: torre-resume.sh <actor> --cwd <dir> [--uuid <uuid>] [--window-s N] [--list] [--dry-run]
# Doctrina (runbook §Procedimiento): NUNCA `--continue` con varias sesiones del mismo dir; la
# sesion VIVA es la del transcript con mtime==AHORA (no "la hora mas alta"); relanzar SIEMPRE con
# bypass (IS_SANDBOX=1 CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 claude --dangerously-skip-permissions --resume <uuid>) desde el cwd EXACTO.
# Renderer CLASICO (TAL-8038): el comando lleva CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 y, ANTES de crear la sesion, se
# instalan `.tui=default` + la barra `ctx:` (talent-context/scripts/install-statusline.sh): sin pantalla alternada el pane
# conserva scrollback (PLAN/handoff capturables) y sin statusLine ninguna torre emite `ctx: NN%` (compact-60 ciego).
# Seguridad: UUID validado con torc_is_uuid en AMBOS caminos (pick_live y --uuid) ANTES de
# cualquier uso; el comando enviado al pane es plantilla FIJA con piezas validadas (jamas
# interpolacion de input crudo). El bypass es autonomia operativa, NO autoridad de merge.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"; . "$HERE/lib.sh"; . "$HERE/lib-torre.sh"
# shellcheck source=/dev/null
. "$HERE/../../talent-channel-operation/scripts/lib-modelos.sh"
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  ACTOR="${1:?actor}"; shift
  CWD=""; UUID=""; WIN="$TORRE_LIVE_WINDOW"; LIST=0; DRY=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --cwd) CWD="${2:?--cwd <dir>}"; shift 2 ;;
      --uuid) UUID="${2:?--uuid <uuid>}"; shift 2 ;;
      --window-s) WIN="${2:?--window-s N}"; printf '%s' "$WIN" | grep -qE '^[0-9]+$' || torc_die "--window-s debe ser numerico"; shift 2 ;;
      --list) LIST=1; shift ;;
      --dry-run) DRY=1; shift ;;
      *) torc_die "flag desconocido: $1" ;;
    esac
  done
  S="$(torc_torre_session "$ACTOR")" || torc_die "actor invalido: '$ACTOR' (minusculas/digitos/guiones)"
  [ -n "$CWD" ] || torc_die "falta --cwd <dir> (las sesiones son dir-scoped: el pwd EXACTO del actor)"
  CWD="$(readlink -f "$CWD" 2>/dev/null)" || torc_die "--cwd no resoluble"
  [ -d "$CWD" ] || torc_die "--cwd no es un directorio: $CWD"

  # dir de transcripts: slug del proyecto claude ('/', '.' y '_' -> '-')
  slug="$(printf '%s' "$CWD" | sed -E 's/[\/._]/-/g')"
  tdir="$TORRE_CLAUDE_PROJECTS/$slug"
  [ -d "$tdir" ] || torc_die "sin transcripts para ese cwd: $tdir (¿cwd EXACTO del actor?)"

  candidates() { find "$tdir" -maxdepth 1 -name '*.jsonl' -printf '%T@\t%p\n' | sort -rn; }

  if [ "$LIST" = 1 ]; then
    torc_say "candidatos en $tdir (gotcha TZ: comparar contra date -u, no contra la hora local)"
    torc_info "ahora UTC: $(date -u '+%Y-%m-%d %H:%M:%S') (epoch $(date +%s))"
    now="$(date +%s)"
    candidates | while IFS=$'\t' read -r epoch path; do
      e="${epoch%%.*}"
      printf '   %s  mtime=%s  edad=%ss\n' "$(basename "${path%.jsonl}")" \
        "$(date -u -d "@$e" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$e")" "$(( now - e ))"
    done
    exit 0
  fi

  if [ -n "$UUID" ]; then
    torc_is_uuid "$UUID" || torc_die "--uuid invalido (no es un UUID): jamas llega input no validado al pane"
  else
    now="$(date +%s)"
    UUID="$(candidates | torc_torre_pick_live "$now" "$WIN")"; rc=$?
    case "$rc" in
      0) : ;;
      2) torc_err "NINGUN transcript vivo (mtime a <=${WIN}s de ahora) en $tdir — la sesion viva se escribe AHORA; candidatos:"
         bash "$0" "$ACTOR" --cwd "$CWD" --list; exit 2 ;;
      3) torc_err "AMBIGUO: >1 transcript vivo en la ventana de ${WIN}s — identifica el UUID correcto y pasa --uuid; candidatos:"
         bash "$0" "$ACTOR" --cwd "$CWD" --list; exit 3 ;;
      *) torc_die "pick_live fallo (rc $rc)" ;;
    esac
    torc_is_uuid "$UUID" || torc_die "UUID detectado invalido — no lanzo"
  fi

  # El rol explícito manda; todos los roles distintos de CEO usan Sonnet.
  case "${TCO_TORRE_ROL:-$ACTOR}" in ceo) ROL=ceo ;; *) ROL=coordinador ;; esac
  MODEL="$(tco_modelo_read "$ROL")" && [ -n "$MODEL" ] || exit 1
  BASE_CMD="IS_SANDBOX=1 CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1 CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 claude --dangerously-skip-permissions --resume $UUID"
  CMD="$BASE_CMD --model $MODEL"

  if [ "$DRY" = 1 ]; then
    torc_say "torre-resume DRY-RUN"
    torc_info "sesion tmux: $S (nueva, -c $CWD)"
    torc_info "comando (send-keys -l, sin shell del host): $CMD"
    torc_info "antes de lanzar (no en dry-run): install-statusline.sh -> .tui=default + barra ctx: en ~/.claude/settings.json"
    exit 0
  fi

  command -v tmux >/dev/null 2>&1 || torc_die "tmux no esta instalado en el host (apt install tmux — talent-channels gotcha 27)"
  torc_torre_has_session "$S" && torc_die "la sesion '$S' YA existe — attach (tmux attach -t $S) o eligela con otro nombre"
  # [TAL-8038] settings listos (tui + barra ctx:) ANTES de crear la sesion; rc 3 (statusLine ajena) solo sigue si ESA barra emite ctx:
  INST="$HERE/../../talent-context/scripts/install-statusline.sh"
  [ -r "$INST" ] || torc_die "falta $INST (skill talent-context): sin la barra ctx: la torre queda ciega a compact-60 — no lanzo"
  bash "$INST" >/dev/null; irc=$?
  case "$irc" in
    0) : ;;
    3) bash "$INST" --check-ctx >/dev/null || torc_die "statusLine ajena que NO emite 'ctx: NN%' — no lanzo (install-statusline.sh --force la reemplaza, o arregla tu barra)" ;;
    *) torc_die "install-statusline.sh fallo (rc $irc; 4 = claude menor que la minima) — no lanzo" ;;
  esac
  tmux new-session -d -s "$S" -c "$CWD" || torc_die "no pude crear la sesion tmux '$S'"
  sleep 1
  # Releer después de statusline y tmux: una retirada tardía impide el CLI.
  MODEL="$(tco_modelo_read "$ROL")" && [ -n "$MODEL" ] || exit 1
  CMD="$BASE_CMD --model $MODEL"
  torc_torre_send_literal "$S" "$CMD" || torc_die "no pude escribir el comando de arranque en '$S'"
  sleep 0.5
  torc_torre_submit "$S" || torc_die "no pude lanzar el comando en '$S'"

  torc_say "sesion $S lanzada (resume $UUID)"
  torc_info "CHECKLIST POST-RESUME (runbook torre-de-control, EN ORDEN, antes de cualquier relay):"
  torc_info " 1. Verificacion de identidad: '¿quien eres y ultimo encargo?' — contexto de OTRO actor => cerrar y re-resume con el UUID correcto"
  torc_info " 2. Purga del TaskList stale del harness (reconciliar contra Linear + la orden curada)"
  torc_info " 3. Rearmar wakeups/watchers (NO sobreviven al relanzamiento)"
  torc_info " 4. Alta en el mapa de la Torre + primer sweep: bash $HERE/torre-sweep.sh ${S#"$TORRE_SESSION_PREFIX"}"
fi
