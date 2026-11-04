#!/usr/bin/env bash
# provision.sh — ORQUESTADOR (Flujo B: runtime LOCAL). Corre las fases en orden con gates locales.
# Runtime puramente local: no hace gates de repo ni llamadas a servicios externos del proyecto
# (gestion de issues / base de datos prod viven en el Flujo A, la entrega del PR).
# Idempotente/reentrante. Flags: --repo URL --machine N --count N --disk /dev/X --gpu "c1 c2"
#   --local-only --force-golden --from F --only F --reintake --dry-run
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TC_INVOKE_CWD="${TC_INVOKE_CWD:-$PWD}"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"
[ "$(id -u)" -eq 0 ] || tc_die "Corre con: sudo bash provision.sh (se necesita SUDO_USER)."

REINTAKE=no DRYRUN=no GPU_LIST="" FROM="" ONLY="" FORCE_GOLDEN=no
FLAG_REPO="" FLAG_COUNT="" FLAG_DISK="" FLAG_MACHINE=""
while [ $# -gt 0 ]; do case "$1" in
  --repo) FLAG_REPO="$2"; shift 2;;
  --machine) FLAG_MACHINE="$2"; shift 2;;
  --count) FLAG_COUNT="$2"; shift 2;;
  --disk) FLAG_DISK="$2"; shift 2;;
  --gpu) GPU_LIST="$2"; shift 2;;
  --local-only) export TC_LOCAL_ONLY=yes; shift;;   # sin Tailscale: acceso solo local (incus exec)
  --force-golden) FORCE_GOLDEN=yes; shift;;          # recrear un golden EXISTENTE (destructivo, TAL-2296)
  --from) FROM="$2"; shift 2;;
  --only) ONLY="$2"; shift 2;;
  --reintake) REINTAKE=yes; shift;;
  --dry-run) DRYRUN=yes; shift;;
  *) tc_die "flag desconocido: $1";;
esac; done

# Los flags de CLI GANAN sobre intake.conf. Se exportan como TC_FLAG_* para que VIAJEN
# por entorno a cada `bash "$HERE/$script"` hijo (que re-sourcea 00-config.sh): allí
# tc_load_config los aplica DESPUÉS de sourcear intake.conf y recomputa REPO_DIR.
# Exportar REPO_URL/COUNT a secas NO basta: intake.conf los pisa al re-sourcearse en el hijo.
tc_apply_flags() {
  [ -n "$FLAG_REPO" ]    && export TC_FLAG_REPO="$FLAG_REPO"
  [ -n "$FLAG_MACHINE" ] && export TC_FLAG_MACHINE="$FLAG_MACHINE"
  [ -n "$FLAG_COUNT" ]   && export TC_FLAG_COUNT="$FLAG_COUNT"
  [ -n "$FLAG_DISK" ]    && export TC_FLAG_DISK="$FLAG_DISK"
  tc_load_config   # reaplica en el proceso padre (coherencia de REPO_DIR/COUNT/POOL_DISK aquí)
  return 0
}
tc_apply_flags

# Fases: nombre:script[:args]
PHASES=(
  "intake:00-intake.sh"
  "disk:01-incus-base.sh"
  "network:01b-network-fix.sh"
  "golden:02-golden.sh"
  "golden-ts:03b-fix-tailscale.sh"
  "clone:03-clone.sh"
  "env:push-carril-env.sh:all"
  "autostart:04-autostart.sh"
  "launchers:install-launchers.sh"
  "verify:verify.sh"
)

# Preflight dividido en dos para que cada verificación dispare antes de la fase que de verdad
# depende de ella, en CUALQUIER ruta de entrada (--from/--only/reanudar). Cada una corre una sola vez.
_PF_LOGINS_DONE=no
_PF_TOKENS_DONE=no

# Logins del host a PROPAGAR per-carril (el golden NO los hornea, TAL-2294). Corre antes de disk|golden.
# Comprueba por EXISTENCIA DE FICHERO bajo $HOST_HOME (no ejecuta los CLIs como root: validaría /root).
tc_preflight_host_logins() {
  [ "$_PF_LOGINS_DONE" = yes ] && return 0
  _PF_LOGINS_DONE=yes
  tc_say "PREFLIGHT host — logins a propagar"
  command -v git  >/dev/null || tc_die "falta git en el host."
  command -v curl >/dev/null || tc_die "falta curl en el host."
  tc_info "usuario host: $HOST_USER ($HOST_HOME)"
  local missing=""
  if [ -f "$HOST_HOME/.claude/.credentials.json" ]; then tc_info "Claude login host: present"
  else tc_warn "host SIN login Claude → sin origen para la propagación automatizada (refresh-claude-auth.sh all cosecha del HOST); acredita el HOST con 'claude login' (login per-carril queda como último recurso)."; missing="$missing claude"; fi
  if [ -f "$HOST_HOME/.codex/auth.json" ]; then tc_info "Codex login host: present"
  else tc_warn "host SIN login Codex → sin origen para MOVER auth de Codex a los carriles. Haz 'codex login' en el host (luego 'auth-move.sh move <cuenta> host:<host> channel:<canal>' per-carril)."; missing="$missing codex"; fi
  if [ -n "$missing" ] && [ "${TC_REQUIRE_HOST_LOGINS:-no}" = yes ]; then
    tc_die "TC_REQUIRE_HOST_LOGINS=yes y faltan logins en el host:$missing"
  fi
}

