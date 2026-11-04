#!/usr/bin/env bash
# 01-incus-base.sh — Instala Incus + crea pool btrfs en POOL_DISK + red NAT.
# ACCIÓN DESTRUCTIVA: la seguridad vive EN ESTE SCRIPT (invocable suelto), no solo en el orquestador.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

[ "$(id -u)" -eq 0 ] || tc_die "01-incus-base requiere root (sudo)."
# Dos modos MUTUAMENTE EXCLUYENTES:
#   --disk /dev/XXX        -> pool btrfs sobre disco dedicado (formatea el device; guardas abajo)
#   --pool-size NNGiB      -> pool btrfs loop-backed gestionado por Incus (maquinas sin disco
#                             secundario; el archivo vive bajo /var/lib/incus y se re-monta solo)
if [ -n "${POOL_LOOP_SIZE:-}" ] && [ -n "${POOL_DISK:-}" ]; then
  tc_die "POOL_DISK y POOL_LOOP_SIZE son mutuamente excluyentes: usa --disk O --pool-size."
fi
if [ -z "${POOL_LOOP_SIZE:-}" ]; then
  [ -n "${POOL_DISK:-}" ] || tc_die "ni POOL_DISK ni POOL_LOOP_SIZE definidos. Usa disk-scan.sh y pasa --disk /dev/XXX, o --pool-size NNGiB si la maquina no tiene disco secundario (nunca auto-elige)."
  DISK="$POOL_DISK"
  [ -b "$DISK" ] || tc_die "$DISK no es un block device."
  tc_say "FASE 1 — BASE INCUS (disco $DISK)"
else
  DISK=""
  tc_say "FASE 1 — BASE INCUS (pool loop-backed $POOL_LOOP_SIZE)"
  # Guarda del modo loop: espacio libre suficiente en el FS que alojara el archivo
  # (/var/lib/incus; antes de instalar incus se mide su padre existente) + margen de 20G.
  _need_g="$(printf '%s' "$POOL_LOOP_SIZE" | grep -oE '^[0-9]+')"
  _avail_g="$(df -BG --output=avail /var/lib 2>/dev/null | tail -1 | tr -dc '0-9')"
  [ -n "$_avail_g" ] || tc_die "no pude medir el espacio libre en /var/lib."
  [ "$_avail_g" -ge $(( _need_g + 20 )) ] || tc_die "ABORTO: /var/lib tiene ${_avail_g}G libres; se necesitan ${_need_g}G del pool + 20G de margen."
fi

