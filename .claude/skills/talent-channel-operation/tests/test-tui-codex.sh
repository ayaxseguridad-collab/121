#!/usr/bin/env bash
# Perfil codex del analizador del TUI: capturas reales de codex 0.166.0, sin cruce con Claude. Solo dentro del arnés.
# Las variantes (cita, 1h, queued, una vacía, lista de tres filas, aviso del alumno...) se derivan en un temporal y nunca
# entran en fixtures/pane/codex_0.166.0/. Las capturas con color se descodifican y, además, se les quitan las secuencias CSI.
# shellcheck disable=SC2329,SC2034,SC2016,SC2030,SC2031
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$TEST_DIR/../scripts"
INST="${TCO_TUI_INST:-$TEST_DIR/../../../instalacion/scripts}"
# shellcheck source=/dev/null
. "$TEST_DIR/capturas-codificadas.sh"
export TF_LINEAR_TEAM_KEY=ABC TCO_REPO_DIR=Repo-Neutro TCO_REPO_SLUG=org-neutra/Repo-Neutro TCO_REPO_STACK=ninguno
export TCO_ANEXO_FILE=references/anexo-neutro.md TCO_HOST_ENV_REL=Repo-Neutro/.env.local
export TCO_LINEAR_INPROGRESS_STATE=00000000-0000-4000-8000-000000000007
export TCO_LINEAR_INREVIEW_STATE=00000000-0000-4000-8000-000000000008
# shellcheck source=/dev/null
. "$SC/00-config.sh"
# shellcheck source=/dev/null
. "${TCO_TUI_LIB:-$SC/lib.sh}"
FX="$TEST_DIR/fixtures/pane"
CX="$FX/codex_0.166.0"
TMP_TEST="$(mktemp -d "${TMPDIR:-/tmp}/tco-tui-codex.XXXXXX")"; trap 'rm -rf "$TMP_TEST"' EXIT
PASS=0; FAIL=0
TOTAL_ESPERADO=164
ok() {
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'PASS %s\n' "$1";
  else FAIL=$((FAIL+1)); printf 'FAIL %s: actual [%s], esperado [%s]\n' "$1" "$2" "$3"; fi
}
rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
perfil() { TCO_TUI_CLI=codex "$@"; }
# «ancla|rc de ocupado» con el perfil codex; el ancla es «rcN» si no se localiza.
probe() {
  local cap anc busy
  cap="$(cat)"
  anc="$(printf '%s\n' "$cap" | perfil tco_tui_anchor_from 2>/dev/null)" || anc="rc$?"
  busy="$(printf '%s\n' "$cap" | perfil rc_of tco_pane_busy_from)"
  printf '%s|%s' "$anc" "$busy"
}
ansi_plano() { tco_fixture_decode "$1" | tco_strip_ansi_from; }
IDLE="$CX/idle.txt"; BUSY="$CX/busy.txt"; DONE="$CX/done.txt"; MODAL="$CX/modal.txt"; BARRA="$CX/barra.txt"; REDRAW="$CX/redraw.txt"

for locale in C C.UTF-8; do
  export LC_ALL="$locale"
  # ---- 1. Los seis estados reales con el perfil codex (12) ----
  for pair in idle:'46 48|1' done:'46 48|1' busy:'46 48|0' barra:'46 48|1' modal:'rc2|2' redraw:'rc2|2'; do
    st="${pair%%:*}"
    ok "codex $st ancla y ocupado $locale" "$(probe < "$CX/$st.txt")" "${pair#*:}"
  done
  # ---- 2. Las nueve capturas con color (descodificadas, y además sin CSI) dan lo mismo que su captura plana (18) ----
  for pair in a-reposo:'46 48|1' b-texto-corto:'46 48|1' c-lee-dos-lineas:'45 48|1' d-texto-con-turno:'46 48|0' \
              e-ocupado:'46 48|0' f-barra-con-turno:'46 48|0' g-terminado:'46 48|1' h-barra:'46 48|1' i-modal:'rc2|2'; do
    nm="${pair%%:*}"; want="${pair#*:}"
    ok "codex $nm con color y sin CSI $locale" \
      "$(tco_fixture_decode "$CX/slash/$nm.ansi.txt" | probe)/$(ansi_plano "$CX/slash/$nm.ansi.txt" | probe)" "$want/$want"
  done
  # ---- 3. Aviso del alumno: líneas «vacías» con un espacio, estado con espacio final, pie con «1 warning» (2) ----
  sed -e 's/^$/ /' -e 's#~/producto$#~/proyecto-curso #' \
      -e 's/shortcuts$/shortcuts                                                    ⚠ 1 warning · f2 to view/' "$IDLE" > "$TMP_TEST/advertencia.txt"
  ok "codex reposo con aviso y blancos finales $locale" "$(probe < "$TMP_TEST/advertencia.txt")" '46 48|1'
  sed -e 's/^$/ /' -e 's#~/producto$#~/proyecto-curso#' \
      -e 's/shortcuts$/shortcuts                                                    ⚠ 1 warning · f2 to view/' "$IDLE" > "$TMP_TEST/advertencia-sin.txt"
  ok "codex reposo con aviso y sin espacio final $locale" "$(probe < "$TMP_TEST/advertencia-sin.txt")" '46 48|1'
  # Captura REAL de un reposo con aviso (otra anchura, logo desplazado, «vacías» con un espacio), versionada tal cual.
  ok "codex reposo real con aviso, captura versionada $locale" "$(probe < "$CX/idle-advertencia.txt")" '46 48|1'
