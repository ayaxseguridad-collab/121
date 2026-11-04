# 01 — Arquitectura y configuración

## Table of Contents

- [Modelo](#modelo)
- [Naming (no colisionar entre máquinas)](#naming-no-colisionar-entre-máquinas)
- [Config (`scripts/00-config.sh`, se source-ea)](#config-scripts00-configsh-se-source-ea)
  - [Flags de `provision.sh` (no-interactivo / multi-fábrica, TAL-2296)](#flags-de-provisionsh-no-interactivo--multi-fábrica-tal-2296)
  - [Multi-fábrica: convivencia de varias fábricas en un host](#multi-fábrica-convivencia-de-varias-fábricas-en-un-host)
- [Recon de gobierno del repo objetivo (onboarding) — TAL-2296](#recon-de-gobierno-del-repo-objetivo-onboarding--tal-2296)
- [Helpers (`scripts/lib.sh`)](#helpers-scriptslibsh)

## Modelo

- **Incus** (contenedores de sistema Ubuntu 24.04 **unprivileged**, comparten kernel del host).
- **Pool btrfs** en un disco dedicado → clonado **copy-on-write** (un clon ocupa ~0 hasta divergir).
- **Red NAT** (`incusbr0`): salida a internet vía el host.
- **golden** = plantilla con toda la toolchain; se clona en N `vibe-channel-<x><y>`.
- **Tailscale** (userspace) en cada canal → acceso por nombre desde el tailnet.

## Naming (no colisionar entre máquinas)

Canal = `${PREFIX}${MACHINE_NUM}${y}` → `vibe-channel-<máquina><channel>`. El skill **pregunta `MACHINE_NUM`** (0-9) en el intake. Máquina 0 → `vibe-channel-01..0N`; máquina 1 → `vibe-channel-11..1N`. Hostnames únicos globalmente en el tailnet.

## Config (`scripts/00-config.sh`, se source-ea)

- **Autodetección**: `HOST_USER`/`HOST_HOME` vía `SUDO_USER`+`getent` (rechaza root directo); `REPO_URL` = remote del repo actual (overridable); `REPO_DIR` limpio con `tc_repo_dir_from_url` (https / `git@host:org/repo` / `.git` / espacios); `tc_repo_https` para clon con token.
- **Defaults overridables**: `POOL`, `BRIDGE`, `IMG`, `GOLDEN`, `PREFIX=vibe-channel-`, `CUSER=vivecoder`, `TS_PORT_BASE=41640`, `ENV_DEST=.env.local`, `MIN_DISK_GB=100`.
- **Sin default (intake)**: `MACHINE_NUM`, `POOL_DISK`, `COUNT`, `CUSER_PASS`.
- **Escrow**: `SECRET_DIR=$HOST_HOME/.config/talent-channels` (0700); elecciones no-secretas en `$SECRET_DIR/intake.conf`.
- Helpers de naming: `tc_channel_name <y>`, `tc_channel_port <y>`, `tc_channels`.

### Flags de `provision.sh` (no-interactivo / multi-fábrica, TAL-2296)

- **`--machine N`** (0-9): fija `MACHINE_NUM` sin intake interactivo (viaja como `TC_FLAG_MACHINE` y
  gana sobre `intake.conf`, igual que `--repo`/`--count`/`--disk`).
- **`--local-only`** (`TC_LOCAL_ONLY=yes`): canales **SIN Tailscale** — no se pide `tailscale-authkey`,
  no hay `tailscale up`, se salta el fix de tailscaled del host (`golden-ts`), y `verify.sh` marca los
  ítems de tailnet como SKIP. El acceso es **local** (`incus exec` / launchers `v` con fallback local,
  gotcha 13). Útil en una sola máquina sin necesidad de acceso remoto por el tailnet.
- **`--force-golden`** (`TC_GOLDEN_FORCE=yes`): permite reconstruir un golden EXISTENTE (destructivo de
  la plantilla; ver `03`). Sin este flag, `02-golden.sh` rehúsa borrar un golden que ya existe.

### Multi-fábrica: convivencia de varias fábricas en un host

Cada fábrica apunta a un proyecto/repo distinto (fábrica portátil, TAL-2282). Para que no se pisen,
**namespacea por fábrica** con env (todo overridable en `00-config.sh`):

- `GOLDEN=golden-<proyecto>` — base CoW independiente por fábrica (`03` §CoW).
- `SECRET_DIR=$HOST_HOME/.config/talent-channels-<proyecto>` — escrow separado.
- `TS_PORT_BASE=<base>` — base de puertos tailscale distinta si dos fábricas conviven (evita colisión
  del puerto `41640+y`).
- **Motor** (opcional): `TF_REPO_URL` → el golden siembra `talent-factory` en `~/$TF_REPO_DIR`
  (`03` §Siembra del motor). `TF_REPO_DIR` se deriva de `TF_REPO_URL` y se **desambigua** del
  `REPO_DIR` de producto (deben ser distintos). `scripts/validate-manifest.sh` valida el manifiesto
  del motor de esa fábrica (claves consumidas presentes, sin duplicados, `TF_PROJECT`/repo coinciden).

## Recon de gobierno del repo objetivo (onboarding) — TAL-2296

Antes de aprovisionar una fábrica sobre un repo, el onboarding incluye un **recon read-only** que
distingue **"verificado" de "asumido"** — nunca dictar pasos de una plataforma/repo por memoria
(regla 20 del proyecto). Dos huecos que el examen de onboarding cubre explícitamente:

- **Gobierno del repo objetivo (verificado, no asumido)**: comprobar contra el repo REAL (no de
  memoria) su modelo de gates y ramas: qué **commit-status/checks** exige la branch protection de la
  rama por defecto (p. ej. hoy en Academia Ejemplo el único requerido es `local-gates`, con Actions
  OFF), qué **prefijos de rama** son válidos, si el flujo es draft+HANDOFF o clásico, y quién aplica
  migraciones. Estos datos gobiernan lo que el canal podrá o no hacer; asumirlos de otro repo rompe
  la entrega. Método: leer el `CLAUDE.md`/`AGENTS.md` del repo + la config de branch protection
  vigente, no la memoria de otra fábrica.
- **Paso de reconciliación de gobierno**: si el gobierno **verificado** difiere de lo **asumido** al
  planear la fábrica (otro gate requerido, otro flujo de PR, otro gestor de paquetes — ver `03` §8),
  se **reconcilia ANTES de aprovisionar**: ajustar el manifiesto del motor (`validate-manifest.sh`) y
  la config de la fábrica a lo que el repo realmente exige. Una fábrica montada sobre un gobierno
  asumido produce PRs que el repo rechaza en el gate.

## Helpers (`scripts/lib.sh`)

`tc_say/info/err/die`, `tc_cexec/cuser` (ejecutar en contenedor), `tc_wait_container/tc_wait_net`, `tc_prompt_secret` (sin eco, 0600, regex), `tc_read_secret/tc_have_secret`, `tc_push_secret_file` (push + chown + chmod), `tc_confirm_exact` (re-teclear para destructivo).

Token-only, **NO MCP**: las credenciales operacionales van en el env por carril y se auto-cargan en el shell (ver 05).
