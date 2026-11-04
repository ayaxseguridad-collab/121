#!/usr/bin/env bash
# 00-config.sh — Config central de talent-channel-operation. Se "source-ea". NO ejecuta acciones.
# Orquestador (coordinador) de carriles tmux en Incus para llevar issues de Linear a merge.
# shellcheck shell=bash

# --- Identidad host (no depende de root; opera incus sin sudo vía grupo incus-admin) ---
if [ "$(id -u)" -eq 0 ]; then
  : "${HOST_USER:=${SUDO_USER:-$(id -un)}}"
else
  : "${HOST_USER:=$(id -un)}"
fi
: "${HOST_HOME:=$(getent passwd "$HOST_USER" 2>/dev/null | cut -d: -f6)}"; : "${HOST_HOME:=$HOME}"

# --- Repo objetivo (donde viven los issues) — IDENTIDAD POR REPO (paquete v1, D13) ---
# El NÚCLEO ya NO lleva defaults de identidad de ningún repo: la identidad (repo, slug, stack,
# anexo, Linear, Supabase) vive en scripts/repo-identity.conf (data-only, overlay por repo,
# generado por sync-package.sh --migrate-identity GOBERNADO POR LA AUTORIDAD del manifiesto
# del proyecto). Precedencia: env > repo-identity.conf > ERROR fail-closed al final del archivo
# (tras agents.conf) — la ausencia JAMÁS degrada en silencio a valores del repo fundador
# (hallazgo B1v3: TLO operaba con identidad de TA heredada de una copia sin adaptar).
: "${TCO_ENV_FILE:=.env.local}"                    # de donde el carril lee tokens (core portable)
# [TAL-8037/M3, n2] El marcador a rechazar es SOLO el del repo-identity.conf.example: el valor COMPLETO con la forma
# PENDIENTE-<CLAVE> (anclado, mayúsculas) — jamás subcadenas ni palabras sueltas, para no rechazar valores legítimos
# (un repo `todo`, `pendiente-app`, `placeholder-site`). Mismo criterio que pkg_es_marcador_example de
# skill-creator/lib-package.sh (duplicado CONSCIENTE: este loader runtime no sourcea esa lib). Rechazo fail-closed.
tco_es_marcador_example() { [[ $1 =~ ^PENDIENTE-[A-Z][A-Z0-9_]*$ ]]; }
tco_cargar_identidad() {
  local dir conf line k v
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  conf="$dir/repo-identity.conf"
  [ -f "$conf" ] || return 0    # la EXIGENCIA dura vive en tco_exigir_identidad (final del archivo)
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      PKG_IDENTITY_PROJECT)  # procedencia (la validan sync/validate); no es var runtime — pero tampoco puede ser un marcador (n1)
        if tco_es_marcador_example "$v"; then printf 'ERROR identidad: marcador de pendiente en repo-identity.conf (%s=%s) — un placeholder no es un valor adjudicado\n' "$k" "$v" >&2; exit 1; fi
        continue ;;
      TCO_REPO_DIR|TCO_REPO_SLUG|TCO_REPO_STACK|TCO_ANEXO_FILE|TCO_SUPABASE_REF|TCO_LINEAR_INPROGRESS_STATE|TCO_LINEAR_INREVIEW_STATE|TCO_POSTMERGE_CMD|TCO_HOST_ENV_REL|TCO_TF_MANIFEST) : ;;
      *) printf 'ERROR identidad: clave desconocida en repo-identity.conf (%s)\n' "$k" >&2; exit 1 ;;
    esac
    if [ -z "$v" ]; then printf 'ERROR identidad: valor vacío en repo-identity.conf (%s)\n' "$k" >&2; exit 1; fi
    if tco_es_marcador_example "$v"; then printf 'ERROR identidad: marcador de pendiente en repo-identity.conf (%s=%s) — un placeholder no es un valor adjudicado; sustituye los PENDIENTE-* por los valores de la instancia\n' "$k" "$v" >&2; exit 1; fi
    [ -n "${!k:-}" ] || printf -v "$k" '%s' "$v"   # env gana; el conf rellena lo no fijado
  done < "$conf"
}
tco_cargar_identidad

