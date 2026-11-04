#!/usr/bin/env bash
# 02-golden.sh — Construye el contenedor plantilla '$GOLDEN' (por defecto 'golden'; multi-fábrica:
# 'golden-<proyecto>'). Repo-agnóstico. NO hornea .env.local operacional NI credenciales de agente
# (eso es per-carril, tras clonar — TAL-2294). Clona con git-bootstrap-token EFÍMERO.
#
# GUARD ANTI-DESTRUCCIÓN (TAL-2296): recrear un golden EXISTENTE tira la plantilla ya construida
# (y en multi-fábrica la base de clonado de ESA fábrica). Por eso NO se borra por defecto: exige
# --force / TC_GOLDEN_FORCE=yes. Para una fábrica NUEVA sin tocar la existente: exporta un nombre
# propio con GOLDEN=golden-<proyecto> (CoW independiente por fábrica).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$HERE/../assets"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"
# shellcheck source=/dev/null
. "$HERE/apply-renderer.sh"   # [TAL-8038] funciones sourceables: renderer clásico + barra ctx (3 capas)

GOLDEN_FORCE="${TC_GOLDEN_FORCE:-no}"
while [ $# -gt 0 ]; do case "$1" in
  --force) GOLDEN_FORCE=yes; shift;;
  *) tc_die "flag desconocido para 02-golden: $1";;
esac; done

[ "$(id -u)" -eq 0 ] || tc_die "02-golden requiere root (sudo)."
[ -n "$REPO_URL" ] || tc_die "REPO_URL no definido (corre 00-intake.sh)."
tc_have_secret git-bootstrap-token || tc_die "Falta git-bootstrap-token (00-intake.sh)."
tc_have_secret cuser-pass || tc_die "Falta cuser-pass (00-intake.sh)."
HTTPS_CLEAN="$(tc_repo_https "$REPO_URL")"

tc_say "FASE 2 — GOLDEN '$GOLDEN' (repo $REPO_DIR)"

if incus info "$GOLDEN" >/dev/null 2>&1; then
  if [ "$GOLDEN_FORCE" = yes ]; then
    tc_warn "'$GOLDEN' ya existe y --force/TC_GOLDEN_FORCE=yes — se DESTRUYE la plantilla y se reconstruye (los clones ya creados son subvolúmenes independientes y sobreviven; pierdes la plantilla y sus retoques)."
    incus delete -f "$GOLDEN"
  else
    tc_die "'$GOLDEN' ya existe. Recrearlo DESTRUYE la plantilla (multi-fábrica: la base de clonado de esta fábrica). Para reconstruir a propósito: --force (o TC_GOLDEN_FORCE=yes). Para una fábrica NUEVA sin tocar ésta: GOLDEN=golden-<proyecto> bash 02-golden.sh."
  fi
fi
tc_say "[1/9] Lanzar $GOLDEN ($IMG) + nesting"
incus launch "$IMG" "$GOLDEN"
incus config set "$GOLDEN" security.nesting=true
tc_wait_net "$GOLDEN" || tc_die "Sin salida a internet en $GOLDEN (¿corriste 01b-network-fix?)."

tc_say "[2/9] Paquetes base + gh + Tailscale (userspace) + docker"
tc_cexec "$GOLDEN" 'echo "Acquire::ForceIPv4 \"true\";" > /etc/apt/apt.conf.d/99force-ipv4
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg git build-essential tmux openssh-server sudo locales jq unzip bubblewrap docker.io docker-compose-v2
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
apt-get update -qq && apt-get install -y -qq gh
curl -fsSL https://tailscale.com/install.sh | sh'
# Tailscale userspace + cleanup no-fatal (desde asset)
tc_cexec "$GOLDEN" 'printf "FLAGS=\"--tun=userspace-networking\"\nPORT=\"0\"\n" > /etc/default/tailscaled; mkdir -p /etc/systemd/system/tailscaled.service.d'
incus file push "$ASSETS/tailscaled-override.conf" "$GOLDEN/etc/systemd/system/tailscaled.service.d/override.conf" >/dev/null
tc_cexec "$GOLDEN" 'systemctl daemon-reload; systemctl stop tailscaled 2>/dev/null || true'

