#!/usr/bin/env bash
# Versión del CLI de un pane y preflight de calibración del despacho; solo dentro del arnés (dobles de incus, ningún pane real).
# shellcheck disable=SC2329,SC2034,SC2016,SC2030,SC2031
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$HERE/../scripts"
export TF_LINEAR_TEAM_KEY=ABC TCO_REPO_DIR=Repo-Neutro TCO_REPO_SLUG=org-neutra/Repo-Neutro TCO_REPO_STACK=ninguno
export TCO_ANEXO_FILE=references/anexo-neutro.md TCO_HOST_ENV_REL=Repo-Neutro/.env.local
export TCO_LINEAR_INPROGRESS_STATE=00000000-0000-4000-8000-000000000007
export TCO_LINEAR_INREVIEW_STATE=00000000-0000-4000-8000-000000000008
# shellcheck source=/dev/null
. "$SC/00-config.sh"
# shellcheck source=/dev/null
. "${TCO_PREFLIGHT_LIB:-$SC/lib.sh}"
TMP_TEST="$(mktemp -d)"; trap 'rm -rf "$TMP_TEST"' EXIT
PASS=0; FAIL=0
ok() {
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'PASS %s\n' "$1";
  else FAIL=$((FAIL+1)); printf 'FAIL %s: actual [%s], esperado [%s]\n' "$1" "$2" "$3"; fi
}
rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }

