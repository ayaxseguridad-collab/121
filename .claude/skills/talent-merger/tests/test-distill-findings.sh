#!/usr/bin/env bash
# test-distill-findings.sh — 20 casos del destilador de findings (scripts/distill-findings.sh).
# Repo sintético por caso (git init + .claude/ con las fixtures de tests/fixtures/distill), `gh` y el
# lector del App sustituidos por dobles en PATH / por DISTILL_FETCH_CR. Sin red ni repo real: corre igual
# dentro de un checkout que en un ZIP plano. Los esperados son LITERALES (escritos a mano) o relacionales,
# nunca recalculados con el código bajo prueba.
#
# Uso:  test-distill-findings.sh [--solo <caso>]    casos: 1 2 3 4 5 6 7a-7h 8 9 10a 10b 10c 10d
# Entorno para el corredor de mutantes: DISTILL_SCRIPT (script bajo prueba) y DISTILL_METRICA_MD (la
# referencia que documenta la métrica del caso 9). Línea final: RESULTADO: PASS=<n> FAIL=<n>.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="${DISTILL_SCRIPT:-$HERE/../scripts/distill-findings.sh}"
METRICA_MD="${DISTILL_METRICA_MD:-$HERE/../references/05-canales-de-refactorizacion.md}"
FIX="$HERE/fixtures/distill"
SOLO=""
if [ "${1:-}" = "--solo" ]; then SOLO="${2:-}"; [ -n "$SOLO" ] || { echo "uso: --solo <caso>" >&2; exit 2; }; fi
[ -f "$SCRIPT" ] || { echo "no existe el script bajo prueba: $SCRIPT" >&2; exit 2; }
for dep in jq git sha256sum; do command -v "$dep" >/dev/null 2>&1 || { echo "falta $dep" >&2; exit 2; }; done

GH_V="$(gh --version 2>/dev/null | head -n 1)"; [ -n "$GH_V" ] || GH_V="gh ausente"
printf 'herramientas: %s | %s | %s | %s\n' "$(bash --version | head -n 1)" "$(jq --version)" "$(git --version)" "$GH_V"
W="$(mktemp -d)" || exit 2
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0; CASO=""; NCASOS=0

ok() { PASS=$((PASS + 1)); }
ko() { FAIL=$((FAIL + 1)); printf '  FAIL caso %s: %s\n' "$CASO" "$1"; }
eq() { if [ "$1" = "$2" ]; then ok; else ko "$3: esperaba [$2] obtuvo [$1]"; fi; }
cierto() { if "${@:2}"; then ok; else ko "$1"; fi; }
sha() { if [ -f "$1" ]; then sha256sum "$1" | cut -d' ' -f1; else echo AUSENTE; fi; }

# --- Infraestructura del repo sintético ------------------------------------------------------------
escribir_dobles() {
  cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/gh.argv"
case "$1 $2" in
  "repo view") echo acme/widgets; exit 0 ;;
  "pr list")
    head=""; prev=""
    for a in "$@"; do [ "$prev" = "--head" ] && head="$a"; prev="$a"; done
    if [ -n "$head" ]; then
      while IFS== read -r k v; do [ "$k" = "$head" ] && echo "$v"; done < "$STUB_DIR/heads.map"
      exit 0
    fi
    cat "$STUB_DIR/prlist.json"; exit 0 ;;
esac
exit 99
EOF
  cat > "$STUB/fetch_cr_comments.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/fetch.argv"
