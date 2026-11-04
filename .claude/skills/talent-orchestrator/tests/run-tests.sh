#!/usr/bin/env bash
# run-tests.sh — Tests de funciones PURAS de talent-orchestrator (sin red, sin Linear).
# Sale 0 si todo pasa.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$HERE/../scripts"
TORC_SECRET_DIR="$(mktemp -d)"; export TORC_SECRET_DIR
export TCO_MODELOS_REGISTRO="$TORC_SECRET_DIR/modelos.conf"
printf 'OPUS_MODEL="claude-%s-%s"\nSONNET_MODEL="claude-%s-%s"\nRESOLVED_UTC="2026-10-04T00:00:00Z"\nCLI_VERSION="2.1.289"\n' opus 4-8 sonnet 5 > "$TCO_MODELOS_REGISTRO"
export TORC_LOCK_DIR="$TORC_SECRET_DIR/locks"
# [TAL-8037/C2] Identidad NEUTRA del arnés: clave de Linear ABC (≠ TAL), sin ids de ninguna casa.
export TF_LINEAR_TEAM_KEY=ABC
# shellcheck source=/dev/null
. "$SC/00-config.sh"
# shellcheck source=/dev/null
. "$SC/lib.sh"
# shellcheck source=/dev/null
. "$SC/lib-torre.sh"

PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf '  FAIL %s: esperaba [%s] obtuvo [%s]\n' "$1" "$3" "$2"; fi; }
rc(){ "$@" >/dev/null 2>&1 && echo 0 || echo 1; }

echo "== validadores =="
ok "uuid ok"      "$(rc torc_is_uuid 00000000-0000-4000-8000-000000000005)" 0
ok "uuid malo"    "$(rc torc_is_uuid no-uuid)" 1
ok "issue ok (clave ABC)" "$(rc torc_is_tal ABC-1497)" 0
ok "issue malo"   "$(rc torc_is_tal ABC-x)" 1
ok "coord ok"     "$(rc torc_is_coord coord-talent)" 0
ok "coord malo"   "$(rc torc_is_coord Coord_Talent)" 1
ok "channel ok"   "$(rc torc_is_channel vibe-channel-01)" 0
ok "channel malo" "$(rc torc_is_channel vibe-channel-)" 1
ok "repo ok"      "$(rc torc_is_repo org-ejemplo/producto)" 0
ok "repo malo"    "$(rc torc_is_repo 'a b/c')" 1

echo "== normalizacion de canal =="
ok "container<-id"   "$(torc_to_container 01)" "vibe-channel-01"
ok "container idemp"  "$(torc_to_container vibe-channel-03)" "vibe-channel-03"
ok "id<-container"   "$(torc_to_channel_id vibe-channel-05)" "05"
ok "id idemp"        "$(torc_to_channel_id 05)" "05"

echo "== orden de prioridad (urgent primero, None al final) =="
ord="$(printf '3\tTAL-3\n1\tTAL-1\n0\tTAL-0\n2\tTAL-2\n' | torc_order_by_priority | paste -sd, -)"
ok "prioridad" "$ord" "TAL-1,TAL-2,TAL-3,TAL-0"

echo "== topo-sort + ciclos =="
nodes="$(mktemp)"; edges="$(mktemp)"
printf 'TAL-1\nTAL-2\nTAL-3\n' > "$nodes"
printf 'TAL-2\tTAL-1\nTAL-3\tTAL-2\n' > "$edges"   # 2 dep de 1; 3 dep de 2  -> 1,2,3
ok "topo orden"  "$(torc_toposort "$nodes" "$edges" | paste -sd, -)" "TAL-1,TAL-2,TAL-3"
ok "topo sin ciclo rc" "$(rc torc_toposort "$nodes" "$edges")" 0
printf 'TAL-1\tTAL-2\nTAL-2\tTAL-1\n' > "$edges"   # ciclo
torc_toposort "$nodes" "$edges" >/dev/null 2>&1; ok "ciclo -> exit2" "$?" 2
rm -f "$nodes" "$edges"

echo "== exclusion de reserva =="
res="$(mktemp)"; printf 'TAL-2\nTAL-9\n' > "$res"
ok "exclude" "$(printf 'TAL-1\nTAL-2\nTAL-3\n' | torc_exclude "$res" | paste -sd, -)" "TAL-1,TAL-3"
: > "$res"   # reserva VACIA: debe conservar TODOS (regresion del bug FNR==NR)
ok "exclude vacio" "$(printf 'TAL-1\nTAL-2\nTAL-3\n' | torc_exclude "$res" | paste -sd, -)" "TAL-1,TAL-2,TAL-3"
rm -f "$res"

echo "== parse del registro (tabla cercada, sin secretos) =="
body="$(printf '%s\n' 'Inventario' '```' \
  '| channel | machine | hwclass | role | coordinador | repo |' \
  '|---|---|---|---|---|---|' \
  '| vibe-channel-01 | m0 | cpu | dev | coord-talent | Producto-2.0 |' \
  '| vibe-channel-05 | m0 | gpu | audit | coord-talent | Producto-2.0 |' \
  '```' 'fin')"
rows="$(printf '%s' "$body" | torc_registry_rows)"
ok "registro nfilas"  "$(printf '%s\n' "$rows" | grep -c .)" "2"
ok "registro col1"    "$(printf '%s\n' "$rows" | head -1 | cut -f1)" "vibe-channel-01"
ok "registro coord"   "$(printf '%s\n' "$rows" | head -1 | cut -f5)" "coord-talent"
ok "registro filtra"  "$(printf '%s\n' "$rows" | awk -F'\t' '$3=="gpu"{print $1}')" "vibe-channel-05"

echo "== orden de trabajo: JSON machine-readable parseable =="
oj="$(torc_build_order_json coord-talent 00000000-0000-4000-8000-000000000005 org-ejemplo/producto 'TAL-1217 TAL-1238' '[["TAL-1217","TAL-1238"]]')"
ok "json parseable"   "$(printf '%s' "$oj" | jq -r '.coordinador')" "coord-talent"
ok "json issue_ids"   "$(printf '%s' "$oj" | jq -rc '.issue_ids')" '["TAL-1217","TAL-1238"]'
ok "json schema_ver"  "$(printf '%s' "$oj" | jq -r '.schema_version')" "1"
ok "json precedence"  "$(printf '%s' "$oj" | jq -rc '.precedence')" '[["TAL-1217","TAL-1238"]]'

echo "== [TAL-1974] guard estatico anti-divergencia: orchestrate.sh <-> work-order.tmpl =="
# (1) el CONSUMIDOR invoca el helper — si el cableado se deshace en silencio, esto lo detecta.
# ANCLADO a linea EJECUTABLE (excluye comentarios con '#'): un grep -q suelto tambien casaria con
# el comentario de arriba (linea que documenta el cableado) aunque la llamada real desaparezca —
# la suite seguiria verde con el consumidor roto. Filtrar primero las lineas de comentario.
ok "orchestrate invoca torc_render_order_body (linea ejecutable)" \
  "$(rc bash -c "grep -v '^[[:space:]]*#' '$SC/orchestrate.sh' | grep -q 'torc_render_order_body'")" 0
# (2) el printf inline duplicado de antes de TAL-1974 NO reaparecio en orchestrate.sh — su firma
# literal (con el placeholder %s, exclusiva del formato viejo; NO confundir con la frase de la
# cabecera del script, que tambien dice "no hay consumidor automatico" y SI debe seguir ahi) debe
# vivir SOLO en assets/work-order.tmpl.
inline_hits="$(grep -c 'Orden de trabajo para \*\*%s\*\*' "$SC/orchestrate.sh")"
ok "printf inline ausente en orchestrate.sh" "$inline_hits" "0"
# (3) fidelidad del render: cero placeholders residuales, invariantes presentes, sin fuga de
# last_verified (vive como comentario de codigo en lib.sh, NUNCA dentro del .tmpl ni del body).
rendered="$(torc_render_order_body 'coord-guard' 'org/repo-guard' '1) TAL-9999' 'Needs Input' '{"ok":true}')"
ok "render: sin placeholders residuales" "$(printf '%s' "$rendered" | grep -cE '__[A-Z_]+__')" "0"
ok "render: contrato dispatch.sh"        "$(printf '%s' "$rendered" | grep -c 'dispatch.sh <carril> <TAL-id>')" "1"
ok "render: DoD reconciliado"            "$(printf '%s' "$rendered" | grep -c 'verify-handoff.sh == 0')" "1"
ok "render: fence json"                  "$(printf '%s' "$rendered" | grep -c '^```json$')" "1"
ok "render: sin fuga de last_verified"   "$(printf '%s' "$rendered" | grep -c 'last_verified')" "0"

echo "== extraccion de issue_ids del cuerpo de una orden =="
order_body="$(printf '%s\n' 'prosa' '```json' "$oj" '```' 'cierre')"
ok "extract ids" "$(printf '%s' "$order_body" | torc_extract_issue_ids | paste -sd, -)" "TAL-1217,TAL-1238"

echo "== idempotency key (determinista, independiente del orden) =="
k1="$(torc_idem_key coord-talent 'TAL-1238 TAL-1217')"
k2="$(torc_idem_key coord-talent 'TAL-1217 TAL-1238')"
ok "idem estable"   "$k1" "$k2"
k3="$(torc_idem_key coord-other 'TAL-1217 TAL-1238')"
ok "idem distingue coord" "$([ "$k1" != "$k3" ] && echo dif || echo igual)" "dif"

echo "== contrato de setup (fail-closed) [MAYOR 3] =="
# [CR] La mutacion de entorno va DENTRO del $(...) (subshell que la aisla del padre); 'ok' corre en
# el shell PADRE para que PASS/FAIL persistan. Con el ( ... ) externo previo, los incrementos de 'ok'
# vivian en el subshell y se perdian -> el suite podia salir VERDE pese a una regresion real de
# torc_missing_setup (justo el contrato fail-closed que este bloque valida).
v="$(unset TORC_COORD_PROJECT_ID TORC_REGISTRY_ISSUE_ID TORC_STATE_TODO TORC_STATE_WORKING \
           TORC_STATE_NEEDS_INPUT TORC_STATE_DONE TORC_LABEL_AGENT_INSTR TORC_LABEL_REGISTRY \
           TORC_LABEL_VERTICAL TORC_LABEL_ACTOR_AI
     torc_missing_setup | wc -l | tr -d ' ')"
ok "todas faltan" "$v" "10"
v="$(export TORC_COORD_PROJECT_ID=x TORC_REGISTRY_ISSUE_ID=x TORC_STATE_TODO=x TORC_STATE_WORKING=x \
            TORC_STATE_NEEDS_INPUT=x TORC_STATE_DONE=x TORC_LABEL_AGENT_INSTR=x TORC_LABEL_REGISTRY=x \
            TORC_LABEL_VERTICAL=x; unset TORC_LABEL_ACTOR_AI
     torc_missing_setup)"
ok "falta solo actor/ai" "$v" "TORC_LABEL_ACTOR_AI"

echo "== cuadrilla: repo + #dev [BLOQUEANTE 1] =="
crew="$(printf '%s\n' \
  '01\tvibe-channel-01\tm0\tcpu\tdev\tcoord-talent\tte/Repo' \
  '05\tvibe-channel-05\tm0\tgpu\taudit-ciber\tcoord-talent\tte/Repo')"
