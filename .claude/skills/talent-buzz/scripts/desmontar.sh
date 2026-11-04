#!/usr/bin/env bash
# Desmonta el nucleo talent-buzz. Por defecto CONSERVA claves, datos Y
# usuarios (usuarios y datos viajan JUNTOS: sin --purge no se borra ninguno
# de los dos — jamas quedan datos de un UID huerfano). Con --purge borra
# volumenes Docker, unidades, datos por instancia y usuarios hermesbotN, EN
# ESE ORDEN (los datos se tratan ANTES de borrar su usuario, hallazgo M5 de
# la ronda de seguridad); con --purge --cuarentena los datos se archivan
# primero (tar 0600 de root, FUERA del arbol que se elimina). Las claves de
# $TB_KEYS_JSON NUNCA se borran desde aqui: se destruyen solo a mano.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=00-config.sh
source "$DIR/00-config.sh"

PURGE=no
CUARENTENA=no
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=yes ;;
    --cuarentena) CUARENTENA=yes ;;
    *) echo "desmontar: argumento desconocido $arg" >&2; exit 1 ;;
  esac
done
if [ "$CUARENTENA" = "yes" ] && [ "$PURGE" = "no" ]; then
  echo "desmontar: --cuarentena solo tiene sentido con --purge" >&2; exit 1
fi

sudo systemctl disable --now buzz-claude buzz-pair-relay 2>/dev/null || true
# `systemctl disable` NO expande globs (a diferencia de stop/start): hay que
# enumerar las instancias buzz-hermes@N o sobreviven al "deshabilitado" y
# vuelven a arrancar en el siguiente boot (hallazgo CodeRabbit PR #22).
mapfile -t HERMES < <(systemctl list-unit-files --plain --no-legend 'buzz-hermes@*.service' 2>/dev/null | awk '{print $1}'; systemctl list-units --all --plain --no-legend 'buzz-hermes@*.service' 2>/dev/null | awk '{print $1}')
if [ "${#HERMES[@]}" -gt 0 ]; then
  mapfile -t HERMES < <(printf '%s\n' "${HERMES[@]}" | sed '/@\.service$/d;/^$/d' | sort -u)
fi
[ "${#HERMES[@]}" -gt 0 ] && sudo systemctl disable --now "${HERMES[@]}" 2>/dev/null || true
"$TB_COMPOSE_DIR/run.sh" stop 2>/dev/null || true

if [ "$PURGE" = "yes" ]; then
  (cd "$TB_COMPOSE_DIR" && docker compose down -v) || true
  sudo rm -f /etc/systemd/system/buzz-claude.service \
             /etc/systemd/system/buzz-pair-relay.service \
             /etc/systemd/system/buzz-hermes@.service \
             "$TB_BIN_DIR/buzz-panic" \
             "$TB_BIN_DIR/buzz-publicar"
  sudo rm -rf /etc/systemd/system/buzz-hermes@.service.d
  sudo systemctl daemon-reload

  # ── Ciclo de vida de instancias hermes (M5): datos ANTES que usuarios ──────
  # Orden obligatorio: (cuarentena) -> borrar datos -> borrar usuario ->
  # verificar que no queda NADA de ese UID en las rutas gestionadas. Borrar el
  # usuario primero dejaria directorios 0700 colgando de un UID reutilizable.
  HERMES_BASE=/var/lib/buzz-hermes
  if [ -d "$HERMES_BASE" ]; then
    for d in "$HERMES_BASE"/*/; do
      [ -d "$d" ] || continue
      n="$(basename "$d")"
      usuario="hermesbot$n"
      if [ "$CUARENTENA" = "yes" ]; then
        # La cuarentena vive FUERA del arbol que se elimina; nace 0600 root.
        qdir=/var/backups/talent-buzz
        sudo install -d -m 0700 -o root -g root "$qdir"
        qfile="$qdir/hermes-$n-$(date +%Y%m%d%H%M%S).tar.gz"
        sudo tar -czf "$qfile" -C "$HERMES_BASE" "$n"
        sudo chmod 0600 "$qfile"
        echo "cuarentena: $qfile ($(sudo stat -c '%U %a' "$qfile"))"
      fi
      sudo rm -rf "$d"
      if id "$usuario" >/dev/null 2>&1; then
        uid="$(id -u "$usuario")"
        sudo userdel "$usuario" 2>/dev/null || true
        # Verificacion acotada a las rutas gestionadas por talent-buzz (no se
        # recorre / entero): nada del UID borrado puede quedar atras.
        restos="$(sudo find "$HERMES_BASE" "$TB_HOME" -xdev -uid "$uid" 2>/dev/null | head -5 || true)"
        if [ -n "$restos" ]; then
          echo "AVISO M5: quedan ficheros del UID $uid ($usuario):" >&2
          echo "$restos" >&2
          exit 1
        fi
      fi
    done
    sudo rmdir "$HERMES_BASE" 2>/dev/null || true
  fi
  # Usuario compartido de despliegues previos a la ronda de seguridad.
  id hermesbot >/dev/null 2>&1 && sudo userdel hermesbot 2>/dev/null || true
  echo "PURGADO: unidades (incl. plantilla hermes), buzz-panic, buzz-publicar, volumenes, datos por instancia y usuarios hermesbotN eliminados (datos tratados ANTES que usuarios). Claves en $TB_KEYS_JSON CONSERVADAS."
else
  echo "Parado y deshabilitado (instancias hermes incluidas). Datos, usuarios y claves conservados JUNTOS (usa --purge para borrar; --purge --cuarentena archiva antes)."
fi
