#!/usr/bin/env bash
# test-code-audit-go.sh — [issue 9011] M8, tercera vía SOLO con revisor=code-audit: GO de audit-gate.sh atado al
# headSha, con su run_id, archivado en el PR y comprobado por un verificador que FALLA CERRADO.
#
# Casos del contrato: M1 (GO verificado -> M8=yes via=code-audit) · M2 (otro SHA, otro run, NO-GO, ausente -> M8=no)
# · M3 (revisor=coderabbit: el GO no sustituye a CodeRabbit) · M4 (el waiver sigue igual y nunca cuenta como code-audit).
# Contrato de la revisión R9011: B1 (la respuesta parcial de comentarios se descarta entera), B2 (solo vale la corrida
# calificada como auditada sobre el COMMIT) y MA1 (el tipo del literal recibido atraviesa el archivador). Contrato de la
# revisión R9011b: B2-R (el archivador lee cada fichero de la corrida UNA vez; escritura atómica; publicación coherente).
# Contrato de la revisión R9011c: MA2 (esquema exacto de cada instantánea; ni enlaces simbólicos ni ficheros no regulares).
# Contrato de la revisión R9011d: MA3 (lo validado es, byte a byte, lo que hay en el fichero: ni un NUL se pierde en la captura).
# Contrato de la revisión R9011e: MN2 (la defensa explícita contra caracteres de control se prueba directa, sin pasar por el esquema).
# Hermético: sin red ni gh real (dobles de gh), sin tmux ni incus. Una mutación por guarda del verificador la rompe.
# shellcheck disable=SC2034,SC2317,SC2329
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$HERE/../scripts"
export TF_LINEAR_TEAM_KEY=ABC TCO_REPO_DIR=Repo-Neutro TCO_REPO_SLUG=org-neutra/Repo-Neutro TCO_REPO_STACK=ninguno
export TCO_ANEXO_FILE=references/anexo-neutro.md TCO_HOST_ENV_REL=Repo-Neutro/.env.local
export TCO_LINEAR_INPROGRESS_STATE=00000000-0000-4000-8000-000000000007
export TCO_LINEAR_INREVIEW_STATE=00000000-0000-4000-8000-000000000008
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOST_HOME="$TMP/home" SECRET_DIR="$TMP/secret"
mkdir -p "$HOST_HOME/Repo-Neutro" "$SECRET_DIR/approvals" "$SECRET_DIR/waivers" "$SECRET_DIR/runs" "$TMP/bin"
printf 'LINEAR_API_KEY=lin_neutro\n' > "$HOST_HOME/Repo-Neutro/.env.local"; chmod 600 "$HOST_HOME/Repo-Neutro/.env.local"
unset TCO_REVISOR TCO_CODE_AUDIT_TTL TCO_CODE_AUDIT_RUN_ID TCO_CODE_AUDIT_AUTHORS
# shellcheck source=/dev/null
. "$SC/00-config.sh"
# shellcheck source=/dev/null
. "$SC/lib.sh"
# shellcheck source=/dev/null
. "$SC/merge-gate.sh"   # trae tco_m8_compose, tco_m8_compose_rev y el verificador (no ejecuta main por el guard)

TOTAL_ESPERADO=182
PASS=0; FAIL=0; SKIP=0
ok() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'PASS %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL %s: actual [%s], esperado [%s]\n' "$1" "$2" "$3"; fi; }
first() { printf '%s' "${1%% *}"; }

HEAD="$(printf 'a%.0s' {1..40})"; OTHER="$(printf 'b%.0s' {1..40})"
NOW="$(date -u +%s)"; TSE=$((NOW - 600)); TSI="$(date -u -d "@$TSE" +%Y-%m-%dT%H:%M:%SZ)"
RUN="tco_${TSE}_a1b2c3d4e5f6"; RUN2="tco_${TSE}_ffffffffffff"
LEAD=lead-example
cm() { jq -n --arg l "$1" --arg c "$2" --arg b "$3" '[{login:$l, created:$c, body:$b}]'; }
vgo() { tco_code_audit_go_verify "$HEAD" "$NOW" 172800 "${1:-}" "${2:-$LEAD}" 2>/dev/null; }
body_ok="$(tco_code_audit_go_record "$RUN" "$HEAD" code "$TSI")"
# registro a mano: marcador, RUN_ID, SHA, TYP, TS y el objeto del veredicto (run, tipo, sha, veredicto, hallazgos)
rec() { # run sha typ ts jrun jtype jsha verdict findings
  printf '<!-- code-audit-go v1 -->\nRUN_ID=%s\nSHA=%s\nTYP=%s\nTS=%s\n```json\n{"run_id":"%s","artifact_type":"%s","artifact_sha":"%s","verdict":"%s","blocking_findings":%s}\n```\n' "$@"
}

echo '== M8 compositor: tco_m8_compose_rev =='
ok 'M1 code-audit + GO verificado -> yes code-audit'      "$(tco_m8_compose_rev code-audit no no no no yes)"  'yes code-audit'
ok 'M2 code-audit sin GO verificado -> no'                "$(tco_m8_compose_rev code-audit no no no no no)"   'no -'
ok 'M3 coderabbit + GO verificado NO aprueba'             "$(tco_m8_compose_rev coderabbit no no no no yes)"  'no -'
ok 'M3 revisor vacío + GO verificado NO aprueba'          "$(tco_m8_compose_rev '' no no no no yes)"          'no -'
ok 'M3 revisor desconocido + GO verificado NO aprueba'    "$(tco_m8_compose_rev inventado no no no no yes)"   'no -'
ok 'M4 waiver con label y revisor=coderabbit -> waiver'   "$(tco_m8_compose_rev coderabbit yes no no yes no)" 'yes waiver'
ok 'M4 waiver con label y revisor=code-audit -> waiver'   "$(tco_m8_compose_rev code-audit yes no no yes no)" 'yes waiver'
ok 'M4 waiver sin label sigue sin aprobar (code-audit)'   "$(tco_m8_compose_rev code-audit no no no yes no)"  'no -'
ok 'con GO verificado Y waiver gana el GO: el waiver no se consume' "$(tco_m8_compose_rev code-audit yes no no yes yes)" 'yes code-audit'
ok 'review real de CodeRabbit gana a todo'                "$(tco_m8_compose_rev code-audit yes yes yes yes yes)" 'yes review-real@head'
ok 'GO verificado no exige label cr-review'               "$(tco_m8_compose_rev code-audit no no no no yes)"  'yes code-audit'
dif=0
for rv in coderabbit '' inventado; do for l in yes no; do for c in yes no; do for r in yes no; do for w in yes no; do for g in yes no; do
  [ "$(tco_m8_compose_rev "$rv" $l $c $r $w $g)" = "$(tco_m8_compose $l $c $r $w)" ] || dif=$((dif+1))
done; done; done; done; done; done
ok 'revisor!=code-audit == tco_m8_compose en las 96 combinaciones (GO incluido)' "$dif" 0
ok 'rc del compositor: code-audit+GO -> 0' "$(tco_m8_compose_rev code-audit no no no no yes >/dev/null; echo $?)" 0
ok 'rc del compositor: coderabbit+GO -> 1' "$(tco_m8_compose_rev coderabbit no no no no yes >/dev/null; echo $?)" 1