tc_say "[3/9] Usuario $CUSER (sudo NOPASSWD + docker), password recuperable"
CPASS="$(tc_read_secret cuser-pass)"
printf '%s' "$CPASS" | incus exec "$GOLDEN" -- bash -c '
  id "'"$CUSER"'" >/dev/null 2>&1 || useradd -m -s /bin/bash "'"$CUSER"'"
  read -r p; echo "'"$CUSER"'":"$p" | chpasswd; unset p
  usermod -aG sudo,docker "'"$CUSER"'"
  echo "'"$CUSER"' ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-'"$CUSER"'; chmod 440 /etc/sudoers.d/90-'"$CUSER"'
  systemctl enable --now docker >/dev/null 2>&1 || true
  mkdir -p /home/"'"$CUSER"'"/.claude /home/"'"$CUSER"'"/.codex
  chown "'"$CUSER"'":"'"$CUSER"'" /home/"'"$CUSER"'"/.claude /home/"'"$CUSER"'"/.codex'
unset CPASS

tc_say "[4/9] Clonar repo con git-bootstrap-token EFÍMERO (origin sin token)"
# Limpieza GARANTIZADA del secreto dentro del contenedor (éxito o fallo intermedio).
# Doble capa: trap host-side (EXIT del script) + trap dentro del shell del contenedor.
_tc_wipe_gbt() {
  incus exec "$GOLDEN" -- bash -c \
    'shred -u /home/'"$CUSER"'/.gbt /home/'"$CUSER"'/.gitaskpass 2>/dev/null || rm -f /home/'"$CUSER"'/.gbt /home/'"$CUSER"'/.gitaskpass' \
    2>/dev/null || true
}
trap _tc_wipe_gbt EXIT
incus file push "$SECRET_DIR/git-bootstrap-token" "$GOLDEN/home/$CUSER/.gbt" >/dev/null
incus exec "$GOLDEN" -- chown "$CUSER:$CUSER" "/home/$CUSER/.gbt"
incus exec "$GOLDEN" -- chmod 600 "/home/$CUSER/.gbt"
tc_cuser "$GOLDEN" '
  set -e
  trap "shred -u \$HOME/.gbt \$HOME/.gitaskpass 2>/dev/null || rm -f \$HOME/.gbt \$HOME/.gitaskpass" EXIT
  printf "#!/bin/sh\nexec cat \$HOME/.gbt\n" > ~/.gitaskpass; chmod 700 ~/.gitaskpass
  AUTHURL="https://x-access-token@'"${HTTPS_CLEAN#https://}"'"
  GIT_ASKPASS=$HOME/.gitaskpass GIT_TERMINAL_PROMPT=0 git clone "$AUTHURL" ~/'"$REPO_DIR"'
  git -C ~/'"$REPO_DIR"' remote set-url origin "'"$HTTPS_CLEAN"'"
  git config --global --unset credential.helper 2>/dev/null || true'
# Verificar que origin NO lleva token embebido
tc_cuser "$GOLDEN" 'git -C ~/'"$REPO_DIR"' remote get-url origin | grep -q "x-access-token\|@.*:" && { echo "ERROR: origin con token"; exit 1; } || true'
# Éxito: limpiar el secreto YA y soltar el trap (no debe re-disparar en fases posteriores).
_tc_wipe_gbt
trap - EXIT

# [TAL-2296] Siembra OPCIONAL del motor talent-factory (run-local-gates.sh / validate-manifest.sh)
# en el golden, para que la flota tenga el motor por CoW. Solo si TF_REPO_URL está definido; mismo
# patrón de token efímero que [4/9] (re-push + doble trap + shred garantizado). Repo-agnóstico.
if [ -n "${TF_REPO_URL:-}" ]; then
  tc_say "[4b/9] Sembrar motor talent-factory (opcional; TF_REPO_URL definido)"
  TF_HTTPS_CLEAN="$(tc_repo_https "$TF_REPO_URL")"
  # El override configurado (TF_REPO_DIR en intake/00-config) MANDA; solo se deriva de la URL si no se
  # fijó. Debe coincidir con lo que verify.sh comprueba (que lee TF_REPO_DIR) — si aquí se derivara y
  # allí se leyera el override, se clonaría en una ruta y se verificaría otra. Además, el override es
  # precisamente la vía para resolver una colisión de basenames motor↔producto.
  TF_DIR_C="${TF_REPO_DIR:-$(tc_repo_dir_from_url "$TF_REPO_URL")}"
  [ "$TF_DIR_C" != "$REPO_DIR" ] || tc_die "el directorio del motor ('$TF_DIR_C') colisiona con el repo de producto ('$REPO_DIR') — fija TF_REPO_DIR del motor a un nombre distinto (motor y producto viven en directorios separados)."
  trap _tc_wipe_gbt EXIT
  incus file push "$SECRET_DIR/git-bootstrap-token" "$GOLDEN/home/$CUSER/.gbt" >/dev/null
  incus exec "$GOLDEN" -- chown "$CUSER:$CUSER" "/home/$CUSER/.gbt"
  incus exec "$GOLDEN" -- chmod 600 "/home/$CUSER/.gbt"
  tc_cuser "$GOLDEN" '
    set -e
    trap "shred -u \$HOME/.gbt \$HOME/.gitaskpass 2>/dev/null || rm -f \$HOME/.gbt \$HOME/.gitaskpass" EXIT
    printf "#!/bin/sh\nexec cat \$HOME/.gbt\n" > ~/.gitaskpass; chmod 700 ~/.gitaskpass
    AUTHURL="https://x-access-token@'"${TF_HTTPS_CLEAN#https://}"'"
    GIT_ASKPASS=$HOME/.gitaskpass GIT_TERMINAL_PROMPT=0 git clone "$AUTHURL" "$HOME/'"$TF_DIR_C"'"
    git -C "$HOME/'"$TF_DIR_C"'" remote set-url origin "'"$TF_HTTPS_CLEAN"'"'
  tc_cuser "$GOLDEN" 'git -C "$HOME/'"$TF_DIR_C"'" remote get-url origin | grep -q "x-access-token\|@.*:" && { echo "ERROR: origin del motor con token"; exit 1; } || true'
  _tc_wipe_gbt
  trap - EXIT
  tc_info "motor sembrado en ~/$TF_DIR_C. AVISO: el motor puede ir DETRÁS de su origin — 'git -C ~/$TF_DIR_C pull' antes de correr gates."
fi

# [TAL-1552] Los CLIs de agente se instalan como ROOT (tc_cexec corre como root) y en su ÚLTIMA estable.
# Deliberado: el usuario del carril NO tiene permisos sobre el prefix global de npm, así que un self-update
# lanzado desde el pane fallaría con EACCES y MATARÍA el proceso (el pane caería a un shell). Con el binario
# root-managed + el notifier de update suprimido (config.toml del auditor en [6/9] + DISABLE_AUTOUPDATER en
# [7/9]), el prompt de actualización no aparece. NO se pinea versión (regla 14: última estable por rebuild).
tc_say "[5/9] Node (versión del repo o LTS) + CLIs npm globales"
tc_cexec "$GOLDEN" 'set -e
RD="/home/'"$CUSER"'/'"$REPO_DIR"'"
NV=""
[ -f "$RD/.nvmrc" ] && NV=$(grep -oE "[0-9]+" "$RD/.nvmrc" | head -1)
[ -z "$NV" ] && NV=$(grep -oE "\"node\"[^0-9]*([0-9]+)" "$RD/package.json" 2>/dev/null | grep -oE "[0-9]+" | head -1)
[ -z "$NV" ] && NV=24   # Active LTS verificado 2026-07-18 (nodejs.org/en/about/previous-releases, endoflife.date/nodejs); re-verificar en próxima auditoría
echo "Node major = $NV"
curl -fsSL "https://deb.nodesource.com/setup_${NV}.x" | bash -
apt-get install -y -qq nodejs
npm install -g @anthropic-ai/claude-code @openai/codex @railway/cli convex supabase'

# CodeRabbit CLI (review pre-PR; NO es npm) — TAL-1502/TAL-1512. El binario forma parte del GATE
# pre-PR, y el instalador oficial `curl|sh` NO verifica checksum (limitación del vendor). Por eso NO
# usamos su install.sh: descargamos el ARTEFACTO VERSIONADO directo y verificamos su sha256 contra un
# hash pineado (por arquitectura), FAIL-CLOSED si no coincide. Versión + hashes obligatorios. La auth
# va per-carril (push-carril-env.sh escribe ~/.coderabbit/auth.json directo, SIN exponer la key en argv).
# Para subir de versión: descargar el zip nuevo, capturar su sha256, actualizar CR_CLI_VERSION + hashes,
# y verificar que el formato de auth.json no cambió (push-carril-env.sh lo escribe a mano).
tc_say "[5b/9] CodeRabbit CLI (coderabbit/cr) — review pre-PR (artefacto verificado)"
# Pin DURO (no overrideable por env): el sha256 es la garantía de integridad del binario que forma parte
# del gate pre-PR; permitir override por env dejaría poner versión+sha de un binario distinto y pasaría la
# verificación. Para subir de versión se edita coderabbit-pin.conf (fuente única).
# shellcheck source=/dev/null
. "$HERE/coderabbit-pin.conf"
# Los regex son defensa en profundidad: si una edición futura introdujera un valor con comillas/metacaracteres,
# romperían la interpolación al inner shell de tc_cuser (shell injection). Con estos patrones solo pasa una
# versión semántica / sha256 hex puro.
[[ "$CR_CLI_VERSION"      =~ ^[0-9][0-9.]*$ ]] || tc_die "CR_CLI_VERSION formato inválido (esperado N.N.N): $CR_CLI_VERSION"
[[ "$CR_CLI_SHA256_X64"   =~ ^[a-f0-9]{64}$ ]] || tc_die "CR_CLI_SHA256_X64 no es un sha256 hex de 64 chars."
[[ "$CR_CLI_SHA256_ARM64" =~ ^[a-f0-9]{64}$ ]] || tc_die "CR_CLI_SHA256_ARM64 no es un sha256 hex de 64 chars."
tc_cuser "$GOLDEN" 'set -e
VER="'"$CR_CLI_VERSION"'"; SHA_X64="'"$CR_CLI_SHA256_X64"'"; SHA_ARM64="'"$CR_CLI_SHA256_ARM64"'"
case "$(uname -m)" in
  x86_64|amd64) ARCH=x64;  WANT="$SHA_X64" ;;
  aarch64|arm64) ARCH=arm64; WANT="$SHA_ARM64" ;;
  *) echo "ERROR: arch $(uname -m) no soportada para el CLI de CR" >&2; exit 1 ;;
