#!/usr/bin/env bash
# run-tests.sh — Corredor de las pruebas de talent-merger (fila `talent-merger` de scripts/run-all-suites.sh).
#
# Descubre tests/test-*.sh EXCLUYENDO los ids que ya tienen fila propia en el inventario de la batería, leídos de
# `scripts/run-all-suites.sh --listar` (no de una lista a mano): una prueba con fila propia no se ejecuta aquí
# otra vez. Una fila `test-X.sh` cubre también sus compañeras `test-X-*.sh` (la fila las invoca en su comando).
# Exige el EMPAREJADO: cada scripts/X.sh tiene su tests/test-X.sh, salvo las librerías (lib-*.sh y cad-lib.sh),
# que se prueban desde la prueba de su consumidor. Lleva un test NEGATIVO: si un id con fila propia dejara de
# estar excluido, la comprobación de doble ejecución falla.
# Línea final (la que reconoce la batería): RESULTADO: PASS=<n> FAIL=<n>.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SC="$HERE/../scripts"

buscar_arriba() {
  local d="$HERE"
  while :; do
    if [ -f "$d/scripts/run-all-suites.sh" ]; then printf '%s\n' "$d"; return 0; fi
    [ "$d" != / ] || return 1
    d="$(dirname "$d")"
  done
}
RAIZ="$(buscar_arriba)" || { echo "FAIL no encuentro scripts/run-all-suites.sh hacia arriba: inventario ilegible"; exit 2; }

PASS=0; FAIL=0
ok() { # <descripción> <esperado> <obtenido>
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf '  FAIL %s: esperaba [%s] obtuvo [%s]\n' "$1" "$2" "$3"; fi
}

# descubrir <id>... — imprime las pruebas de tests/ que NO tienen fila propia.
descubrir() {
  local f b id skip
  for f in "$HERE"/test-*.sh; do
    [ -f "$f" ] || continue
    b="${f##*/}"; skip=0
    for id in "$@"; do
      case "$b" in "$id" | "${id%.sh}"-*) skip=1 ;; esac
    done
    [ "$skip" = 1 ] || printf '%s\n' "$b"
  done
}

# verificar_sin_doble <id>... -- <descubierta>... — rc 1 si alguna descubierta ya tiene fila propia.
verificar_sin_doble() {
  local ids=() desc=() a d id mal=0 destino=ids
  for a in "$@"; do
    if [ "$a" = -- ]; then destino=desc; continue; fi
    if [ "$destino" = ids ]; then ids+=("$a"); else desc+=("$a"); fi
  done
  for d in "${desc[@]}"; do
    for id in "${ids[@]}"; do
      case "$d" in "$id" | "${id%.sh}"-*) echo "doble ejecución: $d ya corre en la fila $id"; mal=1 ;; esac
    done
  done
  return "$mal"
}

echo "== inventario y descubrimiento =="
lista="$(bash "$RAIZ/scripts/run-all-suites.sh" --listar 2>/dev/null)"; lrc=$?
ok "el inventario se lee de run-all-suites.sh --listar" 0 "$lrc"
IDS=(); while IFS= read -r l; do IDS+=("$l"); done < <(printf '%s\n' "$lista" | grep -E '^test-.*\.sh$' || true)
DESC=(); while IFS= read -r l; do DESC+=("$l"); done < <(descubrir "${IDS[@]}")
TODAS=(); while IFS= read -r l; do TODAS+=("$l"); done < <(descubrir)
ok "hay pruebas propias que correr" 1 "$([ "${#DESC[@]}" -gt 0 ] && echo 1 || echo 0)"
ok "talent-merger tiene su fila en el inventario" 1 "$(printf '%s\n' "$lista" | grep -cx talent-merger || true)"
ok "la fila propia de la prueba del destilador sigue en el inventario" 1 "$(printf '%s\n' "$lista" | grep -cx test-distill-findings.sh || true)"
ok "la prueba del destilador no se descubre aquí" 0 "$(printf '%s\n' "${DESC[@]}" | grep -c '^test-distill-findings' || true)"
ok "sus compañeras tampoco" 0 "$(printf '%s\n' "${DESC[@]}" | grep -c 'mutants' || true)"
verificar_sin_doble "${IDS[@]}" -- "${DESC[@]}" > /dev/null; ok "ningún test corre dos veces" 0 "$?"

echo "== negativo: un id con fila propia que dejara de excluirse =="
neg="$(verificar_sin_doble test-fantasma.sh -- test-fantasma.sh test-fantasma-mutantes.sh test-otra.sh)"; nrc=$?
ok "doble ejecución sintética detectada: rc" 1 "$nrc"
ok "doble ejecución sintética: señala solo las dos" 2 "$(printf '%s\n' "$neg" | grep -c .)"
verificar_sin_doble "${IDS[@]}" -- "${TODAS[@]}" > /dev/null; nrc=$?
ok "sin exclusión, las pruebas con fila propia se detectarían (el ejecutor las repetiría): rc" 1 "$nrc"

echo "== emparejado scripts/X.sh <-> tests/test-X.sh =="
for s in "$SC"/*.sh; do
  b="${s##*/}"
  case "$b" in lib-*.sh | cad-lib.sh) continue ;; esac
  ok "emparejado: $b tiene tests/test-$b" 1 "$([ -f "$HERE/test-$b" ] && echo 1 || echo 0)"
done

echo "== pruebas =="
for t in "${DESC[@]}"; do
  echo "-- $t"
  out="$(env -u TF_SCRIPTS_DIR bash "$HERE/$t" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  res="$(printf '%s\n' "$out" | grep '^RESULTADO: PASS=' | tail -n 1)"
  if [ -z "$res" ] || [ "$rc" -ne 0 ]; then
    FAIL=$((FAIL + 1)); printf '  FAIL %s: rc=%s y %s\n' "$t" "$rc" "${res:-sin línea RESULTADO}"
  fi
  if [ -n "$res" ]; then
    p="${res#RESULTADO: PASS=}"; p="${p%% *}"; f="${res##*FAIL=}"
    PASS=$((PASS + p)); FAIL=$((FAIL + f))
  fi
done

printf 'RESULTADO: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
