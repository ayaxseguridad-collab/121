#!/usr/bin/env bash
# behavior-watch.sh — Detecta un canal ACTIVO SIN PROGRESO y lo AVISA por el bus. SOLO avisa:
# no actúa jamás sobre el canal ni teclea en su pane; qué hacer con uno alertado lo decide el coordinador (ref 11).
#
# Uso:  behavior-watch.sh <canal-NN> [--report-only]
#
# rc: 0 SANO (busy) · 1 SANO (idle) · 2 UNKNOWN (fuente esencial no medible; NUNCA sella) ·
#     22 PROGRESO-ESTANCADO. Los rc 20 (LOOP) y 21 (RUNTIME-EXCESIVO) NO existen en este detector: quedan
#     para la 2.1 (PENDIENTE-2.1.md).
#
# PROGRESO-ESTANCADO = P1 (sesión busy) + P2 (run vigente) + las TRES condiciones, ninguna fuente sola:
#   (1) bytes del transcript sin cambio >= TC_STALL_WINDOW · (2) HEAD y porcelain del clon sin cambio en la
#   ventana · (3) descendientes de `claude`: ninguno, o ticks de CPU sin avance entre dos ticks.
# Ventanas por tick y persistidas: el estado guarda la última observación de cada reloj y DESDE CUÁNDO no
# cambia. El primer tick de un canal abre las ventanas y no vota (un vigía que nace gritando es
# indistinguible de uno roto). Medir, leer el bus, decidir y persistir van bajo el MISMO flock; el sello va
# fuera, con el marcador ya fijado bajo el candado (patrón de vigia-cuota.sh).
#
# Qué NO lee: el TEXTO de relevos, órdenes o prompts. Del transcript solo usa su tamaño en bytes (el principal
# más los de sus subagentes, <sid>/subagents/*.jsonl) y la corroboración estructural de turno en vuelo
# (tco_transcript_pending_tool_from: tipo de registro, marcador isSidechain, tipo de bloque e ids de tool_use/tool_result;
# NUNCA el valor de un mensaje, ni un prefijo); del bus, solo la CABECERA (<iso> [rol: R] [marcador: M]); la nota no se
# lee. No escribe bajo $TCO_RUNS_DIR. --report-only no crea nada: ni directorio de estado ni fichero de candado.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

BW_TOKEN=PROGRESO-ESTANCADO
BW_SELLAR="$HERE/../../talent-ceo/scripts/bus-sellar.sh"
BW_LEER="$HERE/../../talent-ceo/scripts/bus-leer.sh"

# [Seam inyectable] PID del proceso `claude` del pane (el mismo recorrido que _tco_carril_session:
# pane_pid, sus hijos y el propio pane, el primero cuyo cmdline es claude). rc 1 si no se resuelve.
_bw_claude_pid() { # carril pane
  local c pid cand ccmd
  c="$(tco_container "$1")"
  pid="$(incus exec "$c" -- su - "$TCO_CUSER" -c "tmux display-message -p -t '$2' '#{pane_pid}'" 2>/dev/null)"
  printf '%s' "$pid" | grep -qE '^[0-9]+$' || return 1
  for cand in $(incus exec "$c" -- su - "$TCO_CUSER" -c "pgrep -P $pid 2>/dev/null; printf '%s\n' $pid" 2>/dev/null); do
    ccmd="$(incus exec "$c" -- su - "$TCO_CUSER" -c "tr '\\0' ' ' < /proc/$cand/cmdline 2>/dev/null" 2>/dev/null)"
    case "$ccmd" in *claude*) printf '%s\n' "$cand"; return 0 ;; esac
  done
  return 1
}