echo '== verificador del GO: tco_code_audit_go_verify (falla cerrado) =='
ok 'V ok: GO atado al head, al run y a la hora'           "$(cm $LEAD "$TSI" "$body_ok" | vgo)" "yes $RUN"
ok 'V rc 0 en el caso verde'                              "$(cm $LEAD "$TSI" "$body_ok" | vgo >/dev/null; echo $?)" 0
ok 'V ausente: lista vacía -> no'                         "$(first "$(printf '[]' | vgo)")" no
ok 'V ausente: stdin vacío -> no'                         "$(first "$(printf '' | vgo)")" no
ok 'V ausente: JSON ilegible -> no'                       "$(first "$(printf 'basura' | vgo)")" no
ok 'V otro SHA: el registro es de otro head'              "$(cm $LEAD "$TSI" "$(tco_code_audit_go_record "$RUN" "$OTHER" code "$TSI")" | vgo)" 'no sin-registro-para-el-head'
ok 'V otro SHA: SHA del registro = head pero el objeto es de otro sha' "$(first "$(cm $LEAD "$TSI" "$(rec "$RUN" "$HEAD" code "$TSI" "$RUN" code "$OTHER" GO '[]')" | vgo)")" no
ok 'V otro run: el objeto lleva otro run_id que el registro' "$(first "$(cm $LEAD "$TSI" "$(rec "$RUN" "$HEAD" code "$TSI" "$RUN2" code "$HEAD" GO '[]')" | vgo)")" no
ok 'V otro run: run_id fijado por el operador distinto'    "$(cm $LEAD "$TSI" "$body_ok" | vgo "$RUN2")" 'no run-distinto-del-esperado'
ok 'V run fijado por el operador y coincide -> yes'        "$(cm $LEAD "$TSI" "$body_ok" | vgo "$RUN")" "yes $RUN"
ok 'V NO-GO -> no'                                         "$(cm $LEAD "$TSI" "$(rec "$RUN" "$HEAD" code "$TSI" "$RUN" code "$HEAD" NO-GO '["bloqueante"]')" | vgo)" 'no veredicto-no-go'
ok 'V NO-GO sin hallazgos listados -> no'                  "$(first "$(cm $LEAD "$TSI" "$(rec "$RUN" "$HEAD" code "$TSI" "$RUN" code "$HEAD" NO-GO '[]')" | vgo)")" no
ok 'V GO con hallazgos es incoherente -> no'               "$(first "$(cm $LEAD "$TSI" "$(rec "$RUN" "$HEAD" code "$TSI" "$RUN" code "$HEAD" GO '["x"]')" | vgo)")" no
ok 'V tipo plan no vale para el merge'                     "$(cm $LEAD "$TSI" "$(rec "$RUN" "$HEAD" plan "$TSI" "$RUN" plan "$HEAD" GO '[]')" | vgo)" 'no tipo-no-code'
ok 'V caducado (hace 3 días, run coherente)'               "$(old=$((NOW - 259200)); cm $LEAD "$(date -u -d "@$old" +%Y-%m-%dT%H:%M:%SZ)" "$(tco_code_audit_go_record "tco_${old}_a1b2c3d4e5f6" "$HEAD" code "$(date -u -d "@$old" +%Y-%m-%dT%H:%M:%SZ)")" | vgo)" 'no caducado'
ok 'V hora futura -> no'                                   "$(fut=$((NOW + 7200)); cm $LEAD "$TSI" "$(tco_code_audit_go_record "tco_${fut}_a1b2c3d4e5f6" "$HEAD" code "$(date -u -d "@$fut" +%Y-%m-%dT%H:%M:%SZ)")" | vgo)" 'no ts-futuro'
ok 'V run_id incoherente con la hora del registro'         "$(cm $LEAD "$TSI" "$(tco_code_audit_go_record "tco_$((TSE - 5000))_a1b2c3d4e5f6" "$HEAD" code "$TSI")" | vgo)" 'no run-incoherente-con-ts'
ok 'V autor ajeno al dueño del token'                      "$(cm intruso "$TSI" "$body_ok" | vgo)" 'no sin-registro-para-el-head'
ok 'V autor en la lista de varios (sin distinguir mayúsculas)' "$(cm Lead-Example "$TSI" "$body_ok" | vgo '' 'otro,lead-example')" "yes $RUN"
ok 'V sin autores permitidos -> no (fail-closed)'           "$(cm $LEAD "$TSI" "$body_ok" | tco_code_audit_go_verify "$HEAD" "$NOW" 172800 '' '' 2>/dev/null)" 'no sin-autores-permitidos'
ok 'V sin marcador -> no'                                  "$(first "$(cm $LEAD "$TSI" "${body_ok#*$'\n'}" | vgo)")" no
ok 'V marcador que no abre el comentario -> no'            "$(first "$(cm $LEAD "$TSI" "texto previo"$'\n'"$body_ok" | vgo)")" no
ok 'V registro duplicado (dos RUN_ID) -> no'               "$(first "$(cm $LEAD "$TSI" "$(printf '%s\nRUN_ID=%s' "$body_ok" "$RUN2")" | vgo)")" no
ok 'V el último registro del head manda: GO y luego NO-GO -> no' "$( { cm $LEAD "$TSI" "$body_ok"; cm $LEAD "$(date -u -d "@$((TSE + 60))" +%Y-%m-%dT%H:%M:%SZ)" "$(rec "$RUN" "$HEAD" code "$TSI" "$RUN" code "$HEAD" NO-GO '["x"]')"; } | jq -s add | vgo)" 'no veredicto-no-go'
ok 'V el último registro del head manda: NO-GO y luego GO -> yes' "$( { cm $LEAD "$TSI" "$(rec "$RUN" "$HEAD" code "$TSI" "$RUN" code "$HEAD" NO-GO '["x"]')"; cm $LEAD "$(date -u -d "@$((TSE + 60))" +%Y-%m-%dT%H:%M:%SZ)" "$body_ok"; } | jq -s add | vgo)" "yes $RUN"
ok 'V head inválido -> entrada-invalida'                   "$(printf '[]' | tco_code_audit_go_verify 'no-es-un-sha' "$NOW" 172800 '' "$LEAD" 2>/dev/null)" 'no entrada-invalida'
ok 'V hora actual no numérica -> entrada-invalida'         "$(printf '[]' | tco_code_audit_go_verify "$HEAD" 'ayer' 172800 '' "$LEAD" 2>/dev/null)" 'no entrada-invalida'

echo '== cableado REAL de M8 (tco_gather_and_gate con gh doble) =='
G_HEAD="$HEAD"; G_REVIEWS='[]'; G_LABELS='[]'; G_COMMENTS='[]'; G_VIEWER=$LEAD
gh() {
  case "$*" in
    *"api user"*) printf '%s' "$G_VIEWER" ;;
    *"headRefOid,mergeStateStatus"*) printf '{"headRefOid":"%s","mergeStateStatus":"CLEAN"}' "$G_HEAD" ;;
    *"--json statusCheckRollup"*) printf '[]' ;;
    *"--json labels"*) printf '%s' "$G_LABELS" ;;
    *"--json headRefOid --jq"*) printf '%s' "$G_HEAD" ;;
    *"/pulls/"*"/reviews"*) printf '%s' "$G_REVIEWS" ;;
    *"/issues/"*"/comments"*) printf '%s' "$G_COMMENTS"; return "${G_COMMENTS_RC:-0}" ;;
    *"api graphql"*) printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
    *) return 1 ;;
  esac
}
printf 'approved_by=prueba\n' > "$SECRET_DIR/approvals/9-$HEAD.ok"
gate() { # revisor
  GATE_OUT="$(TCO_MG_NO_LINEAR=yes TCO_REVISOR="$1" tco_gather_and_gate 9 "$HEAD" 2>&1)"; GATE_RC=$?
}
G_COMMENTS="$(cm $LEAD "$TSI" "$body_ok")"
gate code-audit
ok 'M1 gate real: GO verificado -> rc 0'                  "$GATE_RC" 0
ok 'M1 gate real: imprime M8=yes via=code-audit'           "$(printf '%s\n' "$GATE_OUT" | grep -c 'M8=yes via=code-audit')" 1
ok 'M1 gate real: la decisión final es PASS'               "$(printf '%s\n' "$GATE_OUT" | tail -1)" PASS
gate coderabbit
ok 'M3 gate real: revisor=coderabbit rechaza el mismo GO'  "$GATE_RC" 1
ok 'M3 gate real: ni rastro de via=code-audit'             "$(printf '%s\n' "$GATE_OUT" | grep -c 'via=code-audit')" 0
gate ''
ok 'M3 gate real: sin TCO_REVISOR rechaza (fail-closed)'   "$GATE_RC" 1
G_COMMENTS="$(cm $LEAD "$TSI" "$(tco_code_audit_go_record "$RUN" "$OTHER" code "$TSI")")"
gate code-audit
ok 'M2 gate real: GO de otro SHA -> rc 1'                  "$GATE_RC" 1
ok 'M2 gate real: M8 queda en no'                          "$(printf '%s\n' "$GATE_OUT" | grep -c 'M8: reviews=no')" 1
G_COMMENTS="$(cm $LEAD "$TSI" "$(rec "$RUN" "$HEAD" code "$TSI" "$RUN2" code "$HEAD" GO '[]')")"
gate code-audit
ok 'M2 gate real: GO de otro run_id -> rc 1'               "$GATE_RC" 1
G_COMMENTS="$(cm $LEAD "$TSI" "$(rec "$RUN" "$HEAD" code "$TSI" "$RUN" code "$HEAD" NO-GO '["bloqueante"]')")"
gate code-audit
ok 'M2 gate real: NO-GO -> rc 1'                           "$GATE_RC" 1
G_COMMENTS='[]'
gate code-audit
ok 'M2 gate real: GO ausente -> rc 1'                      "$GATE_RC" 1
G_COMMENTS="$(cm intruso "$TSI" "$body_ok")"
gate code-audit
ok 'M2 gate real: registro de un autor ajeno -> rc 1'      "$GATE_RC" 1
old=$((NOW - 259200)); oldi="$(date -u -d "@$old" +%Y-%m-%dT%H:%M:%SZ)"
G_COMMENTS="$(cm $LEAD "$oldi" "$(tco_code_audit_go_record "tco_${old}_a1b2c3d4e5f6" "$HEAD" code "$oldi")")"
gate code-audit
ok 'M2 gate real: GO caducado -> rc 1'                     "$GATE_RC" 1
G_COMMENTS="$(cm $LEAD "$TSI" "$body_ok")"; G_VIEWER=''
gate code-audit
ok 'M2 gate real: dueño del token no resoluble -> rc 1'    "$GATE_RC" 1
G_VIEWER=$LEAD
# B1: una respuesta PARCIAL de comentarios (gh falla tras entregar una página con un GO válido) se descarta entera.
G_COMMENTS="$(cm $LEAD "$TSI" "$body_ok")"; G_COMMENTS_RC=1
gate code-audit
ok 'B1 gate real: gh falla tras una página con GO válido -> rc 1' "$GATE_RC" 1
G_COMMENTS_RC=0
G_COMMENTS='[]'; G_LABELS='["cr-review"]'; printf 'waived_by=lead at=ahora pr=9 sha=%s\nreason=prueba\n' "$HEAD" > "$SECRET_DIR/waivers/9-$HEAD.cr-waiver"
gate code-audit
ok 'M4 gate real: el waiver aprueba igual con code-audit'  "$GATE_RC" 0
ok 'M4 gate real: se nombra via=waiver y NO code-audit'    "$(printf '%s\n' "$GATE_OUT" | grep -c 'via=waiver')/$(printf '%s\n' "$GATE_OUT" | grep -c 'via=code-audit')" '3/0'
gate coderabbit
ok 'M4 gate real: el waiver aprueba igual con coderabbit (sin cambios)' "$GATE_RC" 0
ok 'M4 gate real: coderabbit nombra via=waiver'            "$(printf '%s\n' "$GATE_OUT" | grep -c 'via=waiver')" 3