esac
url="https://cli.coderabbit.ai/releases/${VER}/coderabbit-linux-${ARCH}.zip"
tmp="$(mktemp -d)"; cleanup() { rm -rf "$tmp"; }; trap cleanup EXIT
curl -fsSL --connect-timeout 30 --max-time 300 --retry 2 "$url" -o "$tmp/cr.zip"
got="$(sha256sum "$tmp/cr.zip" | cut -d" " -f1)"
[ "$got" = "$WANT" ] || { echo "ERROR: sha256 del CLI de CR no coincide (got=$got want=$WANT) — FAIL-CLOSED, no se instala" >&2; exit 1; }
unzip -o -q "$tmp/cr.zip" -d "$tmp/x"
bin="$(find "$tmp/x" -type f -name coderabbit | head -1)"
[ -n "$bin" ] || { echo "ERROR: binario coderabbit no encontrado en el zip" >&2; exit 1; }
mkdir -p "$HOME/.local/bin"; install -m 0755 "$bin" "$HOME/.local/bin/coderabbit"; ln -sf coderabbit "$HOME/.local/bin/cr"
export PATH="$HOME/.local/bin:$PATH"
if ver="$(coderabbit --version 2>/dev/null)" && [ -n "$ver" ]; then
  echo "CodeRabbit CLI: $ver (pin $VER, linux-$ARCH, sha256 verificado)"