# [Seam inyectable] Bytes de los transcripts de los SUBAGENTES de la sesión: el CLI los escribe en
# <proyecto>/<sid>/subagents/*.jsonl, APARTE del principal. Imprime la suma (0 si no hay ninguno); rc 1 si no
# se pudo leer (entonces la condición (1) no es medible: UNKNOWN, nunca «quieto»).
# Una lectura fallida NO puede salir como 0: sin directorio es 0 legítimo, pero un
# directorio que existe y no se puede leer o recorrer, o un find con rc ≠ 0, cortan antes de la marca TCO-FIN y
# la función da rc 1. La suma se hace aquí, fuera de la tubería remota (cuyo rc era el de awk). El sid va entre
# comillas simples en el -c: solo se acepta [A-Za-z0-9_-]. Seam del selftest: TCO_SUBAG_CMD <carril> <script>
# (vacío = el `incus exec … su - $TCO_CUSER -c` de los demás helpers), como TCO_PROC_CMD.
# «0» solo cuando la AUSENCIA se PRUEBA: `test -e` da falso tanto con ENOENT como con EACCES (un
# <sid> sin permiso de recorrido esconde su subagents). Si subagents no existe, el ancestro más cercano que SÍ existe
# (<sid>, o el directorio del proyecto) tiene que ser un directorio recorrible; si no, no se puede saber: rc 1.
# `find -H`: un subagents enlazado se sigue. El sid se valida sobre la cadena ENTERA.
# Un ENLACE solo prueba ausencia si su destino se resuelve: subagents o <sid> enlazados a un destino que
# no se alcanza (EACCES en su camino) dan `test -e` falso, y eso NO es «no existe»: rc 1. El mismo borde a nivel de
# fichero: una entrada *.jsonl de subagents que no es un fichero regular (un enlace) no se salta en silencio: rc 1.
# La rama del directorio del proyecto tiene su caso en el selftest (F-PROY-000/600).
_bw_subagent_bytes() { # carril sessionId
  local c slug base script out line s=0
  [[ "${2:-}" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || return 1
  c="$(tco_container "$1")"
  slug="$(_tco_claude_project_slug "$(tco_repo_path)")"
  base="/home/$TCO_CUSER/${TCO_TRANSCRIPT_DIR:-.claude/projects}/$slug"
  script="b='$base'; s=\"\$b/$2\"; d=\"\$s/subagents\"; if [ ! -e \"\$d\" ]; then [ -L \"\$d\" ] && exit 1; if [ -e \"\$s\" ]; then [ -d \"\$s\" ] && [ -x \"\$s\" ] || exit 1; else [ -L \"\$s\" ] && exit 1; [ -d \"\$b\" ] && [ -x \"\$b\" ] || exit 1; fi; echo TCO-FIN; exit 0; fi; [ -d \"\$d\" ] && [ -r \"\$d\" ] && [ -x \"\$d\" ] || exit 1; n=\"\$(find -H \"\$d\" -maxdepth 1 -name '*.jsonl' ! -type f -print -quit)\" || exit 1; [ -z \"\$n\" ] || exit 1; find -H \"\$d\" -maxdepth 1 -type f -name '*.jsonl' -printf '%s\\n' || exit 1; echo TCO-FIN"   # C:SUB-LEE
  if [ -n "${TCO_SUBAG_CMD:-}" ]; then
    out="$("$TCO_SUBAG_CMD" "$1" "$script" 2>/dev/null)" || return 1
  else
    out="$(incus exec "$c" -- su - "$TCO_CUSER" -c "$script" 2>/dev/null)" || return 1
  fi
  [ "$(printf '%s\n' "$out" | tail -n 1)" = TCO-FIN ] || return 1
  while IFS= read -r line; do
    [ "$line" = TCO-FIN ] && continue
    case "$line" in ''|*[!0-9]*) return 1 ;; esac
    s=$(( s + line ))
  done <<<"$out"
  printf '%s\n' "$s"
}

# Cabeceras del bus pendientes para el cursor behavior-<canal> -> epoch del sello MÁS RECIENTE del canal.
# Cuenta como sello del canal: marcador que empieza por «<canal>-» (sin distinguir mayúsculas) o rol
# igual al canal. Los VIGIA-* no cuentan nunca (el detector no se casa consigo mismo).
# Imprime el epoch o nada; rc 1 si el bus no se pudo leer (cursor mayor que el bus, sin TA_BUS, …).
_bw_bus_last() { # canal peek(0|1)
  local canal="$1" raw ts
  if [ "$2" = 1 ]; then raw="$(bash "$BW_LEER" --lector "behavior-$canal" --peek 2>/dev/null)" || return 1
  else raw="$(bash "$BW_LEER" --lector "behavior-$canal" 2>/dev/null)" || return 1; fi
  ts="$(printf '%s\n' "$raw" | awk -v c="$canal" '
    match($0, /^[^ ]+ \[rol: [^]]*\] \[marcador: [^]]*\]/) {
      cab = substr($0, RSTART, RLENGTH); t = cab; sub(/ .*$/, "", t)
      r = cab; sub(/^[^ ]+ \[rol: /, "", r); sub(/\].*$/, "", r)
      m = substr(cab, index(cab, "[marcador: ") + 11); sub(/\].*$/, "", m)
      if (toupper(substr(m, 1, 6)) == "VIGIA-") next
      if (toupper(substr(m, 1, length(c) + 1)) == toupper(c "-") || r == c) last = t
    }
    END { if (last != "") print last }')"
  [ -n "$ts" ] || return 0
  date -u -d "$ts" +%s 2>/dev/null || return 0
}

