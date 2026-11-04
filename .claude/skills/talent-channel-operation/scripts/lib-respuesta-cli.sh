#!/usr/bin/env bash
# Respuesta de sonda: un solo objeto, éxito explícito y resultado no vacío.
cli_respuesta_objeto() {
  jq -es 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1
}
cli_respuesta_exito() {
  local respuesta
  respuesta=$(cat)
  cli_respuesta_objeto <<< "$respuesta" || return 1
  jq -e '.is_error == false and .subtype == "success" and (.result | type == "string" and length > 0)' <<< "$respuesta" >/dev/null 2>&1
}
