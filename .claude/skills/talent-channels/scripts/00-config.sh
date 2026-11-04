#!/usr/bin/env bash
# 00-config.sh — Config central del skill talent-channels. Se "source-ea" desde las demás fases.
# NO contiene secretos. NO ejecuta acciones (solo define variables + helpers). Repo-agnóstico.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Identidad del host real (funciona bajo sudo: resuelve el usuario invocador,
# nunca root/$HOME=/root). provision.sh DEBE correr con sudo desde un usuario real.
# ---------------------------------------------------------------------------
tc_resolve_host_identity() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
      HOST_USER="$SUDO_USER"
      HOST_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    else
      echo "ERROR: no ejecutes como root directo. Usa 'sudo' desde tu usuario (se necesita SUDO_USER)." >&2
      return 1
    fi
  else
    HOST_USER="${USER:-$(id -un)}"
    HOST_HOME="${HOME:?HOME no definido}"
  fi
  [ -n "$HOST_HOME" ] && [ -d "$HOST_HOME" ] || { echo "ERROR: no pude resolver HOME de '$HOST_USER'." >&2; return 1; }
}

# ---------------------------------------------------------------------------
# REPO_DIR limpio desde REPO_URL: soporta https://host/org/repo(.git),
# git@host:org/repo.git, file:///path, y rutas locales con espacios.
# ---------------------------------------------------------------------------
tc_repo_dir_from_url() {
  local url="$1" base
  base="${url%/}"            # quita slash final
  base="${base##*/}"         # basename (tras último '/')
  base="${base##*:}"         # por si es git@host:repo (sin '/')
  base="${base%.git}"        # quita .git
  printf '%s' "$base"
}

# URL https LIMPIA (sin token) desde https://… o git@host:org/repo(.git). Para clone con bootstrap.
tc_repo_https() {
  local url="$1" rest authority path
  case "$url" in
    # git@host:org/repo(.git) -> https://host/org/repo(.git)
    # Orden correcto: quitar 'git@', cambiar el PRIMER ':' (host:path) por '/', y DESPUÉS anteponer https://
    # (anteponer antes corrompía la URL: el primer ':' pasaba a ser el de 'https:').
    git@*) url="${url#git@}"; url="${url/:/\/}"; url="https://$url";;
  esac
  # Quitar userinfo embebido (https://token@host/…): esta función PROMETE una URL sin token —
  # si el secreto viajara aquí podría acabar en logs o en el remote del clon.
  case "$url" in
    https://*)
      rest="${url#https://}"
      authority="${rest%%/*}"
      path="${rest#"$authority"}"
      if [ "$authority" != "${authority##*@}" ]; then
        url="https://${authority##*@}${path}"
      fi
      ;;
  esac
  case "$url" in *.git) ;; *) url="$url.git";; esac
  printf '%s' "$url"
}

# ---------------------------------------------------------------------------
# Carga SEGURA de intake.conf — NUNCA `source` directo: provision.sh corre con sudo,
# así que un intake.conf manipulado sería ejecución arbitraria como root. Solo se
# aceptan asignaciones de claves WHITELISTED con charset seguro; cualquier otra línea
# aborta la carga (fail-closed). Los valores se serializaron con printf %q en el
# intake, por eso el eval final (solo de la asignación ya validada) los desescapa.
# ---------------------------------------------------------------------------
tc_load_intake_conf() {
  local f="$1" line key val
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue;; esac
    case "$line" in
      MACHINE_NUM=*|REPO_URL=*|REPO_DIR=*|COUNT=*|POOL_DISK=*) ;;
      *) echo "ERROR: línea no permitida en $f (clave fuera de whitelist) — carga abortada." >&2; return 1;;
    esac
    key="${line%%=*}"; val="${line#*=}"
    # Charset seguro: sin comillas, espacios, ';', '&', '|', '$', '`', paréntesis ni
    # redirecciones. La barra invertida se admite solo por los escapes que emite %q.
    printf '%s' "$val" | grep -qE '^[A-Za-z0-9._~:/@%+\-]*$' \
      || { echo "ERROR: valor con charset no permitido en $f para $key — carga abortada." >&2; return 1; }
    eval "$key=$val"
  done < "$f"
}

