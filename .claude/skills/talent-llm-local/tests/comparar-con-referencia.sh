#!/usr/bin/env bash
# comparar-con-referencia.sh — ¿lo que genera el skill es lo que corre de verdad?
#
#   bash tests/comparar-con-referencia.sh
#
# Renderiza la unidad del motor desde la plantilla y la compara con la que hay viva
# en la maquina. Es la prueba de que el skill RECONSTRUYE el montaje rodado y no una
# aproximacion parecida.
#
# Se normalizan tres cosas que DEBEN diferir y no significan nada:
#   · la imagen — el skill fija el digest; la maquina de referencia arrastra :latest
#   · la linea --api-key — la maquina de referencia la lleva; el skill ya NO pone
#     claves en la linea de arranque (las ve cualquiera con `ps`) y autentica en el
#     medidor. Es una diferencia INTENCIONADA y una mejora, no una desviacion
#   · la linea Description
#
# NO se lee ni se imprime /etc/llm-local/vllm.env en ningun momento.

set -uo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(cd "$AQUI/.." && pwd)"
VIVA=/etc/systemd/system/vllm.service

# Sin unidad viva esta prueba NO PUEDE decir nada. Salir 0 aqui la contaria como
# aprobada y es justo lo contrario: no se ha verificado.
if [ ! -r "$VIVA" ]; then
  echo "  OMIT  No hay unidad viva en $VIVA: esta comprobacion NO se ha podido hacer."
  echo "        (no es un aprobado; solo se puede correr en una maquina ya montada)"
  exit 2
fi

normaliza() {
  sed -E \
    -e 's#vllm/vllm-openai[@:][^ \\]*#<IMAGEN>#' \
    -e '/--api-key/d' \
    -e 's#--tool-call-parser qwen3_xml --enable-auto-tool-choice \\#--tool-call-parser qwen3_xml --enable-auto-tool-choice#' \
    -e '/^Description=/d' \
    "$1" | sed -E 's/[[:space:]]+$//' | grep -v '^[[:space:]]*#' | grep -v '^$'
}

RENDER="$(mktemp)"; trap 'rm -f "$RENDER"' EXIT

# Mismos valores que la maquina de referencia usa hoy, para que la comparacion mida
# la ESTRUCTURA de la unidad y no diferencias de configuracion elegidas a proposito.
export LL_MODELS=/srv/models/hf ENV_FILE=/etc/llm-local/vllm.env \
       BIND_ADDR=127.0.0.1 PORT_MOTOR=8000 \
       VLLM_IMAGE="vllm/vllm-openai:latest" \
       MODEL_ID=nvidia/Qwen3.6-35B-A3B-NVFP4 SERVED_NAME=claude-qwen-local \
       TP_SIZE=2 MOE_BACKEND=marlin MAX_MODEL_LEN=262144 MAX_NUM_SEQS=16 \
       GPU_MEM_UTIL=0.90 API_KEYS="x"

python3 - "$SKILL/assets/vllm.service.tmpl" >"$RENDER" <<'PY'
import os, re, sys
t = open(sys.argv[1]).read()
faltan = []
def sub(m):
    v = os.environ.get(m.group(1))
    if v is None:
        faltan.append(m.group(1)); return m.group(0)
    return v
s = re.sub(r"@@(\w+)@@", sub, t)
if faltan:
    sys.exit("sin valor para: " + ", ".join(sorted(set(faltan))))
sys.stdout.write(s)
PY

# /tmp/lls-diff.$$ es adivinable (PID) y /tmp es escribible por todos: cualquiera
# podria pre-crearlo como symlink a un fichero del sistema y la redireccion lo
# sobreescribiria con los privilegios de quien corre la prueba. mktemp, igual que
# $RENDER dos lineas mas arriba.
DIFF="$(mktemp)"; trap 'rm -f "$RENDER" "$DIFF"' EXIT

if diff -u <(normaliza "$VIVA") <(normaliza "$RENDER") >"$DIFF" 2>&1; then
  echo "  OK    La unidad que genera el skill coincide con la que corre en la maquina."
  exit 0
fi

echo "  DIFERENCIAS entre la unidad viva y la que genera el skill:"
echo "  (— es lo que corre ahora · + es lo que montaria el skill)"
echo
sed 's/^/    /' "$DIFF"
echo
echo "  Revisa si cada diferencia es intencionada. Si lo es, actualiza la plantilla"
echo "  o esta prueba; si no lo es, el skill no reproduce lo rodado."
exit 1
