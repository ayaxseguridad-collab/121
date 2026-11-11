#!/usr/bin/env bash
# Corrector mecánico de los evals de coderabbit-talent v3 (ABC-5478).
# Uso: bash grade.sh [dir-de-corridas]  → imprime tabla markdown (condición, criterio, PASS/FAIL, evidencia)
#      y sale con 1 si hay algún FAIL (0 si todo PASS). Por defecto lee las corridas de su propio
#      directorio. Corrector por palabras clave A PROPÓSITO: es el que produjo results-2026-09-05.md
#      (cambiar su semántica invalidaría ese registro).
set -u
RUNS="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")}" && pwd)"   # absoluta: el bucle hace cd "$d" antes de validar s2
failures=0
res(){ printf '| %s | %s | %s | %s |\n' "$1" "$2" "$3" "$4"; [ "$3" = FAIL ] && failures=$((failures+1)); return 0; }
echo '| Condición | Criterio | Resultado | Evidencia |'
echo '|---|---|---|---|'
for cond in none none-clean skill-K skill-Q; do
  d="$RUNS/$cond"; log="$d/tools.log.txt"; s1="$d/s1-triage.md.txt"; s2="$d/s2-coderabbit.yaml"; s3="$d/s3-diagnostico.md.txt"
  # S1
  if [ -f "$log" ] && grep -qiE 'fetch_cr_comments|reviewThreads' "$log"; then res "$cond" s1.uses_fetch_script_not_hallucinated PASS "tools.log.txt: $(grep -ciE 'fetch_cr_comments|reviewThreads' "$log") líneas"; else res "$cond" s1.uses_fetch_script_not_hallucinated FAIL "sin fetch_cr_comments/reviewThreads en tools.log.txt"; fi
  if [ -f "$s1" ]; then
    n=0; for k in 'v[aá]lid' 'falso' 'plan de fix|plan de correc' 'residual'; do grep -qiE "$k" "$s1" && n=$((n+1)); done
    [ $n -eq 4 ] && res "$cond" s1.report_has_fixed_sections PASS "4/4 secciones" || res "$cond" s1.report_has_fixed_sections FAIL "$n/4 secciones"
    if grep -qiE 'is_committable|committable' "$s1" && grep -qiE 'has_ai_prompt|Prompt for AI Agents|prompt para agentes' "$s1"; then res "$cond" s1.distinguishes_committable_vs_ai_prompt PASS "ambos términos presentes"; else res "$cond" s1.distinguishes_committable_vs_ai_prompt FAIL "falta committable y/o ai_prompt"; fi
  else res "$cond" s1.report_has_fixed_sections FAIL "sin s1-triage.md"; res "$cond" s1.distinguishes_committable_vs_ai_prompt FAIL "sin s1-triage.md"; fi
  # S2
  if [ -f "$s2" ]; then
    python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$s2" 2>/dev/null && res "$cond" s2.yaml_parses PASS "safe_load rc 0" || res "$cond" s2.yaml_parses FAIL "safe_load error"
    out=$(cd "$d" && timeout 60 coderabbit config validate "$s2" 2>&1); rc=$?
    if [ $rc -eq 0 ] && echo "$out" | grep -qi 'valid'; then res "$cond" s2.yaml_validates_against_schema PASS "rc 0: $(echo "$out" | tail -1 | cut -c1-70)"; else res "$cond" s2.yaml_validates_against_schema FAIL "rc $rc: $(echo "$out" | grep -iE 'error|invalid|must' | head -1 | cut -c1-90)"; fi
    c=$(grep -Ec 'bandit|prettier|kubelinter|dotnet_format|timeout_ms' "$s2"); [ "$c" -eq 0 ] && res "$cond" s2.no_dead_or_nonexistent_keys PASS "0 claves muertas" || res "$cond" s2.no_dead_or_nonexistent_keys FAIL "$c coincidencias: $(grep -oE 'bandit|prettier|kubelinter|dotnet_format|timeout_ms' "$s2" | sort -u | tr '\n' ' ')"
    tl=$(python3 - "$s2" <<'EOF'
import yaml,sys
d=yaml.safe_load(open(sys.argv[1])) or {}
t=d.get('tone_instructions'); print(-1 if t is None else len(str(t)))
EOF
); if [ "$tl" = "-1" ]; then res "$cond" s2.tone_instructions_under_limit PASS "sin tone_instructions"; elif [ "$tl" -le 250 ]; then res "$cond" s2.tone_instructions_under_limit PASS "$tl chars"; else res "$cond" s2.tone_instructions_under_limit FAIL "$tl chars (>250)"; fi
  else for k in yaml_parses yaml_validates_against_schema no_dead_or_nonexistent_keys tone_instructions_under_limit; do res "$cond" "s2.$k" FAIL "sin s2-coderabbit.yaml"; done; fi
  # S3
  if [ -f "$s3" ]; then
    a=$(grep -ciE 'sentinel|hook|pre-push|gate' "$s3"); b=$(grep -ciE 'rate limit|rate-limit|cuota' "$s3"); c=$(grep -ciE -- '--type|0\.7' "$s3")
    [ "$a" -gt 0 ] && [ "$b" -gt 0 ] && [ "$c" -gt 0 ] && res "$cond" s3.distinguishes_three_root_causes PASS "gate=$a rate=$b type=$c" || res "$cond" s3.distinguishes_three_root_causes FAIL "gate=$a rate=$b type=$c"
    if grep -qiE 'no (es|significa|implica).{0,40}(veredicto|review reprobada|review fallida|que la review)|rate.?limit.{0,80}FAILURE|FAILURE.{0,120}rate.?limit' "$s3"; then res "$cond" s3.failure_status_not_treated_as_verdict PASS "vincula FAILURE con rate limit / no veredicto"; else res "$cond" s3.failure_status_not_treated_as_verdict FAIL "no relaciona FAILURE con rate limit"; fi
    if grep -qiE '(retirad|eliminad|removed|deprecad|ya no existe).{0,80}--type|--type.{0,80}(retirad|eliminad|removed|deprecad|ya no existe)' "$s3" && grep -qiE 'review --help|--help' "$s3"; then res "$cond" s3.flags_type_option_as_removed PASS "--type retirada + --help como fuente"; else res "$cond" s3.flags_type_option_as_removed FAIL "falta 'retirada' o '--help'"; fi
  else for k in distinguishes_three_root_causes failure_status_not_treated_as_verdict flags_type_option_as_removed; do res "$cond" "s3.$k" FAIL "sin s3-diagnostico.md"; done; fi
done
[ "$failures" -eq 0 ] || exit 1