# ---------------------------------------------------------------------------
# Defaults (overridables por env). Los valores específicos de máquina/secretos
# NO tienen default: se piden en 00-intake.sh.
# ---------------------------------------------------------------------------
tc_load_config() {
  tc_resolve_host_identity || return 1

  # Escrow de secretos (fuera del repo) — se calcula pronto para poder cargar intake.conf.
  : "${SECRET_DIR:=$HOST_HOME/.config/talent-channels}"
  # Elecciones no-secretas del intake (MACHINE_NUM, REPO_URL, COUNT, POOL_DISK...) —
  # parser whitelist, nunca source (ver tc_load_intake_conf).
  if [ -f "$SECRET_DIR/intake.conf" ]; then
    tc_load_intake_conf "$SECRET_DIR/intake.conf" || return 1
  fi

  # Overrides de flags de CLI (TC_FLAG_*): viajan POR ENTORNO a los scripts hijo
  # (intake.conf NO los toca) y GANAN sobre intake.conf. Se aplican aquí, TRAS sourcear
  # el intake, de modo que cada hijo que re-sourcea 00-config respeta el flag.
  # [CR] los flags de CLI evitan el parser whitelist de intake.conf: mismo contrato aqui
  # (URL limpia sin userinfo; --disk bajo /dev sin metacaracteres) antes de asignar.
  if [ -n "${TC_FLAG_REPO:-}" ]; then
    printf '%s' "$TC_FLAG_REPO" | grep -qE '^(https://|git@)[A-Za-z0-9._~:/@%+-]+$' \
      || { echo "ERROR: TC_FLAG_REPO/--repo debe ser https://… o git@host:org/repo (sin espacios ni metacaracteres)." >&2; return 1; }
    case "$TC_FLAG_REPO" in
      https://*)
        _fa="${TC_FLAG_REPO#https://}"; _fa="${_fa%%/*}"
        case "$_fa" in *@*) echo "ERROR: TC_FLAG_REPO/--repo no debe incluir usuario/token embebido." >&2; return 1;; esac
        unset _fa
        ;;
    esac
    REPO_URL="$TC_FLAG_REPO"; REPO_DIR=""   # REPO_DIR se recomputa abajo
  fi
  # [TAL-2296] --machine N (un dígito 0-9): fija MACHINE_NUM sin intake interactivo (provisioning
  # no-interactivo / multi-fábrica). Mismo contrato que el intake (naming <x><y> único en el tailnet).
  if [ -n "${TC_FLAG_MACHINE:-}" ]; then
    printf '%s' "$TC_FLAG_MACHINE" | grep -qE '^[0-9]$' \
      || { echo "ERROR: TC_FLAG_MACHINE/--machine debe ser un dígito 0-9 (contrato <x><y>)." >&2; return 1; }
    MACHINE_NUM="$TC_FLAG_MACHINE"
  fi
  # [CR] mismo contrato que el intake (COUNT 1-9, un dígito): un --count fuera de rango crearía
  # canales fuera del naming <x><y> que 03b-fix-tailscale rechaza después.
  if [ -n "${TC_FLAG_COUNT:-}" ]; then
    printf '%s' "$TC_FLAG_COUNT" | grep -qE '^[1-9]$' \
      || { echo "ERROR: TC_FLAG_COUNT/--count debe ser 1-9 (contrato <x><y>)." >&2; return 1; }
    COUNT="$TC_FLAG_COUNT"
  fi
  if [ -n "${TC_FLAG_DISK:-}" ]; then
    printf '%s' "$TC_FLAG_DISK" | grep -qE '^/dev/[A-Za-z0-9._/+:-]+$' \
      || { echo "ERROR: TC_FLAG_DISK/--disk debe ser un device bajo /dev (sin espacios ni metacaracteres)." >&2; return 1; }
    POOL_DISK="$TC_FLAG_DISK"
  fi
  # Modo pool loop-backed (maquinas SIN disco secundario): tamano del archivo loop gestionado
  # por Incus nativo. Mutuamente excluyente con --disk (se valida en 01-incus-base).
  if [ -n "${TC_FLAG_POOL_SIZE:-}" ]; then
    printf '%s' "$TC_FLAG_POOL_SIZE" | grep -qE '^[0-9]{2,4}GiB$' \
      || { echo "ERROR: TC_FLAG_POOL_SIZE/--pool-size debe ser NNGiB (p.ej. 300GiB)." >&2; return 1; }
    POOL_LOOP_SIZE="$TC_FLAG_POOL_SIZE"
  fi

  # Repo objetivo (repo-agnóstico). Default = remote del repo actual si lo hay.
  : "${REPO_URL:=}"
  if [ -z "$REPO_URL" ] && git -C "${TC_INVOKE_CWD:-$PWD}" rev-parse --git-dir >/dev/null 2>&1; then
    REPO_URL="$(git -C "${TC_INVOKE_CWD:-$PWD}" remote get-url origin 2>/dev/null || true)"
  fi
  : "${REPO_DIR:=$( [ -n "$REPO_URL" ] && tc_repo_dir_from_url "$REPO_URL" )}"
  : "${ENV_DEST:=.env.local}"          # destino del env por carril dentro del repo

  # Motor talent-factory (OPCIONAL; TAL-2296 multi-fábrica): si TF_REPO_URL está definido, 02-golden
  # lo siembra en el golden por CoW (run-local-gates.sh / validate-manifest.sh). TF_REPO_DIR se
  # DESAMBIGUA del REPO_DIR de producto (deben ser distintos; 02-golden aborta si colisionan).
  : "${TF_REPO_URL:=}"
  : "${TF_REPO_DIR:=$( [ -n "$TF_REPO_URL" ] && tc_repo_dir_from_url "$TF_REPO_URL" )}"

  # Identidad git POR CANAL (contrato de la fábrica): plantillas del manifiesto con el ÚNICO
  # placeholder {channel} (= nombre exacto del contenedor), expandidas por 03-clone en la provisión
  # y exigidas por verify.sh (scope identity) con igualdad exacta. SIN default: el dominio/nombre
  # vive en el VALOR de la clave por fábrica, jamás en el paquete. Fail-closed en 03-clone si faltan.
  : "${TF_CHANNEL_GIT_NAME_TMPL:=}"
  : "${TF_CHANNEL_GIT_EMAIL_TMPL:=}"

  # Incus / red / pool
  : "${POOL:=carriles}"
  : "${BRIDGE:=incusbr0}"
  # IMG: se mantiene 24.04 a propósito (Ubuntu 26.04 LTS "Resolute Raccoon" salió 2026-04-23,
  # pero 24.04 sigue soportado hasta 2029 y es la compatibilidad probada con el paquete nativo
  # de Incus y con el resto de la flota). Migrar es decisión de lead pendiente — ver
  # references/03-golden.md §Vigencias, NO cambiar este default sin esa decisión.
  : "${IMG:=images:ubuntu/24.04}"

  # Golden / canales. MULTI-FÁBRICA (TAL-2296, overridables por env):
  #   - GOLDEN=golden-<proyecto>  → base CoW independiente por fábrica (no pisar el golden de otra).
  #   - SECRET_DIR=…/talent-channels-<proyecto>  → escrow namespaced por fábrica (calculado arriba).
  #   - TS_PORT_BASE=…            → base de puertos tailscale distinta si dos fábricas conviven en un host.
  : "${GOLDEN:=golden}"
  : "${PREFIX:=vibe-channel-}"          # canal = ${PREFIX}${MACHINE_NUM}${y}
  : "${CUSER:=vivecoder}"
  : "${TS_PORT_BASE:=41640}"           # puerto tailscale del canal y = base + y
  if [ -e "$SECRET_DIR/panel.conf" ] || [ -L "$SECRET_DIR/panel.conf" ]; then
    local panel f="$SECRET_DIR/panel.conf" owner expected
    owner="$(stat -c '%U:%G' -- "$f" 2>/dev/null)" || owner=desconocido
    expected="$(id -u "$HOST_USER")" || return 1
    if ! { [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ] &&
      [ "$(stat -c %u -- "$f")" = "$expected" ] &&
      IFS= read -r panel < "$f" && [[ $panel =~ ^([A-Za-z0-9_.-]+):\.0$ ]] &&
      [ "$(wc -c < "$f")" -eq "$((${#panel}+1))" ]; }; then
      printf 'ERROR: selección de panel ilegible o inválida: %s; propietario=%s; corrige permisos: sudo chown %q %q && sudo chmod 600 %q; si el contenido es inválido, reinstala con: sudo rm -- %q && sudo bash %q/install-launchers.sh\n' "$f" "$owner" "$HOST_USER:" "$f" "$f" "$f" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" >&2
      return 1
    fi
    [ "${TMUX_SESSION+x}" = x ] || TMUX_SESSION="${panel%:.0}"
  fi
  : "${TMUX_SESSION:=v}"
  : "${TC_LOCAL_ONLY:=no}"             # yes = sin Tailscale (acceso solo local vía incus exec)

  # [TAL-2630] Perfil ESPERADO por canal (ground-truth DECLARADA, no inferida). La fuente durable
  # es el mapa de escrow `$SECRET_DIR/channel-profiles.list` (líneas `canal=perfil`; perfil ∈
  # produccion|mergeador|runner); estos overrides de entorno son AD-HOC (p. ej. un rollout puntual).
  # Un canal declarado con perfiles DISTINTOS por >1 fuente → conflicto fail-closed en verify.sh.
  # Sin declaración = FALLO fail-closed en verify.sh (NO se asume `produccion`): TODO canal debe
  # declararse (el intake/rollout siembra todos, incl. producción). Ver references/05 §Perfiles.
  : "${TC_MERGEADOR_CHANNELS:=}"       # lista (espacios) de canales de perfil Mergeador (override)
  : "${TC_RUNNER_CHANNELS:=}"          # lista (espacios) de canales de perfil runner (override)
  : "${TC_CRED_SCANNER:=}"             # hook opcional: ruta EN el contenedor al scanner sellado del
                                       # motor para el barrido runner (si vacío, fallback canónico)

  # Sin default — se piden en intake (vacío = falta preguntar)
  : "${MACHINE_NUM:=}"                  # x: nº de máquina (0-9)
  : "${POOL_DISK:=}"                    # device del pool (explícito, nunca auto)
  : "${POOL_LOOP_SIZE:=}"               # alternativa: pool btrfs loop-backed (NNGiB), sin disco dedicado
  : "${COUNT:=}"                        # nº de canales a crear
  : "${MIN_DISK_GB:=100}"              # umbral mínimo de disco

  export HOST_USER HOST_HOME REPO_URL REPO_DIR ENV_DEST POOL BRIDGE IMG GOLDEN \
         PREFIX CUSER TS_PORT_BASE TMUX_SESSION MACHINE_NUM POOL_DISK COUNT \
         MIN_DISK_GB SECRET_DIR TF_REPO_URL TF_REPO_DIR TC_LOCAL_ONLY \
         TC_MERGEADOR_CHANNELS TC_RUNNER_CHANNELS TC_CRED_SCANNER \
         TF_CHANNEL_GIT_NAME_TMPL TF_CHANNEL_GIT_EMAIL_TMPL
}

# Nombre del canal y (1..N) para esta máquina. Requiere MACHINE_NUM.
tc_channel_name() { printf '%s%s%s' "$PREFIX" "$MACHINE_NUM" "$1"; }
# Puerto tailscale del canal y.
tc_channel_port() { printf '%s' "$((TS_PORT_BASE + $1))"; }
# Lista de canales 1..COUNT.
tc_channels() { local y; for y in $(seq 1 "${COUNT:?COUNT no definido}"); do tc_channel_name "$y"; done; }

# Cargar al ser source-eado (salvo TC_NO_AUTOLOAD=1 para tests).
[ "${TC_NO_AUTOLOAD:-0}" = "1" ] || tc_load_config
