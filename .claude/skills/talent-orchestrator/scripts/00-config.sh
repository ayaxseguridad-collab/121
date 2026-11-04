#!/usr/bin/env bash
# 00-config.sh — Config central de talent-orchestrator (Orquestador). Se "source-ea". NO ejecuta acciones.
# El Orquestador lee Linear de PRODUCTO, cura batches y crea ORDENES DE TRABAJO en el proyecto
# Linear "Coordinacion" que el coordinador (talent-channel-operation) LEE y despacha a mano
# (no hay consumidor automatico). Token-only, NO MCP.
# shellcheck shell=bash

# --- Identidad host ---
if [ "$(id -u)" -eq 0 ]; then
  : "${HOST_USER:=${SUDO_USER:-$(id -un)}}"
else
  : "${HOST_USER:=$(id -un)}"
fi
: "${HOST_HOME:=$(getent passwd "$HOST_USER" 2>/dev/null | cut -d: -f6)}"; : "${HOST_HOME:=$HOME}"

# --- Linear: IDs base (initiative/team/state In Progress de producto) — IDENTIDAD POR INSTANCIA ---
# [TAL-8037] SIN defaults de casa: el team, la initiative meta y el estado «In Progress» son de CADA
# instancia (los fija el setup gated en agents.conf/env). Vacíos = fail-closed: orchestrate.sh los
# exige con `:?` donde se usan, jamás se asumen los de otra fábrica.
: "${TORC_TEAM_ID:=}"            # UUID del team Linear de la instancia (la clave del team: TF_LINEAR_TEAM_KEY)
# Initiative META de coordinación/orquestación (NO la de producto). El proyecto Coordinación
# debe pertenecer a esta initiative (excepción formalizada en la doctrina de la instancia). El preflight
# valida la pertenencia. El trabajo de producto va en su initiative; esta capa meta va en otra.
: "${TORC_INITIATIVE_ID:=}"      # UUID de la initiative meta de la instancia
: "${TORC_STATE_INPROGRESS:=}"   # UUID del estado "In Progress" (type started) del team de la instancia

# --- Capa COORDINACION (SETUP gated: estos IDs NO existen hasta que el lead autorice el setup) ---
# El preflight de orchestrate.sh los valida por API y FALLA ruidoso si faltan. Override real en el
# escrow (agents.conf) o por env. NUNCA se inventan ni se auto-crean.
: "${TORC_COORD_PROJECT_ID:=}"          # proyecto Linear "Coordinacion"
: "${TORC_REGISTRY_ISSUE_ID:=}"         # issue-registro de la flota (siempre In Progress, label registry)
: "${TORC_STATE_TODO:=}"                # estado "To Do" (type unstarted) de las ordenes de trabajo
: "${TORC_STATE_WORKING:=}"             # estado "In Progress" (type started)
: "${TORC_STATE_NEEDS_INPUT:=}"         # estado "Needs Input" (gated; type a decidir por el lead)
: "${TORC_STATE_DONE:=}"                # estado "Done" (type completed)
: "${TORC_LABEL_AGENT_INSTR:=}"         # label agent-instructions
: "${TORC_LABEL_REGISTRY:=}"            # label registry
: "${TORC_LABEL_VERTICAL:=}"            # label vertical/* obligatorio (p.ej. vertical/academy)
: "${TORC_LABEL_ACTOR_AI:=}"            # label actor/ai obligatorio

# --- Naming de canal (alineado con talent-channel-operation: container = ${PREFIX}${channel_id}) ---
: "${TORC_CHANNEL_PREFIX:=vibe-channel-}"

# --- Batch ---
: "${TORC_DEFAULT_CAP:=4}"             # tamano de batch por defecto (<= cuadrilla, 4-6)
: "${TORC_SCHEMA_VERSION:=1}"          # version del bloque machine-readable de la orden

# --- Escrow runtime (fuera del repo, gitignored): ids reales del setup, locks ---
: "${TORC_SECRET_DIR:=$HOST_HOME/.config/talent-orchestrator}"
: "${TORC_LOCK_DIR:=$TORC_SECRET_DIR/locks}"
: "${TORC_LOCK_TTL:=3600}"

