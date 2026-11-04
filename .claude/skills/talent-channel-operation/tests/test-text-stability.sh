#!/usr/bin/env bash
# Reposo vivo durante flujo de texto; únicamente dentro del arnés.
# shellcheck disable=SC2329,SC2034
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$HERE/../scripts"
# shellcheck source=/dev/null
. "$HERE/capturas-codificadas.sh"
export TF_LINEAR_TEAM_KEY=ABC TCO_REPO_DIR=Repo-Neutro TCO_REPO_SLUG=org-neutra/Repo-Neutro TCO_REPO_STACK=ninguno
export TCO_ANEXO_FILE=references/anexo-neutro.md TCO_HOST_ENV_REL=Repo-Neutro/.env.local
export TCO_LINEAR_INPROGRESS_STATE=00000000-0000-4000-8000-000000000007
export TCO_LINEAR_INREVIEW_STATE=00000000-0000-4000-8000-000000000008
# shellcheck source=/dev/null
. "$SC/00-config.sh"
# shellcheck source=/dev/null
. "${TCO_STABILITY_LIB:-$SC/lib.sh}"
FX="$HERE/fixtures/reposo/flujo-texto"
TMP_TEST="$(mktemp -d)"; trap 'rm -rf "$TMP_TEST"' EXIT
PASS=0; FAIL=0
ok() {
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'PASS %s\n' "$1";
  else FAIL=$((FAIL+1)); printf 'FAIL %s: actual [%s], esperado [%s]\n' "$1" "$2" "$3"; fi
}
rc_of() { local rc=0; "$@" > "$TMP_TEST/out" 2> "$TMP_TEST/err" || rc=$?; printf '%s' "$rc"; }
sleep() { printf '%s\n' "$1" >> "$TMP_TEST/gaps"; }
_tco_carril_session() { [ "$disk" = yes ] && printf 'sid idle 1'; }
_tco_transcript_lines() { printf '{"type":"assistant","message":{"content":"texto"}}'; }
_tco_pane_cli_version() { printf 'claude:2.1.289'; }
TCO_PANE_CALIBRATED=claude:2.1.289
tmux() {
  local n; n="$(cat "$TMP_TEST/index")"
  printf '%s' "$((n+1))" > "$TMP_TEST/index"
  local -a sequence; read -r -a sequence <<< "$screens"
  n="${sequence[n]:-${sequence[-1]}}"
  if [ "$n" = fail ]; then return 1; fi
  cat "$FX/t-$n.txt"
}
incus() { tmux capture-pane; }
# Conserva tco_cap_pane real y su transporte; los dobles nunca tocan paneles reales.
reset() { printf 0 > "$TMP_TEST/index"; : > "$TMP_TEST/gaps"; }
for file in "$FX"/*.txt; do
  ok "escáner de captura ${file##*/}" "$(rc_of tco_fixture_secret_scan < "$file")" 0
done
for disk in no yes; do
  for n in 04 05 06 07 08 09 10 11; do
    next=$((10#$n+1)); printf -v next '%02d' "$next"
    screens="$n $next"; reset
    ok "texto creciendo $n/$next disco=$disk es ocupado" "$(rc_of tco_pane_busy 01 v:.0)" 0
  done
  screens='39 40'; reset
  ok "texto final idéntico disco=$disk es reposo" "$(rc_of tco_pane_busy 01 v:.0)" 1
  ok "gap por defecto disco=$disk es dos segundos" "$(cat "$TMP_TEST/gaps")" 2
  screens='39 fail'; reset
  ok "segunda captura fallida disco=$disk es desconocido" "$(rc_of tco_pane_busy 01 v:.0)" 2
done
disk=no; screens='39 40'; reset
ok 'gap configurable' "$(TCO_IDLE_STABILITY_GAP=0.5 rc_of tco_pane_busy 01 v:.0)" 1
ok 'gap configurable aplicado' "$(cat "$TMP_TEST/gaps")" 0.5
ok 'gap inválido fail-closed' "$(TCO_IDLE_STABILITY_GAP=no rc_of tco_pane_busy 01 v:.0)" 2
ok 'cambio solo en pie conserva reposo' "$(
  reset; screens='39 40'
  tco_cap_pane() { incus | sed "s/ctx: 5%/ctx: $(cat "$TMP_TEST/index")%/"; }
  rc_of tco_pane_busy 01 v:.0
)" 1
for after in busy unknown; do
  ok "autoridad primaria cambia a $after tras intervalo" "$(
    reset; disk=yes; screens='39 40'
    _tco_carril_session() {
      if [ "$(cat "$TMP_TEST/index")" -eq 0 ]; then printf 'sid idle 1';
      else printf 'sid %s 1' "$after"; fi
    }
    rc_of tco_pane_busy 01 v:.0
  )" "$(if [ "$after" = busy ]; then printf 0; else printf 2; fi)"
done
ok 'segunda captura con modal no confirma reposo' "$(
  reset; screens='39 40'
  tco_cap_pane() {
    if [ "$(cat "$TMP_TEST/index")" -eq 0 ]; then incus;
    else cat "$HERE/fixtures/pane/claude_2.1.289/modal.txt"; fi
  }
  rc_of tco_pane_busy 01 v:.0
)" 2
screens='04 05 06 07 08 09 10 11 12'; reset
ok 'espera no declara reposo durante flujo real' "$(rc_of tco_wait_state 01 v:.0 NUNCA 0 3 3)" 1
screens='04 05 06 07 08 09 10 11 12 39 40'; reset
ok 'espera declara reposo después del flujo estable' "$(rc_of tco_wait_state 01 v:.0 NUNCA 0 10 3)" 3
ok 'recorte final del flujo estable' "$(grep -c 'Churned for' "$TMP_TEST/out")" 1
# Interacción de las tres ramas: ancla con título/color y confirmación viva de reposo.
for locale in C C.UTF-8; do
  for file in "$HERE"/fixtures/pane/claude_2.1.289/composer-*.txt; do
    for disk in no yes; do
      ok "reposo estable con borde titulado ${file##*/} disco=$disk locale=$locale" "$(
        export LC_ALL="$locale"
        tco_cap_pane() { tco_fixture_decode "$file"; }
        rc_of tco_pane_busy 01 v:.0
      )" 1
    done
  done
  for file in "$HERE"/fixtures/pane/claude_2.1.289/composer-*.txt "$HERE"/fixtures/reposo/*.txt "$FX"/*.txt; do
    ok "captura real sin diálogo estructural ${file##*/} locale=$locale" "$(
      export LC_ALL="$locale"
      tco_fixture_decode "$file" | rc_of tco_pane_anomaly
    )" 1
  done
done
# Aunque una autoridad doble diga idle, pantallas distintas entre sondeos reinician la cuenta.
tco_pane_busy() { return 1; }
screens='04 05 06 07 08 09 10 11 12'; reset
ok 'pantalla creciente entre sondeos no declara reposo' "$(rc_of tco_wait_state 01 v:.0 NUNCA 0 8 3)" 1
screens='39 40'; reset
ok 'pantalla idéntica entre sondeos declara reposo' "$(rc_of tco_wait_state 01 v:.0 NUNCA 0 4 3)" 3
printf 'RESULTADO estabilidad: PASS=%s FAIL=%s TOTAL=%s\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$((PASS+FAIL))" -eq 95 ] && [ "$FAIL" -eq 0 ]