else
  echo "ERROR: CodeRabbit CLI no quedó instalado/visible para el carril (--version falló o vacío)" >&2; exit 1
fi'

tc_say "[6/9] Rol/config de Codex + gitconfig de IDENTIDAD (SIN credenciales de agente)"
# [TAL-2294] El golden NO hornea NINGUNA credencial de agente (ni Claude ~/.claude/.credentials.json
# ni Codex ~/.codex/auth.json). Un login vive en UN solo lugar: hornearlo en la plantilla lo clona a
# cada carril → cascada de rotación del refresh token (causó la caída F2). Las credenciales llegan
# per-carril por cosecha/propagación verificada (refresh-claude-auth.sh / auth-move.sh) DESPUÉS de
# clonar. Los directorios ~/.claude y ~/.codex ya se crearon (owner correcto) en [3/9].
# Rol de Codex (auditor/analista): persistente (AGENTS.md global) + prompt de arranque inmediato (role-prompt.txt, lo lanza 'v').
incus file push "$ASSETS/codex-role.txt" "$GOLDEN/home/$CUSER/.codex/AGENTS.md" >/dev/null
incus file push "$ASSETS/codex-role.txt" "$GOLDEN/home/$CUSER/.codex/role-prompt.txt" >/dev/null
incus exec "$GOLDEN" -- chown "$CUSER:$CUSER" "/home/$CUSER/.codex/AGENTS.md" "/home/$CUSER/.codex/role-prompt.txt"
# [TAL-1552] config.toml del auditor: suprime el chequeo de actualización al arrancar (check_for_update_on_startup=false;
# root-managed, en estos contenedores el update fallaría por EACCES) y siembra la confianza del repo del carril
# (evita el prompt "trust directory"). Path del proyecto renderizado con expansión bash (no sed: __REPO_DIR__ puede traer '/').
CODEX_CFG_CONTENT="$(cat "$ASSETS/codex-config.toml")"
CODEX_CFG_CONTENT="${CODEX_CFG_CONTENT//__CUSER__/$CUSER}"
CODEX_CFG_CONTENT="${CODEX_CFG_CONTENT//__REPO_DIR__/$REPO_DIR}"
_codex_cfg_tmp="$(mktemp)"
printf '%s\n' "$CODEX_CFG_CONTENT" > "$_codex_cfg_tmp"
incus file push "$_codex_cfg_tmp" "$GOLDEN/home/$CUSER/.codex/config.toml" >/dev/null; rm -f "$_codex_cfg_tmp"
incus exec "$GOLDEN" -- chown "$CUSER:$CUSER" "/home/$CUSER/.codex/config.toml"
# Identidad git: el golden viaja SIN identidad — NUNCA se hereda del host (ni user.name/user.email:
# firmar como el host rompe la trazabilidad de autoría por canal, medido en producción) ni queda la
# rama silenciosa «sin gitconfig». La identidad es POR CANAL: 03-clone la escribe expandiendo
# {channel} sobre TF_CHANNEL_GIT_{NAME,EMAIL}_TMPL del manifiesto de la fábrica (fail-closed), y
# verify.sh (scope identity) exige la igualdad exacta. El resto del ~/.gitconfig del host sigue sin
# viajar JAMÁS (credential.helper/http.extraHeader/url.insteadOf serían fuga de credenciales).
incus exec "$GOLDEN" -- su - "$CUSER" -c 'rm -f ~/.gitconfig; git config --global init.defaultBranch main'
tc_info "golden SIN identidad git (la identidad es por canal, expandida en 03-clone desde el manifiesto de la fábrica)."