done
export LC_ALL=C.UTF-8

# ---- 4. Barra: la lista de órdenes abierta es una rama propia y el compositor da eco exacto de /model (7) ----
ok "barra es lista abierta" "$(perfil rc_of tco_tui_list_open_from < "$BARRA")" 0
ok "barra: la lista abierta da la misma ancla que el analizador" "$(perfil tco_tui_list_open_from < "$BARRA")" "$(perfil tco_tui_anchor_from < "$BARRA")"
ok "barra: eco exacto de /model en el compositor" "$(perfil tco_tui_regions_from composer < "$BARRA" | perfil rc_of tco_composer_echo_from /model)" 0
ok "barra: otro texto no da eco de /model" "$(perfil tco_tui_regions_from composer < "$BARRA" | perfil rc_of tco_composer_echo_from /effort)" 1
for st in idle busy done modal redraw; do
  printf '%s:%s ' "$st" "$(perfil rc_of tco_tui_list_open_from < "$CX/$st.txt")"
done > "$TMP_TEST/lista-no"
ok "los demás estados no son lista abierta" "$(cat "$TMP_TEST/lista-no")" 'idle:2 busy:2 done:2 modal:2 redraw:2 '
ok "barra con turno (con color) es lista abierta" "$(tco_fixture_decode "$CX/slash/f-barra-con-turno.ansi.txt" | perfil rc_of tco_tui_list_open_from)" 0
ok "reposo con /model tecleado y la lista cerrada NO es lista abierta" \
  "$(sed 's#^› Ask Codex to do anything#› /model#' "$IDLE" | perfil rc_of tco_tui_list_open_from)" 2

# ---- 5. Sin cruce: con el perfil de Claude las seis de Codex dan rc 2, y con el de Codex las de Claude (17) ----
for st in idle busy done modal redraw barra; do
  ok "perfil vacío: $st de codex es rc 2" "$(rc_of tco_pane_busy_from < "$CX/$st.txt")" 2
done
for st in idle busy done modal redraw; do
  ok "perfil codex: $st de claude_2.1.289 es rc 2" "$(perfil rc_of tco_pane_busy_from < "$FX/claude_2.1.289/$st.txt")" 2
done
for st in idle busy done modal redraw barra; do
  ok "perfil codex: $st de claude_2.1.302 es rc 2" "$(perfil rc_of tco_pane_busy_from < "$FX/claude_2.1.302/$st.txt")" 2
done
# ---- 6. Un perfil desconocido no cae en reglas ajenas: rc 2 en todo, también con las capturas de Claude (11) ----
for st in idle busy done modal redraw barra; do
  ok "perfil otro: $st de codex es rc 2" "$(TCO_TUI_CLI=otro rc_of tco_pane_busy_from < "$CX/$st.txt")" 2
done
ok "perfil otro: reposo de claude es rc 2 (con el perfil de Claude sería 1)" "$(TCO_TUI_CLI=otro rc_of tco_pane_busy_from < "$FX/claude_2.1.302/idle.txt")" 2
ok "perfil otro: ocupado de claude es rc 2 (con el perfil de Claude sería 0)" "$(TCO_TUI_CLI=otro rc_of tco_pane_busy_from < "$FX/claude_2.1.302/busy.txt")" 2
ok "perfil otro: el ancla es rc 2" "$(TCO_TUI_CLI=otro rc_of tco_tui_anchor_from < "$FX/claude_2.1.302/idle.txt")" 2
ok "perfil otro: la lista abierta es rc 2" "$(TCO_TUI_CLI=otro rc_of tco_tui_list_open_from < "$FX/claude_2.1.302/barra.txt")" 2
ok "perfil otro: anomalía cli-desconocido" "$(TCO_TUI_CLI=otro tco_pane_anomaly < "$FX/claude_2.1.302/idle.txt")" cli-desconocido

