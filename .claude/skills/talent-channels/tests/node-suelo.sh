#!/usr/bin/env bash
# node-suelo.sh — suelo de parche de Node en el golden (issue 9558).
# Extrae por ancla de contenido los fragmentos REALES de 02-golden.sh (el lector del TSV de suelos, en el
# host, y la comprobación de `node -v`, dentro del contenedor) y los ejecuta con un doble de `node -v` en el
# PATH: nunca hay red, ni incus, ni un Node real. La lógica probada es la del script, no una copia paralela.
# Casos del contrato: 24.vulnerable → falla (test negativo permanente del exploit); 24.22.1 → pasa;
# 22.22.3 → falla; 22.23.4 → pasa; 26.12.1 → pasa; mayor 30 sin suelo → falla cerrada. Más los bordes.
# La versión vulnerable de la mayor 24 se COMPONE (no se escribe literal) para que el barrido por esa cita
# en skills/ dé 0 sin quitar el caso.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/../scripts" && pwd)"
ASSETS_REAL="$(cd "$HERE/../assets" && pwd)"
G="$SCRIPTS/02-golden.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1" >&2; }

WORK="$(mktemp -d)"; : "${WORK:?}"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Doble de node: `node -v` imprime v$NODE_FAKE (vacío → no imprime nada).
# shellcheck disable=SC2016  # el guion del doble va literal, sin expandir aquí
printf '%s\n' '#!/bin/sh' \
  'if [ "$1" = "-v" ]; then [ -n "${NODE_FAKE:-}" ] && echo "v${NODE_FAKE}"; exit 0; fi' \
  'exit 1' > "$WORK/bin/node"
chmod +x "$WORK/bin/node"

# Extracción por ancla (no por número de línea).
extrae() { # ancla-ini ancla-fin → líneas ENTRE las dos anclas (sin ellas)
  local a b
  a="$(grep -nxF "$1" "$G" | head -1 | cut -d: -f1)"
  b="$(grep -nxF "$2" "$G" | head -1 | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || return 1
  sed -n "$((a + 1)),$((b - 1))p" "$G"
}
HOST_SNIPPET="$(extrae '# suelos-host:ini' '# suelos-host:fin')" || { echo "anclas del lector de suelos no encontradas en 02-golden.sh" >&2; exit 1; }
CONT_SNIPPET="$(extrae '# suelo:ini' '# suelo:fin')" || { echo "anclas de la comprobación de suelo no encontradas en 02-golden.sh" >&2; exit 1; }

# caso <mayor-pedida> <versión-del-doble> [dir-assets] → rc de la comprobación; stderr/stdout en $WORK/out
caso() {
  local nv="$1" ver="$2" a="${3:-$ASSETS_REAL}"
  (
    # shellcheck disable=SC2034,SC2329  # ASSETS y tc_die los usa el fragmento real, evaluado con eval
    ASSETS="$a"
    # shellcheck disable=SC2329
    tc_die() { echo "tc_die: $*" >&2; exit 1; }
    eval "$HOST_SNIPPET"
    export SUELOS="$NODE_SUELOS" NV="$nv" NODE_FAKE="$ver"
    PATH="$WORK/bin:$PATH"
    bash -ec "$CONT_SNIPPET"
  ) > "$WORK/out" 2>&1
}
espera_rc0()  { # etiqueta mayor versión
  if caso "$2" "$3"; then ok "$1"; else bad "$1 — rc≠0: $(tr '\n' ' ' < "$WORK/out")"; fi
}
espera_falla() { # etiqueta mayor versión patrón-del-mensaje
  if caso "$2" "$3"; then bad "$1 — pasó y debía FALLAR: $(tr '\n' ' ' < "$WORK/out")"
  elif grep -q -- "$4" "$WORK/out"; then ok "$1"
  else bad "$1 — falló pero sin el mensaje esperado ($4): $(tr '\n' ' ' < "$WORK/out")"; fi
}

VULN24="$(printf '%s.%s.%s' 24 20 0)"   # Node 24 afectado por el aviso de seguridad del 21-oct-2026

echo "== node-suelo: los 6 casos del contrato =="
espera_falla "1 Node $VULN24 (24 afectada) → rc≠0 con mensaje claro (test negativo del exploit)" 24 "$VULN24" "por DEBAJO del suelo de parche 24.22.1"
espera_rc0   "2 Node 24.22.1 → rc 0" 24 24.22.1
espera_falla "3 Node 22.22.3 → rc≠0" 22 22.22.3 "por DEBAJO del suelo de parche 22.23.4"
espera_rc0   "4 Node 22.23.4 → rc 0" 22 22.23.4
espera_rc0   "5 Node 26.12.1 → rc 0" 26 26.12.1
espera_falla "6 mayor 30 sin suelo conocido → rc≠0 (falla cerrada)" 30 30.0.0 "no tiene suelo de parche conocido"

