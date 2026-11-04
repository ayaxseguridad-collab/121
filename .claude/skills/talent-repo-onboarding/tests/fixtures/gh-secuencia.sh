#!/usr/bin/env bash
# gh-secuencia.sh — doble de `gh` para los casos lectura-estable-* (issue 9011). Ni una llamada real a GitHub.
# Solo acepta `gh api <endpoint>` (GET) sobre los dos endpoints de A2/A2b del repo GH_DOBLE_SLUG; cualquier
# otra orden (p. ej. `--method`) sale con rc 90 y queda en el registro.
#
# Por endpoint (clave `proteccion` o `repo`) sirve una SECUENCIA de fichas, una por línea en
# $GH_DOBLE_DIR/<clave>.seq. Agotada, repite la última; si existe $GH_DOBLE_DIR/<clave>.ciclo, vuelve a
# empezar (alterna sin parar). Fichas: un nombre `<x>` sirve $GH_DOBLE_DIR/<clave>.<x>.json; `pro` y `fallo`
# imitan errores de gh (rc 1); `roto` sirve texto que no es JSON.
# Registro: cada orden en llamadas.log y la cuenta de lecturas por clave en <clave>.n. Freno: más de
# GH_DOBLE_MAX lecturas de una clave (200) sale con rc 92 «bucle sin tope», para que un bucle infinito
# acabe en ROJO y no cuelgue la suite.
set -u
d="${GH_DOBLE_DIR:?GH_DOBLE_DIR sin definir}"
slug="${GH_DOBLE_SLUG:?GH_DOBLE_SLUG sin definir}"
printf '%s\n' "$*" >> "$d/llamadas.log"
if [ "$#" -ne 2 ] || [ "$1" != api ]; then
  printf 'gh doble: orden no permitida: %s\n' "$*" >&2
  exit 90
fi
case "$2" in
  "repos/$slug/branches/main/protection") clave=proteccion ;;
  "repos/$slug") clave=repo ;;
  *) printf 'gh doble: endpoint no previsto: %s\n' "$2" >&2; exit 91 ;;
esac
n=0
[ -f "$d/$clave.n" ] && n="$(cat "$d/$clave.n")"
n=$(( n + 1 ))
printf '%s\n' "$n" > "$d/$clave.n"
if [ "$n" -gt "${GH_DOBLE_MAX:-200}" ]; then
  printf 'gh doble: más de %s lecturas de %s: bucle sin tope\n' "${GH_DOBLE_MAX:-200}" "$clave" >&2
  exit 92
fi
total="$(grep -c '' "$d/$clave.seq")"
if [ "$n" -le "$total" ]; then
  i="$n"
elif [ -f "$d/$clave.ciclo" ]; then
  i=$(( (n - 1) % total + 1 ))
else
  i="$total"
fi
ficha="$(sed -n "${i}p" "$d/$clave.seq")"
case "$ficha" in
  pro)   printf 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)\n' >&2; exit 1 ;;
  fallo) printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1 ;;
  roto)  printf 'esto no es json\n' ;;
  *)     cat -- "$d/$clave.$ficha.json" ;;
esac
