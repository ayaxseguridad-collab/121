#!/usr/bin/env bash
# verify.sh — Verificación end-to-end READ-ONLY. Reporta PASS/FAIL por ítem. No modifica nada.
set -uo pipefail
etapa=preparado
if [ $# -gt 0 ]; then
  [ $# -eq 2 ] && [ "$1" = --etapa ] || { echo 'uso: verify.sh [--etapa creado|acreditado|preparado] (preparado: alias del histórico sin argumentos)' >&2; exit 2; }
  case "$2" in creado|acreditado|preparado) etapa="$2" ;; *) echo 'etapa desconocida; modos: creado|acreditado|preparado (alias histórico)' >&2; exit 2 ;; esac
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

# Seam de test: TC_VERIFY_SCOPE=identity permite al arnés de test correr SOLO la sección de
# identidad/perfil (TAL-2630) sin los checks de infra, para poder obtener exit 0 en sandbox.
# RESTRINGIDO AL ARNÉS: solo válido con TC_NO_AUTOLOAD=1. Sin ese flag, un operador que intente
# reducir el scope en una ejecución operacional FALLA CERRADO — nadie puede saltarse el verificador
# de infra con una env var suelta en producción.
if [ "${TC_VERIFY_SCOPE:-full}" != full ] && [ "${TC_NO_AUTOLOAD:-0}" != 1 ]; then
  tc_die "TC_VERIFY_SCOPE solo se permite en el arnés de test (requiere TC_NO_AUTOLOAD=1)"
fi

ok=0; bad=0
# chk MSG SCRIPT [ARGS...] — ejecuta SCRIPT con bash -c pasando los valores como ARGV ($1,$2,…),
# NUNCA concatenados en el texto (sin eval): un valor con comillas no puede inyectar comandos.
chk() {
  local msg="$1" script="$2"; shift 2
  if bash -c "$script" _ "$@" >/dev/null 2>&1; then printf '  PASS  %s\n' "$msg"; ok=$((ok+1)); else printf '  FAIL  %s\n' "$msg"; bad=$((bad+1)); fi
}
# chk_fn MSG FN [ARGS...] — como chk pero ejecuta un helper de lib.sh IN-PROCESS (no `bash -c`, que
# es un subshell donde las FUNCIONES no están definidas). Seguro: sin eval; los ARGS son posicionales
# desde config validada. Testeable: el helper corre en el shell actual (con `incus` override-able).
chk_fn() {
  local msg="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '  PASS  %s\n' "$msg"; ok=$((ok+1)); else printf '  FAIL  %s\n' "$msg"; bad=$((bad+1)); fi
}
# Falla directa (fail-closed) con mensaje, sin ejecutar nada.
chk_fail() { printf '  FAIL  %s\n' "$1"; bad=$((bad+1)); }

# [TAL-8038] Contrato del renderer clásico (lo aplica apply-renderer.sh; la versión mínima vive en talent-context).
RENDERER_JQ='.tui == "default" and (.statusLine.type == "command") and ((.statusLine.command // "") | test("statusline-ctx[.]sh"))'
RENDERER_MIN="${TC_RENDERER_MIN_FILE:-$HERE/../../talent-context/assets/claude-min-version}"

# Fuente única: solo nombres de sesiones de los CLI y del token del asistente.
readonly -a CREDENCIALES_ASISTENTE=('.claude/.credentials.json' '.codex/auth.json' '.claude_token.env')
golden_sin_credencial() {
  local ruta nombres directorio
  for ruta in "${CREDENCIALES_ASISTENTE[@]}"; do
    directorio="/home/$2"
    if [ "${ruta%/*}" != "$ruta" ]; then directorio+="/${ruta%/*}"; fi
    nombres="$(incus query "/1.0/instances/$1/files?path=$directorio")" || return 1
    jq -e --arg nombre "${ruta##*/}" 'type == "array" and (index($nombre) == null)' <<< "$nombres" >/dev/null || return 1
  done
}

if [ "${TC_VERIFY_SCOPE:-full}" != identity ]; then
tc_say "VERIFICACIÓN (read-only)"
if [ "$etapa" != creado ]; then
  # shellcheck source=/dev/null
  . "$HERE/../../talent-channel-operation/scripts/lib-modelos.sh"
  tco_modelos_read || exit 1
else
  tc_info 'PENDIENTE: modelo de canales hasta la preparación en F5; etapa creado exige modelo vacío.'