[ "$#" -eq 2 ] || exit 9
cat "$STUB_DIR/threads-$2.json" 2>/dev/null || true
EOF
  chmod +x "$BIN/gh" "$STUB/fetch_cr_comments.sh"
}
nuevo_repo() { # $1 nombre del caso · $2 fixture (opcional) · $3 sufijo del directorio del repo (opcional)
  R="$W/$1/repo${3:-}"; STUB="$W/$1/stub"; BIN="$W/$1/bin"; SHA_ALM0=""
  mkdir -p "$R/.claude/memory" "$STUB" "$BIN"
  git -C "$R" init -q 2>/dev/null || true
  printf 'gotchas senuelo\n' > "$R/.claude/memory/gotchas.md"
  SHA_GOTCHAS0="$(sha "$R/.claude/memory/gotchas.md")"
  echo '[]' > "$STUB/prlist.json"; : > "$STUB/heads.map"
  local d="${2:+$FIX/$2}" pair
  if [ -n "$d" ]; then
    for pair in history.jsonl:.cr-review-history.jsonl findings.jsonl:.cr-review-findings.jsonl known-debt.jsonl:.cr-review-known-debt.jsonl; do
      [ ! -f "$d/${pair%%:*}" ] || cp "$d/${pair%%:*}" "$R/.claude/${pair#*:}"
    done
    [ ! -f "$d/prlist.json" ] || cp "$d/prlist.json" "$STUB/prlist.json"
    [ ! -f "$d/heads.map" ] || cp "$d/heads.map" "$STUB/heads.map"
    cp "$d"/threads-*.json "$STUB/" 2>/dev/null || true
  fi
  escribir_dobles
}
almacenes_sha() { sha "$R/.claude/.cr-review-history.jsonl"; sha "$R/.claude/.cr-review-findings.jsonl"; sha "$R/.claude/.cr-review-known-debt.jsonl"; }
run() { # argumentos del script -> RC OUT ERR
  [ -n "$SHA_ALM0" ] || SHA_ALM0="$(almacenes_sha)"
  ( cd "$R" && PATH="$BIN:$PATH" STUB_DIR="$STUB" DISTILL_FETCH_CR="$STUB/fetch_cr_comments.sh" bash "$SCRIPT" "$@" ) > "$STUB/stdout" 2> "$STUB/stderr"
  RC=$?
  OUT="$(cat "$STUB/stdout")"; ERR="$(cat "$STUB/stderr")"
}
invariantes() { # ningún almacén cambia y gotchas.md no se toca nunca
  eq "$(almacenes_sha)" "$SHA_ALM0" "los tres almacenes .cr-review-* quedan intactos (sha256)"
  eq "$(sha "$R/.claude/memory/gotchas.md")" "$SHA_GOTCHAS0" "gotchas.md senuelo intacto (sha256)"
}
CAND() { echo "$R/.claude/.gotcha-candidates.jsonl"; }
WMK() { echo "$R/.claude/.distill-watermark.json"; }
PEND() { echo "$R/.claude/.distill-pending.json"; }
salidas_sha() { sha "$(CAND)"; sha "$(WMK)"; sha "$(PEND)"; }

# --- Caso 1: el mismo finding en history (3 runs) + findings + known-debt de UN PR cuenta UNA vez --------
caso_1() {
  nuevo_repo caso1 caso1
  run --limit 10
  eq "$RC" 0 "rc"
  eq "$(printf '%s\n' "$OUT" | jq -s 'length')" 1 "un candidato en total (el known-debt ajeno no cuenta)"
  eq "$(printf '%s' "$OUT" | jq -r '.count')" 1 "count por vehiculo, no por registro ni por run"
  eq "$(printf '%s' "$OUT" | jq -c '.vehicles')" '["101"]' "vehicles"
  eq "$(printf '%s' "$OUT" | jq -r '.waived')" true "waived derivado por fp del known-debt"
  eq "$(printf '%s' "$OUT" | jq -c '.occurrence_fps')" '["22fa6fabfc60da433be2bd563eef941c129022f97ae5bf8b78965f030fa2db87"]' "precedencia history > findings en occurrence_fps"
  eq "$(printf '%s' "$OUT" | jq -r '.primera_vez + " " + .ultima_vez')" "2026-10-01T10:00:00Z 2026-10-03T10:00:00Z" "primera y ultima vez"
  invariantes
}