echo '== archivado del GO en el PR: verify-code-audit-go.sh --archivar =='
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  *"api user"*) printf '%s' "$G_VIEWER" ;;
  *"pr view"*"headRefOid"*) printf '%s' "$G_HEAD" ;;
  *"/issues/"*"/comments"*) cat "$COMMENTS_FILE"; exit "${COMMENTS_RC:-0}" ;;
  "pr comment"*) f=""; while [ $# -gt 0 ]; do [ "$1" = "--body-file" ] && f="$2"; shift; done; cp "$f" "$POSTED" ;;
  *) exit 1 ;;
esac
GH
chmod 755 "$TMP/bin/gh"
export G_HEAD G_VIEWER POSTED="$TMP/posted.md"
printf 'RUN_ID=%s\nSHA=%s\nTYP=code\nTS=%s\n' "$RUN" "$HEAD" "$TSI" > "$SECRET_DIR/runs/audit-last-01.env"
# [B2] calificación de lo auditado, ligada a la corrida (la escribe audit-gate.sh al decidir): RUN_ID, SHA y AUDITADO.
calif() { printf 'RUN_ID=%s\nSHA=%s\nAUDITADO=%s\n' "${2:-$RUN}" "${3:-$HEAD}" "$1" > "$SECRET_DIR/runs/audit-last-01.calificacion"; }
calif commit
printf 'Veredicto del auditor:\n{"run_id":"%s","artifact_type":"code",\n"artifact_sha":"%s","verdict":"GO",\n"blocking_findings":[]}\n' "$RUN" "$HEAD" > "$TMP/literal-go.txt"
printf 'Veredicto del auditor:\n{"run_id":"%s","artifact_type":"code","artifact_sha":"%s","verdict":"NO-GO","blocking_findings":["x"]}\n' "$RUN" "$HEAD" > "$TMP/literal-nogo.txt"
archivar() { rm -f "$POSTED"; PATH="$TMP/bin:$PATH" bash "$SC/verify-code-audit-go.sh" --archivar 9 01 "$1" >/dev/null 2>&1; }
archivar "$TMP/literal-go.txt"; rc=$?
ok 'archivar: un GO que re-verifica se publica (rc 0)'      "$rc" 0
ok 'archivar: el comentario publicado pasa el verificador' "$(cm $LEAD "$TSI" "$(cat "$POSTED" 2>/dev/null)" | vgo)" "yes $RUN"
archivar "$TMP/literal-nogo.txt"; rc=$?
ok 'archivar: un NO-GO no se publica'                       "$rc/$(test -e "$POSTED"; echo $?)" '1/1'
G_HEAD="$OTHER"; export G_HEAD
archivar "$TMP/literal-go.txt"; rc=$?
ok 'archivar: si el head del PR ya no es el auditado, no se publica' "$rc/$(test -e "$POSTED"; echo $?)" '1/1'
G_HEAD="$HEAD"; export G_HEAD
printf 'RUN_ID=%s\nSHA=%s\nTYP=plan\nTS=%s\n' "$RUN" "$HEAD" "$TSI" > "$SECRET_DIR/runs/audit-last-01.env"
archivar "$TMP/literal-go.txt"; rc=$?
ok 'archivar: el veredicto de plan no se archiva como code' "$rc/$(test -e "$POSTED"; echo $?)" '1/1'
# MA1: el tipo del veredicto LITERAL atraviesa el archivador; nunca se reconstruye desde el TYP del registro.
printf 'RUN_ID=%s\nSHA=%s\nTYP=plan\nTS=%s\n' "$RUN" "$HEAD" "$TSI" > "$SECRET_DIR/runs/audit-last-01.env"
printf 'Veredicto del auditor:\n{"run_id":"%s","artifact_type":"code","artifact_sha":"%s","verdict":"GO","blocking_findings":[]}\n' "$RUN" "$HEAD" > "$TMP/literal-code.txt"
archivar "$TMP/literal-code.txt"; rc=$?
ok 'MA1 archivar: literal code con TYP plan en el registro -> no' "$rc/$(test -e "$POSTED"; echo $?)" '1/1'
printf 'RUN_ID=%s\nSHA=%s\nTYP=code\nTS=%s\n' "$RUN" "$HEAD" "$TSI" > "$SECRET_DIR/runs/audit-last-01.env"
printf 'Veredicto del auditor:\n{"run_id":"%s","artifact_type":"plan","artifact_sha":"%s","verdict":"GO","blocking_findings":[]}\n' "$RUN" "$HEAD" > "$TMP/literal-plan.txt"
archivar "$TMP/literal-plan.txt"; rc=$?
ok 'MA1 archivar: literal plan con TYP code en el registro -> no' "$rc/$(test -e "$POSTED"; echo $?)" '1/1'
printf 'Veredicto del auditor:\n{"run_id":"%s","artifact_sha":"%s","verdict":"GO","blocking_findings":[]}\n' "$RUN" "$HEAD" > "$TMP/literal-sintipo.txt"
archivar "$TMP/literal-sintipo.txt"; rc=$?
ok 'MA1 archivar: literal sin artifact_type -> no' "$rc/$(test -e "$POSTED"; echo $?)" '1/1'
# B2: la corrida se archiva SOLO si se calificó como auditada sobre el COMMIT, y la calificación es de ESA corrida.
rm -f "$SECRET_DIR/runs/audit-last-01.calificacion"
archivar "$TMP/literal-go.txt"; rc=$?
ok 'B2 archivar: registro sin calificación (corrida anterior) -> no' "$rc/$(test -e "$POSTED"; echo $?)" '1/1'
calif commit "$RUN2"
archivar "$TMP/literal-go.txt"; rc=$?
ok 'B2 archivar: calificación de OTRA corrida -> no' "$rc/$(test -e "$POSTED"; echo $?)" '1/1'
calif commit "$RUN" "$OTHER"
archivar "$TMP/literal-go.txt"; rc=$?
ok 'B2 archivar: calificación de otro sha -> no' "$rc/$(test -e "$POSTED"; echo $?)" '1/1'
calif inventado
archivar "$TMP/literal-go.txt"; rc=$?
ok 'B2 archivar: calificación con valor ajeno -> no' "$rc/$(test -e "$POSTED"; echo $?)" '1/1'
calif working-tree
archivar "$TMP/literal-go.txt"; rc=$?
ok 'B2 archivar: corrida del working tree -> no' "$rc/$(test -e "$POSTED"; echo $?)" '1/1'
calif commit
archivar "$TMP/literal-go.txt"; rc=$?
ok 'B2 archivar: corrida del commit (control) -> se publica' "$rc/$(test -e "$POSTED"; echo $?)" '0/0'
cm $LEAD "$TSI" "$body_ok" > "$TMP/comments.json"
export COMMENTS_FILE="$TMP/comments.json"
ok 'CLI: verify-code-audit-go.sh <pr> <sha> da yes con el GO archivado' "$(first "$(PATH="$TMP/bin:$PATH" bash "$SC/verify-code-audit-go.sh" 9 "$HEAD" 2>/dev/null | tail -1)")" yes
ok 'CLI: con otro head da no y rc 1' "$(PATH="$TMP/bin:$PATH" bash "$SC/verify-code-audit-go.sh" 9 "$OTHER" >/dev/null 2>&1; echo $?)" 1