ok "crew repo"  "$(printf '%b\n' "$crew" | torc_crew_repo | cut -f1)" "te/Repo"
ok "crew devs"  "$(printf '%b\n' "$crew" | torc_crew_repo | cut -f2)" "1"
ok "crew vacio devs" "$(printf '' | torc_crew_repo | cut -f2)" "0"

echo "== lock release solo por dueno [minor] =="
torc_lock_acquire L1 >/dev/null
printf '999999 1' > "$TORC_LOCK_DIR/L1.lock/owner"   # simular otro dueno (PID ajeno)
torc_lock_release L1; ok "no libera ajeno" "$([ -d "$TORC_LOCK_DIR/L1.lock" ] && echo existe || echo no)" "existe"
printf '%s 1' "$$" > "$TORC_LOCK_DIR/L1.lock/owner"  # ahora soy yo
torc_lock_release L1; ok "libera propio" "$([ -d "$TORC_LOCK_DIR/L1.lock" ] && echo existe || echo no)" "no"

echo "== cascada de bloqueo transitivo [CR #4] =="
cf="$(mktemp)"; ef="$(mktemp)"
printf 'B\nC\nD\n' > "$cf"               # cands: B,C,D (A ya excluida como blocked, ausente)
printf 'B\tA\nC\tB\nD\tE\n' > "$ef"      # B dep A(ausente); C dep B; D dep E(ausente)
ok "cascada transitiva" "$(torc_cascade_blocked "$cf" "$ef" | paste -sd, -)" "B,C,D"
printf 'X\nY\n' > "$cf"; printf 'Y\tX\n' > "$ef"   # X presente, Y dep X presente -> nada se bloquea
ok "cascada sin huerfanos" "$(torc_cascade_blocked "$cf" "$ef" | paste -sd, -)" ""
rm -f "$cf" "$ef"

echo "== [TAL-3265 r6] truncacion de relaciones: fail-closed SOLO si hasNextPage=true =="
# Regresion del NO-GO r1: select-work.sh solo miraba length>=50 sin pedir/consultar
# relations.pageInfo.hasNextPage -> exactamente 50 relaciones (el total real, sin mas paginas)
# se rechazaba como falso positivo. torc_relations_truncated es la funcion pura que arbitra.
_mkrel() { # id count hasNextPage(true|false|missing)
  local id="$1" n="$2" hnp="$3"
  if [ "$hnp" = "missing" ]; then
    jq -nc --arg id "$id" --argjson n "$n" '{identifier:$id, relations:{nodes:[range($n)]}}'
  else
    jq -nc --arg id "$id" --argjson n "$n" --argjson hnp "$hnp" \
      '{identifier:$id, relations:{nodes:[range($n)], pageInfo:{hasNextPage:$hnp}}}'
  fi
}
relf="$(mktemp)"
{ _mkrel TAL-1 50 true; _mkrel TAL-2 50 false; _mkrel TAL-3 3 true; _mkrel TAL-4 50 missing; } > "$relf"
ok "50+hasNextPage=true -> truncada (dispara)" "$(torc_relations_truncated < "$relf" | paste -sd, -)" "TAL-1"
ok "exactamente 50 sin pagina siguiente -> NO truncada (total real)" \
  "$(_mkrel TAL-9 50 false | torc_relations_truncated)" ""
ok "menos de 50 nunca truncada aunque hasNextPage=true" \
  "$(_mkrel TAL-8 3 true | torc_relations_truncated)" ""
ok "pageInfo ausente (defensivo, query vieja) -> NO truncada" \
  "$(_mkrel TAL-7 50 missing | torc_relations_truncated)" ""
rm -f "$relf"

# ===========================================================================
# [TAL-1568] Pre-create: fetch fail-closed + decision tri-state + router puro.
# Se stubbea linear_api (funcion sourceable) para probar SIN red. El wiring real del `case` en
# orchestrate.sh queda cubierto por: el router puro (abajo, tabla completa) + `bash -n` + shellcheck +
# el smoke `--dry-run`. Un doble-stub por subproceso no es viable aqui (orchestrate.sh re-sourcea lib.sh
# y pisaria un stub de funcion; un mock a nivel curl exigiria simular TODO el preflight).
# ===========================================================================
UUID_OK="00000000-0000-4000-8000-000000000005"
STUB_JSON=''; STUB_FAIL=0
linear_api() { [ "${STUB_FAIL:-0}" = 1 ] && return 1; printf '%s' "$STUB_JSON"; }   # override: sin red
mk_resp()   { jq -n --argjson nodes "$1" --argjson hn "${2:-false}" '{data:{issues:{pageInfo:{hasNextPage:$hn}, nodes:$nodes}}}'; }
node_desc() { jq -n --arg id "$1" --arg d "$2" '{identifier:$id, description:$d}'; }
blk_desc()  { printf 'prosa %s\n```json\n%s\n```\n' "${2:-}" "$(jq -n --argjson x "$1" '{issue_ids:$x}')"; }
bad_desc()  { printf 'prosa\n```json\n{bad json no parseable\n```\n'; }   # bloque json corrupto

echo "== [TAL-1568] fetch fail-closed de ordenes abiertas =="
STUB_JSON="$(mk_resp "[$(node_desc TAL-900 x)]" false)"
ok "fetch a: 1 orden id"         "$(torc_fetch_open_orders "$UUID_OK" L1 | jq -r '.identifier')" "TAL-900"
ok "fetch a: rc0"                "$(rc torc_fetch_open_orders "$UUID_OK" L1)" 0
STUB_JSON="$(mk_resp '[]' false)"
ok "fetch b: vacio nfilas"       "$(torc_fetch_open_orders "$UUID_OK" L1 | grep -c .)" "0"
ok "fetch b: rc0"                "$(rc torc_fetch_open_orders "$UUID_OK" L1)" 0
STUB_JSON="$(jq -n '{data:{issues:{pageInfo:{hasNextPage:false},nodes:[]}}, errors:[{message:"boom"}]}')"
ok "fetch c: errors+data -> rc1" "$(rc torc_fetch_open_orders "$UUID_OK" L1)" 1
STUB_JSON='{"data":{}}'
ok "fetch d1: sin data.issues"   "$(rc torc_fetch_open_orders "$UUID_OK" L1)" 1
STUB_JSON='{bad json'
ok "fetch d2: malformado"        "$(rc torc_fetch_open_orders "$UUID_OK" L1)" 1
STUB_JSON="$(mk_resp "[$(node_desc TAL-901 x)]" true)"
ok "fetch e: hasNextPage -> rc1" "$(rc torc_fetch_open_orders "$UUID_OK" L1)" 1
STUB_FAIL=1
ok "fetch f: api-fail -> rc1"    "$(rc torc_fetch_open_orders "$UUID_OK" L1)" 1
STUB_FAIL=0

echo "== [TAL-1568] decision pre-create tri-state =="
KEY="deadbeefkey"
# block: orden abierta del coordinador con bloque valido NO solapado (TAL-99) + sin la key -> block.
STUB_JSON="$(mk_resp "[$(node_desc TAL-900 "$(blk_desc '["TAL-99"]')")]" false)"
ok "precheck f: block"           "$(torc_precreate_check "$UUID_OK" AI COORD "$KEY" "TAL-1 TAL-2" no)"  "block TAL-900"
STUB_JSON="$(mk_resp '[]' false)"
ok "precheck k: create"          "$(torc_precreate_check "$UUID_OK" AI COORD "$KEY" "TAL-1 TAL-2" yes)" "create"
STUB_JSON="$(mk_resp "[$(node_desc TAL-905 "lleva la key $KEY dentro")]" false)"
ok "precheck g+h: allow->noop"   "$(torc_precreate_check "$UUID_OK" AI COORD "$KEY" "TAL-1 TAL-2" yes)" "noop TAL-905"
STUB_JSON="$(mk_resp "[$(node_desc TAL-906 "$(blk_desc '["TAL-1"]')")]" false)"
ok "precheck i: allow->overlap"  "$(torc_precreate_check "$UUID_OK" AI COORD "$KEY" "TAL-1 TAL-2" yes)" "overlap TAL-1"
STUB_JSON="$(jq -n '{errors:[{message:"boom"}]}')"
ok "precheck j: hard-fail rc!=0" "$(rc torc_precreate_check "$UUID_OK" AI COORD "$KEY" "TAL-1 TAL-2" yes)" 1
# reserva NO verificable: una orden abierta con bloque json corrupto -> fail-closed (rc!=0), NUNCA create.
STUB_JSON="$(mk_resp "[$(node_desc TAL-907 "$(bad_desc)")]" false)"
ok "precheck l: json corrupto -> rc!=0" "$(rc torc_precreate_check "$UUID_OK" AI COORD "$KEY" "TAL-1 TAL-2" yes)" 1
# reserva NO verificable: orden abierta SIN bloque machine-readable (legacy/manual) -> fail-closed, NUNCA create.
STUB_JSON="$(mk_resp "[$(node_desc TAL-909 "orden vieja sin bloque machine-readable")]" false)"
ok "precheck n: sin bloque -> rc!=0" "$(rc torc_precreate_check "$UUID_OK" AI COORD "$KEY" "TAL-1 TAL-2" yes)" 1
# idempotency-key con METACARACTERES de regex (CR: 'idem[1' rompe test() pero contains() literal funciona):
# comparacion literal -> NO crashea. Presente en una orden abierta -> noop; ausente -> create.
METAKEY='idem[1'
STUB_JSON="$(mk_resp "[$(node_desc TAL-910 "lleva la key $METAKEY literal en la orden")]" false)"
ok "precheck o: metakey presente -> noop" "$(torc_precreate_check "$UUID_OK" AI COORD "$METAKEY" "TAL-1 TAL-2" yes)" "noop TAL-910"
STUB_JSON="$(mk_resp "[$(node_desc TAL-911 "$(blk_desc '["TAL-77"]')")]" false)"
ok "precheck p: metakey ausente -> create" "$(torc_precreate_check "$UUID_OK" AI COORD "$METAKEY" "TAL-1 TAL-2" yes)" "create"
# precedencia noop>block: re-ejecutar el MISMO batch (key presente) con allow=no da noop, NO block.
STUB_JSON="$(mk_resp "[$(node_desc TAL-908 "lleva la key $KEY dentro")]" false)"
ok "precheck m: mismo batch -> noop (no block)" "$(torc_precreate_check "$UUID_OK" AI COORD "$KEY" "TAL-1 TAL-2" no)" "noop TAL-908"

echo "== [TAL-1568] router puro de decision (fail-closed default) =="
ok "route create"   "$(torc_route_precreate 'create' 0)"              "PROCEED"
ok "route noop"     "$(torc_route_precreate 'noop TAL-1' 0)"          "SKIP"
ok "route block"    "$(torc_route_precreate 'block TAL-1' 0)"         "ABORT:orden-abierta"
ok "route overlap"  "$(torc_route_precreate 'overlap TAL-1 TAL-2' 0)" "ABORT:solape"
ok "route rc!=0"    "$(torc_route_precreate 'create' 1)"              "ABORT:fallo-duro"
ok "route raro"     "$(torc_route_precreate 'weird' 0)"               "ABORT:token-inesperado"
ok "route vacio"    "$(torc_route_precreate '' 0)"                    "ABORT:token-inesperado"