# --- Flota de carriles (Incus) ---
: "${TCO_PREFIX:=vibe-channel-}"                   # contenedor = ${PREFIX}${NN}
: "${TCO_CUSER:=vivecoder}"                        # usuario dentro del contenedor
: "${TCO_CUSER_UID:=1001}"                          # uid:gid de $TCO_CUSER en el contenedor (golden) — override si difiere
: "${TCO_TMUX:=v}"                                 # sesión tmux; pane .0=desarrollo .1=auditoría
# Manifiesto de la fábrica (fuente del .claude/tf-manifest.conf que el despacho provisiona en cada
# canal — contrato TF_SENSITIVE_SURFACES de verify-handoff). SIN default: cada fábrica lo fija en su
# config (repo-identity.conf o agents.conf) con ruta ABSOLUTA; el dispatch es fail-closed sin él.
: "${TCO_TF_MANIFEST:=}"
# TODO el ruteo de carriles usa ESTAS LISTAS (dispatch/select-issues/status las leen).
# Topología por defecto: 4 dev (01-04) + 2 audit (05-06). Para más dev en paralelo, aprovisiona
# contenedores ADICIONALES (p.ej. TCO_DEV_CARRILES="01 02 03 04 07 08"; TCO_MAX_ACTIVE=6). Reconvertir
# 05/06 a desarrollo es una decisión de topología deliberada (dejan de ser audit-only) — ver 01-modelo.
# [P2] TCO_DEV_CARRILES es DURABLE en $SECRET_DIR/agents.conf (gitignored): fíjalo ahí para que la
# topología real de la máquina sobreviva a re-arranques del coordinador (agents.conf se sourcea al
# final de este archivo y GANA sobre este default). El default de aquí es solo el arranque en frío.
: "${TCO_DEV_CARRILES:=01 02 03 04}"              # carriles de desarrollo (override durable en agents.conf)
: "${TCO_AUDIT_CARRILES:=05 06}"                   # 5=ciberseguridad 6=playwright (solo reportan)
# [G33] El límite real de TCO_MAX_ACTIVE lo marca la SUSCRIPCIÓN/cuenta de los agentes, no la CPU:
# con cuenta compartida entre carriles topa antes (verificado en producción); con cuentas
# independientes por carril, 6 activos funcionó sin problema.
: "${TCO_MAX_ACTIVE:=3}"                            # cap de suscripción (<= activos a la vez); subir a 6 con 6 carriles dev
: "${TCO_PIN_WAIT_MAX:=120}"                        # ciclos máx (×~30s) de espera de un carril pineado ocupado/busy antes de bloquear el resume (R5-B1)

# --- Binarios/flags de los agentes (agente-agnóstico). SIN default committeado: se definen en
#     $SECRET_DIR/agents.conf (gitignored, runtime). Mantiene el repo agente-agnóstico (binarios fuera del repo).
: "${TCO_DEV_CLI:=}"      # lanzador del agente de desarrollo (pane .0): UN solo ejecutable (nombre de lanzador o ruta absoluta; sin asignaciones, env ni espacios: los flags van en TCO_DEV_FLAGS)
: "${TCO_DEV_FLAGS:=}"    # flags extra del dev (vacío si el alias ya los trae). Plan mode se activa con shift+tab
: "${TCO_AUDIT_CLI:=}"    # binario del agente de auditoría (pane .1): UN solo ejecutable, como TCO_DEV_CLI. [v5] Además del binario decide las
                          # SUBMIT-KEYS del pane de auditoría: los TUIs tipo codex requieren 'Enter' (a veces
                          # ×2) — 'C-m' NO les envía el input (ver tco_audit_submit_keys en lib.sh).
# [G32→TAL-8042] patrón de EJECUTABLES de agente a matar al reciclar (definir en agents.conf, gitignored).
# Vacío = solo kill-session. SEMÁNTICA: ERE ANCLADA (`^(…)$`) sobre el NOMBRE del ejecutable — basename de
# argv[0] O comm del proceso —, NO sobre la línea de comandos (el viejo `pkill -f` alcanzaba `~/.codex`,
# `tail -f codex.log`, el lector de stdout…). Recomendado: TCO_AGENT_PROC_PAT="claude|codex". Los valores
# viejos con clase de caracteres (`[c]laude|[c]odex`) siguen casando. Sin riesgo de self-match.
: "${TCO_AGENT_PROC_PAT:=}"
# [TAL-8042] Topología del auditor (FAB-OBS-001). `distinto` (DEFAULT): el auditor (pane .1) es de OTRO agente
# que el dev (pane .0) — garantía de independencia adversarial por proveedor; el despacho MUERE si coinciden.
# `mismo-adversarial`: el auditor es el MISMO agente que el dev (p. ej. una sola cuenta/proveedor), declarado a
# propósito — la garantía es solo de ROL adversarial (no de proveedor) y el despacho lo imprime en cada corrida.
: "${TCO_AUDIT_TOPOLOGY:=distinto}"
: "${TCO_PANE_IDENT_WAIT:=30}"   # s máx. que el preflight de identidad espera a que el agente aparezca en cada pane tras lanzarlo
: "${TCO_AUDIT_FLAGS:=}"  # flags del agente de auditoría
: "${TCO_AUDIT_EFFORT_CMD:=}"  # [M3] comando post-arranque que fija el EFFORT del auditor (pane .1), enviado por send-keys tras lanzarlo. Vacío = no-op. Garantiza effort consistente sin depender de la config persistida previa del contenedor del agente