# ---- 7. Ocupado: solo cuenta la última línea en columna 0 del transcript (9) ----
sed '10s/.*/• Working (5s • esc to interrupt) es una cita de un veredicto/' "$DONE" > "$TMP_TEST/cita.txt"
ok "una cita de «esc to interrupt» en un mensaje intermedio no ocupa el panel" "$(probe < "$TMP_TEST/cita.txt")" '46 48|1'
sed 's/(5s •/(1h 02m 03s •/' "$BUSY" > "$TMP_TEST/hora.txt"
ok "ocupado con «1h 02m 03s»" "$(probe < "$TMP_TEST/hora.txt")" '46 48|0'
sed 's/esc to interrupt)/esc to interrupt · 1 queued)/' "$BUSY" > "$TMP_TEST/cola.txt"
ok "ocupado con «· 1 queued»" "$(probe < "$TMP_TEST/cola.txt")" '46 48|0'
sed '45d' "$BUSY" > "$TMP_TEST/una-vacia.txt"
ok "ocupado con UNA sola vacía antes del compositor" "$(probe < "$TMP_TEST/una-vacia.txt")" '45 47|0'
sed 's/esc to interrupt) · .*/esc to interrupt · 1 background terminal running/' "$BUSY" > "$TMP_TEST/sin-cierre.txt"
ok "forma de temporizador sin el cierre estricto es rc 2" "$(probe < "$TMP_TEST/sin-cierre.txt")" '46 48|2'
sed '49s/Ejecuta espera de 40 segundos/esc to interrupt/' "$DONE" > "$TMP_TEST/titulo.txt"
ok "una línea de estado con el título «esc to interrupt» y el compositor en reposo es reposo" "$(probe < "$TMP_TEST/titulo.txt")" '46 48|1'
ansi_plano "$CX/slash/f-barra-con-turno.ansi.txt" > "$TMP_TEST/f-plano.txt"
sed -e '45s#.*#› /model  choose what model and reasoning effort to use\n  /mcp  list configured MCP servers\n  /mention  mention a file#' \
    -e '47s#.*#› /m#' "$TMP_TEST/f-plano.txt" > "$TMP_TEST/lista3-turno.txt"
ok "lista de tres filas con un turno en curso" "$(probe < "$TMP_TEST/lista3-turno.txt")" '48 50|0'
sed -e '43,44d' -e '45s#.*#› /model  choose what model and reasoning effort to use\n  /mcp  list configured MCP servers\n  /mention  mention a file#' \
    -e '47s#.*#› /m#' "$TMP_TEST/f-plano.txt" > "$TMP_TEST/lista3-reposo.txt"
ok "la misma lista de tres filas sin turno es reposo" "$(probe < "$TMP_TEST/lista3-reposo.txt")" '46 48|1'
ok "lista de tres filas es lista abierta" "$(perfil rc_of tco_tui_list_open_from < "$TMP_TEST/lista3-turno.txt")" 0

# ---- 7b. Marcador de ocupado: exactamente «• », «◦ » o ninguno (16) ----
# codex-cli 0.166.0, tui/src/status_indicator_widget.rs → motion::activity_indicator (ReducedMotionIndicator::Hidden):
# con truecolor «•» con shimmer; sin truecolor parpadea cada 600 ms entre «•» y «◦» atenuado; con movimiento reducido no
# hay marcador. Medido en el ensayo de la 1.7.5: «◦ Working (31s • esc to interrupt)». Variantes derivadas de busy.txt.
ESC=$'\033'
for locale in C C.UTF-8; do
  export LC_ALL="$locale"
  sed '44s/^• Working/◦ Working/' "$BUSY" > "$TMP_TEST/hueco.txt"
  ok "ocupado con el fotograma «◦» $locale" "$(probe < "$TMP_TEST/hueco.txt")" '46 48|0'
  sed '44s/^• Working/Working/' "$BUSY" > "$TMP_TEST/sin-marcador.txt"
  ok "ocupado sin marcador (movimiento reducido) $locale" "$(probe < "$TMP_TEST/sin-marcador.txt")" '46 48|0'
  sed -e '44s/^• Working/◦ Working/' -e 's/esc to interrupt) · .*/esc to interrupt · 1 background terminal running/' \
    "$BUSY" > "$TMP_TEST/hueco-sin-cierre.txt"
  ok "«◦» con forma de temporizador sin el cierre estricto es rc 2 $locale" "$(probe < "$TMP_TEST/hueco-sin-cierre.txt")" '46 48|2'
  sed '44s/.*/Note (see the report) para el informe/' "$BUSY" > "$TMP_TEST/texto-parentesis.txt"
  ok "texto en columna 0 «Note (see…)» sin marcador no ocupa el panel $locale" "$(probe < "$TMP_TEST/texto-parentesis.txt")" '46 48|1'
  sed '44s/.*/Note (see esc to interrupt) en una respuesta/' "$BUSY" > "$TMP_TEST/texto-cita.txt"
  ok "texto sin marcador que cita «esc to interrupt» sin el tiempo no ocupa el panel $locale" "$(probe < "$TMP_TEST/texto-cita.txt")" '46 48|1'
  sed '44s/^• Working/◌ Working/' "$BUSY" > "$TMP_TEST/glifo-ajeno.txt"
  ok "un glifo ajeno «◌» no ocupa el panel $locale" "$(probe < "$TMP_TEST/glifo-ajeno.txt")" '46 48|1'
  sed '44s/^• Working/⠋ Working/' "$BUSY" > "$TMP_TEST/braille.txt"
  ok "un fotograma braille «⠋» no ocupa el panel $locale" "$(probe < "$TMP_TEST/braille.txt")" '46 48|1'
  tco_fixture_decode "$CX/slash/e-ocupado.ansi.txt" \
    | sed "44s/^${ESC}\[1m${ESC}\[38;2;128;128;128m•/${ESC}[2m◦/" > "$TMP_TEST/hueco-color.txt"
  ok "ocupado con «◦» atenuado y color $locale" "$(grep -c '◦' "$TMP_TEST/hueco-color.txt" | tr -d '\n')/$(probe < "$TMP_TEST/hueco-color.txt")" '1/46 48|0'
