#!/usr/bin/env bash
# lib-torre.sh — Helpers de la Torre de Control (TAL-2278). Se "source-ea" tras 00-config.sh + lib.sh.
# Doctrina: references/09-torre-de-control.md + docs/runbooks/torre-de-control.md (ADR-0043/0046).
# Dos capas:
#   - Funciones PURAS (stdin = captura; sin tmux ni red) — cubiertas por tests/run-tests.sh.
#   - Wrappers RUNTIME sobre tmux del HOST (las sesiones torre-* NO viven en Incus).
# Anti-fantasma: captura con -e para distinguir ghost-text (dim ^[[2m, p.ej. el /exit fantasma
# del autocomplete) de cola real ("Press up to edit queued messages" en brillo pleno), y
# verificacion de input POST-paste PRE-submit (jamas submit a ciegas).
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# PURAS — validadores y parsers (testeables sin tmux)
# ---------------------------------------------------------------------------

# Normaliza actor -> nombre de sesion torre-<actor>. Acepta ya prefijado (idempotente, patron
# torc_to_container). Solo minusculas/digitos/guiones: el nombre viaja a `tmux -t` sin escape.
torc_torre_session() { # actor|torre-actor -> torre-actor ; rc 1 si invalido
  local a="${1:-}"; a="${a#"$TORRE_SESSION_PREFIX"}"
  printf '%s' "$a" | grep -qE '^[a-z0-9][a-z0-9-]*$' || return 1
  printf '%s%s' "$TORRE_SESSION_PREFIX" "$a"
}

# Quita los tramos DIM (ghost-text del autocomplete) de una captura con -e. Un tramo dim abierto
# sin cierre se descarta hasta el fin de linea (tmux re-emite los codigos por linea).
torc_torre_strip_ghost() { # stdin = captura CON -e -> misma captura sin ghost
  local esc; esc="$(printf '\033')"
  sed -E -e "s/${esc}\[2m[^${esc}]*(${esc}\[(22|0)m)?//g"
}

# Quita TODOS los codigos ANSI (SGR) de una captura.
torc_torre_strip_ansi() { # stdin -> texto plano
  local esc; esc="$(printf '\033')"
  sed -E -e "s/${esc}\[[0-9;]*m//g"
}

# Region del COMPOSER: desde la ULTIMA linea-prompt ('> ' — las anteriores son eco del historial)
# hasta el final de la captura (incluye lineas de continuacion del box). Conserva las lineas RAW.
torc_torre_composer_region() { # stdin = captura (con o sin -e) -> lineas raw ; rc 1 si no hay prompt
  local esc; esc="$(printf '\033')"
  # el borde │ (U+2502) es multibyte: en un bracket [|│] se matchea por BYTES y rompe el '?';
  # se normaliza a '|' ANTES de evaluar el patron (gsub literal funciona byte a byte).
  awk -v esc="$esc" '
    { raw[NR]=$0; c=$0; gsub(esc"\\[[0-9;]*m","",c); gsub(/│/,"|",c)
      if (c ~ /^[[:space:]]*[|]?[[:space:]]*>([[:space:]]|$)/) last=NR }
    END { if(!last) exit 1; for(i=last;i<=NR;i++) print raw[i] }'
}

# Contenido COMPLETO del composer sin bordes: la linea-prompt ('> …') MAS sus lineas de
# continuacion (bordeadas con │) — texto real pendiente puede vivir SOLO en una continuacion y
# clobbearlo seria perder input del operador. Se corta en la primera linea no-bordeada (fondo del
# box / barra de estado), asi la barra nunca cuenta como contenido.
torc_torre_composer_text() { # stdin = captura -> contenido del composer (multilinea)
  torc_torre_composer_region | torc_torre_strip_ansi | sed -e 's/│/|/g' | awk '
    NR==1 { sub(/^[[:space:]]*[|]?[[:space:]]*>[[:space:]]?/,""); sub(/[[:space:]]*[|]?[[:space:]]*$/,""); print; next }
    /^[[:space:]]*\|/ { l=$0; sub(/^[[:space:]]*\|[[:space:]]?/,"",l); sub(/[[:space:]]*[|]?[[:space:]]*$/,"",l); print l; next }
    { exit }'
}

