#!/usr/bin/env bash
# disk-scan.sh — READ-ONLY. Lista discos candidatos para el pool y marca seguro/no-seguro.
# NUNCA formatea ni monta en escritura. Ayuda al operador a elegir POOL_DISK.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
boot_src="$(findmnt -n -o SOURCE /boot 2>/dev/null || true)"

# Discos FÍSICOS que sostienen root/boot. findmnt devuelve el device FINAL (con LVM/mdraid/LUKS
# es /dev/mapper/vg-root, /dev/dm-0, /dev/md0…, no el disco), así que un match por substring no
# basta: `lsblk -s` (árbol inverso) lista los ANCESTROS del device y de ahí tomamos los TYPE=disk.
# Sin esto, el disco de sistema saldría como "candidato" y el operador podría wipearlo.
sys_disks=""
for src in "$root_src" "$boot_src"; do
  [ -b "$src" ] || continue
  sys_disks="$sys_disks
$(lsblk -spno NAME,TYPE "$src" 2>/dev/null | awk '$2=="disk"{print $1}')"
done

tc_say "Discos del sistema (read-only)"
lsblk -dpno NAME,SIZE,TYPE,MODEL 2>/dev/null

echo
tc_say "Candidatos para el pool (umbral ≥ ${MIN_DISK_GB} GB)"
printf '%-16s %-8s %-10s %-9s %s\n' DEVICE SIZE PARTICIONES MONTADO VEREDICTO
for dev in $(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}'); do
  size=$(lsblk -dno SIZE "$dev")
  size_g=$(lsblk -dnbo SIZE "$dev"); size_g=$(( size_g / 1000000000 ))
  nparts=$(lsblk -no NAME "$dev" | tail -n +2 | wc -l)
  mounted=$(lsblk -no MOUNTPOINTS "$dev" | grep -c . || true)
  verdict="candidato"
  # Doble check: match directo (root en partición del disco) O disco físico subyacente (LVM/mdraid/LUKS).
  if printf '%s' "$root_src $boot_src" | grep -q "$dev" \
     || printf '%s\n' "$sys_disks" | grep -qxF "$dev"; then verdict="NO (root/boot)"
  elif [ "$mounted" -gt 0 ]; then verdict="NO (montado)"
  elif [ "$size_g" -lt "$MIN_DISK_GB" ]; then verdict="NO (<${MIN_DISK_GB}GB)"
  elif [ "$nparts" -gt 0 ]; then verdict="REVISAR (tiene particiones)"
  fi
  printf '%-16s %-8s %-10s %-9s %s\n' "$dev" "$size" "$nparts" "$mounted" "$verdict"
done
echo
tc_info "Elige el device con 'provision.sh --disk /dev/XXX' (o POOL_DISK=...). 01-incus-base.sh re-pedirá confirmación tecleando el device."
tc_info "Sin disco secundario utilizable: 'provision.sh --pool-size NNGiB' crea el pool btrfs loop-backed (archivo gestionado por Incus en /var/lib/incus, sin formatear nada)."