echo "== node-suelo: bordes =="
espera_falla "7 24.22.0 (un parche por debajo) → rc≠0" 24 24.22.0 "por DEBAJO"
espera_rc0   "8 24.23.0 (minor superior) → rc 0" 24 24.23.0
espera_rc0   "9 24.22.2 (parche superior) → rc 0" 24 24.22.2
espera_falla "10 24.9.99 (minor menor, comparación numérica y no de texto) → rc≠0" 24 24.9.99 "por DEBAJO"
espera_falla "11 mayor 25 (no es LTS ni tiene suelo) → rc≠0" 25 25.0.0 "no tiene suelo de parche conocido"
espera_falla "12 versión con sufijo (24.22.1-rc.1) → rc≠0, solo vale X.Y.Z puro" 24 24.22.1-rc.1 "no devolvió una versión X.Y.Z"
espera_falla "13 node -v sin salida → rc≠0" 24 "" "no devolvió una versión X.Y.Z"

echo "== node-suelo: el lector de suelos es fail-closed =="
D="$WORK/assets-malos"; mkdir -p "$D"
if caso 24 24.22.1 "$WORK/no-existe"; then bad "14 TSV ausente → debía FALLAR"; elif grep -q 'falta assets/node-suelos.tsv' "$WORK/out"; then ok "14 TSV ausente → tc_die"; else bad "14 TSV ausente sin mensaje esperado"; fi
printf '# solo comentarios\n' > "$D/node-suelos.tsv"
if caso 24 24.22.1 "$D"; then bad "15 TSV sin ningún suelo → debía FALLAR"; elif grep -q 'no define ningún suelo' "$WORK/out"; then ok "15 TSV sin ningún suelo → tc_die"; else bad "15 TSV vacío sin mensaje esperado"; fi
printf '24\t22.23.4\n' > "$D/node-suelos.tsv"
if caso 24 24.22.1 "$D"; then bad "16 fila con suelo de OTRA mayor → debía FALLAR"; elif grep -q 'fila inválida' "$WORK/out"; then ok "16 fila con suelo de otra mayor → tc_die"; else bad "16 fila incoherente sin mensaje esperado"; fi
printf '24\t24.22.1; touch x\n' > "$D/node-suelos.tsv"
if caso 24 24.22.1 "$D"; then bad "17 fila con metacaracteres → debía FALLAR"; elif grep -q 'fila inválida' "$WORK/out"; then ok "17 fila con metacaracteres → tc_die (no llega al shell interno)"; else bad "17 fila con metacaracteres sin mensaje esperado"; fi
printf '# sin tabulador\n24 24.22.1\n' > "$D/node-suelos.tsv"
if caso 24 24.22.1 "$D"; then bad "18 fila sin tabulador → debía FALLAR"; elif grep -q 'fila inválida' "$WORK/out"; then ok "18 fila sin tabulador → tc_die"; else bad "18 fila sin tabulador sin mensaje esperado"; fi

echo "== node-suelo: cableado en 02-golden.sh =="
n_inst="$(grep -nxF 'apt-get install -y -qq nodejs' "$G" | head -1 | cut -d: -f1)"
n_suelo="$(grep -nxF '# suelo:ini' "$G" | head -1 | cut -d: -f1)"
n_ca="$(grep -nxF 'apt-get install -y -qq --only-upgrade ca-certificates' "$G" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # el patrón es el texto literal $RH_NPM de la línea de instalación (issue 9564: pkg@versión del lock, npm aislado)
n_npm="$(grep -n '^npm install -g \$RH_NPM' "$G" | head -1 | cut -d: -f1)"
if [ -n "$n_inst" ] && [ -n "$n_suelo" ] && [ -n "$n_ca" ] && [ -n "$n_npm" ] && [ "$n_inst" -lt "$n_suelo" ] && [ "$n_suelo" -lt "$n_ca" ] && [ "$n_ca" -lt "$n_npm" ]; then
  ok "19 orden: instalar nodejs → comprobar suelo → ca-certificates al día → CLIs npm"
else bad "19 orden de instalar nodejs, comprobar suelo, ca-certificates y CLIs npm (líneas: $n_inst $n_suelo $n_ca $n_npm)"; fi
if sed -n "${n_npm:-1},$((${n_npm:-1} + 1))p" "$G" | grep -qF '|| tc_die'; then ok "20 el paso de Node cae en tc_die del host si el contenedor sale con rc≠0"
else bad "20 el tc_cexec de Node no lleva '|| tc_die'"; fi

echo "================  PASS=$PASS  FAIL=$FAIL  ================"
[ "$FAIL" -eq 0 ]