# ---- _tco_pane_cli_version: GRAMÁTICA CERRADA de la salida COMPLETA de «<agente> --version», validada sobre BYTES ----
# La salida (o la del override) va a un fichero y solo vale si es EXACTAMENTE una línea terminada en \n que encaja ANCLADA
# con la forma del CLI (references/formas-version.tsv) y sin ningún byte de más. No se extrae nada de un texto libre.
# Doble de incus: nunca toca un contenedor; devuelve los bytes de FAKE_FILE tal cual o, sin él, FAKE_VER por printf %b,
# y anota la orden remota.
incus() {
  local args=("$@") i cval=""
  for ((i=0; i<${#args[@]}; i++)); do
    if [ "${args[$i]}" = "-c" ]; then cval="${args[$((i+1))]}"; break; fi
  done
  printf '%s\n' "$cval" >> "$TMP_TEST/remoto"
  # Con OTHER_BIN, el binario del OTRO pane (último argumento de la orden) responde con su captura buena OTHER_FILE.
  if [ -n "${OTHER_BIN:-}" ] && [ "${args[$((${#args[@]} - 1))]}" = "$OTHER_BIN" ]; then cat "$OTHER_FILE"
  elif [ -n "${FAKE_FILE:-}" ]; then cat "$FAKE_FILE"; else printf '%b' "$FAKE_VER"; fi
}
unset TCO_PANE_CLI_VERSION_CMD FAKE_FILE
mkdir -p "$TMP_TEST/tmp"
ver_case() ( # salida-del-cli agente pane
  # Ley del lead (7-nov): el auditor (pane .1) es siempre Codex y el desarrollo (pane .0) es Claude; el agente bajo prueba ocupa su pane.
  FAKE_VER="$1"; AGENTE="$2"; TCO_TMUX=v
  case "$3" in *.1) TCO_DEV_CLI=claude; TCO_AUDIT_CLI="$2" ;; *) TCO_DEV_CLI="$2"; TCO_AUDIT_CLI=codex ;; esac
  export TMPDIR="$TMP_TEST/tmp" # el fichero temporal de la función queda aquí: se comprueba que no sobrevive
  _tco_pane_agent_exes() { printf '%s\n' "$AGENTE"; }
  _tco_pane_cli_version 01 "$3"
)
ver_file() ( # fichero-con-la-salida agente pane
  FAKE_FILE="$1"; ver_case '' "$2" "$3"
)
VDIR="$HERE/fixtures/version"
REAL_CLAUDE="$VDIR/claude--version.bin"; REAL_CODEX="$VDIR/codex--version.bin"
FORMAS="$SC/../references/formas-version.tsv"
forma_de() { local k v; while IFS=$'\t' read -r k v; do [ "$k" = "$1" ] && printf '%s' "$v"; done < "$FORMAS"; }

# Positivos REALES (fixtures/version/ORIGEN.md: stdout crudo de «<cli> --version», 17-oct-2026).
ok "cerrada: las capturas reales son las de ORIGEN.md (sha256)" \
  "$(sha256sum < "$REAL_CLAUDE" | cut -c1-64)/$(sha256sum < "$REAL_CODEX" | cut -c1-64)" \
  "f98cef0381704b555d9188ed0ac009867d71df3478510517617c28f5a5054953/1df57fdc934f35bbd09e26308fbbd895698596f3be833ace1027c6bcfd2f81e2"
ok "cerrada: captura REAL de claude -> claude:2.1.301" "$(ver_file "$REAL_CLAUDE" claude v:.0)" "claude:2.1.301"
ok "cerrada: captura REAL de codex -> codex:0.162.1" "$(ver_file "$REAL_CODEX" codex v:.1)" "codex:0.162.1"
ok "cerrada: la captura real de un CLI con la forma del OTRO -> rc 1" \
  "$(ver_file "$REAL_CLAUDE" codex v:.1 >/dev/null 2>&1; echo $?)/$(ver_file "$REAL_CODEX" claude v:.0 >/dev/null 2>&1; echo $?)" "1/1"

# Casos ANTERIORES (extracción k3/k5), cada uno con su veredicto bajo la gramática cerrada.
ok "versión: «2.1.302 (Claude Code)» -> claude:2.1.302" "$(ver_case '2.1.302 (Claude Code)\n' claude v:.0)" "claude:2.1.302"
ok "versión: «codex-cli 0.125.0» -> codex:0.125.0" "$(ver_case 'codex-cli 0.125.0\n' codex v:.1)" "codex:0.125.0"
# Antes «salida solo numérica -> sin cambio»: el triple pelado no tiene la forma de ningún CLI.
ok "versión: salida solo numérica «2.1.289» -> rc 1 (sin la forma del CLI)" "$(ver_case '2.1.289\n' claude v:.0 >/dev/null 2>&1; echo $?)" 1
# Antes «primera aparición cuando hay varias líneas»: la salida es UNA línea; dos líneas nunca valen.
ok "versión: varias líneas «Claude Code 2.1.302 / node 24.1.0» -> rc 1" "$(ver_case 'Claude Code 2.1.302\nnode 24.1.0\n' claude v:.0 >/dev/null 2>&1; echo $?)" 1
ok "versión: sin x.y.z -> rc 1" "$(ver_case 'sin version\n' claude v:.0 >/dev/null 2>&1; echo $?)" 1
ok "versión: salida vacía -> rc 1" "$(ver_case '' claude v:.0 >/dev/null 2>&1; echo $?)" 1
# Antes «build 42 versión 2.1.302 -> claude:2.1.302»: el prefijo ya no se salta (rc 1, aceptado en la decisión).
ok "versión: prefijo «build 42 versión 2.1.302» -> rc 1" "$(ver_case 'build 42 versión 2.1.302\n' claude v:.0 >/dev/null 2>&1; echo $?)" 1
# Antes «2.1.302 y 12.34.56 -> la primera»: no se busca ningún triple dentro de un texto libre.
ok "versión: «2.1.302 y 12.34.56» -> rc 1" "$(ver_case '2.1.302 y 12.34.56\n' claude v:.0 >/dev/null 2>&1; echo $?)" 1
# Antes «dos dígitos por componente» con el triple pelado: se reescribe con la forma real; el pelado da rc 1.
ok "versión: dos dígitos por componente «12.34.56 (Claude Code)» -> claude:12.34.56" "$(ver_case '12.34.56 (Claude Code)\n' claude v:.0)" "claude:12.34.56"
ok "versión: «12.34.56» pelado -> rc 1" "$(ver_case '12.34.56\n' claude v:.0 >/dev/null 2>&1; echo $?)" 1
# Una versión con sufijo pegado NUNCA casa: se rechaza, no se recorta (sin forma y con forma).
ok "versión: sufijo «2.1.302-beta» -> rc 1 (no se recorta a la estable)" "$(ver_case '2.1.302-beta\n' claude v:.0 >/dev/null 2>&1; echo $?)" 1
ok "versión: sufijo «2.1.302+build5» -> rc 1" "$(ver_case '2.1.302+build5\n' claude v:.0 >/dev/null 2>&1; echo $?)" 1
ok "versión: sufijo «2.1.302rc1» -> rc 1" "$(ver_case '2.1.302rc1\n' claude v:.0 >/dev/null 2>&1; echo $?)" 1
ok "versión: cuarto componente «2.1.302.4» -> rc 1" "$(ver_case '2.1.302.4\n' claude v:.0 >/dev/null 2>&1; echo $?)" 1
ok "versión: con sufijo no imprime nada (ni la estable recortada)" "$(ver_case '2.1.302-beta (Claude Code)\n' claude v:.0 2>/dev/null)" ""
# Antes «claude:2.1.302(ClaudeCode) -> claude:2.1.302»: no es la forma exacta del CLI.
ok "versión: «claude:2.1.302(ClaudeCode)» -> rc 1" "$(ver_case 'claude:2.1.302(ClaudeCode)\n' claude v:.0 >/dev/null 2>&1; echo $?)" 1
ok "versión: parcial «2.1» -> rc 1" "$(ver_case '2.1\n' claude v:.0 >/dev/null 2>&1; echo $?)" 1
ok "versión: partida por un espacio «2.1. 302» -> rc 1" "$(ver_case '2.1. 302\n' claude v:.0 >/dev/null 2>&1; echo $?)" 1
ok "versión: número suelto sin x.y.z «build 42» -> rc 1" "$(ver_case 'build 42\n' claude v:.0 >/dev/null 2>&1; echo $?)" 1
ok "versión: nunca devuelve paréntesis ni espacios" \
  "$(ver_case '2.1.302 (Claude Code)\n' claude v:.0 | grep -c '[( ]')" 0
# El override del operador se ejecuta TAL CUAL en el canal y su salida pasa por la MISMA gramática cerrada: la del CLI del
# pane (ya no tiene forma propia x.y.z). F7 lo define como el binario con --version, sin tubería.
: > "$TMP_TEST/remoto"
ok "versión: override «claude --version» con la salida real -> claude:2.1.301" \
  "$(TCO_PANE_CLI_VERSION_CMD='claude --version' ver_file "$REAL_CLAUDE" claude v:.0)" "claude:2.1.301"
ok "versión: el override viaja como orden remota" "$(grep -cxF 'claude --version' "$TMP_TEST/remoto")" 1
ok "versión: override que entrega «2.1.302-beta (Claude Code)» -> rc 1 (F7)" \
  "$(TCO_PANE_CLI_VERSION_CMD='claude --version' ver_case '2.1.302-beta (Claude Code)\n' claude v:.0 >/dev/null 2>&1; echo $?)" 1
ok "versión: override «codex --version» con la salida real -> codex:0.162.1" \
  "$(TCO_PANE_CLI_VERSION_CMD='codex --version' ver_file "$REAL_CODEX" codex v:.1)" "codex:0.162.1"
# Dobles de pane-identity-regressions.py (modos capture_node y capture_interpreter) con su forma real, y sus NEGATIVAS:
# el mismo doble sin \n (como era «printf 2.1.288») o sin la forma del CLI da rc 1.
ok "doble identidad (dev): «2.1.288 (Claude Code)\n» -> claude:2.1.288" \
  "$(TCO_PANE_CLI_VERSION_CMD='printf "2.1.288 (Claude Code)\n"' ver_case '2.1.288 (Claude Code)\n' claude v:.0)" "claude:2.1.288"
for salida in '2.1.288' '2.1.288\n' '2.1.288 (Claude Code)'; do
  ok "doble identidad (dev) NEGATIVA: «$salida» -> rc 1" \
    "$(TCO_PANE_CLI_VERSION_CMD='printf 2.1.288' ver_case "$salida" claude v:.0 >/dev/null 2>&1; echo $?)" 1
done
ok "doble identidad (auditor): «codex-cli 0.1.0\n» -> codex:0.1.0" \
  "$(TCO_PANE_CLI_VERSION_CMD='printf "codex-cli 0.1.0\n"' ver_case 'codex-cli 0.1.0\n' codex v:.1)" "codex:0.1.0"
for salida in '0.1.0' '0.1.0\n' 'codex-cli 0.1.0'; do
  ok "doble identidad (auditor) NEGATIVA: «$salida» -> rc 1" \
    "$(TCO_PANE_CLI_VERSION_CMD='printf 0.1.0' ver_case "$salida" codex v:.1 >/dev/null 2>&1; echo $?)" 1
done

# ---- Los dos sentidos de la frontera estable/sufijo, de punta a punta con la validación REAL (antes del doble de la versión) ----
# Sentido 1: el CLI responde «2.1.302-beta (Claude Code)» y el registro tiene la estable «claude:2.1.302» -> el preflight falla.
# Sentido 2: el CLI responde «2.1.302 (Claude Code)» y el registro tiene «claude:2.1.302-beta» -> tampoco pasa.
# Control positivo: «2.1.302 (Claude Code)» contra «claude:2.1.302» pasa (si no, los rojos de arriba no probarían nada).
# Ley del lead (7-nov): el desarrollo (pane .0) es Claude y el auditor (pane .1) es siempre Codex. El CLI bajo prueba ocupa su pane y
# el OTRO pane responde con su captura real buena y está calibrado, así que solo falla el CLI bajo prueba.
pf_real() ( # salida-del-cli(claude) registro(claude)
  FAKE_VER="$1"; TCO_DEV_CLI=claude; TCO_AUDIT_CLI=codex; TCO_TMUX=v; TCO_PANE_CALIBRATED="$2|codex:0.162.1"
  OTHER_BIN=codex; OTHER_FILE="$REAL_CODEX"
  export TMPDIR="$TMP_TEST/tmp"
  _tco_pane_agent_exes() { tco_cli_exe "$3"; }
  : > "$TMP_TEST/remoto"
  tco_pane_calibration_preflight 01 >/dev/null 2> "$TMP_TEST/err-real"
)
pf_file() ( # fichero-con-la-salida cli registro: el cli ocupa su pane (claude = .0, codex = .1); el otro pane va bien
  FAKE_FILE="$1"; AGENTE="$2"; TCO_DEV_CLI=claude; TCO_AUDIT_CLI=codex; TCO_TMUX=v
  if [ "$2" = claude ]; then TCO_PANE_CALIBRATED="$3|codex:0.162.1"; OTHER_BIN=codex; OTHER_FILE="$REAL_CODEX"
  else TCO_PANE_CALIBRATED="claude:2.1.301|$3"; OTHER_BIN=claude; OTHER_FILE="$REAL_CLAUDE"; fi
  export TMPDIR="$TMP_TEST/tmp"
  _tco_pane_agent_exes() { tco_cli_exe "$3"; }
  : > "$TMP_TEST/remoto"
  tco_pane_calibration_preflight 01 >/dev/null 2> "$TMP_TEST/err-real"
)
rc=0; pf_real '2.1.302 (Claude Code)\n' 'claude:2.1.302' || rc=$?
ok "frontera: control positivo «2.1.302 (Claude Code)» contra «claude:2.1.302» -> rc 0" "$rc" 0
rc=0; pf_real '2.1.302-beta (Claude Code)\n' 'claude:2.1.302' || rc=$?
ok "frontera sentido 1: CLI «2.1.302-beta (Claude Code)» contra el registro estable -> el preflight falla (rc 1)" "$rc" 1
ok "frontera sentido 1: no pude resolver CLI:versión, sin teclas (ninguna orden remota salvo --version)" \
  "$(grep -c 'no pude resolver' "$TMP_TEST/err-real")/$(grep -c 'send-keys' "$TMP_TEST/remoto")/$(grep -vc -- '--version' "$TMP_TEST/remoto")" "1/0/0"
rc=0; pf_real '2.1.302 (Claude Code)\n' 'claude:2.1.302-beta' || rc=$?
ok "frontera sentido 2: CLI estable «2.1.302 (Claude Code)» contra el registro «claude:2.1.302-beta» -> el preflight falla (rc 1)" "$rc" 1
ok "frontera sentido 2: el mensaje es «sin calibrar» y no se teclea nada" \
  "$(grep -c 'claude:2.1.302 sin calibrar' "$TMP_TEST/err-real")/$(grep -c 'send-keys' "$TMP_TEST/remoto")" "1/0"
rc=0; TCO_PANE_CALIBRATED='claude:2.1.302-beta' tco_pane_calibrated 'claude:2.1.302' >/dev/null 2>&1 || rc=$?
ok "frontera sentido 2: tco_pane_calibrated «claude:2.1.302» contra «claude:2.1.302-beta» -> rc 1" "$rc" 1
rc=0; TCO_PANE_CALIBRATED='claude:2.1.302' tco_pane_calibrated 'claude:2.1.302-beta' >/dev/null 2>&1 || rc=$?
ok "frontera: tco_pane_calibrated «claude:2.1.302-beta» contra «claude:2.1.302» -> rc 1" "$rc" 1

# ---- Negativos de k3/k5 (lista negra y lista blanca de terminadores), conservados: siguen en rc 1 bajo la gramática cerrada ----
# Cada salida se prueba pelada y con la forma del CLI detrás («<salida> (Claude Code)»): ningún carácter pegado al triple, ni
# delante ni detrás, deja una forma válida. El preflight contra el registro estable «claude:2.1.302» falla sin teclear.
# Las salidas pasan por printf %b: \033 es ESC y \xHH un byte (U+2010 = \xe2\x80\x90, β = \xce\xb2).
for salida in '2.1.302-beta' '2.1.302+build5' '2.1.302rc1' '2.1.302.4' \
  '2.1.302~rc1' '2.1.302_beta' '2.1.302\033[0m-beta' '2.1.302\xe2\x80\x90beta' '2.1.302\xce\xb2' \
  '2.1.302/1' '2.1.302:1' '2.1.302@x' '2.1.302\r' '12.2.1.302' '.2.1.302' '2.1.302-beta 2.1.302'; do
  out="$(ver_case "$salida\n" claude v:.0 2>/dev/null)"; rc=$?
  ok "k3/k5: «$salida» -> rc 1 y sin salida (extracción)" "$rc:$out" "1:"
  out="$(ver_case "$salida (Claude Code)\n" claude v:.0 2>/dev/null)"; rc=$?
  ok "k3/k5: «$salida (Claude Code)» -> rc 1 y sin salida (extracción)" "$rc:$out" "1:"
  rc=0; pf_real "$salida (Claude Code)\n" 'claude:2.1.302' || rc=$?
  ok "k3/k5: «$salida (Claude Code)» contra «claude:2.1.302» -> el preflight falla y no teclea (ninguna orden remota salvo --version)" \
    "$([ "$rc" -ne 0 ] && echo falla || echo pasa)/$(grep -c 'send-keys' "$TMP_TEST/remoto")/$(grep -vc -- '--version' "$TMP_TEST/remoto")" "falla/0/0"
done
# Antes POSITIVOS de la lista blanca (ANSI alrededor, tabulador, coma, «)» y fin sin salto de línea): ninguno es la forma exacta
# del CLI, así que pasan a rc 1. El ANSI ya no se quita: un byte de control en la salida de --version es una salida distinta.
ok "k5 antes positivo: «\033[1m2.1.302\033[0m (Claude Code)» -> rc 1" \
  "$(ver_case '\033[1m2.1.302\033[0m (Claude Code)\n' claude v:.0 >/dev/null 2>&1; echo $?)" 1
rc=0; pf_real '\033[1m2.1.302\033[0m (Claude Code)\n' 'claude:2.1.302' || rc=$?
ok "k5 antes positivo: «\033[1m2.1.302\033[0m (Claude Code)» contra «claude:2.1.302» -> el preflight falla" "$rc" 1
ok "k5 antes positivo: tabulador «2.1.302\t(Claude Code)» -> rc 1" "$(ver_case '2.1.302\t(Claude Code)\n' claude v:.0 >/dev/null 2>&1; echo $?)" 1
ok "k5 antes positivo: coma «v2.1.302, build 7» -> rc 1" "$(ver_case 'v2.1.302, build 7\n' claude v:.0 >/dev/null 2>&1; echo $?)" 1
ok "k5 antes positivo: «(2.1.302)» -> rc 1" "$(ver_case '(2.1.302)\n' claude v:.0 >/dev/null 2>&1; echo $?)" 1
ok "k5 antes positivo: sin salto de línea final «2.1.302 (Claude Code)» -> rc 1" "$(ver_case '2.1.302 (Claude Code)' claude v:.0 >/dev/null 2>&1; echo $?)" 1

# ---- Negativos PERMANENTES sobre las capturas REALES: extracción y preflight de punta a punta ----
# Cada caso se construye con los bytes de la captura real (fixtures/version) más la alteración; NUL de verdad en el fichero
# (bash los perdería en «$(…)»: por eso la función valida el FICHERO). Extracción: rc 1, nada en stdout y un mensaje con el CLI,
# la forma esperada y lo que llegó escapado. Preflight contra el par real: falla, 0 send-keys, ninguna orden salvo --version.
IFS= read -r LINEA_CLAUDE < "$REAL_CLAUDE"; IFS= read -r LINEA_CODEX < "$REAL_CODEX"
caso() { # nombre fichero-real pos inserto-%b [sin-salto] -> ruta del caso
  local f="$TMP_TEST/caso-$1" l
  IFS= read -r l < "$2"
  { printf '%s' "${l:0:$3}"; printf '%b' "$4"; printf '%s' "${l:$3}"; [ "${5:-}" = sin-salto ] || printf '\n'; } > "$f"
  printf '%s' "$f"
}
neg_case() { # etiqueta cli fichero registro
  local out rc forma
  forma="$(forma_de "$2")"
  out="$(ver_file "$3" "$2" v:.0 2> "$TMP_TEST/neg.err")"; rc=$?
  ok "cerrada: $1 -> extracción rc 1 y sin salida" "$rc:$out" "1:"
  ok "cerrada: $1 -> el mensaje nombra el CLI, la forma esperada y lo que llegó" \
    "$(grep -cF -- "'$2'" "$TMP_TEST/neg.err")/$(grep -cF -- "$forma" "$TMP_TEST/neg.err")/$(grep -c 'llegaron' "$TMP_TEST/neg.err")" "1/1/1"
  rc=0; pf_file "$3" "$2" "$4" || rc=$?
  ok "cerrada: $1 contra «$4» -> el preflight falla y no teclea" \
    "$([ "$rc" -ne 0 ] && echo falla || echo pasa)/$(grep -c 'no pude resolver' "$TMP_TEST/err-real")/$(grep -c 'send-keys' "$TMP_TEST/remoto")/$(grep -vc -- '--version' "$TMP_TEST/remoto")" "falla/1/0/0"
}
rc=0; pf_file "$REAL_CLAUDE" claude 'claude:2.1.301' || rc=$?
ok "cerrada: control positivo — captura real de claude contra «claude:2.1.301» -> el preflight pasa" "$rc" 0
rc=0; pf_file "$REAL_CODEX" codex 'codex:0.162.1' || rc=$?
ok "cerrada: control positivo — captura real de codex contra «codex:0.162.1» -> el preflight pasa" "$rc" 0
N1="$(caso nul-detras "$REAL_CLAUDE" 7 '\x00')"; N2="$(caso nul-dentro "$REAL_CLAUDE" 4 '\x00')"
N3="$(caso nul-final "$REAL_CLAUDE" "${#LINEA_CLAUDE}" '\x00')"
ok "cerrada: los tres casos NUL llevan el byte 00 de verdad (od)" \
  "$(od -An -tx1 "$N1" | grep -c ' 00')/$(od -An -tx1 "$N2" | grep -c ' 00')/$(od -An -tx1 "$N3" | grep -c ' 00')" "1/1/1"
neg_case "NUL detrás del triple «2.1.301\\x00 (Claude Code)»" claude "$N1" 'claude:2.1.301'
ok "cerrada: el mensaje del NUL lo muestra escapado (\\0), sin teclearlo" "$(grep -cF '\0' "$TMP_TEST/neg.err")" 1
neg_case "NUL dentro del triple «2.1.\\x00301 (Claude Code)»" claude "$N2" 'claude:2.1.301'
neg_case "NUL al final «… (Claude Code)\\x00»" claude "$N3" 'claude:2.1.301'
neg_case "retorno de carro «… (Claude Code)\\r\\n»" claude "$(caso cr "$REAL_CLAUDE" "${#LINEA_CLAUDE}" '\r')" 'claude:2.1.301'
neg_case "ANSI («\\033[1m» delante del triple)" claude "$(caso ansi "$REAL_CLAUDE" 0 '\033[1m')" 'claude:2.1.301'
neg_case "dos líneas (la real dos veces)" claude "$(caso dos-lineas "$REAL_CLAUDE" "${#LINEA_CLAUDE}" "\\n$LINEA_CLAUDE")" 'claude:2.1.301'
neg_case "sin \\n final" claude "$(caso sin-salto "$REAL_CLAUDE" 0 '' sin-salto)" 'claude:2.1.301'
neg_case "sufijo «2.1.301-beta (Claude Code)»" claude "$(caso sufijo "$REAL_CLAUDE" 7 '-beta')" 'claude:2.1.301'
neg_case "espacio doble «2.1.301  (Claude Code)»" claude "$(caso doble-espacio "$REAL_CLAUDE" 7 ' ')" 'claude:2.1.301'
neg_case "prefijo «build 42 versión 2.1.301 (Claude Code)» (rc 1 aceptado)" claude "$(caso prefijo "$REAL_CLAUDE" 0 'build 42 versi\xc3\xb3n ')" 'claude:2.1.301'
neg_case "codex: NUL detrás «codex-cli 0.162.1\\x00»" codex "$(caso cx-nul-detras "$REAL_CODEX" "${#LINEA_CODEX}" '\x00')" 'codex:0.162.1'
neg_case "codex: NUL dentro «codex-cli 0.\\x00162.1»" codex "$(caso cx-nul-dentro "$REAL_CODEX" 12 '\x00')" 'codex:0.162.1'
neg_case "codex: NUL delante del triple «codex-cli \\x000.162.1»" codex "$(caso cx-nul-delante "$REAL_CODEX" 10 '\x00')" 'codex:0.162.1'
neg_case "codex: retorno de carro" codex "$(caso cx-cr "$REAL_CODEX" "${#LINEA_CODEX}" '\r')" 'codex:0.162.1'
neg_case "codex: ANSI" codex "$(caso cx-ansi "$REAL_CODEX" 10 '\033[1m')" 'codex:0.162.1'
neg_case "codex: dos líneas" codex "$(caso cx-dos-lineas "$REAL_CODEX" "${#LINEA_CODEX}" "\\n$LINEA_CODEX")" 'codex:0.162.1'
neg_case "codex: sin \\n final" codex "$(caso cx-sin-salto "$REAL_CODEX" 0 '' sin-salto)" 'codex:0.162.1'
neg_case "codex: sufijo «codex-cli 0.162.1-alpha.2»" codex "$(caso cx-sufijo "$REAL_CODEX" "${#LINEA_CODEX}" '-alpha.2')" 'codex:0.162.1'
neg_case "codex: espacio doble «codex-cli  0.162.1»" codex "$(caso cx-doble-espacio "$REAL_CODEX" 9 ' ')" 'codex:0.162.1'
neg_case "codex: prefijo «build 42 codex-cli 0.162.1»" codex "$(caso cx-prefijo "$REAL_CODEX" 0 'build 42 ')" 'codex:0.162.1'
# El mensaje enseña lo recibido ACOTADO: de 200 bytes, como mucho 80.
printf 'Z%.0s' {1..200} > "$TMP_TEST/caso-largo"; printf '\n' >> "$TMP_TEST/caso-largo"
ver_file "$TMP_TEST/caso-largo" claude v:.0 >/dev/null 2> "$TMP_TEST/largo.err"
ok "cerrada: el mensaje enseña como mucho 80 bytes de lo recibido" \
  "$(n="$(tr -cd Z < "$TMP_TEST/largo.err" | wc -c)"; [ "$n" -ge 1 ] && [ "$n" -le 80 ] && echo acotado || echo "n=$n")" acotado

# ---- Barrido GENERADO de los 256 bytes en tres posiciones (delante, dentro y detrás del triple) sobre las capturas reales ----
# Oráculo: un dígito insertado junto a otro dígito forma OTRA versión válida (se lee esa, nunca la real); cualquier otro byte da
# rc 1, sin salida y con mensaje. El preflight contra el par REAL falla en los 256 (otra versión o ninguna) y no teclea nada.
barrido() { # cli fichero-real registro inicio-del-triple etiqueta:pos...
  local cli="$1" real="$2" reg="$3" t0="$4" linea triple et pos n k esc f want got rc mal_ext mal_pf lista
  shift 4
  IFS= read -r linea < "$real"; triple="${linea:$t0}"; triple="${triple%% *}"
  for et in "$@"; do
    pos="${et#*:}"; k=$((pos - t0)); mal_ext=0; mal_pf=0; lista=""
    for ((n=0; n<256; n++)); do
      printf -v esc '\\x%02x' "$n"
      f="$TMP_TEST/barrido"
      { printf '%s' "${linea:0:$pos}"; printf '%b' "$esc"; printf '%s\n' "${linea:$pos}"; } > "$f"
      want=""; [ "$n" -ge 48 ] && [ "$n" -le 57 ] && want="$cli:${triple:0:$k}$((n - 48))${triple:$k}"
      got="$(ver_file "$f" "$cli" v:.0 2> "$TMP_TEST/barrido.err")"; rc=$?
      if [ -n "$want" ]; then
        [ "$rc:$got" = "0:$want" ] || { mal_ext=$((mal_ext+1)); lista="$lista $n"; }
      elif [ "$rc:$got" != "1:" ] || ! grep -qF -- "'$cli'" "$TMP_TEST/barrido.err" || ! grep -q 'llegaron' "$TMP_TEST/barrido.err"; then
        mal_ext=$((mal_ext+1)); lista="$lista $n"
      fi
      rc=0; pf_file "$f" "$cli" "$reg" || rc=$?
      if [ "$rc" -eq 0 ] || grep -q 'send-keys' "$TMP_TEST/remoto" || grep -vq -- '--version' "$TMP_TEST/remoto"; then
        mal_pf=$((mal_pf+1)); lista="$lista pf$n"
      fi
    done
    [ -z "$lista" ] || printf 'barrido %s %s: bytes discrepantes:%s\n' "$cli" "${et%%:*}" "$lista"
    ok "barrido $cli ${et%%:*} (pos $pos): 256 bytes; solo un dígito da otra versión, el resto rc 1 con mensaje" "$mal_ext" 0
    ok "barrido $cli ${et%%:*} (pos $pos): el preflight contra «$reg» falla en los 256 y no teclea" "$mal_pf" 0
  done
}
barrido claude "$REAL_CLAUDE" 'claude:2.1.301' 0 delante:0 dentro:4 detras:7
barrido codex "$REAL_CODEX" 'codex:0.162.1' 10 delante:10 dentro:12 detras:17
ok "cerrada: la función no deja ficheros temporales" "$(find "$TMP_TEST/tmp" -type f | wc -l | tr -d ' ')" 0
ok "cerrada: LC_ALL=C solo dentro de la función (el llamador sin LC_ALL sigue sin él)" \
  "$( unset LC_ALL; FAKE_FILE="$REAL_CLAUDE"; TCO_DEV_CLI=claude; TCO_AUDIT_CLI=codex; TCO_TMUX=v
      _tco_pane_agent_exes() { printf 'claude\n'; }
      _tco_pane_cli_version 01 v:.0 >/dev/null 2>&1; printf '%s' "${LC_ALL-sin}")" sin

# ---- UN solo sitio de formas: references/formas-version.tsv; ni lib.sh ni fases.py llevan formas literales propias ----
FASES="$HERE/../../../instalacion/scripts/fases.py"
literales() { grep -cF -e '(Claude Code' -e 'Claude Code)' -e 'codex-cli' "$1"; }
ok "formas: el fichero de formas tiene exactamente claude y codex, cada una ERE anclada ^…$" \
  "$(cut -f1 "$FORMAS" | tr '\n' ' ')/$(grep -cE $'^[a-z]+\t\\^[^\t]*\\$$' "$FORMAS")/$(wc -l < "$FORMAS" | tr -d ' ')" "claude codex /2/2"
ok "formas: control — el check SÍ ve las formas literales (en el propio fichero de formas)" \
  "$([ "$(literales "$FORMAS")" -ge 2 ] && echo las-ve || echo ciego)" las-ve
ok "formas: lib.sh no tiene formas literales propias («(Claude Code», «Claude Code)», «codex-cli»)" "$(literales "${TCO_PREFLIGHT_LIB:-$SC/lib.sh}")" 0
ok "formas: fases.py no tiene formas literales propias («(Claude Code», «Claude Code)», «codex-cli»)" "$(literales "$FASES")" 0
ok "formas: lib.sh y fases.py leen el MISMO fichero de formas" \
  "$([ "$(grep -c 'references/formas-version.tsv' "${TCO_PREFLIGHT_LIB:-$SC/lib.sh}")" -ge 1 ] && [ "$(grep -c 'references/formas-version.tsv' "$FASES")" -ge 1 ] && echo si || echo no)" si
ok "formas: el lector de lib.sh da la forma del fichero" "$(_tco_cli_version_forma claude 2>/dev/null)/$(_tco_cli_version_forma codex 2>/dev/null)" "$(forma_de claude)/$(forma_de codex)"
ok "formas: un CLI sin forma -> rc 1 con mensaje que lo nombra" \
  "$(_tco_cli_version_forma otro-cli >/dev/null 2> "$TMP_TEST/forma.err"; echo $?)/$(grep -c 'otro-cli' "$TMP_TEST/forma.err")" "1/1"

# ---- tco_pane_calibration_preflight: error claro y temprano ante un CLI sin calibrar ----
# Doble de la versión por pane (el .0 y el .1 pueden ser CLI distintos).
VER_DEV='claude:2.1.302'; VER_AUD='codex:0.125.0'
_tco_pane_cli_version() {
  case "$2" in
    *.0) [ -n "$VER_DEV" ] && printf '%s' "$VER_DEV";;
    *.1) [ -n "$VER_AUD" ] && printf '%s' "$VER_AUD";;
  esac
}
TCO_TMUX=v
pf() { # registro -> rc; el mensaje queda en $TMP_TEST/err
  TCO_PANE_CALIBRATED="$1" tco_pane_calibration_preflight 01 >/dev/null 2> "$TMP_TEST/err"
}
rc=0; pf 'claude:2.1.302|codex:0.125.0' || rc=$?
ok "preflight: ambos panes calibrados -> rc 0" "$rc" 0
ok "preflight: calibrado no escribe error" "$(wc -c < "$TMP_TEST/err" | tr -d ' ')" 0
rc=0; pf 'codex:0.125.0' || rc=$?
ok "preflight: dev sin calibrar -> rc 1" "$rc" 1
ok "preflight: el mensaje nombra CLI y versión" "$(grep -c 'claude:2.1.302 sin calibrar' "$TMP_TEST/err")" 1
ok "preflight: el mensaje nombra el pane" "$(grep -c 'v:.0' "$TMP_TEST/err")" 1
ok "preflight: el mensaje da el remedio" "$(grep -c 'f8-capturas.sh' "$TMP_TEST/err")/$(grep -c 'calibrar-pane.sh --registrar' "$TMP_TEST/err")" "1/1"
ok "preflight: el mensaje avisa que no se teclea nada" "$(grep -c 'no se teclea nada' "$TMP_TEST/err")" 1
rc=0; pf 'claude:2.1.302' || rc=$?
ok "preflight: auditor sin calibrar -> rc 1" "$rc" 1
ok "preflight: el mensaje nombra el CLI del auditor" "$(grep -c 'codex:0.125.0 sin calibrar' "$TMP_TEST/err")/$(grep -c 'v:.1' "$TMP_TEST/err")" "1/1"
rc=0; pf '' || rc=$?
ok "preflight: registro vacío -> rc 1" "$rc" 1
# Un registro de otra versión, de otro CLI o con prefijo común NO acredita el par.
for registro in 'claude:2.1.289' 'claude:2.1.3020|codex:0.125.0' 'claude:2.1.30|codex:0.125.0' 'xclaude:2.1.302|codex:0.125.0' 'codex:2.1.302|codex:0.125.0'; do
  rc=0; pf "$registro" || rc=$?
  ok "preflight: «$registro» no acredita claude:2.1.302" "$rc" 1
done
VER_DEV=''
rc=0; pf 'claude:2.1.302|codex:0.125.0' || rc=$?
ok "preflight: versión no resoluble -> rc 1" "$rc" 1
ok "preflight: versión no resoluble tiene su propio mensaje" "$(grep -c 'no pude resolver' "$TMP_TEST/err")/$(grep -c 'sin calibrar' "$TMP_TEST/err")" "1/0"
VER_DEV='claude:2.1.302'

# ---- Cableado en dispatch.sh: una sola llamada, común a normal y --soft, tras la identidad y ANTES de cualquier tecleo ----
D="$SC/dispatch.sh"
CAL_LINE="$(grep -n '^  tco_pane_calibration_preflight "\$CARRIL" \\$' "$D" | head -1 | cut -d: -f1)"
ID_LINE="$(grep -n '^  tco_pane_identity_preflight "\$CARRIL" \\$' "$D" | head -1 | cut -d: -f1)"
GATE_LINE="$(grep -n 'tco_ensure_model "\$CARRIL" "\$P_DEV" "\$DEV_MODEL"' "$D" | head -1 | cut -d: -f1)"
BRIEF_LINE="$(grep -n 'tco_relay_file "\$CARRIL" "\$P_DEV" "\$tmp/dev-prompt.txt"' "$D" | head -1 | cut -d: -f1)"
ok "dispatch.sh: una sola llamada al preflight de calibración, a nivel superior (normal y --soft)" \
  "$(grep -c 'tco_pane_calibration_preflight "\$CARRIL"' "$D")/${CAL_LINE:+si}" "1/si"
ok "dispatch.sh: la calibración va DESPUÉS de la identidad y ANTES del gate de modelo y del brief" \
  "$([ -n "$CAL_LINE" ] && [ -n "$ID_LINE" ] && [ -n "$GATE_LINE" ] && [ -n "$BRIEF_LINE" ] && [ "$ID_LINE" -lt "$CAL_LINE" ] && [ "$CAL_LINE" -lt "$GATE_LINE" ] && [ "$GATE_LINE" -lt "$BRIEF_LINE" ] && echo si || echo no)" si
# Hasta la llamada, el despacho no teclea nada en los panes: ningún envío de texto o teclas antes de la comprobación.
ok "dispatch.sh: antes del preflight no hay ningún envío de texto al pane (_tco_send_text_submit, send-keys, tco_set_model, relay)" \
  "$(head -n "${CAL_LINE:-0}" "$D" | grep -v '^[[:space:]]*#' | grep -cE '_tco_send_text_submit|send-keys|tco_set_model|tco_set_effort|tco_relay_file|tco_send_dialog_choice')" 0
# Las LÍNEAS REALES de dispatch.sh con un preflight que falla: MUERE; con uno que pasa: SIGUE.
CAL_SNIP="$(sed -n "${CAL_LINE:-1},$((${CAL_LINE:-1}+1))p" "$D" | sed 's/\\$//' | tr '\n' ' ')"
CAL_DIE="$( ( CARRIL=01; tco_pane_calibration_preflight() { return 1; }; tco_die() { echo "DIE: $*"; exit 7; }; eval "$CAL_SNIP"; echo SIGUE ) 2>&1 )"
ok "dispatch.sh: CLI sin calibrar (preflight rc 1) -> el despacho MUERE y no sigue" \
  "$(printf '%s' "$CAL_DIE" | grep -c '^DIE: 01: ')/$(printf '%s' "$CAL_DIE" | grep -c SIGUE)" "1/0"
CAL_OK="$( ( CARRIL=01; tco_pane_calibration_preflight() { return 0; }; tco_die() { echo "DIE: $*"; exit 7; }; eval "$CAL_SNIP"; echo SIGUE ) 2>&1 )"
ok "dispatch.sh: CLI calibrado (preflight rc 0) -> el despacho SIGUE" "$CAL_OK" SIGUE
# El preflight real, ejecutado como lo hace el despacho, no emite ni una tecla: el doble de incus registra cualquier orden.
: > "$TMP_TEST/remoto"
(
  CARRIL=01; TCO_PANE_CALIBRATED='codex:0.125.0'
  tco_die() { exit 7; }
  eval "$CAL_SNIP"
) >/dev/null 2>&1
ok "dispatch.sh: con un CLI sin calibrar el preflight no manda ninguna orden al canal" "$(wc -c < "$TMP_TEST/remoto" | tr -d ' ')" 0

# ---- El reciclaje suave (--soft) no teclea NADA antes del preflight: prueba de COMPORTAMIENTO sobre un doble de tmux ----
# El texto de dispatch.sh no delata las llamadas indirectas (tco_recycle_carril --soft envía «/clear» + Enter con
# _tco_send_text_submit). Aquí corre la función REAL con el transporte sustituido: cada send-keys que llega al canal queda
# anotado y el compositor del doble es la captura real 2.1.302 en reposo, que cambia en cuanto llega un send-keys -l.
IDLE302="$HERE/fixtures/pane/claude_2.1.302/idle.txt"
NBSP=$'\xc2\xa0'
soft_case() ( # registro-calibrado -> «rc:send-keys:compositor»
  TCO_PANE_CALIBRATED="$1"; TCO_TMUX=v
  TCO_IDLE_STABILITY_GAP=0; TCO_RELAY_SUBMIT_GAP=0; TCO_RELAY_ECHO_GAP=0
  : > "$TMP_TEST/incus.log"; printf idle > "$TMP_TEST/estado"
  _tco_carril_session() { printf 'sid-neutro idle 2026-01-01T00:00:00Z\n'; }
  _tco_transcript_lines() { :; }
  _tco_pane_cli_version() { printf 'claude:2.1.302'; }
  sleep() { :; }
  incus() {
    printf '%s\n' "$*" >> "$TMP_TEST/incus.log"
    case "$*" in
      *' -l -- '*) printf typed > "$TMP_TEST/estado" ;;
      *' C-m') printf submit > "$TMP_TEST/estado" ;;
      # La lectura de los %N de la sesión (R9011j7 J7-01): una ventana con los dos panes del canal.
      *'#{session_name}'*) printf 'v|@0|0|%%0|1.2\nv|@0|1|%%1|1.2\n' ;;
    esac
    return 0
  }
  tco_cap_pane_e() {
    if [ "$(cat "$TMP_TEST/estado")" = idle ]; then cat "$IDLE302"
    else LC_ALL=C sed "s/❯${NBSP} *\$/❯${NBSP}\/clear/" "$IDLE302"; fi
  }
  tco_cap_pane() { tco_cap_pane_e | tco_strip_ansi_from; }
  local rc=0 original after
  tco_recycle_carril 01 --soft >/dev/null 2>&1 || rc=$?
  original="$(tco_tui_regions_from composer < "$IDLE302")"
  after="$(tco_cap_pane_e | tco_tui_regions_from composer)"
  printf '%s:%s:%s' "$([ "$rc" -eq 0 ] && echo 0 || echo fallo)" "$(grep -c 'send-keys' "$TMP_TEST/incus.log")" \
    "$([ "$after" = "$original" ] && echo intacto || echo alterado)"
)
ok "soft: con el registro vacío el reciclaje falla, hay 0 send-keys y el compositor del doble queda intacto" \
  "$(soft_case '')" "fallo:0:intacto"
ok "soft: con otro CLI calibrado (no el del pane) tampoco teclea nada" \
  "$(soft_case 'codex:0.125.0')" "fallo:0:intacto"
ok "soft: control positivo — con el par calibrado el doble SÍ recibe /clear y Enter (2 send-keys, compositor alterado)" \
  "$(soft_case 'claude:2.1.302')" "0:2:alterado"
RECYCLE_BODY="$(sed -n '/^tco_recycle_carril() {/,/^}/p' "${TCO_PREFLIGHT_LIB:-$SC/lib.sh}")"
ok "soft: el preflight es lo primero del reciclaje suave, antes de esperar reposo y de cualquier envío" \
  "$(printf '%s\n' "$RECYCLE_BODY" | grep -nE 'tco_pane_calibration_preflight|tco_wait_idle|_tco_send_text_submit' | sed -n '1p' | grep -c 'tco_pane_calibration_preflight')" 1

printf 'PASS=%s FAIL=%s TOTAL=%s\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] && [ "$((PASS+FAIL))" -ge 30 ]
