#!/usr/bin/env bash
# check_nucleo_parity.sh — gate de paridad del núcleo (bidireccional, fail-closed)
#
# USO:  bash scripts/check_nucleo_parity.sh
#       Directorio de ejecución: la RAÍZ del skill (el script se re-ancla solo).
#
# Verifica, con exit != 0 ante CUALQUIER deriva:
#   1) Conjunto A (canon): líneas del bloque delimitado
#      <!-- nucleo-clausulas:begin --> ... <!-- nucleo-clausulas:end -->
#      de templates/00-nucleo.md (se excluyen fences ``` y líneas vacías).
#      Delimitadores ausentes -> exit 2.
#   2) Conjunto B (manifest): líneas de templates/nucleo-manifest.txt excluyendo
#      explícitamente comentarios (SOLO "# " o "#" a secas — las cláusulas "## ..."
#      NO son comentarios), líneas vacías y líneas EXCEPT.
#   3) A == B en AMBAS direcciones (una cláusula nueva en el canon sin manifest,
#      o viceversa, es deriva -> exit 1).
#   4) Cada cláusula de B existe literalmente en cada templates/0[1-9]-*.md,
#      salvo excepción declarada como línea exacta:  EXCEPT <basename>:<cláusula>
#
# Ningún hallazgo termina en echo+exit 0: el rc acumula y el script SIEMPRE
# devuelve distinto de cero si hubo cualquier deriva.

set -u
cd "$(dirname "$0")/.." || exit 2

CANON="templates/00-nucleo.md"
MANIFEST="templates/nucleo-manifest.txt"

[ -f "$CANON" ] || { echo "ERROR: no existe $CANON"; exit 2; }
[ -f "$MANIFEST" ] || { echo "ERROR: no existe $MANIFEST"; exit 2; }
grep -q 'nucleo-clausulas:begin' "$CANON" || { echo "ERROR: falta delimitador begin en $CANON"; exit 2; }
grep -q 'nucleo-clausulas:end' "$CANON" || { echo "ERROR: falta delimitador end en $CANON"; exit 2; }

# Conjunto A — canon (entre delimitadores; sin fences ni vacías)
A=$(awk '/nucleo-clausulas:begin/{f=1;next} /nucleo-clausulas:end/{f=0} f' "$CANON" \
  | grep -v '^```' | sed '/^[[:space:]]*$/d' | LC_ALL=C sort -u)

# Conjunto B — manifest (sin comentarios, vacías ni EXCEPT).
# Comentario = "# " o "#" solo; una cláusula "## heading" NO es comentario.
B=$(grep -vE '^#( |$)' "$MANIFEST" | grep -v '^EXCEPT ' | sed '/^[[:space:]]*$/d' | LC_ALL=C sort -u)

rc=0

# 1) Paridad bidireccional canon <-> manifest
if ! DIFF_OUT=$(diff <(printf '%s\n' "$A") <(printf '%s\n' "$B")); then
  echo "DERIVA canon<->manifest (izq=canon, der=manifest):"
  printf '%s\n' "$DIFF_OUT"
  rc=1
fi

# 2) Manifest -> plantillas 01..09 (con regla EXCEPT por basename)
while IFS= read -r c; do
  [ -z "$c" ] && continue
  for f in templates/0[1-9]-*.md; do
    b=$(basename "$f" .md)
    if ! grep -qF -- "$c" "$f"; then
      if ! grep -qxF "EXCEPT $b:$c" "$MANIFEST"; then
        echo "FALTA [$c] EN $f"
        rc=1
      fi
    fi
  done
done <<EOF_B
$B
EOF_B

if [ "$rc" -eq 0 ]; then
  echo "PARIDAD OK: canon == manifest == 9 plantillas (excepciones: solo las declaradas)"
fi
exit "$rc"