# --- Caso 2: el mismo candidate_key en 2 PR con fp distintos ---------------------------------------------
caso_2() {
  nuevo_repo caso2 caso2
  run --limit 10
  eq "$RC" 0 "rc"
  eq "$(printf '%s\n' "$OUT" | jq -s 'length')" 1 "un solo candidato (la identidad no es el fp)"
  eq "$(printf '%s' "$OUT" | jq -r '.count')" 2 "count 2"
  eq "$(printf '%s' "$OUT" | jq -c '.occurrence_fps')" '["b69f1ea0062b0f38a17b48c8c2e98b499c51a9046e4941bbf2514446f77bd879","d86231fccf1866622510c851375fd6d6da3922ced2ef90073a4d04d746e610d9"]' "dos occurrence_fps"
  eq "$(printf '%s' "$OUT" | jq -c '.vehicles')" '["201","202"]' "vehicles = los dos PR (la rama se resuelve a PR)"
  local antes; antes="$(sha "$(CAND)")"
  run --limit 10
  eq "$(sha "$(CAND)")" "$antes" "repetir la ejecucion es idempotente (el fichero acumulativo no cambia)"
  invariantes
}

# --- Caso 3: estabilidad de candidate_key y forma del fragmento -------------------------------------------
caso_3() {
  nuevo_repo caso3 caso3
  run --limit 20 --markdown
  eq "$RC" 0 "rc"
  local f; f="$(CAND)"
  eq "$(jq -s 'length' "$f")" 2 "cinco titulos del mismo tema = una key; otro tema = otra"
  local a; a="$(jq -c 'select(.title_stem == "unvalidated redirect target allows open redirect")' "$f")"
  eq "$(printf '%s' "$a" | jq -r '.count')" 5 "base, +linea, +ruta, +comillas y +backticks comparten key"
  eq "$(printf '%s' "$a" | jq -r '.file_class')" 'src/*.ts' "file_class de src/lib/x.ts"
  eq "$(printf '%s' "$a" | jq -r '.clase')" functional "clase"
  eq "$(printf '%s' "$a" | jq -r '.sugerencia_regla')" 'Recurrencia de functional en src/*.ts (5 vehículos): unvalidated redirect target allows open redirect' "sugerencia_regla solo con campos reducidos"
  eq "$(jq -r 'select(.title_stem != "unvalidated redirect target allows open redirect") | .count' "$f")" 1 "el otro tema queda aparte"
  eq "$(printf '%s\n' "$OUT" | grep -cxF '### [2026-10-05] unvalidated redirect target allows open redirect')" 1 "cabecera del fragmento = title_stem"
  eq "$(printf '%s\n' "$OUT" | grep -c 'Unvalidated')" 0 "ningun titulo crudo en el fragmento"
  invariantes
}

# --- Caso 4: ruido (CLI minor; App minor/null, walkthrough y poema sin hilo) -> 0 candidatos ---------------
caso_4() {
  nuevo_repo caso4 caso4
  run --limit 10
  eq "$RC" 0 "rc"
  eq "$(printf '%s' "$OUT" | jq -r '.candidates')" 0 "linea de cero candidatos"
  eq "$(printf '%s' "$OUT" | jq -r '.vehiculos')" 0 "ningun vehiculo con findings graves"
  eq "$(grep -cxF 'acme/widgets 401' "$STUB/fetch.argv")" 1 "control: la Fuente B si consulto el PR 401"
  eq "$(jq -r '.candidates' "$(CAND)")" 0 "la linea de cero tambien se persiste"
  invariantes
}

