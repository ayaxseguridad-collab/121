# 02 — Disco y pool (acción destructiva)

## Table of Contents

- [Elegir disco](#elegir-disco)
  - [Una partición también vale como `POOL_DISK`](#una-partición-también-vale-como-pool_disk)
- [Guardas del script (todas obligatorias antes de `wipefs`)](#guardas-del-script-todas-obligatorias-antes-de-wipefs)
- [Pool + red](#pool--red)
- [Fix Docker↔Incus (`01b-network-fix.sh`)](#fix-docker↔incus-01b-network-fixsh)

`scripts/01-incus-base.sh` instala Incus + crea el pool **btrfs** en `POOL_DISK` + red NAT. Es **destructivo** (formatea), así que la seguridad vive **en el propio script** (no solo en el orquestador), porque es invocable suelto.

## Elegir disco

`sudo bash scripts/disk-scan.sh` (READ-ONLY, nunca formatea) lista discos y marca: `NO (root/boot)`, `NO (montado)`, `NO (<MIN_DISK_GB)`, `REVISAR (tiene particiones)`, o `candidato`.

### Una partición también vale como `POOL_DISK`

No hace falta un disco entero dedicado: `POOL_DISK` puede ser una **partición** (`/dev/sda2`, `/dev/nvme0n1p7`, …). La guarda "disco con particiones → rechazado" solo aplica a `TYPE=disk`; una partición (`TYPE=part`) sin FS pasa el empty-check como raw. Útil cuando solo puedes ceder espacio de un disco con datos: encoge un FS existente y crea una partición nueva para el pool. Patrón seguro de cirugía (preservando datos): `e2fsck -f` → `resize2fs <partición-con-FS> <menor>` (encoge FS **antes** que la partición) → recrear la partición con **mismo sector de inicio** (`sgdisk`/`parted`) → `resize2fs` sin tamaño (rellena) → crear la partición del pool en el hueco. Haz backup de la tabla GPT (`sfdisk -d`/`sgdisk --backup`) antes.

## Guardas del script (todas obligatorias antes de `wipefs`)

- `POOL_DISK` **explícito** (`--disk /dev/X`); nunca auto-elige.
- Rechaza disco de `/` o `/boot`, y cualquier device con él mismo o sus hijos **montados**.
- Tamaño ≥ `MIN_DISK_GB` (default 100).
- **Disco con particiones → RECHAZADO por defecto** (puede tener datos aunque desmontadas). Override: `TC_ALLOW_PARTITIONED=yes` + confirmación re-tecleando `BORRAR /dev/X`.
- **Empty-check raw-aware**: si hay FS, monta `-o ro` y exige vacío (≠ lost+found). FS declarado **NO montable** (posible LUKS/BitLocker/cifrado con datos) → rechazado por defecto; override `TC_ALLOW_UNMOUNTABLE_FS=yes` + confirmación extra.
- **Rechazo de firmas persistentes**: un device "crudo" (sin FS montable ni particiones) puede conservar metadatos LUKS/LVM/RAID/tabla de particiones sin estar montado. `wipefs -n` (dry-run) los detecta antes de autorizar el formateo; si hay firmas, exige confirmación extra re-tecleando `BORRAR FIRMAS EN /dev/X`.
- **Confirmación final**: re-teclear el device exacto. `CONFIRM_FORMAT=yes` no basta solo (heredable).

## Pool + red

`incus admin init --preseed` crea pool `$POOL` (btrfs, source=`$POOL_DISK`) + bridge `$BRIDGE` (NAT) + profile default. Añade `$HOST_USER` a `incus-admin` (aplica tras re-login; en la sesión, root usa incus).

## Fix Docker↔Incus (`01b-network-fix.sh`)

Docker fuerza iptables `FORWARD` a DROP → sin esto los contenedores no salen a internet. Añade `FORWARD -i/-o $BRIDGE ACCEPT` + servicio `incus-forward.service` (persistente). Correr **siempre tras 01** y antes del golden.