# --- [v5] Gestión de MODELO (Regla 0 ampliada): la cuenta puede AGOTAR un modelo y el panel queda
#     inservible (colgado sin producir). El lanzador del contenedor (alias claude-root) NO pasa
#     --model → cae al default de la cuenta, que puede ser el agotado. El coordinador VERIFICA y
#     FUERZA el modelo capaz antes de despachar y tras cada recycle/resume. ---
# Modelos exclusivamente del registro del usuario, aplicado tras agents.conf.
: "${TCO_DEV_MODEL:=}"
: "${TCO_DEV_MODEL_ARGS:=}"
: "${TCO_PLAN_MODEL:=}"
: "${TCO_FALLBACK_MODEL:=}"
: "${TCO_AUDIT_MODEL_ARGS:=}"
: "${TCO_MODEL_CURRENT_MARK:=✔|✓|current|selected|●}"  # marca del modelo ACTIVO en el diálogo /model (calibrar en smoke). [TAL-3807] ❯ EXCLUIDO: es el CURSOR (movible), no la marca activa — puede estar sobre cualquier opción mientras ✔ marca la realmente activa
# [TAL-3619/Fix1] Override calibrable de tco_model_family_re (etiquetas de pantalla) para
# cuando la familia derivada del identificador del registro no matchea el label
# real del picker en una versión/cuenta concreta. Vacío = derivar por familia (default).
# [TAL-3807, bounce r2→r3 F-r2-2 + bounce r3 F2] Formato: pares "slug=regex". Separador CANÓNICO =
# SALTO DE LÍNEA; el `|` como separador de pares (formato LEGACY de TAL-3619) sigue ACEPTADO por
# compatibilidad — el parser desambigua: un `|` sólo separa pares si el token siguiente es otro
# "slug=…"; si no, es alternancia DENTRO del valor. Ambos formatos conviven (agents.conf viejos con
# múltiples pares separados por `|` siguen funcionando). Las claves son los identificadores
# completos de modelos.conf; las expresiones de etiqueta se calibran contra el picker vigente.
: "${TCO_MODEL_PICKER_ALIASES:=}"
# El selector numerado exige familia y versión del registro, independientemente de este override.
: "${TCO_FRESH_REGEX:=}"        # regex del placeholder de sesión FRESCA; detecta RESUME+auto-compact del
                                # lanzador (el resume retiene scrollback viejo y BAJA el effort). Vacío = sin detección; calibrar en smoke

# --- [v5] TUI / relay: doctrina file+`lee` para AMBOS panes (paste-buffer deprecado) ---
: "${TCO_AUDIT_SUBMIT_SEQ:=}"   # teclas de submit del pane de auditoría; vacío = derivar de TCO_AUDIT_CLI
                                # (codex → 'Enter Enter'; resto → 'C-m'). Override explícito si el TUI cambia
: "${TCO_AUDIT_BUSY_REGEX:=esc to interrupt|working|thinking}"  # actividad del pane auditor (case-insensitive)
# [P2/TAL-2295] actividad del pane dev AMPLIADA: además de 'esc to interrupt' (marcador clásico),
# los contadores de tiempo/tokens ('12s ·', '1m3s ·'), los medidores de flujo ('↓ 3', '↑ 5') y
# '· thinking' son señal POSITIVA de que el agente trabaja. Un pane-busy más inclusivo hace la
# detección de idle MÁS conservadora (no declara idle prematuro): fail-closed hacia "ocupado".
: "${TCO_BUSY_REGEX:=esc to interrupt|[0-9]+m?s ·|↓ [0-9]|↑ [0-9]|· thinking}"   # actividad del pane dev [P2]

# --- [TAL-3619] Primitiva A: evidencia en disco (AUTORIDAD del status/modelo/entrega) ---
: "${TCO_SESSIONS_DIR:=.claude/sessions}"        # dir de sessions/<pid>.json bajo el HOME del canal
: "${TCO_TRANSCRIPT_DIR:=.claude/projects}"      # dir de projects/<slug>/<sessionId>.jsonl bajo el HOME del canal
: "${TCO_TRANSCRIPT_TAIL:=200}"                  # líneas de cola del transcript que se leen por observación
: "${TCO_PLAN_RECORDS:=20}"                      # [TAL-8039] últimos registros con ExitPlanMode que lee el extractor del plan (regla 17)
: "${TCO_SESSION_STATUS_BUSY_VALUES:=busy}"      # vocabulario CALIBRADO de status=BUSY (pipe-sep)
: "${TCO_SESSION_STATUS_IDLE_VALUES:=idle}"      # [2ª ronda code-gate] vocabulario CALIBRADO de status=IDLE (pipe-sep); status FUERA de ambos vocabularios -> rc 2 SIEMPRE (nunca se acepta un desconocido como reposo, ni siquiera sin turno en vuelo)
: "${TCO_SESSION_BUSY_STALE_MAX:=}"              # s: SOLO la excepción asimétrica del `busy` rancio sin turno en vuelo -> rc 2 (vacío = sin excepción, status persistente puro)
: "${TCO_MODEL_EFFECT_MAX:=60}"                  # s de deadline esperando el assistant descendiente del submit (tco_verify_model_effect)
# [BOUNCE-r2/#7] deadline por intento de tco_wait_idle dentro de tco_abort_dev_dispatch (2 intentos
# con Escape entre medias): confirma por AUTORIDAD PRIMARIA (tco_pane_busy) que el dev pane se
# detuvo de verdad tras un fallo de verificación de modelo, antes de escalar con tco_die.
: "${TCO_ABORT_CONFIRM_MAX:=30}"                 # s de deadline por intento de confirmación de detención (tco_abort_dev_dispatch)

