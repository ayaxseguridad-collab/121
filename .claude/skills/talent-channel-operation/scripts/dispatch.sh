#!/usr/bin/env bash
# dispatch.sh — Lanza un carril de desarrollo para un issue: pane .0 = equipo de desarrollo
# (bypass desde el arranque + plan mode + effort xhigh + prompt), pane .1 = equipo de auditoría (rol).
# [v5] Además: gate de MODELO (Regla 0 ampliada — la cuenta puede agotar un modelo y el panel queda
# inservible), bootstrap de githooks en el clon del carril, y modo --soft (follow-up trivial que
# conserva la sesión del agente con su modelo bueno: /clear + reset del repo, sin relanzar CLIs).
# [TAL-2276] --force-reset además resetea el git del carril a origin/main PRE-preflight (tras el gate
# BD-sync en verde), para no exigir el reset manual cuando el carril arrastra WIP/rama del issue previo.
# Uso: dispatch.sh [--dry-run] [--force-reset] [--soft] [--no-linear] <carril> <TAL-id>
#      --no-linear: SOLO smoke tests (exige TCO_SMOKE_MODE=yes; guard M1) — no mueve la issue en Linear.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

# El manifiesto es dato, nunca código shell. Cada gate declarado exige un comando
# literal entre comillas; un manifiesto incompleto impide incluso renderizar el brief.
tco_dispatch_gate_lines() { # manifiesto
  local manifest="$1" ids id key cmd seen=' '
  case "$manifest" in /*) ;; *) return 1 ;; esac
  [ -r "$manifest" ] || return 1
  ids="$(sed -n 's/^TF_GATE_IDS="\([^"]*\)"[[:space:]]*$/\1/p' "$manifest" | tail -1)"
  [ -n "${ids//[[:space:]]/}" ] || return 1
  for id in $ids; do
    printf '%s' "$id" | grep -qE '^[A-Za-z][A-Za-z0-9_-]*$' || return 1
    key="${id//-/_}"
    case "$seen" in *" $key "*) return 1 ;; esac
    seen="$seen$key "
    cmd="$(sed -n "s/^TF_GATE_CMD_$key=\"\([^\"]*\)\"[[:space:]]*$/\\1/p" "$manifest" | tail -1)"
    [ -n "${cmd//[[:space:]]/}" ] || return 1
    printf '        %s: %s -> <exit code real>\n' "$id" "$cmd"
  done
}

tco_dispatch_instance_blocks() { # plantilla
  local gates line header
  gates="$(tco_dispatch_gate_lines "${TCO_TF_MANIFEST:-}")" || return 1
  header="$(tco_stop_audit_header '__ISSUE__')"
  case "${TCO_REPO_STACK:-}" in supabase|convex|ninguno) ;; *) return 1 ;; esac
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      __GATES__) printf '%s\n' "$gates" ;;
      __MIGRATION_REPORT__)
        [ "$TCO_REPO_STACK" != supabase ] || printf '%s\n' '    · migration_slots: <archivos de migración con slot standby, o "n/a">' ;;
      __MIGRATIONS__)
        [ "$TCO_REPO_STACK" != supabase ] || printf '%s\n' '- MIGRACIONES: si tocas `supabase/migrations/`, usa el slot standby `29990101000000`. Decláralas en `migration_slots` del HANDOFF y no las apliques a producción: la estación de merge renumera y aplica.' ;;
      *) printf '%s\n' "${line//__STOP_AUDIT_HEADER__/$header}" ;;
    esac
  done < "$1"
  return 0
}
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  DRY=no; FORCE=no; SOFT=no; NOLINEAR=no
  while :; do case "${1:-}" in
    --dry-run) DRY=yes; shift;;
    --force-reset) FORCE=yes; shift;;
    --soft) SOFT=yes; shift;;
    --no-linear)
      # [v5/B3+M1] flag RESERVADO a smoke: sin TCO_SMOKE_MODE=yes el dispatch MUERE — jamás
      # saltarse la trazabilidad Linear (regla 27) en trabajo real.
      [ "${TCO_SMOKE_MODE:-}" = yes ] || tco_die "--no-linear es SOLO para smoke tests: requiere TCO_SMOKE_MODE=yes en el entorno (guard M1)"
      NOLINEAR=yes; shift;;
    *) break;;
  esac; done
  CARRIL="${1:?carril}"; ISSUE="${2:?TAL-id}"
  # [CR] topologia: dispatch SOLO en carriles de desarrollo (05/06 son audit-only)
  case " $TCO_DEV_CARRILES " in
    *" $CARRIL "*) ;;
    *) tco_die "carril invalido para desarrollo: $CARRIL (permitidos: $TCO_DEV_CARRILES)";;
  esac
  c="$(tco_container "$CARRIL")"; rp="$(tco_repo_path)"; A="$HERE/../assets"; tmp="$(mktemp -d)"
  # [CR] lock por carril: dos dispatch concurrentes ya no pueden pasar ambos el preflight/libre
  # y reciclar la misma sesion (mismo patron que audit-carril). El trap tambien limpia el tmp.
  tco_lock_acquire "dispatch-$CARRIL" || tco_die "dispatch ya en curso para $CARRIL (lock)"
  trap 'tco_lock_release "dispatch-$CARRIL"; rm -rf "$tmp"' EXIT

  # render del prompt de dispatch
  # [CR] escapar los valores antes del sed: un '&', '|' o '\' en ISSUE/TCO_REPO_DIR corrompería
  # el render (o lo rompería) antes de arrancar el carril. Delimitador '|' + reemplazo escapado.
  # [v5] __POSTMERGE__ se rellena desde TCO_POSTMERGE_CMD (config por repo — anexo): el tmpl es
  # repo-agnóstico y el paso post-merge canónico lo decide 00-config.sh, no el texto.
  # [TAL-3619/re-despacho, finding 5] __STOP_AUDIT_FILE__ se rellena desde TCO_STOP_AUDIT_FILE
  # (00-config.sh) — antes el nombre del fichero estaba HARDCODEADO en el tmpl (coincidía con el
  # default por suerte, no por construcción: un override de TCO_STOP_AUDIT_FILE nunca habría
  # llegado al brief real del dev).
  escape_sed_replacement() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }
  issue_esc="$(escape_sed_replacement "$ISSUE")"
  repo_dir_esc="$(escape_sed_replacement "$TCO_REPO_DIR")"
  postmerge_esc="$(escape_sed_replacement "${TCO_POSTMERGE_CMD:-}")"
  stop_audit_esc="$(escape_sed_replacement "${TCO_STOP_AUDIT_FILE:-stop-audit-report.txt}")"
  tco_dispatch_instance_blocks "$A/prompt-dispatch.tmpl" > "$tmp/instance-prompt.txt" \
    || tco_die "manifiesto de gates o stack inválido — no puedo componer el brief de la instancia"
  sed -e "s|__ISSUE__|$issue_esc|g" -e "s|__REPO_DIR__|$repo_dir_esc|g" -e "s|__POSTMERGE__|$postmerge_esc|g" \
      -e "s|__STOP_AUDIT_FILE__|$stop_audit_esc|g" \
    "$tmp/instance-prompt.txt" > "$tmp/dev-prompt.txt"

  if [ "$DRY" = yes ]; then
    tco_say "DRY-RUN dispatch $ISSUE -> $CARRIL ($c) — no se toca ningún carril"
    tco_info "dev:       ${TCO_DEV_CLI:-<define en agents.conf>} ${TCO_DEV_FLAGS:-} ${TCO_DEV_MODEL_ARGS:-}"
    tco_info "auditoría: ${TCO_AUDIT_CLI:-<define en agents.conf>} ${TCO_AUDIT_FLAGS:-} ${TCO_AUDIT_MODEL_ARGS:-}"
    tco_info "preflight de identidad: dev=$(tco_cli_exe "${TCO_DEV_CLI:-}" 2>/dev/null || echo '?') auditor=$(tco_cli_exe "${TCO_AUDIT_CLI:-}" 2>/dev/null || echo '?') topología=${TCO_AUDIT_TOPOLOGY:-distinto} (se verifica por proceso real en el despacho)"
    # [BOUNCE-r2, NO-GO code r1] El dry-run informaba TCO_DEV_MODEL (modelo de CODING) crudo,
    # contradiciendo el camino real: dispatch.sh opera la fase PLAN y fuerza/verifica
    # tco_model_for_phase(plan) (Regla 0 -> Opus vigente), no TCO_DEV_MODEL directo. El info line
    # debe reportar lo mismo que el camino real, o el smoke queda mintiendo sobre qué modelo se
    # fuerza de verdad.
    if [ -n "${TCO_DEV_MODEL:-}" ]; then
      _DRY_DEV_MODEL="$(tco_model_for_phase plan)" || _DRY_DEV_MODEL="<error resolviendo fase plan>"
    else
      _DRY_DEV_MODEL="<sin gate de modelo>"
    fi
    tco_info "modelo dev garantizado (fase plan): $_DRY_DEV_MODEL"
    tco_info "post-merge (__POSTMERGE__): ${TCO_POSTMERGE_CMD:-<vacío>}"
    # [TAL-2276] transparencia: el DRY-RUN nunca resetea; se informa qué haría un --force-reset real.
    if tco_should_force_reset "$FORCE" "$SOFT" no; then
      tco_info "git pre-preflight reset (--force-reset): SÍ se resetearía $CARRIL a origin/main (dry-run NO lo ejecuta)"
    else
      tco_info "git pre-preflight reset: no aplica (sin --force-reset, o modo --soft)"
    fi
    tco_info "rol auditoría: $A/role-auditoria.txt"
    tco_say "prompt de dispatch (render)"; sed 's/^/  /' "$tmp/dev-prompt.txt"
    exit 0
  fi
  tco_require_agents
  tco_wait_config "${TCO_EFFORT_DEFER_WAIT:-20}" 1 || tco_die 'intervalo de verificación diferida inválido'
  # [TAL-1623] tokens en el proceso de dispatch: el preflight (hijo) los cargaba solo para si
  # mismo y el paso In Progress de este proceso moria con LINEAR_API_KEY vacia (fail-closed).
  tco_load_tokens || tco_die "no pude cargar los tokens del host — no se despacha."
  # [CR] El gate pre-issue [B4] es OBLIGATORIO y dispatch lo hace cumplir en código (no solo en
  # doctrina): si alguien omite el paso manual, el carril no arranca sobre estado sin verificar.
  # [TAL-2275] se pasa $ISSUE (posicional): el preflight verifica ademas el ESTADO Linear del issue
  # (gate 3, gotcha TAL-1178). En smoke (--no-linear ⇒ TCO_SMOKE_MODE=yes) el propio preflight salta ese gate.
  # [TAL-2276] --force-reset limpia el git del carril a origin/main. Lo señalamos a preflight con un
  # flag explícito (no muta desde aquí): preflight lo hace ENTRE su gate BD-sync y su gate git, solo si
  # BD-sync quedó en verde (orden fail-closed). El predicado excluye --soft (respeta tco_wait_idle del
  # recycle suave) y --dry-run. `if` explícito para no disparar `set -e` con el predicado en falso.
  pf_args=("$CARRIL")
  [ -n "$ISSUE" ] && pf_args+=("$ISSUE")
  if tco_should_force_reset "$FORCE" "$SOFT" "$DRY"; then pf_args+=("--force-reset-git"); fi
  bash "$HERE/preflight-issue.sh" "${pf_args[@]}" || tco_die "preflight-issue FALLÓ para $CARRIL — no se despacha (gate B4)."
  # [TAL-1615] In Progress EN CODIGO al despachar (regla 27: sin issue In Progress no se toca
  # codigo). Fail-closed ANTES de reciclar el carril: si Linear no confirma, no se despacha.
  if [ "$NOLINEAR" = yes ]; then
    tco_info "SMOKE (--no-linear): salto el paso In Progress de Linear para $ISSUE"
  else
    tco_linear_set_state "$ISSUE" "$TCO_LINEAR_INPROGRESS_STATE" \
      || tco_die "$ISSUE: no pude ponerlo In Progress en Linear — no se despacha (reintenta o revisa LINEAR_API_KEY)."
    tco_info "$ISSUE en In Progress (Linear, verificado)"
  fi

  if [ "$SOFT" = yes ]; then
    # ------------------------------------------------------------------
    # [v5/E25] DISPATCH SUAVE: follow-up trivial en el mismo carril SIN relanzar CLIs (un relaunch
    # caería al modelo default de la cuenta, quizá agotado). Requiere sesión viva con ambos panes.
    # ------------------------------------------------------------------
    tco_say "dispatch SUAVE $ISSUE -> $CARRIL ($c) — conserva sesión y modelo"
    # --soft actúa sobre una sesión que YA EXISTÍA (R9011j7 J7-01): lee AQUÍ, una vez y ANTES de cualquier tecla (también antes
    # del «/clear» del reciclaje), el id estable (`%N`) de los dos panes, con tco_panes_fijar_sesion: con más de una ventana en
    # la sesión del canal (el paquete nunca abre otra) o sin los dos panes en la única, rc 1 sin teclear nada. Desde aquí, el
    # reciclaje y TODO lo que se comprueba, calibra, teclea o captura van por ese `%N` (`$P_DEV`, `$P_AUD`), nunca por un
    # destino relativo.
    tco_panes_fijar_sesion "$CARRIL" \
      || tco_die "$CARRIL: dispatch --soft requiere la sesión viva del canal con UNA sola ventana y sus dos panes (el error de arriba dice qué se encontró y el remedio) — no se ha tecleado nada"
    P_DEV="$(tco_pane_destino "$(tco_pane_dev)")"; P_AUD="$(tco_pane_destino "$(tco_pane_audit)")"
    # El reciclaje suave teclea («/clear» + Enter): comprueba la calibración del CLI de ambos panes ÉL MISMO antes de enviar
    # nada (lib.sh); el preflight de más abajo repite la comprobación tras la identidad, común a normal y --soft.
    tco_recycle_carril "$CARRIL" --soft "$P_DEV" "$P_AUD" || tco_die "$CARRIL: recycle suave FALLÓ — usa dispatch normal"
  else
    # No clobbear trabajo en curso: solo se mata la sesión si el carril está libre o se pasa --force-reset.
    if [ "$FORCE" != yes ] && ! tco_carril_libre "$CARRIL"; then
      tco_die "carril $CARRIL OCUPADO (sesión activa con trabajo). Usa --force-reset para sobrescribir (pierde lo que haya en ambos panes)."
    fi
    tco_say "dispatch $ISSUE -> $CARRIL ($c)"
    # [Pilar 7 / Cond. 5] RECICLAJE LIMPIO antes de relanzar: mata sesión + procesos de agente + relay
    # del issue anterior (acotado al contenedor del carril). No arrastra contexto/identidad ni zombis.
    # [TAL-3619/re-despacho, sweep set-e] bare antes: un rc≠0 (p. ej. contenedor inalcanzable) moría
    # bajo set -e sin mensaje, en vez del fail-closed explícito que ya usa el camino --soft (línea 106).
    tco_recycle_carril "$CARRIL" || tco_die "$CARRIL: reciclaje (hard) FALLÓ — ESCALAR (revisa conectividad/estado del contenedor)"
    sleep 1
  fi
  # [reset freshness — regla lead] El reciclaje dejó el repo del carril en origin/main (fetch+reset --hard);
  # VERIFICAR fail-closed: el carril NUNCA debe arrancar sobre un main viejo del golden (incidente: arrancó
  # 39 commits stale). El gate git (working tree limpio + al día) lo gatea preflight-issue.sh [B4] antes del dispatch.
  # [CR] fetch fresco INLINE antes de leer las refs (fail-closed y atómico): si `git fetch` falla, el `&&`
  # corta y `cur` queda VACÍO → tco_die. Así la comparación NUNCA usa un origin/main viejo del golden.
  cur="$(incus exec "$c" -- su - "$TCO_CUSER" -c "cd '$rp' && git fetch origin --quiet && git rev-parse HEAD 2>/dev/null" 2>/dev/null || echo '')"
  ori="$(incus exec "$c" -- su - "$TCO_CUSER" -c "cd '$rp' && git rev-parse origin/main 2>/dev/null" 2>/dev/null || echo '')"
  [ -n "$cur" ] && [ -n "$ori" ] && [ "$cur" = "$ori" ] || tco_die "$CARRIL: el repo NO quedó en origin/main tras el reciclaje (o el fetch falló) (HEAD=${cur:-?} vs origin/main=${ori:-?}) — ESCALAR (no arranco sobre un main viejo del golden)"
  # [v5/C19] Bootstrap de githooks en el clon del carril (defensa en profundidad): sin él, el
  # pre-push del repo no corre en el carril. Warn-no-die deliberado: el enforcement REAL es el
  # merge-gate M8 + la CR App sobre el PR (trazado abajo si falla).
  if [ "${TCO_BOOTSTRAP_GITHOOKS:-yes}" = yes ]; then
    if incus exec "$c" -- su - "$TCO_CUSER" -c "cd '$rp' && bash scripts/setup-githooks.sh" >/dev/null 2>&1 \
       && [ "$(incus exec "$c" -- su - "$TCO_CUSER" -c "cd '$rp' && git config core.hooksPath" 2>/dev/null)" = .githooks ]; then
      tco_info "$CARRIL: githooks activados en el clon (core.hooksPath=.githooks)"
    elif tco_githooks_ensure "$CARRIL"; then
      # [TAL-8040] hooksPath divergente (p. ej. `githooks` sin punto) CORREGIDO y registrado ([HOOKSPATH] previo -> nuevo)
      tco_info "$CARRIL: githooks activados en el clon (core.hooksPath=.githooks)"
    else
      tco_err "$CARRIL: setup-githooks NO quedó activo — TRAZA: backstop = merge-gate M8 + CR App sobre el PR"
    fi
  fi

  # ── Productor del manifiesto de fábrica: el canal DEBE portar .claude/tf-manifest.conf ANTES
  # del primer trabajo — verify-handoff (canónico) es fail-closed sin manifiesto resoluble (el
  # respaldo embebido ya no existe). Fuente: TCO_TF_MANIFEST (config de la fábrica: ruta absoluta
  # a su manifiesto, mismo contrato TF_SENSITIVE_SURFACES que valida verify-handoff). Idempotente:
  # re-despacho = refresh de la copia con el manifiesto vigente (nunca stale del golden).
  [ -n "${TCO_TF_MANIFEST:-}" ] || tco_die "$CARRIL: TCO_TF_MANIFEST sin definir — el despacho no puede provisionar el manifiesto del canal (fail-closed). Define en la config de la fábrica (repo-identity.conf o agents.conf) la ruta absoluta a su manifiesto."
  case "$TCO_TF_MANIFEST" in /*) : ;; *) tco_die "$CARRIL: TCO_TF_MANIFEST='$TCO_TF_MANIFEST' no es ruta absoluta (fail-closed)";; esac
  [ -f "$TCO_TF_MANIFEST" ] || tco_die "$CARRIL: TCO_TF_MANIFEST='$TCO_TF_MANIFEST' no existe (fail-closed)"
  # Misma extracción canónica que verify-handoff (sed a la ÚLTIMA ocurrencia + tokens no vacíos):
  # un grep parcial podría divergir del parser real (línea duplicada, comillas, solo-espacios).
  _tf_surfaces="$(sed -n 's/^TF_SENSITIVE_SURFACES="\([^"]*\)".*$/\1/p' "$TCO_TF_MANIFEST" | tail -1)"
  _tf_tokens=0
  for _t in $_tf_surfaces; do _tf_tokens=$((_tf_tokens+1)); done
  [ "$_tf_tokens" -gt 0 ] \
    || tco_die "$CARRIL: '$TCO_TF_MANIFEST' sin TF_SENSITIVE_SURFACES con tokens (extracción canónica de verify-handoff) — fail-closed"
  incus exec "$c" -- su - "$TCO_CUSER" -c "mkdir -p '$rp/.claude'" \
    || tco_die "$CARRIL: no pude asegurar $rp/.claude en el canal"
  incus file push "$TCO_TF_MANIFEST" "$c$rp/.claude/tf-manifest.conf" --uid "$TCO_CUSER_UID" --gid "$TCO_CUSER_UID" --mode 0600 \
    || tco_die "$CARRIL: incus file push del manifiesto al canal falló"
  tco_info "$CARRIL: manifiesto de fábrica provisionado ($rp/.claude/tf-manifest.conf ← $TCO_TF_MANIFEST)"
  # [TAL-8040] higiene git: la copia NO es estado versionable → excluirla del clon (idempotente) y verificar
  # FAIL-CLOSED (existe · sha256 == fuente · check-ignore · status limpio) ANTES de crear la sesión; vale también en --soft.
  tco_tfm_exclude_ensure "$CARRIL" \
    || tco_die "$CARRIL: no pude añadir .claude/tf-manifest.conf a .git/info/exclude del clon (fail-closed)"
  tco_tfm_post_dispatch_check "$CARRIL" "$TCO_TF_MANIFEST" \
    || tco_die "$CARRIL: POST_DISPATCH_CHECK del manifiesto FALLÓ (punto indicado en [TFM-HYGIENE] arriba) — no se despacha (fail-closed)"
  tco_info "[TFM-HYGIENE] $CARRIL: manifiesto presente, idéntico a la fuente, ignorado por git y con árbol limpio"

  if [ "$SOFT" != yes ]; then
    # [B2] sesión limpia con creación VERIFICADA: el recycle ya esperó la muerte de la sesión; aun así,
    # crear new-session y CONFIRMAR que existe, reintentando ante 'duplicate session' (carrera residual).
    SESS_OK=no
    for _st in 1 2 3; do
      # [CR] NO aceptar una sesión PREEXISTENTE como creación válida: matar la vieja, ESPERAR a que muera, y si
      # sigue viva → OLD-ALIVE (no crear encima); si no, crear y capturar el rc del new-session (NEW-OK/NEW-FAIL).
      sess_res="$(incus exec "$c" -- su - "$TCO_CUSER" -c "
        tmux kill-session -t '$TCO_TMUX' 2>/dev/null || true
        for _k in 1 2 3 4 5 6 7 8 9 10; do tmux has-session -t '$TCO_TMUX' 2>/dev/null || break; sleep 0.3; done
        if tmux has-session -t '$TCO_TMUX' 2>/dev/null; then echo OLD-ALIVE; exit 0; fi
        tmux new-session -d -s '$TCO_TMUX' -x 220 -y 50 -c '$rp' && echo NEW-OK || echo NEW-FAIL" 2>/dev/null || echo EXEC-FAIL)"
      if [ "$sess_res" = NEW-OK ] && incus exec "$c" -- su - "$TCO_CUSER" -c "tmux has-session -t '$TCO_TMUX' 2>/dev/null"; then SESS_OK=yes; break; fi
      tco_err "$CARRIL: sesión tmux no creada limpia (estado=$sess_res, intento $_st)"; sleep 1
    done
    [ "$SESS_OK" = yes ] || tco_die "no pude crear una sesión tmux NUEVA '$TCO_TMUX' en $CARRIL (sesión vieja no murió o new-session falló) — ESCALAR"
    # pane .0 dev (bypass) · pane .1 auditoría (rol). El pane .1 se crea AQUÍ, antes de la sonda (antes nacía en la misma
    # orden que lanzaba): la sonda corre en CADA pane de destino.
    incus exec "$c" -- su - "$TCO_CUSER" -c "tmux split-window -h -t '$TCO_TMUX' -c '$rp'" \
      || tco_die "$CARRIL: no pude crear el pane de auditoría en la sesión '$TCO_TMUX'"
    # Destino ESTABLE de cada pane (`%N`), leído UNA vez aquí, recién creados: la sonda, el lanzamiento, remain-on-exit, la
    # vida, la identidad y TODO lo que se calibra, teclea o captura después usan ese id (`$P_DEV`, `$P_AUD`), nunca
    # `sesión:.N` (relativo a la ventana actual, que un hook o un cliente pueden cambiar; R9011j6 N-04).
    tco_pane_id_fijar "$CARRIL" "$(tco_pane_dev)" && tco_pane_id_fijar "$CARRIL" "$(tco_pane_audit)" \
      || tco_die "$CARRIL: no pude leer el id estable de los panes de la sesión '$TCO_TMUX' — no se despacha"
    P_DEV="$(tco_pane_destino "$(tco_pane_dev)")"; P_AUD="$(tco_pane_destino "$(tco_pane_audit)")"
    # remain-on-exit mientras se comprueba y se lanza: la sonda deja su pane muerto (no retirado), y un agente que muera nada
    # más arrancar (rc 127…) deja su pane muerto, con su rc, en lugar de desaparecer y arrastrar al otro pane a «can't find
    # pane: 1». tco_remain_preparar guarda el valor previo de la ventana y lo fija; tco_panes_vivos lo restaura exactamente.
    tco_remain_preparar "$CARRIL" "$P_DEV" || tco_die "$CARRIL: no pude preparar remain-on-exit antes de lanzar — no se despacha"
    # COMPROBACIÓN PREVIA fail-closed: `tmux respawn-pane` ejecuta con `bash -c`, sin .bashrc, así que un lanzador que solo
    # exista como alias (claude-root) muere con rc 127, el pane .0 desaparece y el despacho acaba en «can't find pane: 1».
    # La sonda es un respawn-pane en CADA pane de destino con el -c del clon (su shell, su entorno y su PATH, los del
    # lanzamiento) y acredita la ruta canónica del lanzador; el lanzamiento de abajo ejecuta ESA ruta, sin volver al PATH.
    tco_launchers_ready "$CARRIL" "$rp" TCO_DEV_CLI "$P_DEV" "$TCO_DEV_CLI" TCO_AUDIT_CLI "$P_AUD" "$TCO_AUDIT_CLI" \
      || tco_die "$CARRIL: lanzador de agente sin ejecutable en el canal — no se despacha (fail-closed; el error de arriba nombra el CLI y el remedio)"
    # [v5/A4] lanzamiento con MODEL_ARGS explícitos: el lanzador del contenedor (claude-root) NO pasa
    # --model y cae al default de la cuenta. El registro comprobado fija el ID completo.
    tco_modelos_config || tco_die "$CARRIL: registro de modelos inválido antes del lanzamiento"
    LANZ_DEV="$(tco_orden_acreditada TCO_DEV_CLI "$P_DEV" "$TCO_DEV_FLAGS ${TCO_DEV_MODEL_ARGS:-}")" \
      && LANZ_AUD="$(tco_orden_acreditada TCO_AUDIT_CLI "$P_AUD" "$TCO_AUDIT_FLAGS ${TCO_AUDIT_MODEL_ARGS:-}")" \
      || tco_die "$CARRIL: sin ruta acreditada del lanzador — no se despacha"
    incus exec "$c" -- su - "$TCO_CUSER" -c "
      tmux respawn-pane -k -t '$P_DEV' -c '$rp' '$LANZ_DEV'
      tmux respawn-pane -k -t '$P_AUD' -c '$rp' '$LANZ_AUD'" \
      || tco_die "$CARRIL: no pude iniciar los procesos de agente"
    tco_panes_vivos "$CARRIL" TCO_DEV_CLI "$P_DEV" "$TCO_DEV_CLI" TCO_AUDIT_CLI "$P_AUD" "$TCO_AUDIT_CLI" \
      || tco_die "$CARRIL: un pane de agente murió o no existe tras lanzarlo, o no se pudo restaurar remain-on-exit (el error de arriba nombra el CLI, el pane y el rc) — no se despacha"
    sleep 9
    # [v5/A4] TUI del dev LISTO + detección de RESUME: el lanzador puede RESUMIR y auto-compactar la
    # sesión previa en vez de arrancar fresco (scrollback retiene contenido viejo y el resume BAJA el
    # effort). Si la captura no muestra el placeholder de sesión fresca (TCO_FRESH_REGEX), trazar —
    # el remedio es exactamente lo que sigue: re-fijar MODELO y EFFORT (no depender del estado heredado).
    tco_wait_tui_ready "$CARRIL" "$P_DEV" 90 "${TCO_TUI_READY_REGEX:-}" \
      || tco_err "$CARRIL: el TUI del dev no confirmó estado LISTO en 90s — continúo con verificación de modelo/effort (fail-closed más abajo)"
    if [ -n "${TCO_FRESH_REGEX:-}" ]; then
      if ! tco_cap_pane "$CARRIL" "$P_DEV" 2>/dev/null | grep -qiE "$TCO_FRESH_REGEX"; then
        tco_err "$CARRIL: el pane dev parece RESUMED/auto-compact (sin placeholder de sesión fresca) — re-fijo modelo y effort a continuación (traza A4)"
      fi
    fi
  fi
  # --soft no vuelve a leer el `%N` aquí: lo leyó UNA vez antes del reciclaje (R9011j7 J7-01). Una relectura por destino
  # relativo después del «/clear» tomaría la ventana activa de ESE momento. Fin de la lectura de los panes (normal y --soft).

  # [TAL-8042] PREFLIGHT DE IDENTIDAD (normal y --soft): el pane .0 ejecuta el binario de TCO_DEV_CLI y el .1
  # el de TCO_AUDIT_CLI, por PROCESO REAL (no por config ni por lo que responda el TUI) — y con la topología
  # `distinto` el auditor NO es el agente del dev. Desviación → MUERE aquí, ANTES del modelo/rol/brief
  # (fail-closed: un auditor del mismo proveedor no es independiente; FAB-OBS-001). Imprime el auditor real.
  tco_pane_identity_preflight "$CARRIL" \
    || tco_die "$CARRIL: identidad de los panes NO confirmada (binario del pane ≠ TCO_DEV_CLI/TCO_AUDIT_CLI, o auditor = dev con topología 'distinto') — ESCALAR (no se entrega modelo, rol ni brief)"

  # CALIBRACIÓN DEL CLI (normal y --soft): cada pane debe ejecutar un par cli:versión con capturas reales calibradas en esta
  # identidad. Un CLI sin calibrar cambia el TUI (la lista de órdenes de «/model») y el despacho acababa en ch06 con el pane
  # a medio teclear: falla aquí, antes de teclear nada, con el CLI, la versión y el remedio.
  tco_pane_calibration_preflight "$CARRIL" \
    || tco_die "$CARRIL: CLI de un pane SIN calibrar (el error de arriba nombra el CLI, la versión y el remedio) — ESCALAR; no se teclea nada"

  # [v5/A4] GATE DE MODELO (ambos modos): verificar/forzar el modelo capaz ANTES del effort y del
  # brief. Fail-closed: si el modelo configurado no se confirma, NO se despacha sobre un panel
  # posiblemente agotado/degradado — se escala al lead.
  # [BOUNCE-r2/#8] DEV_MODEL = modelo de la FASE que dispatch.sh opera (plan, Regla 0), NO
  # TCO_DEV_MODEL directo (ese es el modelo de CODING) — un solo punto de resolución, reusado
  # también en el bloque de verificación de abajo. El gate de opt-out sigue en TCO_DEV_MODEL
  # (vaciarlo en agents.conf desactiva TODO el gate de modelo, plan incluido).
  if [ -n "${TCO_DEV_MODEL:-}" ]; then
    DEV_MODEL="$(tco_model_for_phase plan)" || tco_die "$CARRIL: no pude resolver el modelo de la fase plan (tco_model_for_phase) — ESCALAR"
    if tco_ensure_model "$CARRIL" "$P_DEV" "$DEV_MODEL"; then
      tco_info "$CARRIL: modelo '$DEV_MODEL' (fase plan) garantizado en el pane dev"
    else
      tco_die "$CARRIL: modelo '$DEV_MODEL' (fase plan) SIN confirmar (¿cuenta agotada?) — ESCALAR; no despacho sobre modelo degradado"
    fi
  fi
  tco_ensure_audit_model "$CARRIL" \
    || tco_die "$CARRIL: modelo del auditor Claude SIN confirmar — no se despacha"
  # Secuencia: BYPASS al arrancar -> /effort xhigh (plan) -> PLAN MODE con shift+tab -> prompt.
  # [Regla 0] El COORDINADOR fija el /effort en cada transición (los agentes NO lo cambian solos):
  # plan=xhigh (aquí); coding=high (el coordinador, tras el GO de plan y ANTES de aprobar);
  # re-plan=xhigh (el coordinador, tras NO-GO). /effort max PROHIBIDO.
  # El plan mode monta SOBRE la sesión bypass => el dev planifica SIN prompts de aprobación.
  # [v5] tri-estado (fix del falso negativo 3/3 bajo carga): rc1 = envío falló (fatal aquí);
  # rc2 = enviado sin confirmación visual → verificación DIFERIDA tras entregar el brief.
  EFFORT_DEFERRED=no
  ef_rc=0; tco_set_effort "$CARRIL" "$P_DEV" xhigh || ef_rc=$?
  case "$ef_rc" in
    0) ;;
    2) EFFORT_DEFERRED=yes; tco_err "$CARRIL: effort xhigh sin confirmación visual — verificación diferida tras el brief (rc 2)";;
    *) tco_die "$CARRIL: no pude ENVIAR /effort xhigh al pane dev — Regla 0 sin garantizar";;
  esac
  sleep 2   # maneja el diálogo "Switching…1.Yes/2.No"
  # [M3] EFFORT del AUDITOR (pane .1): fijarlo explícitamente (no depender de la config persistida previa
  # del contenedor del agente). Configurable y agente-agnóstico (TCO_AUDIT_EFFORT_CMD en agents.conf); vacío = no-op.
  if [ "$SOFT" != yes ] && [ -n "${TCO_AUDIT_EFFORT_CMD:-}" ]; then
    _tco_send_text_submit "$CARRIL" "$P_AUD" "$TCO_AUDIT_EFFORT_CMD" C-m yes \
      || tco_die "$CARRIL: TCO_AUDIT_EFFORT_CMD configurado pero FALLÓ al enviar al pane de auditoría — effort del auditor sin garantizar"
    sleep 2
  fi
  # shift+tab hasta confirmar 'plan mode on' (cicla si el primer toggle cae en otro modo)
  PLAN_OK=no
  for _ in 1 2 3 4 5 6; do
    incus exec "$c" -- su - "$TCO_CUSER" -c "tmux send-keys -t '$P_DEV' BTab"; sleep 1
    if incus exec "$c" -- su - "$TCO_CUSER" -c "tmux capture-pane -t '$P_DEV' -p -J" | grep -qi 'plan mode on'; then PLAN_OK=yes; break; fi
  done
  # [Mayor 1] GATE de arranque (no solo log): sin 'plan mode on' confirmado, el dev podría empezar a
  # implementar sin plan → ABORTAR (fail-closed) para que el coordinador ESCALE de inmediato, no más tarde.
  if [ "$PLAN_OK" != yes ]; then
    tco_die "no pude confirmar 'plan mode on' tras 6 shift+tab en $CARRIL — ESCALAR (no se entrega el brief)"
  fi
  # ya en plan mode -> el brief de tarea al dev por la vía FIABLE (archivo + 'lee', entrega verificada).
  # Es el brief del orquestador (confiable), no contenido relevado: mensaje neutro.
  # [bug2/B1] Entrega VERIFICADA por contenido (tco_relay_file confirma por el ECO del relay, no por
  # pane-busy de arranque). Si no se confirma → FALLAR: el carril NUNCA debe avanzar sin el brief del issue
  # (el escalado deja el carril vivo para re-entrega, NO lo orfana).
  # [TAL-3619] uuid_out: fichero CREADO/TRUNCADO aquí (secuencia normativa de Fix 4/dispatch.sh) —
  # tco_relay_file escribe el uuid de la submisión SOLO con entrega confirmada.
  MODEL_UUID_OUT="$tmp/model-verify.uuid"
  : > "$MODEL_UUID_OUT"
  if ! tco_relay_file "$CARRIL" "$P_DEV" "$tmp/dev-prompt.txt" "dispatch" \
        "— es tu brief de tarea; síguelo y presenta el plan con ExitPlanMode" 30 "$MODEL_UUID_OUT"; then
    tco_die "no pude entregar/confirmar el brief al dev en $CARRIL (sin eco del relay) — ESCALAR (no avanzo sin brief)"
  fi
  # [TAL-3619/Fix1, endurecido por auditoría] AUTORIDAD en disco de que el modelo garantizado
  # arriba (picker) sirvió REALMENTE este brief: valida el uuid de la entrega (forma UUID, NUNCA
  # vacío/inventado) y espera al assistant DESCENDIENTE de ESE submit — nunca "el último
  # assistant" (r7-B3: podía ser el turno anterior al switch). FAIL-CLOSED: un uuid vacío o
  # malformado NO degrada a "me conformo con el picker" — el picker prueba el estado en el
  # INSTANTE del switch, no que ESE modelo sirvió el brief que se acaba de relevar; degradar
  # aquí incumplía el propio contrato de esta capa (causalidad del modelo servido). El dev pane
  # de este repo SIEMPRE corre un CLI con superficie de sesión en disco (Claude): un uuid
  # ausente/malformado en producción es señal de fallo real, no de "CLI no calibrado" legítimo.
  if [ -n "${TCO_DEV_MODEL:-}" ]; then
    # [BOUNCE-r2/#8] Reusa el MISMO DEV_MODEL (fase plan) computado en el gate de arriba — nunca
    # TCO_DEV_MODEL (coding) directo.
    MODEL_UUID="$(cat "$MODEL_UUID_OUT" 2>/dev/null)"
    if ! printf '%s' "$MODEL_UUID" | grep -qE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
      # [BOUNCE-r2/#7] Gap de contrato: sin esto el dev pane YA con el brief seguía en modelo SIN
      # verificar hasta el relevo humano. tco_abort_dev_dispatch interrumpe y CONFIRMA por
      # autoridad primaria (tco_pane_busy) antes de escalar — nunca éxito silencioso, nunca deja
      # el dev ejecutando sobre un modelo no probado.
      tco_abort_dev_dispatch "$CARRIL" "$P_DEV" "uuid de entrega inválido tras el brief" || true
      tco_die "$CARRIL: sin uuid de entrega VÁLIDO tras relevar el brief — no puedo probar causalmente que '$DEV_MODEL' sirvió ese turno — ESCALAR (Regla 0 sin garantizar; el picker por sí solo no basta)"
    fi
    if tco_verify_model_effect "$CARRIL" "$P_DEV" "$DEV_MODEL" "$MODEL_UUID"; then
      tco_info "$CARRIL: modelo '$DEV_MODEL' (fase plan) confirmado por AUTORIDAD en disco para el brief"
    else
      # [BOUNCE-r2/#7] mismo gap de contrato: verificación de efecto fallida -> abortar+confirmar
      # ANTES de escalar (tco_die termina el proceso; la interrupción del pane DEBE ir antes).
      tco_abort_dev_dispatch "$CARRIL" "$P_DEV" "modelo '$DEV_MODEL' sin confirmar por autoridad en disco" || true
      tco_die "$CARRIL: modelo '$DEV_MODEL' (fase plan) SIN confirmar por autoridad en disco tras el brief — ESCALAR (Regla 0 sin garantizar)"
    fi
  fi
  # [v5] verificación DIFERIDA del effort (rc 2 arriba): el pico de carga del arranque ya pasó y el
  # brief actuó de nudge — ahora la barra debe reflejar xhigh. Si no, el fail-closed se ejecuta AQUÍ.
  if [ "$EFFORT_DEFERRED" = yes ]; then
    sleep "${TCO_EFFORT_DEFER_WAIT:-20}" || tco_die 'espera de verificación diferida fallida'
    if tco_cap_pane "$CARRIL" "$P_DEV" 2>/dev/null | grep -v '^$' | tail -8 | tco_effort_confirmed_from xhigh; then
      tco_info "$CARRIL: effort xhigh CONFIRMADO en verificación diferida"
    else
      tco_die "$CARRIL: effort xhigh SIN confirmar tampoco en la verificación diferida — Regla 0 sin garantizar (revisar el pane)"
    fi
  fi
  if [ "$SOFT" = yes ]; then
    tco_info "dispatch SUAVE hecho. dev en PLAN MODE + effort:xhigh (modelo conservado); brief entregado; auditoría intacta."
  else
    # [M2] Esperar a que el AUDITOR (pane .1) termine de bootear antes de cargar el rol: si se envía sobre el
    # splash, el rol no aterriza / se trunca. Heurística agente-agnóstica: el pane deja de estar vacío.
    for _rw in 1 2 3 4 5 6 7 8 9 10; do
      aud_boot="$(incus exec "$c" -- su - "$TCO_CUSER" -c "tmux capture-pane -t '$P_AUD' -p -J 2>/dev/null" 2>/dev/null | grep -v '^$' | tail -2 || true)"
      [ -n "$aud_boot" ] && break
      sleep 2
    done
    # [bug1/nogo2/M1/M2] Inyectar el rol y CONFIRMAR por la RESPUESTA REAL del auditor (NO por el eco):
    # el rol pide RESPONDER con 'ROL-AUDITORIA-LISTO' al FINAL de su línea; `tco_role_ack` lo detecta
    # anclado a fin de línea. Sin confirmación tras reintentos → FALLAR (un auditor SIN rol no audita).
    # [TAL-1623] no cargar el rol hasta que el TUI del auditor este LISTO (la entrega se pierde
    # en silencio si el CLI aun arranca — visto en despliegue real).
    tco_wait_tui_ready "$CARRIL" "$P_AUD" 90 \
      || tco_die "$CARRIL: el CLI de auditoría no llegó a estado LISTO en 90s — ESCALAR"
    # [v5] rol por la vía canónica file+`lee` (paste-buffer DEPRECADO también en el pane de auditoría —
    # falló en panes originales y reciclados, batch v14) + nudge con las SUBMIT-KEYS del CLI del auditor
    # (codex pierde el Enter de forma intermitente: 'Enter Enter', no C-m). ACK ampliado (TCO_ROLE_ACK_MAX
    # ×5s): un panel fresco tarda ~40s+ en empezar a procesar tras el `lee`.
    ROLE_OK=no
    tco_wait_config 5 "${TCO_ROLE_ACK_MAX:-24}" || tco_die 'máximo de sondeos de rol inválido'
    ROLE_PENDING="$(mktemp)" || tco_die 'no pude crear el recibo del texto de rol'
    # El mensaje del relay NO lleva el token: su eco en el pane no puede acabar en él (el ACK es la RESPUESTA del auditor, no
    # el eco del `lee`; references/03). La línea que debe responder la pide el fichero del rol.
    for _ra in 1 2 3; do
      tco_relay_file "$CARRIL" "$P_AUD" "$A/role-auditoria.txt" "rol" \
        "— es tu ROL de auditoría: cárgalo y responde SOLO con la línea de confirmación de carga que pide el fichero" "${TCO_RELAY_VERIFY_MAX:-90}" "" "$ROLE_PENDING" || true
      for (( _w=1; _w<=${TCO_ROLE_ACK_MAX:-24}; _w++ )); do
        sleep 5 || tco_die 'espera de rol fallida'
        # [P2] codex "Update available!" BLOQUEA el priming del rol (el input queda detrás del prompt):
        # saltarlo (Escape) + trust en cada ciclo antes de evaluar el ACK — idempotente si no aparece.
        if tco_cap_pane "$CARRIL" "$P_AUD" 2>/dev/null | tco_codex_update_prompt_from; then
          tco_codex_skip_update_and_trust "$CARRIL" "$P_AUD"
          tco_relay_file "$CARRIL" "$P_AUD" "$A/role-auditoria.txt" "rol" \
            "— recarga tu ROL de auditoría y responde SOLO con la línea de confirmación de carga que pide el fichero" "${TCO_RELAY_VERIFY_MAX:-90}" "" "$ROLE_PENDING" || true
        fi
        # nudge en el 2º ciclo: el TUI del auditor puede dejar el input detrás de un diálogo —
        # Escape lo descarta y las submit-keys del CLI envían. El gate real sigue siendo el ACK.
        if [ "$_w" = 2 ]; then
          tco_escape_stuck_input "$CARRIL" "$P_AUD" || true
          sleep 1 || tco_die 'espera antes de submit fallida'
          tco_send_submit "$CARRIL" "$P_AUD" --expected "$(cat "$ROLE_PENDING")" || true
        fi
        if tco_cap_pane "$CARRIL" "$P_AUD" 2>/dev/null | tco_role_ack 'ROL-AUDITORIA-LISTO'; then ROLE_OK=yes; break; fi
      done
      [ "$ROLE_OK" = yes ] && break
      tco_err "$CARRIL: rol de auditoría no confirmado por la RESPUESTA del auditor (intento $_ra) — reintento"
    done
    rm -f "$ROLE_PENDING"
    [ "$ROLE_OK" = yes ] || tco_die "no pude confirmar la carga del rol de auditoría en $CARRIL (sin respuesta real 'ROL-AUDITORIA-LISTO' del auditor) — ESCALAR (auditor sin rol no audita)"
    # [m1] Gate de salud post-dispatch: ambos panes ya CONFIRMADOS arriba (brief con eco + rol con eco), o se
    # habría escalado por fallo. Log de salud.
    tco_info "health-check $CARRIL — dev: brief entregado+confirmado · auditoría: rol confirmado (ROL-AUDITORIA-LISTO)"
    tco_info "dispatch hecho. dev en PLAN MODE (sobre bypass) + effort:xhigh + modelo verificado; brief entregado; auditoría con rol."
  fi
fi