done

# ---- 8. Ancla estricta: nunca una pieza suelta (5) ----
sed -e 's/^  1\. /› 1. /' -e 's/^› 6\. /  6. /' -e '$s#.*#  GPT-5.6-Sol medium · ~/producto#' "$MODAL" > "$TMP_TEST/selector1.txt"
ok "un selector con la primera fila seleccionada y una línea de estado falsa es rc 2" "$(perfil rc_of tco_tui_anchor_from < "$TMP_TEST/selector1.txt")" 2
sed -e '$s#.*#  GPT-5.6-Sol medium · ~/producto#' "$MODAL" > "$TMP_TEST/selector6.txt"
ok "un selector con la sexta fila seleccionada y una línea de estado falsa es rc 2" "$(perfil rc_of tco_tui_anchor_from < "$TMP_TEST/selector6.txt")" 2
ok "un eco de usuario con salida sangrada y sin compositor es rc 2" \
  "$(printf '%s\n' '' '› x' '' '  └ (no output)' | perfil rc_of tco_tui_anchor_from)" 2
ansi_plano "$CX/slash/c-lee-dos-lineas.ansi.txt" | sed '47s#$#\n  tercera línea del compositor#' > "$TMP_TEST/compositor3.txt"
ok "un compositor de tres líneas se localiza entero" "$(probe < "$TMP_TEST/compositor3.txt")" '45 49|1'
sed '$d' "$DONE" > "$TMP_TEST/sin-pie.txt"
ok "sin pie el estado cierra el ancla" "$(probe < "$TMP_TEST/sin-pie.txt")" '46 48|1'

# ---- 8b. Borrador en el compositor: Codex deja en el pie solo lo de la derecha (bottom_pane/footer.rs, ComposerHasDraft) (5) ----
# Medido en el ensayo de la 1.7.5 (F8): bajo la línea de estado, solo «⚠ 1 warning · f2 to view», alineado a la derecha.
# El relay del plan al auditor no se sometía porque el ancla no lo aceptaba y el pane quedaba «ambiguo».
TXT_C='lee /tmp/fabrica-relay/encargo-prueba.md revisa este documento de prueba y responde con un resumen breve de su estructura, sin cambiar ningun fichero del repositorio y sin ejecutar ninguna orden; despues espera la siguiente instruccion del coordinador'
ansi_plano "$CX/slash/c-lee-dos-lineas.ansi.txt" | sed '49s#$#\n                                                                                    ⚠ 1 warning · f2 to view#' > "$TMP_TEST/borrador-aviso.txt"
ok "borrador con el pie solo de aviso a la derecha se localiza" "$(probe < "$TMP_TEST/borrador-aviso.txt")" '45 48|1'
ok "eco íntegro del borrador con el pie solo de aviso" \
  "$(perfil tco_tui_regions_from composer < "$TMP_TEST/borrador-aviso.txt" | perfil rc_of tco_composer_echo_from "$TXT_C")" 0