# --- Torre de Control (TAL-2278): operacion torre-* en tmux del HOST (ver lib-torre.sh) ---
: "${TORRE_SESSION_PREFIX:=torre-}"     # sesiones tmux torre-<actor> (runbook torre-de-control)
: "${TORRE_BUSY_REGEX:=esc to interrupt}"  # marcador semantico de actividad del TUI
: "${TORRE_USAGE_REGEX:=approaching.*limit|usage limit|resets at}"  # aviso de limite de cuenta (barra)
: "${TORRE_CTX_THRESHOLD:=60}"          # % de contexto que dispara compact-60 (protocolo del lead)
: "${TORRE_LIVE_WINDOW:=90}"            # ventana (s) para considerar VIVO un transcript (mtime==ahora)
: "${TORRE_VERIFY_MAX:=30}"             # ventana (s) de verificacion de entrega de un relay
: "${TORRE_IDLE_MAX:=120}"              # espera maxima (s) a idle estable antes de un relay
: "${TORRE_HANDOFF_MAX:=300}"           # espera maxima (s) al handoff de regreso (compact-60)
: "${TORRE_HANDOFF_HARD_MAX:=1200}"     # [TAL-8039] tope DURO (s) de la prorroga del handoff mientras el turno sigue vivo
: "${TORRE_HANDOFF_EXTEND:=60}"         # [TAL-8039] paso (s) de prorroga cada vez que vence el plazo con el turno vivo
: "${TORRE_HANDOFF_POLL:=10}"           # [TAL-8039] intervalo (s) entre lecturas del fichero/pantalla del handoff
: "${TORRE_COMPACT_MAX:=600}"           # espera maxima (s) al fin del /compact
: "${TORRE_RELAY_DIR:=$TORC_SECRET_DIR/relay}"       # archivos de relevo (0600, fuera del repo)
: "${TORRE_HANDOFF_DIR:=$TORC_SECRET_DIR/handoffs}"  # handoffs compact-60 (copia FUERA de la sesion)
: "${TORRE_CLAUDE_PROJECTS:=$HOST_HOME/.claude/projects}"  # transcripts para el resume canonico

# Overrides runtime (gitignored): IDs reales del setup gated + tokens por maquina.
# shellcheck source=/dev/null
[ -f "$TORC_SECRET_DIR/agents.conf" ] && . "$TORC_SECRET_DIR/agents.conf"

