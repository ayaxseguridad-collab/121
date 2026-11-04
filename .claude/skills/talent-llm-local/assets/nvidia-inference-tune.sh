#!/usr/bin/env bash
# Deja las GPU en estado de servidor de inferencia: limite de potencia, sin
# overclock y simetricas. Todo esto es volatil y se reaplica en cada arranque.
#
# Falla RUIDOSAMENTE si algo no queda aplicado. Un ajuste de rendimiento que falla
# en silencio es peor que no tenerlo: crees que corres a 150 W y corres a 198.
set -euo pipefail

: "${LIMIT_W:=150}"

nvidia-smi -pm 1 >/dev/null

mapfile -t IDX < <(nvidia-smi --query-gpu=index --format=csv,noheader)
[ "${#IDX[@]}" -gt 0 ] || { echo "no se detecta ninguna GPU" >&2; exit 1; }

# Rango soportado por la tarjeta. Pedir un limite fuera de rango falla, y hay que
# enterarse ANTES de dar el montaje por bueno.
MIN_W=$(nvidia-smi -i "${IDX[0]}" --query-gpu=power.min_limit --format=csv,noheader,nounits | cut -d. -f1)
MAX_W=$(nvidia-smi -i "${IDX[0]}" --query-gpu=power.max_limit --format=csv,noheader,nounits | cut -d. -f1)
if [ -n "$MIN_W" ] && [ -n "$MAX_W" ] && { [ "$LIMIT_W" -lt "$MIN_W" ] || [ "$LIMIT_W" -gt "$MAX_W" ]; }; then
  echo "limite pedido ${LIMIT_W}W fuera del rango de la tarjeta (${MIN_W}-${MAX_W}W)" >&2
  exit 1
fi

# TODAS las tarjetas, no solo la primera: si una queda con otro limite u otro
# reloj, en multi-GPU la lenta marca el ritmo de las dos.
for i in "${IDX[@]}"; do
  nvidia-smi -i "$i" -pl "$LIMIT_W" >/dev/null
  nvidia-smi -i "$i" -rgc >/dev/null 2>&1 || true
done

# Offsets de overclock a cero en todas las tarjetas (nvidia-smi no expone esto).
python3 - <<'PY'
import ctypes
n = ctypes.CDLL("libnvidia-ml.so.1")
n.nvmlInit_v2()
c = ctypes.c_uint()
n.nvmlDeviceGetCount_v2(ctypes.byref(c))
for i in range(c.value):
    d = ctypes.c_void_p()
    n.nvmlDeviceGetHandleByIndex_v2(i, ctypes.byref(d))
    n.nvmlDeviceSetGpcClkVfOffset(d, ctypes.c_int(0))
    n.nvmlDeviceSetMemClkVfOffset(d, ctypes.c_int(0))
n.nvmlShutdown()
PY

# Verificacion: el ajuste no vale hasta que se comprueba que quedo puesto.
fallo=0
for i in "${IDX[@]}"; do
  w=$(nvidia-smi -i "$i" --query-gpu=enforced.power.limit --format=csv,noheader,nounits)
  if (( ${w%.*} != LIMIT_W )); then
    echo "GPU$i: limite ${w}W, esperado ${LIMIT_W}W" >&2
    fallo=1
  fi
done

# Relojes maximos iguales entre tarjetas: la asimetria crea un rezagado en multi-GPU.
distintos=$(nvidia-smi --query-gpu=clocks.max.sm,clocks.max.memory --format=csv,noheader | sort -u | wc -l)
if (( distintos > 1 )); then
  echo "GPU con relojes maximos distintos:" >&2
  nvidia-smi --query-gpu=index,clocks.max.sm,clocks.max.memory --format=csv >&2
  fallo=1
fi

exit "$fallo"
