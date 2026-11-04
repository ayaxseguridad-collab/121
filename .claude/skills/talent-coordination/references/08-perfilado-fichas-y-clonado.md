# 08 — Perfilado de la flota, fichas de carril y clonado

Cómo caracterizar el hardware de cada máquina de la flota, generar su manual de
aprovechamiento (fichas + auto-identificación) y clonar una máquina ya
configurada a otra del mismo hardware (dual-boot). El output canónico del método
vive en `docs/carriles/` (patrón TAL-1482), no en este skill; aquí queda el
procedimiento reproducible y sus gotchas.

## Table of Contents

1. [Perfilar el hardware](#1-perfilar-el-hardware)
2. [Benchmark DEV / ASR / OPS](#2-benchmark-dev--asr--ops)
3. [Roster + normalización 0–100](#3-roster--normalización-0100)
4. [Renumeración](#4-renumeración)
5. [Fichas + auto-identificación](#5-fichas--auto-identificación)
6. [Clonado de una máquina (dual-boot)](#6-clonado-de-una-máquina-dual-boot)
7. [Validación de este material (el CI NO cubre `.claude/**`)](#7-validación-de-este-material-el-ci-no-cubre-claude)
8. [HOST-GUARD en clonado y perfilado](#8-host-guard-en-clonado-y-perfilado)

---

```text
Flujo del método (extremo a extremo):

  1. PERFILAR           2. BENCHMARK          3. ROSTER
  hw-probe.sh en    →    carril-bench.mjs →    normalizar 0-100
  cada máquina            (DEV/ASR/OPS)         por eje + GENERAL
  (CPU/RAM/GPU/disco)     como ARCHIVO,          ponderado
                          nunca retecleado

        │                                              │
        ▼                                              ▼
  4. RENUMERACIÓN  ←────────────────────────  (si entran/salen máquinas)
  mapeo viejo→nuevo explícito (ej. E15→E10)

        │
        ▼
  5. FICHAS + AUTO-ID          6. CLONADO (dual-boot, opcional)
  docs/carriles/README.md  +   rsync FS-level → fstab/grub → identidad
  docs/carriles/E#.md          propia → smoke de arranque
  .claude/carril.local (ID)
```

## 1. Perfilar el hardware

`scripts/hw-probe.sh` — cross-platform (macOS `sysctl` / `system_profiler`,
Linux `lscpu` / `free` / `nvidia-smi`). Imprime CPU, núcleos físicos/lógicos,
RAM, GPU o acelerador y disco. Se corre en CADA máquina y el carril pega el
output al coordinador.

Gotcha lscpu locale: en un Linux con locale español `lscpu` traduce las
etiquetas (`Model name` → `Nombre del modelo`) y un parseo por etiqueta inglesa
no matchea. El script fuerza `LC_ALL=C lscpu` con fallback a `/proc/cpuinfo`.

## 2. Benchmark DEV / ASR / OPS

`scripts/carril-bench.mjs` — mide tres ejes que mapean al trabajo real del
carril:

- **DEV** = build & test: `worker_threads` multi-core + RAM (typecheck,
  bundling, suites). Throughput en Mu/s.
- **ASR** = transcripción Whisper local: RTF (real-time factor). CUDA ≫ mlx ≫ CPU.
- **OPS** = I/O ligero: fs, JSON, `spawn` (SQL, scripts, git, migraciones,
  llamadas a API externa).

Se corre en cada máquina; el carril pega el bloque JSON de resultados.

Gotcha de distribución: NO pegar el script por chat para que el carril lo
reteclee. El pegado parte líneas largas y duplica bloques (un `report`
duplicado dio SyntaxError en ~13 carriles a la vez). Se distribuye como ARCHIVO
(este `scripts/`), nunca retecleado.

## 3. Roster + normalización 0–100

Con los datos crudos se construye el roster y se normaliza cada eje a 0–100
(100 = la mejor máquina medida en ese eje, no un máximo teórico). Si se necesita
un único número, GENERAL ponderado (p. ej. `0.5·DEV + 0.2·ASR + 0.3·OPS`), pero
el reparto usa los tres ejes por separado: una máquina puede ser top en ASR
(GPU) y floja en DEV, y se asigna en consecuencia.

## 4. Renumeración

Si entran o salen máquinas, renumerar con una regla EXPLÍCITA y un mapeo
viejo→nuevo escrito (ejemplo real: «E15→E10; viejas E10–E14 suman +1; E1–E9
igual»). El ID de carril (`E#`) es independiente del hostname del SO: una
máquina puede ser el carril `E10` y llamarse `vibecoder-10`.

## 5. Fichas + auto-identificación

Output en `docs/carriles/` (entra por un PR de docs, separado de este skill):

- `README.md` — inventario, tabla de scores, mapeo de renumeración, reparto y
  una ficha por máquina.
- `E#.md` — ficha individual: hardware, perfil medido, config
  (`--max-old-space-size`, `--workers`, transcripción local vs proveedor),
  reparto y una nota de credenciales (QUÉ token usa la máquina, nunca el valor).

Auto-identificación: cada máquina PUEDE tener `.claude/carril.local` (gitignored,
SOLO el ID). Al inicio de sesión, si existe, el agente carga
`docs/carriles/<ID>.md` y aplica su presupuesto antes de trabajar; si no existe,
continúa sin perfil (no es error). El mecanismo se declara en `CLAUDE.md`,
`AGENTS.md` y `.github/copilot-instructions.md`. Los valores de las credenciales
van por entorno/escrow, NUNCA en la ficha; la ficha solo nombra QUÉ token usa la
máquina.

En las fichas se usa vocabulario neutro («agente», «carril»), nunca el nombre
comercial de una herramienta (regla 2 del proyecto).

## 6. Clonado de una máquina (dual-boot)

Para replicar una máquina ya configurada (golden image) en otra del MISMO
hardware sin reinstalar el entorno: clonar el filesystem a nivel FS —no `dd` de
disco si hay que preservar otro SO en el destino— y dejar dual-boot.

Origen `E_src` ya configurada, destino con espacio libre:

1. **(SO existente del destino, p. ej. Windows)** Encoger su partición desde el
   propio SO (Fast Startup off + cifrado suspendido), dejar espacio sin asignar.
2. **(live USB Linux en el destino)** Diagnóstico: `lsblk -f`, `parted -l`,
   `ip -br a`. Confirmar disco interno, hueco y que cae en la misma LAN que el
   origen.
3. Crear + formatear la partición destino (ext4); anotar su UUID.
4. **rsync FS-level** por LAN (`-aAXH --numeric-ids -x`), con sshd TEMPORAL en el
   origen y Docker/Supabase PARADOS (si no, se clona Postgres inconsistente).
5. Montar destino + binds (`/dev /dev/pts /proc /sys /run`) + la ESP; reescribir
   `/etc/fstab` con los UUID del DESTINO (root + EFI).
6. chroot + `grub-install --target=x86_64-efi` + `update-grub` (os-prober
   detecta el otro SO → menú dual-boot).
7. **Identidad única**: hostname propio, vaciar `/etc/machine-id`, regenerar las
   SSH host keys. El usuario/contraseña de login SÍ se heredan (mismo
   `/etc/shadow` clonado).
8. **Credenciales propias**: NO heredar los tokens del origen (se revocan entre
   sí); reinyectar los del destino tras el primer arranque.
9. Crear swapfile si el origen lo tenía y el `-x` del rsync no lo copió.
10. Reboot → verificar que arrancan ambos SO + smoke del stack (node, git, repo).
11. Limpieza del origen: apagar sshd temporal, revocar el sudoers, reactivar
    Docker.

### Gotchas del clonado (aprendidos en caliente)

- **El terminal del live se come `;` / comillas / multilínea al pegar** →
  comandos ATÓMICOS de una línea, sin `;` ni comillas. Un `for … done` o un
  `a; b; c` pegado se parte y se ejecuta a medias.
- **`mount --bind` NO es recursivo** → los submounts (`/dev/pts`,
  `/sys/firmware/efi/efivars`) se montan aparte. Sin `efivars`, `grub-install`
  avisa «EFI variables cannot be set» y NO escribe la NVRAM → el firmware no ve
  el nuevo SO. Montar `efivars` y reinstalar GRUB.
- **initramfs stale tras corregir el fstab** → el initramfs del origen lleva el
  layout viejo grabado (systemd-en-initramfs monta por UUID). Tras cambiar el
  fstab, `update-initramfs -u -k all` SIEMPRE, o el arranque cae en
  `emergency mode` buscando el UUID viejo de la EFI.
- **El USB live se saca DESPUÉS del poweroff, nunca con el live corriendo** → el
  sistema live corre DESDE el USB (squashfs); extraerlo en caliente provoca
  `SQUASHFS error -5` y «Failed to execute shutdown binary».
- **Montar el clon por UUID, no por `/dev/sdaX`** → en un live nuevo las letras
  de disco pueden permutar (el USB puede salir `sda`); montar por UUID monta
  SIEMPRE la partición correcta.
- **sudoers NOPASSWD temporal de mínimo privilegio** → acotado a `/usr/bin/rsync`
  (no `ALL`), creado solo para la ventana del clon y revocado al acabar
  (`rm /etc/sudoers.d/clone-rsync`). Preferible: clave SSH dedicada de un uso.

## 7. Validación de este material (el CI NO cubre `.claude/**`)

El pipeline de CI ignora `.claude/**` (markdownlint vía `.markdownlint-cli2.jsonc`,
lychee vía `.lychee.toml`, y Trivy excluye `.claude`). Validar a mano:

- markdownlint: desde FUERA del repo (p. ej. `/tmp`) y con `--config` apuntando a
  las REGLAS base (`.markdownlint.json`), NO a `.markdownlint-cli2.jsonc` (que
  incluye el ignore de `.claude/**` → lintaría 0 archivos = verde FALSO):
  `repo="$PWD"; (cd /tmp && npx markdownlint-cli2 --config "$repo/.markdownlint.json" "$repo/.claude/skills/talent-coordination/**/*.md")`.
- shell: `shellcheck .claude/skills/talent-coordination/scripts/hw-probe.sh`.
- node: `node -c .claude/skills/talent-coordination/scripts/carril-bench.mjs`.
- secretos: un `grep -rEni` sobre los prefijos de credencial del proyecto
  (claves de proveedores —Supabase, GitHub, AWS, modelos—, `service-role`, contraseñas, etc.)
  negado con `!` para que el check FALLE ante cualquier match. NO `gitleaks ||
  grep`: el `||` corre el grep cuando gitleaks falla y grep devuelve `0` al
  hallar match → verde falso.
- infraestructura por RUTA ABSOLUTA o `command -v`, nunca por nombre suelto en
  `PATH`: antes de censar una herramienta como presente, resolverla con su ruta
  canónica (`/usr/bin/<tool>`, p. ej. `/usr/bin/incus`) o `command -v <tool>` y
  leer QUÉ resuelve. Un binario *shimmeado* —un wrapper del mismo nombre situado
  antes en el `PATH`— responde "instalado" sin serlo y da un censo verde FALSO,
  mismo registro que el `--config` que linta 0 archivos: la herramienta
  "responde", pero no es la que crees. Detalle del HOST-GUARD completo en §8.

## 8. HOST-GUARD en clonado y perfilado

Doctrina de verificación de identidad (herramienta y máquina destino) antes de
actuar, aplicable a cualquier operación de este skill que toque una máquina
remota o cree binarios/scripts en un PATH compartido por varias
sesiones/agentes (perfilado §1-2, clonado §6):

- **PROHIBIDO** crear un binario/script con el MISMO NOMBRE que una
  herramienta de sistema (`git`, `ssh`, `incus`, `rsync`, etc.) en un PATH
  compartido. Un wrapper legítimo se llama DISTINTO (p. ej. `rsync-carril05`)
  y vive en la config privada de la máquina — nunca delante en el PATH de la
  herramienta real.
- Toda verificación de que una herramienta "está instalada" resuelve por RUTA
  ABSOLUTA (`/usr/bin/rsync`) o `command -v <tool>` primero — nunca confiar en
  que el nombre en PATH es el binario esperado (ver gotcha de §7: un shim
  responde "instalado" sin serlo).
- Antes de CUALQUIER comando contra una máquina remota (el rsync/ssh del
  clonado, §6): assert explícito de que el hostname/IP destino es el
  esperado — nunca asumir por el orden de `lsblk`/`ip -br a` de una sesión
  anterior — y prefijo ssh explícito y visible en cada comando remoto (nunca
  un alias ambiguo que oculte el destino real).
- Scope CREATE-ONLY salvo orden explícita con lista nominal: la partición/
  filesystem de destino se CREA (mkfs, mount, escritura del clon) — y **`mkfs`
  cuenta como DESTRUCTIVO salvo sobre un target RECIÉN CREADO Y VERIFICADO en
  esta misma operación** (la partición que este mismo flujo acaba de crear,
  verificada por identidad — device/UUID/tamaño — antes de formatear). Un
  `mkfs` sobre una partición o filesystem PREEXISTENTE destruye su contenido
  igual que un borrado → requiere **GO nominal explícito del lead citando el
  device exacto**, igual que borrar algo que no se acaba de crear (una
  partición existente, un volumen de otra máquina) — nunca "limpieza"
  implícita de un script ni un mkfs "porque el destino parecía vacío".

Esta es la versión GENERAL del HOST-GUARD que en flotas Incus (`talent-channels`,
`talent-channel-operation`, `talent-orchestrator`) protege contenedores en vez de
particiones/filesystems bare-metal — mismo principio (verificar antes de
actuar, nunca confiar en el nombre o el orden), aplicación distinta según si la
"máquina" es un contenedor o hardware físico. Este skill NO opera flota Incus
(ver Deslinde en `SKILL.md`); la doctrina específica de contenedores vive
primero en esos skills hermanos.
