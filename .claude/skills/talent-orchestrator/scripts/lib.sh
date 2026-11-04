#!/usr/bin/env bash
# lib.sh — Helpers de talent-orchestrator. Se "source-ea" tras 00-config.sh.
# Incluye funciones PURAS (testeables sin red), cubiertas por tests/run-tests.sh:
#   validadores · linear_api (variables, no interpolacion) · normalizacion de canal ·
#   orden de prioridad · topo-sort + ciclos · exclusion de reserva · parse de registro ·
#   render/JSON de orden · extraccion de issue_ids · idempotency key · locks.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# [TAL-1974] Directorio raiz del skill (padre de scripts/), para localizar assets/ sin depender
# del HERE del caller — se resuelve por el BASH_SOURCE de este propio archivo, no el del script
# que lo source-ea (robusto ante cualquier consumidor futuro que no defina su propio HERE).
# ---------------------------------------------------------------------------
: "${TORC_SKILL_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

torc_say()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
torc_info() { printf '   %s\n' "$*"; }
torc_err()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }
torc_die()  { torc_err "$*"; exit 1; }

# Redaccion de secretos en logs (nunca volcar tokens).
torc_redact() {
  sed -E 's/(lin_api_|sbp_|sb_secret_|gh[pso]_)[A-Za-z0-9_-]{6,}/\1REDACTED/g;
          s/((LINEAR_API_KEY|[A-Z_]*TOKEN|[A-Z_]*SECRET|[A-Z_]*KEY)=)[^[:space:]]+/\1REDACTED/g'
}

