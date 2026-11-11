#!/usr/bin/env bash
# run-tests.sh — Tests HERMÉTICOS de talent-medidor (F1).
#
# Sin red, sin systemd, sin tocar nada fuera de su directorio temporal: la DB, las raíces de
# transcripts, el perfil y los precios apuntan a `mktemp -d`. `bash tests/run-tests.sh` -> exit 0.
#
# Fixtures: las 9 de F0 en tests/fixtures/ (copia byte a byte de la entrega de F0) y las DERIVADAS,
# que se construyen aquí dentro, en el temporal, y no añaden ficheros al árbol. Todo dato es
# SINTÉTICO y evidentemente falso; las direcciones usan el rango de documentación de la RFC 5737 y
# los correos el dominio reservado de la RFC 2606.
#
# Anti-tautología: los esperados son LITERALES escritos aquí o relaciones calculadas con OTRA
# implementación (jq, sha256sum, wc -c). Ningún esperado sale de la función de producción.
#
# ── LA SUITE SE AFIRMA A SÍ MISMA ──────────────────────────────────────────────────────────────
# Al final comprueba que el número de aserciones EJECUTADAS coincide con TOTAL_ESPERADO. Un caso
# que desaparezca —borrado, un `return` de más, una fixture que deja de construirse— se lleva su
# cobertura sin que nada enrojezca si no se cuenta. K37 lo prueba borrando un caso de una copia.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${MEDIDOR_ROOT:-$(cd "$HERE/.." && pwd)}"
S="$ROOT/scripts"
FX="$ROOT/tests/fixtures"
PY=(python3 -B)

TOTAL_ESPERADO=80
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (esperado='$2' obtenido='$3')"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ── andamiaje ──────────────────────────────────────────────────────────────────────────────────
# entorno <nombre>: raíces, DB, perfil válido sin partes y precios SIN filas, todo en el temporal.
entorno() {
  E="$T/$1"
  mkdir -p "$E/claude/p" "$E/codex" "$E/db"
  export TALENT_MEDIDOR_DB="$E/db/m.db" TALENT_MEDIDOR_CLAUDE_DIR="$E/claude" \
         TALENT_MEDIDOR_CODEX_DIR="$E/codex" TALENT_MEDIDOR_PRECIOS="$E/precios.tsv" \
         TA_PERFIL="$E/perfil.tsv"
  unset TALENT_MEDIDOR_PAUSA_FIFO TALENT_MEDIDOR_NORMALIZACION
  printf 'tipo\tid\tmaquina\tcontenedor\tsesion\tatributos\nmaquina\tmaq-sint\tmaq-sint\t-\t-\trol=mando\n' > "$TA_PERFIL"
  printf 'desde_fecha\tmodelo\tin\tout\tcache_w_5m\tcache_w_1h\tcache_r\tfuente\n' > "$TALENT_MEDIDOR_PRECIOS"
}
tick() { "${PY[@]}" "$S/recolector.py" --tick > "$E/tick.out" 2> "$E/tick.err"; }
q() {
  "${PY[@]}" -c 'import sqlite3,sys
con=sqlite3.connect(sys.argv[1])
for r in con.execute(sys.argv[2]): print("|".join("" if v is None else str(v) for v in r))
con.commit()' "$TALENT_MEDIDOR_DB" "$1"
}
# asistente <session> <uuid> <parent|null> <message.id> <out> [ts] [extra-json-sin-llaves]
asistente() {
  local parent='null' ts='' extra=''
  [ "$3" = null ] || parent="\"$3\""
  [ -n "${6-}" ] && ts="\"timestamp\":\"$6\","
  [ -n "${7-}" ] && extra="$7,"
  printf '{"type":"assistant",%s%s"uuid":"%s","parentUuid":%s,"sessionId":"%s","message":{"id":"%s","model":"claude-fx-modelo-a","usage":{"input_tokens":1,"output_tokens":%s}}}\n' \
    "$ts" "$extra" "$2" "$parent" "$1" "$4" "$5"
}
todas_las_f0() { cp -r "$FX"/claude-* "$FX"/trampa-contenido.jsonl "$E/claude/p/"; cp "$FX"/codex-* "$E/codex/"; escribibles; }
# Las copias heredan el modo de origen; los casos que AÑADEN líneas necesitan poder escribir.
escribibles() { chmod -R u+w "$E/claude" "$E/codex"; }

# ── K01-K05: unidad contable y normalización de Claude ───────────────────────────────────────
caso_K01() {
  echo "K01 · 5 registros del mismo message.id -> 1 unidad con 754"
  entorno k01; cp "$FX/claude-respuesta-5-registros.jsonl" "$E/claude/p/"; tick
  assert_eq "[K01-1] una sola fila para msg_fx0001duplicado" "1" "$(q "SELECT count(*) FROM usage_raw WHERE unidad_id='msg_fx0001duplicado'")"
  assert_eq "[K01-2] out_tok = 754 (nunca 3770)" "754" "$(q "SELECT out_tok FROM usage_raw WHERE unidad_id='msg_fx0001duplicado'")"
}
caso_K02() {
  echo "K02 · gana el ÚLTIMO usage por timestamp, no el primero ni el último del fichero"
  entorno k02
  { asistente fx-s-k02 fx-k02-1 null msg_fxk02 900 2026-09-22T10:00:01Z
    asistente fx-s-k02 fx-k02-2 null msg_fxk02 754 2026-09-22T10:00:02Z
    asistente fx-s-k02 fx-k02-0 null msg_fxk02 50 2026-09-22T10:00:00Z; } > "$E/claude/p/k02.jsonl"
  tick
  assert_eq "[K02-1] out_tok = 754 (T2, el de mayor timestamp)" "754" "$(q "SELECT out_tok FROM usage_raw WHERE unidad_id='msg_fxk02'")"
}
caso_K03_K05() {
  echo "K03-K05 · normalización Claude sobre la fixture de caché 5m/1h"
  entorno k03; cp "$FX/claude-cache-5m-1h.jsonl" "$E/claude/p/"; tick
  assert_eq "[K03] in_total = 3+900+200 = 1103" "1103" "$(q "SELECT in_total FROM usage_raw WHERE unidad_id='msg_fx0002cache'")"
  assert_eq "[K04] cache_w_5m|cache_w_1h = 300|600" "300|600" "$(q "SELECT cache_w_5m, cache_w_1h FROM usage_raw WHERE unidad_id='msg_fx0002cache'")"
  assert_eq "[K05] out_tok|thinking_tok = 120|15 (thinking aparte)" "120|15" "$(q "SELECT out_tok, thinking_tok FROM usage_raw WHERE unidad_id='msg_fx0002cache'")"
}