fi
chk "incus instalado"                 'command -v incus'
chk "pool '$POOL' (btrfs)"            'incus storage show "$1" | grep -q "driver: btrfs"' "$POOL"
chk "red '$BRIDGE'"                   'incus network show "$1"' "$BRIDGE"
chk "incus-forward.service activo"    'systemctl is-active incus-forward.service'
chk "incus-startup habilitado"        'systemctl is-enabled incus-startup.service'
chk "golden STOPPED"                  'incus list -f csv -c ns "^$1\$" | grep -qi stopped' "$GOLDEN"
if [ "$etapa" = acreditado ]; then
  # Golden está parado: consultar solo nombres por la API de ficheros, sin leer secretos.
  chk_fn "golden sin credencial claude NI codex" golden_sin_credencial "$GOLDEN" "$CUSER"
fi

for y in $(seq 1 "${COUNT:-0}"); do
  ch="$(tc_channel_name "$y")"; port="$(tc_channel_port "$y")"
  chk "$ch RUNNING"                   'incus list -f csv -c ns "^$1\$" | grep -qi running' "$ch"
  chk "$ch hostname único"            'test "$(incus exec "$1" -- hostname)" = "$1"' "$ch"
  chk "$ch TCP saliente"              'incus exec "$1" -- bash -c "timeout 4 bash -c \"echo > /dev/tcp/1.1.1.1/443\""' "$ch"
  chk "$ch toolchain (node/claude/codex)" 'incus exec "$1" -- bash -lc "command -v node && command -v claude && command -v codex"' "$ch"
  chk "$ch .codex/.claude dueño $CUSER"   'incus exec "$1" -- test -d /home/"$2"/.codex && incus exec "$1" -- test -d /home/"$2"/.claude && [ "$(incus exec "$1" -- stat -c %U /home/"$2"/.codex)" = "$2" ] && [ "$(incus exec "$1" -- stat -c %U /home/"$2"/.claude)" = "$2" ]' "$ch" "$CUSER"
  # [TAL-2296] Config baseline horneada en el golden (heredada por CoW) — NO son credenciales:
  chk "$ch codex config.toml (trust + no-autoupdate)" 'incus exec "$1" -- grep -q "check_for_update_on_startup = false" /home/"$2"/.codex/config.toml && incus exec "$1" -- grep -q "trust_level = \"trusted\"" /home/"$2"/.codex/config.toml' "$ch" "$CUSER"
  if [ "$etapa" = creado ]; then
    chk "$ch claude baseline (onboarding=true, modelo vacío, sin credencial claude NI codex)" 'incus exec "$1" -- jq -s -e "length == 1 and (.[0] | type == \"object\" and .hasCompletedOnboarding == true)" /home/"$2"/.claude.json && incus exec "$1" -- jq -s -e '\''length == 1 and (.[0] | type == "object" and .model == "")'\'' /home/"$2"/.claude/settings.json && for ruta in "${@:3}"; do incus exec "$1" -- test ! -e "/home/$2/$ruta" && incus exec "$1" -- test ! -L "/home/$2/$ruta" || exit 1; done' "$ch" "$CUSER" "${CREDENCIALES_ASISTENTE[@]}"
  elif [ "$etapa" = acreditado ]; then
    bad_antes=$bad
    chk "$ch claude baseline (onboarding=true, modelo vigente exacto=$TCO_SONNET_VIGENTE)" 'incus exec "$1" -- jq -s -e "length == 1 and (.[0] | type == \"object\" and .hasCompletedOnboarding == true)" /home/"$2"/.claude.json && incus exec "$1" -- jq -s -e --arg m "$3" "length == 1 and (.[0] | type == \"object\" and .model == \$m)" /home/"$2"/.claude/settings.json' "$ch" "$CUSER" "$TCO_SONNET_VIGENTE"
    if [ "$bad" -gt "$bad_antes" ]; then
      tc_info "F5 exige el ID completo antes del primer despacho. Tras el primer despacho, el selector de sesión puede guardar el alias de familia (sonnet); el doctor de F7 acredita el modelo EN USO leyendo la etiqueta del panel. Para volver a preparar, como C1: bash '$HERE/../../talent-channel-operation/scripts/preparar-modelo-canal.sh' '$ch' '$CUSER'. Revisar también onboarding; las fases F6–F8 no repiten check-F5."
    fi
  else
  chk "$ch claude baseline (onboarding=true, modelo=$TCO_SONNET_VIGENTE, sin credencial claude NI codex)" 'incus exec "$1" -- jq -s -e "length == 1 and (.[0] | type == \"object\" and .hasCompletedOnboarding == true)" /home/"$2"/.claude.json && incus exec "$1" -- jq -s -e --arg m "$3" "length == 1 and (.[0] | type == \"object\" and .model == \$m)" /home/"$2"/.claude/settings.json && incus exec "$1" -- test ! -f /home/"$2"/.claude/.credentials.json && incus exec "$1" -- test ! -f /home/"$2"/.codex/auth.json' "$ch" "$CUSER" "$TCO_SONNET_VIGENTE"
  fi
  chk "$ch DISABLE_AUTOUPDATER en bashrc" 'incus exec "$1" -- grep -q "DISABLE_AUTOUPDATER=1" /home/"$2"/.bashrc' "$ch" "$CUSER"
  # [TAL-8038] Renderer CLÁSICO + barra ctx (3 capas + versión mínima): sin esto el pane puede caer en pantalla alternada
  # (PLAN/handoff no capturables) y ningún pane emite `ctx: NN%` (compact-60 ciego). Aplicación: apply-renderer.sh.
  chk "$ch renderer: settings .tui=default + statusLine statusline-ctx.sh" 'incus exec "$1" -- jq -s -e "length == 1 and (.[0] | type == \"object\") and (.[0] | $3)" /home/"$2"/.claude/settings.json' "$ch" "$CUSER" "$RENDERER_JQ"
  chk "$ch renderer: export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 en bashrc" 'incus exec "$1" -- grep -q "^export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1" /home/"$2"/.bashrc' "$ch" "$CUSER"
  chk "$ch renderer: tmux.conf alternate-screen off" 'incus exec "$1" -- grep -qx "set -g alternate-screen off" /home/"$2"/.tmux.conf' "$ch" "$CUSER"
  if [ -r "$RENDERER_MIN" ]; then
    chk "$ch renderer: claude >= mínima ($(tr -d '[:space:]' < "$RENDERER_MIN"))" 'v="$(incus exec "$1" -- bash -lc "claude --version" 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)"; m="$(tr -d "[:space:]" < "$2")"; [ -n "$v" ] && [ -n "$m" ] && [ "$(printf "%s\n%s\n" "$m" "$v" | sort -V | head -1)" = "$m" ]' "$ch" "$RENDERER_MIN"
  else
    chk_fail "$ch renderer: falta $RENDERER_MIN (skill talent-context ausente) — no se puede exigir la versión mínima de claude (fail-closed)"
  fi
  if [ "${TC_LOCAL_ONLY:-no}" != yes ]; then
    chk "$ch tailscale puerto $port"    'incus exec "$1" -- grep -q "PORT=\"$2\"" /etc/default/tailscaled' "$ch" "$port"
  else
    # local-only: en vez de solo SKIP, AFIRMAR el aislamiento (fail-closed) — si no, un canal con
    # tailscaled deshabilitado pero estado PERSISTIDO pasaría inadvertido y reconectaría al reiniciar.
    chk "$ch AISLADO del tailnet (local-only: estado ausente + servicio no habilitado + sin IP)" 'incus exec "$1" -- test ! -e /var/lib/tailscale/tailscaled.state && ! incus exec "$1" -- systemctl is-enabled tailscaled >/dev/null 2>&1 && ! incus exec "$1" -- tailscale ip -4 >/dev/null 2>&1' "$ch"
  fi
  chk "$ch repo"                      'incus exec "$1" -- test -d "/home/$2/$3/.git"' "$ch" "$CUSER" "$REPO_DIR"
  if [ -n "${TF_REPO_DIR:-}" ]; then
    chk "$ch motor talent-factory ($TF_REPO_DIR)" 'incus exec "$1" -- test -d "/home/$2/$3/.git"' "$ch" "$CUSER" "$TF_REPO_DIR"
  fi
  # $ENV_DEST solo se exige si este carril tiene env en el escrow: push-carril-env.sh salta
  # carriles sin <canal>.env y esa es una ruta soportada — sin esto, verify daría FAIL falso.
  if [ -s "$SECRET_DIR/env/$ch.env" ]; then
    chk "$ch $ENV_DEST"               'incus exec "$1" -- test -f "/home/$2/$3/$4"' "$ch" "$CUSER" "$REPO_DIR" "$ENV_DEST"
  else
    tc_info "SKIP  $ch $ENV_DEST (sin $ch.env en el escrow — ruta soportada)"
  fi
  if [ "${TC_LOCAL_ONLY:-no}" != yes ]; then
    chk "$ch en tailnet"             'tailscale status 2>/dev/null | grep -qw "$1"' "$ch"
  else
    tc_info "SKIP  $ch en tailnet (TC_LOCAL_ONLY=yes — acceso local vía incus exec)"
  fi