# Guardas destructivas SOLO en modo disco (el modo loop no formatea ningún device).
if [ -n "$DISK" ]; then
  # --- GUARDAS DESTRUCTIVAS (a nivel script) ---
  # Resolver los discos físicos que respaldan / /boot /boot/efi (cubre LVM/LUKS/md/dm-crypt:
  # findmnt da /dev/mapper/...; lsblk -s sube por los padres hasta el disco físico real).
  # Aborta si $DISK (o su disco padre, si $DISK es una partición) coincide con alguno.
  # lsblk -s pinta arte de árbol (└─/├─) pegado al nombre; se limpia a [alnum] (nombres de disco: sda/nvme0n1/vda).
  _base_disks_of_dev() { lsblk -nso NAME,TYPE "$1" 2>/dev/null | awk '{n=$1; gsub(/[^[:alnum:]]/,"",n); if($2=="disk") print "/dev/"n}'; }
  sys_bases="$( for mp in / /boot /boot/efi; do
      s="$(findmnt -nro SOURCE --target "$mp" 2>/dev/null || true)"
      [ -n "$s" ] && _base_disks_of_dev "$s"
    done | sort -u )"
  disk_bases="$(_base_disks_of_dev "$DISK")"; [ -z "$disk_bases" ] && disk_bases="$DISK"
  for sd in $sys_bases; do
    for db in $disk_bases; do
      [ "$sd" = "$db" ] && tc_die "ABORTO: $DISK respalda / , /boot o /boot/efi del host vivo (disco físico $sd, posible LVM/LUKS). Nunca formatear el disco del sistema."
    done
  done

  # montado (él mismo o hijos)
  if lsblk -no MOUNTPOINTS "$DISK" | grep -q .; then tc_die "ABORTO: $DISK o sus particiones están montados."; fi

  # tamaño mínimo
  size_g=$(( $(lsblk -dnbo SIZE "$DISK") / 1000000000 ))
  [ "$size_g" -ge "$MIN_DISK_GB" ] || tc_die "ABORTO: $DISK tiene ${size_g}GB (< ${MIN_DISK_GB}GB)."

  # tipo y particiones
  dtype="$(lsblk -dno TYPE "$DISK")"
  nparts=$(lsblk -no NAME "$DISK" | tail -n +2 | wc -l)
  if [ "$dtype" = "disk" ] && [ "$nparts" -gt 0 ]; then
    if [ "${TC_ALLOW_PARTITIONED:-no}" != "yes" ]; then
      tc_die "ABORTO: $DISK es un disco CON $nparts particiones (puede contener datos aunque estén desmontadas). Rechazado por defecto. Para forzar: TC_ALLOW_PARTITIONED=yes + confirmación extra."
    fi
    tc_info "AVISO: vas a formatear un disco con particiones."
    tc_confirm_exact "BORRAR $DISK" "Confirma escribiendo exactamente" || tc_die "ABORTO: confirmación de particiones no coincide."
  fi

  # empty-check raw-aware: si hay FS directo, montar -o ro y verificar vacío
  fstype="$(lsblk -dno FSTYPE "$DISK" 2>/dev/null || true)"
  if [ -n "$fstype" ]; then
    tmpm="$(mktemp -d)"
    if mount -o ro "$DISK" "$tmpm" 2>/dev/null; then
      cnt=$(find "$tmpm" -mindepth 1 -maxdepth 1 ! -name 'lost+found' | wc -l)
      umount "$tmpm"; rmdir "$tmpm"
      [ "$cnt" -eq 0 ] || tc_die "ABORTO: $DISK tiene un FS '$fstype' con $cnt entradas (no vacío)."
      tc_info "FS '$fstype' presente pero vacío."
    else
      rmdir "$tmpm" 2>/dev/null || true
      # FS declarado pero NO montable read-only: puede ser LUKS/BitLocker/cifrado/FS con datos.
      # ABORTO por defecto (no asumir reformateable). Override muy explícito + confirmación extra.
      if [ "${TC_ALLOW_UNMOUNTABLE_FS:-no}" = "yes" ]; then
        tc_info "AVISO: $DISK declara FS '$fstype' NO montable. Override TC_ALLOW_UNMOUNTABLE_FS=yes activo."
        tc_confirm_exact "BORRAR FS $fstype EN $DISK" "FS no montable (posible LUKS/BitLocker/cifrado con datos). Confirma escribiendo exactamente" \
          || tc_die "ABORTO: confirmación de FS no montable no coincide."
      else
        tc_die "ABORTO: $DISK declara FS '$fstype' pero NO es montable read-only (posible LUKS/BitLocker/cifrado/FS con datos). Rechazado por defecto para no destruir datos. Para forzar: TC_ALLOW_UNMOUNTABLE_FS=yes + confirmación extra."
      fi
    fi
  else
    # Sin FSTYPE declarado ≠ vacío: puede haber firmas persistentes (LUKS/LVM/RAID/tabla de
    # particiones) sin montar. wipefs -n (dry-run, no borra) las detecta; si hay, confirmación extra.
    if wipefs -n "$DISK" 2>/dev/null | grep -q .; then
      tc_info "AVISO: $DISK sin FS directo pero CON firmas persistentes (wipefs -n):"
      wipefs -n "$DISK" 2>/dev/null || true
      tc_confirm_exact "BORRAR FIRMAS EN $DISK" "Firmas persistentes detectadas (posible LUKS/LVM/RAID/tabla de particiones). Confirma escribiendo exactamente" \
        || tc_die "ABORTO: confirmación de firmas persistentes no coincide."
    else
      tc_info "Sin FS directo ni firmas persistentes (disco raw limpio)."
    fi
  fi

  # CONFIRMACIÓN FINAL re-tecleando el device (no basta CONFIRM_FORMAT heredable)
  [ "${CONFIRM_FORMAT:-}" = "yes" ] || tc_info "(sugerencia: exporta CONFIRM_FORMAT=yes además de la confirmación interactiva)"
  tc_confirm_exact "$DISK" "Vas a FORMATEAR (${size_g}GB) — re-teclea el device exacto" \
    || tc_die "ABORTO: el device tecleado no coincide. Nada formateado."
fi