# --- Caso 5: el lector del App recibe EXACTAMENTE dos argumentos y nunca el flag de fuentes agregadas -----
caso_5() {
  nuevo_repo caso5 caso5
  run --limit 10
  eq "$RC" 0 "rc"
  eq "$(cat "$STUB/fetch.argv")" 'acme/widgets 101' "argv literal del lector"
  eq "$(grep -c -e '--sources' "$STUB/fetch.argv")" 0 "ninguna llamada con el flag de fuentes agregadas"
  eq "$(grep -c -e '--sources' "$SCRIPT")" 0 "el flag no aparece en el script"
  eq "$(printf '%s\n' "$OUT" | jq -s 'length')" 1 "un candidato (solo el hilo major)"
  eq "$(printf '%s' "$OUT" | jq -c '.vehicles')" '["101"]' "vehiculo = PR"
  eq "$(printf '%s' "$OUT" | jq -r '.title_stem')" 'race condition between checkout confirmation and the webhook' "titulo del hilo"
  eq "$(printf '%s' "$OUT" | jq -c '.occurrence_fps')" '["73621bf96297a9de7a7b098473e2d29ffcbee549aa74e3618f03582a3d62f7ee"]' "occurrence_fp = sha256 del thread_id"
  eq "$(cat "$(WMK)")" '{"watermark":"2026-10-05T12:00:00Z"}' "el watermark avanza tras persistir"
  run --limit 10
  eq "$RC" 0 "segunda ejecucion"
  eq "$(wc -l < "$STUB/fetch.argv" | tr -d ' ')" 1 "el PR anterior al watermark no se vuelve a pedir"
  eq "$(jq -r '.count' "$(CAND)")" 1 "el fichero acumulativo conserva el candidato"
  eq "$(printf '%s' "$OUT" | jq -r '.candidates')" 0 "sin vehiculos nuevos el stdout es la linea de cero, no el indice"
  invariantes
}

# --- Caso 6: JSONL roto entre dos validos -> rc 3 y salida intacta ----------------------------------------
caso_6() {
  nuevo_repo caso6 caso6
  cp "$FIX/caso6/previo.jsonl" "$(CAND)"; cp "$FIX/caso6/watermark.json" "$(WMK)"
  local antes; antes="$(sha "$(CAND)") $(sha "$(WMK)")"
  run --limit 10
  eq "$RC" 3 "rc 3 = entrada invalida"
  eq "$(sha "$(CAND)") $(sha "$(WMK)")" "$antes" "salida y watermark byte a byte iguales"
  eq "$(jq -r '.motivo' "$(PEND)")" entrada_invalida "pendiente con motivo enumerado"
  invariantes
}

