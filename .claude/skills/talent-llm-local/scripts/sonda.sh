#!/usr/bin/env bash
# sonda.sh — LA PUERTA. Mide la maquina y decide si puede correr ESTA configuracion.
#
# No es un selector: no elige un perfil mas modesto ni monta una version inferior.
# O la maquina reproduce el montaje rodado, o se dice exactamente que le falta.
#
#   Uso:  bash sonda.sh [--json]
#   Sale: 0 autoriza · 1 rechaza (con el motivo de cada requisito que falla)
#
# Para probar la puerta sin el hardware:  NVIDIA_SMI=../tests/fake-nvidia-smi.sh bash sonda.sh

set -uo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-config.sh
. "$AQUI/00-config.sh"
# shellcheck source=lib.sh
. "$AQUI/lib.sh"

: "${NVIDIA_SMI:=nvidia-smi}"
FORMATO_JSON=0
[ "${1:-}" = "--json" ] && FORMATO_JSON=1

FALLOS=()
rechazo() { FALLOS+=("$1"); }

# ------------------------------------------------------------------ sistema
SO="$(uname -s)"
DISTRO="$( [ -r /etc/os-release ] && . /etc/os-release && printf '%s %s' "${NAME:-?}" "${VERSION_ID:-}" )"
if [ "$SO" != "Linux" ]; then
  rechazo "Sistema: '$SO'. Este montaje necesita Linux — el motor corre en contenedor con el NVIDIA Container Toolkit, que no existe fuera de Linux."
elif ! tiene systemctl; then
  rechazo "Sistema: sin systemd. Los servicios que sobreviven al reinicio son unidades systemd; sin el no hay persistencia."
fi

# Distribucion. Que exista `apt-get` NO basta: el instalador da de alta repositorios
# concretos, y autorizar aqui algo que luego no sabe preparar seria un falso positivo
# de compatibilidad. La puerta se cierra donde acaba lo rodado, que es Ubuntu.
# LL_DISTRO_ID permite forzarla (para pruebas, o para quien acepte el riesgo a sabiendas).
DISTRO_ID="${LL_DISTRO_ID:-$( [ -r /etc/os-release ] && . /etc/os-release && printf '%s' "${ID:-}" )}"
if [ "$SO" = "Linux" ]; then
  if ! tiene apt-get; then
    rechazo "Sistema: '${DISTRO:-desconocida}' no usa apt. El instalador prepara Docker y el NVIDIA Container Toolkit con paquetes .deb; en otra familia de distribucion habria que instalarlos a mano, y eso no lo hemos rodado."
  elif [ "$DISTRO_ID" != "ubuntu" ]; then
    rechazo "Sistema: '${DISTRO:-desconocida}' (ID '${DISTRO_ID:-?}'). Lo rodado es Ubuntu. El instalador da de alta los repositorios oficiales de Docker y de NVIDIA para tu distribucion, pero en otra que no sea Ubuntu no lo hemos probado de extremo a extremo. Si quieres intentarlo bajo tu responsabilidad: LL_DISTRO_ID=ubuntu ."
  fi
fi

# ------------------------------------------------------------------ GPU
N_GPUS=0; VRAM_TOTAL=0; VRAM_MIN=0; COMPUTE=""; DRIVER=""; MODELOS_GPU=""
# Ojo: nada de "${NVIDIA_SMI%% *}" para quedarse con el binario — si la ruta lleva
# espacios, el troceo la parte por la mitad y la sonda cree que no hay driver.
if ! tiene "$NVIDIA_SMI" && [ ! -x "$NVIDIA_SMI" ]; then
  rechazo "GPU: no se encuentra 'nvidia-smi'. O no hay tarjeta NVIDIA, o falta el driver propietario. Instala el driver de NVIDIA y vuelve a lanzar la sonda."