ansi_plano "$CX/slash/c-lee-dos-lineas.ansi.txt" | sed '49s#$#\n                                                                                      12% context left#' > "$TMP_TEST/borrador-contexto.txt"
ok "borrador con el contexto a la derecha como pie se localiza" "$(probe < "$TMP_TEST/borrador-contexto.txt")" '45 48|1'
ansi_plano "$CX/slash/c-lee-dos-lineas.ansi.txt" | sed '49s#$#\n                                                                                    ⚠ 1 warning · f2 to view\n  otra línea#' > "$TMP_TEST/dos-pies.txt"
ok "dos líneas bajo el estado no son pie: rc 2" "$(perfil rc_of tco_tui_anchor_from < "$TMP_TEST/dos-pies.txt")" 2
ansi_plano "$CX/slash/c-lee-dos-lineas.ansi.txt" | sed '49s#$#\n⚠ 1 warning · f2 to view#' > "$TMP_TEST/pie-col0.txt"
ok "un aviso en columna 0 bajo el estado no es pie: rc 2" "$(perfil rc_of tco_tui_anchor_from < "$TMP_TEST/pie-col0.txt")" 2

# ---- 9. Anomalías por rama en el perfil codex (6) ----
an() { local o; o="$(perfil tco_pane_anomaly)"; printf '%s' "${o:-limpio}"; }
ok "anomalía codex: el selector de modelo es modal" "$(an < "$MODAL")" modal
ok "anomalía codex: el cuadro de confianza es trust" "$(printf '%s\n' '  Do you trust the contents of this directory?' '› 1. Yes, I trust this folder' '  2. No' | an)" trust
sed '$s#.*#  Press up to edit queued messages#' "$DONE" > "$TMP_TEST/queued.txt"
ok "anomalía codex: el aviso de cola de Claude no aplica" "$(an < "$TMP_TEST/queued.txt")" limpio
ok "anomalía codex: la encuesta de Claude no aplica" "$(printf '%s\n' 'How is Claude doing this session? (optional)' '1: Bad    2: Fine   3: Good   0: Dismiss' | an)" limpio
ok "anomalía codex: reposo limpio" "$(an < "$IDLE")" limpio
ok "anomalía codex: ocupado limpio" "$(an < "$BUSY")" limpio

# ---- 10. Eco, compositor vacío y entrega con el perfil codex (7) ----
reg_e="$(tco_fixture_decode "$CX/slash/e-ocupado.ansi.txt" | perfil tco_tui_regions_from composer)"
reg_b="$(tco_fixture_decode "$CX/slash/b-texto-corto.ansi.txt" | perfil tco_tui_regions_from composer)"
ok "compositor vacío: el marcador atenuado no cuenta" "$(printf '%s\n' "$reg_e" | perfil rc_of tco_composer_empty_from)" 0
ok "compositor con texto no es vacío" "$(printf '%s\n' "$reg_b" | perfil rc_of tco_composer_empty_from)" 1
ok "eco exacto del texto tecleado" "$(printf '%s\n' "$reg_b" | perfil rc_of tco_composer_echo_from 'hola mundo')" 0
ok "entrega: la línea de ocupado es señal de consumo" "$(perfil rc_of tco_delivered_from "$(cat "$BUSY")" '')" 0
ok "entrega: el token en el transcript es señal de consumo" "$(perfil rc_of tco_delivered_from "$(cat "$DONE")" terminado)" 0
ok "entrega: sin ocupado ni token no hay entrega" "$(perfil rc_of tco_delivered_from "$(cat "$IDLE")" terminado)" 1
ok "entrega: el título «esc to interrupt» de la línea de estado no es señal" "$(perfil rc_of tco_delivered_from "$(cat "$TMP_TEST/titulo.txt")" '')" 1

# ---- 11. tco_tui_cli_de: único sitio que interpreta el par (9) ----
ok "tco_tui_cli_de codex:0.166.0" "$(tco_tui_cli_de codex:0.166.0)" codex
ok "tco_tui_cli_de claude:2.1.302" "$(tco_tui_cli_de claude:2.1.302)" claude
ok "tco_tui_cli_de codex_0.166.0" "$(tco_tui_cli_de codex_0.166.0)" codex
for bad in otro:1.0.0 codex codex:1.2 codex:0.166.0-beta 'codex:1.2.3 x' ''; do
  ok "tco_tui_cli_de rechaza «$bad»" "$(rc_of tco_tui_cli_de "$bad")" 1
done

# ---- 12. Perfil de un panel = su CLI declarado; un CLI no resuelto no fija perfil (4) ----
(
  TCO_DEV_CLI=claude-root; TCO_AUDIT_CLI=codex-root
  printf '%s|%s|%s' "$(_tco_tui_cli_panel 01 "$(tco_pane_audit)")" "$(rc_of _tco_tui_cli_panel 01 "$(tco_pane_dev)")" \
    "$(rc_of _tco_tui_cli_panel 01 '%99')" > "$TMP_TEST/panel-1"
  TCO_AUDIT_CLI=''
  rc_of _tco_tui_cli_panel 01 "$(tco_pane_audit)" > "$TMP_TEST/panel-2"
  TCO_DEV_CLI=/usr/bin/codex
  _tco_tui_cli_panel 01 "$(tco_pane_dev)" > "$TMP_TEST/panel-3"
)
ok "panel de auditoría codex fija el perfil; el de desarrollo Claude y un panel ajeno no" "$(cat "$TMP_TEST/panel-1")" 'codex|1|1'
ok "CLI declarado vacío no fija perfil" "$(cat "$TMP_TEST/panel-2")" 1
ok "CLI con ruta absoluta fija el perfil" "$(cat "$TMP_TEST/panel-3")" codex
ok "00-config.sh desfija el perfil heredado del entorno" \
  "$(TCO_TUI_CLI=codex bash -c '. "$1/00-config.sh"; printf "%s" "${TCO_TUI_CLI-sin}"' _ "$SC")" sin