# ===========================================================================
# [TAL-2278] Torre de Control — funciones puras de lib-torre.sh
# ===========================================================================
E="$(printf '\033')"   # fixtures ANSI sinteticos (capturas con -e)
xrc(){ "$@" >/dev/null 2>&1; echo $?; }   # rc EXACTO (pick_live/extract_handoff tienen semantica 2/3/4)

echo "== torre: nombre de sesion =="
ok "sesion ok"      "$(torc_torre_session mergeador)" "torre-mergeador"
ok "sesion idemp"   "$(torc_torre_session torre-c1)" "torre-c1"
ok "sesion mala rc" "$(rc torc_torre_session 'Mer geador')" 1
ok "sesion vacia"   "$(rc torc_torre_session '')" 1

echo "== torre: input_state (ghost dim vs cola real vs texto — captura -e) =="
GHOST_FIX="$(printf '│ > %s[2m/exit%s[22m │\n' "$E" "$E")"                     # /exit FANTASMA (autocomplete dim)
TEXT_FIX='│ > hola mundo │'
EMPTY_FIX='│ > │'
QUEUED_FIX="$(printf '│ > │\n Press up to edit queued messages\n')"           # cola REAL (brillo pleno)
QUEUED_DIM="$(printf '│ > │\n%s[2m Press up to edit queued messages%s[22m\n' "$E" "$E")"
ok "ghost dim"      "$(printf '%s\n' "$GHOST_FIX"  | torc_torre_input_state)" "ghost"
ok "texto real"     "$(printf '%s\n' "$TEXT_FIX"   | torc_torre_input_state)" "text"
ok "vacio"          "$(printf '%s\n' "$EMPTY_FIX"  | torc_torre_input_state)" "empty"
ok "cola real"      "$(printf '%s\n' "$QUEUED_FIX" | torc_torre_input_state)" "queued"
ok "cola en dim NO es cola" "$(printf '%s\n' "$QUEUED_DIM" | torc_torre_input_state)" "empty"
ok "sin composer"   "$(printf 'salida cualquiera\n' | torc_torre_input_state)" "empty"
# [NO-GO codigo #2] texto real SOLO en una linea de continuacion del composer: detectarlo evita
# que relay_line limpie (clobbee) input pendiente del operador.
MULTI_TEXT="$(printf '│ > │\n│ texto solo en continuacion │\n╰────╯\n? for shortcuts\n')"
MULTI_GHOST="$(printf '│ > │\n│ %s[2mghost en continuacion%s[22m │\n' "$E" "$E")"
SOLO_BARRA="$(printf '│ > │\n╰────╯\n? for shortcuts · opus\n')"
ok "texto en continuacion" "$(printf '%s\n' "$MULTI_TEXT"  | torc_torre_input_state)" "text"
ok "ghost en continuacion" "$(printf '%s\n' "$MULTI_GHOST" | torc_torre_input_state)" "ghost"
ok "barra NO es contenido" "$(printf '%s\n' "$SOLO_BARRA"  | torc_torre_input_state)" "empty"

echo "== torre: post_paste_ok (match LITERAL, anti /exit fantasma) =="
PASTE_OK="$(printf '│ > lee a+b.txt e incorporalo │\n')"                       # token con metacaracter regex
PASTE_GHOST="$(printf '│ > %s[2mlee a+b.txt%s[22m │\n' "$E" "$E")"             # token SOLO como ghost
PASTE_OTRO="$(printf '│ > /exit │\n')"                                          # contenido real distinto
ok "paste ok"          "$(printf '%s\n' "$PASTE_OK"    | torc_torre_post_paste_ok 'lee a+b.txt')" "ok"
ok "paste ok rc"       "$(printf '%s\n' "$PASTE_OK"    | xrc torc_torre_post_paste_ok 'lee a+b.txt')" 0
ok "token solo ghost"  "$(printf '%s\n' "$PASTE_GHOST" | torc_torre_post_paste_ok 'lee a+b.txt')" "mismatch"
ok "token solo ghost rc" "$(printf '%s\n' "$PASTE_GHOST" | xrc torc_torre_post_paste_ok 'lee a+b.txt')" 1
ok "contenido distinto" "$(printf '%s\n' "$PASTE_OTRO"  | torc_torre_post_paste_ok 'lee a+b.txt')" "mismatch"
# texto largo partido por el box del TUI (padding + borde): el join normaliza espacios
PASTE_WRAP="$(printf '│ > lee archivo.txt e     │\n│   incorporalo ya        │\n')"
ok "paste wrapeado"    "$(printf '%s\n' "$PASTE_WRAP" | torc_torre_post_paste_ok 'lee archivo.txt e incorporalo ya')" "ok"

echo "== torre: ctx_pct (fail-closed UNKNOWN) =="
ok "ctx 42"       "$(printf 'opus · ctx: 42%% · ? for shortcuts\n' | torc_torre_ctx_pct)" "42"
ok "ctx ultimo"   "$(printf 'ctx: 10%%\nctx: 61%%\n' | torc_torre_ctx_pct)" "61"
ok "sin ctx rc"   "$(printf 'barra sin contexto\n' | xrc torc_torre_ctx_pct)" 1

echo "== torre: pick_live (rc EXACTOS 0/2/3; solo basenames UUID) =="
U1="00000000-0000-4000-8000-000000000007"; U2="00000000-0000-4000-8000-000000000010"
ok "un vivo"        "$(printf '999950\t/x/%s.jsonl\n990000\t/x/%s.jsonl\n' "$U1" "$U2" | torc_torre_pick_live 1000000 90)" "$U1"
ok "un vivo rc"     "$(printf '999950\t/x/%s.jsonl\n' "$U1" | xrc torc_torre_pick_live 1000000 90)" 0
ok "ninguno rc2"    "$(printf '990000\t/x/%s.jsonl\n' "$U1" | xrc torc_torre_pick_live 1000000 90)" 2
ok "ambiguo rc3"    "$(printf '999950\t/x/%s.jsonl\n999960\t/x/%s.jsonl\n' "$U1" "$U2" | xrc torc_torre_pick_live 1000000 90)" 3
ok "no-uuid rc2"    "$(printf '999990\t/x/notas.jsonl\n' | xrc torc_torre_pick_live 1000000 90)" 2
ok "mtime decimal"  "$(printf '999950.123\t/x/%s.jsonl\n' "$U1" | torc_torre_pick_live 1000000 90)" "$U1"
ok "args malos rc1" "$(printf '' | xrc torc_torre_pick_live abc 90)" 1

echo "== torre: extract_handoff (anti-stale por nonce; rc EXACTOS 0/2/4) =="
NON="torre_hf_1_aa"; VIEJO="torre_hf_0_zz"
HF_STALE_Y_ACTUAL="$(printf 'HANDOFF-INICIO %s\nESTADO VIEJO\nHANDOFF-FIN %s\nruido\nHANDOFF-INICIO %s\nESTADO ACTUAL\nHANDOFF-FIN %s\n' "$VIEJO" "$VIEJO" "$NON" "$NON")"
ok "stale ignorado"   "$(printf '%s\n' "$HF_STALE_Y_ACTUAL" | torc_torre_extract_handoff "$NON")" "ESTADO ACTUAL"
ok "solo stale rc2"   "$(printf 'HANDOFF-INICIO %s\nX\nHANDOFF-FIN %s\n' "$VIEJO" "$VIEJO" | xrc torc_torre_extract_handoff "$NON")" 2
ok "sin nonce rc2"    "$(printf 'HANDOFF-INICIO\nX\nHANDOFF-FIN\n' | xrc torc_torre_extract_handoff "$NON")" 2
HF_DOBLE="$(printf 'HANDOFF-INICIO %s\nPRIMERO\nHANDOFF-FIN %s\nHANDOFF-INICIO %s\nULTIMO\nHANDOFF-FIN %s\n' "$NON" "$NON" "$NON" "$NON")"
ok "doble -> ultimo"  "$(printf '%s\n' "$HF_DOBLE" | torc_torre_extract_handoff "$NON")" "ULTIMO"
ok "truncado rc4"     "$(printf 'HANDOFF-INICIO %s\nA MEDIAS\n' "$NON" | xrc torc_torre_extract_handoff "$NON")" 4
# [NO-GO codigo #1] el ULTIMO bloque del nonce truncado -> rc 4 fail-closed; JAMAS caer al bloque
# previo completo (seria compactar con un handoff stale/incompleto).
HF_ULTIMO_TRUNCO="$(printf 'HANDOFF-INICIO %s\nCOMPLETO VIEJO\nHANDOFF-FIN %s\nruido\nHANDOFF-INICIO %s\nA MEDIAS\n' "$NON" "$NON" "$NON")"
ok "ultimo trunco rc4 (no cae al previo)" "$(printf '%s\n' "$HF_ULTIMO_TRUNCO" | xrc torc_torre_extract_handoff "$NON")" 4
ok "ultimo trunco sin output" "$(printf '%s\n' "$HF_ULTIMO_TRUNCO" | torc_torre_extract_handoff "$NON" || true)" ""
ok "nonce invalido rc4" "$(printf 'x\n' | xrc torc_torre_extract_handoff 'malo;rm')" 4
NONCE_GEN="$(torc_torre_new_nonce)"
ok "nonce generado valido" "$(printf '%s' "$NONCE_GEN" | grep -qE '^torre_hf_[0-9]+_[0-9a-f]+$' && echo 0 || echo 1)" 0

echo "== torre: busy / usage (marcadores semanticos) =="
ok "busy"       "$(printf 'trabajando… esc to interrupt\n' | xrc torc_torre_busy_from)" 0
ok "idle"       "$(printf 'prompt en reposo\n' | xrc torc_torre_busy_from)" 1
ok "usage warn" "$(printf 'approaching weekly limit · resets at 3pm\n' | xrc torc_torre_usage_warn)" 0
ok "sin warn"   "$(printf 'todo normal\n' | xrc torc_torre_usage_warn)" 1

echo "== torre: validacion UUID (inyeccion jamas llega al pane) =="
ok "uuid inyeccion ;"  "$(rc torc_is_uuid '00000000-0000-4000-8000-000000000011;ls')" 1
ok "uuid inyeccion \$()" "$(rc torc_is_uuid '$(reboot)')" 1
ok "uuid backticks"    "$(rc torc_is_uuid '\`id\`')" 1
ok "uuid corto"        "$(rc torc_is_uuid 'aaaa-bbbb')" 1