# Tokens de operación que se propagan en la fase 'env' (push-carril-env.sh). Corre antes de 'env'
# (cubre --only env / --from env). Parseo TEXTUAL ESTRICTO de los KEY=value (sin source/eval: están
# sin escapar). Salida solo present/missing — nunca valores ni prefijos.
tc_preflight_env_tokens() {
  [ "$_PF_TOKENS_DONE" = yes ] && return 0
  _PF_TOKENS_DONE=yes
  tc_say "PREFLIGHT host — tokens de operación a propagar"
  local empty=0 y ch envf k
  for y in $(seq 1 "${COUNT:-0}"); do
    ch="$(tc_channel_name "$y")"; envf="$SECRET_DIR/env/$ch.env"
    for k in GITHUB_TOKEN LINEAR_API_KEY SUPABASE_ACCESS_TOKEN; do
      if [ -f "$envf" ] && grep -Eq "^$k=.+$" "$envf"; then tc_info "$ch $k: present"
      else tc_info "$ch $k: missing"; empty=$((empty+1)); fi
    done
  done
  if [ "$empty" -gt 0 ] && [ "${TC_REQUIRE_OP_TOKENS:-no}" = yes ]; then
    tc_die "TC_REQUIRE_OP_TOKENS=yes y hay $empty token(s) de operación vacíos/ausentes."
  fi
}

started=no
for entry in "${PHASES[@]}"; do
  IFS=: read -r name script arg <<<"$entry"
  if [ -n "$ONLY" ]; then [ "$name" = "$ONLY" ] || continue; fi
  if [ -n "$FROM" ] && [ "$started" = no ]; then [ "$name" = "$FROM" ] && started=yes || continue; fi
  # intake: saltar si ya hay intake.conf y no --reintake
  if [ "$name" = intake ] && [ "$REINTAKE" = no ] && [ -f "$SECRET_DIR/intake.conf" ]; then
    tc_info "intake ya hecho (intake.conf) — saltado (usa --reintake para rehacer)"; continue
  fi
  [ "$name" = network ] && [ -z "$ONLY" ] && true   # network siempre tras disco
  # local-only: sin Tailscale → el fix de tailscaled del HOST (golden-ts) no aplica.
  if [ "$name" = golden-ts ] && [ "${TC_LOCAL_ONLY:-no}" = yes ]; then
    tc_info "» FASE golden-ts saltada (--local-only: sin Tailscale en el host)"; continue
  fi
  tc_say "» FASE: $name"
  if [ "$DRYRUN" = yes ]; then echo "(dry-run) $script $arg"; continue; fi
  # preflight host-side (run-once): logins antes de disk|golden; tokens antes de env.
  case "$name" in disk|golden) tc_preflight_host_logins;; esac
  [ "$name" = env ] && tc_preflight_env_tokens
  # golden-ts es 03b con target golden
  if [ "$name" = golden-ts ]; then bash "$HERE/$script" "$GOLDEN"
  elif [ "$name" = golden ] && [ "$FORCE_GOLDEN" = yes ]; then bash "$HERE/$script" --force
  else bash "$HERE/$script" ${arg:+$arg}; fi
  # recargar config tras intake — tc_load_config sourcea intake.conf y reaplica TC_FLAG_* (ya exportados)
  [ "$name" = intake ] && tc_load_config
done

# acreditación de agentes: propagación canónica (Claude) + MOVE (Codex)
if [ "$DRYRUN" = no ] && [ -z "$ONLY" ]; then
  tc_say "ACREDITACIÓN DE AGENTES — propaga credenciales (método canónico)"
  tc_info "Claude: acredita por PROPAGACIÓN — 'bash scripts/refresh-claude-auth.sh all' cosecha del HOST y copia a los carriles. El 'claude login' (navegador) per-carril queda como último recurso si el host no está acreditado."
  tc_info "Codex: el golden NO lo hornea (TAL-2294). Mueve un login per-carril: 'bash scripts/auth-move.sh move <cuenta> host:<host> channel:<canal>' (nunca fan-out)."
fi

# GPU opcional (solo si se pidió)
if [ -n "$GPU_LIST" ] && [ "$DRYRUN" = no ]; then
  for ch in $GPU_LIST; do tc_say "GPU on: $ch"; bash "$HERE/enable-gpu.sh" "$ch"; done
fi

echo; echo "✅ PROVISION COMPLETO. Revisa la verificación de arriba, propaga Claude por carril donde falte (método canónico: 'refresh-claude-auth.sh all') y MUEVE un login de Codex a cada carril con 'auth-move.sh move <cuenta> host:<host> channel:<canal>' (TAL-2294; nunca fan-out)."