echo '== B1: la adquisición de comentarios es todo o nada (gh api --paginate) =='
pag_go="$(cm $LEAD "$TSI" "$body_ok")"
pag_nogo_tarde="$(cm $LEAD "$(date -u -d "@$((TSE + 60))" +%Y-%m-%dT%H:%M:%SZ)" "$(rec "$RUN" "$HEAD" code "$TSI" "$RUN" code "$HEAD" NO-GO '["x"]')")"
pag_nogo_antes="$(cm $LEAD "$(date -u -d "@$((TSE - 60))" +%Y-%m-%dT%H:%M:%SZ)" "$(rec "$RUN" "$HEAD" code "$TSI" "$RUN" code "$HEAD" NO-GO '["x"]')")"
cli_res() { # «<primera palabra>/<rc>» del verificador por línea de órdenes
  local o r; o="$(PATH="$TMP/bin:$PATH" bash "$SC/verify-code-audit-go.sh" 9 "$HEAD" 2>/dev/null)"; r=$?
  printf '%s/%s' "$(first "$o")" "$r"
}
export COMMENTS_RC=1
printf '%s\n' "$pag_go" > "$COMMENTS_FILE"
ok 'B1 gh falla DESPUÉS de una página con GO válido (la revocación iba en la siguiente) -> no' "$(cli_res)" 'no/1'
: > "$COMMENTS_FILE"
ok 'B1 gh falla sin entregar nada -> no' "$(cli_res)" 'no/1'
export COMMENTS_RC=0
printf '%s\n[{"login":"%s","created":"x","body":"trunc' "$pag_go" "$LEAD" > "$COMMENTS_FILE"
ok 'B1 JSON roto en la segunda página (rc 0) -> no' "$(cli_res)" 'no/1'
printf '%s\n%s\n' "$pag_go" "$pag_nogo_tarde" > "$COMMENTS_FILE"
ok 'B1 dos páginas completas, revocación en la segunda -> no' "$(cli_res)" 'no/1'
printf '%s\n%s\n' "$pag_nogo_antes" "$pag_go" > "$COMMENTS_FILE"
ok 'B1 dos páginas completas, GO válido como último registro -> yes' "$(cli_res)" 'yes/0'

echo '== B2 y MA1 con el productor REAL (tco_audit_once con dobles de Incus y de panel) =='
export TCO_REVISOR=code-audit
# shellcheck source=/dev/null
. "$SC/audit-gate.sh"
tco_ensure_audit_model() { return 0; }
tco_pane_audit() { printf 'v:0.1'; }
incus() {
  case "$*" in
    *'tmux list-panes'*) printf '1\n' ;;
    *'git cat-file'*) [ "$AUDIT_FIXTURE_COMMIT" = yes ] ;;
    *) return 1 ;;
  esac
}
tco_send_ready() { return 0; }
tco_relay_file() { return 0; }
sleep() { :; }
tco_cap_pane() {
  local r s envf="$TCO_RUNS_DIR/audit-last-$1.env"
  r="$(sed -n 's/^RUN_ID=//p' "$envf")"; s="$(sed -n 's/^SHA=//p' "$envf")"
  if [ -n "$AUDIT_FIXTURE_VERDICT_TYPE" ]; then
    printf 'Veredicto del auditor:\n{"run_id":"%s","artifact_type":"%s","artifact_sha":"%s","verdict":"GO","blocking_findings":[]}\n' "$r" "$AUDIT_FIXTURE_VERDICT_TYPE" "$s"
  else
    printf 'Veredicto del auditor:\n{"run_id":"%s","artifact_sha":"%s","verdict":"GO","blocking_findings":[]}\n' "$r" "$s"
  fi
}
printf 'artefacto local\n' > "$TMP/artefacto.txt"
auditar() { # nombre commit_en_el_canal(yes|no) tipo_del_literal
  rm -f "$SECRET_DIR/runs/audit-last-01".*
  AUDIT_FIXTURE_COMMIT="$2"; AUDIT_FIXTURE_VERDICT_TYPE="$3"
  AUDIT_OUT="$(tco_audit_once 01 code "$TMP/artefacto.txt" "$HEAD" "$TMP/lit-$1.txt" 2>/dev/null)"
}
audit_qual() { sed -n 's/^AUDITADO=//p' "$SECRET_DIR/runs/audit-last-01.calificacion" 2>/dev/null; }
m8_tras_archivar() { # tras archivar: M8 sobre lo publicado (o sin comentarios si no se publicó)
  if [ -f "$POSTED" ]; then G_COMMENTS="$(cm $LEAD "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(cat "$POSTED")")"; else G_COMMENTS='[]'; fi
  gate code-audit
}
G_HEAD="$HEAD"; G_VIEWER=$LEAD; G_LABELS='[]'; export G_HEAD G_VIEWER
auditar commit yes code
ok 'B2 productor: la corrida del commit se califica commit' "$(audit_qual)" commit
archivar "$TMP/lit-commit.txt"; rc=$?
ok 'B2 productor+archivador: GO sobre el commit se archiva' "$AUDIT_OUT/$rc/$(test -e "$POSTED"; echo $?)" 'GO/0/0'
m8_tras_archivar
ok 'B2 productor+M8: GO sobre el commit -> M8 rc 0' "$GATE_RC" 0
auditar worktree no code
ok 'B2 productor: la corrida del working tree se califica working-tree' "$(audit_qual)" working-tree
archivar "$TMP/lit-worktree.txt"; rc=$?
ok 'B2 productor+archivador: GO sobre el working tree NO se archiva' "$AUDIT_OUT/$rc/$(test -e "$POSTED"; echo $?)" 'GO/1/1'
m8_tras_archivar
ok 'B2 productor+M8: GO sobre el working tree -> M8 rc 1' "$GATE_RC" 1
rm -f "$SECRET_DIR/runs/audit-last-01".*
( TCO_AUDIT_REQUIRE_COMMIT=yes; AUDIT_FIXTURE_COMMIT=no; AUDIT_FIXTURE_VERDICT_TYPE=code
  tco_audit_once 01 code "$TMP/artefacto.txt" "$HEAD" "$TMP/lit-require.txt" >/dev/null 2>&1 )
ok 'B2 productor: con TCO_AUDIT_REQUIRE_COMMIT=yes muere y deja la corrida calificada working-tree' "$(audit_qual)" working-tree
auditar plan-literal yes plan
archivar "$TMP/lit-plan-literal.txt"; rc=$?
ok 'MA1 productor+archivador: el auditor emite artifact_type=plan -> no se archiva' "$AUDIT_OUT/$rc/$(test -e "$POSTED"; echo $?)" 'GO/1/1'