# ── K06-K10: Codex ───────────────────────────────────────────────────────────────────────────
caso_K06_K07() {
  echo "K06-K07 · Codex: unidad por response_id; el turno solo como control"
  entorno k06; cp "$FX/codex-turno-3-respuestas.jsonl" "$E/codex/"; tick
  assert_eq "[K06-1] 3 filas resp_fx0000..2" "resp_fx0000,resp_fx0001,resp_fx0002" "$(q "SELECT group_concat(unidad_id) FROM (SELECT unidad_id FROM usage_raw ORDER BY unidad_id)")"
  assert_eq "[K06-2] Σ in|Σ out = 3500|150" "3500|150" "$(q "SELECT sum(in_tok), sum(out_tok) FROM usage_raw")"
  assert_eq "[K06-3] control_turnos_codex coincide con el último turn_token_usage" "3500|150|1" "$(q "SELECT turno_in, turno_out, coincide FROM control_turnos_codex")"
  assert_eq "[K07] in_total de resp_fx0001 = 2000 (el cacheado ya va dentro)" "2000" "$(q "SELECT in_total FROM usage_raw WHERE unidad_id='resp_fx0001'")"
}
caso_K08() {
  echo "K08 · Codex 23.172 con 11.008 cacheados -> in_total 23.172 (fixture derivada)"
  entorno k08
  printf '{"timestamp":"2026-09-22T00:00:00.000Z","type":"token_usage_record","payload":{"session_id":"fx-thread-k08","turn_id":"fx-turn-k08","response_id":"resp_fxk08","usage":{"input_tokens":23172,"cached_input_tokens":11008,"output_tokens":10},"turn_token_usage":{"input_tokens":23172,"output_tokens":10}}}\n' > "$E/codex/k08.jsonl"
  tick
  assert_eq "[K08] in_total = 23172 (nunca 34180)" "23172" "$(q "SELECT in_total FROM usage_raw WHERE unidad_id='resp_fxk08'")"
}
caso_K09() {
  echo "K09 · token_count -> 0 filas de uso y 1 muestra de cuota"
  entorno k09; cp "$FX/codex-token-count.jsonl" "$E/codex/"; tick
  assert_eq "[K09-1] 0 filas de uso" "0" "$(q "SELECT count(*) FROM usage_raw")"
  assert_eq "[K09-2] 1 muestra 10080|1790000000" "1|10080|1790000000" "$(q "SELECT count(*), max(window_minutes), max(resets_at) FROM cuota_muestras")"
}
caso_K10() {
  echo "K10 · model/effort del turn_context VIGENTE en cada punto"
  entorno k10
  { printf '{"type":"turn_context","payload":{"model":"gpt-fx-a","effort":"high"}}\n'
    printf '{"timestamp":"2026-09-22T00:00:01Z","type":"token_usage_record","payload":{"session_id":"fx-thread-k10","turn_id":"fx-t1","response_id":"resp_fxk10a","usage":{"input_tokens":1,"output_tokens":1}}}\n'
    printf '{"type":"turn_context","payload":{"model":"gpt-fx-b","effort":"low"}}\n'
    printf '{"timestamp":"2026-09-22T00:00:02Z","type":"token_usage_record","payload":{"session_id":"fx-thread-k10","turn_id":"fx-t2","response_id":"resp_fxk10b","usage":{"input_tokens":1,"output_tokens":1}}}\n'; } > "$E/codex/k10.jsonl"
  tick
  assert_eq "[K10-1] rec1 -> gpt-fx-a|high" "gpt-fx-a|high" "$(q "SELECT model, effort FROM usage_raw WHERE unidad_id='resp_fxk10a'")"
  assert_eq "[K10-2] rec2 -> gpt-fx-b|low" "gpt-fx-b|low" "$(q "SELECT model, effort FROM usage_raw WHERE unidad_id='resp_fxk10b'")"
}

