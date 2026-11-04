#!/usr/bin/env bash
# El CRM corre como servicio y arranca solo con la máquina.
# Este script queda para manejarlo a mano si hace falta.
case "$1" in
  parar)     systemctl --user stop crm-atencion    ; echo "CRM detenido" ;;
  arrancar)  systemctl --user start crm-atencion   ; echo "CRM arrancado" ;;
  reiniciar) systemctl --user restart crm-atencion ; echo "CRM reiniciado" ;;
  registro)  tail -40 "$(dirname "$0")/datos/servicio.log" ;;
  *)
    systemctl --user status crm-atencion --no-pager | head -12
    echo
    echo "  Panel: http://localhost:3200"
    echo "  Opciones: $0 [arrancar|parar|reiniciar|registro]"
    ;;
esac