echo "== [review PR #13] torc_load_tokens: REL del conf VALIDADA antes de leer (anti-traversal) =="
# Copia aislada del 00-config (BASH_SOURCE ancla repo-identity.conf al dir del script): permite
# inyectar confs malignos sin tocar el conf del repo. El archivo evil EXISTE fuera de HOST_HOME:
# si la validacion no corta ANTES de leer, el token EVIL se cargaria (ese era el hallazgo).
_P13O="$(mktemp -d)"; mkdir -p "$_P13O/sc" "$_P13O/home/sub dir" "$_P13O/evil" "$_P13O/s"
cp "$SC/00-config.sh" "$_P13O/sc/00-config.sh"
printf 'LINEAR_API_KEY=EVIL_FUERA_DE_HOME\n' > "$_P13O/evil/.env.local"
printf 'LINEAR_API_KEY=TOKEN_BUENO\n' > "$_P13O/home/sub dir/.env.local"
_p13o_run() { # <REL> — escribe el conf de la copia y corre torc_load_tokens en entorno limpio
  printf 'PKG_IDENTITY_PROJECT=x\nTORC_HOST_ENV_REL=%s\n' "$1" > "$_P13O/sc/repo-identity.conf"
  env -i PATH="$PATH" bash -c '
    unset LINEAR_API_KEY
    export HOST_HOME="$1/home" TORC_SECRET_DIR="$1/s" TORC_HOST_ENV=""
    . "$1/sc/00-config.sh"
    torc_load_tokens >/dev/null 2>&1; rc=$?
    printf "rc=%s key=%s" "$rc" "${LINEAR_API_KEY:-none}"
  ' _ "$_P13O"
}
ok "traversal ../ -> rc1 sin leer token"   "$(_p13o_run '../evil/.env.local')"        "rc=1 key=none"
ok "absoluta -> rc1 sin leer token"        "$(_p13o_run "$_P13O/evil/.env.local")"    "rc=1 key=none"
ok "backslash -> rc1"                      "$(_p13o_run 'a\b/.env.local')"            "rc=1 key=none"
ok "sufijo ajeno a /.env.local -> rc1"     "$(_p13o_run 'sub dir/otro.env')"          "rc=1 key=none"
ok "REL valida (con espacios) -> rc0+token" "$(_p13o_run 'sub dir/.env.local')"       "rc=0 key=TOKEN_BUENO"
echo "== [review PR #13, NO-GO-3] torc_load_tokens: canonicalización anti-symlink + contrato del override =="
# Bypass reproducido por el review: home/link -> dir FUERA de HOST_HOME pasaba la validación
# léxica y cargaba el token ajeno (ORC_SYMLINK rc=0). Ahora home y target se canonicalizan
# (realpath -e) y el target resuelto debe permanecer BAJO el home resuelto.
ln -s "$_P13O/evil" "$_P13O/home/link"
ok "symlink EXTERNO (home/link->fuera) -> rc1 sin leer token" "$(_p13o_run 'link/.env.local')" "rc=1 key=none"
mkdir -p "$_P13O/home/real"
printf 'LINEAR_API_KEY=TOKEN_INTERNO\n' > "$_P13O/home/real/.env.local"
ln -s real "$_P13O/home/lnk"
ok "symlink INTERNO (resuelve bajo home) -> rc0+token (sin sobre-cierre)" "$(_p13o_run 'lnk/.env.local')" "rc=0 key=TOKEN_INTERNO"
ok "override TORC_HOST_ENV RELATIVO -> rc1 (contrato: absoluta)" "$(env -i PATH="$PATH" bash -c '
    unset LINEAR_API_KEY
    export HOST_HOME="$1/home" TORC_SECRET_DIR="$1/s" TORC_HOST_ENV="relativa/x/.env.local"
    . "$1/sc/00-config.sh"
    torc_load_tokens >/dev/null 2>&1; rc=$?
    printf "rc=%s key=%s" "$rc" "${LINEAR_API_KEY:-none}"
  ' _ "$_P13O")" "rc=1 key=none"

rm -f "$_P13O/sc/repo-identity.conf"
ok "sin TORC_HOST_ENV y sin conf -> rc1 fail-closed" "$(env -i PATH="$PATH" bash -c '
    unset LINEAR_API_KEY
    export HOST_HOME="$1/home" TORC_SECRET_DIR="$1/s" TORC_HOST_ENV=""
    . "$1/sc/00-config.sh"
    torc_load_tokens >/dev/null 2>&1; rc=$?
    printf "rc=%s key=%s" "$rc" "${LINEAR_API_KEY:-none}"
  ' _ "$_P13O")" "rc=1 key=none"
rm -rf "$_P13O"

echo "== [TAL-8038] renderer clasico + barra ctx en torres (torre-resume / pozos-install-token-torre) =="
# Todo con dobles por PATH (tmux, sleep, claude) y HOME temporal: ningun tmux ni claude reales, ninguna espera real.
_T8="$(mktemp -d)"; mkdir -p "$_T8/shims" "$_T8/home/.claude" "$_T8/cwd" "$_T8/s/env"
_UU=00000000-0000-4000-8000-000000000012
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "${FAKE_CLAUDE_VER:-2.1.289} (Claude Code)"; else echo OK; fi\n' > "$_T8/shims/claude"
printf '#!/bin/sh\nexit 0\n' > "$_T8/shims/sleep"
# tmux doble: registra cada llamada; has-session -> NO existe (rc 1) salvo FAKE_TMUX_HAS=1; list-panes -> pane 0 de un pid inexistente;
# al PRIMER new-session/send-keys -l copia el settings.json de HOME (prueba «ya estaba listo ANTES de lanzar»).
cat > "$_T8/shims/tmux" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >> "$T8_LOG"
case "$1" in
  has-session) [ "${FAKE_TMUX_HAS:-0}" = 1 ] && exit 0 || exit 1 ;;
  list-panes) echo "0 ${FAKE_PANE_PID:-999999}"; exit 0 ;;
  new-session|send-keys)
    if [ ! -e "$T8_LOG.settings" ]; then cp "$HOME/.claude/settings.json" "$T8_LOG.settings" 2>/dev/null || echo ABSENT > "$T8_LOG.settings"; fi ;;
esac
exit 0
SHIM
chmod +x "$_T8/shims/"*
_t8env() { env -i TCO_MODELOS_REGISTRO="$TCO_MODELOS_REGISTRO" PATH="$_T8/shims:$PATH" HOME="$_T8/home" HOST_HOME="$_T8/home" TORC_SECRET_DIR="$_T8/s" SECRET_DIR="$_T8/s" \
  TORRE_CLAUDE_PROJECTS="$_T8/proj" T8_LOG="$_T8/tmux.log" FAKE_CLAUDE_VER="${FAKE_CLAUDE_VER:-2.1.289}" FAKE_TMUX_HAS="${FAKE_TMUX_HAS:-0}" FAKE_PANE_PID="${FAKE_PANE_PID:-999999}" "$@"; }
_slug="$(readlink -f "$_T8/cwd" | sed -E 's/[\/._]/-/g')"; mkdir -p "$_T8/proj/$_slug"
_t8reset() { rm -f "$_T8/tmux.log" "$_T8/tmux.log.settings" "$_T8/home/.claude/settings.json" "$_T8/home/.claude/statusline-ctx.sh"; }

# La salida de la barra del paquete la leen AMBOS parsers (contrato intacto: 92 / rc 1 sin dato — talent-context prueba el suyo)
_SLCTX="$SC/../../talent-context/assets/statusline-ctx.sh"
ok "barra del paquete (91.7) -> torc_torre_ctx_pct = 92" \
  "$(printf '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":91.7}}' | bash "$_SLCTX" | torc_torre_ctx_pct)" 92
ok "barra del paquete sin dato (null) -> torc_torre_ctx_pct rc 1 (jamas 0 ni 100)" \
  "$(printf '{"context_window":{"used_percentage":null}}' | bash "$_SLCTX" | xrc torc_torre_ctx_pct)" 1

# --dry-run: el comando lleva el env del renderer clasico y el bypass (invariante: IS_SANDBOX=1 ... --resume <uuid>)
_t8reset
_dry="$(_t8env bash "$SC/torre-resume.sh" mi-actor --cwd "$_T8/cwd" --uuid "$_UU" --dry-run 2>&1)"
ok "torre-resume --dry-run lleva CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 claude --dangerously-skip-permissions --resume" \
  "$(printf '%s' "$_dry" | grep -c 'CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 claude --dangerously-skip-permissions --resume '"$_UU")" 1
ok "torre-resume --dry-run conserva el bypass IS_SANDBOX=1 y el --resume <uuid>" \
  "$(printf '%s' "$_dry" | grep -c 'IS_SANDBOX=1 .*claude --dangerously-skip-permissions --resume '"$_UU")" 1
ok "torre-resume --dry-run NO escribe settings ni crea sesion" "$([ ! -e "$_T8/home/.claude/settings.json" ] && [ ! -e "$_T8/tmux.log" ] && echo si)" si

# lanzamiento real (doble de tmux): settings con tui+statusLine YA al llamar a new-session, y el comando lleva el env
_t8reset
_t8env bash "$SC/torre-resume.sh" mi-actor --cwd "$_T8/cwd" --uuid "$_UU" >/dev/null 2>&1; _rc=$?
ok "torre-resume lanza (rc 0) con el doble de tmux" "$_rc" 0
ok "torre-resume: al llamar a new-session settings ya tiene .tui=default y statusLine command" \
  "$(jq -e '.tui=="default" and .statusLine.type=="command"' "$_T8/tmux.log.settings" >/dev/null 2>&1 && echo si)" si
ok "torre-resume: el comando enviado al pane lleva el env del renderer clasico" \
  "$(grep -c 'send-keys .*-l.*CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 claude --dangerously-skip-permissions --resume '"$_UU" "$_T8/tmux.log")" 1
ok "torre-resume: la barra queda instalada y emite ctx:" \
  "$(printf '{"context_window":{"used_percentage":41}}' | bash "$_T8/home/.claude/statusline-ctx.sh")" "ctx: 41%"
# claude menor que la minima -> aborta ANTES de crear la sesion (fail-closed)
_t8reset
FAKE_CLAUDE_VER=2.1.277 _t8env bash "$SC/torre-resume.sh" mi-actor --cwd "$_T8/cwd" --uuid "$_UU" >/dev/null 2>&1; _rc=$?
ok "torre-resume: claude 2.1.277 -> aborta (rc!=0) sin new-session" "$([ "$_rc" -ne 0 ] && ! grep -q new-session "$_T8/tmux.log" 2>/dev/null && echo si)" si
# statusLine ajena: sin ctx legible -> aborta; con ctx legible -> sigue (y no la pisa)
_t8reset
printf '#!/bin/sh\ncat >/dev/null; echo "sin dato"\n' > "$_T8/home/mia.sh"; chmod +x "$_T8/home/mia.sh"
printf '{"statusLine":{"type":"command","command":"bash %s/mia.sh"}}\n' "$_T8/home" > "$_T8/home/.claude/settings.json"
_t8env bash "$SC/torre-resume.sh" mi-actor --cwd "$_T8/cwd" --uuid "$_UU" >/dev/null 2>&1; _rc=$?
ok "torre-resume: statusLine ajena SIN ctx -> aborta sin new-session" "$([ "$_rc" -ne 0 ] && ! grep -q new-session "$_T8/tmux.log" 2>/dev/null && echo si)" si
rm -f "$_T8/tmux.log" "$_T8/tmux.log.settings"
printf '#!/bin/sh\ncat >/dev/null; echo "mi barra ctx: 33%%"\n' > "$_T8/home/mia.sh"
_t8env bash "$SC/torre-resume.sh" mi-actor --cwd "$_T8/cwd" --uuid "$_UU" >/dev/null 2>&1; _rc=$?
ok "torre-resume: statusLine ajena CON ctx legible -> lanza y no la pisa" \
  "$([ "$_rc" -eq 0 ] && [ "$(jq -r .statusLine.command "$_T8/home/.claude/settings.json")" = "bash $_T8/home/mia.sh" ] && jq -e '.tui=="default"' "$_T8/tmux.log.settings" >/dev/null 2>&1 && echo si)" si