# --- [TAL-3619] Primitiva B: región del TUI por posición del chrome (FALLBACK por CLI, nunca autoridad) ---
: "${TCO_TUI_CHROME_TAIL:=12}"                   # líneas finales donde se busca la estructura completa del composer
: "${TCO_TUI_BORDER_TOP_REGEX:=^[[:space:]]*╭}"   # borde SUPERIOR del composer (calibrar por versión de CLI)
: "${TCO_TUI_BORDER_BOTTOM_REGEX:=^[[:space:]]*╰}" # borde INFERIOR del composer (calibrar por versión de CLI)
: "${TCO_TUI_FOOTER_REGEX:=\? for shortcuts|bypass permissions|shift\+tab}"  # línea de hints del footer
: "${TCO_AMBIG_MAX:=3}"                          # ciclos consecutivos de captura AMBIGUA antes de que tco_wait_idle escale (rc 2 distinguible, nunca autoriza envío)
# [TAL-3619/re-despacho, finding 4] Ventana entre snap1 y snap2 de tco_stable_idle_capture (fallback
# de extracción de STOP-AUDIT en relay.sh) — el idle-check crítico corre DESPUÉS del snapshot final.
: "${TCO_STABLE_GAP:=2}"                         # s de espera entre snapshot inicial y final antes del re-check de idle
: "${TCO_IDLE_STABILITY_GAP:=2}"                 # s entre capturas de transcripción para confirmar reposo vivo (texto creciente = ocupado)
# [TAL-3619/r9-r11] Registro de CALIBRACIÓN del fallback de pane (pares "cli:version" pipe-sep).
# Cada entrada EXIGE un juego COMPLETO de fixtures reales committeados al arnés (idle/busy/modal/
# redraw) en tests/fixtures/pane/<cli>_<ver>/ — ver tests/fixtures/pane/README.md + scripts/capture-pane-fixtures.sh
# (TAL-8042) + invariants.tsv. Par fuera de este registro -> tco_pane_busy_from vía tco_pane_busy responde rc 2
# SIEMPRE (nunca idle, nunca busy adivinado). VACÍO por defecto: sin capturas REALES de un Codex vivo el
# fallback nace INERTE (⇒ rc 2 ⇒ entrega manual verificada por captura, INV-CO-020) hasta que se calibre
# (TAL-8047: primer Codex vivo del ensayo en frío).
: "${TCO_PANE_CALIBRATED:=}"
: "${TCO_PANE_CLI_VERSION_CMD:=}"                # override del comando de versión si un CLI no acepta `--version` (vacío = "<bin> --version")

: "${TCO_RELAY_SUBMIT_GAP:=2}"   # [P2] s entre el send-keys del TEXTO y el del SUBMIT (Enter separado real: en un TUI ocupado el Enter en la misma llamada se pierde)
: "${TCO_RELAY_VERIFY_MAX:=90}"  # ventana (s) de verificación de entrega al pane de AUDITORÍA: un panel
                                 # claude fresco/reciclado tarda ~40s+ en empezar a procesar tras el `lee`
: "${TCO_ROLE_ACK_MAX:=24}"      # iteraciones (×5s) de espera del ACK del rol del auditor (antes 12: corto para panes fríos)
: "${TCO_EFFORT_CONFIRM_MAX:=24}" # s de deadline para CONFIRMAR /effort (antes ~12s efectivos: bajo carga el
                                  # banner tarda >12s en pintarse y daba falso negativo 3/3 en despacho batch)
: "${TCO_EFFORT_DEFER_WAIT:=20}"  # s de espera antes de la verificación DIFERIDA del effort (rc=2 de tco_set_effort)
: "${TCO_EFFORT_DOWNSHIFT_MAX:=900}"  # [P2] s de deadline para CONFIRMAR un downshift /effort post-GO: el dev
                                      # YA implementa (busy), el '/effort high' se ENCOLA y su diálogo de
                                      # confirmación tarda hasta que el agente lo consume (4º arg de tco_set_effort)

# --- [P2/TAL-2295] Muro 1 (auth caída): reauth de carril (Claude por copia · Codex por MOVE) ---
: "${TCO_REAUTH_PROBE_TIMEOUT:=90}"   # timeout DURO de la verificación FUNCIONAL del donante (request real
                                      # one-shot, salida silenciada; NO 'claude login status', que miente con token rancio)
