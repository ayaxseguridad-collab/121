#!/usr/bin/env bash
# Abre el puerto del CRM en el firewall para poder entrar desde otras
# máquinas de la red interna. Pide la contraseña de administrador.

PUERTO=3200
IP=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)

echo
echo "  Voy a abrir el puerto $PUERTO en el firewall de esta máquina."
echo "  Te va a pedir tu contraseña de administrador."
echo

if command -v pkexec >/dev/null && [ -n "$DISPLAY" ]; then
  pkexec ufw allow "$PUERTO"/tcp || sudo ufw allow "$PUERTO"/tcp
else
  sudo ufw allow "$PUERTO"/tcp
fi

echo
echo "Comprobando..."
if sudo -n ufw status 2>/dev/null | grep -q "$PUERTO" || pkexec ufw status 2>/dev/null | grep -q "$PUERTO"; then
  echo "  ✓ El puerto quedó abierto."
else
  echo "  (no pude releer el estado del firewall, probá igual desde la otra máquina)"
fi

echo
echo "  Desde otra PC o del celular, entrá a:"
echo
echo "      http://$IP:$PUERTO"
echo
echo "  Si no entra, puede ser que esta máquina virtual esté en modo NAT."
echo "  En ese caso hay que ponerla en 'Adaptador puente' en VirtualBox."
echo
read -r -p "Enter para cerrar..."