# --- Caso 7: saneamiento, un caso por clase, control positivo primero --------------------------------------
senuelos() {
  local at='@'
  CORREO="ana.perez${at}example.invalid"
  TOKEN="gh""p_abcdefghijklmnopqrstuvwxyzabcdefghij"
  TELEFONO="5512345678"
  TARJETA="4111111111111111"
  CABECERA="authorization: bearer qzxwvbnmkjhg"
  SECRETO="password=hunterhunter"
  CUERPO_ID="idopaco-zzqxwvbn"
  CUERPO_NOMBRE="Marta Ejemplo Prueba"
}
hist_unica() { # $1 rama · $2 titulo : un run con un finding major; sin PR para la rama => la rama saneada es el vehiculo
  jq -n -c --arg br "$1" --arg t "$2" '{run_id: "20261007T100000Z-71", gen: {epoch: "e1", value: 1}, sha: "0000000", base_sha: "1111111", ts: "2026-10-07T10:00:00Z", branch: $br, state: "findings", seat_fp: null, finding_count: 1, findings: [{severity: "major", file: "src/m.ts", lineStart: 5, lineEnd: 9, title: $t, category: "security", fp: "9223edf47b6675a4173953136817845e05d8224e8a78bae0c8d5f07a984979d1"}]}' > "$R/.claude/.cr-review-history.jsonl"
}
ausente_de_salidas() { # $1 senuelo : ausente de las tres salidas, del stdout y del stderr
  local f
  for f in "$(CAND)" "$(WMK)" "$(PEND)"; do
    if [ -f "$f" ] && grep -qF -- "$1" "$f"; then ko "el senuelo aparece en ${f##*/}"; else ok; fi
  done
  if printf '%s\n%s\n' "$OUT" "$ERR" | grep -qF -- "$1"; then ko "el senuelo aparece en stdout/stderr"; else ok; fi
}
caso7_clase() { # $1 clase · $2 senuelo · $3 rama · $4 titulo
  nuevo_repo "caso7$1"
  hist_unica "$3" "$4"
  if grep -qF -- "$2" "$R/.claude/.cr-review-history.jsonl"; then ok; else ko "control positivo: el senuelo no esta en la entrada"; fi
  run --limit 5 --markdown
  eq "$RC" 0 "rc"
  eq "$(jq -s 'length' "$(CAND)")" 1 "el candidato existe (la ausencia del senuelo significa algo)"
  ausente_de_salidas "$2"
  if grep -q -- "redactado-$1" "$(CAND)"; then ok; else ko "el saneador dejo su marca redactado-$1"; fi
  invariantes
}
caso_7a() { senuelos; caso7_clase correo "$CORREO" "fix/${CORREO}" "Logger prints ${CORREO} in debug output"; }
caso_7b() { senuelos; caso7_clase telefono "$TELEFONO" "fix/llamar-${TELEFONO}" "Retry loop never terminates"; }
caso_7c() { senuelos; caso7_clase token "$TOKEN" "fix/${TOKEN}" "Deploy script echoes ${TOKEN} to the console"; }
caso_7e() { senuelos; caso7_clase cabecera "$CABECERA" "fix/log-de-cabeceras" "Debug log prints ${CABECERA}"; }
caso_7f() { senuelos; caso7_clase financiero "$TARJETA" "fix/pago-${TARJETA}" "Checkout total is computed twice"; }
caso_7g() { senuelos; caso7_clase secreto "$SECRETO" "fix/config-segura" "Config file stores ${SECRETO} in plain text"; }
caso_7d() { # el cuerpo del finding (CLI: description; App: body) no se persiste jamas
  senuelos
  nuevo_repo caso7d
  local cuerpo="Detalle interno con ${CUERPO_ID} que menciona a ${CUERPO_NOMBRE} en el texto."
  jq -n -c --arg d "$cuerpo" '{severity: "major", file: "src/m.ts", lineStart: 5, lineEnd: 9, title: "Order total is computed twice", description: $d, prompt: $d, category: "functional", fpMaterial: [$d, null, null, null, $d], run_id: "20261007T100000Z-72", gen: {epoch: "e1", value: 1}}' > "$R/.claude/.cr-review-findings.jsonl"
  echo '[{"number":701,"mergedAt":"2026-10-07T12:00:00Z","headRefName":"feat/cuerpo"}]' > "$STUB/prlist.json"
  jq -n --arg b "$(printf '_⚠️ Potential issue_ | _🟠 Major_\n\n**Stock is decremented twice**\n\n%s' "$cuerpo")" '{thread_id: "PRRT_cuerpo_1", path: "src/s.ts", category: "bug", severity: "major", body: $b}' > "$STUB/threads-701.json"
  if grep -qF -- "$CUERPO_ID" "$R/.claude/.cr-review-findings.jsonl" && grep -qF -- "$CUERPO_NOMBRE" "$STUB/threads-701.json"; then ok; else ko "control positivo: el cuerpo no esta en las entradas"; fi
  run --limit 5 --markdown
  eq "$RC" 0 "rc"
  eq "$(jq -s 'length' "$(CAND)")" 2 "los dos candidatos existen"
  ausente_de_salidas "$CUERPO_ID"
  ausente_de_salidas "$CUERPO_NOMBRE"
  invariantes
}
caso_7h() { # el motivo del pendiente es un codigo enumerado, nunca el texto del error de mv -T
  senuelos
  nuevo_repo caso7h "" "-${CORREO}-${TOKEN}"
  hist_unica "fix/neutra" "Lock is released twice"
  mkdir -p "$(CAND)" && : > "$(CAND)/ocupado"
  : > "$R/.claude/semilla"
  local crudo; crudo="$(mv -T -- "$R/.claude/semilla" "$(CAND)" 2>&1)"
  if printf '%s' "$crudo" | grep -qF -- "$CORREO" && printf '%s' "$crudo" | grep -qF -- "$TOKEN"; then ok; else ko "control positivo: el error crudo de mv -T no lleva los senuelos"; fi
  run --limit 5
  eq "$RC" 4 "rc 4 = persist fallido"
  eq "$(jq -r '.motivo' "$(PEND)")" persist_fallido "motivo enumerado"
  ausente_de_salidas "$CORREO"
  ausente_de_salidas "$TOKEN"
  invariantes
}