echo '== B2-R: escritura atómica, una instantánea por fichero y publicación coherente (productor y archivador reales) =='
# Dos corridas del mismo canal pueden solaparse: el archivador debe leer CADA fichero de la corrida UNA sola vez y sacar todos
# sus campos de esa lectura (identidad de una corrida con la calificación de otra = «no»); y quien escribe esos ficheros los
# deja completos o no los toca (temporal del mismo directorio + mv). Aquí no se usa ningún sed «a medida»: los dobles de
# lectura cuentan CUALQUIER apertura de los dos ficheros (sed, cat, grep, head, tail, awk) y, según el escenario, dejan que
# la otra corrida escriba justo antes de una lectura concreta.
ENVF="$TCO_RUNS_DIR/audit-last-01.env"; QUALF="$TCO_RUNS_DIR/audit-last-01.calificacion"
RUN3="tco_${TSE}_eeeeeeeeeeee"
huerfanos() { find "$TCO_RUNS_DIR" -maxdepth 1 -type f -name '.*' | wc -l | tr -d ' '; }
mv_log() { # destino esperado -> si/no: se movió un temporal DISTINTO del destino y del MISMO directorio
  local s d; IFS=$'\t' read -r s d < "$TMP/mv.log"
  if [ "$d" = "$1" ] && [ -n "$s" ] && [ "$s" != "$d" ] && [ "$(dirname "$s")" = "$(dirname "$d")" ]; then echo si; else echo no; fi
}
mv() { # doble: registra «origen<TAB>destino» y el contenido del destino EN ESE MOMENTO; puede hacer fallar el rename
  local ultimo="${!#}"
  if [ "$ultimo" = "${MV_DST:-}" ]; then
    printf '%s\t%s\n' "${*: -2:1}" "$ultimo" >> "$TMP/mv.log"
    command cat "$ultimo" > "$TMP/mv-destino-antes.txt" 2>/dev/null || : > "$TMP/mv-destino-antes.txt"
    [ "${MV_FALLA:-no}" = yes ] && return 1
  fi
  command mv "$@"
}
rm -f "$SECRET_DIR/runs/audit-last-01".*
MV_FALLA=no; MV_DST="$QUALF"; : > "$TMP/mv.log"
printf 'VIEJO\n' > "$QUALF"
tco_audit_qualify 01 "$RUN" "$HEAD" commit
ok 'B2-R atómica (calificación): temporal del mismo directorio + mv sobre el destino' "$(mv_log "$QUALF")" si
ok 'B2-R atómica (calificación): hasta el mv el destino conserva lo anterior (nadie ve un fichero a medias)' "$(cat "$TMP/mv-destino-antes.txt")" VIEJO
ok 'B2-R atómica (calificación): el contenido final es completo' "$(cat "$QUALF")" "$(printf 'RUN_ID=%s\nSHA=%s\nAUDITADO=%s' "$RUN" "$HEAD" commit)"
ok 'B2-R atómica (calificación): ningún temporal huérfano' "$(huerfanos)" 0
ok 'B2-R atómica (calificación): conserva los permisos de la umask (no los 600 del temporal)' "$(stat -c %a "$QUALF")" "$(printf '%o' $(( 0666 & ~0$(umask) )))"
printf 'VIEJO\n' > "$QUALF"; : > "$TMP/mv.log"; MV_FALLA=yes
tco_audit_qualify 01 "$RUN" "$HEAD" commit; rc=$?
ok 'B2-R atómica (calificación): si el mv falla, devuelve error' "$rc" 1
ok 'B2-R atómica (calificación): si el mv falla, el destino queda intacto y sin temporal' "$(cat "$QUALF")/$(huerfanos)" 'VIEJO/0'
MV_FALLA=no; MV_DST="$ENVF"; : > "$TMP/mv.log"
printf 'VIEJO\n' > "$ENVF"
AUDIT_FIXTURE_COMMIT=yes; AUDIT_FIXTURE_VERDICT_TYPE=code
tco_audit_once 01 code "$TMP/artefacto.txt" "$HEAD" "$TMP/atomica.txt" > /dev/null 2>&1
ok 'B2-R atómica (.env): temporal del mismo directorio + mv sobre el destino' "$(mv_log "$ENVF")" si
ok 'B2-R atómica (.env): hasta el mv el destino conserva lo anterior' "$(cat "$TMP/mv-destino-antes.txt")" VIEJO
ok 'B2-R atómica (.env): el contenido y el esquema no cambian (cuatro líneas, como exige la acreditación de F8)' "$(wc -l < "$ENVF" | tr -d ' ')/$(sed -n 's/^\([A-Z_]*\)=.*/\1/p' "$ENVF" | tr '\n' ' ')" '4/RUN_ID SHA TYP TS '
ok 'B2-R atómica (.env): ningún temporal huérfano' "$(huerfanos)" 0
MV_DST=''

# Dobles de lectura: cuentan las aperturas de los dos ficheros de la corrida y aplican el escenario de la otra corrida.
liberar_a() { local i=0; : > "$TMP/a-liberar"; while [ ! -e "$TMP/a-fin" ] && [ "$i" -lt 500 ]; do /bin/sleep 0.02; i=$((i+1)); done; }
espera() { local i=0; while [ ! -e "$1" ] && [ "$i" -lt 500 ]; do /bin/sleep 0.02; i=$((i+1)); done; }
espia() { # herramienta args…
  local h="$1" a n; shift
  for a in "$@"; do
    if [ "$a" = "$ENVF" ]; then
      printf x >> "$TMP/lect-env"
      n="$(command wc -c < "$TMP/lect-env" | tr -d ' ')"
      if [ "${ESP_ENV_SWAP_N:-0}" = "$n" ]; then command cp "$ESP_ENV_SWAP_SRC" "$ENVF.nuevo" && command mv "$ENVF.nuevo" "$ENVF"; fi
      if [ "${ESP_ENV_LINK_N:-0}" = "$n" ]; then command rm -f "$ENVF" && command ln -s "$ESP_ENV_SWAP_SRC" "$ENVF"; fi
    elif [ "$a" = "$QUALF" ]; then
      printf x >> "$TMP/lect-qual"
      n="$(command wc -c < "$TMP/lect-qual" | tr -d ' ')"
      case "${ESP_QUAL:-}" in
        primera) [ "$n" = 1 ] && liberar_a ;;
        auditado) case " $* " in *'s/^AUDITADO=//p'*) liberar_a ;; esac ;;
        borrar) [ "$n" = 1 ] && command rm -f "$QUALF" ;;
        enlace) [ "$n" = 1 ] && command rm -f "$QUALF" && command ln -s "$ESP_ENV_SWAP_SRC" "$QUALF" ;;
      esac
    fi
  done
  command "$h" "$@"
}
sed() { espia sed "$@"; }
# El doble de «cat» NO se define en el ámbito global del fichero: redefiniría también el cat de las líneas de arriba y el
# resultado dependería del orden de las definiciones. Vive solo en la subshell que ejecuta al archivador (arch y carrera), que
# es quien abre los dos ficheros con cat (_tco_ca_slurp): ahí cuenta exactamente las mismas aperturas que antes.
con_cat_espiado() { ( cat() { espia cat "$@"; }; "$@" ); }
grep() { espia grep "$@"; }
head() { espia head "$@"; }
tail() { espia tail "$@"; }
awk() { espia awk "$@"; }
gh() {
  case "$*" in
    'pr comment'*)
      local f=''; while [ "$#" -gt 0 ]; do [ "$1" = --body-file ] && f="$2"; shift; done
      command cp "$f" "$POSTED"
      command wc -c < "$TMP/lect-env" > "$TMP/pub-env"; command wc -c < "$TMP/lect-qual" > "$TMP/pub-qual"
      if [ -n "${GH_TRAS_PUBLICAR:-}" ]; then "$GH_TRAS_PUBLICAR"; fi ;;
    *"api user"*) printf '%s' "$G_VIEWER" ;;
    *"headRefOid,mergeStateStatus"*) printf '{"headRefOid":"%s","mergeStateStatus":"CLEAN"}' "$G_HEAD" ;;
    *"--json statusCheckRollup"*) printf '[]' ;;
    *"--json labels"*) printf '%s' "$G_LABELS" ;;
    *"--json headRefOid --jq"*) printf '%s' "$G_HEAD" ;;
    *"/pulls/"*"/reviews"*) printf '%s' "$G_REVIEWS" ;;
    *"/issues/"*"/comments"*) printf '%s' "$G_COMMENTS"; return "${G_COMMENTS_RC:-0}" ;;
    *"api graphql"*) printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
    *) return 1 ;;
  esac
}
poner_env() { printf 'RUN_ID=%s\nSHA=%s\nTYP=%s\nTS=%s\n' "$1" "$2" "$3" "$TSI" > "${4:-$ENVF}"; }
poner_calif() { printf 'RUN_ID=%s\nSHA=%s\nAUDITADO=%s\n' "$1" "$2" "$3" > "$QUALF"; }
literal_go() { printf 'Veredicto del auditor:\n{"run_id":"%s","artifact_type":"code","artifact_sha":"%s","verdict":"GO","blocking_findings":[]}\n' "$1" "$2" > "$3"; }
cambiar_disco() { poner_env "$RUN3" "$OTHER" code; poner_calif "$RUN3" "$OTHER" commit; }
arch() { # literal -> rc del archivador en proceso (salida combinada en $TMP/arch.out); lecturas contadas desde cero
  rm -f "$POSTED" "$TMP/pub-env" "$TMP/pub-qual"; : > "$TMP/lect-env"; : > "$TMP/lect-qual"
  con_cat_espiado tco_code_audit_go_archive 9 01 "$1" > "$TMP/arch.out" 2>&1
}
G_HEAD="$HEAD"; G_VIEWER=$LEAD; G_LABELS='[]'; G_REVIEWS='[]'; G_COMMENTS='[]'; G_COMMENTS_RC=0
ESP_QUAL=''; ESP_ENV_SWAP_N=0; GH_TRAS_PUBLICAR=''
literal_go "$RUN" "$HEAD" "$TMP/lit-r.txt"