# ── K11-K16: subagentes, origen del turno y fase ─────────────────────────────────────────────
caso_K11() {
  echo "K11 · subagente descubierto en subagents/, misma sesión que la madre"
  entorno k11; cp -r "$FX/claude-subagente" "$E/claude/p/"; tick
  assert_eq "[K11-1] 2 unidades en fx-session-0003" "2" "$(q "SELECT count(*) FROM usage_raw WHERE session_id='fx-session-0003'")"
  assert_eq "[K11-2] sub: es_subagente=1, agent_type=Explore" "1|Explore" "$(q "SELECT es_subagente, agent_type FROM usage_raw WHERE unidad_id='msg_fx0003sub'")"
  assert_eq "[K11-3] madre: es_subagente=0" "0" "$(q "SELECT es_subagente FROM usage_raw WHERE unidad_id='msg_fx0003madre'")"
}
caso_K12_K13() {
  echo "K12-K13 · origen cron por la cadena del fire; manual desde una raíz de usuario"
  entorno k12; cp "$FX/claude-cron-y-manual.jsonl" "$E/claude/p/"; escribibles
  asistente fx-session-0004 fx-a-0002 fx-manual-0001 msg_fx0004m 1 >> "$E/claude/p/claude-cron-y-manual.jsonl"
  tick
  assert_eq "[K12] msg_fx0004a -> cron" "cron" "$(q "SELECT origen_turno FROM usage_raw WHERE unidad_id='msg_fx0004a'")"
  assert_eq "[K13] msg_fx0004m -> manual" "manual" "$(q "SELECT origen_turno FROM usage_raw WHERE unidad_id='msg_fx0004m'")"
}
caso_K14() {
  echo "K14 · el fire del tick ANTERIOR sigue encadenando (DAG persistido)"
  entorno k14
  head -1 "$FX/claude-cron-y-manual.jsonl" > "$E/claude/p/k14.jsonl"; tick
  tail -n +2 "$FX/claude-cron-y-manual.jsonl" >> "$E/claude/p/k14.jsonl"; tick
  assert_eq "[K14] msg_fx0004a sigue siendo cron" "cron" "$(q "SELECT origen_turno FROM usage_raw WHERE unidad_id='msg_fx0004a'")"
}
caso_K15_K16() {
  echo "K15-K16 · fase: plan solo con permissionMode=plan; coordinacion solo por rol"
  entorno k15
  local coord_cwd="/srv/sintetico/coord"
  { printf '{"type":"user","uuid":"fx-k15-u1","parentUuid":null,"sessionId":"fx-s-k15","permissionMode":"plan"}\n'
    asistente fx-s-k15 fx-k15-a1 fx-k15-u1 msg_fxk15a1 1
    printf '{"type":"user","uuid":"fx-k15-u2","parentUuid":"fx-k15-a1","sessionId":"fx-s-k15","permissionMode":"bypassPermissions"}\n'
    asistente fx-s-k15 fx-k15-a2 fx-k15-u2 msg_fxk15a2 1
    asistente fx-s-k15 fx-k15-a3 fx-k15-a2 msg_fxk15a3 1 "" "\"cwd\":\"$coord_cwd\""; } > "$E/claude/p/k15.jsonl"
  printf 'torre\ttorre-sint\tmaq-sint\t-\tses-sint\trol=coordinador;cwd=%s;pane_kind=dev\n' "$coord_cwd" >> "$TA_PERFIL"
  tick
  assert_eq "[K15-1] a1 -> plan" "plan" "$(q "SELECT fase FROM usage_raw WHERE unidad_id='msg_fxk15a1'")"
  assert_eq "[K15-2] a2 (bypassPermissions, sin rol) -> NO MEDIDO" "NO MEDIDO" "$(q "SELECT fase FROM usage_raw WHERE unidad_id='msg_fxk15a2'")"
  assert_eq "[K16-1] a3 (cwd del coordinador) -> coordinacion" "coordinacion" "$(q "SELECT fase FROM usage_raw WHERE unidad_id='msg_fxk15a3'")"
  assert_eq "[K16-2] a3 -> part_id|rol|pane_kind del perfil" "torre-sint|coordinador|dev" "$(q "SELECT part_id, rol, pane_kind FROM usage_raw WHERE unidad_id='msg_fxk15a3'")"
}

# ── K17-K18: coste ───────────────────────────────────────────────────────────────────────────
caso_K17_K18() {
  echo "K17-K18 · coste por precios.tsv con desde_fecha; modelo sin fila -> NULL + NO MEDIDO"
  entorno k17
  { printf '2026-01-01\tclaude-fx-modelo-a\t1\t1\t1\t1\t1\tsintetico\n'
    printf '2027-01-01\tclaude-fx-modelo-a\t2\t2\t2\t2\t2\tsintetico\n'; } >> "$TALENT_MEDIDOR_PRECIOS"
  sed 's/^{/{"timestamp": "2026-09-22T12:00:00Z", /' "$FX/claude-respuesta-5-registros.jsonl" > "$E/claude/p/k18.jsonl"
  printf '{"type":"assistant","timestamp":"2026-09-22T12:00:00Z","uuid":"fx-k17","parentUuid":null,"sessionId":"fx-s-k17","message":{"id":"msg_fxk17","model":"claude-fx-inexistente","usage":{"input_tokens":1,"output_tokens":1}}}\n' > "$E/claude/p/k17.jsonl"
  tick
  assert_eq "[K17] modelo desconocido -> cost_usd NULL y NO MEDIDO" "1" "$(q "SELECT count(*) FROM usage_raw WHERE unidad_id='msg_fxk17' AND cost_usd IS NULL AND cost_estado='NO MEDIDO'")"
  assert_eq "[K18] 2+0+100+50+754 tokens a 1 USD/MTok vigente = 0.000906" "0.000906|MEDIDO" "$(q "SELECT printf('%.6f', cost_usd), cost_estado FROM usage_raw WHERE unidad_id='msg_fx0001duplicado'")"
}