done
fi  # TC_VERIFY_SCOPE != identity

# ── [TAL-2630] IDENTIDAD/PERFIL POR CANAL (fail-closed, defensa en profundidad) ──────────────
# Enumera TODOS los contenedores reales de ESTA fábrica (por MACHINE_NUM, no todo el PREFIX del
# host) y valida la credencial EFECTIVA de cada uno contra su perfil DECLARADO (ground-truth), sin
# grep de texto del árbol del repo. Cubre los canales fuera de 1..COUNT (p. ej. 91-94 del Mergeador).
tc_say "IDENTIDAD/PERFIL POR CANAL (TAL-2630)"
if real_channels="$(tc_list_real_channels)"; then
  if [ -z "$real_channels" ]; then
    tc_info "sin contenedores de la fábrica (${PREFIX}${MACHINE_NUM}·) presentes"
  fi
  for ch in $real_channels; do
    prof="$(tc_expected_profile "$ch")"
    case "$prof" in
      invalid)
        chk_fail "$ch perfil declarado INVÁLIDO o en conflicto (revisar channel-profiles.list / overrides)";;
      undeclared)
        chk_fail "$ch SIN perfil declarado (channel-profiles.list) — exige declaración explícita (fail-closed; siémbralo con 'channel-profiles.sh set $ch <perfil>')";;
      produccion)
        # SIEMPRE valida identidad (sin ruta de salto): tc_verify_env_identity es fail-closed en ambos
        # sentidos (escrow presente↔env del canal coincide; escrow ausente↔canal sin env operacional).
        chk_fn "$ch [prod] identidad env (md5==escrow, fail-closed)" tc_verify_env_identity "$ch"
        chk_fn "$ch [prod] identidad git (user.name/email == plantillas {channel})" tc_verify_git_identity "$ch"
        chk_fn "$ch [prod] SIN sbp_/CR efectiva ni sesión CR (todo el contenedor)" tc_prod_no_sensitive "$ch";;
      mergeador|piloto)
        # [TAL-5142] `piloto` (canal de LAB A2A) comparte VERBATIM las reglas de `mergeador`.
        chk_fn "$ch [$prof] identidad env (md5==escrow)"        tc_verify_env_identity "$ch"
        chk_fn "$ch [$prof] identidad git (user.name/email == plantillas {channel})" tc_verify_git_identity "$ch"
        chk_fn "$ch [$prof] identidad CR (apiKey md5==escrow)"  tc_verify_cr_identity "$ch"
        chk_fn "$ch [$prof] sbp_ efectiva presente"             tc_mergeador_has_sbp "$ch";;
      runner)
        chk_fn "$ch [runner] LIMPIO (sin cred efectiva en ningún home)" tc_runner_clean "$ch";;
      *)
        chk_fail "$ch perfil esperado no reconocido: '$prof'";;
    esac
  done
  # Reconciliación fail-closed: cada canal declarado/con-escrow de la fábrica debe EXISTIR.
  # Capturar el rc de tc_expected_channel_set ANTES del `for`: un `for ch in $(...)` DESCARTA el
  # exit code de la sustitución, así que un fallo del filtro de scope pasaría inadvertido y la
  # reconciliación se OMITIRÍA en silencio. Aquí: rc≠0 → FALLO explícito, no iterar sobre un conjunto
  # potencialmente incompleto.
  expected_set="$(tc_expected_channel_set)"; expected_rc=$?
  if [ "$expected_rc" -ne 0 ]; then
    chk_fail "no se pudo computar el conjunto esperado de canales (filtro de scope) — fail-closed"
  else
    for ch in $expected_set; do
      printf '%s\n' "$real_channels" | grep -qx "$ch" || chk_fail "$ch declarado/con-escrow pero SIN contenedor"
    done
  fi
