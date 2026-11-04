#!/usr/bin/env bash
# 04-autostart.sh — Autostart escalonado de los canales tras reboot/corte de luz. golden NO.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"
[ "$(id -u)" -eq 0 ] || tc_die "04-autostart requiere root (sudo)."

tc_say "FASE 4 — AUTOSTART"
# [CR] "golden NO arranca solo" es contrato: si el golden existe y no se pudo configurar,
# fallar (el || true anterior podia reportar la fase completa con el golden auto-arrancando).
if incus info "$GOLDEN" >/dev/null 2>&1; then
  incus config set "$GOLDEN" boot.autostart false
else
  tc_die "no existe el contenedor golden: $GOLDEN (corre 02-golden.sh antes)"
fi
# Escalonado REAL: en Incus `boot.autostart.delay` es la espera DESPUÉS de arrancar esa instancia
# y ANTES de arrancar la siguiente (no un retardo del propio arranque). Con la prioridad
# decreciente fijando el orden, un delay CONSTANTE por canal produce arranques separados +8s;
# un delay incremental arrancaría los dos primeros en bloque (pico post-corte de luz).
STAGGER_S=8
priority=100
for ch in $(tc_channels); do
  incus info "$ch" >/dev/null 2>&1 || continue
  incus config set "$ch" boot.autostart true
  incus config set "$ch" boot.autostart.delay "$STAGGER_S"
  incus config set "$ch" boot.autostart.priority "$priority"
  tc_info "$ch -> autostart=$(incus config get "$ch" boot.autostart) delay=${STAGGER_S}s priority=$priority"
  priority=$((priority - 1))
done
tc_info "incus-startup: $(systemctl is-enabled incus-startup.service 2>/dev/null||echo '?') · incus.socket: $(systemctl is-enabled incus.socket 2>/dev/null||echo '?') · incus-forward: $(systemctl is-enabled incus-forward.service 2>/dev/null||echo '?')"
echo "✅ FASE 4 COMPLETA (golden=$(incus config get "$GOLDEN" boot.autostart || echo false))."