# Una instantánea por fichero y registro de la instantánea validada.
poner_env "$RUN" "$HEAD" code; poner_calif "$RUN" "$HEAD" commit
arch "$TMP/lit-r.txt"; rc=$?
ok 'B2-R control: corrida coherente sobre el commit -> se publica' "$rc/$(test -e "$POSTED"; echo $?)" '0/0'
ok 'B2-R una instantánea: el .env se abre UNA sola vez antes de publicar' "$(cat "$TMP/pub-env")" 1
ok 'B2-R una instantánea: la calificación se abre UNA sola vez antes de publicar' "$(cat "$TMP/pub-qual")" 1
ok 'B2-R el registro publicado lleva el run_id y el sha de la instantánea' "$(grep -c "^RUN_ID=$RUN\$" "$POSTED")/$(grep -c "^SHA=$HEAD\$" "$POSTED")" '1/1'
ok 'B2-R sin cambios en disco, el mensaje no avisa de ninguna otra corrida' "$(grep -c 'instantánea validada' "$TMP/arch.out")" 0
# El disco cambia (otra corrida) justo después de publicar: se dice, y lo publicado sigue siendo la instantánea validada.
poner_env "$RUN" "$HEAD" code; poner_calif "$RUN" "$HEAD" commit
GH_TRAS_PUBLICAR=cambiar_disco
arch "$TMP/lit-r.txt"; rc=$?
GH_TRAS_PUBLICAR=''
ok 'B2-R publicación: aunque el disco cambie después, se publica la instantánea validada' "$rc/$(test -e "$POSTED"; echo $?)" '0/0'
ok 'B2-R publicación: el registro es de la instantánea (run_id y sha), nunca de la relectura' "$(grep -c "^RUN_ID=$RUN\$" "$POSTED")/$(grep -c "$RUN3" "$POSTED")/$(grep -c "$OTHER" "$POSTED")" '1/0/0'
ok 'B2-R publicación: si el disco cambió, el mensaje lo dice' "$(grep -c 'instantánea validada' "$TMP/arch.out")" 1
# Borrado de la calificación durante la lectura.
poner_env "$RUN" "$HEAD" code; poner_calif "$RUN" "$HEAD" commit
ESP_QUAL=borrar; arch "$TMP/lit-r.txt"; rc=$?; ESP_QUAL=''
ok 'B2-R la calificación desaparece durante la lectura -> no' "$rc/$(test -e "$POSTED"; echo $?)" '1/1'
# .env: la identidad de una corrida con el SHA o el TYP de otra (la otra reescribe el fichero entre dos aperturas).
poner_env "$RUN3" "$OTHER" code "$TMP/env-y.txt"
poner_env "$RUN" "$HEAD" code; poner_calif "$RUN" "$OTHER" commit; literal_go "$RUN" "$OTHER" "$TMP/lit-mezcla.txt"
G_HEAD="$OTHER"; ESP_ENV_SWAP_N=2; ESP_ENV_SWAP_SRC="$TMP/env-y.txt"
arch "$TMP/lit-mezcla.txt"; rc=$?
ESP_ENV_SWAP_N=0
ok 'B2-R .env: RUN_ID de una corrida y SHA de otra -> no' "$rc/$(test -e "$POSTED"; echo $?)" '1/1'
poner_env "$RUN3" "$HEAD" code "$TMP/env-y.txt"
poner_env "$RUN" "$HEAD" plan; poner_calif "$RUN" "$HEAD" commit; literal_go "$RUN" "$HEAD" "$TMP/lit-r.txt"
G_HEAD="$HEAD"; ESP_ENV_SWAP_N=3; ESP_ENV_SWAP_SRC="$TMP/env-y.txt"
arch "$TMP/lit-r.txt"; rc=$?
ESP_ENV_SWAP_N=0
ok 'B2-R .env: RUN_ID de una corrida y TYP de otra -> no' "$rc/$(test -e "$POSTED"; echo $?)" '1/1'