# --- Linear token (token-only, NO MCP). Solo se carga en el shell del orquestador; nunca se imprime. ---
# Carga SOLO LINEAR_API_KEY (no evalua lineas arbitrarias del .env.local).
# [paquete v1, D13] IDENTIDAD POR REPO: el env del repo anclado ya NO tiene default del fundador
# (una fábrica ajena leería los tokens de Academia Ejemplo en silencio — misma clase B1v3/TLO).
# Precedencia: TORC_HOST_ENV (env, absoluto) > scripts/repo-identity.conf (TORC_HOST_ENV_REL,
# relativo a $HOST_HOME, data-only sin `source`) > ERROR fail-closed.
# [Review PR #13 del motor] Validación ESTRUCTURAL de la ruta REL EN EL LOADER, antes de leer
# archivo alguno — contrato idéntico a pkg_validate_env_rel (skill-creator/scripts/lib-package.sh);
# duplicado CONSCIENTE: este loader runtime no sourcea lib-package.sh (pkg_die2 haría exit del
# shell del orquestador). Sin esto, un conf manipulado con `../../otra/.env.local` escapa de
# $HOST_HOME y carga el LINEAR_API_KEY de otra fábrica en silencio.
# [TAL-8037/M3, n2] El marcador a rechazar es SOLO el del .example: el valor COMPLETO PENDIENTE-<CLAVE> (anclado, mayúsculas);
# jamás subcadenas ni palabras sueltas (mismo criterio que pkg_es_marcador_example de skill-creator/lib-package.sh;
# duplicado CONSCIENTE: este loader runtime no sourcea esa lib).
torc_es_marcador_example() { [[ $1 =~ ^PENDIENTE-[A-Z][A-Z0-9_]*$ ]]; }
torc_validate_env_rel() {
  local v="$1"
  [ -n "$v" ] || { printf 'ERROR identidad (orquestador): TORC_HOST_ENV_REL vacía en repo-identity.conf\n' >&2; return 1; }
  case "$v" in
    /*) printf 'ERROR identidad (orquestador): TORC_HOST_ENV_REL absoluta (%s) — debe ser relativa a $HOST_HOME\n' "$v" >&2; return 1 ;;
    *"\\"*) printf 'ERROR identidad (orquestador): TORC_HOST_ENV_REL con backslash (%s)\n' "$v" >&2; return 1 ;;
    */.env.local) : ;;
    *) printf 'ERROR identidad (orquestador): TORC_HOST_ENV_REL debe terminar en /.env.local (%s)\n' "$v" >&2; return 1 ;;
  esac
  if printf '%s' "$v" | command grep -Eq '(^|/)\.\.?(/|$)'; then
    printf 'ERROR identidad (orquestador): componente ./.. en TORC_HOST_ENV_REL (%s) — traversal fuera de $HOST_HOME\n' "$v" >&2
    return 1
  fi
  return 0
}
torc_load_tokens() {
  local envf="${TORC_HOST_ENV:-}" v conf line k rel="" home_r target_r
  if [ -n "$envf" ]; then
    # [Review PR #13, NO-GO-3] El override por env cumple su contrato documentado: ABSOLUTA.
    case "$envf" in
      /*) : ;;
      *) printf 'ERROR identidad (orquestador): TORC_HOST_ENV debe ser ruta ABSOLUTA (%s) — su contrato es (env, absoluto)\n' "$envf" >&2; return 1 ;;
    esac
  else
    conf="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repo-identity.conf"
    if [ -f "$conf" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        k="${line%%=*}"
        if torc_es_marcador_example "${line#*=}"; then
          printf 'ERROR identidad (orquestador): marcador de pendiente en repo-identity.conf (%s=%s) — un placeholder no es un valor adjudicado\n' "$k" "${line#*=}" >&2; return 1
        fi
        case "$k" in
          PKG_IDENTITY_PROJECT) : ;;  # procedencia (la validan sync/validate)
          TORC_HOST_ENV_REL) rel="${line#*=}" ;;
          *) printf 'ERROR identidad (orquestador): clave desconocida en repo-identity.conf (%s)\n' "$k" >&2; return 1 ;;
        esac
      done < "$conf"
    fi
    if [ -n "$rel" ]; then
      torc_validate_env_rel "$rel" || return 1
      # [Review PR #13, NO-GO-3] Resolución CANÓNICA anti-symlink: la validación léxica no ve
      # un symlink DENTRO de $HOST_HOME apuntando fuera (home/link -> /otra-fabrica). Se
      # canonicalizan home y target (realpath -e) y el target resuelto debe permanecer BAJO
      # el home resuelto; SOLO entonces se lee el archivo.
      home_r="$(realpath -e -- "$HOST_HOME" 2>/dev/null)" \
        || { printf 'ERROR identidad (orquestador): HOST_HOME no resoluble (%s)\n' "$HOST_HOME" >&2; return 1; }
      target_r="$(realpath -e -- "$HOST_HOME/$rel" 2>/dev/null)" \
        || { printf 'ERROR identidad (orquestador): el env declarado no existe (%s)\n' "$HOST_HOME/$rel" >&2; return 1; }
      case "$target_r" in
        "$home_r"/*) envf="$target_r" ;;
        *) printf 'ERROR identidad (orquestador): TORC_HOST_ENV_REL resuelve FUERA de $HOST_HOME (%s -> %s) — symlink de escape\n' "$rel" "$target_r" >&2; return 1 ;;
      esac
    fi
  fi
  if [ -z "$envf" ]; then
    printf 'ERROR identidad (orquestador): TORC_HOST_ENV sin valor y sin scripts/repo-identity.conf — JAMÁS se asume el env del repo fundador\n' >&2
    return 1
  fi
  if [ ! -f "$envf" ]; then
    printf 'ERROR identidad (orquestador): el env declarado no existe (%s)\n' "$envf" >&2
    return 1
  fi
  v="$(grep -E '^LINEAR_API_KEY=' "$envf" 2>/dev/null | head -1 | cut -d= -f2-)"
  [ -n "$v" ] && export LINEAR_API_KEY="$v"
  return 0
}
