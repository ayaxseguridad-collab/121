#!/usr/bin/env bash
# Compositor con sugerencias: capturas reales y transporte sustituido, solo en el arnés.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$TEST_DIR/../scripts"
# shellcheck source=/dev/null
. "$TEST_DIR/capturas-codificadas.sh"
export TF_LINEAR_TEAM_KEY=ABC TCO_REPO_DIR=Repo-Neutro TCO_REPO_SLUG=org-neutra/Repo-Neutro TCO_REPO_STACK=ninguno
export TCO_ANEXO_FILE=references/anexo-neutro.md TCO_HOST_ENV_REL=Repo-Neutro/.env.local
export TCO_LINEAR_INPROGRESS_STATE=00000000-0000-4000-8000-000000000007
export TCO_LINEAR_INREVIEW_STATE=00000000-0000-4000-8000-000000000008
# shellcheck source=/dev/null
. "$SC/00-config.sh"
# shellcheck source=/dev/null
. "${TCO_SLASH_LIB:-$SC/lib.sh}"
REAL="$TEST_DIR/fixtures/pane/claude_2.1.289"
# CLI 2.1.302: la lista de órdenes lleva la fila seleccionada con «  ❯ » y las demás con 4 espacios, y la columna de
# descripción es la 32 (en 2.1.289: filas con 2 espacios y descripción en la 36). Capturas reales de un TUI vivo.
REAL302="$TEST_DIR/fixtures/pane/claude_2.1.302"
TMP_TEST="$(mktemp -d)"
trap 'rm -rf "$TMP_TEST"' EXIT
PASS=0; FAIL=0
ok() {
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'PASS %s\n' "$1";
  else FAIL=$((FAIL+1)); printf 'FAIL %s: actual [%s], esperado [%s]\n' "$1" "$2" "$3"; fi
}
rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
# La secuencia depende de las teclas, nunca de un contador de capturas.
# Parámetros: estado inicial, sufijo (''|.ansi), directorio de capturas, versión del CLI y modo del reposo:
# «fallback» (par registrado como calibrado, sin superficie de sesión) o «superficie» (sesión en disco, par sin registro).
# shellcheck disable=SC2329
send_sequence() (
  local initial="$1" suffix="$2" dir="${3:-$REAL}" version="${4:-2.1.289}" mode="${5:-fallback}" rc=0
  : > "$TMP_TEST/calls"; printf '%s' "$initial" > "$TMP_TEST/state"
  incus() {
    printf '%s\n' "$*" >> "$TMP_TEST/calls"
    case "$*" in
      *' -l -- '*) printf typed > "$TMP_TEST/state";;
      *' C-m') printf modal > "$TMP_TEST/state";;
      *) return 1;;
    esac
  }
  sleep() { :; }
  local registry="claude:$version"
  if [ "$mode" = superficie ]; then
    _tco_carril_session() { printf 'sid-sintetico idle 2026-01-01T00:00:00Z\n'; }
    _tco_transcript_lines() { :; }
    _tco_pane_cli_version() { printf 'claude:9.9.9'; }
    registry=''
  else
    _tco_carril_session() { return 1; }
    _tco_pane_cli_version() { printf 'claude:%s' "$version"; }
  fi
  tco_cap_pane_e() {
    case "$(cat "$TMP_TEST/state")" in
      idle) tco_fixture_decode "$dir/slash/s-reposo$suffix.txt";;
      typed) tco_fixture_decode "$dir/slash/s-slash-model$suffix.txt";;
      modal) cat "$dir/modal.txt";;
    esac
  }
  tco_cap_pane() { tco_cap_pane_e | tco_strip_ansi_from; }
  TCO_PANE_CALIBRATED="$registry" TCO_IDLE_STABILITY_GAP=0 TCO_RELAY_SUBMIT_GAP=0 TCO_RELAY_ECHO_GAP=0 \
    _tco_send_text_submit 01 v:.0 /model >/dev/null 2>&1 || rc=$?
  printf '%s:%s:%s:%s' "$rc" "$(grep -c ' -l -- ' "$TMP_TEST/calls")" \
    "$(grep -c ' C-m' "$TMP_TEST/calls")" "$(cat "$TMP_TEST/state")"
)
AWK_BIN="${TCO_TEST_AWK:-awk}"
command -v "$AWK_BIN" >/dev/null || { printf 'FAIL falta %s\n' "$AWK_BIN"; exit 1; }
# Todas las funciones puras usan la variante elegida.
awk() { command "$AWK_BIN" "$@"; }
for locale in C C.UTF-8; do
  export LC_ALL="$locale"
  for kind in model effort parcial; do
    case "$kind" in model) text=/model;; effort) text=/effort;; parcial) text=/mod;; esac
    for suffix in '' .ansi; do
      cap="$(tco_fixture_decode "$REAL/slash/s-slash-$kind$suffix.txt")"
      label="$kind$suffix $AWK_BIN $locale"
      ok "captura limpia $label" "$(printf '%s' "$cap" | rc_of tco_fixture_secret_scan)" 0
      ok "ancla real $label" "$(printf '%s' "$cap" | tco_tui_anchor_from)" '22 24'
      ok "compositor exacto $label" "$(printf '%s' "$cap" | tco_tui_regions_from composer | tco_strip_dim_from | sed 's/^[[:space:]]*❯//; s/ //g' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" "$text"
      ok "eco verificado $label" "$(printf '%s' "$cap" | tco_tui_regions_from composer | rc_of tco_composer_echo_from "$text")" 0
      ok "sugerencias sin diálogo $label" "$(printf '%s' "$cap" | rc_of tco_pane_anomaly)" 1
      ok "reposo $label" "$(printf '%s' "$cap" | rc_of tco_pane_busy_from)" 1
    done
  done
  for suffix in '' .ansi; do
    for kind in s-reposo s-texto-normal; do
      cap="$(tco_fixture_decode "$REAL/slash/$kind$suffix.txt")"
      ok "forma normal conserva ancla $kind$suffix $AWK_BIN $locale" "$(printf '%s' "$cap" | rc_of tco_tui_anchor_from)" 0
    done
    ok "envío real un tecleo un Enter $suffix $AWK_BIN $locale" "$(send_sequence idle "$suffix")" '0:1:1:modal'
    ok "diálogo real bloquea sin tecleo $suffix $AWK_BIN $locale" "$(send_sequence modal "$suffix")" '2:0:0:modal'
  done
  cap="$(tco_fixture_decode "$REAL/slash/s-slash-model.txt")"
  fake="$(printf '%s\n' "$cap" | sed 's/❯ \/model/❯ texto normal/')"
  ok "texto normal exige pie $AWK_BIN $locale" "$(printf '%s' "$fake" | rc_of tco_tui_anchor_from)" 2
  for extra in 'prosa fuera de sugerencias' '  /' '   /model falso' '  /modelXYZ! falso'; do
    ok "fila ajena rechaza ancla $extra $AWK_BIN $locale" "$(printf '%s\n%s\n' "$cap" "$extra" | rc_of tco_tui_anchor_from)" 2
  done
  no_rows="$(printf '%s\n' "$cap" | sed -n '1,24p')"
  ok "barra sin sugerencias exige pie $AWK_BIN $locale" "$(printf '%s' "$no_rows" | rc_of tco_tui_anchor_from)" 2
  ok "continuación sin sugerencia rechazada $AWK_BIN $locale" "$(printf '%s\n                                    continuación\n' "$no_rows" | rc_of tco_tui_anchor_from)" 2
  dialog="$(printf '%s\n' "$cap"; cat "$REAL/modal.txt")"
  ok "barra con diálogo real activo $AWK_BIN $locale" "$(printf '%s' "$dialog" | tco_pane_anomaly)" modal
  ok "barra con diálogo impide envío $AWK_BIN $locale" "$(printf '%s' "$dialog" | rc_of tco_send_ready_from)" 2

  # ---- CLI 2.1.302: capturas reales de la lista de órdenes nueva (fila «  ❯ » + 4 espacios, descripción en la 32) ----
  # El ancla esperada sale de los separadores de la captura PLANA, no del analizador bajo prueba.
  oracle() { grep -n '^─' "$REAL302/slash/$1.txt" | head -2 | cut -d: -f1 | tr '\n' ' ' | sed 's/ $//'; }
  for kind in model effort parcial; do
    case "$kind" in model) text=/model;; effort) text=/effort;; parcial) text=/mod;; esac
    for suffix in '' .ansi; do
      cap="$(tco_fixture_decode "$REAL302/slash/s-slash-$kind$suffix.txt")"
      label="302 $kind$suffix $locale"
      ok "captura limpia $label" "$(printf '%s' "$cap" | rc_of tco_fixture_secret_scan)" 0
      ok "ancla real $label" "$(printf '%s' "$cap" | tco_tui_anchor_from)" "$(oracle "s-slash-$kind")"
      # El TUI 2.1.302 separa el prompt del texto con un espacio duro (U+00A0, bytes 302 240): se quita aquí también.
      ok "compositor exacto $label" "$(printf '%s' "$cap" | tco_tui_regions_from composer | tco_strip_dim_from | sed 's/^[[:space:]]*❯//; s/ //g' | tr -d '\302\240' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" "$text"
      ok "eco verificado $label" "$(printf '%s' "$cap" | tco_tui_regions_from composer | rc_of tco_composer_echo_from "$text")" 0
      ok "sugerencias sin diálogo $label" "$(printf '%s' "$cap" | rc_of tco_pane_anomaly)" 1
      ok "reposo $label" "$(printf '%s' "$cap" | rc_of tco_pane_busy_from)" 1
    done
  done
  # Orden con argumento (sin lista) y texto largo de dos líneas en el compositor: el eco sigue verificándose.
  long_text='lee /home/USER/.tco-relay/dispatch.0123456789abcdef.txt — es tu brief de tarea; síguelo y presenta el plan con ExitPlanMode'
  for pair in "s-effort-argumento:/effort xhigh" "s-lee-dos-lineas:$long_text"; do
    name="${pair%%:*}"; text="${pair#*:}"
    for suffix in '' .ansi; do
      cap="$(tco_fixture_decode "$REAL302/slash/$name$suffix.txt")"
      label="302 $name$suffix $locale"
      ok "ancla real $label" "$(printf '%s' "$cap" | tco_tui_anchor_from)" "$(oracle "$name")"
      ok "eco verificado $label" "$(printf '%s' "$cap" | tco_tui_regions_from composer | rc_of tco_composer_echo_from "$text")" 0
      ok "reposo $label" "$(printf '%s' "$cap" | rc_of tco_pane_busy_from)" 1
    done
  done
  for suffix in '' .ansi; do
    for kind in s-reposo s-texto-normal; do
      cap="$(tco_fixture_decode "$REAL302/slash/$kind$suffix.txt")"
      ok "302 forma normal conserva ancla $kind$suffix $locale" "$(printf '%s' "$cap" | tco_tui_anchor_from)" "$(oracle "$kind")"
    done
    ok "302 envío real un tecleo un Enter $suffix $locale" "$(send_sequence idle "$suffix" "$REAL302" 2.1.302 fallback)" '0:1:1:modal'
    ok "302 envío real con superficie de sesión $suffix $locale" "$(send_sequence idle "$suffix" "$REAL302" 2.1.302 superficie)" '0:1:1:modal'
    ok "302 diálogo real bloquea sin tecleo $suffix $locale" "$(send_sequence modal "$suffix" "$REAL302" 2.1.302 fallback)" '2:0:0:modal'
  done
  # Los seis estados de la calibración clasifican con el analizador real (la barra con la lista abierta es reposo).
  for pair in idle:1 busy:0 done:1 modal:2 redraw:2 barra:1; do
    ok "302 estado ${pair%%:*} clasifica $locale" "$(rc_of tco_pane_busy_from < "$REAL302/${pair%%:*}.txt")" "${pair##*:}"
  done
  # La lista de órdenes ABIERTA es una rama propia del analizador (tco_tui_list_open_from): la captura barra de la
  # calibración solo vale si la reconoce. El eco de «/model» en el compositor, con el pie normal y SIN lista, no basta.
  nbsp=$'\xc2\xa0'
  for st in idle busy done modal redraw; do
    ok "302 $st no es lista abierta $locale" "$(rc_of tco_tui_list_open_from < "$REAL302/$st.txt")" 2
  done
  ok "302 barra es lista abierta $locale" "$(rc_of tco_tui_list_open_from < "$REAL302/barra.txt")" 0
  ok "302 barra: la lista abierta da la misma ancla que el analizador $locale" \
    "$(tco_tui_list_open_from < "$REAL302/barra.txt")" "$(tco_tui_anchor_from < "$REAL302/barra.txt")"
  for suffix in '' .ansi; do
    ok "302 s-slash-model$suffix es lista abierta $locale" "$(tco_fixture_decode "$REAL302/slash/s-slash-model$suffix.txt" | rc_of tco_tui_list_open_from)" 0
    ok "289 s-slash-model$suffix (forma de 2 espacios) es lista abierta $locale" "$(tco_fixture_decode "$REAL/slash/s-slash-model$suffix.txt" | rc_of tco_tui_list_open_from)" 0
    ok "302 s-reposo$suffix no es lista abierta $locale" "$(tco_fixture_decode "$REAL302/slash/s-reposo$suffix.txt" | rc_of tco_tui_list_open_from)" 2
    ok "302 s-texto-normal$suffix no es lista abierta $locale" "$(tco_fixture_decode "$REAL302/slash/s-texto-normal$suffix.txt" | rc_of tco_tui_list_open_from)" 2
  done
  # Caso real de H4: «/model» tecleado, lista CERRADA, pie normal. El eco coincide y la caja es la normal, pero no hay lista.
  cerrada="$(LC_ALL=C sed "s/❯${nbsp} *\$/❯${nbsp}\/model/" "$REAL302/idle.txt")"
  ok "302 lista cerrada: el ancla normal la acepta (control: ahí falla el eco solo) $locale" "$(printf '%s\n' "$cerrada" | rc_of tco_tui_anchor_from)" 0
  ok "302 lista cerrada: el compositor contiene exactamente /model (el eco no distingue) $locale" \
    "$(printf '%s\n' "$cerrada" | tco_tui_regions_from composer | rc_of tco_composer_echo_from /model)" 0
  ok "302 lista cerrada con /model en el compositor NO es lista abierta $locale" "$(printf '%s\n' "$cerrada" | rc_of tco_tui_list_open_from)" 2
  ok "302 lista cerrada clasifica como reposo (la clasificación tampoco la distingue) $locale" "$(printf '%s\n' "$cerrada" | rc_of tco_pane_busy_from)" 1
  # Negativos: cada deformación de la lista real debe seguir rechazándose (rc 2) y nunca acreditar el compositor.
  base302="$(tco_fixture_decode "$REAL302/slash/s-slash-model.txt")"
  pad30="$(printf '%30s' '')"; pad32="$(printf '%32s' '')"
  mixta="$(printf '%s\n' "$base302" | sed 's/^    \/auto-mode-setup/  \/auto-mode-setup/')"
  ok "302 forma mezclada (2 y 4 espacios) rechaza $locale" "$(printf '%s' "$mixta" | rc_of tco_tui_anchor_from)" 2
  dos_sel="$(printf '%s\n' "$base302" | sed 's/^    \/effort/  ❯ \/effort/')"
  ok "302 dos filas seleccionadas rechaza $locale" "$(printf '%s' "$dos_sel" | rc_of tco_tui_anchor_from)" 2
  sel3="$(printf '%s\n' "$base302" | sed 's/^  ❯ \/model/   ❯ \/model/')"
  ok "302 fila seleccionada con 3 espacios rechaza $locale" "$(printf '%s' "$sel3" | rc_of tco_tui_anchor_from)" 2
  literal="$(printf '%s\n' "$base302" | sed 's/^    \/advisor/  X \/advisor/')"
  ok "302 fila con prefijo literal ajeno rechaza $locale" "$(printf '%s' "$literal" | rc_of tco_tui_anchor_from)" 2
  col="$(printf '%s\n' "$base302" | sed "s/^${pad32}bugs/${pad30}bugs/")"
  ok "302 continuación en otra columna rechaza $locale" "$(printf '%s' "$col" | rc_of tco_tui_anchor_from)" 2
  col36="$(printf '%s\n' "$base302" | sed "s/^${pad32}bugs/${pad32}    bugs/")"
  ok "302 continuación en la columna 36 de 2.1.289 rechaza $locale" "$(printf '%s' "$col36" | rc_of tco_tui_anchor_from)" 2
  for extra in 'prosa fuera de sugerencias' '  /' '    /' '     /model falso' '    /modelXYZ! falso' '  ❯ /'; do
    ok "302 fila ajena rechaza ancla $extra $locale" "$(printf '%s\n%s\n' "$base302" "$extra" | rc_of tco_tui_anchor_from)" 2
  done
  fake302="$(printf '%s\n' "$base302" | sed '8s/\/model/texto normal/')"
  ok "302 texto normal exige pie $locale" "$(printf '%s' "$fake302" | rc_of tco_tui_anchor_from)" 2
  sin_filas="$(printf '%s\n' "$base302" | sed -n '1,9p')"
  ok "302 barra sin sugerencias exige pie $locale" "$(printf '%s' "$sin_filas" | rc_of tco_tui_anchor_from)" 2
  ok "302 continuación sin sugerencia previa rechazada $locale" "$(printf '%s\n%scontinuación\n' "$sin_filas" "$pad32" | rc_of tco_tui_anchor_from)" 2
  dialog302="$(printf '%s\n' "$base302"; cat "$REAL302/modal.txt")"
  ok "302 barra con diálogo real activo $locale" "$(printf '%s' "$dialog302" | tco_pane_anomaly)" modal
  ok "302 barra con diálogo impide envío $locale" "$(printf '%s' "$dialog302" | rc_of tco_send_ready_from)" 2
