#!/usr/bin/env bash
# canario-main.sh — Canario de main: tras cada fusión, el gate `unit` SELLADO sobre la main nueva (talent-ceo, ref 08).
#
# Repo-agnóstico, token-only, sin MCP. Un choque semántico entre dos PR verdes por separado deja `main` roja y
# ningún gate por PR lo ve; el canario corre el gate sobre el `origin/main` real, en un runner que se le indica.
#
# Uso:
#   canario-main.sh --repo <clon> --estado <dir> --runner <spec> --runner-repo <ruta> --manifest <fichero> (--una-vez | --cada <s>)
#                   [--runner-user <u>] [--repo-slug <owner/repo>] [--gate <id>] [--tope <s>] [--sellado <run-gate-sealed.sh>]
#   canario-main.sh --help
#
# Un tick trae `origin/main` y, si el sha es nuevo, lo prueba en un worktree DESECHABLE bajo <estado> con
# `run-gate-sealed.sh <gate> --runner … --run-group rgcan<sha9> --sha S --base S --pr 0` (gate `unit` por defecto,
# tope 3600 s). `--una-vez` hace UN tick; `--cada <s>` los repite (60 s es el periodo de la fuente viva).
#
# Salida (stdout, una línea por veredicto) y registro (<estado>/canario.log):
#   CANARIO-MAIN-<sha9>-VERDE|ROJO|NO-MEDIDO …      CANARIO-FIN <sha9> <HH:MM:SSZ> rc=<rc> result=<PASS|FAIL|NO-MEDIDO>
# rc de un tick: 0 = nada nuevo o VERDE · 1 = ROJO · 3 = NO-MEDIDO · 2 = PRECONDICIÓN o fallo de E/S (candado ocupado incluido).
#
# ── EL VEREDICTO SALE DEL RECEIPT, NUNCA DEL JOURNAL NI DEL RC SOLO ───────────────────────────────
# VERDE = rc 0 del gate Y receipt con el sha de ESTA corrida, el gate pedido, `finished_at >= T0` (medido antes de
# lanzar) y result PASS. ROJO = rc 1 Y el mismo receipt con result FAIL. Todo lo demás es NO-MEDIDO, nunca rojo ni
# verde: rc >= 2 de run-gate-sealed.sh (2 precondición, 3 NO MEDIDO sellado, 124 tope), receipt ausente, ilegible, de
# otro sha, de otro gate o anterior a T0, result distinto de PASS/FAIL, o un rc que contradice al receipt. Tomar el
# último `unit rc=` de un journal dio un FALSO rojo (05-oct): un resultado viejo no es el de esta corrida.
#
# ── EL SHA SE MARCA HECHO SOLO TRAS UN VEREDICTO ───────────────────────────────────────────────────
# <estado>/canario-hechos.txt recibe el sha cuando hay VERDE o ROJO. Marcarlo antes de correr perdía el sha si el
# proceso moría a mitad de la corrida; un NO-MEDIDO tampoco lo marca: el tick siguiente lo reintenta (en modo
# `--cada` eso es un reintento cada <s> mientras el instrumento falle). Un proceso muerto deja el candado libre.
#
# ── UN SOLO CANARIO POR <estado> ───────────────────────────────────────────────────────────────────
# Candado de proceso (flock) sobre <estado>/canario.lock, tomado al arrancar y soltado al morir; el gate corre con el
# descriptor cerrado, así que un canario muerto no deja el candado en manos de sus hijos. Un segundo canario sale rc 2.
#
# ── CADA INTENTO TIENE SU DIRECTORIO DE RECEIPTS ───────────────────────────────────────────────────
# Un receipt solo vale si lo escribió ESTE intento. Cada intento usa su directorio propio y único (`mktemp -d`
# bajo <estado>/rec/): un receipt PASS que dejó un intento anterior, o un gate superviviente que escribe tarde, no
# está donde este intento lee, ni siquiera si ambos comparten el segundo medido (`finished_at >= T0` no los separa).
# Los directorios de un NO-MEDIDO se borran; los de un VERDE o un ROJO se conservan como evidencia.
#
# ── LEY DE CORTE: EL GATE VA EN SU PROPIA SESIÓN, CON SU GRUPO REGISTRADO ──────────────────────────
# El gate se lanza con `setsid`; su grupo (pgid == sid == pid) se registra al arrancar en <estado>/gate-activo
# («<pgid> <sha9> rgcan<sha9>»). Antes de señalarlo se verifica con `ps -o pid,pgid,sid,args`: que sea el grupo
# registrado y, si tiene líder, que su línea de órdenes contenga el lanzador sellado y su `--run-group`; si no
# coincide, NO se señala a nadie y el registro se descarta. Un TERM o INT al canario corta el gate registrado; un
# corte brusco (KILL) lo deja vivo y el tick siguiente lo retira ANTES de lanzar otro: nunca hay dos gates propios a
# la vez. Nada de `kill 0`, `pkill`, `pgrep` ni grupo derivado del padre. El `sleep` del bucle
# también va en su sesión: se señala solo su grupo registrado, si todos sus miembros son un `sleep <n>`.
#
# ── LO QUE NO HACE ─────────────────────────────────────────────────────────────────────────────────
# No sella en el bus, no revierte, no bloquea ventanas y no pone el ROJO por su cuenta: el sello
# `CANARIO-MAIN-<sha9>-VERDE|ROJO` lo pone una persona con `bus-sellar.sh` tras leer el caso.
# Un `fetch` que falla da `CANARIO-MAIN-NO-MEDIDO fetch-fallo` (sin sha, sin CANARIO-FIN) y rc 3.
set -uo pipefail
umask 077
export LC_ALL=C GIT_TERMINAL_PROMPT=0
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Un `shift 2` con la opcion como ULTIMO argumento no desplaza nada (rc != 0) y, sin `set -e`, el
# bucle vuelve a leer el mismo `$1`: BUCLE INFINITO. Se exige el valor ANTES de desplazar.
_exige_valor(){ [ "$1" -ge 2 ] || { printf '%s: PRECOND: %s exige un valor\n' "${0##*/}" "$2" >&2; exit 2; }; }
_precond() { printf 'canario-main: PRECOND: %s\n' "$1" >&2; exit 2; }