# pozos-install-token-torre.sh: mismo contrato (settings listos antes de relanzar; env en el comando; rc 8 si no se pueden dejar listos)
printf 'tok-de-prueba-no-real\n' > "$_T8/tok"; printf '%s\n' "$_UU" > "$_T8/s/env/torre-x.session"
_t8reset
FAKE_TMUX_HAS=1 _t8env bash "$SC/pozos-install-token-torre.sh" torre-x "$_T8/tok" >/dev/null 2>&1; _rc=$?
ok "pozos-install-token-torre: relanza (rc 0) con dobles" "$_rc" 0
ok "pozos-install-token-torre: settings con tui+statusLine ya listos al primer send-keys" \
  "$(jq -e '.tui=="default" and .statusLine.type=="command"' "$_T8/tmux.log.settings" >/dev/null 2>&1 && echo si)" si
ok "pozos-install-token-torre: el relanzamiento lleva el env del renderer clasico y --resume <uuid>" \
  "$(grep -c 'send-keys .*-l.*CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 claude --dangerously-skip-permissions --resume '"$_UU" "$_T8/tmux.log")" 1
_t8reset
FAKE_CLAUDE_VER=2.1.277 FAKE_TMUX_HAS=1 _t8env bash "$SC/pozos-install-token-torre.sh" torre-x "$_T8/tok" >/dev/null 2>&1; _rc=$?
ok "pozos-install-token-torre: claude 2.1.277 -> rc 8 sin tocar la terminal (ni un send-keys)" \
  "$([ "$_rc" -eq 8 ] && ! grep -q send-keys "$_T8/tmux.log" 2>/dev/null && echo si)" si
# El instalador corre ANTES del kill: con un CLI «vivo» (proceso señuelo hijo del pane, cmdline claude-decoy) un rc 8 del instalador
# deja la sesion VIVA; con el instalador correcto el relanzamiento si mata el CLI. (Mutacion: mover el instalador tras `kill "$C"`.)
_t8decoy() { bash -c 'bash -c "exec -a claude-decoy sleep 300" & wait' & _PP=$!
  for _i in 1 2 3 4 5 6 7 8 9 10; do _DC="$(pgrep -P "$_PP" 2>/dev/null | head -1)"; [ -n "$_DC" ] && break; command sleep 0.2; done; }
_t8decoy_stop() { kill "$_DC" "$_PP" 2>/dev/null; wait "$_PP" 2>/dev/null; }
_t8reset; _t8decoy
FAKE_PANE_PID="$_PP" FAKE_TMUX_HAS=1 FAKE_CLAUDE_VER=2.1.277 _t8env bash "$SC/pozos-install-token-torre.sh" torre-x "$_T8/tok" >/dev/null 2>&1; _rc=$?
ok "pozos-install-token-torre: señuelo localizado como CLI del pane (precondicion del test)" "$([ -n "$_DC" ] && kill -0 "$_DC" 2>/dev/null && echo si)" si
ok "pozos-install-token-torre: rc 8 del instalador deja el CLI VIVO (el kill va despues) y ningun send-keys" \
  "$([ "$_rc" -eq 8 ] && kill -0 "$_DC" 2>/dev/null && ! grep -q send-keys "$_T8/tmux.log" 2>/dev/null && echo si)" si
_t8reset
FAKE_PANE_PID="$_PP" FAKE_TMUX_HAS=1 _t8env bash "$SC/pozos-install-token-torre.sh" torre-x "$_T8/tok" >/dev/null 2>&1; _rc=$?
for _i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$_DC" 2>/dev/null || break; command sleep 0.2; done
ok "pozos-install-token-torre: con instalador OK el relanzamiento SI mata el CLI y relanza (control del test anterior)" \
  "$([ "$_rc" -eq 0 ] && ! kill -0 "$_DC" 2>/dev/null && grep -q 'send-keys .*-l.*CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 claude' "$_T8/tmux.log" && echo si)" si
_t8decoy_stop
rm -rf "$_T8"
echo "== [TAL-8039] handoff de compact-60 por FICHERO: read_handoff_file (rc 0/2/4) =="
_HT="$(mktemp -d)"; _HN="torre_hf_9_abcd1234"; _HOLD="torre_hf_1_viejo000"
_hf_block() { printf 'HANDOFF-INICIO %s\n%s\nHANDOFF-FIN %s\n' "$1" "$2" "$1"; }
_hnow="$(date +%s)"
_hf_block "$_HN" "ESTADO ACTUAL" > "$_HT/ok.md"
ok "fichero valido -> rc 0" "$(torc_torre_read_handoff_file "$_HT/ok.md" "$_HN" "$((_hnow-5))" >/dev/null 2>&1; echo $?)" 0
ok "fichero valido -> contenido del bloque" "$(torc_torre_read_handoff_file "$_HT/ok.md" "$_HN" "$((_hnow-5))" 2>/dev/null)" "ESTADO ACTUAL"
_hf_block "$_HOLD" "ESTADO DE OTRA EJECUCION" > "$_HT/otro.md"
ok "nonce INCORRECTO (otra ejecucion, mtime fresco) -> rc 2" "$(torc_torre_read_handoff_file "$_HT/otro.md" "$_HN" "$((_hnow-5))" >/dev/null 2>&1; echo $?)" 2
ok "nonce incorrecto: ni una linea del bloque ajeno" "$(torc_torre_read_handoff_file "$_HT/otro.md" "$_HN" "$((_hnow-5))" 2>/dev/null | wc -l | tr -d ' ')" 0
printf 'HANDOFF-INICIO %s\nA MEDIAS\n' "$_HN" > "$_HT/inc.md"
ok "bloque INCOMPLETO (INICIO sin FIN) -> rc 4" "$(torc_torre_read_handoff_file "$_HT/inc.md" "$_HN" "$((_hnow-5))" >/dev/null 2>&1; echo $?)" 4
printf 'HANDOFF-INICIO %s\nCOMPLETO VIEJO\nHANDOFF-FIN %s\nruido\nHANDOFF-INICIO %s\nA MEDIAS\n' "$_HN" "$_HN" "$_HN" > "$_HT/inc2.md"
ok "ultimo INICIO truncado -> rc 4 (no cae al bloque previo completo)" "$(torc_torre_read_handoff_file "$_HT/inc2.md" "$_HN" "$((_hnow-5))" >/dev/null 2>&1; echo $?)" 4
_hf_block "$_HN" "ESTADO VIEJO EN DISCO" > "$_HT/antiguo.md"; touch -d '2 hours ago' "$_HT/antiguo.md"
ok "fichero ANTIGUO (mtime previo a la peticion) con el nonce correcto -> rc 2" "$(torc_torre_read_handoff_file "$_HT/antiguo.md" "$_HN" "$((_hnow-5))" >/dev/null 2>&1; echo $?)" 2
ok "antiguo: la misma lectura con since anterior a su mtime SI pasa (la guarda es el mtime)" "$(torc_torre_read_handoff_file "$_HT/antiguo.md" "$_HN" "$((_hnow-86400))" >/dev/null 2>&1; echo $?)" 0
ok "fichero ausente -> rc 2" "$(torc_torre_read_handoff_file "$_HT/no-existe.md" "$_HN" "$((_hnow-5))" >/dev/null 2>&1; echo $?)" 2
ln -s "$_HT/ok.md" "$_HT/enlace.md"
ok "symlink -> rc 2 (jamas se sigue)" "$(torc_torre_read_handoff_file "$_HT/enlace.md" "$_HN" "$((_hnow-5))" >/dev/null 2>&1; echo $?)" 2
_hf_block "$_HN" "" > "$_HT/vacio.md"
ok "bloque VACIO -> rc 4" "$(torc_torre_read_handoff_file "$_HT/vacio.md" "$_HN" "$((_hnow-5))" >/dev/null 2>&1; echo $?)" 4
ok "nonce invalido -> rc 4" "$(torc_torre_read_handoff_file "$_HT/ok.md" 'malo;rm' "$((_hnow-5))" >/dev/null 2>&1; echo $?)" 4
ok "since invalido -> rc 4" "$(torc_torre_read_handoff_file "$_HT/ok.md" "$_HN" 'ayer' >/dev/null 2>&1; echo $?)" 4
{ _hf_block "$_HOLD" "VIEJO"; printf 'ruido\n'; _hf_block "$_HN" "ACTUAL DEL FICHERO"; } > "$_HT/mixto.md"
ok "fichero con un bloque viejo y el actual -> el actual" "$(torc_torre_read_handoff_file "$_HT/mixto.md" "$_HN" "$((_hnow-5))" 2>/dev/null)" "ACTUAL DEL FICHERO"

echo "== [TAL-8039] collect_handoff: fichero primero, pantalla de respaldo, prorroga con tope (reloj simulado) =="
# Reloj y sleep SIMULADOS: el turno vivo de ~369 s se prueba sin dormirlo. Estado en ficheros (las
# funciones corren en subshells de $(...)).
_ALIVE_REAL="$(declare -f torc_torre_alive)"   # el real, para restaurarlo tras el mock
_CK="$_HT/clock"; _CS="$_HT/screen"; _CB="$_HT/busyuntil"; _CF="$_HT/aparece"
_c_reset() { rm -f "$_HT"/pend.md "$_CF" "$_HT/busycalls"; : > "$_CS"; _hbase="$(date +%s)"; printf '%s' "$_hbase" > "$_CK"; printf '%s' "$_hbase" > "$_HT/start"; printf '0' > "$_CB"; printf '0' > "$_HT/aparece_en"; }
torc_torre_now()   { cat "$_CK"; }
torc_torre_sleep() { local t; t=$(( $(cat "$_CK") + $1 )); printf '%s' "$t" > "$_CK"
  # el "actor" escribe el fichero cuando el reloj alcanza su instante (aparece_en != 0)
  local a; a="$(cat "$_HT/aparece_en")"
  if [ "$a" != 0 ] && [ "$t" -ge "$a" ] && [ ! -f "$_HT/pend.md" ]; then _hf_block "$_HN" "ESTADO DEL FICHERO" > "$_HT/pend.md"; fi; }
torc_torre_alive() { printf 'x\n' >> "$_HT/busycalls"; [ "$(cat "$_CK")" -lt "$(cat "$_CB")" ]; }
torc_torre_cap() { cat "$_CS"; }
_c_run() { # imprime "rc=<rc> t=<s simulados> out=<salida>"
  local out rc=0 s0; s0="$(cat "$_HT/start")"
  out="$(torc_torre_collect_handoff torre-zz "$_HN" "$_HT/pend.md" "$((s0-5))" 2>"$_HT/err")" || rc=$?
  printf 'rc=%s t=%s out=%s' "$rc" "$(( $(cat "$_CK") - s0 ))" "$out"
}
TORRE_HANDOFF_MAX=300; TORRE_HANDOFF_EXTEND=60; TORRE_HANDOFF_HARD_MAX=1200; TORRE_HANDOFF_POLL=10

