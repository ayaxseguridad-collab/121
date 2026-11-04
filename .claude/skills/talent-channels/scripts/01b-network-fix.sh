#!/usr/bin/env bash
# 01b-network-fix.sh — Arregla salida a internet de los contenedores cuando Docker
# fuerza la política iptables FORWARD a DROP (conflicto Docker↔Incus). Persistente.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

[ "$(id -u)" -eq 0 ] || tc_die "01b-network-fix requiere root (sudo)."
BR="$BRIDGE"

tc_say "FASE 1b — FIX DE RED (Docker↔Incus) para $BR"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
iptables -C FORWARD -i "$BR" -j ACCEPT 2>/dev/null || iptables -I FORWARD -i "$BR" -j ACCEPT
# Retorno RESTRINGIDO a conexiones ya abiertas (ESTABLISHED,RELATED): mantiene la salida a
# internet de los canales sin abrir el bridge a forwarding lateral/inbound arbitrario.
# Se retira la regla ancha legada (-o $BR ACCEPT) si quedó de una versión anterior.
iptables -D FORWARD -o "$BR" -j ACCEPT 2>/dev/null || true
iptables -C FORWARD -o "$BR" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
  || iptables -I FORWARD -o "$BR" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
tc_info "reglas FORWARD activas para $BR (salida ACCEPT; retorno solo ESTABLISHED,RELATED)"

# Servicio systemd persistente (reaplica en cada arranque, idempotente).
unit=/etc/systemd/system/incus-forward.service
cat > "$unit" <<EOF
[Unit]
Description=Allow forwarding for $BR (Docker/Incus coexistence)
After=incus.service docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '/usr/sbin/iptables -C FORWARD -i $BR -j ACCEPT 2>/dev/null || /usr/sbin/iptables -I FORWARD -i $BR -j ACCEPT'
ExecStart=/bin/sh -c '/usr/sbin/iptables -C FORWARD -o $BR -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || /usr/sbin/iptables -I FORWARD -o $BR -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT'

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now incus-forward.service
tc_info "incus-forward.service: $(systemctl is-enabled incus-forward.service)/$(systemctl is-active incus-forward.service)"
echo "✅ FASE 1b COMPLETA. Salida a internet habilitada para $BR (persistente)."