# MA2 (R9011c): cada instantánea debe tener el esquema EXACTO que escribe audit-gate.sh y ser un fichero regular (ni enlace
# simbólico ni directorio). Antes solo se contaban las claves conocidas: una línea extra, una línea sin «=», un CR, el orden
# cambiado o un enlace a un contenido válido se archivaban y M8 daba «yes». Cada caso hostil comprueba el archivador Y M8 sobre lo
# que quede publicado: rc del archivador / publicado (0 = sí) / rc de M8; esperado «1/1/1» (no archiva, no publica, M8 en no).
limpiar_f() { if [ -d "$1" ] && [ ! -L "$1" ]; then rmdir "$1"; else rm -f "$1"; fi; }
ma2_base() { # deja las dos instantáneas válidas, el head del PR en el sha auditado y el literal GO de ESA corrida
  limpiar_f "$ENVF"; limpiar_f "$QUALF"; G_HEAD="$HEAD"; ESP_QUAL=''; ESP_ENV_LINK_N=0
  literal_go "$RUN" "$HEAD" "$TMP/lit-r.txt"; poner_env "$RUN" "$HEAD" code; poner_calif "$RUN" "$HEAD" commit
}
ma2_resultado() { # nombre literal esperado
  local rc
  arch "$2"; rc=$?
  m8_tras_archivar
  ok "MA2 $1" "$rc/$(test -e "$POSTED"; echo $?)/$GATE_RC" "$3"
}
ma2_caso() { # nombre fichero(env|calif) formato args…  -> reescribe ESE fichero con el contenido hostil; el otro queda válido
  local nom="$1" cual="$2" fmt="$3" destino; shift 3
  ma2_base
  if [ "$cual" = env ]; then destino="$ENVF"; else destino="$QUALF"; fi
  limpiar_f "$destino"
  # shellcheck disable=SC2059
  printf "$fmt" "$@" > "$destino"
  ma2_resultado "$nom" "$TMP/lit-r.txt" 1/1/1
}
ma2_base
ma2_resultado 'control: .env y calificación a mano con el esquema exacto -> se archiva y M8 yes' "$TMP/lit-r.txt" 0/0/0
ma2_base
auditar ma2-productor yes code
ma2_resultado 'control: .env y calificación escritos por el productor real -> se archiva y M8 yes' "$TMP/lit-ma2-productor.txt" 0/0/0
for cual in env calif; do
  if [ "$cual" = env ]; then
    ET='.env'; VA=("$RUN" "$HEAD" code "$TSI")
    FM='RUN_ID=%s\nSHA=%s\nTYP=%s\nTS=%s\n'
    FMO='SHA=%s\nRUN_ID=%s\nTYP=%s\nTS=%s\n'; VO=("$HEAD" "$RUN" code "$TSI")
    FMV='RUN_ID=%s\nSHA=%s\n\nTYP=%s\nTS=%s\n'
    FME='RUN_ID=%s\nSHA=%s\nTYP=%s\nTS=%s \n'
    FMN='RUN_ID=%s\nSHA=%s\nTYP=%s\nTS=%s'
    FMC='RUN_ID=%s\nSHA=%s\nTYP=%s\r\nTS=%s\n'
    FMD='RUN_ID=%s\nSHA=%s\nTYP=%s\nTS=%s\nTYP=%s\n'; VD=("${VA[@]}" code)
  else
    ET='calificación'; VA=("$RUN" "$HEAD" commit)
    FM='RUN_ID=%s\nSHA=%s\nAUDITADO=%s\n'
    FMO='SHA=%s\nRUN_ID=%s\nAUDITADO=%s\n'; VO=("$HEAD" "$RUN" commit)
    FMV='RUN_ID=%s\nSHA=%s\n\nAUDITADO=%s\n'
    FME='RUN_ID=%s\nSHA=%s\nAUDITADO=%s \n'
    FMN='RUN_ID=%s\nSHA=%s\nAUDITADO=%s'
    FMC='RUN_ID=%s\nSHA=%s\nAUDITADO=%s\r\n'
    FMD='RUN_ID=%s\nSHA=%s\nAUDITADO=%s\nAUDITADO=%s\n'; VD=("${VA[@]}" commit)
  fi
  ma2_caso "$ET con una línea extra EXTRA=hostil y CR" "$cual" "${FM}EXTRA=hostil\r\n" "${VA[@]}"
  ma2_caso "$ET con una línea sin '='" "$cual" "${FM}LINEA_SIN_IGUAL\n" "${VA[@]}"
  ma2_caso "$ET con una línea extra con dos '='" "$cual" "${FM}EXTRA=a=b\n" "${VA[@]}"
  ma2_caso "$ET con una clave repetida (RUN_ID al final)" "$cual" "${FM}RUN_ID=%s\n" "${VA[@]}" "$RUN"
  ma2_caso "$ET con el orden cambiado" "$cual" "$FMO" "${VO[@]}"
  ma2_caso "$ET con una línea vacía en medio" "$cual" "$FMV" "${VA[@]}"
  ma2_caso "$ET con un espacio final en el último valor" "$cual" "$FME" "${VA[@]}"
  ma2_caso "$ET sin el salto de línea final" "$cual" "$FMN" "${VA[@]}"
  ma2_caso "$ET con un CR dentro de un valor" "$cual" "$FMC" "${VA[@]}"
  ma2_caso "$ET con la última clave duplicada" "$cual" "$FMD" "${VD[@]}"
  ma2_caso "$ET vacío" "$cual" ''
  # enlace simbólico a un contenido válido, y directorio en lugar de fichero
  ma2_base
  if [ "$cual" = env ]; then destino="$ENVF"; else destino="$QUALF"; fi
  command cp "$destino" "$TMP/obj-valido-$cual.txt"; rm -f "$destino"; ln -s "$TMP/obj-valido-$cual.txt" "$destino"
  ma2_resultado "$ET sustituido por un enlace simbólico a un contenido válido" "$TMP/lit-r.txt" 1/1/1
  ma2_base
  limpiar_f "$destino"; mkdir "$destino"
  ma2_resultado "$ET sustituido por un directorio" "$TMP/lit-r.txt" 1/1/1
done
# Valores con forma inválida (el resto del fichero es válido)
ma2_caso '.env con un TYP desconocido' env 'RUN_ID=%s\nSHA=%s\nTYP=otro\nTS=%s\n' "$RUN" "$HEAD" "$TSI"
ma2_caso '.env con un TS mal formado' env 'RUN_ID=%s\nSHA=%s\nTYP=code\nTS=ayer\n' "$RUN" "$HEAD"
ma2_caso '.env con un TS sin la Z final' env 'RUN_ID=%s\nSHA=%s\nTYP=code\nTS=%s\n' "$RUN" "$HEAD" "${TSI%Z}"
ma2_caso '.env con un RUN_ID de otra forma' env 'RUN_ID=corrida-1\nSHA=%s\nTYP=code\nTS=%s\n' "$HEAD" "$TSI"
ma2_caso 'calificación con un AUDITADO desconocido' calif 'RUN_ID=%s\nSHA=%s\nAUDITADO=inventado\n' "$RUN" "$HEAD"
# SHA en mayúsculas o corto en las DOS instantáneas, con el head del PR y el literal en la misma forma (solo la forma las rechaza)
for mal in "$(printf 'A%.0s' {1..40})" "${HEAD:0:12}"; do
  ma2_base
  G_HEAD="$mal"; literal_go "$RUN" "$mal" "$TMP/lit-sha.txt"; poner_env "$RUN" "$mal" code; poner_calif "$RUN" "$mal" commit
  ma2_resultado "SHA con forma inválida en las dos instantáneas (${#mal} caracteres)" "$TMP/lit-sha.txt" 1/1/1
done
# MA3 (R9011d): bash elimina los bytes NUL al capturar con $(…) y la instantánea llegaba ya saneada a la validación: un NUL al
# final, dentro de TYP/AUDITADO («co\0de», «com\0mit») o en medio de RUN_ID/SHA se archivaba y M8 daba «yes». Lo validado debe
# ser, byte a byte, lo que hay en el fichero (los NUL los escribe printf aquí, nunca van en el fuente). Cualquier diferencia = «no».
ma2_caso '.env válido con un byte NUL al final' env 'RUN_ID=%s\nSHA=%s\nTYP=code\nTS=%s\n\000' "$RUN" "$HEAD" "$TSI"
ma2_caso '.env con un NUL dentro de TYP (co\0de)' env 'RUN_ID=%s\nSHA=%s\nTYP=co\000de\nTS=%s\n' "$RUN" "$HEAD" "$TSI"
ma2_caso '.env con un NUL en medio del RUN_ID' env 'RUN_ID=%s\000%s\nSHA=%s\nTYP=code\nTS=%s\n' "${RUN:0:10}" "${RUN:10}" "$HEAD" "$TSI"
ma2_caso '.env con un NUL en medio del SHA' env 'RUN_ID=%s\nSHA=%s\000%s\nTYP=code\nTS=%s\n' "$RUN" "${HEAD:0:20}" "${HEAD:20}" "$TSI"
ma2_caso 'calificación válida con un byte NUL al final' calif 'RUN_ID=%s\nSHA=%s\nAUDITADO=commit\n\000' "$RUN" "$HEAD"
ma2_caso 'calificación con un NUL dentro de AUDITADO (com\0mit)' calif 'RUN_ID=%s\nSHA=%s\nAUDITADO=com\000mit\n' "$RUN" "$HEAD"
ma2_caso 'calificación con un NUL en medio del RUN_ID' calif 'RUN_ID=%s\000%s\nSHA=%s\nAUDITADO=commit\n' "${RUN:0:10}" "${RUN:10}" "$HEAD"
ma2_caso 'calificación con un NUL en medio del SHA' calif 'RUN_ID=%s\nSHA=%s\000%s\nAUDITADO=commit\n' "$RUN" "${HEAD:0:20}" "${HEAD:20}"
# Carácter de control (no NUL) dentro de un valor: rechazo explícito, además del CR
ma2_caso '.env con un carácter de control (SOH) dentro de un valor' env 'RUN_ID=%s\nSHA=%s\nTYP=co\001de\nTS=%s\n' "$RUN" "$HEAD" "$TSI"
ma2_caso 'calificación con un carácter de control (SOH) dentro de un valor' calif 'RUN_ID=%s\nSHA=%s\nAUDITADO=com\001mit\n' "$RUN" "$HEAD"
# Cierre de la ventana entre comprobar y leer: el fichero pasa a enlace simbólico JUSTO antes de la lectura
ma2_base
cp "$ENVF" "$TMP/obj-valido-env.txt"; ESP_ENV_LINK_N=1; ESP_ENV_SWAP_SRC="$TMP/obj-valido-env.txt"
ma2_resultado '.env cambiado a enlace simbólico justo antes de la lectura' "$TMP/lit-r.txt" 1/1/1
ma2_base
cp "$QUALF" "$TMP/obj-valido-calif.txt"; ESP_QUAL=enlace; ESP_ENV_SWAP_SRC="$TMP/obj-valido-calif.txt"
ma2_resultado 'calificación cambiada a enlace simbólico justo antes de la lectura' "$TMP/lit-r.txt" 1/1/1
ESP_QUAL=''; ESP_ENV_LINK_N=0; ESP_ENV_SWAP_N=0
ma2_base