# [TAL-2296] Config BASELINE de Claude (UI + modelo), NO credenciales. Se hornea en el golden para que
# cada clon nazca sin el wizard de onboarding y con un valor de modelo neutro.
# Preparar el canal aplica el Sonnet vigente del registro resuelto del usuario.
# El login (~/.claude/.credentials.json) NO se toca: sigue siendo
# per-carril (TAL-2294). La VERIFICACIÓN de que el default está VIVO sigue siendo gate per-carril del
# coordinador (ref 06 §Agentes al día): aquí solo se siembra la línea base.
tc_say "[6b/9] Baseline de Claude: hasCompletedOnboarding + modelo por defecto (sin credenciales)"
tc_cuser "$GOLDEN" 'set -e
  # ~/.claude.json: estado de UI (marca el onboarding como hecho). jq si el fichero ya existe.
  if [ -f "$HOME/.claude.json" ]; then
    tmp="$(mktemp)"; jq -s -e "if length == 1 and (.[0] | type == \"object\") then .[0] | .hasCompletedOnboarding = true else error(\"onboarding JSON inválido\") end" "$HOME/.claude.json" > "$tmp"; mv "$tmp" "$HOME/.claude.json"
  else
    printf "%s\n" "{\"hasCompletedOnboarding\": true}" > "$HOME/.claude.json"
  fi
  chmod 600 "$HOME/.claude.json"
  # El golden se construye antes de acreditar Claude: no puede resolver el modelo.
  # La preparación del clon aplica el identificador completo de Sonnet vigente.
  mkdir -p "$HOME/.claude"
  if [ -f "$HOME/.claude/settings.json" ]; then
    tmp="$(mktemp)"; jq -s -e "if length == 1 and (.[0] | type == \"object\") then .[0] | .model = \"\" else error(\"settings JSON inválido\") end" "$HOME/.claude/settings.json" > "$tmp"; mv "$tmp" "$HOME/.claude/settings.json"
  else
    printf "%s\n" "{\"model\": \"\"}" > "$HOME/.claude/settings.json"
  fi
  chmod 600 "$HOME/.claude/settings.json"'
