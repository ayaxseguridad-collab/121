#!/usr/bin/env bash
# La sonda es una PUERTA: con entorno incompleto RECHAZA explicando; jamas
# autoriza una version recortada. Se prueba con PATH controlado y fakes.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SONDA="$DIR/../scripts/sonda.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKES="$TMP/bin"
mkdir -p "$FAKES"
# Fakes minimos: comandos que la sonda consulta. bash/coreutils reales via /usr/bin.
for c in git node npm python3 openssl curl ss claude systemctl docker tailscale ip getent tar cc; do
  cat > "$FAKES/$c" <<'EOF'
#!/bin/sh
case "$0" in
  */tailscale) case "$1" in ip) echo "100.100.1.2";; *) echo '{}';; esac ;;
  */docker) exit 0 ;;
  */ip) echo "" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$FAKES/$c"
done
# df es un FAKE DETERMINISTA (hallazgo 8 de la ronda de seguridad): con el
# df real, el caso "entorno completo" pasaba o fallaba segun el espacio libre
# del host — el resultado dependia del runner, no del codigo. El fake responde
# segun TB_TEST_DF: ok (espacio de sobra), poco (1 GB) o fallo (rc!=0, salida
# vacia — el caso "no medible").
cat > "$FAKES/df" <<'DFEOF'
#!/bin/sh
case "${TB_TEST_DF:-ok}" in
  ok)   printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfake 999999999 1 999999999 1%%%% /\n' ;;
  poco) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfake 999999999 1 1048576 99%%%% /\n' ;;
  fallo) exit 1 ;;
esac
DFEOF
chmod +x "$FAKES/df"

# Coreutils reales imprescindibles, via symlink — el PATH del test NO incluye
# /usr/bin entero para que "quitar un fake" signifique de verdad "no existe".
BASE="$TMP/base"
mkdir -p "$BASE"
for real in bash sh uname awk head cut tr grep sed cat mktemp dirname; do
  ln -s "$(command -v "$real")" "$BASE/$real"
done
BASE_PATH="$BASE"

fallos=0

# Caso 1: entorno completo -> AUTORIZADO
if salida=$(env -i HOME="$TMP" USER=test TMPDIR="$TMP" TB_TEST_DF=ok PATH="$FAKES:$BASE_PATH" TB_HOME="$TMP/eq" TB_MODE=tailscale bash "$SONDA" 2>&1); then
  echo "OK  caso1: autoriza con entorno completo"
else
  echo "FALLO caso1: rechazo con entorno completo:"; echo "$salida" | tail -5; fallos=$((fallos+1))
fi

# Caso 2: sin docker -> RECHAZADO y lo dice
rm "$FAKES/docker"
if salida=$(env -i HOME="$TMP" USER=test TMPDIR="$TMP" TB_TEST_DF=ok PATH="$FAKES:$BASE_PATH" TB_HOME="$TMP/eq" TB_MODE=tailscale bash "$SONDA" 2>&1); then
  echo "FALLO caso2: autorizo sin docker"; fallos=$((fallos+1))
else
  if echo "$salida" | grep -q "docker"; then
    echo "OK  caso2: rechaza sin docker y lo explica"
  else
    echo "FALLO caso2: rechaza pero sin mencionar docker"; fallos=$((fallos+1))
  fi
fi

# Caso 2b: sin cc -> RECHAZADO y lo dice (hallazgo e2e / INV-TB-027).
# docker se restaura primero: el caso debe aislar la ausencia de cc.
cat > "$FAKES/docker" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$FAKES/docker"
rm "$FAKES/cc"
if salida=$(env -i HOME="$TMP" USER=test TMPDIR="$TMP" TB_TEST_DF=ok PATH="$FAKES:$BASE_PATH" TB_HOME="$TMP/eq" TB_MODE=tailscale bash "$SONDA" 2>&1); then
  echo "FALLO caso2b: autorizo sin cc"; fallos=$((fallos+1))
else
  if echo "$salida" | grep -q "'cc'"; then
    echo "OK  caso2b: rechaza sin cc y lo explica"
  else
    echo "FALLO caso2b: rechaza pero sin mencionar cc"; fallos=$((fallos+1))
  fi
fi
cat > "$FAKES/cc" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$FAKES/cc"

# Caso 3: modo dominio sin TB_DOMAIN -> RECHAZADO
cat > "$FAKES/docker" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$FAKES/docker"
if salida=$(env -i HOME="$TMP" USER=test TMPDIR="$TMP" TB_TEST_DF=ok PATH="$FAKES:$BASE_PATH" TB_HOME="$TMP/eq" TB_MODE=dominio bash "$SONDA" 2>&1); then
  echo "FALLO caso3: autorizo modo dominio sin dominio"; fallos=$((fallos+1))
else
  echo "OK  caso3: rechaza modo dominio sin TB_DOMAIN"
fi

# Caso 4: espacio insuficiente (df determinista reporta 1 GB) -> RECHAZADO
if salida=$(env -i HOME="$TMP" USER=test TMPDIR="$TMP" TB_TEST_DF=poco PATH="$FAKES:$BASE_PATH" TB_HOME="$TMP/eq" TB_MODE=tailscale bash "$SONDA" 2>&1); then
  echo "FALLO caso4: autorizo con 1 GB libre"; fallos=$((fallos+1))
else
  if echo "$salida" | grep -q "15 GB"; then
    echo "OK  caso4: rechaza por espacio y lo dice"
  else
    echo "FALLO caso4: rechaza pero sin mencionar el espacio"; fallos=$((fallos+1))
  fi
fi

# Caso 5: medicion de espacio FALLA (df rc!=0) -> RECHAZADO como "no medible",
# distinto de "sin espacio" (fail-closed del hallazgo 8; sonda.sh lo distingue)
if salida=$(env -i HOME="$TMP" USER=test TMPDIR="$TMP" TB_TEST_DF=fallo PATH="$FAKES:$BASE_PATH" TB_HOME="$TMP/eq" TB_MODE=tailscale bash "$SONDA" 2>&1); then
  echo "FALLO caso5: autorizo sin poder medir el disco"; fallos=$((fallos+1))
else
  if echo "$salida" | grep -q "no se pudo medir"; then
    echo "OK  caso5: falla cerrado como no-medible (no como sin-espacio)"
  else
    echo "FALLO caso5: rechaza pero sin distinguir la medicion fallida"; fallos=$((fallos+1))
  fi
fi

if [ "$fallos" -eq 0 ]; then echo "probar-sonda: TODO OK"; else echo "probar-sonda: $fallos fallos"; exit 1; fi
