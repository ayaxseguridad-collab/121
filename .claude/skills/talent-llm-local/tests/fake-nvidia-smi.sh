#!/usr/bin/env bash
# fake-nvidia-smi.sh — nvidia-smi de mentira, para ejercitar la puerta sin el hardware.
#
# Emula solo lo que consume sonda.sh:
#   nvidia-smi --query-gpu=index,name,memory.total,compute_cap,driver_version \
#              --format=csv,noheader,nounits
#
# Se controla con FAKE_GPUS, una lista separada por ';' de 'nombre|vram_mib|compute':
#
#   FAKE_GPUS='RTX 5060 Ti|16311|12.0;RTX 5060 Ti|16311|12.0'   # la de referencia
#   FAKE_GPUS=''                                                 # sin tarjetas
#
# FAKE_DRIVER cambia la version de driver (por defecto, la de la maquina rodada).

# Sin ':' a proposito: FAKE_GPUS='' debe significar "maquina sin tarjetas", no
# "usa el valor por defecto" (que es justo lo que hace ':=' con una cadena vacia).
: "${FAKE_GPUS=NVIDIA GeForce RTX 5060 Ti|16311|12.0;NVIDIA GeForce RTX 5060 Ti|16311|12.0}"
: "${FAKE_DRIVER:=595.84}"

[ -z "$FAKE_GPUS" ] && exit 0

idx=0
IFS=';' read -r -a _tarjetas <<<"$FAKE_GPUS"
for t in "${_tarjetas[@]}"; do
  IFS='|' read -r nombre vram cc <<<"$t"
  printf '%s, %s, %s, %s, %s\n' "$idx" "$nombre" "$vram" "$cc" "$FAKE_DRIVER"
  idx=$((idx + 1))
done