# Anti-regresión TAL-2294: el baseline NUNCA debe crear un login. Si apareció, ABORTA (fail-closed).
tc_cuser "$GOLDEN" 'test ! -f "$HOME/.claude/.credentials.json" && test ! -f "$HOME/.codex/auth.json"' \
  || tc_die "REGRESIÓN: apareció una credencial de agente en el golden — el golden NO hornea credenciales (TAL-2294)."

# Flags del modo autónomo (el contenedor ES el sandbox): UNA sola fuente para los alias del .bashrc (humanos) y los
# lanzadores ejecutables (el despacho). `tmux respawn-pane` ejecuta con `bash -c` y no lee el .bashrc: un alias no arranca el CLI.
CLAUDE_ROOT_FLAGS="--dangerously-skip-permissions"
CODEX_ROOT_FLAGS="--dangerously-bypass-approvals-and-sandbox"
tc_launcher_text() { # agente flags → texto del lanzador ejecutable (un solo exec literal: la identidad de panes lo sigue)
  printf '%s\n' '#!/bin/bash' \
    '# Lanzador de canal: mismo efecto que el alias del .bashrc, pero fichero (tmux respawn-pane usa bash -c y no lee el .bashrc).' \
    "IS_SANDBOX=1 exec $1 $2 \"\$@\""
}
tc_install_launcher() { # nombre agente flags → ~/.local/bin/<nombre> (0755, del usuario del canal), por stdin
  tc_launcher_text "$2" "$3" | incus exec "$GOLDEN" -- su - "$CUSER" -c \
    "mkdir -p \"\$HOME/.local/bin\" && cat > \"\$HOME/.local/bin/$1\" && chmod 0755 \"\$HOME/.local/bin/$1\"" \
    || tc_die "no pude instalar el lanzador $1 en el golden"
}