else
  chk_fail "no se pudo enumerar los contenedores de la fábrica (incus list / MACHINE_NUM) — fail-closed"
fi

echo
tc_info "PASS=$ok FAIL=$bad"
tc_info "TAL-2630: el perfil por canal (produccion/mergeador/piloto/runner) es DECLARADO en \$SECRET_DIR/channel-profiles.list (o TC_MERGEADOR_CHANNELS/TC_RUNNER_CHANNELS); siémbralo con 'channel-profiles.sh set <canal> <perfil>' — TODO canal DEBE declararse (sin declarar = FALLO fail-closed; el intake/rollout siembra todos). Un FAIL de identidad/perfil arriba = credencial no esperada o perfil no impuesto."
tc_info "Recordatorios: el golden NO hornea credenciales (TAL-2294); Claude se acredita por PROPAGACIÓN (refresh-claude-auth.sh, método canónico) — 'claude login' per-carril queda como último recurso; auth de Codex se MUEVE per-carril con 'auth-move.sh move' (nunca fan-out); los tokens gh/linear/supabase se verifican en el host (preflight de 'env'); Tailscale SSH remoto requiere regla ssh en la ACL del tailnet (si no, usa acceso LOCAL: sudo incus exec <canal> -- su - $CUSER)."
[ "$bad" -eq 0 ]