: "${TCO_CLAUDE_DONOR:=}"             # carril donante por defecto para propagar Claude (COPIA; Claude admite fan-out a N canales)
: "${TCO_CODEX_DONOR:=}"              # donante por defecto del MOVE de codex: carril NN o endpoint tipado (host:/channel:/pool:)
: "${TCO_CODEX_ACCOUNT:=}"            # alias de cuenta del ledger para el MOVE de codex (auth-move.sh <cuenta>)
: "${TCO_AUTHMOVE_SH:=}"              # ruta a auth-move.sh (vacío = resolver el de talent-channels junto al skill)
: "${TCO_PARKED_DEBOUNCE_S:=60}"     # [P2] debounce (s) entre las 2 confirmaciones de carril PARKED (anti falso-positivo)
: "${TCO_PARKED_REGEX:=PARKED|a la espera|esperando (tu |el |la |)?(feedback|instrucciones|instruccion|decisión|decision|go|revisión|revision|órdenes|ordenes|siguiente)|he (terminado|entregado)[^.]*espero|awaiting (your )?(input|feedback|review|instructions)}"  # [P2] marcadores de un informe REAL de parking
: "${TCO_VERIFY_HANDOFF_SH:=}"       # [P2] ruta a verify-handoff.sh (vacío = <TCO_HOST_REPO_ROOT|.>/scripts/verify-handoff.sh)

# --- [v5] Bootstrap y smoke ---
: "${TCO_BOOTSTRAP_GITHOOKS:=yes}"  # activa .githooks en el clon del carril al despachar (warn si falla;
                                    # el backstop real es el merge-gate M8 + CR App sobre el PR)
: "${TCO_SMOKE_MODE:=}"         # yes = habilita los flags --no-linear de merge-gate/dispatch (SOLO smoke
                                # tests sin efectos; jamás en trabajo real — los gates mueren si falta)
# --- [v5] Gates: shaok por entregable-idéntico tras rebase mecánico (siempre con traza) ---
: "${TCO_SHAOK_EQUIV:=yes}"     # permite shaok=yes si el ENTREGABLE es byte-idéntico entre auditedSha y headSha (traza SHAOK-EQUIV)
: "${TCO_SHAOK_EXEMPT_PATHS:=}"  # paths exentos del byte-compare (índices compartidos); su diff SE REPORTA, no se oculta. VACÍO en TA: no hay índice/registro compartido colisionable (no existe docs/proyectos/)
: "${TCO_HOST_REPO_ROOT:=}"     # repo git del HOST para tco_deliverable_unchanged (vacío = raíz del clon donde vive el skill)
: "${TCO_AUDIT_REQUIRE_COMMIT:=no}"  # yes = audit-gate MUERE si artifact_sha no es un commit del carril (default: warn + auditar working tree)

# --- [TAL-3619/Fix2] Contrato informe-por-fichero del STOP-AUDIT (capture-pane solo alcanza el
#     viewport; el fichero es el transporte fiable para informes largos — el pane queda como señal) ---
: "${TCO_STOP_AUDIT_FILE:=stop-audit-report.txt}"  # nombre del fichero bajo el HOME del canal
: "${TCO_STOP_AUDIT_MAX_AGE:=7200}"                 # s: guarda SECUNDARIA de antigüedad (la correlación de SHA es el criterio principal)

# --- Escrow runtime (fuera del repo): estado de corridas, locks, env por carril, agents.conf ---
: "${SECRET_DIR:=$HOST_HOME/.config/talent-channel-operation}"
: "${TCO_RUNS_DIR:=$SECRET_DIR/runs}"
: "${TCO_LOCK_DIR:=$SECRET_DIR/locks}"
: "${TCO_LOCK_TTL:=3600}"                           # stale-lock TTL (s)

# --- Política de operación ---
# Merge SIEMPRE humano (no existe modo auto): el gate verde produce stop-merge → OK del lead.
# TA usa Supabase (Postgres): las migraciones SQL viven en supabase/migrations/*.sql y el post-merge
# (aplicarlas a prod vía Management API) lo ejecuta el MERGEADOR (regla 24 / PROC-M13 en
# talent-merger/references/anexo-<proyecto>.md — Fábrica v2 cambió el actor, no la
# mecánica; ver CHANGELOG de este skill).
: "${TCO_MIGRATION_POLICY:=escalate}"              # SOLO escalate para destructivas (no existe 'auto'); ver tco_detect_destructive_migration en lib.sh

# --- Supabase (ledger de migraciones prod — regla 24): IDENTIDAD POR REPO (D13) ---
# TCO_SUPABASE_REF viene de env/repo-identity.conf; requerido si stack=supabase (assert final).