repo=''; estado=''; runner=''; runner_repo=''; runner_user=''; manifest=''; repo_slug=''
gate=unit; tope=3600; cada=''; una_vez=0; sellado=''
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) _exige_valor $# "$1"; repo="${2-}"; shift 2 ;;
    --estado) _exige_valor $# "$1"; estado="${2-}"; shift 2 ;;
    --runner) _exige_valor $# "$1"; runner="${2-}"; shift 2 ;;
    --runner-repo) _exige_valor $# "$1"; runner_repo="${2-}"; shift 2 ;;
    --runner-user) _exige_valor $# "$1"; runner_user="${2-}"; shift 2 ;;
    --manifest) _exige_valor $# "$1"; manifest="${2-}"; shift 2 ;;
    --repo-slug) _exige_valor $# "$1"; repo_slug="${2-}"; shift 2 ;;
    --gate) _exige_valor $# "$1"; gate="${2-}"; shift 2 ;;
    --tope) _exige_valor $# "$1"; tope="${2-}"; shift 2 ;;
    --sellado) _exige_valor $# "$1"; sellado="${2-}"; shift 2 ;;
    --cada) _exige_valor $# "$1"; cada="${2-}"; shift 2 ;;
    --una-vez) una_vez=1; shift ;;
    --help) sed -n '2,53p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "canario-main: argumento desconocido: $1" >&2; exit 2 ;;
  esac
done

# ── PRECONDICIONES: nada se toca hasta que todo está en forma ─────────────────────────────────────
for _par in "repo:$repo" "estado:$estado" "runner:$runner" "runner-repo:$runner_repo" "manifest:$manifest"; do
  [ -n "${_par#*:}" ] || _precond "falta --${_par%%:*}"