done
# Integridad del juego 2.1.302: inventario de capturas codificadas y suma de los bytes originales.
ok "302 inventario y sumas de las capturas codificadas" "$(tco_fixture_check_sums "$REAL302" >/dev/null 2>&1; echo $?)" 0
# Ida y vuelta: codificar los bytes originales de cada captura devuelve exactamente el fichero versionado.
RT_BAD=0
while IFS= read -r f; do
  tco_fixture_decode "$f" > "$TMP_TEST/crudo"
  tco_fixture_encode "$TMP_TEST/crudo" | cmp -s - "$f" || RT_BAD=$((RT_BAD+1))
done < <(find "$REAL302" -type f -name '*.ansi.txt' | LC_ALL=C sort)
ok "302 ida y vuelta de codificar y descodificar es idéntica en cada captura" "$RT_BAD" 0
# Un byte alterado en una captura codificada debe romper la suma original.
rm -rf "$TMP_TEST/alt"; cp -r "$REAL302" "$TMP_TEST/alt"
sed -i '1s/^/x/' "$TMP_TEST/alt/slash/s-slash-model.ansi.txt"
ok "302 un byte alterado rompe la suma original" "$(tco_fixture_check_sums "$TMP_TEST/alt" >/dev/null 2>&1; echo $?)" 1
rm -rf "$TMP_TEST/alt"; cp -r "$REAL302" "$TMP_TEST/alt"
rm -f "$TMP_TEST/alt/slash/s-reposo.ansi.txt"
ok "302 una captura codificada ausente rompe el inventario" "$(tco_fixture_check_sums "$TMP_TEST/alt" >/dev/null 2>&1; echo $?)" 1
printf 'PASS=%s FAIL=%s TOTAL=%s\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] && [ "$((PASS+FAIL))" -eq 310 ]