# --- Linear (estados del TEAM del repo): IDENTIDAD POR REPO (D13) ---
# Los UUID de estados son POR TEAM del tracker: heredar los del fundador apuntaría los flujos
# de otro repo a estados ajenos. Vienen de env/repo-identity.conf (assert final).
: "${TCO_LINEAR_CONNECT_TIMEOUT:=10}"              # curl --connect-timeout para la API de Linear
: "${TCO_LINEAR_MAX_TIME:=60}"                     # curl --max-time para la API de Linear
# [TAL-2275] Gate pre-issue [B4]: verificar el ESTADO Linear del issue objetivo antes de despachar
# (gotcha TAL-1178: el resume/compact rehidrata intenciones muertas; el TaskList del harness NO es
# fuente de verdad). Fail-closed: si el estado no se resuelve, ESCALAR. SOLO el literal 'no' desactiva
# el gate; un valor desconocido avisa y mantiene el gate ACTIVO (no apagar seguridad por un typo).
: "${TCO_PREFLIGHT_REQUIRE_LINEAR_STATE:=yes}"
# Estados 'started' cuyo NOMBRE bloquea el dispatch (ADEMAS de completed/canceled, que bloquean por
# type). Pipe-separado, match exacto case-insensitive. Default: "In Review" (PR ya abierto → no re-despachar).
: "${TCO_DISPATCH_BLOCK_STARTED_NAMES:=In Review}"

# (La capa de consumo de órdenes Linear se retiró en 4.0 — TAL-1556; su rediseño es TAL-1568.)

# --- [TAL-3266] Gate pre-issue (4): audit-issue + contrato de control HOLD/RELEASE/SIN-AUDIT ---
# Escape hatch: SOLO el literal 'no' desactiva el gate; cualquier otro valor (typo) → activo + aviso.
# Patrón ESPEJO de TCO_PREFLIGHT_REQUIRE_LINEAR_STATE (mismo case de 3 ramas, mismo default 'yes').
: "${TCO_PREFLIGHT_REQUIRE_AUDIT_ISSUE:=yes}"
# IDs Linear (user.id) autorizados a emitir HOLD/RELEASE/SIN-AUDIT. Separados por pipe (|).
# DEFAULT VACÍO = fail-closed TOTAL: todo HOLD veta (venga de quien venga) y NINGÚN SIN-AUDIT es
# válido. Se puebla POR ESTACIÓN en agents.conf post-fusión; los user.id no son secretos pero sí
# config operativa por máquina, nunca en el repo.
: "${TCO_CONTROL_AUTHORITY_IDS:=}"
# Registro append-only de claims SIN-AUDIT consumidos (cross-host). flock -x sobre este archivo
# actúa como CAS: un comment.id ya consumido no vuelve a bypasear. Si el archivo no es alcanzable
# desde la estación de despacho, el claim ESCALA (no consume silenciosamente).
: "${TCO_CONTROL_CLAIM_FILE:=$SECRET_DIR/control-claims.log}"
# Umbral de score de audit-issue (perfil §8: 70; recalibrar al acumular 10+ issues con plantilla).
: "${TCO_AUDIT_ISSUE_MIN_SCORE:=70}"
# Ruta al helper de issue-craft relativa a la raíz del repo del host (override por máquina si difiere).
: "${TCO_ISSUE_CRAFT_HELPER:=.claude/skills/talent-issue-craft/scripts/issue_craft_helper.ts}"
# Comentarios por página al paginar comentarios de control (anti-explosión de complejidad de API).
: "${TCO_CONTROL_COMMENTS_PAGE:=50}"

# Cargar overrides runtime (gitignored): binarios reales, tokens, IDs por máquina.
# NOTA identidad: agents.conf puede pisar claves de identidad (precedencia env sellada, D13);
# en máquinas MULTI-repo no fijar identidad aquí — el conf por repo es la fuente correcta.
# shellcheck source=/dev/null
[ -f "$SECRET_DIR/agents.conf" ] && . "$SECRET_DIR/agents.conf"
# shellcheck source=lib-modelos.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-modelos.sh"
# Cargar configuración no consume modelos. Un registro inválido deja los valores vacíos;
# el consumidor exigirá de nuevo el registro y emitirá el diagnóstico al necesitarlo.
tco_modelos_config 2>/dev/null || :