# ── K19-K24: pasadas, rollups, cursor ────────────────────────────────────────────────────────
caso_K19_K20() {
  echo "K19-K20 · la misma respuesta en dos pasadas: 1 fila y rollup recalculado"
  entorno k19
  asistente fx-s-k19 fx-k19-1 null msg_fxP 100 2026-09-22T12:00:01Z > "$E/claude/p/k19.jsonl"; tick
  asistente fx-s-k19 fx-k19-2 null msg_fxP 754 2026-09-22T12:00:02Z >> "$E/claude/p/k19.jsonl"; tick
  assert_eq "[K19-1] una sola fila" "1" "$(q "SELECT count(*) FROM usage_raw WHERE unidad_id='msg_fxP'")"
  assert_eq "[K19-2] out_tok = 754 (la segunda pasada actualiza)" "754" "$(q "SELECT out_tok FROM usage_raw WHERE unidad_id='msg_fxP'")"
  assert_eq "[K20] rollup_5m del bucket == recálculo directo == 754" "754|754" "$(q "SELECT (SELECT sum(out_tok) FROM rollup_5m), (SELECT sum(out_tok) FROM usage_raw)")"
}
caso_K21() {
  echo "K21 · la última línea sin salto de línea no se consume"
  entorno k21
  local l1 l2; l1="$(asistente fx-s-k21 fx-k21-1 null msg_fxk21a 1)"; l2="$(asistente fx-s-k21 fx-k21-2 null msg_fxk21b 1)"
  printf '%s\n%s' "$l1" "${l2:0:40}" > "$E/claude/p/k21.jsonl"; tick
  assert_eq "[K21-1] tick1: 1 unidad" "1" "$(q "SELECT count(*) FROM usage_raw")"
  assert_eq "[K21-2] cursor = wc -c de la línea 1" "$(printf '%s\n' "$l1" | wc -c)" "$(q "SELECT offset FROM cursores")"
  printf '%s\n%s\n' "$l1" "$l2" > "$E/claude/p/k21.jsonl"; tick
  assert_eq "[K21-3] tick2: 2 unidades" "2" "$(q "SELECT count(*) FROM usage_raw")"
}
caso_K22() {
  echo "K22 · kill -9 entre insertar el lote y su COMMIT: 0 pérdidas, 0 duplicados"
  entorno k22
  { asistente fx-s-k22 fx-k22-1 null msg_fxk22a 1; asistente fx-s-k22 fx-k22-2 null msg_fxk22b 2
    asistente fx-s-k22 fx-k22-3 null msg_fxk22c 3; } > "$E/claude/p/k22.jsonl"
  mkfifo "$E/pausa"
  TALENT_MEDIDOR_PAUSA_FIFO="$E/pausa" "${PY[@]}" "$S/recolector.py" --tick > /dev/null 2>&1 &
  local pid=$! i=0
  while [ ! -e "$E/pausa.en-pausa" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i+1)); done
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  tick
  assert_eq "[K22-1] 3 unidades tras reanudar" "3" "$(q "SELECT count(*) FROM usage_raw")"
  assert_eq "[K22-2] count(*) == count(DISTINCT session_id, unidad_id)" "3" "$(q "SELECT count(*) FROM (SELECT DISTINCT session_id, unidad_id FROM usage_raw)")"
  assert_eq "[K22-3] cursor = tamaño del fichero" "$(wc -c < "$E/claude/p/k22.jsonl")" "$(q "SELECT offset FROM cursores")"
}
caso_K23() {
  echo "K23 · segundo tick inmediato: nada que hacer"
  entorno k23; todas_las_f0; tick; tick
  assert_eq "[K23] insertadas=0 actualizadas=0" "1" "$(grep -c '^insertadas=0 actualizadas=0 ' "$E/tick.out")"
}
caso_K24() {
  echo "K24 · cursor por (inode, offset): rotación y truncado se leen desde 0"
  entorno k24
  local f="$E/claude/p/k24.jsonl"
  asistente fx-s-k24 fx-k24-1 null msg_fxk24a 1 > "$f"; tick
  { asistente fx-s-k24 fx-k24-2 null msg_fxk24b 1; asistente fx-s-k24 fx-k24-3 null msg_fxk24c 1
    asistente fx-s-k24 fx-k24-4 null msg_fxk24d 1; } > "$E/nuevo.jsonl"
  mv "$E/nuevo.jsonl" "$f"; tick
  assert_eq "[K24-1] fichero nuevo (otro inode, MÁS largo): sus 3 unidades" "3" "$(q "SELECT count(*) FROM usage_raw WHERE unidad_id IN ('msg_fxk24b','msg_fxk24c','msg_fxk24d')")"
  asistente fx-s-k24 fx-k24-5 null msg_fxk24e 1 > "$f"; tick
  assert_eq "[K24-2] truncado (mismo inode, más corto): su unidad" "1" "$(q "SELECT count(*) FROM usage_raw WHERE unidad_id='msg_fxk24e'")"
}