bw_main() { # C:VACIO
  local canal="${1:-}" report=0 dir state lock now sess sid status upd raw bytes lines inflight=no
  local live lrc runl p2rc run ph reason head por huella pid cpu ticks hijos bus_now prev="" first=1
  local t_since g_since t_delta='?' g_delta='?' c_delta='?' c1=u c2=u c3=u verdict rc tok newstate tmp
  local marcador="" estado="" bus_last='' bl_out write=1 sello=no srcs sub
  [ "${2:-}" = --report-only ] && report=1
  if ! printf '%s' "$canal" | grep -qE '^[A-Za-z0-9_-]{1,16}$' || { [ -n "${2:-}" ] && [ "$report" = 0 ]; }; then
    echo "uso: behavior-watch.sh <canal-NN> [--report-only]" >&2; return 2
  fi
  dir="$TCO_BEHAVIOR_DIR"; state="$dir/$canal.state"; lock="$dir/$canal.lock"
  if [ -L "$dir" ]; then echo "behavior-watch: PRECOND: $dir es symlink" >&2; return 2; fi
  if [ ! -d "$dir" ] && [ "$report" = 0 ]; then   # C:REPORT-NUEVO
    if ! { mkdir -p -- "$(dirname -- "$dir")" 2>/dev/null && mkdir -m 700 -- "$dir" 2>/dev/null; }; then
      echo "behavior-watch: PRECOND: no se pudo crear $dir" >&2; return 2
    fi
  fi
  for f in "$state" "$lock"; do
    if [ -L "$f" ]; then echo "behavior-watch: PRECOND: $f es symlink" >&2; return 2; fi
    if [ -e "$f" ] && [ ! -f "$f" ]; then echo "behavior-watch: PRECOND: $f no es regular" >&2; return 2; fi
  done
  if [ "$report" = 1 ]; then
    # Solo lectura: sin candado todavía no hay escritor que excluir; con él, se toma compartido sin crear nada.
    if [ -f "$lock" ]; then
      exec 9<"$lock" || { echo "behavior-watch: PRECOND: lock no abrible: $lock" >&2; return 2; }
      flock -s -w 30 9 || { echo "behavior-watch: PRECOND: lock no adquirible" >&2; return 2; }                         # C:LOCK
    fi
  else
    exec 9>>"$lock" || { echo "behavior-watch: PRECOND: lock no abrible: $lock" >&2; return 2; }
    flock -x -w 30 9 || { echo "behavior-watch: PRECOND: lock no adquirible" >&2; return 2; }                           # C:LOCK
  fi

  # ── Medir, bajo el candado ─────────────────────────────────────────────────────────────────────
  now="$(date +%s)"
  live=unknown; bytes=''
  if sess="$(_tco_carril_session "$canal" "$(tco_pane_dev)")"; then
    read -r sid status upd _ <<<"$sess"
    if raw="$(_tco_carril_transcript "$canal" "$sid")"; then
      bytes="$(printf '%s\n' "$raw" | head -1)"
      # el reloj (1) suma los transcripts de los subagentes: un subagente trabajando no es quietud
      if sub="$(_bw_subagent_bytes "$canal" "$sid")"; then bytes=$(( bytes + sub )); else bytes=''; fi   # C:SUBAG
      lines="$(printf '%s\n' "$raw" | tail -n +2)"
      printf '%s\n' "$lines" | tco_transcript_pending_tool_from && inflight=yes   # C:INFLIGHT
      tco_session_liveness_from "$status" "$upd" "$inflight"; lrc=$?
      case "$lrc" in 0) live=busy ;; 1) live=idle ;; esac
    fi
  fi
  runl="$(tco_active_run_for "$canal")"; p2rc=$?   # C:W-DET-RO (el detector solo LEE $TCO_RUNS_DIR)
  read -r run ph reason <<<"$runl"
  huella=''
  if head="$(_tco_carril_git "$canal" rev-parse HEAD)" && [ -n "$head" ] && por="$(_tco_carril_git "$canal" status --porcelain)"; then
    huella="$head:$(printf '%s' "$por" | sha256sum | cut -c1-64)"
  fi
  ticks=''; hijos=''
  if pid="$(_bw_claude_pid "$canal" "$(tco_pane_dev)")" && cpu="$(tco_children_cpu_ticks "$canal" "$pid")"; then
    read -r ticks hijos <<<"$cpu"
  fi
  bus_now=''; bl_out=0
  if [ "$report" = 1 ]; then bus_now="$(_bw_bus_last "$canal" 1)" || bl_out=1
  else bus_now="$(_bw_bus_last "$canal" 0)" || bl_out=1; fi

  # ── Estado previo y descarte de lo más viejo ─────────────────────────────────────────────────
  if [ -f "$state" ] && jq -e '.v == 1' "$state" >/dev/null 2>&1; then prev="$(cat "$state")"; first=0; fi
  if [ "$first" = 0 ] && [ "$(jq -r '.obs_ts // 0' <<<"$prev")" -gt "$now" ]; then write=0; fi   # C:LOCK

  # Relojes: «desde cuándo no cambia». Una fuente ilegible en este tick se OLVIDA (su ventana se reabre).
  t_since=''; g_since=''
  if [ -n "$bytes" ]; then
    t_since="$now"
    if [ "$first" = 0 ] && [ "$(jq -r '.transcript.bytes // empty' <<<"$prev")" = "$bytes" ]; then
      t_since="$(jq -r '.transcript.since' <<<"$prev")"; t_delta=0
    elif [ "$first" = 0 ] && [ -n "$(jq -r '.transcript.bytes // empty' <<<"$prev")" ]; then
      t_delta=$(( bytes - $(jq -r '.transcript.bytes' <<<"$prev") ))
    fi
  fi
  if [ -n "$huella" ]; then
    g_since="$now"
    if [ "$first" = 0 ] && [ "$(jq -r '.git.huella // empty' <<<"$prev")" = "$huella" ]; then
      g_since="$(jq -r '.git.since' <<<"$prev")"; g_delta=no
    elif [ "$first" = 0 ] && [ -n "$(jq -r '.git.huella // empty' <<<"$prev")" ]; then
      g_delta=yes
    fi
  fi
  if [ -n "$hijos" ]; then
    if [ "$hijos" = 0 ]; then c_delta=none
    elif [ "$first" = 0 ] && [ -n "$(jq -r '.cpu.ticks // empty' <<<"$prev")" ] && [ "$(jq -r '.cpu.hijos // 0' <<<"$prev")" != 0 ]; then
      c_delta=$(( ticks - $(jq -r '.cpu.ticks' <<<"$prev") ))
    fi
  fi

  # ── Condiciones de PROGRESO-ESTANCADO: y (sí) · n (no) · u (no medible) ──────────────────────
  if [ -n "$t_since" ]; then [ $(( now - t_since )) -ge "$TC_STALL_WINDOW" ] && c1=y || c1=n; fi   # C:STALL-1
  if [ -n "$g_since" ]; then [ $(( now - g_since )) -ge "$TC_STALL_WINDOW" ] && c2=y || c2=n; fi   # C:STALL-2
  if [ -n "$hijos" ]; then
    if [ "$hijos" = 0 ] || [ "$c_delta" = 0 ]; then c3=y; else c3=n; fi                          # C:STALL-3
  fi

  # ── Veredicto ────────────────────────────────────────────────────────────────────────────────
  if [ "$live" = unknown ]; then verdict=UNKNOWN; rc=2                                               # C:UNK
  elif [ "$live" = idle ]; then verdict=SANO; rc=1                                                   # C:P1
  elif [ "$p2rc" = 2 ]; then verdict=UNKNOWN; rc=2                                                   # C:UNK
  elif [ "$p2rc" != 0 ]; then verdict=SANO; rc=0                                                     # C:P2
  elif [ "$first" = 1 ]; then verdict=SANO; rc=0
  else
    srcs="$c1$c2$c3"
    case "$srcs" in
      *n*) verdict=SANO; rc=0 ;;
      *u*) verdict=UNKNOWN; rc=2 ;;                                                                  # C:UNK
      *) verdict="$BW_TOKEN"; rc=22 ;;                                                               # C:RC22
    esac
  fi

  # ── Transición del token (el marcador se fija AQUÍ, bajo el candado) ─────────────────────────
  tok='null'
  if [ "$first" = 0 ]; then tok="$(jq -c --arg t "$BW_TOKEN" '.tokens[$t] // null' <<<"$prev")"; fi
  if [ "$verdict" = "$BW_TOKEN" ]; then
    if [ "$tok" = null ]; then
      tok="$(jq -nc --argjson n "$now" --arg m "VIGIA-$BW_TOKEN-$canal-$now" '{first_seen:$n,last_seen:$n,estado:"pendiente",marcador:$m}')"
    else
      tok="$(jq -c --argjson n "$now" '.last_seen = $n' <<<"$tok")"
    fi
    estado="$(jq -r '.estado' <<<"$tok")"; marcador="$(jq -r '.marcador' <<<"$tok")"
    [ "$estado" = pendiente ] && sello=yes
  elif [ "$verdict" != UNKNOWN ]; then
    tok='null'   # pasó a falso: se borra; la próxima transición lleva otro first_seen y otro marcador
  fi

  bus_last="$( [ "$first" = 0 ] && jq -r '.bus_last // empty' <<<"$prev")"
  if [ -n "$bus_now" ] && { [ -z "$bus_last" ] || [ "$bus_now" -gt "$bus_last" ]; }; then bus_last="$bus_now"; fi

  if [ "$report" = 0 ] && [ "$write" = 1 ]; then
    newstate="$(jq -nc --argjson n "$now" --arg b "$bytes" --arg ts "$t_since" --arg h "$huella" --arg gs "$g_since" \
      --arg tk "$ticks" --arg hj "$hijos" --arg bl "$bus_last" --arg t "$BW_TOKEN" --argjson tok "$tok" '{
        v: 1, obs_ts: $n,
        transcript: (if $b == "" then null else {bytes: ($b|tonumber), since: ($ts|tonumber)} end),
        git: (if $h == "" then null else {huella: $h, since: ($gs|tonumber)} end),
        cpu: (if $hj == "" then null else {ticks: ($tk|tonumber), hijos: ($hj|tonumber)} end),
        bus_last: (if $bl == "" then null else ($bl|tonumber) end),
        tokens: (if $tok == null then {} else {($t): $tok} end)}')"
    tmp="$(mktemp "$dir/.$canal.state.XXXXXX")" || { echo "behavior-watch: no se pudo crear el temporal" >&2; return 2; }
    if ! { printf '%s\n' "$newstate" > "$tmp" && mv -f "$tmp" "$state"; }; then
      rm -f -- "${tmp:?}"; echo "behavior-watch: no se pudo persistir" >&2; return 2
    fi
  fi
  flock -u 9 2>/dev/null || true
  exec 9>&-

  local bl_txt=none
  if [ -n "$bus_last" ]; then bl_txt=$(( now - bus_last )); elif [ "$bl_out" = 1 ]; then bl_txt='?'; fi
  local salida
  salida="$(printf 'behavior: %s · rc %s · liveness=%s · active_run=%s run_reason=%s · phase=%s · transcript_delta=%s git_delta=%s cpu_delta=%s · bus_last=%s' \
    "$verdict" "$rc" "$live" "${run:-no}" "${reason:-state_unreadable}" "${ph:--}" "$t_delta" "$g_delta" "$c_delta" "$bl_txt")"
  printf '%s\n' "$salida"

  # ── Aviso por transición, FUERA del candado. Solo rc 0, o rc 3 de ESE marcador, pasan a avisado ──
  if [ "$report" = 0 ] && [ "$write" = 1 ] && [ "$sello" = yes ]; then
    local src
    bash "$BW_SELLAR" --marcador "$marcador" --rol "${TA_ROL:-}" --nota "$salida" >/dev/null 2>&1; src=$?
    if [ "$src" = 0 ] || [ "$src" = 3 ]; then                                                         # C:SELLO
      tmp=''
      if exec 9>>"$lock" && flock -x -w 30 9 && tmp="$(mktemp "$dir/.$canal.state.XXXXXX")" &&
         jq -c --arg t "$BW_TOKEN" --arg m "$marcador" \
           'if .tokens[$t].marcador == $m then .tokens[$t].estado = "avisado" else . end' "$state" > "$tmp" &&
         mv -f "$tmp" "$state"; then :
      else
        [ -n "$tmp" ] && rm -f -- "${tmp:?}"
        echo "behavior-watch: sellado pero no se pudo marcar avisado; se reintentará" >&2
      fi
      exec 9>&-
    else
      echo "behavior-watch: el sellador devolvió rc $src: la transición queda PENDIENTE y se reintenta en el próximo tick" >&2
    fi
  fi
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  bw_main "$@"; exit $?
fi