# --- [paquete v1, D13] Identidad EXIGIDA — fail-closed, tras agents.conf para honrar overrides ---
tco_exigir_identidad() {
  local k faltan=""
  for k in TCO_REPO_DIR TCO_REPO_SLUG TCO_REPO_STACK TCO_ANEXO_FILE TCO_LINEAR_INPROGRESS_STATE TCO_LINEAR_INREVIEW_STATE; do
    [ -n "${!k:-}" ] || faltan="$faltan $k"
  done
  # [Review PR #13 del motor] TCO_HOST_ENV_REL solo es identidad EXIGIDA cuando no hay
  # TCO_HOST_ENV (env, absoluta): la precedencia documentada de tco_load_tokens es
  # TCO_HOST_ENV > TCO_HOST_ENV_REL > ERROR — exigir la REL con la absoluta ya fijada
  # contradecía esa precedencia y bloqueaba el override legítimo del operador.
  if [ -z "${TCO_HOST_ENV:-}" ] && [ -z "${TCO_HOST_ENV_REL:-}" ]; then
    faltan="$faltan TCO_HOST_ENV_REL"
  fi
  # [TAL-8037/M3] También los valores EFECTIVOS (env/agents.conf/conf): ninguna clave de identidad puede ser un marcador.
  for k in TCO_REPO_DIR TCO_REPO_SLUG TCO_REPO_STACK TCO_ANEXO_FILE TCO_SUPABASE_REF TCO_LINEAR_INPROGRESS_STATE TCO_LINEAR_INREVIEW_STATE TCO_POSTMERGE_CMD TCO_HOST_ENV_REL TCO_HOST_ENV TCO_TF_MANIFEST; do
    if tco_es_marcador_example "${!k:-}"; then printf 'ERROR identidad: marcador de pendiente en %s (%s) — un placeholder no es un valor adjudicado\n' "$k" "${!k}" >&2; exit 1; fi
  done
  if [ -n "$faltan" ]; then
    printf 'ERROR identidad:%s sin valor — genera scripts/repo-identity.conf (copia repo-identity.conf.example y sustituye los PENDIENTE-*, o sync-package.sh --migrate-identity con la AUTORIDAD del proyecto) o exporta por env. JAMÁS se asumen valores de otro repo.\n' "$faltan" >&2
    exit 1
  fi
  # [TAL-8037] Stack: enum CERRADO supabase|convex|ninguno (ninguno = sin backend gestionado: no exige TCO_SUPABASE_REF).
  # Un valor fuera del enum es identidad mal adjudicada — se corta aquí, no se opera con un stack desconocido.
  case "$TCO_REPO_STACK" in
    supabase|convex|ninguno) : ;;
    *) printf 'ERROR identidad: TCO_REPO_STACK fuera del enum supabase|convex|ninguno (%s)\n' "$TCO_REPO_STACK" >&2; exit 1 ;;
  esac
  if [ "$TCO_REPO_STACK" = "supabase" ] && [ -z "${TCO_SUPABASE_REF:-}" ]; then
    printf 'ERROR identidad: TCO_SUPABASE_REF requerido con TCO_REPO_STACK=supabase\n' >&2
    exit 1
  fi
  # [B1-P0] Anti-override divergente: con conf presente, la identidad EFECTIVA (tras env y
  # agents.conf) debe COINCIDIR con el conf clave a clave. Un override de estación que
  # repunte la identidad (p. ej. TCO_REPO_DIR en agents.conf de una máquina multi-repo)
  # produce identidad MIXTA — se corta aquí, jamás se opera con ella.
  local cf line ck cv divergentes=""
  cf="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repo-identity.conf"
  if [ -f "$cf" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ""|"#"*) continue ;; esac
      ck="${line%%=*}"; cv="${line#*=}"
      case "$ck" in PKG_IDENTITY_PROJECT) continue ;; esac
      if [ "${!ck:-}" != "$cv" ]; then divergentes="$divergentes $ck(efectivo='${!ck:-}' conf='$cv')"; fi
    done < "$cf"
    if [ -n "$divergentes" ]; then
      printf 'ERROR identidad: OVERRIDE DIVERGENTE del conf del repo —%s. Corrige el override (env/agents.conf) o migra el conf con autoridad; identidad mixta = operar contra el repo equivocado.\n' "$divergentes" >&2
      exit 1
    fi
  fi
}
tco_exigir_identidad
# Post-merge: hint NEUTRO (repo-agnóstico); el valor real por repo viene de identidad/anexo.
: "${TCO_POSTMERGE_CMD:=echo 'post-merge: seguir el anexo operativo del repo'}"

# --- Helpers de direccionamiento ---
tco_container() { printf '%s%s' "$TCO_PREFIX" "$1"; }                 # 01 -> vibe-channel-01
tco_pane_dev()   { printf '%s:.0' "$TCO_TMUX"; }
tco_pane_audit() { printf '%s:.1' "$TCO_TMUX"; }
tco_repo_path()  { printf '/home/%s/%s' "$TCO_CUSER" "$TCO_REPO_DIR"; }

