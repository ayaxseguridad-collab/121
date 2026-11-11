#!/usr/bin/env bash
# Doble de curl para test-parte-guardia.sh (Management API de Supabase; nunca abre un socket).
# Respuesta en $PARTE_DOBLE_DIR/dinero.respuesta: línea 1 = código HTTP, resto = cuerpo. Sin fichero = exit 7.
# Anota argv y cuerpos enviados (para comprobar read_only y que el token no viaja por argv).
set -u
: "${PARTE_DOBLE_DIR:?}"
printf '%s\n' "$*" >>"$PARTE_DOBLE_DIR/curl-argv.log"
cuerpo=""; previo=""
for a in "$@"; do
  [ "$previo" = "--data-binary" ] && cuerpo="${a#@}"
  previo="$a"
done
[ -z "$cuerpo" ] || { cat -- "$cuerpo"; echo; } >>"$PARTE_DOBLE_DIR/curl-cuerpos.log"
f="$PARTE_DOBLE_DIR/dinero.respuesta"
[ -f "$f" ] || exit 7
printf '%s\n%s' "$(tail -n +2 "$f")" "$(head -n 1 "$f")"