_c_reset; printf '%s' "$((_hbase+400))" > "$_CB"; printf '%s' "$((_hbase+369))" > "$_HT/aparece_en"
_r="$(_c_run)"
ok "turno VIVO: acepta el handoff que llega a ~369 s (> TORRE_HANDOFF_MAX=300)" "${_r%% t=*}" "rc=0"
ok "turno vivo: contenido del fichero" "${_r#*out=}" "ESTADO DEL FICHERO"
ok "turno vivo: se devolvio tras la llegada (t>=369) y antes de agotar el tope" "$(t="${_r#* t=}"; t="${t%% out=*}"; [ "$t" -ge 369 ] && [ "$t" -lt 450 ] && echo si || echo no)" "si"
ok "turno vivo: origen=fichero logueado" "$(grep -c 'origen=fichero' "$_HT/err")" "1"
ok "turno vivo: la prorroga se anuncio" "$([ "$(grep -c 'prorroga' "$_HT/err")" -ge 1 ] && echo si || echo no)" "si"
_c_reset; printf '0' > "$_CB"; printf '%s' "$((_hbase+369))" > "$_HT/aparece_en"
_r="$(_c_run)"
ok "turno PARADO: no prorroga -> rc 1 aunque el fichero llegaria a 369 s" "${_r%% t=*}" "rc=1"
ok "turno parado: se rindio al plazo base (t<=310)" "$(t="${_r#* t=}"; t="${t%% out=*}"; [ "$t" -ge 300 ] && [ "$t" -le 310 ] && echo si || echo no)" "si"
ok "turno parado: avisa 'turno parado'" "$(grep -c 'turno parado' "$_HT/err")" "1"
_c_reset; printf '%s' "$((_hbase+99999))" > "$_CB"
_r="$(_c_run)"
ok "turno vivo SIN handoff: tope duro -> rc 1" "${_r%% t=*}" "rc=1"
ok "turno vivo sin handoff: corta en el TOPE (1200 s, no mas)" "$(t="${_r#* t=}"; t="${t%% out=*}"; [ "$t" -ge 1200 ] && [ "$t" -le 1210 ] && echo si || echo no)" "si"
_c_reset; printf '%s' "$((_hbase+99999))" > "$_CB"; printf '%s' "$((_hbase+1500))" > "$_HT/aparece_en"
_r="$(_c_run)"
ok "turno vivo: un handoff posterior al tope NO se acepta (rc 1)" "${_r%% t=*}" "rc=1"

# pantalla de respaldo (mismo extractor rc 0/2/4)
_c_reset; _hf_block "$_HN" "ESTADO DE PANTALLA" > "$_CS"
_r="$(_c_run)"
ok "sin fichero + bloque en pantalla -> rc 0 (respaldo)" "${_r%% t=*}:${_r#*out=}" "rc=0:ESTADO DE PANTALLA"
ok "respaldo: origen=pantalla logueado" "$(grep -c 'origen=pantalla' "$_HT/err")" "1"
_c_reset; _hf_block "$_HN" "ESTADO DE PANTALLA" > "$_CS"; _hf_block "$_HN" "ESTADO DEL FICHERO" > "$_HT/pend.md"
_r="$(_c_run)"
ok "fichero Y pantalla: manda el FICHERO" "${_r#*out=}" "ESTADO DEL FICHERO"
_c_reset; _hf_block "$_HN" "ESTADO DE PANTALLA" > "$_CS"; printf 'HANDOFF-INICIO %s\nA MEDIAS\n' "$_HN" > "$_HT/pend.md"
_r="$(_c_run)"
ok "fichero INCOMPLETO + pantalla completa -> cae a la pantalla" "${_r%% t=*}:${_r#*out=}" "rc=0:ESTADO DE PANTALLA"
_c_reset; _hf_block "$_HOLD" "STALE" > "$_CS"
_r="$(_c_run)"
ok "pantalla solo con handoff viejo (rc 2 del extractor) -> rc 1" "${_r%% t=*}" "rc=1"
_c_reset; printf 'HANDOFF-INICIO %s\nTRUNCADO\n' "$_HN" > "$_CS"
_r="$(_c_run)"
ok "pantalla truncada (rc 4 del extractor) -> rc 1" "${_r%% t=*}" "rc=1"
_c_reset; _hf_block "$_HN" "ESTADO VIEJO EN DISCO" > "$_HT/pend.md"; touch -d '2 hours ago' "$_HT/pend.md"
_r="$(_c_run)"
ok "fichero ANTIGUO + turno parado -> rc 1" "${_r%% t=*}" "rc=1"
_c_reset; _hf_block "$_HOLD" "OTRA EJECUCION" > "$_HT/pend.md"
_r="$(_c_run)"
ok "fichero de OTRA ejecucion (otro nonce) + turno parado -> rc 1" "${_r%% t=*}" "rc=1"
# m5: pane/sesion muerta (captura fallida) NO es «turno vivo»: aborta al plazo base, sin esperar el tope
unset -f torc_torre_alive; eval "$_ALIVE_REAL"
torc_torre_cap() { return 1; }
_c_reset
_r="$(_c_run)"
ok "m5: captura FALLIDA (pane/sesion muerta) -> rc 1 al plazo base (t<=310), sin prorrogar hasta el tope" "${_r%% t=*}:$(t="${_r#* t=}"; t="${t%% out=*}"; [ "$t" -ge 300 ] && [ "$t" -le 310 ] && echo si || echo no)" "rc=1:si"
ok "m5: el motivo dice 'turno parado' (no vivo)" "$(grep -c 'turno parado' "$_HT/err")" "1"
torc_torre_cap() { printf '* Working (esc to interrupt)\n'; }
ok "m5: torc_torre_alive real: captura legible y ocupada -> 0" "$(torc_torre_alive s >/dev/null 2>&1; echo $?)" "0"
torc_torre_cap() { printf '> \nctx: 20%%\n'; }
ok "m5: torc_torre_alive real: captura legible e idle -> 1" "$(torc_torre_alive s >/dev/null 2>&1; echo $?)" "1"
torc_torre_cap() { return 1; }
ok "m5: torc_torre_alive real: captura fallida -> 1 (NO vivo)" "$(torc_torre_alive s >/dev/null 2>&1; echo $?)" "1"
torc_torre_cap() { printf ''; }
ok "m5: torc_torre_alive real: captura vacia -> 1" "$(torc_torre_alive s >/dev/null 2>&1; echo $?)" "1"
# mtime ilegible (stat falla) -> rc 2, fail-closed
_hf_block "$_HN" "ESTADO" > "$_HT/okstat.md"
stat() { return 1; }
ok "read_handoff_file: mtime ILEGIBLE (stat falla) -> rc 2" "$(torc_torre_read_handoff_file "$_HT/okstat.md" "$_HN" "$((_hnow-5))" >/dev/null 2>&1; echo $?)" "2"
unset -f stat
stat() { printf 'no-es-un-numero\n'; }
ok "read_handoff_file: mtime no numerico -> rc 2" "$(torc_torre_read_handoff_file "$_HT/okstat.md" "$_HN" "$((_hnow-5))" >/dev/null 2>&1; echo $?)" "2"
unset -f stat
unset -f torc_torre_now torc_torre_sleep torc_torre_alive torc_torre_cap
. "$SC/lib-torre.sh"   # restaura los helpers reales mockeados
TORRE_HANDOFF_MAX=300

echo "== [TAL-8039] torre-compact.sh run (tmux de mentira): aborto sin handoff; positivo por fichero =="
_FB="$_HT/fakebin"; _FT="$_HT/ft"; mkdir -p "$_FB" "$_FT"
cat > "$_FB/tmux" <<'FAKETMUX'
#!/usr/bin/env bash
# tmux de MENTIRA para torre-compact.sh: un solo pane torre-zz con composer, historial y barra ctx.
FT="${FT_DIR:?}"
sub="${1:-}"; shift || true
case "$sub" in
  has-session) exit 0 ;;
  list-sessions) printf 'torre-zz\n'; exit 0 ;;
  capture-pane)
    cat "$FT/hist" 2>/dev/null
    printf '> %s\n' "$(cat "$FT/composer" 2>/dev/null)"
    printf 'ctx: 20%%\n'
    [ -f "$FT/busy" ] && printf '* Working (esc to interrupt)\n'
    exit 0 ;;
  send-keys)
    lit=0; args=()
    while [ $# -gt 0 ]; do
      case "$1" in -t) shift 2 ;; -l) lit=1; shift ;; --) shift; args+=("$@"); break ;; *) args+=("$1"); shift ;; esac
    done
    if [ "$lit" = 1 ]; then printf '%s' "${args[*]}" > "$FT/composer"; exit 0; fi
    case "${args[0]:-}" in
      Escape|C-u) : > "$FT/composer" ;;
      C-m)
        txt="$(cat "$FT/composer")"
        printf '%s\n' "$txt" >> "$FT/submits"
        printf '* %s\n' "$txt" >> "$FT/hist"
        : > "$FT/composer"
        case "$txt" in
          *HANDOFF-INICIO*)
            n="$(printf '%s' "$txt" | sed -E "s/.*'HANDOFF-INICIO ([A-Za-z0-9_-]+)'.*/\1/")"
            f="$(printf '%s' "$txt" | sed -E 's/.*escribe AHORA con la herramienta Write el fichero ([^ ]+) con tu handoff.*/\1/')"
            case "${FT_MODE:-none}" in
              file)   printf 'HANDOFF-INICIO %s\nESTADO E2E\nlinea dos del handoff\nHANDOFF-FIN %s\n' "$n" "$n" > "$f" ;;
              stale)  printf 'HANDOFF-INICIO torre_hf_1_otraejec\nESTADO AJENO\nHANDOFF-FIN torre_hf_1_otraejec\n' > "$f" ;;
              old)    printf 'HANDOFF-INICIO %s\nESTADO VIEJO REUTILIZADO\nHANDOFF-FIN %s\n' "$n" "$n" > "$f"; touch -d '2 hours ago' "$f" ;;
              screen) printf 'HANDOFF-INICIO %s\nESTADO DE PANTALLA E2E\nHANDOFF-FIN %s\n' "$n" "$n" >> "$FT/hist" ;;
            esac ;;
        esac ;;
    esac
    exit 0 ;;