# Tokens del COORDINADOR para orquestar (consultar Linear/Supabase/gh: select-issues, merge-gate,
# preflight, migraciones post-merge vía Management API). Distintos del env de mínimo privilegio POR CARRIL
# ($SECRET_DIR/env/<carril>.env, que gestiona el skill talent-channels y usa el carril dentro de su
# contenedor): el coordinador NO inyecta sus tokens en los carriles. Token-only, NO MCP; nunca se imprimen.
# [Review PR #13 del motor] Validación ESTRUCTURAL de la ruta REL EN EL LOADER, antes de leer
# archivo alguno — contrato idéntico a pkg_validate_env_rel (skill-creator/scripts/lib-package.sh);
# duplicado CONSCIENTE: este loader runtime no sourcea lib-package.sh (pkg_die2 haría exit del
# shell del coordinador). Sin esto, una REL manipulada con `../../otra/.env.local` escapa de
# $HOST_HOME y carga los tokens de otra fábrica en silencio (misma clase que el orquestador).
tco_validate_env_rel() {
  local v="$1"
  [ -n "$v" ] || { printf 'ERROR identidad: TCO_HOST_ENV_REL vacía\n' >&2; return 1; }
  # shellcheck disable=SC2016  # intencional: $HOST_HOME en los mensajes de error es referencia
  # textual al nombre de la variable, no una expansión buscada (directiva cubre el case completo:
  # no se puede anclar a una rama individual de case, SC1124).
  case "$v" in
    /*) printf 'ERROR identidad: TCO_HOST_ENV_REL absoluta (%s) — debe ser relativa a $HOST_HOME\n' "$v" >&2; return 1 ;;
    *"\\"*) printf 'ERROR identidad: TCO_HOST_ENV_REL con backslash (%s)\n' "$v" >&2; return 1 ;;
    */.env.local) : ;;
    *) printf 'ERROR identidad: TCO_HOST_ENV_REL debe terminar en /.env.local (%s)\n' "$v" >&2; return 1 ;;
  esac
  if printf '%s' "$v" | command grep -Eq '(^|/)\.\.?(/|$)'; then
    # shellcheck disable=SC2016  # intencional: $HOST_HOME es referencia textual, no expansión buscada
    printf 'ERROR identidad: componente ./.. en TCO_HOST_ENV_REL (%s) — traversal fuera de $HOST_HOME\n' "$v" >&2
    return 1
  fi
  return 0
}
tco_load_tokens() {
  # [Ronda P0-2, B2] SIN default del fundador: la ruta del env del host es IDENTIDAD POR REPO.
  # Precedencia: TCO_HOST_ENV (env, absoluta) > TCO_HOST_ENV_REL del conf (relativa a HOST_HOME)
  # > ERROR fail-closed. En esta máquina el env de TA EXISTE y el de otros repos no — un default
  # habría cargado credenciales de TA en flujos ajenos (credenciales cruzadas entre fábricas).
  local envf="${TCO_HOST_ENV:-}" k v home_r target_r
  if [ -n "$envf" ]; then
    # [Review PR #13, NO-GO-3] El override por env cumple su contrato documentado: ABSOLUTA.
    case "$envf" in
      /*) : ;;
      *) printf 'ERROR identidad: TCO_HOST_ENV debe ser ruta ABSOLUTA (%s) — su contrato es (env, absoluta)\n' "$envf" >&2; return 1 ;;
    esac
  elif [ -n "${TCO_HOST_ENV_REL:-}" ]; then
    tco_validate_env_rel "$TCO_HOST_ENV_REL" || return 1
    # [Review PR #13, NO-GO-3] Resolución CANÓNICA anti-symlink (misma clase que el
    # orquestador): home y target canonicalizados con realpath -e; el target resuelto debe
    # permanecer BAJO el home resuelto — un symlink home/link -> fuera ya no escapa.
    home_r="$(realpath -e -- "$HOST_HOME" 2>/dev/null)" \
      || { printf 'ERROR identidad: HOST_HOME no resoluble (%s)\n' "$HOST_HOME" >&2; return 1; }
    target_r="$(realpath -e -- "$HOST_HOME/$TCO_HOST_ENV_REL" 2>/dev/null)" \
      || { printf 'ERROR: no existe el archivo de entorno del host: %s (identidad del repo mal adjudicada o env sin provisionar)\n' "$HOST_HOME/$TCO_HOST_ENV_REL" >&2; return 1; }
    # shellcheck disable=SC2016  # intencional: $HOST_HOME en el mensaje de error es referencia
    # textual, no expansión buscada (directiva sobre el case completo, no se puede anclar a una
    # rama individual, SC1124).
    case "$target_r" in
      "$home_r"/*) envf="$target_r" ;;
      *) printf 'ERROR identidad: TCO_HOST_ENV_REL resuelve FUERA de $HOST_HOME (%s -> %s) — symlink de escape\n' "$TCO_HOST_ENV_REL" "$target_r" >&2; return 1 ;;
    esac
  fi
  if [ -z "$envf" ]; then
    printf 'ERROR identidad: TCO_HOST_ENV sin valor y sin TCO_HOST_ENV_REL en repo-identity.conf — JAMÁS se asume el env del repo fundador\n' >&2
    return 1
  fi
  [ -f "$envf" ] || {
    printf 'ERROR: no existe el archivo de entorno del host: %s (identidad del repo mal adjudicada o env sin provisionar)\n' "$envf" >&2
    return 1
  }
  # [B2] Carga por ALLOWLIST (parseo seguro, NO `source`): SOLO los tokens que el coordinador
  # necesita. Exportar toda clave mayúscula permitía a un env re-pisar identidad TCO_* DESPUÉS
  # del guard anti-override — la allowlist lo excluye por construcción.
  while IFS='=' read -r k v; do
    case "$k" in
      LINEAR_API_KEY|GITHUB_TOKEN|GH_TOKEN|SUPABASE_ACCESS_TOKEN) : ;;
      *) continue ;;
    esac
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"   # quita comillas envolventes si las hay
    export "$k=$v"
  done < <(grep -E '^[A-Z][A-Z0-9_]*=' "$envf" 2>/dev/null)
  return 0
}
