#!/usr/bin/env bash
# probar-puente.sh — las OCHO combinaciones del puente, de verdad.
#
#   bash tests/probar-puente.sh
#
#   texto / herramientas  ×  bloqueante / streaming  ×  qwen / qwent
#
# Y ademas la comprobacion que suele faltar: que `qwen` NO devuelva razonamiento.
# Verificar solo que el pensante piensa deja pasar el caso en que ambos piensan, que
# es una regresion cara (el modo rapido dejaria de ser rapido sin avisar).
#
# Necesita el puente en marcha. Sale 0 si las ocho pasan.

set -uo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/00-config.sh
. "$AQUI/../scripts/00-config.sh"
# shellcheck source=../scripts/lib.sh
. "$AQUI/../scripts/lib.sh"

URL="http://$BIND_ADDR:$PORT_PUENTE/v1/messages"
curl -sf -o /dev/null --max-time 5 -X POST "$URL" -H 'content-type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"qwen","max_tokens":16,"messages":[{"role":"user","content":"hola"}]}' \
  || morir "El puente no responde en $BIND_ADDR:$PORT_PUENTE." \
     "Arrancalo antes:  sudo systemctl start llm-bridge"

HERRAMIENTA='{"name":"obtener_tiempo","description":"Devuelve el tiempo de una ciudad",
  "input_schema":{"type":"object","properties":{"ciudad":{"type":"string"}},"required":["ciudad"]}}'

PASA=0; FALLA=0

# uso: caso <nombre> <modelo> <modo:texto|tools> <transporte:bloq|stream>
caso() {
  local nombre="$1" modelo="$2" modo="$3" transporte="$4"
  local espera_razonamiento="no"; [ "$modelo" = "qwent" ] && espera_razonamiento="si"

  local cuerpo
  cuerpo="$(MODELO="$modelo" MODO="$modo" TRANSPORTE="$transporte" \
            MAXTOK="$THINK_MIN_TOKENS" HERRAMIENTA="$HERRAMIENTA" python3 -c '
import json, os
modo, transporte = os.environ["MODO"], os.environ["TRANSPORTE"]
peticion = {
    "model": os.environ["MODELO"],
    "max_tokens": int(os.environ["MAXTOK"]),
    "stream": transporte == "stream",
    "messages": [{"role": "user", "content":
        "¿Que tiempo hace en Lima? Usa la herramienta." if modo == "tools"
        else "Responde unicamente con la palabra: listo"}],
}
if modo == "tools":
    peticion["tools"] = [json.loads(os.environ["HERRAMIENTA"])]
print(json.dumps(peticion))')"

  local salida
  salida="$(curl -sf --max-time 300 -X POST "$URL" \
            -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
            -d "$cuerpo" 2>/dev/null)" || { printf '  FALLO %-38s la peticion no responde\n' "$nombre"; FALLA=$((FALLA+1)); return; }

  local problema=""
  # En streaming la respuesta es SSE; en bloqueante, un JSON. Se busca sobre el
  # texto crudo a proposito: vale para los dos transportes.
  if [ "$transporte" = "stream" ]; then
    grep -q 'event: message_start' <<<"$salida" || problema="no llegan eventos de streaming"
    [ -z "$problema" ] && ! grep -q 'event: message_stop' <<<"$salida" && problema="el streaming no se cierra"
  else
    grep -q '"type"[[:space:]]*:[[:space:]]*"message"' <<<"$salida" || problema="la respuesta no es un mensaje"
  fi

  if [ -z "$problema" ] && [ "$modo" = "tools" ]; then
    grep -q 'tool_use' <<<"$salida" || problema="no ha llamado a la herramienta"
  fi

  if [ -z "$problema" ]; then
    if [ "$espera_razonamiento" = "si" ]; then
      grep -q '"thinking"' <<<"$salida" || problema="qwent NO ha devuelto razonamiento"
    else
      grep -q '"thinking"' <<<"$salida" && problema="qwen SI ha devuelto razonamiento (deberia ir sin pensar)"
    fi
  fi

  if [ -z "$problema" ]; then
    printf '  OK    %s\n' "$nombre"; PASA=$((PASA+1))
  else
    printf '  FALLO %-38s %s\n' "$nombre" "$problema"; FALLA=$((FALLA+1))
  fi
}

titulo "Puente — 8 combinaciones"
for modelo in qwen qwent; do
  for modo in texto tools; do
    for transporte in bloq stream; do
      caso "$modelo · $modo · $transporte" "$modelo" "$modo" "$transporte"
    done
  done
done

printf '\n  %d correctas · %d fallidas de 8\n\n' "$PASA" "$FALLA"
[ "$FALLA" -eq 0 ]