# Clasifica el estado del INPUT de un pane a partir de una captura CON -e (doctrina ref 09):
#   queued — "Press up to edit queued messages" en brillo pleno (cola REAL: no reintentar a ciegas)
#   text   — contenido REAL pendiente en el composer (no es nuestro: no clobbear)
#   ghost  — solo autocomplete dim (p.ej. /exit fantasma): NO se "neutraliza", se ignora
#   empty  — composer vacio (o pane sin composer identificable)
torc_torre_input_state() { # stdin = captura CON -e -> imprime el estado (rc 0 siempre que lea)
  local cap qline line gline
  cap="$(cat)"
  qline="$(printf '%s\n' "$cap" | grep -i 'press up to edit queued messages' | tail -1)" || true
  # brillo pleno = cola real (la frase sobrevive al strip de ghost); en dim seria render fantasma
  if [ -n "$qline" ] && printf '%s\n' "$qline" | torc_torre_strip_ghost \
      | grep -qi 'press up to edit queued messages'; then
    printf 'queued\n'; return 0
  fi
  # composer COMPLETO (prompt + continuaciones): texto real solo-en-continuacion tambien cuenta
  line="$(printf '%s\n' "$cap" | torc_torre_composer_text)" || line=""
  [ -n "${line//[[:space:]]/}" ] || { printf 'empty\n'; return 0; }
  gline="$(printf '%s\n' "$cap" | torc_torre_strip_ghost | torc_torre_composer_text)" || gline=""
  if [ -n "${gline//[[:space:]]/}" ]; then printf 'text\n'; else printf 'ghost\n'; fi
}

# ¿Hay un MENU de seleccion abierto en el pane? (TAL-8043; el coordinador que espera una decision en
# un menu sin sellar nada no deja rastro: el detector lo hace visible al doctor y al sweep.)
# Un menu abierto cumple LAS TRES: (1) una linea con CURSOR numerado `❯ N. opcion` (U+276F),
# (2) al menos otra opcion numerada `N. opcion` y (3) la linea de pista del selector (`Esc to
# cancel`, `Enter to select`, `to navigate`, flechas). Con solo (1)+(2) un composer que lleve
# `❯ 1. texto` bajo una lista numerada del transcript lo simularia; la pista de (3) la imprime el
# selector y NO el composer en reposo. Solo lee stdin (captura plana o con -e); rc 0 menu · 1 no.
torc_torre_menu_open() { # stdin = captura -> rc 0 | 1
  torc_torre_active_region | sed -e 's/│/ /g' | awk '
    /^[[:space:]]*❯[[:space:]]+[0-9]+\.[[:space:]]+[^[:space:]]/ { cur++; num++; next }
    /^[[:space:]]+[0-9]+\.[[:space:]]+[^[:space:]]/ { num++ }
    tolower($0) ~ /(esc to (cancel|exit|go back)|enter to (select|confirm)|to navigate|↑\/↓|↑↓)/ { hint++ }
    END { exit (cur >= 1 && num >= 2 && hint >= 1) ? 0 : 1 }'
}