# ── K25-K31: eje de datos de personas ────────────────────────────────────────────────────────
ALLOWLIST='agent_type cache_r cache_w cache_w_1h cache_w_5m cursor cwd_sha descartadas_json effort es_subagente estado_cwd_sha estado_effort estado_model in_tok in_total k lineas model orden out_tok parent_uuid permission_mode proveedor rechazadas_forma resets_at session_id subtipo thinking_tok tipo ts ts_month turn_id turno_in turno_out unidad_id used_percent uuid uuids ventana window_minutes'
RE_CORREO='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
RE_IPV4='(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9.]|$)'
caso_K25() {
  echo "K25 · extractor sin fugas sobre la trampa de F0"
  assert_eq "[K25-1] control positivo: la fixture SÍ lleva \"content\" (2 apariciones)" "2" "$(grep -o '"content"' "$FX/trampa-contenido.jsonl" | wc -l)"
  "${PY[@]}" "$S/extractor.py" "$FX/trampa-contenido.jsonl" > "$T/k25.out"; local rc=$?
  assert_eq "[K25-2] rc del extractor" "0" "$rc"
  assert_eq "[K25-3] la unidad sale" "1" "$(grep -c 'msg_fx0007trampa' "$T/k25.out")"
  assert_eq "[K25-4] 0 líneas con content/text/tool_use/TRAMPA-SINTETICA" "0" "$(grep -cE '"content"|"text"|tool_use|TRAMPA-SINTETICA' "$T/k25.out")"
}
caso_K26() {
  echo "K26 · claves de salida ⊆ allowlist LITERAL; ningún objeto anidado"
  : > "$T/k26.out"
  local f
  for f in "$FX"/claude-*.jsonl "$FX"/claude-subagente/madre.jsonl "$FX"/claude-subagente/subagents/*.jsonl "$FX"/trampa-contenido.jsonl; do
    "${PY[@]}" "$S/extractor.py" "$f" >> "$T/k26.out"
  done
  for f in "$FX"/codex-*.jsonl; do "${PY[@]}" "$S/extractor_codex.py" "$f" >> "$T/k26.out"; done
  printf '{"type":"assistant","uuid":"fx-k26","parentUuid":null,"sessionId":"fx-s-k26","requestId":"192.0.2.77","message":{"id":"msg_fxk26","model":"claude-fx-modelo-a","usage":{"input_tokens":1,"output_tokens":1}}}\n' > "$T/k26-ip.jsonl"
  "${PY[@]}" "$S/extractor.py" "$T/k26-ip.jsonl" >> "$T/k26.out"
  local fuera
  fuera="$(jq -r 'keys[]' "$T/k26.out" | sort -u | while read -r k; do case " $ALLOWLIST " in *" $k "*) : ;; *) printf '%s ' "$k" ;; esac; done)"
  assert_eq "[K26-1] claves fuera de la allowlist" "" "$fuera"
  assert_eq "[K26-2] requestId con IPv4 no sale; ningún valor objeto" "0|0" "$(grep -c '192\.0\.2\.77' "$T/k26.out")|$(jq -r '.[] | objects' "$T/k26.out" | wc -l)"
}
caso_K27_K31() {
  echo "K27-K31 · forma, cwd, prefijos de token, meta y barrido del almacén"
  entorno pii; cp "$FX/trampa-contenido.jsonl" "$E/claude/p/"; cp -r "$FX/claude-subagente" "$E/claude/p/"
  local tok home_lit="/home/usuario-sintetico/proyecto"
  tok="gh""p_""AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  { printf '{"type":"assistant","uuid":"fx-k27a","parentUuid":null,"sessionId":"fx-s-k27","message":{"id":"msg_fxk27a","model":"persona.sintetica@example.com","usage":{"input_tokens":1,"output_tokens":1}}}\n'
    printf '{"type":"assistant","uuid":"fx-k27b","parentUuid":null,"sessionId":"fx-s-k27","message":{"id":"msg_fxk27b","model":"192.0.2.10","usage":{"input_tokens":1,"output_tokens":1}}}\n'; } > "$E/claude/p/k27.jsonl"
  asistente fx-s-k28 fx-k28 null msg_fxk28 1 "" "\"cwd\":\"$home_lit\"" > "$E/claude/p/k28.jsonl"
  asistente "$tok" fx-k29 null msg_fxk29 1 > "$E/claude/p/k29.jsonl"
  assert_eq "[K27-1] control positivo: el patrón caza correo e IPv4 en la fixture" "1|1" "$(grep -cE "$RE_CORREO" "$E/claude/p/k27.jsonl")|$(grep -cE "$RE_IPV4" <(sed -n 2p "$E/claude/p/k27.jsonl"))"
  "${PY[@]}" "$S/extractor.py" "$E/claude/p/k27.jsonl" > "$T/k27.out"
  assert_eq "[K27-2] 2 registros rechazados por forma y 0 correo/IPv4 en la salida" "2|0|0" "$(jq -r 'select(.k=="fin") | .rechazadas_forma' "$T/k27.out")|$(grep -cE "$RE_CORREO" "$T/k27.out")|$(grep -cE "$RE_IPV4" "$T/k27.out")"
  "${PY[@]}" "$S/extractor.py" "$E/claude/p/k28.jsonl" > "$T/k28.out"
  assert_eq "[K28-1] cwd_sha == sha256sum del literal" "$(printf '%s' "$home_lit" | sha256sum | cut -d' ' -f1)" "$(jq -r 'select(.k=="unidad") | .cwd_sha' "$T/k28.out")"
  assert_eq "[K28-2] 0 apariciones del literal de la ruta" "0" "$(grep -cF "$home_lit" "$T/k28.out")"
  "${PY[@]}" "$S/extractor.py" "$E/claude/p/k29.jsonl" > "$T/k29.out"
  assert_eq "[K29] sessionId con prefijo de token: rechazado, 0 unidades" "1|0" "$(jq -r 'select(.k=="fin") | .rechazadas_forma' "$T/k29.out")|$(grep -c '"k":"unidad"' "$T/k29.out")"
  "${PY[@]}" "$S/extractor.py" "$E/claude/p/claude-subagente/subagents/agent-fx0001.jsonl" > "$T/k30.out"
  tick
  assert_eq "[K30] agent_type=Explore y 0 FIXTURE-SINTETICA en salida y DB" "Explore|0|0" "$(jq -r 'select(.k=="unidad") | .agent_type' "$T/k30.out")|$(grep -c FIXTURE-SINTETICA "$T/k30.out")|$(q "SELECT count(*) FROM usage_raw WHERE agent_type LIKE '%FIXTURE%'")"
  # K31: barrido de TODAS las columnas TEXT de TODAS las tablas, con control positivo primero.
  cat > "$T/barrido.py" <<'PY'
import re, sqlite3, sys
clases = {"contenido": r"TRAMPA-SINTETICA|FIXTURE-SINTETICA", "correo": r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}",
          "ipv4": r"(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9.]|$)", "ruta": r"/home/|/srv/", "token": r"^(gh[psour]_|sk-ant-|sbp_|lin_api_)"}
con = sqlite3.connect(sys.argv[1]); n = {c: 0 for c in clases}
for (t,) in con.execute("SELECT name FROM sqlite_master WHERE type='table'"):
    cols = [r[1] for r in con.execute("PRAGMA table_info(%s)" % t)]
    for fila in con.execute("SELECT * FROM %s" % t):
        for v in fila:
            if isinstance(v, str):
                for c, p in clases.items():
                    n[c] += bool(re.search(p, v))
print(" ".join("%s=%d" % (c, n[c]) for c in sorted(n)))
PY
  "${PY[@]}" -c 'import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); c.execute("CREATE TABLE s (v TEXT)")
for v in ("TRAMPA-SINTETICA","persona.sintetica@example.com","192.0.2.10","/home/usuario-sintetico","gh"+"p_AAAA"): c.execute("INSERT INTO s VALUES (?)",(v,))
c.commit()' "$T/senuelo.db"
  assert_eq "[K31-1] control positivo: el barrido caza cada clase en un almacén-señuelo" "contenido=1 correo=1 ipv4=1 ruta=1 token=1" "$("${PY[@]}" "$T/barrido.py" "$T/senuelo.db")"
  assert_eq "[K31-2] el almacén tras los ticks: 0 por clase" "contenido=0 correo=0 ipv4=0 ruta=0 token=0" "$("${PY[@]}" "$T/barrido.py" "$TALENT_MEDIDOR_DB")"
}

# ── K32-K37: reconciliación, fuentes, perfil, nice, unidades, auto-afirmación ────────────────
caso_K32_K33() {
  echo "K32-K33 · reconciliación independiente y fuentes intactas"
  entorno k32; todas_las_f0
  local f antes
  antes="$(find "$E/claude" "$E/codex" -type f -exec stat -c '%n %Y' {} + | sort)"
  cp -r "$E/claude" "$E/claude.orig"; cp -r "$E/codex" "$E/codex.orig"
  tick; tick
  bash "$S/reconciliar.sh" > "$E/rec.out" 2>&1; local rc=$?
  assert_eq "[K32-1] DIFERENCIA=0 con rc 0" "DIFERENCIA=0|0" "$(tail -1 "$E/rec.out")|$rc"
  q "UPDATE usage_raw SET out_tok=3770 WHERE unidad_id='msg_fx0001duplicado'" > /dev/null
  bash "$S/reconciliar.sh" > "$E/rec2.out" 2>&1; rc=$?
  assert_eq "[K32-2] con la suma por línea (3770) en la DB: DIFERENCIA=3016, rc 1" "DIFERENCIA=3016|1" "$(tail -1 "$E/rec2.out")|$rc"
  local dif=0
  diff -r "$E/claude" "$E/claude.orig" > /dev/null || dif=1
  diff -r "$E/codex" "$E/codex.orig" > /dev/null || dif=1
  [ "$antes" = "$(find "$E/claude" "$E/codex" -type f -exec stat -c '%n %Y' {} + | sort)" ] || dif=1
  assert_eq "[K33] fuentes byte a byte iguales y mtime sin cambios" "0" "$dif"
}
caso_K34() {
  echo "K34 · perfil con id duplicado (V4): NO MEDIDO en todo, aviso con rc 2"
  entorno k34
  asistente fx-s-k34 fx-k34 null msg_fxk34 1 "" '"cwd":"/srv/sintetico/coord"' > "$E/claude/p/k34.jsonl"
  { printf 'torre\ttorre-sint\tmaq-sint\t-\tses-sint\trol=coordinador;cwd=/srv/sintetico/coord\n'
    printf 'canal\ttorre-sint\tmaq-sint\t-\tses-otra\trol=produccion\n'; } >> "$TA_PERFIL"
  tick
  assert_eq "[K34-1] aviso de perfil con rc 2" "1" "$(grep -c '^aviso_perfil rc=2' "$E/tick.err")"
  assert_eq "[K34-2] part_id NO MEDIDO en todas las filas" "0" "$(q "SELECT count(*) FROM usage_raw WHERE part_id <> 'NO MEDIDO'")"
}
caso_K35() {
  echo "K35 · --bootstrap corre bajo nice 19"
  entorno k35
  assert_eq "[K35] niceness=19" "niceness=19" "$("${PY[@]}" "$S/recolector.py" --bootstrap --diagnostico)"
}
caso_K36() {
  echo "K36 · instalar-unidades --sin-activar: timer de 5 min y 0 llamadas a systemctl"
  entorno k36
  mkdir -p "$E/bin" "$E/home"
  printf '#!/bin/sh\necho "$@" >> "%s/systemctl.log"\n' "$E" > "$E/bin/systemctl"; chmod +x "$E/bin/systemctl"
  PATH="$E/bin:$PATH" HOME="$E/home" bash "$S/instalar-unidades.sh" --solo recolector --destino "$E/units" --sin-activar > /dev/null
  assert_eq "[K36-1] el .timer lleva OnUnitActiveSec=5min" "1" "$(grep -c '^OnUnitActiveSec=5min$' "$E/units/talent-medidor-recolector.timer")"
  assert_eq "[K36-2] 0 llamadas a systemctl y nada en HOME/.config" "0|no" "$( [ -f "$E/systemctl.log" ] && wc -l < "$E/systemctl.log" || echo 0)|$( [ -e "$E/home/.config" ] && echo si || echo no)"
}
# ── K38-K39: ráfaga de partes y neutralidad del paquete ─────────────────────────────────────
# copias_claude <fichero> <sesion> <message.id> <out> <cwd> : 5 registros idénticos de UNA respuesta.
copias_claude() {
  local i
  for i in 1 2 3 4 5; do
    asistente "$2" "fx-$3-$i" null "$3" "$4" "2026-09-22T12:00:0$i""Z" "\"cwd\":\"$5\""
  done >> "$1"
}
# copias_codex <fichero> <sesion> <response_id> <out> : 5 registros idénticos de UNA respuesta.
copias_codex() {
  local i
  for i in 1 2 3 4 5; do
    printf '{"timestamp":"2026-09-22T13:00:0%s.000Z","type":"token_usage_record","payload":{"session_id":"%s","turn_id":"fx-turno-%s","response_id":"%s","usage":{"input_tokens":10,"output_tokens":%s}}}\n' \
      "$i" "$2" "$2" "$3" "$4"
  done >> "$1"
}
caso_K38() {
  echo "K38 · ráfaga de partes: qué parte gastó qué, con 5 copias por respuesta y dos proveedores"
  entorno k38
  local pa=/srv/sintetico/pa pb=/srv/sintetico/pb pc=/srv/sintetico/pc pd=/srv/sintetico/pd
  { printf 'torre\ttorre-a\tmaq-sint\t-\tses-a\trol=coordinador;cwd=%s;pane_kind=dev\n' "$pa"
    printf 'canal\tcanal-b\tmaq-sint\t-\tses-b\trol=produccion;cwd=%s;pane_kind=dev\n' "$pb"
    printf 'estacion\testacion-c\tmaq-sint\t-\tses-c\trol=mergeador;cwd=%s;pane_kind=aud\n' "$pc"
    printf 'canal\tcanal-d\tmaq-sint\t-\tses-d\trol=produccion\n'; } >> "$TA_PERFIL"
  # Claude: parte A = 100 + 40, parte B = 300, un cwd que el perfil no declara = 11.
  : > "$E/claude/p/k38-a.jsonl"; : > "$E/claude/p/k38-b.jsonl"; : > "$E/claude/p/k38-d.jsonl"
  copias_claude "$E/claude/p/k38-a.jsonl" fx-s-k38a msg_fxk38a1 100 "$pa"
  copias_claude "$E/claude/p/k38-a.jsonl" fx-s-k38a msg_fxk38a2 40 "$pa"
  copias_claude "$E/claude/p/k38-b.jsonl" fx-s-k38b msg_fxk38b1 300 "$pb"
  copias_claude "$E/claude/p/k38-d.jsonl" fx-s-k38d msg_fxk38d1 11 "$pd"
  # Codex: parte C = 25 + 75, y la parte B también gasta por Codex = 7.
  { printf '{"type":"turn_context","payload":{"model":"gpt-fx-a","effort":"high","cwd":"%s"}}\n' "$pc"; } > "$E/codex/k38-c.jsonl"
  copias_codex "$E/codex/k38-c.jsonl" fx-hilo-k38c resp_fxk38c1 25
  copias_codex "$E/codex/k38-c.jsonl" fx-hilo-k38c resp_fxk38c2 75
  { printf '{"type":"turn_context","payload":{"model":"gpt-fx-a","effort":"high","cwd":"%s"}}\n' "$pb"; } > "$E/codex/k38-b.jsonl"
  copias_codex "$E/codex/k38-b.jsonl" fx-hilo-k38b resp_fxk38b1 7
  tick
  local por_parte="SELECT group_concat(part_id||'='||s, ' ') FROM (SELECT part_id, sum(out_tok) s FROM %s GROUP BY part_id ORDER BY part_id)"
  # shellcheck disable=SC2059
  assert_eq "[K38-1] reparto literal por parte (NO MEDIDO = el cwd fuera del perfil)" \
    "NO MEDIDO=11 canal-b=307 estacion-c=100 torre-a=140" "$(q "$(printf "$por_parte" usage_raw)")"
  assert_eq "[K38-2] 7 respuestas (35 registros) y Σ out = 558" "7|558" "$(q "SELECT count(*), sum(out_tok) FROM usage_raw")"
  assert_eq "[K38-3] sumar por registro daría 2790; el almacén dice 558 (5 copias por respuesta)" "2790|558" \
    "$(jq -s '[.[] | (.message.usage.output_tokens // .payload.usage.output_tokens // empty)] | add' "$E"/claude/p/k38-*.jsonl "$E"/codex/k38-*.jsonl)|$(q "SELECT sum(out_tok) FROM usage_raw")"
  bash "$S/reconciliar.sh" > "$E/rec.out" 2>&1; local rc=$?
  assert_eq "[K38-4] reconciliar.sh (jq independiente): DIFERENCIA=0 y rc 0" "DIFERENCIA=0|0" "$(tail -1 "$E/rec.out")|$rc"
  # shellcheck disable=SC2059
  assert_eq "[K38-5] los rollups 5m/1h/1d suman 558 y 1h repite el reparto por parte" \
    "558|558|558|NO MEDIDO=11 canal-b=307 estacion-c=100 torre-a=140" \
    "$(q "SELECT (SELECT sum(out_tok) FROM rollup_5m), (SELECT sum(out_tok) FROM rollup_1h), (SELECT sum(out_tok) FROM rollup_1d)")|$(q "$(printf "$por_parte" rollup_1h)")"
  assert_eq "[K38-6] sin tarifa en precios.tsv: las 7 respuestas son NO MEDIDO con cost_usd NULL (nunca 0)" "7|0" \
    "$(q "SELECT count(*) FROM usage_raw WHERE cost_usd IS NULL AND cost_estado='NO MEDIDO'")|$(q "SELECT count(*) FROM usage_raw WHERE cost_usd = 0")"
  mkdir -p "$E/sinjq" "$E/sinpy"
  ln -s "$(command -v jq)" "$E/sinpy/jq"
  PATH="$E/sinjq" "$(command -v bash)" "$S/reconciliar.sh" > "$E/sinjq.out" 2>&1; rc=$?
  assert_eq "[K38-7] sin jq: rc 2, mensaje y ningún DIFERENCIA=0 fabricado" "2|1|0" "$rc|$(grep -c 'jq ausente' "$E/sinjq.out")|$(grep -c '^DIFERENCIA=0' "$E/sinjq.out")"
  PATH="$E/sinpy" "$(command -v bash)" "$S/reconciliar.sh" > "$E/sinpy.out" 2>&1; rc=$?
  assert_eq "[K38-8] sin python3: rc 2, mensaje y ningún DIFERENCIA=0 fabricado" "2|1|0" "$rc|$(grep -c 'python3 ausente' "$E/sinpy.out")|$(grep -c '^DIFERENCIA=0' "$E/sinpy.out")"
}
caso_K39() {
  echo "K39 · neutralidad del árbol del skill y base declarada (Python 3.12, SQLite 3.24+, jq 1.6+)"
  local p_modelo='claude-(opus|sonnet|haiku)-[0-9]' p_issue='T[A]L-[0-9]' p_anexo='anexo-talent-academ[y]' h1 h2 h3
  assert_eq "[K39-1] control positivo: los tres patrones cazan una línea sembrada cada uno" "3" \
    "$(printf 'claude-%s-5\nT%s-7\nanexo-talent-%s\n' sonnet AL academy | grep -cE "$p_modelo|$p_issue|$p_anexo")"
  h1="$(grep -rhE -e "$p_modelo" "$ROOT" | wc -l)"
  h2="$(grep -rhE -e "$p_issue" "$ROOT" | wc -l)"
  h3="$(grep -rhE -e "$p_anexo" "$ROOT" | wc -l)"
  assert_eq "[K39-2] 0 IDs de modelo, 0 claves de issue y 0 anexo de instancia en TODO el árbol (.jsonl incluidos)" "0|0|0" "$h1|$h2|$h3"
  assert_eq "[K39-3] ningún fichero anexo-* en el árbol (el paquete no lleva overlays)" "0" "$(find "$ROOT" -name 'anexo-*' | wc -l)"
  "${PY[@]}" -c 'import ast, sys
for f in sys.argv[1:]:
    ast.parse(open(f, encoding="utf-8").read(), feature_version=(3,12))' "$S/extractor.py" "$S/extractor_codex.py" "$S/recolector.py" > /dev/null 2>&1; local rc=$?
  assert_eq "[K39-4] los 3 .py se parsean con feature_version=(3,12) (Python de la base declarada)" "0" "$rc"
  "${PY[@]}" -c 'import ast
ast.parse("match 1:\n    case 1:\n        pass\n", feature_version=(3,9))' > /dev/null 2>&1; rc=$?
  assert_eq "[K39-5] control negativo: el mismo parseo SÍ rechaza sintaxis posterior a la versión pedida" "1" "$rc"
  assert_eq "[K39-6] SQLite >= 3.24.0 (el upsert ON CONFLICT DO UPDATE lo exige)" "1" \
    "$("${PY[@]}" -c 'import sqlite3; print(1 if sqlite3.sqlite_version_info >= (3, 24, 0) else 0)')"
  local v mayor resto menor; v="$(jq --version 2>/dev/null)"; v="${v#jq-}"; mayor="${v%%.*}"; resto="${v#*.}"; menor="${resto%%[!0-9]*}"
  assert_eq "[K39-7] jq >= 1.6" "1" "$( case "$mayor$menor" in ''|*[!0-9]*) echo 0 ;; *) if [ "$mayor" -gt 1 ] || { [ "$mayor" -eq 1 ] && [ "$menor" -ge 6 ]; }; then echo 1; else echo 0; fi ;; esac )"
}
caso_K40() {
  echo "K40 · cwd repetido en el perfil: gana la última fila que emite el recolector, y la guía lo dice"
  entorno k40
  local pc=/srv/sintetico/comun
  { printf 'torre\ttorre-a\tmaq-sint\t-\tses-a\trol=produccion;cwd=%s\n' "$pc"
    printf 'torre\ttorre-b\tmaq-sint\t-\tses-b\trol=produccion;cwd=%s\n' "$pc"; } >> "$TA_PERFIL"
  asistente fx-s-k40 fx-k40-1 null msg_fxk40a 5 "" "\"cwd\":\"$pc\"" > "$E/claude/p/k40.jsonl"
  tick
  assert_eq "[K40-1] mismo tipo, mismo cwd: toda la respuesta va a la segunda fila, no a NO MEDIDO" "torre-b" "$(q "SELECT part_id FROM usage_raw WHERE unidad_id='msg_fxk40a'")"
  entorno k40b
  { printf 'canal\tcanal-x\tmaq-sint\t-\tses-x\trol=produccion;cwd=%s\n' "$pc"
    printf 'torre\ttorre-y\tmaq-sint\t-\tses-y\trol=produccion;cwd=%s\n' "$pc"; } >> "$TA_PERFIL"
  asistente fx-s-k40b fx-k40-2 null msg_fxk40b 5 "" "\"cwd\":\"$pc\"" > "$E/claude/p/k40b.jsonl"
  tick
  assert_eq "[K40-2] tipos distintos: gana el tipo que se recorre después (canal), no el orden del fichero" "canal-x" "$(q "SELECT part_id FROM usage_raw WHERE unidad_id='msg_fxk40b'")"
  assert_eq "[K40-3] la guía no promete NO MEDIDO para un cwd repetido y declara que no lo comprueba" "0|1" \
    "$(grep -c 'es ambiguo: la parte sale' "$ROOT/references/instalacion.md")|$(grep -c 'NO lo comprueba ni avisa' "$ROOT/references/instalacion.md")"
}
caso_K37() {
  echo "K37 · la suite se afirma a sí misma"
  if [ "${MEDIDOR_SUITE_ANIDADA-}" = 1 ]; then ok "[K37] (copia anidada: no se re-ejecuta)"; return; fi
  sed '/^caso_K01$/d' "$HERE/run-tests.sh" > "$T/suite-sin-K01.sh"
  MEDIDOR_SUITE_ANIDADA=1 MEDIDOR_ROOT="$ROOT" bash "$T/suite-sin-K01.sh" > "$T/k37.out" 2>&1; local rc=$?
  assert_eq "[K37] sin un caso: rc≠0 y lo dice" "1|1" "$( [ "$rc" -ne 0 ] && echo 1 || echo 0)|$(grep -c '!= TOTAL_ESPERADO' "$T/k37.out")"
}

caso_K01
caso_K02
caso_K03_K05
caso_K06_K07
caso_K08
caso_K09
caso_K10
caso_K11
caso_K12_K13
caso_K14
caso_K15_K16
caso_K17_K18
caso_K19_K20
caso_K21
caso_K22
caso_K23
caso_K24
caso_K25
caso_K26
caso_K27_K31
caso_K32_K33
caso_K34
caso_K35
caso_K36
caso_K38
caso_K39
caso_K40
caso_K37

printf '\n== %d ok, %d FAIL (esperados: %d casos) ==\n' "$PASS" "$FAIL" "$TOTAL_ESPERADO"
rc=0
[ "$FAIL" -eq 0 ] || { echo "FAIL: hubo casos rojos"; rc=1; }
[ $((PASS + FAIL)) -eq "$TOTAL_ESPERADO" ] || {
  echo "FAIL: casos ejecutados $((PASS + FAIL)) != TOTAL_ESPERADO $TOTAL_ESPERADO (¿desapareció un caso?)"; rc=1; }
exit "$rc"
