#!/usr/bin/env bash
# pozos-install-token-remote.sh <host-ip> <contenedor> <sesion-tmux> <token-file> [modelo] — estación remota (ssh root@host + incus exec).
# El token viaja SOLO por stdin (ssh → incus exec → fichero 0600 creado antes de volcar); nunca por tmux ni argv. rc≠0 si falla (APPLY-FALLO).
# Anti-inyección (M5-BOUNCE): host/contenedor/sesión/modelo pasan por la allowlist de pozos-lib.sh ANTES de construir nada, y CADA
# pieza que entra en la orden remota se compone con `printf %q` (el shell del host RE-PARSEA el argumento de ssh, y `su -c` lo
# vuelve a parsear: dos niveles). El cuerpo remoto no lleva saltos de línea, para que %q produzca escapado POSIX y no `$'…'`.
# El proceso `claude` que se mata debe ser HIJO DIRECTO del pane 0 de la sesión y el CWD recuperado, un directorio existente.
# OCUPADO: si el CLI tiene hijos en vuelo (suite/gate), NO se mata — rc=6, el token queda escrito y el rotador reintenta el
# relanzamiento en el ciclo siguiente. `POZOS_FORCE=1` fuerza el relanzamiento pese a los hijos.
. "$(dirname "$0")/pozos-lib.sh"
H=$1; CT=$2; S=$3; TF=$4
MODEL=$(tco_modelo_read merge) && [ -n "$MODEL" ] || exit 1
[ -z "${5:-}" ] || MODEL=$5
[ -n "$H" ] && [ -n "$CT" ] && [ -n "$S" ] && [ -r "$TF" ] || { echo "uso: $0 <host-ip> <contenedor> <sesion-tmux> <token-file> [modelo]" >&2; exit 2; }
pozos_require host   "$H"     "host remoto"  || exit 2
pozos_require ct     "$CT"    "contenedor"   || exit 2
pozos_require sesion "$S"     "sesión tmux"  || exit 2
pozos_require modelo "$MODEL" "modelo"       || exit 2
# remote_cmd <script-para-vivecoder> → orden lista para ssh: cada pieza es UN literal para el shell del host
remote_cmd(){ printf 'incus exec %q -- su - vivecoder -c %q' "$CT" "$1"; }

W='umask 077; : > ~/.claude_token.env; chmod 600 ~/.claude_token.env; { printf "export CLAUDE_CODE_OAUTH_TOKEN=%q\n" "$(cat)"; } > ~/.claude_token.env; grep -q claude_token.env ~/.bashrc || echo "[ -f ~/.claude_token.env ] && . ~/.claude_token.env" >> ~/.bashrc; grep -q claude_token.env ~/.profile 2>/dev/null || echo "[ -f ~/.claude_token.env ] && . ~/.claude_token.env" >> ~/.profile'
timeout 40 ssh -o BatchMode=yes -- "root@$H" "$(remote_cmd "$W")" < "$TF" || { echo "$S@$H: no pude escribir ~/.claude_token.env (ssh/incus)" >&2; exit 4; }

# los únicos datos variables del cuerpo remoto entran por asignaciones escapadas con %q; el resto es literal sin expansión local
R="S=$(printf %q "$S"); MODEL=$(printf %q "$MODEL"); FORCE=$(printf %q "${POZOS_FORCE:-}"); "
R+='PP=$(tmux list-panes -t "$S" -F "#{pane_index} #{pane_pid}" | sed -n "s/^0 //p" | head -1); '
R+='C=""; [ -n "$PP" ] && C=$(pgrep -P "$PP" -f claude | head -1); '
R+='if [ -n "$C" ] && [ -z "$FORCE" ] && [ -n "$(pgrep -P "$C" 2>/dev/null)" ]; then echo OCUPADO; exit 6; fi; '
R+='CWD=""; [ -n "$C" ] && CWD=$(readlink "/proc/$C/cwd" 2>/dev/null); '
R+='[ -n "$CWD" ] && [ -d "$CWD" ] || CWD=$HOME; '
R+='Q=$(printf %q "$CWD"); '
R+='[ -n "$C" ] && { kill "$C"; sleep 3; }; '
R+='tmux send-keys -t "$S" C-u; '
R+='tmux send-keys -t "$S" -l ". ~/.claude_token.env; cd $Q; claude --dangerously-skip-permissions --continue --model $MODEL"; '
R+='sleep 1; tmux send-keys -t "$S" Enter; sleep 12; tmux send-keys -t "$S" Enter; sleep 8; '
R+='tmux send-keys -t "$S" -l "/model $MODEL"; sleep 1; tmux send-keys -t "$S" Enter; sleep 5; tmux send-keys -t "$S" Enter; sleep 2; '
R+='tmux send-keys -t "$S" C-u; '
R+='tmux send-keys -t "$S" -l "CEO: te relance con cuenta nueva (token largo, regla de cuota del lead); verifica modelo $MODEL + effort high y continua donde estabas."; '
R+='sleep 1; tmux send-keys -t "$S" Enter'
tco_modelo_require "$MODEL" || exit 1
timeout 120 ssh -o BatchMode=yes -- "root@$H" "$(remote_cmd "$R")"; rrc=$?
[ "$rrc" = 6 ] && { echo "$S@$H: OCUPADO (hijos en vuelo) — token escrito, relanzamiento diferido al próximo ciclo" >&2; exit 6; }
[ "$rrc" = 0 ] || { echo "$S@$H: fallo al relanzar el CLI (ssh/incus/tmux, rc=$rrc)" >&2; exit 5; }

probe_model=$(tco_modelo_read salud) && [ -n "$probe_model" ] || exit 1
P="MODEL=$(printf %q "$probe_model"); "
P+='. ~/.claude_token.env; timeout 60 claude -p "Responde solo: OK" --model "$MODEL" >/dev/null 2>&1 < /dev/null'
rc=0; timeout 60 ssh -o BatchMode=yes -- "root@$H" "$(remote_cmd "$P")" || rc=$?
echo "$S@$H: sonda rc=$rc"
# rc=7 (M5-BOUNCE CRÍTICO-3, TAL-5115): distinto de rc=6 (OCUPADO, L27/L40 — «token
# escrito, relanzamiento diferido», un éxito-a-reintentar). Antes ambos caían en exit 6: el
# rotador no podía distinguir «diferido, reintenta el próximo ciclo» de «el probe falló de
# verdad tras relanzar» — mismo rc, semántica distinta.
[ "$rc" = 0 ] && exit 0; exit 7
