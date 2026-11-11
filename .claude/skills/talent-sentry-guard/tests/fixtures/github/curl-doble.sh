#!/usr/bin/env bash
# Doble de curl para test-doctor-github.sh (nunca abre un socket). El doctor lo invoca como
#   <cliente> -q -s --max-time 5 --noproxy '*' -H @<hdr> -w '\n%{http_code}' <URL>
# Respuestas en $GH_DOBLE_DIR, un fichero por URL: la clave es la ruta tras https://api.github.com/
# con todo carácter no alfanumérico cambiado por «_»; línea 1 = código HTTP, resto = cuerpo.
# URL sin fichero = conexión fallida (exit 7). Cada llamada se anota en llamadas.log.
set -u
: "${GH_DOBLE_DIR:?}"
url="${*: -1}"
printf '%s\n' "$url" >> "$GH_DOBLE_DIR/llamadas.log"
clave="$(printf '%s' "${url#https://api.github.com/}" | tr -c 'A-Za-z0-9' '_')"
f="$GH_DOBLE_DIR/$clave"
[ -f "$f" ] || exit 7
status="$(head -n 1 "$f")"
printf '%s\n%s' "$(tail -n +2 "$f")" "$status"