done
if [ "$una_vez" -eq 1 ] && [ -n "$cada" ]; then _precond "--una-vez y --cada son excluyentes"; fi
if [ "$una_vez" -eq 0 ] && [ -z "$cada" ]; then _precond "falta --una-vez o --cada <s>"; fi
[[ $runner =~ ^[A-Za-z0-9._:/@-]{1,128}$ ]] || _precond "--runner fuera del charset [A-Za-z0-9._:/@-]"
[[ $runner_repo =~ ^/[A-Za-z0-9._/-]{1,512}$ ]] || _precond "--runner-repo debe ser una ruta absoluta en [A-Za-z0-9._/-]"
[ -z "$runner_user" ] || [[ $runner_user =~ ^[A-Za-z0-9._-]{1,32}$ ]] || _precond "--runner-user fuera del charset [A-Za-z0-9._-]"
[ -z "$repo_slug" ] || [[ $repo_slug =~ ^[A-Za-z0-9._-]{1,64}/[A-Za-z0-9._-]{1,100}$ ]] || _precond "--repo-slug debe ser owner/repo"
[[ $gate =~ ^[A-Za-z0-9._:-]{1,64}$ ]] || _precond "--gate fuera del charset [A-Za-z0-9._:-]"
[[ $tope =~ ^[1-9][0-9]{0,5}$ ]] || _precond "--tope debe ser un entero de segundos (1..999999)"
[ -z "$cada" ] || [[ $cada =~ ^[1-9][0-9]{0,5}$ ]] || _precond "--cada debe ser un entero de segundos (1..999999)"
[ -d "$repo" ] && git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || _precond "--repo no es un clon git: $repo"
[ -f "$manifest" ] && [ ! -L "$manifest" ] || _precond "--manifest debe ser un fichero regular (no symlink): $manifest"
for _tool in setsid ps jq flock timeout git; do
  command -v "$_tool" >/dev/null 2>&1 || _precond "no hay $_tool en el PATH; el canario no puede cortar ni medir sin él"
done
[ -n "$sellado" ] || sellado="$HERE/../../../scripts/run-gate-sealed.sh"
[ -f "$sellado" ] || _precond "no existe run-gate-sealed.sh ($sellado); indícalo con --sellado"
[ ! -L "$estado" ] || _precond "--estado es un symlink: $estado"
mkdir -p -- "$estado" 2>/dev/null && [ -d "$estado" ] || _precond "no se pudo crear --estado: $estado"
repo="$(cd "$repo" && pwd -P)"; estado="$(cd "$estado" && pwd -P)"
manifest="$(cd "$(dirname "$manifest")" && pwd -P)/$(basename "$manifest")"
sellado="$(cd "$(dirname "$sellado")" && pwd -P)/$(basename "$sellado")"
: "${estado:?}"

lock="$estado/canario.lock"; hechos="$estado/canario-hechos.txt"; log="$estado/canario.log"; reg="$estado/gate-activo"
for _f in "$lock" "$hechos" "$log" "$reg"; do
  [ ! -L "$_f" ] || _precond "fichero de estado es symlink: $_f"
  [ ! -e "$_f" ] || [ -f "$_f" ] || _precond "fichero de estado no regular: $_f"
done
: >> "$hechos" && : >> "$log" || _precond "no se pudo crear el estado del canario en $estado"
exec 9>"$lock" || _precond "no se pudo abrir el candado: $lock"
flock -n 9 || _precond "otro canario tiene el candado de $estado (un solo canario por estado)"

# ── LIMPIEZA: el worktree desechable y el sueño en curso se retiran siempre ───────────────────────
WT_ACTUAL=''; SUENO_PID=''
_retira_wt() {   # <ruta>: solo bajo <estado>/wt-canario-*, nunca otra cosa
  local w="$1"
  case "$w" in "$estado"/wt-canario-[0-9a-f]*) ;; *) return 0 ;; esac
  git -C "$repo" worktree remove --force -- "$w" >/dev/null 2>&1 || true
  if [ -e "$w" ] || [ -L "$w" ]; then rm -rf -- "$w"; fi
  git -C "$repo" worktree prune >/dev/null 2>&1 || true
}