# ---- 13. tco_pane_busy: el perfil sale del CLI declarado del panel y el entorno no lo cambia (7) ----
busy_panel() { # cli-declarado cli:versión captura [tui-del-entorno]
  (
    TCO_TUI_CLI="${4:-}" bash -c '
      . "$1/00-config.sh"; . "$1/lib.sh"
      TCO_DEV_CLI="$2"; TCO_AUDIT_CLI="$2"; CV="$3"; CAP="$4"
      _tco_carril_session() { return 1; }
      _tco_pane_cli_version() { printf "%s\n" "$CV"; }
      tco_cap_pane() { cat "$CAP"; }
      sleep() { :; }
      TCO_PANE_CALIBRATED="$CV"; TCO_IDLE_STABILITY_GAP=0
      rc=0; tco_pane_busy 01 "$(tco_pane_audit)" >/dev/null || rc=$?
      printf "%s" "$rc"' _ "$SC" "$1" "$2" "$3"
  )
}
ok "panel codex con captura de reposo: libre" "$(busy_panel codex codex:0.166.0 "$IDLE")" 1
ok "panel codex con captura de ocupado: ocupado" "$(busy_panel codex codex:0.166.0 "$BUSY")" 0
ok "panel codex cuyo CLI resuelto es claude: desconocido" "$(busy_panel codex claude:2.1.302 "$IDLE")" 2
ok "panel claude con captura de claude: libre" "$(busy_panel claude claude:2.1.302 "$FX/claude_2.1.302/idle.txt")" 1
ok "panel claude con captura de codex: desconocido" "$(busy_panel claude codex:0.166.0 "$IDLE")" 2
ok "panel claude con TCO_TUI_CLI=codex heredado: el mismo resultado" "$(busy_panel claude claude:2.1.302 "$FX/claude_2.1.302/idle.txt" codex)" 1
ok "panel claude con TCO_TUI_CLI=otro heredado: el mismo resultado" "$(busy_panel claude claude:2.1.302 "$FX/claude_2.1.302/idle.txt" otro)" 1

# ---- 14. Idempotencia del capturador: cada fixture es un punto fijo de capture-pane-fixtures.sh (6) ----
cap_fix() { # estado fichero
  rm -rf "$TMP_TEST/idem"; mkdir -p "$TMP_TEST/idem"
  TCO_FIXTURE_DIR="$TMP_TEST/idem" bash "$SC/capture-pane-fixtures.sh" --from-stdin --cli-version codex:0.166.0 "$1" < "$2" >/dev/null 2>&1 || return 1
  cmp -s "$TMP_TEST/idem/codex_0.166.0/$1.txt" "$2" && printf 'igual' || printf 'distinto'
}
ok "idempotencia idle" "$(cap_fix idle "$IDLE")" igual
ok "idempotencia busy" "$(cap_fix busy "$BUSY")" igual
ok "idempotencia modal" "$(cap_fix modal "$MODAL")" igual
ok "idempotencia done (como idle)" "$(cap_fix idle "$DONE")" igual
ok "idempotencia barra (como idle)" "$(cap_fix idle "$BARRA")" igual
rm -rf "$TMP_TEST/idem"; mkdir -p "$TMP_TEST/idem"
TCO_FIXTURE_DIR="$TMP_TEST/idem" bash "$SC/capture-pane-fixtures.sh" --from-stdin --cli-version codex:0.166.0 redraw < "$DONE" >/dev/null 2>&1
ok "el recorte de redraw sobre done es la fixture redraw" "$(cmp -s "$TMP_TEST/idem/codex_0.166.0/redraw.txt" "$REDRAW" && echo igual || echo distinto)" igual

# ---- 15. Integridad del juego: sumas, barrido y escáner de secretos (3) ----
ok "codex 0.166.0 inventario y sumas de las capturas codificadas" "$(tco_fixture_check_sums "$CX" >/dev/null 2>&1; echo $?)" 0
ok "codex 0.166.0 barrido de secretos de nombres y contenido" "$(tco_fixture_sweep "$CX")" 0
SC_BAD=0
for st in idle busy done modal redraw barra; do tco_fixture_secret_scan < "$CX/$st.txt" >/dev/null 2>&1 || SC_BAD=$((SC_BAD+1)); done
ok "codex 0.166.0 las seis capturas pasan el escáner" "$SC_BAD" 0