# ---------------------------------------------------------------------------
# Validadores estrictos [BLOQUEANTE 3]. return 0 si valido. Charclass portable (no \w).
# ---------------------------------------------------------------------------
torc_is_uuid()    { printf '%s' "$1" | grep -qE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; }
# [TAL-8037] Clave del team Linear de la INSTANCIA — jamás un default de casa. Resolución fail-closed:
# env TF_LINEAR_TEAM_KEY → línea TF_LINEAR_TEAM_KEY=… del manifiesto TF_MANIFEST (ruta ABSOLUTA, leída como DATO,
# sin `source`) → error nombrando la variable. Formato ^[A-Z][A-Z0-9]{0,9}$ (también el del env). Imprime la clave.
torc_linear_team_key() {
  local key="${TF_LINEAR_TEAM_KEY:-}" mf="${TF_MANIFEST:-}"
  if [ -z "$key" ] && [ -n "$mf" ]; then
    case "$mf" in /*) : ;; *) torc_err "TF_MANIFEST debe ser ruta ABSOLUTA ($mf)"; return 1 ;; esac
    [ -f "$mf" ] && key="$(sed -n -E 's/^TF_LINEAR_TEAM_KEY=("([^"]*)"|([^[:space:]"#]*)).*$/\2\3/p' "$mf" | tail -1)"
  fi
  [ -n "$key" ] || { torc_err "TF_LINEAR_TEAM_KEY sin resolver: ni la variable de entorno ni la línea TF_LINEAR_TEAM_KEY= del manifiesto (TF_MANIFEST) — fail-closed, jamás se asume una clave"; return 1; }
  [[ $key =~ ^[A-Z][A-Z0-9]{0,9}$ ]] || { torc_err "TF_LINEAR_TEAM_KEY inválida ('$key'): se espera ^[A-Z][A-Z0-9]{0,9}$"; return 1; }
  printf '%s' "$key"
}
# ¿$1 es un id de issue de la instancia (<CLAVE>-<n>)? (el nombre histórico torc_is_tal se conserva por compatibilidad)
torc_is_tal()     { local k; k="$(torc_linear_team_key)" || return 1; printf '%s' "$1" | grep -qE "^${k}-[0-9]+\$"; }
torc_is_coord()   { printf '%s' "$1" | grep -qE '^coord-[a-z0-9-]+$'; }
torc_is_channel() { printf '%s' "$1" | grep -qE '^vibe-channel-[0-9]+$'; }
torc_is_repo()    { printf '%s' "$1" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; }

# ---------------------------------------------------------------------------
# [BLOQUEANTE 3] Linear API: SIEMPRE variables GraphQL (jq -n), nunca interpolacion en el query.
# linear_api <query> [variables_json]  -> imprime el JSON de respuesta crudo
# ---------------------------------------------------------------------------
linear_api() {
  local query="$1" vars="${2:-}"
  [ -n "$vars" ] || vars='{}'
  command -v jq >/dev/null 2>&1 || { torc_err "jq requerido"; return 1; }
  # Timeouts: sin ellos curl puede colgarse indefinidamente y dejar el lock vivo (CR #2, fallo operacional).
  jq -n --arg q "$query" --argjson v "$vars" '{query:$q, variables:$v}' \
    | curl -sS --connect-timeout "${TORC_LINEAR_CONNECT_TIMEOUT:-10}" --max-time "${TORC_LINEAR_MAX_TIME:-60}" \
        -X POST https://api.linear.app/graphql \
        -H "Authorization: ${LINEAR_API_KEY:?falta LINEAR_API_KEY}" \
        -H "Content-Type: application/json" -d @-
}

# [CR #4] Propagación transitiva de bloqueo: dado cands (presentes) + edges (child<TAB>parent),
# devuelve los nodos a bloquear porque su parent (directo o transitivo) ya no está presente. Punto fijo.
torc_cascade_blocked() {
  local cands="$1" edges="$2" work out new
  work="$(mktemp)"; out="$(mktemp)"; cp "$cands" "$work"; : > "$out"
  while :; do
    new="$(awk -F'\t' 'FNR==NR{p[$1]=1;next} ($1 in p)&&!($2 in p){print $1}' "$work" "$edges" | sort -u)"
    [ -n "$new" ] || break
    printf '%s\n' "$new" >> "$out"
    printf '%s\n' "$new" > "$work.blk"
    torc_exclude "$work.blk" < "$work" > "$work.new"; mv "$work.new" "$work"
  done
  sort -u "$out"; rm -f "$work" "$out" "$work.blk"
}

# ---------------------------------------------------------------------------
# [TAL-3265 r6] Truncacion de relaciones: fail-closed SOLO si pageInfo.hasNextPage=true.
# stdin: nodes.jsonl (un objeto de issue por linea, con .relations.nodes[] y
#        .relations.pageInfo.hasNextPage — requiere el query con pageInfo{hasNextPage}
#        DENTRO de relations(first:50), no solo en el pageInfo externo de issues).
# stdout: .identifier de las issues realmente truncadas (length>=50 Y hasNextPage=true).
# Vacio = ninguna truncada de verdad, aunque alguna tenga exactamente 50 sin pagina siguiente
# (ese caso es el total real de relaciones, no truncacion — no debe fail-closed).
# ---------------------------------------------------------------------------
torc_relations_truncated() {
  jq -r 'select((.relations.nodes|length)>=50 and ((.relations.pageInfo.hasNextPage)//false)==true) | .identifier'
}

# ---------------------------------------------------------------------------
# [MAYOR no-bloqueante 1] Normalizacion de canal: el coordinador usa channel_id corto (01),
# el container es vibe-channel-01. Exponemos ambas direcciones.
# ---------------------------------------------------------------------------
torc_to_channel_id() { printf '%s' "${1#"$TORC_CHANNEL_PREFIX"}"; }                                   # vibe-channel-01|01 -> 01
torc_to_container()  { case "$1" in "$TORC_CHANNEL_PREFIX"*) printf '%s' "$1";; *) printf '%s%s' "$TORC_CHANNEL_PREFIX" "$1";; esac }  # 01 -> vibe-channel-01

# ---------------------------------------------------------------------------
# Orden de prioridad: remapeo 0(None)->99 para que Urgent(1) quede PRIMERO. [replica select-issues.sh]
# stdin: lineas "PRIO<TAB>TAL-id"  ;  stdout: TAL-id ordenados (urgent primero, None al final)
# ---------------------------------------------------------------------------
torc_order_by_priority() {
  awk -F'\t' '{ p=$1+0; if(p==0)p=99; printf "%02d\t%s\n", p, $2 }' | sort -t$'\t' -k1,1n -s | cut -f2
}

# ---------------------------------------------------------------------------
# [MAYOR 4] Topo-sort (Kahn) + deteccion de ciclos. Determinista (preserva orden de entrada).
# torc_toposort <nodes_file> <edges_file>
#   nodes_file: un TAL-id por linea (candidatos del batch, en el orden deseado)
#   edges_file: "CHILD<TAB>PARENT" = CHILD depende de PARENT (PARENT va antes). Solo aristas intra-batch.
# stdout: orden topologico (parents primero). exit 2 si hay CICLO.
# ---------------------------------------------------------------------------
torc_toposort() {
  awk -F'\t' '
    FNR==NR { id=$1; if(id!="" && !(id in isnode)){ isnode[id]=1; ord[++N]=id; indeg[id]=0 } ; next }
    {
      c=$1; p=$2
      if((c in isnode) && (p in isnode) && c!=p) {
        k=c SUBSEP p
        if(!(k in seen)){ seen[k]=1; adj[p]=adj[p] c SUBSEP; indeg[c]++ }
      }
    }
    END {
      head=1; tail=0
      for(i=1;i<=N;i++) if(indeg[ord[i]]==0) q[++tail]=ord[i]
      cnt=0
      while(head<=tail){
        u=q[head++]; print u; cnt++
        n=split(adj[u], a, SUBSEP)
        for(j=1;j<n;j++){ v=a[j]; if(v!="" && --indeg[v]==0) q[++tail]=v }
      }
      if(cnt!=N) exit 2
    }
  ' "$1" "$2"
}

# ---------------------------------------------------------------------------
# [BLOQUEANTE 1] Exclusion de reserva: quita de los candidatos los TAL ya reservados.
# torc_exclude <reserved_file>   (stdin = candidatos uno/linea ; stdout = no reservados)
# Lee la reserva en BEGIN para ser robusto ante archivo VACIO (el truco FNR==NR falla con file vacio).
# ---------------------------------------------------------------------------
torc_exclude() { awk -v rf="$1" 'BEGIN{while((getline l < rf)>0) r[l]=1} ($1!="" && !($1 in r))'; }

# ---------------------------------------------------------------------------
# Parse del issue-registro: extrae filas de la tabla cercada. CERO secretos en el registro.
# stdin = body markdown del issue-registro
# stdout TSV: channel<TAB>machine<TAB>hwclass<TAB>role<TAB>coordinador<TAB>repo
# ---------------------------------------------------------------------------
torc_registry_rows() {
  awk -v pfx="$TORC_CHANNEL_PREFIX" '
    /^[[:space:]]*```/ { infence=!infence; next }
    infence && index($0, pfx) {
      line=$0
      sub(/^[[:space:]]*\|/,"",line); sub(/\|[[:space:]]*$/,"",line)
      n=split(line, c, "|")
      for(i=1;i<=n;i++){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",c[i]) }
      if(n>=6) printf "%s\t%s\t%s\t%s\t%s\t%s\n", c[1],c[2],c[3],c[4],c[5],c[6]
    }
  '
}

# ---------------------------------------------------------------------------
# [MAYOR 6] Bloque machine-readable de la orden de trabajo. JSON parseable.
# torc_build_order_json <coordinador> <coord_project_id> <repo> <"TAL-1 TAL-2"> [precedence_json] [dod]
# ---------------------------------------------------------------------------
torc_build_order_json() {
  local coord="$1" proj="$2" repo="$3" ids="$4" prec="${5:-[]}" dod="${6:-drafts-entregados+handoff+in-review}" ids_json
  ids_json="$(printf '%s\n' $ids | sed '/^$/d' | jq -R . | jq -s .)"
  jq -n --argjson sv "$TORC_SCHEMA_VERSION" --arg c "$coord" --arg p "$proj" --arg r "$repo" \
        --argjson ids "$ids_json" --argjson prec "$prec" --arg dod "$dod" \
        '{schema_version:$sv, coordinador:$c, coordination_project_id:$p, product_project:$r, issue_ids:$ids, precedence:$prec, dod:$dod}'
}

# ---------------------------------------------------------------------------
# [TAL-1974] Render del cuerpo de la orden de trabajo — UNICA fuente de verdad: assets/work-order.tmpl
# (antes habia un printf inline duplicado en orchestrate.sh que ya habia divergido del .tmpl en la
# linea del DoD; ver tests/run-tests.sh para el guard estatico anti-divergencia). last_verified: 2026-07-18
# (fidelidad .tmpl<->render re-confirmada en esta fecha — anotacion en CODIGO, no dentro del .tmpl, que
# queda PURO: solo el cuerpo de la orden, cero cabecera/comentario, para que el render no filtre nada).
# Placeholders escalares (__COORD__/__REPO__/__NEEDS_INPUT_STATE__): sed con el mismo escapado que
# talent-channel-operation/scripts/dispatch.sh (escape_sed_replacement, protege & | \). Placeholders
# MULTILINEA (__ISSUE_LIST__/__JSON_BLOCK__): awk por comparacion de linea completa (no sed/gsub — su
# valor trae saltos de linea que un reemplazo de una sola linea no puede insertar sin escapado fragil).
# torc_render_order_body <coord> <repo> <issue_list_multilinea> <needs_input_state> <json_block>
# ---------------------------------------------------------------------------
torc_render_order_body() {
  local coord="$1" repo="$2" issue_list="$3" nin="$4" json="$5"
  local tmpl="$TORC_SKILL_DIR/assets/work-order.tmpl" esc_coord esc_repo esc_nin stage1 ilf jf rc
  [ -f "$tmpl" ] || { torc_err "render_order_body: falta $tmpl"; return 1; }
  # [TAL-1974 ronda 2] CADA paso se verifica explicitamente: un fallo silencioso de mktemp/escritura/
  # sed/awk NO debe traducirse en return 0 con un body corrupto (issue_list/json vacios) — el `rm -f`
  # final, con -f, siempre devuelve 0 y enmascararia cualquier fallo previo si no se captura antes.
  esc_coord="$(printf '%s' "$coord" | sed -e 's/[&|\\]/\\&/g')" \
    || { torc_err "render_order_body: fallo escapando coordinador"; return 1; }
  esc_repo="$(printf '%s'  "$repo"  | sed -e 's/[&|\\]/\\&/g')" \
    || { torc_err "render_order_body: fallo escapando repo"; return 1; }
  esc_nin="$(printf '%s'   "$nin"   | sed -e 's/[&|\\]/\\&/g')" \
    || { torc_err "render_order_body: fallo escapando estado needs-input"; return 1; }
  stage1="$(sed -e "s|__COORD__|$esc_coord|g" -e "s|__REPO__|$esc_repo|g" -e "s|__NEEDS_INPUT_STATE__|$esc_nin|g" "$tmpl")" \
    || { torc_err "render_order_body: fallo sustituyendo escalares del template"; return 1; }
  ilf="$(mktemp)" && [ -f "$ilf" ] || { torc_err "render_order_body: fallo mktemp (issue_list)"; return 1; }
  jf="$(mktemp)" && [ -f "$jf" ] || { torc_err "render_order_body: fallo mktemp (json)"; rm -f "$ilf"; return 1; }
  printf '%s\n' "$issue_list" > "$ilf" \
    || { torc_err "render_order_body: fallo escribiendo issue_list temporal"; rm -f "$ilf" "$jf"; return 1; }
  printf '%s\n' "$json" > "$jf" \
    || { torc_err "render_order_body: fallo escribiendo json temporal"; rm -f "$ilf" "$jf"; return 1; }
  printf '%s\n' "$stage1" | awk -v ilf="$ilf" -v jf="$jf" '
    $0=="__ISSUE_LIST__" { while ((getline l < ilf) > 0) print l; close(ilf); next }
    $0=="__JSON_BLOCK__"  { while ((getline l < jf)  > 0) print l; close(jf);  next }
    { print }
  '
  rc=$?
  rm -f "$ilf" "$jf"
  return "$rc"
}

# Extrae issue_ids del bloque ```json de una orden (para leer reservas).
# stdin = body de la orden ; stdout = TAL ids uno/linea
torc_extract_issue_ids() {
  awk '/^[[:space:]]*```json/{inj=1;next} /^[[:space:]]*```/{if(inj){inj=0}} inj' \
    | jq -r '.issue_ids[]?' 2>/dev/null
}

# ---------------------------------------------------------------------------
# [TAL-1568] Fetch fail-closed de ordenes ABIERTAS (state != completed/canceled) que tienen TODOS
# los labels dados (semantica AND explicita: NO usar {id:{in:[...]}} que seria OR). Endurece el patron
# de reserva de select-work.sh anadiendo tambien el check de .errors (GraphQL puede devolver .data
# PARCIAL junto con .errors). Filtro tipado como variable IssueFilter (nunca interpolacion en el query).
# torc_fetch_open_orders <coord_project_id> <label_id...>
#   stdout: JSONL {identifier, description} (una orden por linea); vacio = no hay ordenes (con query OK).
#   return != 0 = fallo DURO (errors / truncacion / API / jq) -> el caller ESCALA. Nunca interpreta
#   'sin datos verificables' como 'no hay ordenes'.
# ---------------------------------------------------------------------------
torc_fetch_open_orders() {
  local pid="$1"; shift
  torc_is_uuid "$pid" || { torc_err "fetch_open_orders: coord_project_id invalido"; return 1; }
  [ "$#" -ge 1 ] || { torc_err "fetch_open_orders: falta >=1 label id"; return 1; }
  local labels_and filter Q vars resp
  labels_and="$(printf '%s\n' "$@" | jq -R . | jq -s 'map({labels:{some:{id:{eq:.}}}})')" \
    || { torc_err "fetch_open_orders: fallo construyendo filtro de labels"; return 1; }
  filter="$(jq -n --arg pid "$pid" --argjson land "$labels_and" \
    '{project:{id:{eq:$pid}}, state:{type:{nin:["completed","canceled"]}}, and:$land}')" \
    || { torc_err "fetch_open_orders: fallo construyendo filtro"; return 1; }
  Q='query($filter:IssueFilter,$after:String){issues(first:250,after:$after,filter:$filter){pageInfo{hasNextPage} nodes{identifier description}}}'
  vars="$(jq -n --argjson f "$filter" '{filter:$f}')" \
    || { torc_err "fetch_open_orders: fallo construyendo vars"; return 1; }
  resp="$(linear_api "$Q" "$vars")" \
    || { torc_err "fetch_open_orders: fallo linear_api — ESCALAR"; return 1; }
  # Fail-closed: exigir .errors ausente/vacio Y .data.issues presente. jq -e '.data.issues' SOLO no basta
  # porque GraphQL puede dar data parcial con .errors.
  printf '%s' "$resp" | jq -e '((.errors // []) | length) == 0 and (.data.issues != null)' >/dev/null 2>&1 \
    || { torc_err "fetch_open_orders: respuesta invalida o con .errors — ESCALAR"; return 1; }
  # Fail-closed ante truncacion: NUNCA interpretar una lista truncada como 'no hay ordenes'.
  [ "$(printf '%s' "$resp" | jq -r '.data.issues.pageInfo.hasNextPage // false')" != true ] \
    || { torc_err "fetch_open_orders: >250 ordenes abiertas — lista truncada; ESCALAR"; return 1; }
  printf '%s' "$resp" | jq -c '.data.issues.nodes[]?' \
    || { torc_err "fetch_open_orders: fallo extrayendo nodes"; return 1; }
}

# ---------------------------------------------------------------------------
# [TAL-1568] Decision pre-create TRI-STATE. NO llama exit/torc_die (llamar exit desde una funcion
# sourceada mataria al caller y romperia tests). Imprime UN token estable y devuelve un codigo:
#   return 0 + token en stdout, exactamente uno de:
#     "create"           -> limpio, crear la orden
#     "noop <TAL-id>"     -> idempotency-key ya presente en una orden abierta -> NO crear
#     "block <TAL-id>"    -> ya hay orden abierta del coordinador (sin --allow-multiple)
#     "overlap <ids>"     -> issues del batch ya reservadas en otra orden abierta
#   return != 0          -> fallo DURO de fetch/validacion -> el caller ESCALA. Incluye 'reserva no
#                           verificable': una orden abierta cuyo bloque json esta corrupto O ausente/vacio.
#   Precedencia: noop > overlap > block > create (re-ejecutar el MISMO batch da noop, no block).
# torc_precreate_check <coord_project_id> <agent_instr_label> <coord_label> <idem_key> <"TAL-1 TAL-2"> <allow_multiple:yes|no>
# ---------------------------------------------------------------------------
torc_precreate_check() {
  local pid="$1" ai="$2" coord="$3" key="$4" ids="$5" allow="${6:-no}" open dup dup_ids reserved overlap coord_orders first_id line desc order_ids
  # ordenes abiertas con agent-instructions (reserva cross-coordinador). Base de (b) idempotencia y (c) solape.
  open="$(torc_fetch_open_orders "$pid" "$ai")" || return 1
  # (b) idempotencia PRIMERO: re-ejecutar el MISMO batch (misma key ya presente) es noop, no block.
  # Comparacion LITERAL con `contains` (NO `test`, que trata $k como REGEX: una idempotency-key con
  # metacaracteres — p.ej. 'idem[1' — romperia la regex de jq o casaria la orden equivocada). FAIL-CLOSED:
  # si jq erra, `dup` es INDETERMINADO -> ESCALAR (no caer a create). El `head -1` va en una asignacion
  # aparte, NO en el pipe de jq: encadenar `| head` induciria SIGPIPE sobre jq y, con pipefail, un exit
  # no-cero espurio que enmascararia el fail-closed.
  dup_ids="$(printf '%s' "$open" | jq -r --arg k "$key" 'select((.description//"")|contains($k))|.identifier' 2>/dev/null)" \
    || { torc_err "precreate_check: fallo evaluando idempotencia (jq) — ESCALAR"; return 1; }
  dup="$(printf '%s' "$dup_ids" | head -1)"
  if [ -n "$dup" ]; then printf 'noop %s\n' "$dup"; return 0; fi
  # (c) solape FAIL-CLOSED, POR ORDEN: CADA orden abierta con agent-instructions DEBE rendir un bloque
  # json parseable con >=1 issue_id. Si una NO lo tiene — corrupto O ausente/vacio (orden legacy/manual
  # mal formada) — su reserva NO es verificable -> ESCALAR. NO tratar 'reserva ilegible' como 'cola limpia'.
  # (Lista de ordenes VACIA sí es cola limpia: el while no itera y no escala.) `<<<` corre en el shell
  # actual (no subshell) para que `reserved`/`return` persistan; `torc_extract_issue_ids` es el ultimo
  # comando del pipe -> su exit se captura sin depender de `pipefail` del caller.
  reserved=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    desc="$(printf '%s' "$line" | jq -r '.description // empty' 2>/dev/null)" \
      || { torc_err "precreate_check: fallo leyendo descripcion de una orden abierta — ESCALAR"; return 1; }
    order_ids="$(printf '%s' "$desc" | torc_extract_issue_ids)" \
      || { torc_err "precreate_check: reserva no verificable (json de una orden abierta corrupto) — ESCALAR"; return 1; }
    [ -n "$order_ids" ] \
      || { torc_err "precreate_check: orden abierta sin bloque machine-readable verificable — ESCALAR"; return 1; }
    reserved="$reserved$order_ids"$'\n'
  done <<< "$open"
  overlap="$(printf '%s' "$reserved" | sort -u | grep -Fxf <(printf '%s\n' $ids) 2>/dev/null | paste -sd' ' -)"
  if [ -n "$overlap" ]; then printf 'overlap %s\n' "$overlap"; return 0; fi
  # (a) guard por coordinador: si no es dup/overlap y ya hay orden abierta del coordinador (AMBOS labels:
  # agent-instructions AND coord-<x>) -> block. --allow-multiple salta SOLO este guard.
  if [ "$allow" != yes ]; then
    coord_orders="$(torc_fetch_open_orders "$pid" "$ai" "$coord")" || return 1
    first_id="$(printf '%s' "$coord_orders" | jq -r '.identifier' 2>/dev/null | head -1)"
    if [ -n "$first_id" ]; then printf 'block %s\n' "$first_id"; return 0; fi
  fi
  printf 'create\n'; return 0
}

# ---------------------------------------------------------------------------
# [TAL-1568] Router PURO (sin efectos) de la decision pre-create -> accion para el caller.
# torc_route_precreate <token-line> <rc>   ; stdout: PROCEED | SKIP | ABORT:<motivo>
#   rc != 0 -> ABORT (fallo duro) ; create -> PROCEED ; noop -> SKIP ; block/overlap -> ABORT ;
#   cualquier token inesperado -> ABORT (fail-closed).
# ---------------------------------------------------------------------------
torc_route_precreate() {
  local token="$1" rc="${2:-1}" verb
  [ "$rc" = 0 ] || { printf 'ABORT:fallo-duro\n'; return 0; }
  verb="${token%% *}"
  case "$verb" in
    create)  printf 'PROCEED\n' ;;
    noop)    printf 'SKIP\n' ;;
    block)   printf 'ABORT:orden-abierta\n' ;;
    overlap) printf 'ABORT:solape\n' ;;
    *)       printf 'ABORT:token-inesperado\n' ;;
  esac
}

# ---------------------------------------------------------------------------
# [BLOQUEANTE 1] Idempotency key determinista (schema_version + coordinador + issue_ids ordenados).
# torc_idem_key <coordinador> <"TAL-1 TAL-2 ...">
# ---------------------------------------------------------------------------
torc_idem_key() {
  local coord="$1" ids="$2"
  { printf '%s\n%s\n' "$TORC_SCHEMA_VERSION" "$coord"; printf '%s\n' $ids | sed '/^$/d' | sort -u; } \
    | sha1sum | cut -d' ' -f1
}

# ---------------------------------------------------------------------------
# [MAYOR 3] Contrato de setup completo (fail-closed). Lista de variables requeridas + faltantes.
# ---------------------------------------------------------------------------
torc_required_setup_vars() {
  printf '%s\n' TORC_COORD_PROJECT_ID TORC_REGISTRY_ISSUE_ID \
    TORC_STATE_TODO TORC_STATE_WORKING TORC_STATE_NEEDS_INPUT TORC_STATE_DONE \
    TORC_LABEL_AGENT_INSTR TORC_LABEL_REGISTRY TORC_LABEL_VERTICAL TORC_LABEL_ACTOR_AI
}
torc_missing_setup() { local v; while read -r v; do [ -n "${!v:-}" ] || printf '%s\n' "$v"; done < <(torc_required_setup_vars); }

# [BLOQUEANTE 1] Extrae repo + #canales dev de la cuadrilla. stdin = TSV de registry.sh.
# stdout: "repo<TAB>devcount"  (repo vacio y/o devcount 0 => coordinador sin cuadrilla valida)
torc_crew_repo() { awk -F'\t' 'NF>=7{ if(repo=="")repo=$7; if($5 ~ /dev/)d++ } END{ printf "%s\t%d\n", repo, d+0 }'; }

# ---------------------------------------------------------------------------
# Locks atomicos (guard de instancia unica del orquestador). mkdir + PID/ts; stale por PID/TTL.
# ---------------------------------------------------------------------------
torc_lock_acquire() {
  local ttl="${2:-$TORC_LOCK_TTL}" d="$TORC_LOCK_DIR/$1.lock" owner pid ts now
  mkdir -p "$TORC_LOCK_DIR"
  if mkdir "$d" 2>/dev/null; then printf '%s %s' "$$" "$(date +%s)" > "$d/owner"; return 0; fi
  owner="$(cat "$d/owner" 2>/dev/null)"; pid="${owner%% *}"; ts="${owner##* }"; now="$(date +%s)"
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    rm -rf "$d"; mkdir "$d" 2>/dev/null && { printf '%s %s' "$$" "$now" > "$d/owner"; return 0; }
  fi
  if [ -n "$ts" ] && [ "$((now - ts))" -gt "$ttl" ]; then
    rm -rf "$d"; mkdir "$d" 2>/dev/null && { printf '%s %s' "$$" "$now" > "$d/owner"; return 0; }
  fi
  return 1
}
# Libera SOLO si el lock es nuestro (PID == $$). No pisamos locks de otros procesos.
torc_lock_release() {
  local d="$TORC_LOCK_DIR/$1.lock" owner pid
  owner="$(cat "$d/owner" 2>/dev/null)"; pid="${owner%% *}"
  [ -z "$pid" ] || [ "$pid" = "$$" ] || return 0
  rm -rf "$d" 2>/dev/null
}
