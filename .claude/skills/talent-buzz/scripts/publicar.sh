#!/usr/bin/env bash
# buzz-publicar — publica ./respuesta.txt del workdir del agente por STDIN.
#
#   buzz-publicar <uuid-del-canal>
#
# Contrato (ronda de seguridad, B1/M4/M6/M7):
# - El contenido viaja EXCLUSIVAMENTE por stdin (`--content -`): jamas toca
#   argv ni sintaxis de shell — no hay comillas, heredocs ni delimitadores
#   que una respuesta hostil pueda cerrar.
# - Protocolo centinela: montar.sh siembra respuesta.txt con la linea
#   centinela; el agente la sustituye con str_replace (herramienta de
#   archivos, no shell) y ejecuta este helper. Entre siembra y publicacion
#   solo UN turno puede escribir: un segundo str_replace concurrente falla
#   solo (el centinela ya no esta) — sin mezcla de turnos (M4).
# - Recuperacion en TODAS las salidas (M7): el trap de salida SIEMPRE deja un
#   respuesta.txt valido con centinela. Si el envio falla, el payload se
#   conserva aparte con nombre EXCLUSIVO (mktemp) como evidencia autoritativa
#   y el helper sale con rc!=0 — el fallback del patch 01 (rearmado,
#   BEST-EFFORT: solo publica si hubo agent_message_chunk y el relay responde)
#   puede rescatar el turno, pero la evidencia del fallo es el payload
#   preservado, no el fallback.
set -euo pipefail
umask 077

CENTINELA="PLANTILLA-RESPUESTA (sustituye esta linea con tu respuesta usando str_replace y ejecuta: buzz-publicar <uuid-del-canal>)"
ARCHIVO="./respuesta.txt"

fatal() { echo "buzz-publicar: $*" >&2; exit 1; }

resembrar() {
  # Escritura atomica del centinela: pase lo que pase, el siguiente turno
  # encuentra un respuesta.txt valido sobre el que str_replace puede operar.
  local tmp
  tmp="$(mktemp "./.respuesta-semilla.XXXXXX")" || return 1
  printf '%s\n' "$CENTINELA" > "$tmp"
  mv -f "$tmp" "$ARCHIVO"
}

CANAL="${1:-}"
[ -n "$CANAL" ] || fatal "falta el uuid del canal (uso: buzz-publicar <uuid>)"
[[ "$CANAL" =~ ^[0-9a-fA-F-]{36}$ ]] || fatal "'$CANAL' no parece un uuid de canal"
command -v buzz >/dev/null || fatal "no encuentro el CLI buzz en PATH"

[ -f "$ARCHIVO" ] || { resembrar; fatal "no existe $ARCHIVO — resembrado; escribe tu respuesta con str_replace y reintenta"; }

# Consumo exclusivo: mv atomico. Si otro turno ya lo consumio, aqui no hay
# fichero y el fallo es ruidoso (jamas se publica contenido a medias).
TMP="$(mktemp "./.respuesta-turno.XXXXXX")"
# mv explicito con limpieza del temporal: el trap aun no esta armado (se arma
# tras definir limpiar, abajo) y bajo set -e un mv fallido abortaria dejando el
# .respuesta-turno.* vacio como residuo. Si otro turno ya consumio el fichero,
# aqui no hay origen y el fallo es ruidoso (jamas se publica a medias).
if ! mv -f -- "$ARCHIVO" "$TMP"; then
  rm -f -- "$TMP"
  fatal "respuesta.txt ya fue consumido por otro turno (o no se pudo mover)"
fi

# El trap garantiza M7: centinela resembrado en TODA salida, exito o fallo.
# shellcheck disable=SC2329  # invocada indirectamente por el trap EXIT
limpiar() {
  resembrar || echo "buzz-publicar: AVISO — no pude resembrar el centinela" >&2
  rm -f "$TMP" 2>/dev/null || true
}
trap limpiar EXIT

CONTENIDO="$(cat "$TMP")"
# Rechaza contenido compuesto SOLO de espacios en blanco — incluye tabs y
# saltos de linea, no solo el espacio ASCII (que era lo unico que filtraba
# "${CONTENIDO// /}"). grep busca al menos un caracter no-blanco en el fichero.
if ! grep -q '[^[:space:]]' "$TMP"; then
  fatal "respuesta vacia (solo espacios en blanco) — nada que publicar"
fi
if [ "$(printf '%s\n' "$CONTENIDO")" = "$(printf '%s\n' "$CENTINELA")" ]; then
  fatal "respuesta.txt sigue siendo la plantilla — sustituyela con str_replace antes de publicar"
fi

if buzz messages send --channel "$CANAL" --content - < "$TMP"; then
  exit 0
fi

# Envio fallido: preservar el payload como EVIDENCIA con nombre exclusivo
# (mktemp — una marca temporal de baja resolucion podria pisar un fallo
# anterior), permisos 0600 del dueño de la instancia (umask 077).
FALLIDA="$(mktemp "./respuesta-fallida.XXXXXX")"
# Preservar por RENOMBRADO atomico, no cp: un cp puede fallar a medias (disco
# lleno) y, con set -e, abortar ANTES del mensaje dejando que el trap borre
# $TMP — el payload se perderia. mv es rename(2): mueve entero o falla sin
# tocar el origen. En el fallo (raro) del propio mv, se desarma el trap para
# conservar $TMP como evidencia.
if mv -f "$TMP" "$FALLIDA"; then
  echo "buzz-publicar: envio fallido — payload preservado en $FALLIDA; el fallback (best-effort) puede rescatar el turno" >&2
else
  trap - EXIT
  rm -f "$FALLIDA" 2>/dev/null || true
  resembrar || echo "buzz-publicar: AVISO — no pude resembrar el centinela" >&2
  echo "buzz-publicar: envio fallido — payload preservado en $TMP (no pude renombrarlo)" >&2
fi
exit 1