# Cola activa: ocho líneas no vacías; descarta citas explícitas
# y el historial anterior al último prompt de entrada. Límite textual, no prueba de autoridad.
torc_torre_active_region() {
  torc_torre_strip_ansi | awk '
    NF { a[++n]=$0 }
    END {
      start=n-7; if(start<1) start=1
      prompt=0
      for(i=1;i<=n;i++) {
        if(a[i] ~ /^[[:space:]]*(>|❯)[[:space:]]*$/) prompt=i
      }
      if(start<=prompt) start=prompt+1
      # Reconstruye las citas desde el último prompt en la captura completa;
      # conserva el estado al entrar en la cola, aunque la apertura quede fuera.
      quoted=0
      for(i=prompt+1;i<=n;i++) {
        if(a[i] ~ /^[[:space:]]*```/) { quoted=!quoted; continue }
        if(tolower(a[i]) ~ /(cita expl(i|í)cita|no selector activo).*:/) { quoted=1; continue }
        if(i>=start && !quoted) print a[i]
      }
    }'
}

torc_torre_question_pending() {
  local region last
  region="$(torc_torre_active_region)"
  printf '%s\n' "$region" | torc_torre_busy_from && return 1
  last="$(printf '%s\n' "$region" | grep -vEi 'ctx[:= ]|^[[:space:]]*[>❯][[:space:]]*$|^[[:space:]─━]+$' | tail -n1)"
  [[ $last =~ \?[[:space:]]*$ ]]
}

# Verificacion POST-paste PRE-submit (gotcha /exit fantasma): ¿el token esperado esta como texto
# REAL (no-dim) en la region del composer? Match LITERAL (index, no regex) con espacios
# normalizados (el box del TUI rellena/parte lineas con padding). Fallback sin composer
# identificable (TUIs sin '> ', p.ej. smoke con `cat`): busca en la cola visible del pane.
torc_torre_post_paste_ok() { # token (stdin = captura CON -e) -> ok (rc 0) | mismatch (rc 1)
  local tok="$1" cap region hay
  [ -n "$tok" ] || { printf 'mismatch\n'; return 1; }
  cap="$(torc_torre_strip_ghost)"
  region="$(printf '%s\n' "$cap" | torc_torre_composer_region)" || region="$cap"
  hay="$(printf '%s\n' "$region" | torc_torre_strip_ansi | sed -e 's/│/|/g' \
    | sed -E 's/[[:space:]]*[|][[:space:]]*/ /g' | tr '\n' ' ' | tr -s ' ')"
  # match LITERAL via index() con el token por ENVIRON (awk -v procesa backslashes) y espacios normalizados
  if printf '%s\n' "$hay" | TORRE_TOK="$tok" awk '
      BEGIN { tok=ENVIRON["TORRE_TOK"]; gsub(/[[:space:]]+/," ",tok) }
      { if (index($0, tok) > 0) f=1 } END { exit f?0:1 }'; then
    printf 'ok\n'; return 0
  fi
  printf 'mismatch\n'; return 1
}

# Porcentaje de contexto de la barra de estado ('ctx: NN%'). Ultimo match (la barra vive abajo).
# Sin match -> rc 1 (UNKNOWN fail-closed: jamas asumir 0).
torc_torre_ctx_pct() { # stdin = captura -> N ; rc 1 si no legible
  local pct
  pct="$(torc_torre_strip_ansi | grep -oiE 'ctx[:= ][[:space:]]*[0-9]{1,3}[[:space:]]*%' \
    | tail -1 | grep -oE '[0-9]{1,3}')" || return 1
  [ -n "$pct" ] || return 1
  printf '%s\n' "$pct"
}

# ¿Actividad (busy) en la captura? Marcador semantico positivo (patron tco_pane_busy).
torc_torre_busy_from() { # stdin = captura -> rc 0 busy | rc 1 idle
  torc_torre_strip_ansi | grep -qiE "${TORRE_BUSY_REGEX:-esc to interrupt}"
}

# ¿Aviso de limite de cuenta del CLI en la barra? (tope por reloj/cuenta — ref 09 §Monitor)
torc_torre_usage_warn() { # stdin = captura -> rc 0 si hay aviso
  torc_torre_strip_ansi | grep -qiE "${TORRE_USAGE_REGEX:-approaching.*limit|usage limit|resets at}"
}

# Seleccion de la sesion VIVA para el resume canonico (doctrina "mtime==AHORA, no hora mas alta").
# stdin: lineas "epoch<TAB>path" de los *.jsonl. Solo son candidatos los basenames UUID validos
# (torc_is_uuid — un archivo raro en el dir de transcripts JAMAS fluye al comando de lanzamiento).
# rc EXACTOS: 0 = un unico vivo (imprime su UUID) · 2 = ninguno vivo · 3 = ambiguo (>1 vivos).
torc_torre_pick_live() { # now_epoch window_s (stdin = "epoch<TAB>path") -> uuid
  local now="${1:-}" win="${2:-}" epoch path base uuid live="" n=0
  printf '%s %s' "$now" "$win" | grep -qE '^[0-9]+ [0-9]+$' || { torc_err "pick_live: now/window invalidos"; return 1; }
  while IFS=$'\t' read -r epoch path; do
    [ -n "$epoch" ] && [ -n "$path" ] || continue
    epoch="${epoch%%.*}"
    printf '%s' "$epoch" | grep -qE '^[0-9]+$' || continue
    base="$(basename "$path")"; uuid="${base%.jsonl}"
    torc_is_uuid "$uuid" || continue
    # vivo = |now - mtime| <= ventana (tolera reloj ligeramente adelantado)
    local d=$(( now - epoch )); [ "$d" -lt 0 ] && d=$(( -d ))
    if [ "$d" -le "$win" ]; then live="$uuid"; n=$((n+1)); fi
  done
  [ "$n" -eq 0 ] && return 2
  [ "$n" -gt 1 ] && return 3
  printf '%s\n' "$live"
}

# Extraccion ANTI-STALE del handoff de regreso (compact-60): SOLO el ULTIMO bloque delimitado por
# 'HANDOFF-INICIO <nonce>' / 'HANDOFF-FIN <nonce>' con nonce EXACTO (match literal via index).
# Bloques con otro nonce o sin nonce (handoffs viejos del scrollback) NUNCA matchean.
# rc EXACTOS: 0 = bloque extraido · 2 = sin bloque con ese nonce · 4 = truncado (INICIO sin FIN).
torc_torre_extract_handoff() { # nonce (stdin = captura con scrollback) -> contenido del bloque
  local nonce="$1"
  printf '%s' "$nonce" | grep -qE '^[A-Za-z0-9_-]+$' || { torc_err "extract_handoff: nonce invalido"; return 4; }
  torc_torre_strip_ansi | awk -v nonce="$nonce" '
    index($0, "HANDOFF-INICIO " nonce) { inblk=1; buf=""; open=1; next }
    index($0, "HANDOFF-FIN " nonce)    { if (inblk) { done=buf; havedone=1; inblk=0; open=0 } ; next }
    inblk { buf = buf $0 "\n" }
    END {
      # el ULTIMO estado del nonce manda: si su ultimo INICIO quedo abierto (truncado), rc 4
      # fail-closed — JAMAS caer a un bloque previo completo (seria un handoff stale/incompleto).
      if (open) exit 4
      if (havedone) { printf "%s", done; exit 0 }
      exit 2
    }'
}

# [TAL-8039] Lectura del handoff de regreso POR FICHERO (patron TAL-3619 de STOP-AUDIT): con el TUI
# en pantalla alternada capture-pane es solo el viewport y un handoff largo pierde su 'HANDOFF-INICIO'
# (compact-60 de C1 al 92 %: bloque en ~369 s, fuera del viewport). El actor ESCRIBE el bloque con
# Write en <fichero> (nonce en los marcadores); aqui se verifica el CONTENIDO, jamas el tamano de
# pantalla. Fail-closed: cada rechazo dice por que.
# rc EXACTOS: 0 = bloque verificado (stdout = su contenido) · 2 = sin handoff valido (fichero
# ausente / no regular o symlink / ANTIGUO: mtime previo a la peticion / sin bloque con ESTE nonce,
# incluido el de otra ejecucion) · 4 = bloque INCOMPLETO (INICIO sin FIN, nonce invalido o vacio).
torc_torre_read_handoff_file() { # fichero nonce since_epoch -> contenido del bloque
  local f="${1:-}" nonce="${2:-}" since="${3:-}" mtime out erc=0
  printf '%s' "$nonce" | grep -qE '^[A-Za-z0-9_-]+$' || { torc_err "read_handoff_file: nonce invalido"; return 4; }
  printf '%s' "$since" | grep -qE '^[0-9]+$' || { torc_err "read_handoff_file: since_epoch invalido"; return 4; }
  if [ -L "$f" ] || [ ! -f "$f" ]; then torc_info "handoff-fichero: ausente o no regular ($f)" >&2; return 2; fi
  mtime="$(stat -c %Y -- "$f" 2>/dev/null)" || { torc_info "handoff-fichero: no pude leer el mtime de $f" >&2; return 2; }
  printf '%s' "$mtime" | grep -qE '^[0-9]+$' || return 2
  if [ "$mtime" -lt "$since" ]; then
    torc_info "handoff-fichero: ANTIGUO (mtime $mtime < peticion $since) — de otra ejecucion, se ignora" >&2; return 2
  fi
  out="$(torc_torre_extract_handoff "$nonce" < "$f")" || erc=$?
  case "$erc" in
    0) : ;;
    2) torc_info "handoff-fichero: sin bloque con el nonce $nonce (otra ejecucion o aun sin escribir)" >&2; return 2 ;;
    *) torc_info "handoff-fichero: bloque INCOMPLETO (INICIO sin FIN)" >&2; return 4 ;;
  esac
  if [ -z "${out//[[:space:]]/}" ]; then torc_info "handoff-fichero: bloque VACIO" >&2; return 4; fi
  printf '%s\n' "$out"
}

# [TAL-8039] ¿Turno VIVO (justifica prorrogar)? Captura legible Y marcador de actividad. Una captura
# fallida (pane o sesion muerta) NO es «vivo»: a diferencia de torc_torre_busy (que ante la duda dice
# ocupado para no actuar a ciegas), prorrogar sobre un pane muerto solo gasta minutos hasta el tope.
torc_torre_alive() { # session -> 0 vivo | 1 parado/ilegible
  local cap
  cap="$(torc_torre_cap "$1" 2>/dev/null)" || return 1
  [ -n "$cap" ] || return 1
  printf '%s\n' "$cap" | grep -v '^$' | tail -8 | torc_torre_busy_from
}

# Relojes inyectables (los tests simulan los ~369 s sin dormirlos).
torc_torre_now()   { date +%s; }
torc_torre_sleep() { sleep "$1"; }

# [TAL-8039] Recoge el handoff de regreso: FICHERO primero, pantalla de RESPALDO (capture-pane 800,
# mismo extractor anti-stale), prorroga con tope mientras el turno siga VIVO. El plazo base es
# TORRE_HANDOFF_MAX; al vencer, si el pane sigue ocupado (torc_torre_alive) se prorroga TORRE_HANDOFF_EXTEND s, sin pasar de TORRE_HANDOFF_HARD_MAX desde
# el inicio; un turno PARADO o un pane ilegible (torc_torre_alive) no prorroga. stdout = contenido; rc 0 = recogido · 1 = sin handoff
# verificado (el llamador ABORTA antes de /compact). Loguea origen=fichero|pantalla.
torc_torre_collect_handoff() { # session nonce fichero since_epoch
  local s="$1" nonce="$2" f="$3" since="$4" start deadline hard now hf frc alive ferr why=""
  ferr="$(mktemp)" || { torc_err "collect_handoff: sin fichero temporal"; return 1; }
  start="$(torc_torre_now)"; deadline=$(( start + TORRE_HANDOFF_MAX )); hard=$(( start + TORRE_HANDOFF_HARD_MAX ))
  while :; do
    frc=0; hf="$(torc_torre_read_handoff_file "$f" "$nonce" "$since" 2>"$ferr")" || frc=$?
    [ -s "$ferr" ] && why="$(tail -1 "$ferr")"
    if [ "$frc" = 0 ] && [ -n "$hf" ]; then
      rm -f "$ferr"; torc_info "handoff origen=fichero ($f)" >&2; printf '%s\n' "$hf"; return 0
    fi
    hf=""; frc=0
    hf="$(torc_torre_cap "$s" 800 | torc_torre_extract_handoff "$nonce")" || frc=$?
    if [ "$frc" = 0 ] && [ -n "$hf" ]; then
      rm -f "$ferr"; torc_info "handoff origen=pantalla (RESPALDO: capture-pane; el fichero no llego)" >&2; printf '%s\n' "$hf"; return 0
    fi
    now="$(torc_torre_now)"
    if [ "$now" -ge "$deadline" ]; then
      alive=0; torc_torre_alive "$s" && alive=1    # turno VIVO = captura legible Y ocupado; captura fallida = NO vivo (aborta ya)
      if [ "$now" -lt "$hard" ] && [ "$alive" = 1 ]; then
        deadline=$(( now + TORRE_HANDOFF_EXTEND )); [ "$deadline" -gt "$hard" ] && deadline="$hard"
        torc_info "$s: plazo vencido con el turno VIVO — prorroga hasta +$(( deadline - start ))s (tope ${TORRE_HANDOFF_HARD_MAX}s)" >&2
      else
        torc_info "$s: sin handoff verificado a +$(( now - start ))s (turno $([ "$alive" = 1 ] && echo vivo || echo parado); tope ${TORRE_HANDOFF_HARD_MAX}s)" >&2
        [ -n "$why" ] && torc_info "$s: ultimo motivo del fichero: ${why#"${why%%[![:space:]]*}"}" >&2
        rm -f "$ferr"; return 1
      fi
    fi
    torc_torre_sleep "$TORRE_HANDOFF_POLL"
  done
}

# Nonce/run-id unico por ejecucion de compact (jamas marcadores fijos: anti-stale).
torc_torre_new_nonce() { printf 'torre_hf_%s_%s' "$(date +%s)" "$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }

# ---------------------------------------------------------------------------
# RUNTIME — tmux del HOST (sin incus; las sesiones torre-* corren en el host de la fabrica)
# ---------------------------------------------------------------------------

torc_torre_has_session() { tmux has-session -t "=$1" 2>/dev/null; }

# Sesiones torre-* vivas (una por linea, sin prefijo tmux extra).
torc_torre_sessions() { tmux list-sessions -F '#S' 2>/dev/null | grep -E "^${TORRE_SESSION_PREFIX}" || true; }

# Captura del pane (visible por defecto). -J reune soft-wraps (clave para parsear bloques largos).
torc_torre_cap() { # session [scrollback_n] [ansi(0|1)]
  local s="$1" sb="${2:-}" ansi="${3:-0}"
  local -a opts=(-p -J)
  [ "$ansi" = 1 ] && opts+=(-e)
  [ -n "$sb" ] && opts+=(-S "-$sb")
  tmux capture-pane -t "=$s:" "${opts[@]}" 2>/dev/null
}

torc_torre_clear_input() { # session — Escape descarta menu/seleccion; C-u borra la linea (patron tco)
  tmux send-keys -t "=$1:" Escape 2>/dev/null
  tmux send-keys -t "=$1:" C-u 2>/dev/null || true
}

# Envia TEXTO literal al composer SIN submit (-l: nunca key-names; el texto va como argv, sin shell).
torc_torre_send_literal() { # session text
  tmux send-keys -t "=$1:" -l -- "$2" 2>/dev/null
}

torc_torre_submit() { tmux send-keys -t "=$1:" C-m 2>/dev/null; }

# ¿pane ocupado? captura fallida = OCUPADO (fail-closed, patron tco_pane_busy).
torc_torre_busy() { # session -> 0 busy | 1 idle
  local cap
  cap="$(torc_torre_cap "$1" 2>/dev/null)" || return 0
  [ -n "$cap" ] || return 0
  printf '%s\n' "$cap" | grep -v '^$' | tail -8 | torc_torre_busy_from
}

torc_torre_idle_stable() { # session [n=3] [iv=2] — idle sostenido N capturas
  local n="${2:-3}" iv="${3:-2}" i
  for ((i=0;i<n;i++)); do torc_torre_busy "$1" && return 1; sleep "$iv"; done
  return 0
}

torc_torre_wait_idle() { # session [max_s] — deadline con reloj REAL (patron tco_wait_idle)
  local max="${2:-$TORRE_IDLE_MAX}" deadline
  deadline=$(( $(date +%s) + max ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    torc_torre_idle_stable "$1" 3 2 && return 0
    sleep 4
  done
  return 1
}

# Entrega verificada tras el submit: actividad (busy) O eco LITERAL del token en el pane.
torc_torre_verify_delivered() { # session [max_s] [token]
  local max="${2:-$TORRE_VERIFY_MAX}" tok="${3:-}" deadline cap
  deadline=$(( $(date +%s) + max ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    cap="$(torc_torre_cap "$1" 2>/dev/null | torc_torre_strip_ansi | grep -v '^$' | tail -12)" || cap=""
    printf '%s\n' "$cap" | torc_torre_busy_from && return 0
    [ -n "$tok" ] && printf '%s\n' "$cap" | grep -qF -- "$tok" && return 0
    sleep 2
  done
  return 1
}

# ---------------------------------------------------------------------------
# Relay ANTI-FANTASMA de UNA linea (secuencia completa; la usan torre-relay.sh y torre-compact.sh).
# rc EXACTOS: 0 entregado · 1 sin idle / entrega no confirmada · 3 cola real (queued: ESCALAR,
# jamas reintento ciego — duplica) · 4 mismatch post-paste (NO se hizo submit).
# ---------------------------------------------------------------------------
torc_torre_relay_line() { # session line token [verify_max] [queue(0|1)]
  local s="$1" line="$2" tok="$3" vmax="${4:-$TORRE_VERIFY_MAX}" queue="${5:-0}" st cap
  case "$line" in *$'\n'*) torc_err "relay_line: texto multilinea — usa archivo + 'lee <ruta>'"; return 1;; esac
  case "$line" in *"git push"*) torc_err "aviso: el relay contiene el literal 'git push' — fraseo prohibido por doctrina (usa 'sube la rama'); revisa antes de reenviar";; esac
  # 1) pre-check del composer con -e: cola real -> escalar; texto real ajeno -> no clobbear; ghost -> seguir
  st="$(torc_torre_cap "$s" "" 1 | torc_torre_input_state)"
  case "$st" in
    queued) torc_err "$s: cola REAL en el composer (Press up…) — NO se releva a ciegas; revisar con Up y decidir"; return 3 ;;
    text)   torc_err "$s: texto REAL pendiente en el composer (no es nuestro) — no clobbeo; captura con -e y decide"; return 4 ;;
    ghost)  torc_info "$s: ghost-text dim en el composer (autocomplete) — se ignora sin neutralizar" ;;
  esac
  # 2) baseline idle (salvo modo queue best-effort)
  if [ "$queue" != 1 ]; then
    torc_torre_wait_idle "$s" || { torc_err "$s: pane no llego a idle estable — no relevo"; return 1; }
    torc_torre_clear_input "$s"; sleep 1
  fi
  # 3) escribir el literal SIN submit
  torc_torre_send_literal "$s" "$line" || { torc_err "$s: send-keys fallo"; return 1; }
  sleep 0.5
  # 4) verificacion POST-paste PRE-submit (gotcha /exit fantasma): jamas submit a ciegas
  cap="$(torc_torre_cap "$s" "" 1)"
  if ! printf '%s\n' "$cap" | torc_torre_post_paste_ok "$tok" >/dev/null; then
    torc_err "$s: el composer NO refleja el texto esperado (mismatch post-paste) — ABORTO sin submit; pane intacto para inspeccion"
    return 4
  fi
  # 5) submit + entrega verificada; si aparece cola duplicada, NO reintentar (escalar)
  torc_torre_submit "$s" || { torc_err "$s: submit fallo"; return 1; }
  if torc_torre_verify_delivered "$s" "$vmax" "$tok"; then return 0; fi
  if torc_torre_cap "$s" | grep -qi 'press up to edit queued messages'; then
    torc_err "$s: el mensaje quedo ENCOLADO (pane ocupado) — no reintentar a ciegas (duplica); esperar o revisar"
    return 3
  fi
  [ "$queue" = 1 ] && { torc_err "$s: entrega best-effort NO confirmada (modo queue) — continua"; return 0; }
  torc_err "$s: entrega NO confirmada en ${vmax}s — ESCALAR (ni eco ni actividad)"
  return 1
}