# ── LEY DE CORTE: grupos registrados y verificados, nunca un PID suelto ──────────────────────────────
GATE_PID=''
SUENO_PGID=''
_miembros() {   # <pgid>: "pid línea" de los miembros VIVOS de ese grupo Y de esa sesión (el gate se lanza con setsid: sid == pgid)
  local p g s st a
  while read -r p g s st a; do
    if [ "$g" = "$1" ] && [ "$s" = "$1" ] && [ "${st:0:1}" != Z ]; then printf '%s %s\n' "$p" "$a"; fi
  done < <(ps -eo pid=,pgid=,sid=,stat=,args= 2>/dev/null)
  return 0
}
_grupo_es_el_gate() {   # <pgid> <sha9>: con líder (pid == pgid), su línea lleva el lanzador sellado y su --run-group; sin líder, la sesión es la que creó este canario
  local lineas p a
  lineas="$(_miembros "$1")"
  [ -n "$lineas" ] || return 0
  while read -r p a; do
    if [ "$p" = "$1" ]; then
      case "$a" in *"$sellado"*"--run-group rgcan$2"*) return 0 ;; esac
      return 1
    fi
  done <<<"$lineas"
  return 0
}
_corta_gate() {   # <pgid> <sha9>: TERM y, si resiste, KILL al grupo VERIFICADO; rc 0 solo si no queda ningún miembro vivo
  local n
  [ -n "$(_miembros "$1")" ] || return 0
  _grupo_es_el_gate "$1" "$2" || return 1
  kill -TERM -- "-$1" 2>/dev/null
  n=0; while [ -n "$(_miembros "$1")" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done
  if [ -n "$(_miembros "$1")" ]; then
    kill -KILL -- "-$1" 2>/dev/null
    n=0; while [ -n "$(_miembros "$1")" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done
  fi
  [ -z "$(_miembros "$1")" ]
}
_lanza_sueno() {   # <s>: el sleep va en SU PROPIA sesión y su PGID (== pid) solo se REGISTRA tras comprobarlo con ps
  local n=0 p g s a
  setsid sleep "$1" </dev/null >/dev/null 2>&1 9>&- &
  SUENO_PID=$!
  while [ "$n" -lt 40 ]; do
    read -r p g s a < <(ps -o pid=,pgid=,sid=,args= -p "$SUENO_PID" 2>/dev/null) || return 0
    if [ "$p" = "$SUENO_PID" ] && [ "$g" = "$p" ] && [ "$s" = "$p" ] && [ "$a" = "sleep $1" ]; then SUENO_PGID="$p"; return 0; fi
    sleep 0.05; n=$((n+1))
  done
  return 0   # sin grupo comprobado NO se registra: el sleep acabará solo y no se señala a nadie
}
_corta_sueno() {   # señala SOLO el grupo registrado del sleep, y solo si TODOS sus miembros son un `sleep <n>`; los lista antes
  local lineas p a
  [ -n "$SUENO_PGID" ] || return 0
  lineas="$(_miembros "$SUENO_PGID")"
  [ -n "$lineas" ] || { SUENO_PGID=''; return 0; }
  while read -r p a; do
    [[ $a =~ ^sleep\ [0-9]+$ ]] || { echo "canario-main: el grupo $SUENO_PGID del sueño tiene un miembro que no es un sleep ($p); no se señala" >&2; return 1; }
  done <<<"$lineas"
  echo "canario-main: corto el grupo $SUENO_PGID del sueño: $(printf '%s' "$lineas" | tr '\n' ';')" >&2
  kill -TERM -- "-$SUENO_PGID" 2>/dev/null
  SUENO_PGID=''
  return 0
}
_retira_previo() {   # rc 0 = camino libre (no queda gate propio vivo) · rc 1 = hay un gate propio que no se pudo retirar
  local linea pg s9
  [ -e "$reg" ] || return 0
  linea="$(cat -- "$reg" 2>/dev/null)"
  if [[ $linea =~ ^([0-9]+)\ ([0-9a-f]{9})\ rgcan([0-9a-f]{9})$ ]] && [ "${BASH_REMATCH[2]}" = "${BASH_REMATCH[3]}" ]; then
    pg="${BASH_REMATCH[1]}"; s9="${BASH_REMATCH[2]}"
    if [ -n "$(_miembros "$pg")" ]; then
      if _grupo_es_el_gate "$pg" "$s9"; then
        _corta_gate "$pg" "$s9" || return 1
      else
        echo "canario-main: el grupo registrado $pg no es un gate propio; se descarta el registro SIN señalar a nadie" >&2
      fi
    fi
  else
    echo "canario-main: registro de gate ilegible; se descarta" >&2
  fi
  rm -f -- "$reg"
  return 0
}
_fin() {
  _corta_sueno || true
  if [ -n "$GATE_PID" ] && [ ! -e "$reg" ]; then   # cortado justo al lanzar: el gate escribe su registro lo primero
    local n=0; while [ ! -e "$reg" ] && [ "$n" -lt 20 ]; do sleep 0.1; n=$((n+1)); done
  fi
  if [ -n "$GATE_PID" ] || [ -e "$reg" ]; then _retira_previo || true; fi
  [ -z "$WT_ACTUAL" ] || _retira_wt "$WT_ACTUAL"
}
trap _fin EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

_lee_receipt() {   # <receipt> <sha> <gate> <t0> -> ausente | ilegible | otro-sha | otro-gate | sin-finished_at | anterior-a-T0 | sin-result | ok:<RESULT>
  [ -f "$1" ] && [ ! -L "$1" ] || { echo ausente; return 0; }
  jq -r --arg sha "$2" --arg gate "$3" --arg t0 "$4" '
    if type != "object" then "ilegible"
    elif .sha != $sha then "otro-sha"
    elif .gate_id != $gate then "otro-gate"
    elif ((.finished_at | type) != "string") or ((.finished_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) | not) then "sin-finished_at"
    elif .finished_at < $t0 then "anterior-a-T0"
    elif (.result | type) != "string" then "sin-result"
    else "ok:" + .result end' "$1" 2>/dev/null || echo ilegible
}

_tick() {   # rc 0 nada nuevo/VERDE · 1 ROJO · 3 NO-MEDIDO · 2 fallo de E/S
  local sha sha9 w t0 recdir rc_g codigo veredicto res motivo detalle fin args
  # Nunca se lanza un gate con otro propio vivo: el de un intento cortado se retira (registrado y verificado) o no se sigue.
  if ! _retira_previo; then
    printf 'CANARIO-MAIN-NO-MEDIDO gate-previo-vivo\n' || return 2
    return 3
  fi
  if ! git -C "$repo" fetch -q --no-tags origin '+refs/heads/main:refs/remotes/origin/main' </dev/null >/dev/null 2>&1; then
    printf 'CANARIO-MAIN-NO-MEDIDO fetch-fallo\n' || return 2
    return 3
  fi
  sha="$(git -C "$repo" rev-parse --verify -q 'refs/remotes/origin/main^{commit}' 2>/dev/null)" || sha=''
  if ! [[ $sha =~ ^[0-9a-f]{40}$ ]]; then
    printf 'CANARIO-MAIN-NO-MEDIDO sin-origin-main\n' || return 2
    return 3
  fi
  sha9="${sha:0:9}"
  if grep -qxF -- "$sha" "$hechos" 2>/dev/null; then return 0; fi

  w="$estado/wt-canario-$sha9"
  _retira_wt "$w"
  WT_ACTUAL="$w"
  rc_g=2; codigo=''; motivo=''; recdir=''
  if ! git -C "$repo" worktree add -q --detach "$w" "$sha" >/dev/null 2>&1; then
    motivo=worktree
  else
    t0="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if ! [[ $t0 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
      motivo=sin-hora
    else
      # Directorio de receipts PROPIO de este intento (nombre impredecible): lo que dejó otro intento no está aquí.
      mkdir -p -- "$estado/rec" && recdir="$(mktemp -d "$estado/rec/$sha9.XXXXXX")" || recdir=''
      if [ -z "$recdir" ]; then
        motivo=intento
      else
        args=("$gate" --runner "$runner" --runner-repo "$runner_repo" --repo "$w" --run-group "rgcan$sha9"
              --sha "$sha" --base "$sha" --manifest "$manifest" --receipts "$recdir" --pr 0)
        [ -z "$runner_user" ] || args+=(--runner-user "$runner_user")
        [ -z "$repo_slug" ] || args+=(--repo-slug "$repo_slug")
        # MARCA-DE-HECHO-SOLO-TRAS-VEREDICTO: aqui NO se escribe el sha en <estado>/canario-hechos.txt
        # El gate en SESIÓN PROPIA: registra su grupo (pid == pgid == sid) antes de exec y se espera con `wait`, de modo
        # que un TERM al canario interrumpe la espera y _fin puede cortarlo. Sin lock heredado (9>&-).
        setsid -w bash -c 'printf "%s %s rgcan%s\n" "$$" "$1" "$1" > "$2.tmp" && mv -f -- "$2.tmp" "$2" || exit 125; shift 2; exec "$@"' \
          _ "$sha9" "$reg" timeout "$tope" bash "$sellado" "${args[@]}" </dev/null >"$estado/gate-$sha9.log" 2>&1 9>&- &
        GATE_PID=$!
        wait "$GATE_PID"; rc_g=$?; GATE_PID=''
        codigo="$(_lee_receipt "$recdir/${gate//:/_}.json" "$sha" "$gate" "$t0")"
        # Barrido: nada de este gate queda vivo (un hijo huérfano del grupo registrado) y el registro se retira.
        _retira_previo || true   # si no se pudo, el registro queda y el tick siguiente no lanza nada hasta retirarlo
      fi
    fi
  fi
  _retira_wt "$w"; WT_ACTUAL=''

  case "$rc_g:$codigo" in
    0:ok:PASS) veredicto=VERDE; res=PASS; detalle="gate=$gate rc=0 result=PASS" ;;
    1:ok:FAIL) veredicto=ROJO; res=FAIL; detalle="gate=$gate rc=1 result=FAIL" ;;
    *)
      veredicto=NO-MEDIDO; res=NO-MEDIDO
      if [ -n "$motivo" ]; then :
      elif [ "$rc_g" -eq 124 ]; then motivo="tope-${tope}s"
      elif [ "$rc_g" -ge 2 ]; then motivo="rc-$rc_g"
      elif [ "${codigo#ok:}" = "$codigo" ]; then motivo="receipt-$codigo"
      else motivo="incoherente-rc$rc_g-receipt-${codigo#ok:}"
      fi
      motivo="${motivo//[^A-Za-z0-9._-]/?}"; motivo="${motivo:0:60}"
      detalle="gate=$gate motivo=$motivo rc=$rc_g (gate-$sha9.log)" ;;
  esac
  # Los receipts de un NO-MEDIDO no sirven de evidencia de nada: el directorio del intento se borra (solo bajo rec/<sha9>.XXXXXX).
  if [ "$veredicto" = NO-MEDIDO ] && [ -n "$recdir" ]; then
    case "$recdir" in "$estado"/rec/"$sha9".??????) rm -rf -- "$recdir" ;; esac
  fi
  fin="$(date -u +%H:%M:%SZ)"
  # Emitir, registrar y SOLO ENTONCES marcar hecho: si algo de esto falla, el sha no queda hecho y se reintenta.
  printf 'CANARIO-MAIN-%s-%s %s\n' "$sha9" "$veredicto" "$detalle" || return 2
  printf 'CANARIO-FIN %s %s rc=%s result=%s\n' "$sha9" "$fin" "$rc_g" "$res" >> "$log" || return 2
  if [ "$veredicto" != NO-MEDIDO ]; then printf '%s\n' "$sha" >> "$hechos" || return 2; fi
  case "$veredicto" in VERDE) return 0 ;; ROJO) return 1 ;; *) return 3 ;; esac
}

if [ "$una_vez" -eq 1 ]; then _tick; exit $?; fi
while :; do
  _tick; rc_tick=$?
  [ "$rc_tick" -ne 2 ] || echo "canario-main: el tick no pudo emitir o registrar (rc 2); se reintentará" >&2
  _lanza_sueno "$cada"
  wait "$SUENO_PID"; SUENO_PID=''; SUENO_PGID=''
done
