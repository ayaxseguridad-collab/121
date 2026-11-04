#!/usr/bin/env bash
# status.sh — Foto rápida (read-only): contenedores, tailnet, sesiones tmux, GPU.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

tc_say "Canales (máquina $MACHINE_NUM)"
incus list -c ns4 "$PREFIX$MACHINE_NUM" 2>/dev/null || incus list 2>/dev/null

tc_say "Tailnet"
tailscale status 2>/dev/null | grep -i "$PREFIX" || echo "  (sin nodos $PREFIX visibles)"

tc_say "GPU por canal (off por defecto)"
for y in $(seq 1 "${COUNT:-0}"); do
  ch="$(tc_channel_name "$y")"; incus info "$ch" >/dev/null 2>&1 || continue
  g="$(incus config get "$ch" nvidia.runtime 2>/dev/null)"
  echo "  $ch: GPU=${g:-off}"
done

tc_say "Sesiones tmux por canal"
for y in $(seq 1 "${COUNT:-0}"); do
  ch="$(tc_channel_name "$y")"; incus info "$ch" >/dev/null 2>&1 || continue
  s="$(incus exec "$ch" -- su - "$CUSER" -c "tmux ls 2>/dev/null" 2>/dev/null | head -1)"
  echo "  $ch: ${s:-sin sesión}"
done
