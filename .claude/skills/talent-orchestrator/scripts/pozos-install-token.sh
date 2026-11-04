#!/usr/bin/env bash
# pozos-install-token.sh <canal-NN> <token-file> [modelo] — instala CLAUDE_CODE_OAUTH_TOKEN en el canal (~/.claude_token.env, 0600,
# escrito por STDIN — el token nunca viaja por tmux ni argv —, cargado por .bashrc/.profile), relanza el CLI con --continue EN EL CWD
# DEL PROCESO (relanzar en otro cwd pierde el contexto), manda «continuemos» y sondea. rc≠0 si falla cualquier paso (APPLY-FALLO).
# Anti-inyección (M5-BOUNCE): canal y modelo pasan por la allowlist de pozos-lib.sh ANTES de tocar incus/su/tmux; el CWD que se
# recupera del proceso vivo se re-inserta en la orden de tmux con `printf %q` y solo si es un DIRECTORIO existente; el proceso
# `claude` que se mata debe ser HIJO DIRECTO del pane v.0 (`pgrep -P <pane_pid>`), nunca un claude cualquiera del contenedor.
# OCUPADO: si el CLI tiene hijos en vuelo (suite/gate), NO se mata — rc=6, el token queda escrito y el rotador reintenta el
# relanzamiento en el ciclo siguiente. `POZOS_FORCE=1` fuerza el relanzamiento pese a los hijos.
. "$(dirname "$0")/pozos-lib.sh"
ch=$1; tf=$2
model=$(tco_modelo_read coding) && [ -n "$model" ] || exit 1
[ -z "${3:-}" ] || model=$3
[ -n "$ch" ] && [ -r "$tf" ] || { echo "uso: $0 <canal-NN> <token-file> [modelo]" >&2; exit 2; }
pozos_require ct "$ch" "canal" || exit 2
pozos_require modelo "$model" "modelo" || exit 2
# [TAL-8037] Sin default de casa: la carpeta del repo bajo $HOME del canal es identidad de la instancia (:? fail-closed).
repo=${POZOS_REPO_DIR:?pozos-install-token.sh: POZOS_REPO_DIR sin definir (carpeta del repo bajo el HOME del canal; sin default de casa)}
pozos_require dir "$repo" "POZOS_REPO_DIR" || exit 2
CTN=vibe-channel-$ch
incus exec "$CTN" -- su - vivecoder -c 'umask 077; : > ~/.claude_token.env; chmod 600 ~/.claude_token.env; { printf "export CLAUDE_CODE_OAUTH_TOKEN=%q\n" "$(cat)"; } > ~/.claude_token.env; grep -q claude_token.env ~/.bashrc || echo "[ -f ~/.claude_token.env ] && . ~/.claude_token.env" >> ~/.bashrc; grep -q claude_token.env ~/.profile 2>/dev/null || echo "[ -f ~/.claude_token.env ] && . ~/.claude_token.env" >> ~/.profile' < "$tf" || { echo "ch$ch: no pude escribir ~/.claude_token.env" >&2; exit 4; }
# El script del relanzamiento va como UN argumento a `su -c` (incus exec no interpone shell): el cuerpo es un heredoc
# SIN expansión y los únicos datos variables ($MODEL, $FORCE, $REPO, ya validados) entran por asignaciones escapadas con %q.
RELAUNCH="MODEL=$(printf %q "$model"); FORCE=$(printf %q "${POZOS_FORCE:-}"); REPO=$(printf %q "$repo")
$(cat <<'EOS'
tmux has-session -t v 2>/dev/null || tmux new-session -d -s v -x 220 -y 50 -c "$HOME/$REPO"
PP=$(tmux list-panes -t v -F '#{pane_index} #{pane_pid}' | awk '$1==0{print $2; exit}')
C=""; [ -n "$PP" ] && C=$(pgrep -P "$PP" -f claude | head -1)
# OCUPADO: si el CLI tiene hijos en vuelo (suite, gates) no se mata — el token ya quedó escrito y el relanzamiento se difiere
if [ -n "$C" ] && [ -z "$FORCE" ] && [ -n "$(pgrep -P "$C" 2>/dev/null)" ]; then echo OCUPADO; exit 6; fi
CWD=""; [ -n "$C" ] && CWD=$(readlink "/proc/$C/cwd" 2>/dev/null)
[ -n "$CWD" ] && [ -d "$CWD" ] || CWD=$HOME/$REPO
Q=$(printf %q "$CWD")
[ -n "$C" ] && { kill "$C"; sleep 2; }
tmux send-keys -t v.0 C-u
tmux send-keys -t v.0 -l ". ~/.claude_token.env; cd $Q; claude --dangerously-skip-permissions --continue --model $MODEL"
sleep 1; tmux send-keys -t v.0 Enter; sleep 10; tmux send-keys -t v.0 Enter; sleep 8
tmux send-keys -t v.0 -l "/model $MODEL"; sleep 1; tmux send-keys -t v.0 Enter; sleep 4; tmux send-keys -t v.0 Enter; sleep 2
tmux send-keys -t v.0 C-u
tmux send-keys -t v.0 -l 'continuemos: relanzado con cuenta nueva (token largo); retoma EXACTAMENTE donde estabas en tu encargo actual sin repetir trabajo; verifica /model y effort high.'
sleep 1; tmux send-keys -t v.0 Enter
EOS
)"
tco_modelo_require "$model" || exit 1
incus exec "$CTN" -- su - vivecoder -c "$RELAUNCH" >/dev/null 2>&1; rrc=$?
[ "$rrc" = 6 ] && { echo "ch$ch: OCUPADO (hijos en vuelo) — token escrito, relanzamiento diferido al próximo ciclo" >&2; exit 6; }
[ "$rrc" = 0 ] || { echo "ch$ch: fallo al relanzar el CLI (rc=$rrc)" >&2; exit 5; }
probe_model=$(tco_modelo_read salud) && [ -n "$probe_model" ] || exit 1
PROBE="MODEL=$(printf %q "$probe_model"); "
PROBE+='. ~/.claude_token.env; timeout 60 claude -p "Responde solo: OK" --model "$MODEL" >/dev/null 2>&1 < /dev/null'
rc=0; incus exec "$CTN" -- su - vivecoder -c "$PROBE" || rc=$?
echo "ch$ch: sonda rc=$rc"
# rc=7 (mismo defecto que pozos-install-token-remote.sh, M5-BOUNCE CRÍTICO-1 TAL-5115): distinto
# de rc=6 (OCUPADO, L25/L40 — «token escrito, relanzamiento diferido», un éxito-a-reintentar).
[ "$rc" = 0 ] && exit 0; exit 7