else
  CONSULTA="$("$NVIDIA_SMI" --query-gpu=index,name,memory.total,compute_cap,driver_version \
              --format=csv,noheader,nounits 2>/dev/null)" || CONSULTA=""
  if [ -z "$CONSULTA" ]; then
    rechazo "GPU: 'nvidia-smi' no devuelve tarjetas. Comprueba que el driver esta cargado ('nvidia-smi' a mano deberia listar tus GPU)."
  else
    NOMBRES=(); VRAMS=(); COMPUTES=()
    while IFS=, read -r _idx nombre mem cc drv; do
      nombre="$(printf '%s' "$nombre" | xargs)"; mem="$(printf '%s' "$mem" | xargs)"
      cc="$(printf '%s' "$cc" | xargs)";        drv="$(printf '%s' "$drv" | xargs)"
      NOMBRES+=("$nombre"); VRAMS+=("$mem"); COMPUTES+=("$cc")
      DRIVER="$drv"
      N_GPUS=$((N_GPUS + 1)); VRAM_TOTAL=$((VRAM_TOTAL + mem))
      { [ "$VRAM_MIN" -eq 0 ] || [ "$mem" -lt "$VRAM_MIN" ]; } && VRAM_MIN="$mem"
    done <<<"$CONSULTA"
    COMPUTE="${COMPUTES[0]}"
    MODELOS_GPU="$(printf '%s\n' "${NOMBRES[@]}" | sort -u | paste -sd'; ')"

    # --- numero exacto de tarjetas -------------------------------------------
    # Va ligado a TP=2. Con 1 tarjeta el tensor parallel de tamanio 2 no reparte;
    # con 4 u 8 la topologia deja de ser la que se roda aqui. Ninguna de las dos
    # cosas es "lo mismo", asi que ninguna se autoriza.
    if [ "$N_GPUS" -ne "$EXIGE_GPUS" ]; then
      rechazo "GPU: hay $N_GPUS tarjeta(s) y hacen falta exactamente $EXIGE_GPUS. Esta configuracion es tensor parallel de tamanio $TP_SIZE: con otra cantidad seria otro montaje, y no lo hemos rodado."
    fi

    # --- tarjetas identicas ---------------------------------------------------
    if [ "$(printf '%s\n' "${NOMBRES[@]}" | sort -u | wc -l)" -gt 1 ]; then
      rechazo "GPU: las tarjetas no son iguales ($MODELOS_GPU). El reparto por tensor parallel es simetrico: la mas pequenia marca el ritmo y la grande queda desaprovechada."
    fi

    # --- VRAM ------------------------------------------------------------------
    # Umbrales en MiB tal cual los informa nvidia-smi. Una tarjeta "de 16 GB"
    # declara 16311 MiB (15,93 GiB): con el umbral en GiB, esta misma maquina
    # suspenderia su propia puerta.
    if [ "$VRAM_MIN" -lt "$MIN_VRAM_POR_GPU_MIB" ]; then
      rechazo "GPU: la tarjeta mas pequenia tiene ${VRAM_MIN} MiB y hacen falta ${MIN_VRAM_POR_GPU_MIB}. Cada tarjeta carga su mitad del modelo (medido aqui: 15,2 y 14,7 GiB)."
    fi
    if [ "$VRAM_TOTAL" -lt "$MIN_VRAM_TOTAL_MIB" ]; then
      rechazo "GPU: hay ${VRAM_TOTAL} MiB de VRAM en total y hacen falta ${MIN_VRAM_TOTAL_MIB}. El montaje ocupa 29,9 GiB en marcha; es la unica capacidad en la que lo hemos visto funcionar."
    fi

    # --- NVFP4 -----------------------------------------------------------------
    if [ -n "$COMPUTE" ] && ! version_ge "$COMPUTE" "$MIN_COMPUTE"; then
      rechazo "GPU: capacidad de computo $COMPUTE, y NVFP4 necesita $MIN_COMPUTE o superior (Blackwell). En tarjetas anteriores este modelo cuantizado no arranca; ver 'Lo que queda fuera' en references/01-requisitos-y-sonda.md."
    fi
  fi
fi

# ------------------------------------------------------------------ disco
libre_gb() { df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }
fs_de()    { df --output=source "$1" 2>/dev/null | tail -1; }

DIR_MODELOS="$LL_MODELS"; while [ ! -d "$DIR_MODELOS" ] && [ "$DIR_MODELOS" != "/" ]; do
  DIR_MODELOS="$(dirname "$DIR_MODELOS")"; done
DIR_DOCKER=/var/lib/docker; [ -d "$DIR_DOCKER" ] || DIR_DOCKER=/var/lib

LIBRE_MODELOS="$(libre_gb "$DIR_MODELOS")"; LIBRE_MODELOS="${LIBRE_MODELOS:-0}"
LIBRE_DOCKER="$(libre_gb "$DIR_DOCKER")";   LIBRE_DOCKER="${LIBRE_DOCKER:-0}"

if [ "$(fs_de "$DIR_MODELOS")" = "$(fs_de "$DIR_DOCKER")" ]; then
  [ "$LIBRE_MODELOS" -lt "$MIN_DISCO_GB" ] && rechazo \
    "Disco: quedan ${LIBRE_MODELOS} GB libres y hacen falta ${MIN_DISCO_GB} (pesos e imagen comparten sistema de ficheros). Medido: 22 GB de pesos + 28,1 GB de imagen extraida."
else
  [ "$LIBRE_MODELOS" -lt "$MIN_DISCO_MODELOS_GB" ] && rechazo \
    "Disco: en $DIR_MODELOS quedan ${LIBRE_MODELOS} GB y hacen falta ${MIN_DISCO_MODELOS_GB} para los pesos (22 GB medidos + margen de descarga)."
  [ "$LIBRE_DOCKER" -lt "$MIN_DISCO_DOCKER_GB" ] && rechazo \
    "Disco: en $DIR_DOCKER quedan ${LIBRE_DOCKER} GB y hacen falta ${MIN_DISCO_DOCKER_GB} para la imagen (28,1 GB medidos + margen de actualizacion)."
fi

# ------------------------------------------------------------------ herramientas
# Docker y el NVIDIA Container Toolkit NO son motivo de rechazo: los instala la fase
# `requisitos` de montar.sh. La sonda solo deja constancia de si ya estan.
DOCKER_VER=""; TOOLKIT="no"
tiene docker && DOCKER_VER="$(docker --version 2>/dev/null | sed 's/,.*//')"
{ tiene nvidia-ctk || [ -f /usr/bin/nvidia-container-runtime ]; } && TOOLKIT="si"