tc_say "[7/9] tmux (mouse+extended-keys) + bashrc (alias root, DISABLE_MOUSE, tokens loader)"
tc_cexec "$GOLDEN" "printf 'set -g mouse on\nset -g history-limit 50000\nset -s extended-keys on\nset -as terminal-features \"*:extkeys\"\n' > /home/$CUSER/.tmux.conf; chown $CUSER:$CUSER /home/$CUSER/.tmux.conf"
# tokens loader desde tmpl — render con expansión de parámetros bash (no sed):
# ENV_DEST puede traer subrutas (monorepo: apps/web/.env.local) y romper sed con delimitador '/'.
TOKENS_CONTENT="$(cat "$ASSETS/tokens.bashrc.tmpl")"
TOKENS_CONTENT="${TOKENS_CONTENT//__REPO_DIR__/$REPO_DIR}"
TOKENS_CONTENT="${TOKENS_CONTENT//__ENV_DEST__/$ENV_DEST}"
# mktemp (no path fijo en /tmp): escribir como root a /tmp/<fijo> es vulnerable a symlink-attack.
_tok_tmp="$(mktemp)"
printf '%s\n' "$TOKENS_CONTENT" > "$_tok_tmp"
incus file push "$_tok_tmp" "$GOLDEN/tmp/tc_tokens.bashrc" >/dev/null; rm -f "$_tok_tmp"
tc_cexec "$GOLDEN" "grep -q 'alias claude-root=' /home/$CUSER/.bashrc || cat >> /home/$CUSER/.bashrc <<'EOF'

# carriles: modo autonomo (el contenedor ES el sandbox)
alias claude-root=\"IS_SANDBOX=1 claude $CLAUDE_ROOT_FLAGS\"
alias codex-root=\"IS_SANDBOX=1 codex $CODEX_ROOT_FLAGS\"
export CLAUDE_CODE_DISABLE_MOUSE=1
# [TAL-1552] Suprime el chequeo/notifier de actualización en arranque: en estos contenedores el update
# fallaría (EACCES del prefix global root-managed) y mataría el CLI → el pane caería a un shell.
export DISABLE_AUTOUPDATER=1
EOF
grep -qi 'tokens operativos del repo' /home/$CUSER/.bashrc || cat /tmp/tc_tokens.bashrc >> /home/$CUSER/.bashrc
chown $CUSER:$CUSER /home/$CUSER/.bashrc"
# Lanzadores EJECUTABLES (los usa el despacho, que arranca el CLI con `tmux respawn-pane`, sin .bashrc). Fail-closed: ambos
# deben existir y ser ejecutables del usuario del canal. Que ~/.local/bin esté en el PATH del pane lo comprueba el propio
# despacho antes de lanzar (tco_launchers_ready, dentro de un pane de tmux: misma shell y mismo PATH con que se arranca el CLI)
# y se detiene con el remedio si no. Los flags y las variables de entorno van aquí, en el lanzador: TCO_DEV_CLI/TCO_AUDIT_CLI son un solo ejecutable.
tc_install_launcher claude-root claude "$CLAUDE_ROOT_FLAGS"
tc_install_launcher codex-root codex "$CODEX_ROOT_FLAGS"
tc_cuser "$GOLDEN" 'test -x "$HOME/.local/bin/claude-root" && test -x "$HOME/.local/bin/codex-root"' \
  || tc_die "los lanzadores claude-root/codex-root no quedaron ejecutables en ~/.local/bin de $CUSER: el despacho no podría arrancar los agentes."
# [TAL-8038] Renderer CLÁSICO + barra `ctx:` (3 capas, idempotente; fail-closed): settings.json (.tui=default + statusLine, con
# versión mínima de Claude), export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 en bashrc (guard propio) y `alternate-screen off` en
# tmux.conf. Sin esto un canal puede caer en pantalla alternada (PLAN/handoff no capturables) y ningún pane emite `ctx: NN%`.
tc_say "[7b/9] Renderer clásico + barra ctx (settings .tui/.statusLine + env + tmux alternate-screen off)"
tc_renderer_apply_one "$GOLDEN" || tc_die "no se pudo aplicar el renderer clásico + barra ctx en el golden (fail-closed; ver FAIL arriba)."