# ---- 16. f8-capturas.sh y calibrar-pane.sh: perfil por CLI y mensajes que no meten en un bucle (8) ----
CLON="$TMP_TEST/clon"; ST="$CLON/.claude/skills/talent-channel-operation/scripts"
mkdir -p "$ST"
printf '%s\n' ". \"$SC/00-config.sh\"" > "$ST/00-config.sh"
printf '%s\n' ". \"$SC/lib.sh\"" '_tco_pane_cli_version() { printf "%s\n" "$FAKE_CV"; }' 'tco_cap_pane() { cat "$FAKE_PANE"; }' > "$ST/lib.sh"
cp "$SC/capture-pane-fixtures.sh" "$ST/capture-pane-fixtures.sh"
f8() { # versión captura estado
  F8_FX="$(mktemp -d "$TMP_TEST/f8fx.XXXXXX")"; F8_RC=0
  F8_OUT="$(FAKE_CV="$1" FAKE_PANE="$2" TCO_PANE_CLI_VERSION_CMD='cli --version' TCO_FIXTURE_DIR="$F8_FX" \
    bash "$INST/f8-capturas.sh" "$CLON" 01 v:.1 "$3" 2>&1)" || F8_RC=$?
}
f8 codex:9.9.9 "$MODAL" idle
ok "f8: codex sin capturas de referencia con una clasificación mala: rc 1" "$F8_RC" 1
ok "f8: codex sin capturas de referencia dice que se repite UNA vez y se escala" "$(printf '%s' "$F8_OUT" | grep -c 'repite UNA vez')" 1
ok "f8: ese mensaje no pide provocar el estado otra vez ni imprime la pantalla" "$(printf '%s' "$F8_OUT" | grep -c -e 'vuelve a provocar' -e 'Select Model')" 0
mkdir -p "$CLON/.claude/skills/talent-channel-operation/tests/fixtures/pane/codex_0.166.0"
f8 codex:0.166.0 "$MODAL" idle
ok "f8: codex con capturas de referencia conserva el mensaje de siempre" "$(printf '%s' "$F8_OUT" | grep -c 'vuelve a provocar el estado')" 1
f8 claude:2.1.302 "$MODAL" idle
ok "f8: claude conserva el mensaje de siempre, haya o no capturas de referencia" \
  "$(printf '%s' "$F8_OUT" | grep -c 'clasificación rc=2 esperado=1; descartada, vuelve a provocar el estado')" 1
f8 codex:0.166.0 "$IDLE" idle
ok "f8: codex acepta una captura de reposo bien clasificada" "$F8_RC/$(cmp -s "$F8_FX/codex_0.166.0/idle.txt" "$IDLE" && echo igual)" 0/igual
mkdir -p "$TMP_TEST/inst" "$TMP_TEST/par/codex_0.166.0"
cp "$INST/calibrar-pane.sh" "$TMP_TEST/inst/calibrar-pane.sh"
printf '%s\n' 'print("registrado")' > "$TMP_TEST/inst/calibracion.py"
cp "$CX/idle.txt" "$CX/busy.txt" "$CX/done.txt" "$CX/modal.txt" "$CX/redraw.txt" "$CX/barra.txt" "$TMP_TEST/par/codex_0.166.0/"
CAL_RC=0; CAL_OUT="$(bash "$TMP_TEST/inst/calibrar-pane.sh" "$CLON" "$TMP_TEST/par/codex_0.166.0" --registrar 2>&1)" || CAL_RC=$?
ok "calibrar-pane: las seis de codex 0.166.0 se clasifican y se registran" "$CAL_RC/$(printf '%s' "$CAL_OUT" | grep -c -e 'capturas clasificadas' -e 'registrado')" 0/2
mkdir -p "$TMP_TEST/par9/codex_9.9.9"
cp "$CX/idle.txt" "$CX/busy.txt" "$CX/done.txt" "$CX/redraw.txt" "$CX/barra.txt" "$TMP_TEST/par9/codex_9.9.9/"
cp "$CX/idle.txt" "$TMP_TEST/par9/codex_9.9.9/modal.txt"
CAL_RC=0; CAL_OUT="$(bash "$TMP_TEST/inst/calibrar-pane.sh" "$CLON" "$TMP_TEST/par9/codex_9.9.9" --completo 2>&1)" || CAL_RC=$?
ok "calibrar-pane: codex sin capturas de referencia con una clasificación mala dice repetir UNA vez" "$CAL_RC/$(printf '%s' "$CAL_OUT" | grep -c 'repite UNA vez')" 1/1