# ------------------------------------------------------------------ veredicto
RAM_GB="$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null || echo 0)"

if [ "$FORMATO_JSON" = "1" ]; then
  # Serializado por Python entero, no interpolado a mano: un nombre de GPU o de
  # distribucion con comillas romperia un JSON construido con printf.
  AUTORIZA="$([ "${#FALLOS[@]}" -eq 0 ] && echo true || echo false)" \
  N_GPUS="$N_GPUS" MODELOS_GPU="$MODELOS_GPU" VRAM_TOTAL="$VRAM_TOTAL" \
  VRAM_MIN="$VRAM_MIN" COMPUTE="$COMPUTE" DRIVER="$DRIVER" RAM_GB="$RAM_GB" \
  DOCKER_VER="$DOCKER_VER" TOOLKIT="$TOOLKIT" DISTRO="$DISTRO" \
  python3 -c '
import json, os, sys
print(json.dumps({
    "autoriza": os.environ["AUTORIZA"] == "true",
    "distro": os.environ["DISTRO"],
    "gpus": int(os.environ["N_GPUS"]),
    "modelo_gpu": os.environ["MODELOS_GPU"],
    "vram_total_mib": int(os.environ["VRAM_TOTAL"]),
    "vram_min_mib": int(os.environ["VRAM_MIN"]),
    "compute": os.environ["COMPUTE"],
    "driver": os.environ["DRIVER"],
    "ram_gb": int(os.environ["RAM_GB"]),
    "docker": os.environ["DOCKER_VER"],
    "toolkit": os.environ["TOOLKIT"],
    "motivos": [l.rstrip("\n") for l in sys.stdin if l.strip()],
}, ensure_ascii=False))
' <<<"$(printf '%s\n' ${FALLOS[@]+"${FALLOS[@]}"})"
else
  titulo "Sonda — tu maquina frente a la configuracion de referencia"
  printf '  Sistema      %s (%s)\n' "$SO" "${DISTRO:-?}"
  printf '  GPU          %d x %s\n' "$N_GPUS" "${MODELOS_GPU:-ninguna}"
  printf '  VRAM         %d MiB en total · %d MiB la mas pequenia\n' "$VRAM_TOTAL" "$VRAM_MIN"
  printf '  Computo      %s · driver %s\n' "${COMPUTE:-?}" "${DRIVER:-?}"
  printf '  RAM          %d GB\n' "$RAM_GB"
  printf '  Disco        %d GB libres (pesos) · %d GB libres (imagen)\n' "$LIBRE_MODELOS" "$LIBRE_DOCKER"
  printf '  Docker       %s\n' "${DOCKER_VER:-no instalado — lo instala el montaje}"
  printf '  Toolkit      %s\n' "$([ "$TOOLKIT" = si ] && echo presente || echo 'ausente — lo instala el montaje')"
  printf '\n'
  if [ "${#FALLOS[@]}" -eq 0 ]; then
    ok "Tu maquina puede correr esta configuracion. Sigue con:  sudo bash montar.sh"
  else
    fail "Tu maquina no llega a esta configuracion. Motivos (${#FALLOS[@]}):"
    printf '\n'
    for m in "${FALLOS[@]}"; do printf '   · %s\n\n' "$m"; done
    printf '  El montaje no sigue: instalar una version recortada de esto no seria "lo mismo",\n'
    printf '  y no la hemos rodado. Lo que queda fuera y por que, en:\n'
    printf '    references/01-requisitos-y-sonda.md\n\n'
  fi
fi

# ------------------------------------------------------------------ perfil.conf
# Fichero de diagnostico: pensado para pegarlo en una consulta sin pensarselo dos
# veces. Por eso NO lleva claves, tokens ni nada que permita reconstruirlos.
if [ "${DRY_RUN:-0}" != "1" ] && [ "$FORMATO_JSON" = "0" ]; then
  mkdir -p "$(dirname "$PERFIL")" 2>/dev/null && cat >"$PERFIL" <<EOF || true
# talent-llm-local — diagnostico de la maquina. Sin secretos: se puede compartir.
fecha=$(date -Iseconds)
autoriza=$([ "${#FALLOS[@]}" -eq 0 ] && echo si || echo no)
sistema=$SO
distro=$DISTRO
gpus=$N_GPUS
modelo_gpu=$MODELOS_GPU
vram_total_mib=$VRAM_TOTAL
vram_min_mib=$VRAM_MIN
compute_cap=$COMPUTE
driver=$DRIVER
ram_gb=$RAM_GB
docker=$DOCKER_VER
nvidia_container_toolkit=$TOOLKIT
disco_modelos_gb=$LIBRE_MODELOS
disco_docker_gb=$LIBRE_DOCKER
imagen=$VLLM_IMAGE
modelo=$MODEL_ID
EOF
fi

[ "${#FALLOS[@]}" -eq 0 ]