esac
exit 0
FAKETMUX
chmod +x "$_FB/tmux"
# m1: los sleep de 1-10 s del relay/idle/compact no aportan nada a la prueba -> shim de 20 ms en el PATH del subproceso
printf '#!/bin/sh\nexec /bin/sleep 0.02\n' > "$_FB/sleep"; chmod +x "$_FB/sleep"
_ct_run() { # modo -> rc ; logs en $_FT/{out.log,submits}
  rm -rf "$_FT"/* "$_HT/hdir"; : > "$_FT/hist"; : > "$_FT/composer"
  env -i PATH="$_FB:$PATH" HOME="$_HT" FT_DIR="$_FT" FT_MODE="$1" TORC_SECRET_DIR="$_HT/sec" TORRE_HANDOFF_DIR="$_HT/hdir" \
    TORRE_HANDOFF_MAX=1 TORRE_HANDOFF_POLL=1 TORRE_HANDOFF_HARD_MAX=1 \
    bash "$SC/torre-compact.sh" run zz --threshold 99 >"$_FT/out.log" 2>&1; echo $?
}
ok "e2e sin handoff (el actor no escribe nada): rc != 0" "$([ "$(_ct_run none)" -ne 0 ] && echo si || echo no)" "si"
ok "e2e sin handoff: «ABORTO ANTES de /compact»" "$(grep -c 'ABORTO ANTES de /compact' "$_FT/out.log")" "1"
ok "e2e sin handoff: el mock recibio la peticion pero NUNCA /compact" "$(grep -c 'HANDOFF-INICIO' "$_FT/submits"):$(grep -c '^/compact$' "$_FT/submits")" "1:0"
ok "e2e sin handoff: el dir 0700 se creo ANTES de pedir" "$(stat -c %a "$_HT/hdir")" "700"
ok "e2e: la peticion ordena Write al .pending.md del dir 0700" "$(grep -c "Write el fichero $_HT/hdir/zz\.[0-9TZ]*\.pending\.md" "$_FT/submits")" "1"
ok "e2e fichero de OTRA ejecucion (otro nonce): rc != 0 y sin /compact" "$([ "$(_ct_run stale)" -ne 0 ] && echo si || echo no):$(grep -c '^/compact$' "$_FT/submits")" "si:0"
ok "e2e fichero de otra ejecucion: abortó antes de /compact" "$(grep -c 'ABORTO ANTES de /compact' "$_FT/out.log")" "1"
ok "m2 e2e: handoff ANTIGUO con el nonce REUTILIZADO (mtime previo a la peticion) -> rc != 0 en run" "$([ "$(_ct_run old)" -ne 0 ] && echo si || echo no)" "si"
ok "m2 e2e: ...abortó antes de /compact (el mock no recibio /compact)" "$(grep -c 'ABORTO ANTES de /compact' "$_FT/out.log"):$(grep -c '^/compact$' "$_FT/submits")" "1:0"
ok "m2 e2e: ...y el motivo registrado es el mtime (ANTIGUO)" "$(grep -c 'ANTIGUO' "$_FT/out.log")" "1"
mkdir -p "$_HT/hdir0755"; chmod 755 "$_HT/hdir0755"
_ct_run_dir() { # dir modo -> rc
  rm -rf "$_FT"/*; : > "$_FT/hist"; : > "$_FT/composer"
  env -i PATH="$_FB:$PATH" HOME="$_HT" FT_DIR="$_FT" FT_MODE="$2" TORC_SECRET_DIR="$_HT/sec" TORRE_HANDOFF_DIR="$1" \
    TORRE_HANDOFF_MAX=1 TORRE_HANDOFF_POLL=1 TORRE_HANDOFF_HARD_MAX=1 \
    bash "$SC/torre-compact.sh" run zz --threshold 99 >"$_FT/out.log" 2>&1; echo $?
}
_r="$(_ct_run_dir "$_HT/hdir0755" file)"
ok "dir de handoff PREEXISTENTE 0755 -> se endurece a 0700 y el run termina rc 0" "$_r:$(stat -c %a "$_HT/hdir0755")" "0:700"
mkdir -p "$_HT/real-dir"; ln -s "$_HT/real-dir" "$_HT/hdir-link"; chmod 755 "$_HT/real-dir"
_r="$(_ct_run_dir "$_HT/hdir-link" file)"
ok "dir de handoff = SYMLINK -> rc != 0, «enlace simbolico», NADA compactado" "$([ "$_r" -ne 0 ] && echo si || echo no):$(grep -c 'enlace simbolico' "$_FT/out.log"):$(grep -c 'HANDOFF-INICIO' "$_FT/submits" 2>/dev/null || echo 0)" "si:1:0"
ok "symlink: el chmod NO cayo sobre el destino del enlace (sigue 0755)" "$(stat -c %a "$_HT/real-dir")" "755"
: > "$_HT/un-fichero"
_r="$(_ct_run_dir "$_HT/un-fichero/dentro" file)"
ok "dir de handoff no creable (cuelga de un fichero) -> rc != 0 «NADA compactado»" "$([ "$_r" -ne 0 ] && echo si || echo no):$(grep -c 'NADA compactado' "$_FT/out.log")" "si:1"
ok "e2e POSITIVO por fichero: rc 0" "$(_ct_run file)" "0"
ok "e2e positivo: el mock recibio /compact y el re-relay del handoff" "$(grep -c '^/compact$' "$_FT/submits"):$(grep -c '^lee .*zz\..*\.md — handoff de regreso' "$_FT/submits")" "1:1"
ok "e2e positivo: origen=fichero" "$(grep -c 'origen=fichero' "$_FT/out.log")" "1"
ok "e2e positivo: handoff guardado FUERA 0600 con el contenido" "$(f="$(ls "$_HT"/hdir/zz.*[0-9Z].md | grep -v pending | head -1)"; printf '%s:%s' "$(stat -c %a "$f")" "$(head -1 "$f")")" "600:ESTADO E2E"
ok "e2e positivo: el .pending.md quedo en 0600" "$(stat -c %a "$(ls "$_HT"/hdir/*.pending.md | head -1)")" "600"
ok "e2e dry-run: nombra el .pending.md y no toca tmux" "$(env -i PATH="$_FB:$PATH" HOME="$_HT" FT_DIR="$_FT" TORC_SECRET_DIR="$_HT/sec" TORRE_HANDOFF_DIR="$_HT/hdir2" bash "$SC/torre-compact.sh" run zz --dry-run 2>&1 | grep -c 'pending\.md')" "2"

echo "== [TAL-8039] guardas estaticas =="
ok "torre-compact.sh ya NO captura el handoff con 'torc_torre_cap \"\$S\" 800'" "$(grep -c 'torc_torre_cap "\$S" 800' "$SC/torre-compact.sh")" "0"
ok "torre-compact.sh usa torc_torre_collect_handoff" "$(grep -c 'torc_torre_collect_handoff' "$SC/torre-compact.sh")" "1"
ok "lib-torre.sh: la verificacion de nonce del fichero pasa por el extractor anti-stale" "$(sed -n '/^torc_torre_read_handoff_file()/,/^}/p' "$SC/lib-torre.sh" | grep -c 'torc_torre_extract_handoff "\$nonce"')" "1"
ok "lib-torre.sh: la guarda de mtime esta en read_handoff_file" "$(sed -n '/^torc_torre_read_handoff_file()/,/^}/p' "$SC/lib-torre.sh" | grep -c '"\$mtime" -lt "\$since"')" "1"
rm -rf "$_HT"
echo "== [TAL-8043] torre: menu-abierto (detector puro) + flag del sweep =="
MENU_PLANO="$(printf '  Do you want to proceed?\n ❯ 1. Yes\n   2. No\n\n Esc to cancel · Tab to amend\n')"
MENU_ANSI="$(printf '  Do you want to proceed?\n %s[36m❯ 1. Yes%s[39m\n   2. No\n\n %s[2mEsc to cancel%s[22m\n' "$E" "$E" "$E" "$E")"
MENU_BOX="$(printf '│ Seleccion │\n│ ❯ 1. Opcion A │\n│   2. Opcion B │\n╰──╯\n Enter to select · ↑/↓ to navigate\n')"
ok "menu plano"                  "$(printf '%s\n' "$MENU_PLANO" | xrc torc_torre_menu_open)" 0
ok "menu con ANSI (captura -e)"   "$(printf '%s\n' "$MENU_ANSI" | xrc torc_torre_menu_open)" 0
ok "menu dentro de un box │"      "$(printf '%s\n' "$MENU_BOX" | xrc torc_torre_menu_open)" 0
ok "composer '> 1. texto' NO es menu" "$(printf '│ > 1. texto tecleado │\n   2. otra cosa\n Esc to cancel\n' | xrc torc_torre_menu_open)" 1
ok "lista numerada del transcript NO es menu" "$(printf 'pasos:\n  1. uno\n  2. dos\n? for shortcuts\n' | xrc torc_torre_menu_open)" 1
ok "cursor ❯ sin otra opcion NO es menu" "$(printf ' ❯ 1. Yes\n Esc to cancel\n' | xrc torc_torre_menu_open)" 1
ok "cursor ❯ + opciones sin pista del selector NO es menu" "$(printf ' ❯ 1. hola\n   2. adios\n' | xrc torc_torre_menu_open)" 1
ok "captura vacia NO es menu" "$(printf '' | xrc torc_torre_menu_open)" 1
ok "H06 transcripción rotulada NO es selector activo" "$(printf 'Informe de ejemplo, no selector activo:\n ❯ 1. Yes\n   2. No\n Esc to cancel\nctx: 42%%\n' | xrc torc_torre_menu_open)" 1
ok "R2-04 selector posterior a informe" "$(printf 'Informe de progreso:\n ❯ 1. Yes\n   2. No\n Esc to cancel · ctx: 42%%\n' | xrc torc_torre_menu_open)" 0
ok "R2-04 selector posterior al último prompt" "$(printf 'Informe de ejemplo:\n texto histórico\n>\n ❯ 1. Yes\n   2. No\n Esc to cancel · ctx: 42%%\n' | xrc torc_torre_menu_open)" 0
ok "R2-04 selector después de cerrar una cita" "$(printf '```\ncita explícita:\ntexto histórico\n```\n ❯ 1. Yes\n   2. No\n Esc to cancel\n' | xrc torc_torre_menu_open)" 0
ok "R2-04 cita explícita UTF-8" "$(printf 'Cita explícita:\n ❯ 1. Yes\n   2. No\n Esc to cancel\n' | xrc torc_torre_menu_open)" 1
ok "R2-04 prompt UTF-8 abre una región nueva" "$(printf 'no selector activo:\ntexto histórico\n❯\n ❯ 1. Yes\n   2. No\n Esc to cancel\n' | xrc torc_torre_menu_open)" 0
ok "H06 selector histórico fuera de últimas líneas" "$(printf ' ❯ 1. Yes\n   2. No\n Esc to cancel\nfin\nuno\ndos\ntres\ncuatro\ncinco\nseis\nsiete\nocho\nctx: 42%%\n' | xrc torc_torre_menu_open)" 1
SWB="$(mktemp -d)"; mkdir -p "$SWB/bin"
cat > "$SWB/bin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  has-session) exit 0 ;;
  capture-pane) cat "$SWB_CAP" ;;
  list-sessions) echo torre-zz ;;
  *) exit 1 ;;
esac
SH
chmod +x "$SWB/bin/tmux"
printf 'opus · ctx: 42%% · ? for shortcuts\n' > "$SWB/cap-base"
{ cat "$SWB/cap-base"; printf '%s\n' "$MENU_PLANO"; } > "$SWB/cap-menu"
sweep_resumen() { SWB_CAP="$1" PATH="$SWB/bin:$PATH" bash "$SC/torre-sweep.sh" torre-zz 2>/dev/null | sed -n 's/^ *resumen: //p'; }
ok "sweep sin menu: el resumen no cambia (idle · ctx · ninguno)" "$(sweep_resumen "$SWB/cap-base")" "idle · ctx: 42% · flags: ninguno"
ok "sweep con menu: añade SOLO el flag menu-abierto" "$(sweep_resumen "$SWB/cap-menu")" "idle · ctx: 42% · flags: menu-abierto"
for modo in frontera dentro cierre prompt transcripcion; do
  case "$modo" in
    frontera) texto=$'```\nhistórico uno\nhistórico dos\nhistórico tres\n```\nInforme de progreso:\n ❯ 1. Yes\n   2. No\n Esc to cancel · ctx: 42%'; esperado=0 ;;
    dentro) texto=$'```\n ❯ 1. Yes\n   2. No\n Esc to cancel\n```\nctx: 42%'; esperado=1 ;;
    cierre) texto=$'```\nhistórico\n```\n ❯ 1. Yes\n   2. No\n Esc to cancel · ctx: 42%'; esperado=0 ;;
    prompt) texto=$'```\nhistórico uno\nhistórico dos\nhistórico tres\n>\n ❯ 1. Yes\n   2. No\n Esc to cancel · ctx: 42%'; esperado=0 ;;
    transcripcion) texto=$'Informe de ejemplo, no selector activo:\n ❯ 1. Yes\n   2. No\n Esc to cancel\nctx: 42%'; esperado=1 ;;
  esac
  printf '%s\n' "$texto" > "$SWB/cap-ronda3"
  ok "R3-02 detector cita $modo" "$(printf '%s\n' "$texto" | xrc torc_torre_menu_open)" "$esperado"
  flag=ninguno; [ "$esperado" = 1 ] || flag=menu-abierto
  ok "R3-02 sweep cita $modo" "$(sweep_resumen "$SWB/cap-ronda3")" "idle · ctx: 42% · flags: $flag"
done
rm -rf "$SWB"

echo "== [TAL-8037] clave del team Linear de la INSTANCIA y defaults de casa (fail-closed, jamás TAL) =="
_KMO="$(mktemp -d)"; printf 'TF_LINEAR_TEAM_KEY="XYZ"\n' > "$_KMO/m.conf"
ok "clave ABC: TAL-1497 se RECHAZA"              "$(rc torc_is_tal TAL-1497)" 1
ok "sin variable ni manifiesto -> rc 1"          "$( (unset TF_LINEAR_TEAM_KEY TF_MANIFEST; torc_is_tal ABC-1 >/dev/null 2>&1; echo $?) )" 1
ok "sin variable: el mensaje NOMBRA TF_LINEAR_TEAM_KEY" "$( (unset TF_LINEAR_TEAM_KEY TF_MANIFEST; torc_linear_team_key 2>&1 >/dev/null | grep -c TF_LINEAR_TEAM_KEY) )" 1
ok "clave desde el manifiesto TF_MANIFEST (absoluto)" "$( (unset TF_LINEAR_TEAM_KEY; TF_MANIFEST="$_KMO/m.conf" torc_linear_team_key) )" "XYZ"
ok "TF_MANIFEST relativo -> rc 1"                "$( (unset TF_LINEAR_TEAM_KEY; TF_MANIFEST=rel.conf torc_linear_team_key >/dev/null 2>&1; echo $?) )" 1
ok "clave inválida (minúsculas) -> rc 1"         "$( (TF_LINEAR_TEAM_KEY=abc torc_linear_team_key >/dev/null 2>&1; echo $?) )" 1
ok "status.sh/lib.sh SIN validador con clave de casa fija" "$(grep -cE 'TAL-\[0-9\]' "$SC/status.sh" "$SC/lib.sh" | awk -F: '{n+=$2} END{print n+0}')" 0
ok "00-config SIN ids de casa: TORC_TEAM_ID vacío por defecto"   "$( (unset TORC_TEAM_ID; . "$SC/00-config.sh"; printf '[%s]' "$TORC_TEAM_ID") )" "[]"
ok "00-config SIN ids de casa: TORC_INITIATIVE_ID vacío por defecto" "$( (unset TORC_INITIATIVE_ID; . "$SC/00-config.sh"; printf '[%s]' "$TORC_INITIATIVE_ID") )" "[]"
# torc_preflight (orchestrate.sh): `:?` ANTES de tocar la API cuando falta el team o la initiative (la API se sombrea y nunca debe llamarse)
_pf8037() { # [unset-var] -> rc y marca API
  ( . "$SC/orchestrate.sh"; export TORC_COORD_PROJECT_ID=x TORC_REGISTRY_ISSUE_ID=x TORC_STATE_TODO=x TORC_STATE_WORKING=x TORC_STATE_NEEDS_INPUT=x TORC_STATE_DONE=x \
      TORC_LABEL_AGENT_INSTR=x TORC_LABEL_REGISTRY=x TORC_LABEL_VERTICAL=x TORC_LABEL_ACTOR_AI=x TORC_TEAM_ID=t TORC_INITIATIVE_ID=i; unset "$1"
    linear_api() { echo API-LLAMADA; }; torc_preflight yes 2>&1 | tr '\n' ' '; exit "${PIPESTATUS[0]}" ) 2>&1; }
ok "preflight sin TORC_TEAM_ID -> :? nombrando la variable, sin llamar a la API" "$(_pf8037 TORC_TEAM_ID | grep -c 'TORC_TEAM_ID sin definir')" 1
ok "preflight sin TORC_TEAM_ID: la API NO se llama" "$(_pf8037 TORC_TEAM_ID | grep -c API-LLAMADA)" 0
ok "preflight sin TORC_INITIATIVE_ID -> :? nombrando la variable" "$(_pf8037 TORC_INITIATIVE_ID | grep -c 'TORC_INITIATIVE_ID sin definir')" 1
# [acta m1] la validación es de la CADENA COMPLETA: clave multilínea ($'X2Y\n.*') rechazada, no se compone en ninguna ERE
_KEYML=$'X2Y\n.*'
ok "clave multilínea -> torc_linear_team_key rc 1" "$( (TF_LINEAR_TEAM_KEY="$_KEYML" torc_linear_team_key >/dev/null 2>&1; echo $?) )" 1
ok "clave multilínea: torc_is_tal zzz-1 NO valida" "$( (TF_LINEAR_TEAM_KEY="$_KEYML" torc_is_tal zzz-1 >/dev/null 2>&1; echo $?) )" 1
# [acta M3] el cargador RECHAZA marcadores PENDIENTE-* en CUALQUIER clave del conf (rc 1, nombrando la clave)
_PHO="$_KMO/pho"; mkdir -p "$_PHO/home/P"; cp "$SC/00-config.sh" "$_PHO/"; printf 'LINEAR_API_KEY=k\n' > "$_PHO/home/P/.env.local"
_pho() { printf '%s\n' "$1" > "$_PHO/repo-identity.conf"; env -i PATH="$PATH" HOST_HOME="$_PHO/home" TORC_SECRET_DIR="$_PHO/s" TORC_HOST_ENV="" bash -c ". '$_PHO/00-config.sh'; torc_load_tokens 2>&1; echo rc=\$?" | tr '\n' ' '; }
ok "orq cargador: conf adjudicado carga (rc 0)" "$(_pho $'PKG_IDENTITY_PROJECT=x\nTORC_HOST_ENV_REL=P/.env.local' | grep -oE 'rc=[0-9]')" "rc=0"
ok "orq cargador: TORC_HOST_ENV_REL=PENDIENTE-* -> rc 1 nombrando la clave" "$(_pho $'PKG_IDENTITY_PROJECT=x\nTORC_HOST_ENV_REL=PENDIENTE-TORC_HOST_ENV_REL' | grep -oE 'marcador de pendiente en repo-identity.conf \(TORC_HOST_ENV_REL|rc=1' | tr '\n' ' ')" "marcador de pendiente en repo-identity.conf (TORC_HOST_ENV_REL rc=1 "
ok "orq cargador: PKG_IDENTITY_PROJECT=PENDIENTE-* (cualquier clave) -> rc 1" "$(_pho $'PKG_IDENTITY_PROJECT=PENDIENTE-X\nTORC_HOST_ENV_REL=P/.env.local' | grep -oE 'rc=[0-9]')" "rc=1"
# [n2] valores legítimos con aspecto de pendiente se ACEPTAN (solo el valor completo PENDIENTE-<CLAVE> es el marcador)
ok "orq cargador (n2): PKG_IDENTITY_PROJECT=todo / pendiente-app / placeholder-site -> rc 0" "$(for v in todo pendiente-app placeholder-site; do _pho "PKG_IDENTITY_PROJECT=$v"$'\n'"TORC_HOST_ENV_REL=P/.env.local" | grep -oE 'rc=[0-9]'; done | tr '\n' ' ')" "rc=0 rc=0 rc=0 "
# [acta m3] status.sh: la clave del team viaja al filtro jq (curl sombreado, sin red)
_SHM="$_KMO/shim"; mkdir -p "$_SHM"; printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf %%s '"'"'{"data":{"issues":{"nodes":[{"identifier":"T-1","title":"t","state":{"name":"s"},"description":"ABC-1 ABC-2 ABC-2 TAL-9"}]}}}'"'"'\n' > "$_SHM/curl"; chmod +x "$_SHM/curl"
printf 'LINEAR_API_KEY=k\n' > "$_KMO/tok.env"
_status() { env -i PATH="$_SHM:$PATH" HOST_HOME="$_KMO" TORC_SECRET_DIR="$_KMO/ss" TORC_HOST_ENV="$_KMO/tok.env" TORC_COORD_PROJECT_ID=x TORC_LABEL_AGENT_INSTR=l "$@" bash "$SC/status.sh" 2>&1; echo "rc=$?"; }
ok "status.sh con clave ABC: cuenta SOLO los ABC-n de la descripción (2)" "$(_status TF_LINEAR_TEAM_KEY=ABC | grep -oE '\(issues: [0-9]+\)')" "(issues: 2)"
ok "status.sh sin clave -> fail-closed nombrando TF_LINEAR_TEAM_KEY (rc 1)" "$(_status | grep -oE 'TF_LINEAR_TEAM_KEY sin resolver|rc=[0-9]' | tr '\n' ' ')" "TF_LINEAR_TEAM_KEY sin resolver rc=1 "
# pozos-install-token.sh: la carpeta del repo en el canal es identidad de la instancia
_TKF="$_KMO/tok"; printf 'x\n' > "$_TKF"
ok "pozos-install-token sin POZOS_REPO_DIR -> rc 1 (:? fail-closed)" "$( (unset POZOS_REPO_DIR; bash "$SC/pozos-install-token.sh" 01 "$_TKF" >/dev/null 2>&1; echo $?) )" 1
ok "pozos-install-token: el mensaje NOMBRA POZOS_REPO_DIR" "$( (unset POZOS_REPO_DIR; bash "$SC/pozos-install-token.sh" 01 "$_TKF" 2>&1 | grep -c POZOS_REPO_DIR) )" 1
ok "pozos-install-token con POZOS_REPO_DIR inválido (ruta) -> rc 2 antes de tocar incus" "$( (POZOS_REPO_DIR='a/b' bash "$SC/pozos-install-token.sh" 01 "$_TKF" >/dev/null 2>&1; echo $?) )" 2
ok "pozos-lib: LEDGER por defecto bajo TF_ROOT (sin literal de casa)" "$( (unset AM_LEDGER; TF_ROOT=/x/fab; . "$SC/pozos-lib.sh"; printf '%s' "$LEDGER") )" "/x/fab/ledger/cuentas.json"
rm -rf "$_KMO"
ok "resume por rol y registro vigente junto al lanzamiento" "$(rc bash "$HERE/torre-modelos.sh")" 0
rm -rf "$TORC_SECRET_DIR"

HOST_TEST="$SC/../../../tests/fixtures/instalacion/comprobar-host-user.sh"
ok 'config: rol efectivo ignora SUDO_USER heredado' "$(bash "$HOST_TEST" "$SC/00-config.sh" 1000)" rol-efectivo
ok 'config: root conserva SUDO_USER' "$(bash "$HOST_TEST" "$SC/00-config.sh" 0)" instalador
echo; echo "RESULTADO: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
