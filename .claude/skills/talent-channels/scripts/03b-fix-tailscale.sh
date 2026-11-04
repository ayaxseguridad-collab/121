#!/usr/bin/env bash
# 03b-fix-tailscale.sh — Parche tailscaled (userspace + --cleanup no-fatal) en un target.
# golden: parchea y detiene (no se une al tailnet). Un canal: parchea y hace 'tailscale up'.
# Uso: 03b-fix-tailscale.sh [target]   (default golden)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$HERE/../assets"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

[ "$(id -u)" -eq 0 ] || tc_die "03b requiere root (sudo)."
TARGET="${1:-$GOLDEN}"
# Fail-closed ANTES de tocar nada: un typo aquí arrancaría y reconfiguraría tailscaled en
# cualquier contenedor arbitrario. Solo se acepta el golden o un canal del contrato <x><y>.
case "$TARGET" in
  "$GOLDEN"|"$PREFIX"[0-9][0-9]) ;;
  *) tc_die "target inválido: '$TARGET' (usa '$GOLDEN' o ${PREFIX}<x><y>)" ;;
esac

tc_say "Fix tailscaled en $TARGET"
incus start "$TARGET" 2>/dev/null || true
tc_wait_container "$TARGET" || tc_die "$TARGET no arrancó."

# puerto: golden=0; canal=base+índice y del canal.
# CONTRATO de naming (00-intake.sh): canal = ${PREFIX}<x><y>, con x = nº de máquina
# (1 dígito, validado 0-9) e y = índice de canal (1 dígito, COUNT validado 1-9). El sufijo
# tras el prefijo son EXACTAMENTE 2 dígitos; y se extrae explícito como el 2º dígito, en
# vez de depender en silencio de "el último carácter del nombre".
port=0
case "$TARGET" in
  "$PREFIX"*)
    _suf="${TARGET#"$PREFIX"}"
    printf '%s' "$_suf" | grep -qE '^[0-9]{2}$' || tc_die "target '$TARGET' no cumple el contrato ${PREFIX}<x><y> (sufijo de exactamente 2 dígitos)."
    y="${_suf:1:1}"
    port="$(tc_channel_port "$y")"
    ;;
esac
incus exec "$TARGET" -- bash -c "printf 'FLAGS=\"--tun=userspace-networking\"\nPORT=\"$port\"\n' > /etc/default/tailscaled; mkdir -p /etc/systemd/system/tailscaled.service.d"
incus file push "$ASSETS/tailscaled-override.conf" "$TARGET/etc/systemd/system/tailscaled.service.d/override.conf" >/dev/null
incus exec "$TARGET" -- bash -c 'systemctl daemon-reload; systemctl reset-failed tailscaled 2>/dev/null || true; systemctl restart tailscaled'
sleep 2
incus exec "$TARGET" -- bash -c 'systemctl is-active tailscaled && (test -S /var/run/tailscale/tailscaled.sock && echo "socket OK")'

case "$TARGET" in
  "$PREFIX"*)
    tc_have_secret tailscale-authkey || tc_die "Falta tailscale-authkey."
    set +x   # [CR] antes de leer el secreto: con bash -x la asignación lo imprimiría
    AUTHKEY="$(tc_read_secret tailscale-authkey)"
    # authkey por FICHERO en UN SOLO exec atómico (stdin -> /run/tskey -> trap shred EXIT -> --auth-key=file:).
    # Sin ventana de error: si el exec ni arranca no se escribió nada; si arranca, el trap borra siempre.
    printf '%s' "$AUTHKEY" | incus exec "$TARGET" -- bash -c '
      umask 077; cat > /run/tskey
      trap "shred -u /run/tskey 2>/dev/null || rm -f /run/tskey" EXIT
      tailscale up --ssh --auth-key=file:/run/tskey --hostname="$1" --accept-dns=false' _ "$TARGET"
    unset AUTHKEY
    tc_info "IP: $(incus exec "$TARGET" -- tailscale ip -4 2>/dev/null || echo n/d)"
    ;;
  "$GOLDEN")
    incus exec "$TARGET" -- systemctl stop tailscaled 2>/dev/null || true
    incus stop "$TARGET"
    tc_info "golden parcheado y detenido (no se une al tailnet)."
    ;;
esac
echo "✅ 03b completo en $TARGET."