# La carrera de la revisión R9011b, con el productor real y los dobles de Incus y del panel. A (otro sha, auditable como
# commit) empieza antes y espera en «git cat-file»; B (working tree) termina y es la que se archiva. Con «auditado» el doble
# deja terminar a A justo antes de la lectura de AUDITADO (la del defecto original); con «primera», antes de la primera
# apertura de la calificación. En ambos casos el archivador no puede salir con un GO del working tree de B.
incus() {
  case "$*" in
    *'tmux list-panes'*) printf '1\n' ;;
    *'git cat-file'*)
      if [ "${MODO_A:-no}" = yes ]; then
        : > "$TMP/a-lista"; espera "$TMP/a-liberar"
        return 0
      fi
      return 1 ;;
    *) return 1 ;;
  esac
}
tco_send_ready() { [ "${MODO_A:-no}" != yes ]; }
carrera() { # modo del doble de lectura de la calificación: auditado | primera  ->  CARRERA_RC y CARRERA_M8
  local pid_a
  rm -f "$TMP"/a-lista "$TMP"/a-liberar "$TMP"/a-fin "$TMP/a.rc" "$POSTED" "$SECRET_DIR/waivers/9-$HEAD.cr-waiver" "$SECRET_DIR/runs/audit-last-01".*
  ESP_QUAL=''; ESP_ENV_SWAP_N=0; GH_TRAS_PUBLICAR=''
  G_HEAD="$HEAD"; G_VIEWER=$LEAD; G_LABELS='[]'; G_REVIEWS='[]'; G_COMMENTS_RC=0
  ( ( MODO_A=yes; tco_audit_once 01 code "$TMP/artefacto.txt" "$OTHER" "$TMP/a.txt" ) > "$TMP/a.out" 2> "$TMP/a.err"; printf '%s\n' "$?" > "$TMP/a.rc"; : > "$TMP/a-fin" ) &
  pid_a=$!
  espera "$TMP/a-lista"
  AUDIT_FIXTURE_COMMIT=no; AUDIT_FIXTURE_VERDICT_TYPE=code
  tco_audit_once 01 code "$TMP/artefacto.txt" "$HEAD" "$TMP/b.txt" > "$TMP/b.out" 2> "$TMP/b.err"
  rm -f "$POSTED"; : > "$TMP/lect-env"; : > "$TMP/lect-qual"
  ESP_QUAL="$1"
  con_cat_espiado tco_code_audit_go_archive 9 01 "$TMP/b.txt" > "$TMP/carrera.out" 2>&1
  CARRERA_RC=$?
  ESP_QUAL=''
  : > "$TMP/a-liberar"
  wait "$pid_a"
  if [ -f "$POSTED" ]; then G_COMMENTS="$(cm "$LEAD" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(cat "$POSTED")")"; else G_COMMENTS='[]'; fi
  gate code-audit
  CARRERA_M8=$GATE_RC
}
carrera auditado
ok 'B2-R carrera (R9011b, lectura de AUDITADO): B es del working tree y no se archiva' "$CARRERA_RC/$(test -e "$POSTED"; echo $?)" '1/1'
ok 'B2-R carrera (R9011b, lectura de AUDITADO): M8 queda en no' "$CARRERA_M8" 1
carrera primera
ok 'B2-R carrera (primera apertura de la calificación): B no se archiva' "$CARRERA_RC/$(test -e "$POSTED"; echo $?)" '1/1'
ok 'B2-R carrera (primera apertura de la calificación): M8 queda en no' "$CARRERA_M8" 1

# MN2 (R9011e): la defensa explícita _tco_ca_sin_control tiene su PROPIA prueba, directa sobre la función. Las pruebas del archivador
# no la ven: el esquema exacto de cada campo ya rechaza estos mismos bytes, de modo que quitar la defensa dejaba la suite en verde.
# Aceptados: ASCII imprimible completo (0x20-0x7e), el salto de línea y los valores REALES del productor (los dos ficheros que dejó
# la última corrida de audit-gate.sh en la carrera de arriba). Rechazados: TAB, CR, SOH, DEL, un byte 0x80 y UTF-8 multibyte, bajo
# LC_ALL=C y bajo el locale UTF-8 del sistema. Si el runner no trae ese locale, el caso es SKIP con su motivo, nunca PASS.
# Todos los bytes los genera printf aquí; ninguno va escrito en el fuente.
echo '== MN2: contrato directo de _tco_ca_sin_control (aceptados y rechazados, locale C y UTF-8) =='
sc_rc() { ( LC_ALL="$1"; export LC_ALL; _tco_ca_sin_control "$2" ) > /dev/null 2>&1; echo $?; }
sc_utf8=''
for cand in C.UTF-8 C.utf8; do
  if [ "$(LC_ALL=$cand locale charmap 2> /dev/null)" = UTF-8 ]; then sc_utf8="$cand"; break; fi
done
sc_ascii="$(printf '%b' "$(printf '\\x%02x' {32..126})")"
sc_env_real=''; sc_calif_real=''
_tco_ca_slurp "$TCO_RUNS_DIR/audit-last-01.env" sc_env_real || sc_env_real='<sin instantánea .env del productor>'
_tco_ca_slurp "$TCO_RUNS_DIR/audit-last-01.calificacion" sc_calif_real || sc_calif_real='<sin instantánea .calificacion del productor>'
printf -v sc_salto 'ABC\nDEF\n'
printf -v sc_tab 'a\tb';  printf -v sc_cr 'a\rb';        printf -v sc_soh 'a\001b'
printf -v sc_del 'a\177b'; printf -v sc_alto 'a\200b';   printf -v sc_utf 'a\303\251b'
for sc_loc in C UTF8; do
  if [ "$sc_loc" = C ]; then sc_val=C; else sc_val="$sc_utf8"; fi
  sc_caso() { # nombre valor esperado
    if [ -z "$sc_val" ]; then
      SKIP=$((SKIP + 1)); printf 'SKIP MN2 [%s] %s: el runner no trae un locale UTF-8 utilizable (locale charmap != UTF-8)\n' "$sc_loc" "$1"
    else
      ok "MN2 [$sc_loc] $1" "$(sc_rc "$sc_val" "$2")" "$3"
    fi
  }
  sc_caso 'acepta ASCII imprimible completo (0x20-0x7e)'      "$sc_ascii"      0
  sc_caso 'acepta el salto de línea'                          "$sc_salto"      0
  sc_caso 'acepta la instantánea .env real del productor'     "$sc_env_real"   0
  sc_caso 'acepta la instantánea .calificacion real del productor' "$sc_calif_real" 0
  sc_caso 'rechaza un TAB'                                    "$sc_tab"        1
  sc_caso 'rechaza un CR'                                     "$sc_cr"         1
  sc_caso 'rechaza un SOH (0x01)'                             "$sc_soh"        1
  sc_caso 'rechaza un DEL (0x7f)'                             "$sc_del"        1
  sc_caso 'rechaza un byte 0x80'                              "$sc_alto"       1
  sc_caso 'rechaza UTF-8 multibyte'                           "$sc_utf"        1
done

echo
echo "RESULTADO: PASS=$PASS FAIL=$FAIL SKIP=$SKIP TOTAL=$((PASS + FAIL + SKIP)) (esperados: $TOTAL_ESPERADO)"
[ $((PASS + FAIL + SKIP)) -eq "$TOTAL_ESPERADO" ] || { echo "ERROR: TOTAL != TOTAL_ESPERADO — cobertura perdida o test fantasma" >&2; exit 1; }
[ "$FAIL" -eq 0 ]