tc_say "[8/9] Dependencias del repo (gestor detectado vía corepack) + Playwright (si el repo lo usa)"
# [TAL-2296] Gestor de paquetes del REPO, no asumir npm: corepack respeta el campo "packageManager"
# de package.json (pnpm/yarn via corepack; bun si está; npm por defecto). Habilitar corepack ANTES de
# instalar para que un repo pnpm/yarn no falle con "command not found".
tc_cexec "$GOLDEN" 'corepack enable >/dev/null 2>&1 || true'
# El gestor declarado por el repo se EXIGE (fail-closed): si package.json declara pnpm/yarn/bun y su
# binario no está, se ABORTA — NUNCA se cae en silencio a npm (alteraría resolución y lockfiles). Un
# fallo TRANSITORIO del install sí es reintentable (no fatal).
# [TAL-2296 · re-fix bounce #921] La AUSENCIA del binario se señala por un MARCADOR en stdout
# (ABSENT:/OK:), NO por exit code: si se reusara un código sentinel (p.ej. exit 3) y el propio
# `pnpm/yarn/bun install` fallara devolviendo ESE mismo código por un motivo real (red/lockfile), se
# leería un fallo transitorio como "gestor ausente" (colisión de exit codes — finding CR). Detección e
# instalación van en llamadas SEPARADAS: el exit code del install solo alimenta el aviso transitorio,
# nunca la decisión de ausencia.
pm_detect="$(tc_cuser "$GOLDEN" 'set -e
  cd ~/'"$REPO_DIR"'
  pm=npm
  if command -v jq >/dev/null 2>&1 && [ -f package.json ]; then
    case "$(jq -r ".packageManager // empty" package.json 2>/dev/null)" in
      pnpm@*) pm=pnpm ;; yarn@*) pm=yarn ;; bun@*) pm=bun ;;
    esac
  fi
  command -v "$pm" >/dev/null 2>&1 || { printf "ABSENT:%s\n" "$pm"; exit 0; }
  printf "OK:%s\n" "$pm"')" || pm_detect="ERR:detección falló"
case "$pm_detect" in
  OK:*)     pm="${pm_detect#OK:}" ;;
  ABSENT:*) tc_die "el repo declara el gestor '${pm_detect#ABSENT:}' pero su binario NO está en el golden. No se hace fallback silencioso a npm (rompería resolución/lockfiles). Habilita el gestor (corepack) y reconstruye el golden." ;;
  *)        tc_die "detección del gestor de paquetes falló (salida inesperada: '$pm_detect')." ;;
esac
echo "gestor de paquetes del repo: $pm"
# El exit code del install es SOLO señal de éxito/fallo transitorio (jamás sentinel de ausencia).
tc_cuser "$GOLDEN" 'cd ~/'"$REPO_DIR"' && '"$pm"' install' \
  || tc_info "install de dependencias con '$pm' falló (transitorio — reintentar luego)"
tc_cexec "$GOLDEN" "grep -q '\"playwright\"\\|@playwright/test' /home/$CUSER/$REPO_DIR/package.json 2>/dev/null && (cd /home/$CUSER/$REPO_DIR && npx --yes playwright install-deps chromium firefox >/dev/null 2>&1) || echo 'repo sin playwright; salto deps'"
tc_cuser "$GOLDEN" "grep -q '\"playwright\"\\|@playwright/test' ~/$REPO_DIR/package.json 2>/dev/null && (cd ~/$REPO_DIR && npx playwright install chromium firefox >/dev/null 2>&1) || true"

tc_say "[9/9] Verificación"
# Anti-regresión FINAL (TAL-2294/2296): repetir el hard-check DESPUÉS de los lifecycle scripts de
# dependencias ([8/9] corre postinstall arbitrario) — el golden NO debe contener NINGUNA credencial de
# agente pase lo que pase en el camino. Fail-closed.
tc_cuser "$GOLDEN" 'test ! -f "$HOME/.claude/.credentials.json" && test ! -f "$HOME/.codex/auth.json"' \
  || tc_die "REGRESIÓN (post-deps): apareció una credencial de agente en el golden — el golden NO hornea credenciales (TAL-2294)."
tc_cexec "$GOLDEN" "echo node \$(node -v); claude --version 2>/dev/null||echo 'claude n/d'; codex --version 2>/dev/null||echo 'codex n/d'; tailscale version 2>/dev/null|head -1; id $CUSER"
tc_cuser "$GOLDEN" "ls -d ~/$REPO_DIR >/dev/null && echo 'repo OK'; git -C ~/$REPO_DIR remote get-url origin"
incus config set "$GOLDEN" user.fabrica.base-completa yes
echo "✅ FASE 2 COMPLETA. Golden listo (sin .env.local; los tokens van per-carril tras clonar)."
