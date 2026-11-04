#!/usr/bin/env bash
# enable-gpu.sh — OPCIONAL, OFF por defecto. Expone la GPU NVIDIA (compartida) a un canal a demanda.
# NO lo llama provision.sh por defecto. Uso: enable-gpu.sh <canal> | enable-gpu.sh --off <canal>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"
[ "$(id -u)" -eq 0 ] || tc_die "enable-gpu requiere root (sudo)."

OFF=no; [ "${1:-}" = "--off" ] && { OFF=yes; shift; }
CH="${1:?uso: enable-gpu.sh <canal> | --off <canal>}"
incus info "$CH" >/dev/null 2>&1 || tc_die "$CH no existe."

if [ "$OFF" = yes ]; then
  incus config device remove "$CH" gpu 2>/dev/null || true
  incus config set "$CH" nvidia.runtime=false 2>/dev/null || true
  echo "✅ GPU retirada de $CH."; exit 0
fi

tc_say "enable-gpu en $CH"
# preflight host
command -v nvidia-smi >/dev/null 2>&1 || tc_die "El host no tiene driver NVIDIA (nvidia-smi). No hay GPU que exponer."
nvidia-smi -L | head -1
# nvidia-container-toolkit (libnvidia-container) si falta
if ! dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
  tc_info "Instalando nvidia-container-toolkit (preflight)…"
  install -m 0755 -d /usr/share/keyrings
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y -qq nvidia-container-toolkit
fi
# exponer al carril (compartida; RTX consumo = sin MIG)
incus config set "$CH" nvidia.runtime=true
incus config device add "$CH" gpu gpu 2>/dev/null || tc_info "device gpu ya presente"
incus restart "$CH"; tc_wait_container "$CH" || true
tc_say "Verificación nvidia-smi dentro de $CH"
incus exec "$CH" -- nvidia-smi -L || tc_die "nvidia-smi falló dentro de $CH."
tc_info "AVISO: GPU compartida (sin MIG en RTX de consumo) — VRAM se reparte; actívala solo donde haga falta."
echo "✅ GPU expuesta a $CH (off: enable-gpu.sh --off $CH)."
