#!/usr/bin/env bash
# pozos-install-token-torre.sh <sesion-tmux> <token-file> [modelo] — torre del HOST: escribe el token en $SECRET_DIR/env/<sesion>.env
# (0600, creado antes de volcar el contenido; el token NUNCA viaja por tmux ni por argv) y relanza el CLI con `source` de ese
# fichero, --resume <uuid> EN EL CWD DEL PROCESO. Sale con rc≠0 si falla cualquier paso (el rotador lo propaga como APPLY-FALLO).
# Anti-inyección (M5-BOUNCE): sesión y modelo pasan por la allowlist de pozos-lib.sh; $ENV_FILE y $CWD se insertan en las órdenes
# de tmux con `printf %q` (un path con comilla simple rompía la orden); el proceso `claude` que se mata debe ser HIJO DIRECTO
# del pane 0 de la sesión (`pgrep -P <pane_pid>`) y el CWD recuperado debe ser un DIRECTORIO existente (si no, se usa el default).
# Guards vivos (CEO 1-sep): con una suite/gate en vuelo bajo el CLI NO se mata nada (rc=6, el token queda escrito y el rotador
# reintenta; `POZOS_FORCE=1` lo fuerza), y el relanzamiento va SIEMPRE con `--resume <uuid>` (el cwd del host es compartido con
# el CEO: `--continue` engancharía la sesión equivocada). Sin uuid válido (allowlist `uuid`) sale rc=7 sin tocar la terminal. Renderer clásico (TAL-8038): el relanzamiento lleva
# CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 y antes se instalan `.tui=default` + la barra `ctx:` (rc=8 si no se pueden dejar listas).
. "$(dirname "$0")/pozos-lib.sh"
t=$1; tf=$2
model=$(tco_modelo_read "${TCO_TORRE_ROL:-coordinador}") && [ -n "$model" ] || exit 1
[ -z "${3:-}" ] || model=$3
[ -n "$t" ] && [ -r "$tf" ] || { echo "uso: $0 <sesion-tmux> <token-file> [modelo]" >&2; exit 2; }
pozos_require sesion "$t" "sesión tmux" || exit 2
pozos_require modelo "$model" "modelo" || exit 2
tmux has-session -t "$t" 2>/dev/null || { echo "$t: sesión tmux inexistente" >&2; exit 3; }
mkdir -p "$SECRET_DIR/env" && chmod 700 "$SECRET_DIR/env" || exit 4
ENV_FILE=$SECRET_DIR/env/$t.env
token_env_write "$ENV_FILE" < "$tf" || { echo "$t: no pude escribir $ENV_FILE" >&2; exit 4; }
PP=$(tmux list-panes -t "$t" -F '#{pane_index} #{pane_pid}' | awk '$1==0{print $2; exit}')
C=""; [ -n "$PP" ] && C=$(pgrep -P "$PP" -f claude | head -1)
# Guard anti-suite (CEO 1-sep): si el CLI tiene una suite/gate en vuelo (nieto node/npm/supabase/docker/psql/vitest/playwright),
# NO se relanza ahora — rc=6 y el rotador lo reintenta en el ciclo siguiente (matar el CLI mataría la suite).
if [ -n "$C" ] && [ -z "${POZOS_FORCE:-}" ]; then
  for k in $(pgrep -P "$C" 2>/dev/null); do
    if pgrep -P "$k" -f 'node|npm|supabase|docker|psql|vitest|playwright|next ' >/dev/null 2>&1; then
      echo "$t: CLI con suite/gate en vuelo (pid $k) — relanzamiento diferido al próximo ciclo" >&2; exit 6
    fi
  done
  # OCUPADO: cualquier hijo en vuelo también difiere el relanzamiento (el token ya quedó escrito)
  [ -n "$(pgrep -P "$C" 2>/dev/null)" ] && { echo "$t: OCUPADO (hijos en vuelo) — token escrito, relanzamiento diferido" >&2; exit 6; }
fi
CWD=""; [ -n "$C" ] && CWD=$(readlink "/proc/$C/cwd" 2>/dev/null)
[ -n "$CWD" ] && [ -d "$CWD" ] || CWD=$PWD
# En el HOST el cwd es compartido con el CEO: `--continue` engancharía la sesión equivocada. Se relanza SIEMPRE con el uuid
# exacto (`--resume`), resuelto del cmdline, de los fd del proceso o del último uuid cacheado; sin uuid válido NO se relanza.
SID=""
if [ -n "$C" ]; then
  SID=$(tr '\0' ' ' < "/proc/$C/cmdline" 2>/dev/null | grep -oE -- '--resume [0-9a-f-]{36}' | awk '{print $2}')
  [ -z "$SID" ] && SID=$(ls -l "/proc/$C/fd" 2>/dev/null | grep -oE '[0-9a-f-]{36}\.jsonl' | head -1 | sed 's/\.jsonl//')
fi
[ -z "$SID" ] && SID=$(cat "$SECRET_DIR/env/$t.session" 2>/dev/null)
pozos_require uuid "$SID" "uuid de sesión de $t (cmdline/fd/$SECRET_DIR/env/$t.session)" || exit 7
# [TAL-8038] Renderer clásico + barra ctx: ANTES de matar nada, settings con `.tui=default` + statusLine (talent-context). Una statusLine
# ajena (rc 3) solo sigue si ESA barra emite `ctx: NN%` (--check-ctx); cualquier otro fallo (p.ej. claude < mínima, rc 4) = rc=8 sin tocar la terminal.
INST=$(dirname "$0")/../../talent-context/scripts/install-statusline.sh
[ -r "$INST" ] || { echo "$t: falta $INST (skill talent-context) — no relanzo" >&2; exit 8; }
bash "$INST" >/dev/null; irc=$?
case $irc in
  0) : ;;
  3) bash "$INST" --check-ctx >/dev/null || { echo "$t: statusLine ajena sin 'ctx: NN%' — no relanzo" >&2; exit 8; } ;;
  *) echo "$t: install-statusline.sh falló (rc $irc) — no relanzo" >&2; exit 8 ;;
esac
printf '%s\n' "$SID" > "$SECRET_DIR/env/$t.session"
EQ=$(printf %q "$ENV_FILE"); CQ=$(printf %q "$CWD")
tco_modelo_require "$model" || exit 1
[ -n "$C" ] && { kill "$C"; sleep 3; }
tmux send-keys -t "$t" C-u
tmux send-keys -t "$t" -l ". $EQ; cd $CQ; CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 claude --dangerously-skip-permissions --resume $SID --model $model"; sleep 1; tmux send-keys -t "$t" Enter
sleep 25; tmux send-keys -t "$t" Enter; sleep 12; tmux send-keys -t "$t" -l "/model $model"; sleep 1; tmux send-keys -t "$t" Enter; sleep 5; tmux send-keys -t "$t" Enter
tmux send-keys -t "$t" C-u; tmux send-keys -t "$t" -l "CEO: te relancé con una cuenta nueva (token largo, regla de cuota del lead); verifica modelo $model + effort high y continúa donde estabas."; sleep 1; tmux send-keys -t "$t" Enter
probe_model=$(tco_modelo_read salud) && [ -n "$probe_model" ] || exit 1
rc=0; (. "$ENV_FILE"; timeout 60 claude -p 'Responde solo: OK' --model "$probe_model" >/dev/null 2>&1 </dev/null) || rc=$?
echo "$t relanzada con $(basename "$tf") en $CWD — sonda rc=$rc"
[ "$rc" = 0 ] && exit 0; exit 5