# --- Caso 8: el watermark no avanza si falla el persist (fallo SOLO en el paso de persistir) ----------------
caso_8() {
  nuevo_repo caso8 caso8
  cp "$FIX/caso8/watermark.json" "$(WMK)"
  mkdir -p "$(CAND)" && : > "$(CAND)/ocupado"
  local antes; antes="$(sha "$(WMK)")"
  run --limit 10
  eq "$RC" 4 "rc 4 = persist fallido"
  eq "$(sha "$(WMK)")" "$antes" "watermark byte a byte igual"
  eq "$(jq -r '.motivo' "$(PEND)")" persist_fallido "pendiente: motivo"
  eq "$(jq -r '.vehiculo' "$(PEND)")" 801 "pendiente: vehiculo"
  eq "$(jq -r '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' "$(PEND)")" true "pendiente: ts ISO"
  eq "$(find "$R/.claude" -maxdepth 1 -name '.gotcha-candidates.*' ! -name '.gotcha-candidates.jsonl' | wc -l | tr -d ' ')" 0 "ningun temporal .gotcha-candidates.* sobrante"
  rm -rf "$(CAND)"
  run --limit 10
  eq "$RC" 0 "reintento tras corregir el fallo"
  eq "$(cat "$(WMK)")" '{"watermark":"2026-10-04T10:00:00Z"}' "el watermark avanza solo tras persistir"
  cierto "el pendiente se retira tras persistir" test ! -e "$(PEND)"
  invariantes
}

# --- Caso 9: metrica refacto-vs-bounce, el comando se extrae del propio .md --------------------------------
caso_9() {
  nuevo_repo caso9
  local cmd res
  cmd="$(sed -n '/^# Métrica refacto-vs-bounce/,/^```$/p' "$METRICA_MD" | sed '$d')"
  if [ -n "$cmd" ]; then ok; else ko "no se pudo extraer el comando de la metrica de $METRICA_MD"; fi
  res="$(FLOCK="$FIX/caso9/flock.txt" bash -c "$cmd" 2>&1)"
  eq "$res" 'refacto-vs-bounce: numerador=3 denominador=4' "3 MERGED de 4 (MERGED + BOUNCED); la cita en prosa no cuenta"
}

