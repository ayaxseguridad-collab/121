#!/usr/bin/env bash
# Registro de modelos por usuario; datos estrictos, nunca source ni eval.
# shellcheck shell=bash
tco_modelos_path() {
  printf '%s\n' "${TCO_MODELOS_REGISTRO:-$HOME/.config/talent-channel-operation/modelos.conf}"
}

# Selección durable, compartida con la generación de lanzadores. El entorno anula explícitamente.
tco_modelo_panel_instancia() {
  local f="${SECRET_DIR:-${HOST_HOME:-$HOME}/.config/talent-channels}/panel.conf" pane panel owner expected
  if [ -e "$f" ] || [ -L "$f" ]; then
    owner="$(stat -c '%U:%G' -- "$f" 2>/dev/null)" || owner=desconocido
    if [ -n "${HOST_USER:-}" ]; then expected="$(id -u "$HOST_USER")" || return 1
    else expected="$(stat -c %u -- "${f%/*}")" || return 1
    fi
    if ! { [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ] &&
      [ "$(stat -c %u -- "$f")" = "$expected" ] &&
      IFS= read -r panel < "$f" && [[ $panel =~ ^[A-Za-z0-9_.-]+:\.0$ ]] &&
      [ "$(wc -c < "$f")" -eq "$((${#panel}+1))" ]; }; then
      printf 'ERROR: selección de panel ilegible o inválida: %s; propietario=%s; corrige permisos: sudo chown %q %q && sudo chmod 600 %q; si el contenido es inválido, reinstala con: sudo rm -- %q && sudo bash %q/../../talent-channels/scripts/install-launchers.sh\n' "$f" "$owner" "$expected" "$f" "$f" "$f" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" >&2
      return 1
    fi
  fi
  if [ "${TC_CLAUDE_PANE+x}" = x ]; then pane="$TC_CLAUDE_PANE"
  elif [ "${TMUX_SESSION+x}" = x ]; then pane="$TMUX_SESSION:.0"
  elif [ -e "$f" ]; then pane="$panel"
  else pane=v:.0
  fi
  [[ $pane =~ ^[A-Za-z0-9_.-]+:[0-9]*\.[0-9]+$ ]] || { echo 'ERROR: panel de instancia inválido' >&2; return 1; }
  printf '%s\n' "$pane"
}

# Clave del fichero de fase rechazada por el filtro: el error la nombra (con tco_err si lib.sh está cargada; este fichero
# también se carga solo, desde preparar-modelo-canal.sh y refresh-claude-auth.sh).
_tco_modelo_clave_err() { # contenedor clave
  local m
  m="$(printf '%s: clave de fase inválida %q: la clave es la LÓGICA del pane en la sesión del canal (<sesión>:.0 o <sesión>:.1), nunca su id %%N ni otros caracteres que [A-Za-z0-9_.:-] — fail-closed' "$1" "$2")"
  if declare -F tco_err >/dev/null; then tco_err "$m"; else printf 'ERROR: %s\n' "$m" >&2; fi
}

# Fase por panel: persiste solo después de confirmar el modelo por el picker. La clave ($3) es la LÓGICA del pane
# (tco_pane_clave_fase traduce el `%N` del despacho); el filtro no se ablanda.
tco_modelo_guardar_fase() { # contenedor usuario clave ID
  local phase
  tco_modelos_read || return 1
  case "$4" in
    "$TCO_OPUS_VIGENTE") phase=plan ;;
    "$TCO_SONNET_VIGENTE") phase=coding ;;
    *) return 1 ;;
  esac
  [[ $3 =~ ^[A-Za-z0-9_.:-]+$ ]] || { _tco_modelo_clave_err "$1" "$3"; return 1; }
  incus exec "$1" -- su - "$2" -c '
    set -e
    mkdir -p "$HOME/.claude"
    f="$HOME/.claude/tf-phase-$1.json"
    [ ! -L "$f" ] || exit 1
    tmp=$(mktemp "$HOME/.claude/.phase.XXXXXX")
    trap '\''rm -f "$tmp"'\'' EXIT
    printf "{\"phase\":\"%s\"}\n" "$2" > "$tmp"
    chmod 600 "$tmp"; mv "$tmp" "$f"
  ' _ "$3" "$phase"
}

# Anulación explícita > fase persistida del panel > modelo de configuración del canal.
# Una fuente presente pero inválida es error; nunca se degrada a otra fuente.
tco_modelo_fase_canal() { # contenedor usuario clave
  local phase
  if [ "${TC_CLAUDE_PHASE+x}" = x ]; then
    phase="$TC_CLAUDE_PHASE"
  else
    [[ $3 =~ ^[A-Za-z0-9_.:-]+$ ]] || { _tco_modelo_clave_err "$1" "$3"; return 1; }
    phase="$(incus exec "$1" -- su - "$2" -c '
      set -euo pipefail
      f="$HOME/.claude/tf-phase-$1.json"
      if [ -e "$f" ] || [ -L "$f" ]; then
        [ ! -L "$f" ] || exit 1
        jq -s -e -r "if length == 1 and (.[0] | type == \"object\") then .[0].phase | select(type == \"string\" and IN(\"plan\",\"replan\",\"fallback\",\"coding\",\"audit\")) else error(\"fase JSON inválida\") end" "$f"
      else
        [ ! -L "$HOME/.claude/settings.json" ] || exit 1
        jq -s -e -r "if length == 1 and (.[0] | type == \"object\") then .[0].model | select(type == \"string\" and (contains(\"\\n\") | not) and test(\"^claude-(opus|sonnet)-[0-9]+([.-][a-z0-9]+)*$\")) else error(\"configuración JSON inválida\") end" "$HOME/.claude/settings.json" |
          { IFS= read -r model
            case "$model" in
              claude-opus-*) printf "plan\n" ;;
              claude-sonnet-*) printf "coding\n" ;;
              *) exit 1 ;;
            esac
          }
      fi
    ' _ "$3")" || phase=''
  fi
  case "$phase" in
    plan|replan|fallback|coding|audit) printf '%s\n' "$phase" ;;
    *) printf '%s: sin fase válida; define TC_CLAUDE_PHASE=plan|replan|fallback|coding|audit o prepara la configuración del canal\n' "$1" >&2; return 1 ;;
  esac
}
tco_modelos_error() {
  printf 'ERROR modelos: registro ausente, ilegible o inválido; ejecuta: bash %q/resolver-modelos.sh\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" >&2
  return 1
}
# Versión visible: componentes numéricos cortos contiguos; el sufijo conserva su ID.
tco_modelo_version_visible() {
  local model="${1:-}" rest part version=''
  [[ $model =~ ^claude-(opus|sonnet|fable)-[0-9]+([.-][a-z0-9]+)*$ ]] || return 1
  rest="${model#claude-}"; rest="${rest#*-}"; rest="${rest//./-}"
  while [ -n "$rest" ]; do
    part="${rest%%-*}"
    [[ $part =~ ^[0-9]{1,2}$ ]] || break
    version+="${version:+.}$part"
    [ "$rest" != "$part" ] || break
    rest="${rest#*-}"
  done
  [ -n "$version" ] || return 1
  printf '%s' "$version"
}
# Comparación de etiqueta: solo versión contigua a la familia, sin descripción.
tco_modelo_etiqueta_is() { # ID; stdin = etiqueta visible
  local model="$1" family version labels
  version="$(tco_modelo_version_visible "$model")" || return 1
  family="${model#claude-}"; family="${family%%-*}"
  labels="$(grep -oiE '(^|\[)(opus|sonnet|fable)[[:space:]]+[0-9]+(\.[0-9]+)*' | tr -d '[' | tr '[:upper:]' '[:lower:]')" || return 1
  [ "$labels" = "$family $version" ]
}
# Primera columna de familia y versión exacta; Default nunca es una familia.
tco_modelo_picker_alias() {
  local family="${1#claude-}" version
  family="${family%%-*}"; version="$(tco_modelo_version_visible "$1")" || return 1
  version="${version//./\\.}"
  printf '^[[:space:]]*(❯|>)?[[:space:]]*[0-9]+\\.[[:space:]]+%s([[:space:]]+(✔|✓|●))?[[:space:]]+(%s[[:space:]]+)?%s([^0-9.]|$)' "$family" "$family" "$version"
}
tco_modelos_read() {
  local f="${1:-$(tco_modelos_path)}" line k v
  local opus='' sonnet='' fecha='' cli='' opus_alias='' sonnet_alias=''
  local sol='' mando='' esfuerzo=medium plan=claude:opus code=claude:sonnet sensible=claude:opus audit=claude:sonnet
  local -A vistos=()
  TCO_OPUS_VIGENTE=''; TCO_SONNET_VIGENTE=''
  TCO_MODELOS_FECHA=''; TCO_MODELOS_CLI=''
  TCO_SOL_VIGENTE=''; TCO_MANDO_MODEL=''; TCO_AUDIT_EFFORT=''
  TCO_ROL_PLAN=''; TCO_ROL_CODE=''; TCO_ROL_CODE_SENSIBLE=''; TCO_ROL_AUDIT=''
  TCO_MODELOS_CLAVES=''
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || { tco_modelos_error; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line =~ ^([A-Z_]+)=\"([^\"]+)\"$ ]] || { tco_modelos_error; return 1; }
    k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
    [ -z "${vistos[$k]:-}" ] || { tco_modelos_error; return 1; }; vistos[$k]=1
    case "$k" in
      OPUS_MODEL) [[ $v =~ ^claude-opus-[0-9]+([.-][a-z0-9]+)*$ ]] || { tco_modelos_error; return 1; }; opus="$v" ;;
      SONNET_MODEL) [[ $v =~ ^claude-sonnet-[0-9]+([.-][a-z0-9]+)*$ ]] || { tco_modelos_error; return 1; }; sonnet="$v" ;;
      RESOLVED_UTC) [[ $v =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { tco_modelos_error; return 1; }; fecha="$v" ;;
      CLI_VERSION) [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { tco_modelos_error; return 1; }; cli="$v" ;;
      OPUS_PICKER_ALIAS) opus_alias="$v" ;;
      SONNET_PICKER_ALIAS) sonnet_alias="$v" ;;
      SOL_MODEL) [[ $v =~ ^gpt-[0-9]+(\.[0-9]+)*-sol$ ]] || { tco_modelos_error; return 1; }; sol="$v" ;;
      MANDO_MODEL) [[ $v =~ ^claude-(opus|sonnet|fable)-[0-9]+([.-][a-z0-9]+)*$ ]] || { tco_modelos_error; return 1; }; mando="$v" ;;
      AUDIT_EFFORT) case "$v" in low|medium|high|xhigh) esfuerzo="$v" ;; *) tco_modelos_error; return 1 ;; esac ;;
      PLAN|CODE|CODE_SENSIBLE|AUDIT)
        case "$v" in claude:opus|claude:sonnet|codex:sol) ;; *) tco_modelos_error; return 1 ;; esac
        case "$k" in PLAN) plan="$v" ;; CODE) code="$v" ;; CODE_SENSIBLE) sensible="$v" ;; AUDIT) audit="$v" ;; esac ;;
      *) tco_modelos_error; return 1 ;;
    esac
  done < "$f"
  [ -n "$opus" ] && [ -n "$sonnet" ] && [ -n "$fecha" ] && [ -n "$cli" ] || { tco_modelos_error; return 1; }
  if ! tco_modelo_version_visible "$opus" >/dev/null || ! tco_modelo_version_visible "$sonnet" >/dev/null; then tco_modelos_error; return 1; fi
  # Registros anteriores de cuatro claves siguen siendo datos válidos; se derivan igual.
  [ -z "$opus_alias" ] || [ "$opus_alias" = "$(tco_modelo_picker_alias "$opus")" ] || { tco_modelos_error; return 1; }
  [ -z "$sonnet_alias" ] || [ "$sonnet_alias" = "$(tco_modelo_picker_alias "$sonnet")" ] || { tco_modelos_error; return 1; }
  if [[ "$plan $code $sensible $audit" = *codex:sol* ]] && [ -z "$sol" ]; then tco_modelos_error; return 1; fi
  TCO_OPUS_VIGENTE="$opus"; TCO_SONNET_VIGENTE="$sonnet"
  TCO_MODELOS_FECHA="$fecha"; TCO_MODELOS_CLI="$cli"
  export TCO_SOL_VIGENTE="$sol" TCO_MANDO_MODEL="$mando" TCO_AUDIT_EFFORT="$esfuerzo"
  export TCO_ROL_PLAN="$plan" TCO_ROL_CODE="$code" TCO_ROL_CODE_SENSIBLE="$sensible" TCO_ROL_AUDIT="$audit"
  TCO_MODELOS_CLAVES=" ${!vistos[*]} "
}
tco_modelo_rol_actual() {
  case "${1:-}" in
    ceo|pm) printf 'claude:opus\n' ;;
    plan|replan) printf '%s\n' "$TCO_ROL_PLAN" ;;
    fallback|code_sensible) printf '%s\n' "$TCO_ROL_CODE_SENSIBLE" ;;
    code|coding) printf '%s\n' "$TCO_ROL_CODE" ;;
    audit) printf '%s\n' "$TCO_ROL_AUDIT" ;;
    coordinador|merge|salud) printf 'claude:sonnet\n' ;;
    *) printf 'ERROR modelos: rol desconocido\n' >&2; return 1 ;;
  esac
}
tco_modelo_read() {
  local rol
  tco_modelos_read || return 1
  rol="$(tco_modelo_rol_actual "${1:-}")" || return 1
  case "${1:-}" in ceo|pm) if [ -n "$TCO_MANDO_MODEL" ]; then printf '%s\n' "$TCO_MANDO_MODEL"; return; fi ;; esac
  case "$rol" in claude:opus) printf '%s\n' "$TCO_OPUS_VIGENTE" ;; claude:sonnet) printf '%s\n' "$TCO_SONNET_VIGENTE" ;; codex:sol) printf '%s\n' "$TCO_SOL_VIGENTE" ;; esac
}
tco_modelo_proveedor() {
  local rol
  tco_modelos_read || return 1
  rol="$(tco_modelo_rol_actual "${1:-}")" || return 1
  printf '%s\n' "${rol%%:*}"
}
tco_modelos_guarda_proveedores() {
  local exe proveedor auditor="${TCO_ROL_AUDIT%%:*}" rol
  for rol in "$TCO_ROL_PLAN" "$TCO_ROL_CODE" "$TCO_ROL_CODE_SENSIBLE"; do
    [ "$rol" != codex:sol ] || { echo 'ERROR modelos: despacho con dev Codex no soportado por el paquete 2.0' >&2; return 1; }
  done
  [ -n "${TCO_AUDIT_CLI:-}" ] || return 0
  # [issue 10264] LISTA BLANCA: primer token sin ruta y sin UN solo `-root` (igual que tco_cli_exe; este fichero se carga sin
  # lib.sh, de ahí el recorte en línea). Solo `codex` EXACTO es Codex (vale `codex` y `codex-root`, el lanzador real de los canales);
  # `claude*` conserva su camino y acaba en error; cualquier otro valor (codexx, codex-evil, gemini…) PARA.
  exe="${TCO_AUDIT_CLI%% *}"; exe="${exe##*/}"; exe="${exe%-root}"
  case "$exe" in claude*) proveedor=claude ;; codex) proveedor=codex ;; *) echo 'ERROR modelos: Codex es obligatorio como revisor; el auditor declarado no es Codex y el despacho se PARA y se escala (no hay auditor de reserva)' >&2; return 1 ;; esac
  # Ley del lead (7-nov): el revisor es SIEMPRE Codex. Con otro auditor, o con una topología que no sea `distinto`
  # (auditoría con el mismo agente que desarrolla), el despacho PARA y se escala: nunca cae a un revisor Claude.
  [ "$proveedor" = codex ] || { echo 'ERROR modelos: Codex es obligatorio como revisor; sin él el despacho se PARA y se escala (no hay auditor de reserva)' >&2; return 1; }
  [ "${TCO_AUDIT_TOPOLOGY:-distinto}" = distinto ] || { echo 'ERROR modelos: la auditoría solo admite la topología distinto (auditor Codex, desarrollo Claude); sin Codex el despacho se PARA y se escala' >&2; return 1; }
  if [[ $TCO_MODELOS_CLAVES = *' AUDIT '* ]]; then
    [ "$auditor" = "$proveedor" ] || { echo 'ERROR modelos: AUDIT no coincide con el proveedor del binario auditor' >&2; return 1; }
  else auditor="$proveedor"; fi
  for rol in "$TCO_ROL_PLAN" "$TCO_ROL_CODE" "$TCO_ROL_CODE_SENSIBLE"; do
    [ "$auditor" != "${rol%%:*}" ] || { echo 'ERROR modelos: el auditor y el que desarrolla no pueden ser el mismo proveedor' >&2; return 1; }
  done
}
tco_modelos_config() {
  TCO_PLAN_MODEL=''; TCO_FALLBACK_MODEL=''; TCO_DEV_MODEL=''
  TCO_DEV_MODEL_ARGS=''
  tco_modelos_read || return 1
  TCO_PLAN_MODEL="$(tco_modelo_read plan)" || return 1
  TCO_FALLBACK_MODEL="$(tco_modelo_read fallback)" || return 1
  TCO_DEV_MODEL="$(tco_modelo_read code)" || return 1
  TCO_DEV_MODEL_ARGS="--model $TCO_DEV_MODEL"
  if [ -z "${TCO_AUDIT_MODEL_ARGS:-}" ]; then
    local aexe="${TCO_AUDIT_CLI:-}"; aexe="${aexe%% *}"; aexe="${aexe##*/}"; aexe="${aexe%-root}"   # [issue 10264] mismo recorte que la guarda: codex EXACTO
    case "$aexe" in
      codex) [ "$TCO_ROL_AUDIT" != codex:sol ] || TCO_AUDIT_MODEL_ARGS="--model $TCO_SOL_VIGENTE --config model_reasoning_effort=$TCO_AUDIT_EFFORT" ;;
    esac
  fi
  tco_modelos_guarda_proveedores
}
# Verifica el ID solicitado contra la autoridad actual en el propio punto de uso.
tco_modelo_require() {
  tco_modelos_read || return 1
  if [ -z "${1:-}" ] || { [ "$1" != "$TCO_OPUS_VIGENTE" ] && [ "$1" != "$TCO_SONNET_VIGENTE" ] && [ "$1" != "$TCO_MANDO_MODEL" ]; }; then tco_modelos_error; return 1; fi
}
