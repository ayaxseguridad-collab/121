#!/usr/bin/env bash
# verificar.sh — comprueba el montaje. No toca nada: solo mira y cuenta.
#
#   bash verificar.sh
#
# Separa lo obligatorio de lo opcional a proposito. Quien salta la integracion con
# Claude Code (--sin-puente) tiene un montaje CORRECTO, no uno a medias: sus items
# salen como OMIT, no como fallo.
#
# Cuando algo falla no dice solo "falla": dice que comando lo arregla.

set -uo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-config.sh
. "$AQUI/00-config.sh"
# shellcheck source=lib.sh
. "$AQUI/lib.sh"

N_OK=0; N_FALLO=0; N_OMIT=0
pasa()   { ok "$1";   N_OK=$((N_OK + 1)); }
nopasa() { fail "$1"; N_FALLO=$((N_FALLO + 1)); [ $# -gt 1 ] && printf '         arreglo: %s\n' "$2"; }
salta()  { omit "$1"; N_OMIT=$((N_OMIT + 1)); }

LEAD=""; HERMES_KEYS=()
if [ -r "$KEYS_FILE" ]; then
  # shellcheck disable=SC1090
  . "$KEYS_FILE"
  LEAD="${VLLM_API_KEY:-}"
  for i in $(seq 1 "$N_HERMES"); do v="HERMES_KEY_$i"; HERMES_KEYS+=("${!v:-}"); done
fi

# La clave nunca por argv (ver conf_clave en lib.sh): este mismo verificador
# comprueba mas abajo que ninguna clave aparece en la linea de arranque, asi que
# tampoco puede exponerlas el aqui mientras las prueba.
api() {
  local clave="$1" cfg rc; shift
  cfg="$(conf_clave "$clave")"
  curl -sf --max-time 15 --config "$cfg" "$@"
  rc=$?
  rm -f "$cfg"
  return "$rc"
}

# ============================================================ NUCLEO
titulo "Nucleo — esto tiene que estar"

# --- claves ----------------------------------------------------------------
if [ -z "$LEAD" ]; then
  nopasa "No se pueden leer las claves de $KEYS_FILE" "sudo bash montar.sh --only claves"
else
  pasa "Claves legibles en $KEYS_FILE (modo $(stat -c %a "$KEYS_FILE"))"
fi

# --- motor -----------------------------------------------------------------
if systemctl is-active --quiet vllm.service; then
  pasa "El motor esta corriendo"
else
  nopasa "El motor no esta corriendo" "sudo systemctl start vllm && journalctl -u vllm -n 60 --no-pager"
fi

if systemctl is-enabled --quiet vllm.service 2>/dev/null; then
  pasa "El motor arranca solo tras un reinicio"
else
  nopasa "El motor NO arranca solo tras un reinicio" "sudo systemctl enable vllm"
fi

if curl -sf --max-time 5 -o /dev/null "http://$BIND_ADDR:$PORT_MOTOR/health"; then
  pasa "El motor responde en $BIND_ADDR:$PORT_MOTOR"
else
  nopasa "El motor no responde" "journalctl -u vllm -n 80 --no-pager  ·  references/07-averias.md"
fi

# --- el modelo que se sirve es el que toca ---------------------------------
if [ -n "$LEAD" ]; then
  servidos="$(api "$LEAD" "http://$BIND_ADDR:$PORT_MOTOR/v1/models" 2>/dev/null \
              | python3 -c 'import json,sys;print(" ".join(m["id"] for m in json.load(sys.stdin)["data"]))' 2>/dev/null)"
  if printf '%s' "$servidos" | grep -qw "$SERVED_NAME"; then
    pasa "Sirviendo «$SERVED_NAME»"
  else
    nopasa "No se sirve «$SERVED_NAME» (hay: ${servidos:-nada})" "sudo systemctl restart vllm"
  fi
fi

# --- las cinco claves valen y una inventada no -----------------------------
# Se prueban contra el MEDIDOR, que es quien autentica: las claves de usuario no
# llegan al motor (ni aparecen en la linea de arranque de ningun proceso).
if [ -n "$LEAD" ]; then
  buenas=0
  for k in "$LEAD" "${HERMES_KEYS[@]}"; do
    [ -n "$k" ] && api "$k" -o /dev/null "http://$BIND_ADDR:$PORT_MEDIDOR/v1/models" && buenas=$((buenas + 1))
  done
  total=$((1 + N_HERMES))
  if [ "$buenas" -eq "$total" ]; then
    pasa "Las $total claves autorizan en el medidor"
  else
    nopasa "Solo $buenas de $total claves autorizan" \
           "Suele faltar ALIAS_MAP en $KEYS_FILE. Ver references/07-averias.md"
  fi
  # Que rechace lo que debe rechazar es tan importante como que acepte.
  if api "sk-inventada-no-deberia-valer" -o /dev/null "http://$BIND_ADDR:$PORT_MEDIDOR/v1/models" 2>/dev/null; then
    nopasa "El medidor acepta una clave inventada" "Revisa ALIAS_MAP y reinicia:  sudo systemctl restart llm-meter"
  else
    pasa "Una clave inventada se rechaza"
  fi
  # Y el motor no debe atender a una clave de usuario: solo conoce la interna.
  if api "$LEAD" -o /dev/null "http://$BIND_ADDR:$PORT_MOTOR/v1/models" 2>/dev/null; then
    nopasa "El motor atiende con una clave de USUARIO — deberia conocer solo la interna" \
           "Comprueba que la unidad del motor no lleva --api-key y que $ENV_FILE define VLLM_API_KEY"
  else
    pasa "El motor solo atiende con su clave interna"
  fi
fi

# --- ninguna clave a la vista en la linea de arranque -----------------------
# Los argumentos de un proceso los lee cualquier usuario con `ps`. Si alguna clave
# de usuario acabase ahi, la atribucion por usuario dejaria de significar nada.
if [ -n "$LEAD" ]; then
  if grep -q -- "$LEAD" /etc/systemd/system/vllm.service 2>/dev/null \
     || pgrep -af 'docker run .*--api-key' >/dev/null 2>&1; then
    nopasa "Hay claves en la linea de arranque del motor (visibles con \`ps\`)" \
           "sudo bash montar.sh --only servicio"
  else
    pasa "Ninguna clave de usuario aparece en la linea de arranque"
  fi
  modo_env="$(stat -c %a "$ENV_FILE" 2>/dev/null || echo '?')"
  if [ "$modo_env" = "600" ]; then
    pasa "La clave interna del motor esta en $ENV_FILE (modo 600)"
  else
    nopasa "$ENV_FILE tiene modo $modo_env y deberia ser 600" "sudo chmod 600 $ENV_FILE"
  fi
fi

# --- medidor ---------------------------------------------------------------
if systemctl is-active --quiet llm-meter.service && curl -sf --max-time 5 -o /dev/null "http://$BIND_ADDR:$PORT_MEDIDOR/stats"; then
  pasa "Medidor respondiendo en $BIND_ADDR:$PORT_MEDIDOR"
else
  nopasa "El medidor no responde" "sudo systemctl restart llm-meter && journalctl -u llm-meter -n 40 --no-pager"
fi
systemctl is-enabled --quiet llm-meter.service 2>/dev/null \
  && pasa "El medidor arranca solo tras un reinicio" \
  || nopasa "El medidor NO arranca solo" "sudo systemctl enable llm-meter"

# --- puestos de agente ------------------------------------------------------
perfiles=0
for i in $(seq 1 "$N_HERMES"); do
  [ -f "$LL_HOME/.hermes/profiles/hermes-$i/config.yaml" ] && perfiles=$((perfiles + 1))
done
if [ "$perfiles" -eq "$N_HERMES" ]; then
  pasa "$N_HERMES puestos de agente configurados"
else
  nopasa "Solo $perfiles de $N_HERMES puestos configurados" "sudo bash montar.sh --only hermes"
fi

# ============================================================ LIMITE DE POTENCIA
titulo "Limite de potencia — se cuenta aparte"
# A proposito NO se pliega dentro de la persistencia: un limite que no queda puesto
# es un fallo propio, y esconderlo dentro de "todo correcto" seria mentir sobre el
# consumo y la temperatura a las que corre la maquina.
if [ "$APLICAR_POWER_LIMIT" != "si" ]; then
  salta "Desactivado por configuracion (APLICAR_POWER_LIMIT=$APLICAR_POWER_LIMIT)"
elif ! systemctl is-enabled --quiet nvidia-powerlimit.service 2>/dev/null; then
  nopasa "La unidad del limite no esta habilitada" "sudo systemctl enable --now nvidia-powerlimit"
else
  aplicados="$(nvidia-smi --query-gpu=enforced.power.limit --format=csv,noheader,nounits 2>/dev/null | cut -d. -f1)"
  fuera=0
  while read -r w; do [ -n "$w" ] && [ "$w" -gt "$POWER_LIMIT_W" ] && fuera=1; done <<<"$aplicados"
  if [ "$fuera" = 0 ] && [ -n "$aplicados" ]; then
    pasa "Limite aplicado en todas las tarjetas (<= ${POWER_LIMIT_W} W)"
  else
    nopasa "Hay tarjetas por encima de ${POWER_LIMIT_W} W: $(printf '%s ' $aplicados)" \
           "sudo systemctl restart nvidia-powerlimit && systemctl status nvidia-powerlimit"
  fi
fi

# ============================================================ OPCIONAL
titulo "Opcional — puente y Claude Code"

if [ ! -f /etc/systemd/system/llm-bridge.service ]; then
  salta "Puente no instalado (montaje con --sin-puente). El nucleo de arriba es lo que cuenta."
  salta "Alias /model qwen y qwent: los da el puente"
  salta "Integracion con Claude Code"
else
  if systemctl is-active --quiet llm-bridge.service; then
    pasa "Puente corriendo en $BIND_ADDR:$PORT_PUENTE"
  else
    nopasa "El puente no responde" "sudo systemctl restart llm-bridge && journalctl -u llm-bridge -n 40 --no-pager"
  fi
  systemctl is-enabled --quiet llm-bridge.service 2>/dev/null \
    && pasa "El puente arranca solo tras un reinicio" \
    || nopasa "El puente NO arranca solo" "sudo systemctl enable llm-bridge"

  # Los dos alias, de verdad: que respondan y que el pensante razone.
  probar_alias() {
    local modelo="$1" espera_razonamiento="$2"
    local r
    r="$(curl -sf --max-time 120 -X POST "http://$BIND_ADDR:$PORT_PUENTE/v1/messages" \
         -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
         -d "{\"model\":\"$modelo\",\"max_tokens\":$THINK_MIN_TOKENS,\"messages\":[{\"role\":\"user\",\"content\":\"Responde solo con la palabra: listo\"}]}" 2>/dev/null)" || return 1
    [ -n "$r" ] || return 1
    if [ "$espera_razonamiento" = "si" ]; then
      printf '%s' "$r" | grep -q '"thinking"' || return 2
    fi
    return 0
  }
  case "$(probar_alias qwen no; echo $?)" in
    0) pasa "/model qwen responde" ;;
    *) nopasa "/model qwen no responde" "journalctl -u llm-bridge -n 60 --no-pager" ;;
  esac
  case "$(probar_alias qwent si; echo $?)" in
    0) pasa "/model qwent responde y devuelve razonamiento" ;;
    2) nopasa "qwent responde pero SIN bloque de razonamiento" \
              "Suele ser el campo del razonamiento: el motor lo devuelve en 'reasoning' desde 0.26. Ver references/07-averias.md" ;;
    *) nopasa "/model qwent no responde" "journalctl -u llm-bridge -n 60 --no-pager" ;;
  esac

  ajustes="$LL_HOME/.claude/settings.json"
  if [ ! -f "$ajustes" ]; then
    salta "No hay Claude Code en esta maquina"
  elif grep -q "ANTHROPIC_BASE_URL" "$ajustes" 2>/dev/null; then
    pasa "Claude Code apunta al puente"
    if grep -qE '"(ANTHROPIC_AUTH_TOKEN|ANTHROPIC_API_KEY)"' "$ajustes" 2>/dev/null; then
      nopasa "Hay credencial de pasarela en settings.json — anula tu suscripcion" \
             "Quita ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY de $ajustes"
    else
      pasa "Sin credencial de pasarela: tu suscripcion sigue intacta"
    fi
  else
    nopasa "Claude Code no apunta al puente" "sudo bash montar.sh --only claude"
  fi
fi

# ============================================================ resumen
printf '\n'
if [ "$N_FALLO" -eq 0 ]; then
  ok "$N_OK correctos · $N_OMIT omitidos · 0 fallos"
else
  fail "$N_OK correctos · $N_OMIT omitidos · $N_FALLO FALLOS (cada uno con su arreglo arriba)"
fi
printf '\n'
[ "$N_FALLO" -eq 0 ]
