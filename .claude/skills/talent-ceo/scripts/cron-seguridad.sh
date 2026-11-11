#!/usr/bin/env bash
# Emite la fila DIARIA del modo escritor del doctor (`doctor.sh --seguridad`); no modifica crontab. La instala el
# montaje (F6) con install_cron, igual que la fila semanal de cron-modelos.sh. 04:11 (hora baja), con nice e ionice.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  --linea) [ $# -eq 1 ] || exit 2 ;;
  *) echo 'uso: cron-seguridad.sh --linea (TA_BUS, TA_BUS_STATE_DIR, TA_BUS_LOCK y TA_PERFIL requeridos)' >&2; exit 2 ;;
esac
extra=''
for value in "${TA_BUS:-}" "${TA_BUS_STATE_DIR:-}" "${TA_BUS_LOCK:-}" "${TA_PERFIL:-}" "${TF_MANIFEST:-/ausente}" "$HERE"; do
  case "$value" in /*) : ;; *) echo 'ERROR cron: rutas absolutas requeridas' >&2; exit 2 ;; esac
  case "$value" in *%*|*[[:cntrl:]]*) echo 'ERROR cron: carácter no permitido en ruta' >&2; exit 2 ;; esac
done
if [ -n "${TF_MANIFEST:-}" ]; then
  printf -v extra ' TF_MANIFEST=%q TCO_TF_MANIFEST=%q' "$TF_MANIFEST" "${TCO_TF_MANIFEST:-$TF_MANIFEST}"
fi
printf 'SHELL=/bin/bash\n11 4 * * * TA_BUS=%q TA_BUS_STATE_DIR=%q TA_BUS_LOCK=%q TA_PERFIL=%q%s nice -n 19 ionice -c3 bash %q --seguridad # seguridad-doctor\n' \
  "$TA_BUS" "$TA_BUS_STATE_DIR" "$TA_BUS_LOCK" "$TA_PERFIL" "$extra" "$HERE/doctor.sh"
