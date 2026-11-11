#!/usr/bin/env bash
# instalar-unidades.sh — unidades PERSISTENTES de usuario del medidor (talent-medidor, F1).
#
# Uso:  instalar-unidades.sh --solo recolector [--destino <dir>] [--sin-activar]
#
#   --solo recolector   única unidad de esta fase: talent-medidor-recolector.{service,timer}
#                       (el tick cada 5 min). Las de F2-F5 llegarán con su propia issue.
#   --destino <dir>     directorio de unidades (defecto ~/.config/systemd/user)
#   --sin-activar       escribe las unidades y NO llama a systemctl (lo usan los tests)
#
# El primer volcado de un historial grande NO va por el timer: se hace a mano, una vez, con
# `recolector.py --bootstrap`, que se relanza solo bajo `nice -n 19`.
# rc 0 instalado · 2 uso incorrecto o fallo al escribir/activar.
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
solo=""; destino="${HOME}/.config/systemd/user"; activar=si
while [ $# -gt 0 ]; do
  case "$1" in
    --solo) [ $# -ge 2 ] || { echo "uso: --solo sin valor" >&2; exit 2; }; solo="$2"; shift 2 ;;
    --destino) [ $# -ge 2 ] || { echo "uso: --destino sin valor" >&2; exit 2; }; destino="$2"; shift 2 ;;
    --sin-activar) activar=no; shift ;;
    *) echo "instalar-unidades: flag desconocida: $1" >&2; exit 2 ;;
  esac
done
[ "$solo" = recolector ] || { echo "instalar-unidades: en F1 solo existe --solo recolector" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "instalar-unidades: python3 ausente" >&2; exit 2; }

mkdir -p -- "$destino" || exit 2
python="$(command -v python3)"

cat > "$destino/talent-medidor-recolector.service" <<EOF || exit 2
[Unit]
Description=talent-medidor: tick incremental del recolector de uso

[Service]
Type=oneshot
Nice=10
ExecStart=$python -B $AQUI/recolector.py --tick
EOF

cat > "$destino/talent-medidor-recolector.timer" <<'EOF' || exit 2
[Unit]
Description=talent-medidor: tick del recolector cada 5 minutos

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=talent-medidor-recolector.service

[Install]
WantedBy=timers.target
EOF

echo "unidades escritas en $destino: talent-medidor-recolector.service, talent-medidor-recolector.timer"
if [ "$activar" = si ]; then
  systemctl --user daemon-reload || exit 2
  systemctl --user enable --now talent-medidor-recolector.timer || exit 2
  echo "timer activado"
else
  echo "sin activar (--sin-activar): ninguna llamada a systemctl"
fi