# --- Instalación + pool ---
export DEBIAN_FRONTEND=noninteractive
tc_say "[1/4] Instalar incus + btrfs-progs"
apt-get update -qq
# Paquete nativo del repo Ubuntu (rama Incus 6.0 LTS) a propósito, NO el repo Zabbly (rama 7.x
# vigente con UI web). El caso de uso (contenedores unprivileged + btrfs + NAT) está cubierto
# por 6.0 LTS; adoptar Zabbly es decisión de lead pendiente — ver references/03-golden.md §Vigencias.
apt-get install -y -qq incus btrfs-progs

tc_say "[2/4] Añadir $HOST_USER a incus-admin"
usermod -aG incus-admin "$HOST_USER"
tc_info "grupos: $(id -nG "$HOST_USER")  (aplica tras nuevo login; en esta sesión root usa incus)"

tc_say "[3/4] Crear pool btrfs '$POOL' + red NAT '$BRIDGE'"
# Preflight de estado Incus ANTES de tocar nada: si el preseed fuese a chocar con un
# pool/red preexistentes, fallaría DESPUÉS del wipefs y dejaría el disco borrado sin pool.
_skip_init=no
if incus storage show "$POOL" >/dev/null 2>&1; then
  _src="$(incus storage get "$POOL" source 2>/dev/null || true)"
  if [ -n "$DISK" ]; then
    [ "$_src" = "$DISK" ] || tc_die "ABORTO: ya existe el pool '$POOL' con source '$_src' (≠ $DISK). Resuélvelo antes (incus storage delete/rename) — no se toca el disco."
    tc_info "pool '$POOL' ya existe sobre $DISK — se conserva (no se re-formatea ni re-inicializa)."
  else
    case "$_src" in
      /var/lib/incus/*) tc_info "pool '$POOL' loop-backed ya existe ($_src) — se conserva.";;
      *) tc_die "ABORTO: ya existe el pool '$POOL' con source '$_src' (no loop-backed). Resuélvelo antes — no se toca nada.";;
    esac
  fi
  _skip_init=yes
elif incus network show "$BRIDGE" >/dev/null 2>&1; then
  tc_die "ABORTO: ya existe la red '$BRIDGE' pero no el pool '$POOL' (estado Incus a medias): el preseed chocaría a medio camino. Resuélvelo antes."
fi
if [ "$_skip_init" = no ]; then
if [ -n "$DISK" ]; then
# [CR #790 Major] Re-validación anti-TOCTOU al filo del borrado irreversible: entre el preflight
# (chequeos de montaje/firmas, arriba) y este punto median las comprobaciones de idempotencia del
# pool/red, dejando una ventana en la que $DISK pudo montarse. Re-chequear montaje AQUÍ (última
# oportunidad) evita `wipefs -a` sobre un FS que se montó tras el preflight. Las firmas persistentes
# ya se gatearon con confirmación explícita arriba (re-abortar por firmas rompería ese camino querido).
if lsblk -no MOUNTPOINTS "$DISK" | grep -q .; then
  tc_die "ABORTO (TOCTOU): $DISK o sus particiones se montaron entre el preflight y el wipe — no se formatea nada."
fi
wipefs -a "$DISK"
incus admin init --preseed <<YAML
config: {}
networks:
- name: $BRIDGE
  type: bridge
  config:
    ipv4.address: auto
    ipv6.address: none
storage_pools:
- name: $POOL
  driver: btrfs
  config:
    source: $DISK
profiles:
- name: default
  devices:
    eth0: {name: eth0, network: $BRIDGE, type: nic}
    root: {path: /, pool: $POOL, type: disk}
YAML
else
# Loop-backed: sin source — Incus crea y gestiona el archivo (size=) bajo /var/lib/incus/disks
# y lo re-adjunta solo en cada arranque (a diferencia de un losetup manual).
incus admin init --preseed <<YAML
config: {}
networks:
- name: $BRIDGE
  type: bridge
  config:
    ipv4.address: auto
    ipv6.address: none
storage_pools:
- name: $POOL
  driver: btrfs
  config:
    size: $POOL_LOOP_SIZE
profiles:
- name: default
  devices:
    eth0: {name: eth0, network: $BRIDGE, type: nic}
    root: {path: /, pool: $POOL, type: disk}
YAML
fi
fi

tc_say "[4/4] Verificación"
incus storage list
incus network list
echo "✅ FASE 1 COMPLETA. Pool '$POOL' (btrfs) en ${DISK:-loop-backed $POOL_LOOP_SIZE}, red NAT '$BRIDGE'."