# ---- 16b. Tecla de submit de un panel Codex: su secuencia, una tecla por invocación; Claude conserva C-m (4) ----
submit_keys_case() ( # cli-del-auditor secuencia-forzada tecla-de-submit → teclas de submit enviadas, separadas por coma
  TCO_DEV_CLI=claude-root; TCO_AUDIT_CLI="$1"; TCO_AUDIT_SUBMIT_SEQ="$2"
  : > "$TMP_TEST/submit-calls"
  incus() { printf '%s\n' "$*" >> "$TMP_TEST/submit-calls"; return 0; }
  sleep() { :; }
  tco_send_ready() { return 0; }
  tco_wait_config() { return 0; }
  tco_cap_pane_e() { printf 'x\n'; }
  tco_tui_regions_from() { printf 'x\n'; }
  tco_pane_busy_from() { return 1; }
  tco_composer_echo_from() { return 0; }
  _tco_send_text_submit 01 "$(tco_pane_audit)" hola "$3" yes >/dev/null 2>&1 || { printf 'rc%s' "$?"; return; }
  grep 'send-keys' "$TMP_TEST/submit-calls" | grep -v -e ' -l -- ' | sed -E 's/.* //' | paste -sd, -
)
ok "submit en panel codex: C-m por defecto se envía como Enter,Enter y ninguna C-m" "$(submit_keys_case codex-root '' C-m)" 'Enter,Enter'
ok "submit en panel de auditoría claude: exactamente C-m (sin cambio)" "$(submit_keys_case claude-root '' C-m)" 'C-m'
ok "submit en panel codex con TCO_AUDIT_SUBMIT_SEQ=Enter: Enter una vez" "$(submit_keys_case codex-root Enter C-m)" 'Enter'
ok "submit en panel codex con Enter explícito: Enter una vez" "$(submit_keys_case codex-root '' Enter)" 'Enter'

# ---- 17. Reglas por cuerpo de función, sin ejecutar nada del producto (4) ----
cuerpo() { # fichero función → desde «nombre()» hasta la primera línea que empieza por } o )
  awk -v fn="$2" 'index($0, fn "()") == 1 { on=1 } on { print } on && /^[})]/ { exit }' "$1"
}
PURAS="tco_tui_anchor_from _tco_tui_anchor_codex tco_tui_list_open_from tco_tui_regions_from tco_pane_busy_from _tco_busy_codex_from tco_redraw_fixture_from tco_pane_anomaly tco_composer_echo_from tco_composer_empty_from tco_delivered_from tco_input_pending_from tco_send_ready_from tco_dialog_choice_from tco_extract_stop_audit"
ENTRADAS="tco_clear_input tco_escape_stuck_input tco_send_dialog_choice tco_pane_busy tco_pane_heal tco_verify_delivered tco_send_ready _tco_send_text_submit tco_relay_file tco_queue_dev_file tco_codex_skip_update_and_trust"
PURAS_MAL=0
for f in $PURAS; do
  n="$(cuerpo "$SC/lib.sh" "$f" | grep -cE '_tco_pane_cli_version|_tco_tui_cli_panel|tco_cli_exe|local -x TCO_TUI_CLI|TCO_TUI_CLI=')"
  PURAS_MAL=$((PURAS_MAL + n))
  [ -n "$(cuerpo "$SC/lib.sh" "$f")" ] || PURAS_MAL=$((PURAS_MAL + 1))
done
ok "ninguna función pura resuelve ni fija el CLI" "$PURAS_MAL" 0
ENTRADAS_MAL=0
for f in $ENTRADAS; do
  n="$(cuerpo "$SC/lib.sh" "$f" | grep -cF "local -x TCO_TUI_CLI=''; TCO_TUI_CLI=\"\$(_tco_tui_cli_panel")"
  [ "$n" -eq 1 ] || ENTRADAS_MAL=$((ENTRADAS_MAL+1))
done
ok "cada entrada por panel fija el perfil con local -x desde el CLI declarado" "$ENTRADAS_MAL" 0
ok "lib.sh solo fija el perfil con local -x en las entradas por panel" "$(grep -c 'local -x TCO_TUI_CLI' "$SC/lib.sh")" 11
ok "el despacho del auditor fija el perfil con local -x en tco_audit_once" "$(cuerpo "$SC/audit-gate.sh" tco_audit_once | grep -cF "local -x TCO_TUI_CLI=''; TCO_TUI_CLI=\"\$(_tco_tui_cli_panel")" 1

printf 'PASS=%s FAIL=%s TOTAL=%s\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] && [ "$((PASS+FAIL))" -eq "$TOTAL_ESPERADO" ]