# --- Caso 10: modos -----------------------------------------------------------------------------------------
caso_10a() { # --dry-run no toca ninguna salida
  nuevo_repo caso10a caso10
  cp "$FIX/caso10/previo.jsonl" "$(CAND)"; cp "$FIX/caso10/watermark.json" "$(WMK)"; cp "$FIX/caso10/pendiente.json" "$(PEND)"
  local antes; antes="$(salidas_sha)"
  run --limit 10 --dry-run
  eq "$RC" 0 "rc"
  eq "$(salidas_sha)" "$antes" "sha256 de las tres salidas identico"
  cierto "stdout no vacio" test -n "$OUT"
  eq "$(printf '%s' "$OUT" | jq -r '.count')" 2 "el dry-run calcula el resultado completo"
  invariantes
}
caso_10b() { # --pr <n>
  nuevo_repo caso10b caso10
  run --limit 10 --pr 1002
  eq "$RC" 0 "rc"
  eq "$(printf '%s' "$OUT" | jq -c '.vehicles')" '["1002"]' "solo el vehiculo pedido"
  eq "$(printf '%s' "$OUT" | jq -r '.count')" 1 "count 1"
  run --limit 10 --pr 1001
  eq "$(printf '%s' "$OUT" | jq -c '.vehicles')" '["1001"]' "con indice previo, --pr devuelve solo el vehiculo pedido"
  eq "$(jq -c '.vehicles' "$(CAND)")" '["1001","1002"]' "el fichero es acumulativo: se fusiona por candidate_key"
  invariantes
}
caso_10c() { # --since <ISO>
  nuevo_repo caso10c caso10
  run --limit 10 --since 2026-09-15
  eq "$RC" 0 "rc"
  eq "$(printf '%s' "$OUT" | jq -r '.count')" 1 "solo cuenta el registro posterior"
  eq "$(printf '%s' "$OUT" | jq -c '.vehicles')" '["1002"]' "vehiculo posterior"
  run --limit 10
  eq "$(printf '%s' "$OUT" | jq -r '.count')" 2 "sin filtro se construye el indice con los dos"
  run --limit 10 --since 2026-09-15
  eq "$(printf '%s' "$OUT" | jq -c '.vehicles')" '["1002"]' "con indice previo, --since devuelve solo lo posterior"
  eq "$(jq -r '.count' "$(CAND)")" 2 "el fichero conserva el indice completo"
  invariantes
}
caso_10d() { # --limit es obligatorio y acota los vehiculos
  nuevo_repo caso10d caso10
  run --limit 1
  eq "$RC" 0 "rc con --limit 1"
  eq "$(printf '%s' "$OUT" | jq -r '.count')" 1 "solo el vehiculo mas reciente"
  eq "$(printf '%s' "$OUT" | jq -c '.vehicles')" '["1002"]' "el mas reciente"
  run --limit 10
  eq "$(printf '%s' "$OUT" | jq -r '.count')" 2 "sin tope se construye el indice con los dos"
  run --limit 1
  eq "$(printf '%s' "$OUT" | jq -c '.vehicles')" '["1002"]' "con indice previo, --limit 1 devuelve solo el mas reciente"
  eq "$(jq -r '.count' "$(CAND)")" 2 "el fichero conserva el indice completo"
  nuevo_repo caso10d2 caso10
  cp "$FIX/caso10/previo.jsonl" "$(CAND)"; cp "$FIX/caso10/watermark.json" "$(WMK)"; cp "$FIX/caso10/pendiente.json" "$(PEND)"
  local antes; antes="$(salidas_sha)"
  run
  eq "$RC" 2 "sin --limit: rc 2 (uso invalido)"
  eq "$(salidas_sha)" "$antes" "sin --limit ninguna salida cambia"
  run --since 2026-09-15
  eq "$RC" 2 "sin --limit tampoco en otros modos"
  invariantes
}

CASOS="1 2 3 4 5 6 7a 7b 7c 7d 7e 7f 7g 7h 8 9 10a 10b 10c 10d"
if [ -n "$SOLO" ]; then
  case " $CASOS " in *" $SOLO "*) ;; *) echo "caso desconocido: $SOLO" >&2; exit 2 ;; esac
fi
for c in $CASOS; do
  [ -z "$SOLO" ] || [ "$SOLO" = "$c" ] || continue
  CASO="$c"; NCASOS=$((NCASOS + 1))
  printf '== caso %s ==\n' "$c"
  "caso_$c"
done
printf 'casos ejecutados: %s\n' "$NCASOS"
printf 'RESULTADO: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
