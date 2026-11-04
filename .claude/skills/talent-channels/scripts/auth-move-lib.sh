#!/usr/bin/env bash
# auth-move-lib.sh — MOVE transaccional de credenciales entre endpoints (TAL-2294).
#
# PRINCIPIO: un login funcional vive en UN solo lugar a la vez. Codex rota el refresh
# token en cada uso (de un solo uso): clonar/fan-out re-arma la cascada de deslogueos.
# Por eso Codex se MUEVE (nunca se copia) con este protocolo transaccional. Claude usa
# propagación por copia (ruta primaria, decisión del lead) — ver refresh-claude-auth.sh.
#
# Contratos del protocolo (plan TAL-2288 rev 10, GO del 2026-07-10):
#   - Endpoints TIPADOS: host:<hostname> · channel:<container> · pool:<pozo-id>.
#     Locks/freezes/journal se derivan del endpoint canónico (hash sha256-12) para que
#     host→canal, pozo→canal y canal→canal no colisionen entre espacios de nombres.
#   - TRES locks flock (cuenta + donante + destino) adquiridos en orden determinista
#     (sort lexicográfico de paths). La POSESIÓN se prueba por FDs flock ABIERTOS del
#     proceso (readlink /proc/self/fd), no por PID almacenado (stale/reuso).
#   - FREEZE durable por endpoint ANTES de matar procesos: los entrypoints soportados
#     (launcher v*, relaunch de refresh-*) rechazan arrancar con freeze presente. La
#     ÚNICA vía de ejecución bajo freeze es la autorizada: tx_id coincidente con el
#     freeze + journal vigente + posesión real de los locks (am_authorized_gate).
#   - Punto de COMMIT = mv atómico en destino tras digest verificado, ANTES de cualquier
#     petición desde el destino (un timeout NO demuestra que el servidor no consumió el
#     refresh). Todo fallo post-mv se repara EN DESTINO; jamás se restaura al donante.
#   - Journal durable (temp+fsync+rename+fsync-dir) con fases:
#       PREPARED → ORIGIN_RETIRED → INSTALL_INTENT → DEST_INSTALLED(=COMMIT) → VERIFIED → DONE
#     INSTALL_INTENT se persiste ANTES del mv y DEST_INSTALLED DESPUÉS (el mv ocurre en
#     el contenedor y el journal en el host: no hay atomicidad entre filesystems). La
#     reconciliación decide por fase + INSPECCIÓN de hechos (digest en destino manda).
#   - DURABILIDAD ≠ atomicidad: fsync de archivo Y directorio en snapshot, temporal de
#     destino, final de destino y journal. Un fsync fallido ABORTA sin cleanup.
#   - Cleanup (snapshot + .consumed) SOLO cuando auth destino + journal DEST_INSTALLED
#     son durables. El snapshot es la última copia: no muere antes.
#   - Propiedad en el ledger al COMMIT (DEST_INSTALLED); VERIFIED es solo salud.
#   - Coordinador ÚNICO: guard coordinator_host del ledger vs hostname (fail-closed).
#     Una segunda estación exigiría lease compartida por cuenta (NO soportado).
#
# Se "source-ea" (igual que lib.sh). CLI en auth-move.sh. Tests en ../tests/run-tests.sh
# (PATH-shims + failpoints AM_FAILPOINT/AM_FAIL_FSYNC, solo activos con AM_TEST=1).
# shellcheck shell=bash
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../talent-channel-operation/scripts/lib-modelos.sh"

# --- dependencias del skill (SECRET_DIR, CUSER, tc_*): el caller debe haber sourceado
#     00-config.sh + lib.sh ANTES (auth-move.sh lo hace). Fail-closed si faltan.
am_require_env() {
  [ -n "${SECRET_DIR:-}" ] || { echo "ERROR: SECRET_DIR no definido (sourcea 00-config.sh)" >&2; return 1; }
  [ -n "${CUSER:-}" ]      || { echo "ERROR: CUSER no definido (sourcea 00-config.sh)" >&2; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 requerido (fsync/journal/ledger)" >&2; return 1; }
}

am_info() { printf '  [move] %s\n' "$*"; }
am_err()  { printf 'ERROR [move]: %s\n' "$*" >&2; }
am_die()  { am_err "$*"; exit 1; }

# Timeout duro de las requests funcionales one-shot (salida silenciada siempre).
: "${AM_HC_TIMEOUT:=90}"

# ---------------------------------------------------------------------------
# Failpoints del arnés (SOLO con AM_TEST=1; en producción son no-ops).
#   AM_FAILPOINT=<nombre>  → muerte ABRUPTA (kill -9, sin traps) en ese punto.
#   AM_FAIL_FSYNC=<substr> → el fsync de un path que contenga <substr> FALLA.
# Puntos: pre_persist_<FASE> / post_persist_<FASE> / pre_mv / post_mv (contrato M8).
# ---------------------------------------------------------------------------
am_failpoint() {
  [ "${AM_TEST:-0}" = "1" ] || return 0
  [ "${AM_FAILPOINT:-}" = "$1" ] || return 0
  am_err "FAILPOINT '$1' — muerte abrupta (arnés)"
  kill -9 "${BASHPID:-$$}"
}

# ---------------------------------------------------------------------------
# Endpoints tipados (M1-r9). Canónico: host:<id> | channel:<name> | pool:<id>.
# pool:<id> = contenedor incus cuyo nombre es <id> (los pozos son contenedores con
# login pre-cargado). host:<id> exige <id> == hostname local (solo ejecución local).
# ---------------------------------------------------------------------------
am_ep_validate() { # endpoint → rc 0/1
  case "$1" in
    host:?*|channel:?*|pool:?*) ;;
    *) am_err "endpoint inválido '$1' (esperado host:<id> | channel:<name> | pool:<id>)"; return 1 ;;
  esac
  case "${1#*:}" in
    *[!A-Za-z0-9._-]*) am_err "endpoint '$1': id con charset no permitido"; return 1 ;;
  esac
  if [ "${1%%:*}" = "host" ] && [ "${1#host:}" != "$(hostname)" ]; then
    am_err "endpoint '$1': este proceso corre en '$(hostname)' — solo se opera el host local"
    return 1
  fi
}
am_ep_type() { printf '%s' "${1%%:*}"; }
am_ep_id()   { printf '%s' "${1#*:}"; }

# HOME del agente en el endpoint. AM_TEST_CROOT es un seam SOLO de test (arnés): reubica los HOME de
# los endpoints tipo contenedor bajo un sandbox local para poder ejercitar el flujo sin incus real.
am_ep_home() {
  case "$(am_ep_type "$1")" in
    host) printf '%s' "$HOME" ;;
    *)    if [ -n "${AM_TEST_CROOT:-}" ]; then printf '%s/%s/home/%s' "$AM_TEST_CROOT" "$(am_ep_id "$1")" "$CUSER"; else printf '/home/%s' "$CUSER"; fi ;;
  esac
}
# Path relativo del auth por agente (codex|claude).
am_auth_rel() {
  case "$1" in
    codex)  printf '.codex/auth.json' ;;
    claude) printf '.claude/.credentials.json' ;;
    *) am_err "agente '$1' desconocido (codex|claude)"; return 1 ;;
  esac
}
am_ep_auth_path()   { printf '%s/%s' "$(am_ep_home "$1")" "$(am_auth_rel "$2")"; }
am_ep_freeze_path() { local ap; ap="$(am_ep_auth_path "$1" "$2")"; printf '%s/.move-freeze' "${ap%/*}"; }

# Ejecuta un comando (string) en el endpoint COMO ROOT del namespace del endpoint
# (host: shell del usuario invocador; contenedor: root — ownership se maneja explícito).
am_ep_exec() { # endpoint cmd
  local ep="$1"; shift
  case "$(am_ep_type "$ep")" in
    host) bash -c "$1" ;;
    *)    incus exec "$(am_ep_id "$ep")" -- bash -c "$1" ;;
  esac
}
# Ejecuta como el USUARIO del agente en el endpoint (para one-shots de codex/claude).
am_ep_exec_user() { # endpoint cmd
  local ep="$1"; shift
  case "$(am_ep_type "$ep")" in
    host) bash -c "$1" ;;
    *)    incus exec "$(am_ep_id "$ep")" -- su - "$CUSER" -c "$1" ;;
  esac
}

am_ep_exists() { am_ep_exec "$1" "[ -f $(printf '%q' "$2") ]"; }
am_ep_sha256() { am_ep_exec "$1" "sha256sum $(printf '%q' "$2")" | awk '{print $1}'; }

# fsync de archivo + su directorio EN el endpoint. Con AM_TEST=1 y AM_FAIL_FSYNC
# matcheando el path, falla (inyección del arnés). rc != 0 → el caller ABORTA.
am_ep_fsync() { # endpoint path
  if [ "${AM_TEST:-0}" = "1" ] && [ -n "${AM_FAIL_FSYNC:-}" ] && [[ "$2" == *"${AM_FAIL_FSYNC}"* ]]; then
    am_err "fsync INYECTADO como fallido para '$2' (arnés)"; return 1
  fi
  am_ep_exec "$1" "python3 -c '
import os, sys
p = sys.argv[1]
fd = os.open(p, os.O_RDONLY); os.fsync(fd); os.close(fd)
d = os.path.dirname(p) or \".\"
fd = os.open(d, os.O_RDONLY); os.fsync(fd); os.close(fd)
' $(printf '%q' "$2")"
}
# fsync SOLO del directorio (tras rm/mv de un archivo del dir).
am_ep_fsync_dir() { # endpoint dir
  if [ "${AM_TEST:-0}" = "1" ] && [ -n "${AM_FAIL_FSYNC:-}" ] && [[ "$2" == *"${AM_FAIL_FSYNC}"* ]]; then
    am_err "fsync-dir INYECTADO como fallido para '$2' (arnés)"; return 1
  fi
  am_ep_exec "$1" "python3 -c '
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY); os.fsync(fd); os.close(fd)
' $(printf '%q' "$2")"
}

# ---------------------------------------------------------------------------
# Escritura DURABLE host-side: temp EN EL MISMO directorio persistente que el
# destino final (nunca mktemp default en /tmp: tmpfs no durable + rename EXDEV),
# fsync archivo → rename → fsync dir. Contenido por stdin.
# ---------------------------------------------------------------------------
am_write_durable_host() { # dest_path  (contenido por stdin)
  local dest="$1" dir tmp
  dir="${dest%/*}"; mkdir -p "$dir"; chmod 700 "$dir"
  tmp="$dir/.tmp.$$.$RANDOM"
  ( umask 077; cat > "$tmp" ) || { rm -f "$tmp"; return 1; }
  am_ep_fsync "host:$(hostname)" "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  am_ep_fsync_dir "host:$(hostname)" "$dir"
}

# ---------------------------------------------------------------------------
# Locks (B1-r8). Clave → path por hash (evita colisión entre namespaces y chars
# raros). El lockfile guarda la clave en texto para diagnóstico humano.
# Posesión = FD flock abierto en ESTE proceso (verificable por /proc/self/fd).
# ---------------------------------------------------------------------------
am_lock_path() { # clave-canónica
  local h; h="$(printf '%s' "$1" | sha256sum | cut -c1-12)"
  printf '%s/locks/%s.lock' "$SECRET_DIR" "$h"
}
# Adquiere N locks en orden determinista. Puebla AM_LOCK_FDS / AM_LOCK_PATHS.
# flock -n: un segundo MOVE concurrente sobre cualquiera de las claves → RECHAZO.
declare -a AM_LOCK_FDS=() AM_LOCK_PATHS=()
am_acquire_locks() { # clave...
  local k p fd paths=()
  mkdir -p "$SECRET_DIR/locks"; chmod 700 "$SECRET_DIR/locks"
  for k in "$@"; do
    p="$(am_lock_path "$k")"
    [ -e "$p" ] || ( umask 077; printf '%s\n' "$k" > "$p" )
    paths+=("$p")
  done
  # Orden determinista GLOBAL: sort lexicográfico de paths (mismo orden en move,
  # repair y resume → sin deadlock ABBA entre operaciones concurrentes).
  mapfile -t paths < <(printf '%s\n' "${paths[@]}" | sort -u)
  for p in "${paths[@]}"; do
    # Adquisición PARCIAL: si falla el 2.º/3.er lock hay que SOLTAR los ya tomados antes de
    # retornar. Si no, quedan retenidos en este PID y un reintento se auto-bloquea (cada open()
    # es una OFD distinta y flock es incompatible entre OFDs del mismo proceso).
    if ! exec {fd}<>"$p"; then
      am_err "no pude abrir lock $p"; am_release_locks; return 1
    fi
    if ! flock -n "$fd"; then
      exec {fd}>&- || true
      am_err "lock OCUPADO ($p → clave '$(head -1 "$p" 2>/dev/null)') — otro MOVE en curso; espera o resuelve su tx"
      am_release_locks; return 1
    fi
    AM_LOCK_FDS+=("$fd"); AM_LOCK_PATHS+=("$p")
  done
}
am_release_locks() {
  local fd
  for fd in "${AM_LOCK_FDS[@]:-}"; do [ -n "$fd" ] && exec {fd}>&- 2>/dev/null || true; done
  AM_LOCK_FDS=(); AM_LOCK_PATHS=()
}
# ¿Este proceso POSEE los locks? (readlink de /proc/self/fd → el path exacto).
am_locks_held() {
  local i fd p
  [ "${#AM_LOCK_FDS[@]}" -gt 0 ] || return 1
  for i in "${!AM_LOCK_FDS[@]}"; do
    fd="${AM_LOCK_FDS[$i]}"; p="${AM_LOCK_PATHS[$i]}"
    [ "$(readlink "/proc/self/fd/$fd" 2>/dev/null)" = "$p" ] || return 1
  done
}

# ---------------------------------------------------------------------------
# Journal durable por transacción: $SECRET_DIR/journal/<tx_id>.json
# ---------------------------------------------------------------------------
am_journal_dir()  { printf '%s/journal' "$SECRET_DIR"; }
am_journal_path() { printf '%s/%s.json' "$(am_journal_dir)" "$1"; }

am_journal_write() { # tx_id fase  (resto de campos desde las AM_* globales)
  local tx="$1" fase="$2" jp
  mkdir -p "$(am_journal_dir)"; chmod 700 "$(am_journal_dir)"
  jp="$(am_journal_path "$tx")"
  am_failpoint "pre_persist_${fase}"
  AM_J_TX="$tx" AM_J_FASE="$fase" AM_J_CUENTA="${AM_CUENTA:-}" AM_J_AGENT="${AM_AGENT:-}" \
  AM_J_FROM="${AM_FROM:-}" AM_J_TO="${AM_TO:-}" AM_J_DIGEST="${AM_DIGEST:-}" \
  AM_J_SNAPSHOT="${AM_SNAPSHOT:-}" AM_J_NOTE="${3:-}" AM_J_PREV="$jp" \
  python3 - <<'PY' > "$(am_journal_dir)/.render.$$" || return 1
import json, os, datetime
prev = {}
p = os.environ["AM_J_PREV"]
if os.path.exists(p):
    with open(p) as f:
        prev = json.load(f)
j = prev
j.update({
    "tx_id":    os.environ["AM_J_TX"],
    "fase":     os.environ["AM_J_FASE"],
    "cuenta":   os.environ["AM_J_CUENTA"],
    "agent":    os.environ["AM_J_AGENT"],
    "donante":  os.environ["AM_J_FROM"],
    "destino":  os.environ["AM_J_TO"],
    "digest":   os.environ["AM_J_DIGEST"],
    "snapshot": os.environ["AM_J_SNAPSHOT"],
})
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
j.setdefault("historial", []).append({"ts": ts, "fase": os.environ["AM_J_FASE"], "nota": os.environ.get("AM_J_NOTE","")})
print(json.dumps(j, indent=2, ensure_ascii=False))
PY
  # shellcheck disable=SC2181
  [ $? -eq 0 ] || { rm -f "$(am_journal_dir)/.render.$$"; return 1; }
  am_write_durable_host "$jp" < "$(am_journal_dir)/.render.$$" || { rm -f "$(am_journal_dir)/.render.$$"; return 1; }
  rm -f "$(am_journal_dir)/.render.$$"
  am_failpoint "post_persist_${fase}"
}

am_journal_field() { # tx_id campo
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' \
    "$(am_journal_path "$1")" "$2" 2>/dev/null
}

# Journals INCONCLUSOS (fase ∉ DONE/ABORTED) que tocan una cuenta o endpoint dados.
am_journal_pending() { # [filtro-substring]
  local j fase
  mkdir -p "$(am_journal_dir)"; chmod 700 "$(am_journal_dir)"
  for j in "$(am_journal_dir)"/*.json; do
    [ -e "$j" ] || continue
    fase="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("fase",""))' "$j" 2>/dev/null || true)"
    case "$fase" in DONE|ABORTED|"") continue ;; esac
    if [ -n "${1:-}" ]; then grep -q -- "$1" "$j" || continue; fi
    basename "$j" .json
  done
}

# ---------------------------------------------------------------------------
# Guard de coordinador único (M1-r8): AM_LEDGER (fail-closed si no está), campo
# coordinator_host == hostname, y ledger ESCRIBIBLE en su path canónico local.
# ---------------------------------------------------------------------------
am_coordinator_guard() {
  [ -n "${AM_LEDGER:-}" ] || { am_err "AM_LEDGER no definido — el MOVE exige el ledger de cuentas (fail-closed). Export AM_LEDGER=<path a cuentas.json>."; return 1; }
  [ -f "$AM_LEDGER" ] && [ -w "$AM_LEDGER" ] || { am_err "ledger '$AM_LEDGER' ausente o no escribible — este host no es la estación coordinadora"; return 1; }
  local ch
  ch="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("coordinator_host",""))' "$AM_LEDGER" 2>/dev/null || true)"
  [ -n "$ch" ] || { am_err "el ledger no declara coordinator_host — añádelo (fail-closed; sin él cualquier host se creería coordinador)"; return 1; }
  [ "$ch" = "$(hostname)" ] || { am_err "coordinator_host='$ch' != hostname='$(hostname)' — los MOVE solo corren en la estación coordinadora (una 2ª estación exigiría lease por cuenta, NO soportado)"; return 1; }
}

# Propiedad en el ledger AL COMMIT; VERIFIED solo actualiza salud. Preserva claves
# desconocidas (round-trip json). Escritura durable.
am_ledger_record() { # tx_id evento(commit|verified)
  local tx="$1" ev="$2"
  AM_L_TX="$tx" AM_L_EV="$ev" AM_L_CUENTA="${AM_CUENTA:-}" AM_L_FROM="${AM_FROM:-}" \
  AM_L_TO="${AM_TO:-}" AM_L_LEDGER="$AM_LEDGER" \
  python3 - <<'PY' > "${AM_LEDGER}.render.$$" || return 1
import json, os, datetime
p = os.environ["AM_L_LEDGER"]
with open(p) as f:
    d = json.load(f)
tx, ev = os.environ["AM_L_TX"], os.environ["AM_L_EV"]
cuenta, src, dst = os.environ["AM_L_CUENTA"], os.environ["AM_L_FROM"], os.environ["AM_L_TO"]
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
tag = f"MOVE {tx[:12]}"
for c in d.get("cuentas", []):
    if c.get("alias") == cuenta:
        if ev == "commit":
            # Propiedad: el grant del donante (si un MOVE previo lo registró) sale;
            # entra el del destino. Entradas de prosa curada ajenas se PRESERVAN.
            g = [x for x in c.get("grants_vivos", []) if not x.startswith(f"{src} (MOVE ")]
            g.append(f"{dst} ({tag} {ts})")
            c["grants_vivos"] = g
        else:
            c["verificado"] = f"{tag} health-check OK {ts} en {dst}"
        break
# Donante pozo → su estado refleja el consumo (un-login = una-cosecha).
if ev == "commit" and src.startswith("pool:"):
    pz = d.get("pozos", {}).get(src.split(":", 1)[1])
    if pz is not None:
        pz["estado"] = f"CONSUMIDO→{dst} ({tag})"
print(json.dumps(d, indent=2, ensure_ascii=False))
PY
  # shellcheck disable=SC2181
  [ $? -eq 0 ] || { rm -f "${AM_LEDGER}.render.$$"; return 1; }
  am_write_durable_host "$AM_LEDGER" < "${AM_LEDGER}.render.$$" || { rm -f "${AM_LEDGER}.render.$$"; return 1; }
  rm -f "${AM_LEDGER}.render.$$"
}

# ---------------------------------------------------------------------------
# Freeze durable por endpoint (B2-r9). Contenido = tx_id. Entra ANTES de matar
# procesos; sale SOLO en DONE (o tras restaurar durably al donante en abort
# pre-commit). Ante crash PERMANECE (fail-closed).
# ---------------------------------------------------------------------------
am_freeze_set() { # endpoint agent tx_id
  local ep="$1" ag="$2" tx="$3" fp dir
  fp="$(am_ep_freeze_path "$ep" "$ag")"; dir="${fp%/*}"
  am_ep_exec "$ep" "mkdir -p $(printf '%q' "$dir")"
  am_ep_exec "$ep" "umask 077; printf '%s\n' $(printf '%q' "$tx") > $(printf '%q' "$fp.tmp") && mv $(printf '%q' "$fp.tmp") $(printf '%q' "$fp")" || return 1
  am_ep_fsync "$ep" "$fp" || return 1
  if [ "$(am_ep_type "$ep")" != "host" ]; then
    am_ep_exec "$ep" "chown $CUSER:$CUSER $(printf '%q' "$fp")"
  fi
}
am_freeze_tx() { # endpoint agent → tx_id del freeze (vacío si no hay)
  am_ep_exec "$1" "head -1 $(printf '%q' "$(am_ep_freeze_path "$1" "$2")") 2>/dev/null" || true
}
am_freeze_clear() { # endpoint agent
  local fp; fp="$(am_ep_freeze_path "$1" "$2")"
  am_ep_exec "$1" "rm -f $(printf '%q' "$fp")" || return 1
  am_ep_fsync_dir "$1" "${fp%/*}"
}

# ---------------------------------------------------------------------------
# Vía AUTORIZADA bajo freeze (B1-r10): coincidencia SIMULTÁNEA de tx_id + freeze
# + journal vigente + posesión de locks. Es la única forma de ejecutar el agente
# en un endpoint congelado (health-checks y reparación del propio MOVE).
# ---------------------------------------------------------------------------
am_authorized_gate() { # endpoint agent tx_id
  local ep="$1" ag="$2" tx="$3" ftx fase
  [ -n "$tx" ] || { am_err "vía autorizada SIN tx_id — rechazo"; return 1; }
  ftx="$(am_freeze_tx "$ep" "$ag" | tr -d '[:space:]')"
  [ "$ftx" = "$tx" ] || { am_err "vía autorizada: freeze de '$ep' lleva tx '$ftx' ≠ '$tx' — rechazo"; return 1; }
  fase="$(am_journal_field "$tx" fase)"
  case "$fase" in
    DONE|ABORTED|"") am_err "vía autorizada: journal de '$tx' inexistente o cerrado (fase='$fase') — rechazo"; return 1 ;;
  esac
  am_locks_held || { am_err "vía autorizada: este proceso NO posee los locks de la transacción — rechazo"; return 1; }
}
# One-shot funcional del agente en el endpoint, bajo la vía autorizada. Salida
# SIEMPRE silenciada (las respuestas podrían citar contexto). Timeout duro.
am_health_oneshot() { # endpoint agent tx_id
  local ep="$1" ag="$2" tx="$3" cmd model
  am_authorized_gate "$ep" "$ag" "$tx" || return 1
  case "$ag" in
    codex)  cmd="timeout $AM_HC_TIMEOUT env IS_SANDBOX=1 codex exec --dangerously-bypass-approvals-and-sandbox 'Responde exactamente OK' >/dev/null 2>&1" ;;
    claude)
      model="$(tco_modelo_read salud)" && [ -n "$model" ] || return 1
      cmd="timeout $AM_HC_TIMEOUT claude -p 'Responde exactamente OK' --model '$model' >/dev/null 2>&1" ;;
    *) am_err "agente '$ag' desconocido"; return 1 ;;
  esac
  am_ep_exec_user "$ep" "$cmd"
}

# ---------------------------------------------------------------------------
# Quiescence (B1-r8): matar TODOS los procesos del agente en el endpoint y
# VERIFICAR ausencia. TAL-8042: por EJECUTABLE (argv[0]/comm), no por línea de comandos. rc≠0 → NO se sigue.
# ---------------------------------------------------------------------------
# >>> TF-PROC-SNIPPET v2 — quiescencia por EJECUTABLE (TAL-8042). Copia IDÉNTICA en
# talent-channels/scripts/{lib.sh,auth-move-lib.sh} y talent-channel-operation/scripts/lib.sh
# («duplicar antes que acoplar», TAL-5507); la paridad la asserta talent-channels/tests/run-tests.sh.
# Corre DENTRO del endpoint (bash -c): jamás casa la línea de comandos (el viejo `-f` alcanzaba
# `~/.codex`, `--agent codex`, `tee codex.log` y al lector de stdout del propio MOVE → SIGPIPE tras
# DONE). Un proceso es el agente si el basename de su argv[0] O su `comm` casa, ANCLADO, la ERE dada.
# Zombis fuera (estado Z/X). Protegidos (jamás se les envía señal): ancestros, grupo y sesión de `$$`
# + los PID declarados por el caller; un protegido que SÍ es el agente cuenta como VIVO (falla cerrado).
# Sin comillas simples en el cuerpo (se embebe en un `bash -c '…'`).
read -r -d '' AM_PROC_SNIPPET <<'TF_PROC_EOF' || true
_tf_prot() { # usuario → PID protegidos (ancestros + grupo + sesión de $$); rc 2 = error de enumeración
  local u="$1" p="$$" line rest st ppid pgrp sid out=" " q mypg mysid pids rc
  line="$(cat "/proc/$$/stat" 2>/dev/null)" || return 2
  rest="${line##*) }"; read -r st ppid mypg mysid _ <<< "$rest"
  while [ "${p:-0}" -gt 1 ] 2>/dev/null; do
    out="$out$p "
    line="$(cat "/proc/$p/stat" 2>/dev/null)" || return 2
    rest="${line##*) }"; read -r st ppid pgrp sid _ <<< "$rest"
    p="$ppid"
  done
  pids="$(pgrep -u "$u" 2>/dev/null)"; rc=$?
  [ "$rc" -le 1 ] || return 2
  for q in $pids; do
    line="$(cat "/proc/$q/stat" 2>/dev/null)" || { [ ! -d "/proc/$q" ] && continue; return 2; }
    rest="${line##*) }"; read -r st ppid pgrp sid _ <<< "$rest"
    if [ "$pgrp" = "$mypg" ] || [ "$sid" = "$mysid" ]; then out="$out$q "; fi
  done
  printf "%s" "$out"
}
_tf_identity() { # PID → identidad; rc 4 = terminal Z/X comprobado, rc 2 = ilegible
  local p="$1" line rest uid exe file
  line="$(cat "/proc/$p/stat" 2>/dev/null)" || return 2
  rest="${line##*) }"
  set -- $rest
  [ "$#" -ge 20 ] || return 2
  case "$1" in Z|X) return 4 ;; esac
  uid="$(stat -c "%u" "/proc/$p" 2>/dev/null)" || return 2
  exe="$(readlink "/proc/$p/exe" 2>/dev/null)" || return 2
  file="$(stat -Lc "%d:%i" "/proc/$p/exe" 2>/dev/null)" || return 2
  [ -n "$exe" ] || return 2
  printf "%s:%s:%s:%q" "${20}" "$uid" "$file" "$exe"
}
_tf_agent_scan() { # usuario ERE → PID TAB identidad VIVOS; rc 2 = error o ERE inválida
  local u="$1" re="$2" pids rc p line rest st c a n m identity confirmed identity_rc
  [ -n "$u" ] && [ -n "$re" ] || return 2
  # Validar incluso sin procesos ni nombres legibles.
  rc=0; [[ "" =~ ^($re)$ ]] || rc=$?
  [ "$rc" -le 1 ] || return 2
  pids="$(pgrep -u "$u" 2>/dev/null)"; rc=$?
  [ "$rc" -le 1 ] || return 2
  for p in $pids; do
    line="$(cat "/proc/$p/stat" 2>/dev/null)" || { [ ! -d "/proc/$p" ] && continue; return 2; }
    rest="${line##*) }"; st="${rest%% *}"
    case "$st" in Z|X) continue ;; esac
    # Conservar la lectura previa al nombre, pero exigirla solo si casa.
    identity_rc=0; identity="$(_tf_identity "$p")" || identity_rc=$?
    { [ "$identity_rc" -eq 4 ] || [ ! -d "/proc/$p" ]; } && continue
    # read hasta NUL/EOF conserva espacios y saltos; quitar SOLO el terminador de proc.
    c=""; { IFS= read -r -d "" c < "/proc/$p/comm"; } 2>/dev/null || [ -n "$c" ] || { [ ! -d "/proc/$p" ] && continue; return 2; }
    c="${c%?}"
    a=""; { IFS= read -r -d "" a < "/proc/$p/cmdline"; } 2>/dev/null || true
    a="${a##*/}"
    for n in "$c" "$a"; do
      [ -n "$n" ] || continue
      m=0; [[ $n =~ ^($re)$ ]] || m=$?
      case "$m" in
        0) confirmed="$(_tf_identity "$p")" || { rc=$?; { [ "$rc" -eq 4 ] || [ ! -d "/proc/$p" ]; } && break; return 2; }
           [ "$identity_rc" -eq 0 ] || return 2
           [ "$identity" = "$confirmed" ] || return 2
           printf "%s\t%s\n" "$p" "$identity"; break ;;
        1) ;;
        *) return 2 ;;
      esac
    done
  done
  return 0
}
_tf_quiet() { # usuario ERE → rc 0 SOLO si no queda ningún proceso del agente (error de enumeración = NO quieto)
  local m
  m="$(_tf_agent_scan "$1" "$2")" || return 1
  [ -z "$m" ]
}
_tf_kill_wait() { # usuario ERE [timeout_s=12] [PID-protegidos-extra] → 0 limpio · 1 timeout con agente vivo · 3 error
  local u="$1" re="$2" to="${3:-12}" extra="${4:-}" prot m p end identity current tab rc changed=0
  prot="$(_tf_prot "$u")" || return 3
  prot=" $prot $extra "
  m="$(_tf_agent_scan "$u" "$re")" || return 3
  tab="$(printf "\t")"
  while IFS="$tab" read -r p identity; do
    [ -n "$p" ] || continue
    case "$prot" in *" $p "*) continue ;; esac
    # Recalcular protecciones y acreditar la misma encarnación inmediatamente antes de la señal.
    prot="$(_tf_prot "$u")" || return 3
    prot=" $prot $extra "
    case "$prot" in *" $p "*) continue ;; esac
    current="$(_tf_identity "$p")" || { rc=$?; { [ "$rc" -eq 4 ] || [ ! -d "/proc/$p" ]; } && continue; current=""; }
    if [ -z "$identity" ] || [ "$current" != "$identity" ]; then
      printf "quiesce: PID %s cambió o no es legible; sin señal\n" "$p" >&2
      changed=1; continue
    fi
    kill -9 "$p" 2>/dev/null || true
  done <<< "$m"
  [ "$changed" -eq 0 ] || return 3
  end=$(( $(date +%s) + to ))
  while :; do
    m="$(_tf_agent_scan "$u" "$re")" || return 3
    [ -z "$m" ] && return 0
    [ "$(date +%s)" -ge "$end" ] && return 1
    sleep 0.5
  done
}
TF_PROC_EOF
# <<< TF-PROC-SNIPPET

# TAL-8042: la quiescencia casa el EJECUTABLE del agente (`codex`|`claude`: basename de argv[0] o comm),
# jamás la línea de comandos. Se calcula DENTRO del endpoint (mismo espacio de PID que el pgrep): los
# ancestros, el grupo y la sesión del shell que ejecuta el kill NO se tocan (auto-kill TAL-3539: el MOVE
# corre en el mismo host que el endpoint `host:`) y, si uno de ellos SÍ es el agente, cuenta como VIVO
# (rc 1: falla cerrado, nunca quiescencia falsa). `extra_excl` = PID que el CALLER declara explícitamente
# (solo comparable por número cuando comparte espacio de PID con el endpoint: host o arnés).
am_ep_quiesce() { # endpoint agent [timeout_s=12] [extra_excl_pids]  → 0 quieto · 1 agente vivo · 3 error de pgrep
  local ep="$1" ag="$2" to="${3:-12}" extra="${4:-}" exe u
  case "$ag" in codex|claude) exe="$ag" ;; *) return 1 ;; esac
  case "$(am_ep_type "$ep")" in host) u="$(id -un)" ;; *) u="$CUSER" ;; esac
  am_ep_exec "$ep" "$AM_PROC_SNIPPET
_tf_kill_wait $(printf '%q' "$u") $(printf '%q' "$exe") $(printf '%q' "$to") $(printf '%q' "$extra"); exit \$?"
}
# ¿Endpoint quiescente AHORA? (verificación sin matar — para la re-quiescence pre-mv).
# rc 0 = quiescente (ningún proceso VIVO del agente). rc≠0 = NO quiescente (agente vivo O error de
# enumeración) — FAIL-CLOSED: un `! pgrep` simple convertía CUALQUIER error (rc>1: usuario inválido)
# en "quiescente", dejando avanzar el mv sin confirmar que el agente paró.
am_ep_quiet() { # endpoint agent
  local ep="$1" ag="$2" exe u
  case "$ag" in codex|claude) exe="$ag" ;; *) return 1 ;; esac
  case "$(am_ep_type "$ep")" in host) u="$(id -un)" ;; *) u="$CUSER" ;; esac
  am_ep_exec "$ep" "$AM_PROC_SNIPPET
_tf_quiet $(printf '%q' "$u") $(printf '%q' "$exe"); exit \$?"
}

# ---------------------------------------------------------------------------
# Transferencia de archivos endpoint↔host (secretos: 0600, sin pasar por argv).
# ---------------------------------------------------------------------------
am_pull_to_host() { # endpoint src_path dest_host_path
  local ep="$1" src="$2" dst="$3"
  case "$(am_ep_type "$ep")" in
    host) ( umask 077; cp "$src" "$dst" ) ;;
    *)    incus file pull "$(am_ep_id "$ep")$src" "$dst" && chmod 600 "$dst" ;;
  esac
}
am_push_from_host() { # src_host_path endpoint dest_path  (deja 0600 owner correcto)
  local src="$1" ep="$2" dst="$3" uid gid
  case "$(am_ep_type "$ep")" in
    host) ( umask 077; cp "$src" "$dst" ) && chmod 600 "$dst" ;;
    *)
      uid="$(am_ep_exec "$ep" "id -u $CUSER")" || return 1
      gid="$(am_ep_exec "$ep" "id -g $CUSER")" || return 1
      incus file push --uid "$uid" --gid "$gid" --mode 600 "$src" "$(am_ep_id "$ep")$dst" >/dev/null
      ;;
  esac
}

# ---------------------------------------------------------------------------
# MOVE — el protocolo completo. Uso: am_move <cuenta> <agent> <from_ep> <to_ep>
# Precondiciones → transacción → commit → verificación → DONE. Ver cabecera.
# ---------------------------------------------------------------------------
am_move() {
  local AM_CUENTA="$1" AM_AGENT="$2" AM_FROM="$3" AM_TO="$4"
  local tx src_auth dst_auth dst_tmp snap consumed AM_DIGEST="" AM_SNAPSHOT="" d2
  am_require_env || return 1
  am_ep_validate "$AM_FROM" || return 1
  am_ep_validate "$AM_TO"   || return 1
  [ "$AM_FROM" != "$AM_TO" ] || am_die "donante y destino son el mismo endpoint"
  [ "$AM_AGENT" = "claude" ] && am_info "aviso: para Claude la ruta primaria es la propagación por copia (refresh-claude-auth.sh); MOVE solo para extracción un-login-un-lugar"

  am_coordinator_guard || return 1

  # Locks ANTES de todo lo demás (cuenta + ambos endpoints, orden determinista).
  am_acquire_locks "cuenta:$AM_CUENTA" "$AM_FROM" "$AM_TO" || return 1

  # Reconciliación previa: cualquier journal inconcluso que toque esta cuenta o
  # estos endpoints se resuelve ANTES (primer paso tras adquirir los locks).
  local ptx
  for ptx in $(am_journal_pending "$AM_CUENTA") $(am_journal_pending "$AM_FROM") $(am_journal_pending "$AM_TO"); do
    am_info "journal inconcluso '$ptx' — reconciliando antes de abrir MOVE nuevo"
    am_reconcile "$ptx" || { am_release_locks; am_die "reconciliación de '$ptx' falló — resuelve con 'auth-move.sh repair $ptx' antes de mover"; }
  done

  tx="mv$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
  src_auth="$(am_ep_auth_path "$AM_FROM" "$AM_AGENT")"
  dst_auth="$(am_ep_auth_path "$AM_TO" "$AM_AGENT")"
  dst_tmp="${dst_auth}.mvtmp.${tx}"
  consumed="${src_auth}.consumed.${tx}"
  snap="$SECRET_DIR/snapshots/${tx}.auth"

  # Destino VACÍO de auth (B1-r8 1b): credencial preexistente = otra credencial
  # viva; requiere su propio MOVE de salida primero. (La recuperación idempotente
  # del mismo tx pasa por resume/reconcile, nunca por un MOVE nuevo.)
  if am_ep_exists "$AM_TO" "$dst_auth"; then
    am_release_locks
    am_die "el destino '$AM_TO' ya tiene $dst_auth — un MOVE no pisa credenciales; extrae la existente primero (MOVE separado)"
  fi

  # FREEZE en ambos endpoints ANTES de matar procesos (B2-r9)…
  am_ep_exec "$AM_TO" "mkdir -p $(printf '%q' "${dst_auth%/*}")"
  if [ "$(am_ep_type "$AM_TO")" != "host" ]; then
    am_ep_exec "$AM_TO" "chown -R $CUSER:$CUSER $(printf '%q' "${dst_auth%/*}")"
  fi
  am_freeze_set "$AM_FROM" "$AM_AGENT" "$tx" || { am_release_locks; am_die "no pude congelar '$AM_FROM'"; }
  am_freeze_set "$AM_TO"   "$AM_AGENT" "$tx" || { am_freeze_clear "$AM_FROM" "$AM_AGENT" || true; am_release_locks; am_die "no pude congelar '$AM_TO'"; }

  # …snapshot ANTES del journal PREPARED (la fase promete que el snapshot existe)…
  # pero primero: quiescence + health del donante. Cualquier fallo aquí = abort
  # limpio (nada movido aún): descongelar y salir.
  _am_abort_early() { am_freeze_clear "$AM_FROM" "$AM_AGENT" || true; am_freeze_clear "$AM_TO" "$AM_AGENT" || true; am_release_locks; am_die "$1"; }

  am_ep_quiesce "$AM_FROM" "$AM_AGENT" || _am_abort_early "quiescence del donante '$AM_FROM' falló (proceso imposible de matar) — sin snapshot ni transferencia"
  am_ep_quiesce "$AM_TO"   "$AM_AGENT" || _am_abort_early "quiescence del destino '$AM_TO' falló — el destino no se inmoviliza, no se escribe en él"
  am_ep_exists "$AM_FROM" "$src_auth" || _am_abort_early "el donante '$AM_FROM' no tiene $src_auth"

  # Journal PREPARED necesita existir para que el health-check (vía autorizada)
  # tenga journal vigente que validar.
  AM_CUENTA="$AM_CUENTA" AM_AGENT="$AM_AGENT" AM_FROM="$AM_FROM" AM_TO="$AM_TO" \
  AM_DIGEST="" AM_SNAPSHOT="$snap" am_journal_write "$tx" "PREPARED" "locks+freezes puestos; pre health-check" \
    || _am_abort_early "no pude persistir el journal PREPARED (durabilidad)"

  am_health_oneshot "$AM_FROM" "$AM_AGENT" "$tx" \
    || { am_journal_write "$tx" "ABORTED" "health-check del donante falló"; _am_abort_early "health-check del donante '$AM_FROM' FALLÓ — login muerto o red caída; no se mueve un login no verificado"; }
  # RE-verificar quiescence tras el health-check (M3-rev6): el one-shot puede
  # dejar un hijo residual, sobre todo ante timeout.
  am_ep_quiesce "$AM_FROM" "$AM_AGENT" \
    || { am_journal_write "$tx" "ABORTED" "residuo post health-check"; _am_abort_early "proceso residual del health-check en '$AM_FROM' imposible de matar — sin snapshot ni transferencia"; }

  # Snapshot DURABLE en $SECRET_DIR (mismo fs persistente; temp en el mismo dir).
  mkdir -p "$SECRET_DIR/snapshots"; chmod 700 "$SECRET_DIR/snapshots"
  am_pull_to_host "$AM_FROM" "$src_auth" "$snap.tmp" || { am_journal_write "$tx" "ABORTED" "pull del snapshot falló"; _am_abort_early "no pude tomar snapshot del donante"; }
  am_ep_fsync "host:$(hostname)" "$snap.tmp" || { rm -f "$snap.tmp"; am_journal_write "$tx" "ABORTED" "fsync snapshot falló"; _am_abort_early "fsync del snapshot FALLÓ — no se continúa sobre escritura no confirmada"; }
  mv "$snap.tmp" "$snap" || { rm -f "$snap.tmp"; am_journal_write "$tx" "ABORTED" "rename snapshot falló"; _am_abort_early "no pude fijar el snapshot"; }
  am_ep_fsync_dir "host:$(hostname)" "$SECRET_DIR/snapshots" || { am_journal_write "$tx" "ABORTED" "fsync dir snapshots falló"; _am_abort_early "fsync del directorio de snapshots FALLÓ"; }
  AM_DIGEST="$(sha256sum "$snap" | awk '{print $1}')"
  AM_SNAPSHOT="$snap"
  am_journal_write "$tx" "PREPARED" "snapshot durable ${AM_DIGEST:0:12}" || _am_abort_early "no pude actualizar el journal (digest)"

  # RETIRAR EL ORIGEN (mv atómico mismo dir) + fsync dir → ORIGIN_RETIRED.
  am_ep_exec "$AM_FROM" "mv $(printf '%q' "$src_auth") $(printf '%q' "$consumed")" \
    || { am_journal_write "$tx" "ABORTED" "retiro del origen falló"; _am_abort_early "no pude retirar el auth del donante"; }
  am_ep_fsync_dir "$AM_FROM" "${src_auth%/*}" || am_info "aviso: fsync-dir del donante falló tras retirar (continúo: el snapshot durable es la fuente)"
  am_journal_write "$tx" "ORIGIN_RETIRED" "origen → .consumed" || { am_err "journal ORIGIN_RETIRED no persistió"; am_reconcile "$tx"; am_release_locks; return 1; }

  # PUSH a temporal en destino + fsync + digest + RE-quiescence.
  am_push_from_host "$snap" "$AM_TO" "$dst_tmp" || { am_reconcile "$tx"; am_release_locks; am_die "push al destino falló — transacción reconciliada (donante restaurado)"; }
  am_ep_fsync "$AM_TO" "$dst_tmp" || { am_reconcile "$tx"; am_release_locks; am_die "fsync del temporal en destino FALLÓ — reconciliado"; }
  d2="$(am_ep_sha256 "$AM_TO" "$dst_tmp")"
  [ "$d2" = "$AM_DIGEST" ] || { am_reconcile "$tx"; am_release_locks; am_die "digest del temporal en destino NO coincide (${d2:0:12} ≠ ${AM_DIGEST:0:12}) — reconciliado"; }
  am_ep_quiet "$AM_TO" "$AM_AGENT" || { am_reconcile "$tx"; am_release_locks; am_die "el destino dejó de estar quiescente antes del mv (¿arranque no soportado?) — reconciliado"; }
  # `am_ep_quiet` solo confirma que no hay procesos VIVOS; un agente matado por la quiescence pudo
  # MATERIALIZAR una credencial (login) cuya escritura persiste tras su muerte. Si `dst_auth` ya
  # existe, el `mv` de abajo la SOBRESCRIBIRÍA en silencio (potencialmente de OTRA cuenta). Se
  # reverifica ausencia justo antes del COMMIT — fail-closed: si apareció, no se pisa.
  ! am_ep_exists "$AM_TO" "$dst_auth" || { am_reconcile "$tx"; am_release_locks; am_die "el destino materializó $dst_auth tras el freeze/quiescence — no se pisa una credencial ajena; reconciliado"; }

  # INSTALL_INTENT (pre-mv) → mv atómico (COMMIT) → fsync + re-digest → DEST_INSTALLED.
  am_journal_write "$tx" "INSTALL_INTENT" "pre-mv en destino" || { am_reconcile "$tx"; am_release_locks; return 1; }
  am_failpoint "pre_mv"
  am_ep_exec "$AM_TO" "mv $(printf '%q' "$dst_tmp") $(printf '%q' "$dst_auth")" \
    || { am_reconcile "$tx"; am_release_locks; am_die "mv en destino falló — reconciliado"; }
  am_failpoint "post_mv"
  am_ep_fsync "$AM_TO" "$dst_auth" || { am_err "fsync del auth final FALLÓ — SIN cleanup; reconcilia/repara con el tx $tx"; am_release_locks; return 1; }
  d2="$(am_ep_sha256 "$AM_TO" "$dst_auth")"
  [ "$d2" = "$AM_DIGEST" ] || { am_err "re-lectura del digest final NO coincide — estado contradictorio; FAIL-CLOSED (tx $tx)"; am_release_locks; return 3; }
  am_journal_write "$tx" "DEST_INSTALLED" "COMMIT: auth durable en destino" \
    || { am_err "journal DEST_INSTALLED no persistió — auth YA durable en destino; re-corre 'auth-move.sh resume $tx' (la inspección resolverá commit)"; am_release_locks; return 1; }

  # Propiedad en el ledger AL COMMIT (M1-r8).
  am_ledger_record "$tx" commit || am_info "aviso: ledger no actualizado al commit — corrígelo (la propiedad REAL ya es del destino; journal manda)"

  # CLEANUP (solo ahora: auth destino + journal de commit durables). fsync de dirs.
  rm -f "$snap" && am_ep_fsync_dir "host:$(hostname)" "$SECRET_DIR/snapshots" || am_info "aviso: cleanup del snapshot incompleto — bórralo a mano ($snap)"
  am_ep_exec "$AM_FROM" "rm -f $(printf '%q' "$consumed")" && am_ep_fsync_dir "$AM_FROM" "${src_auth%/*}" || am_info "aviso: .consumed del donante no eliminado — bórralo a mano"

  # Verificación POST-commit (salud, no propiedad). Fallo → reparar en destino.
  if am_health_oneshot "$AM_TO" "$AM_AGENT" "$tx"; then
    am_journal_write "$tx" "VERIFIED" "health-check destino OK" || true
    am_ledger_record "$tx" verified || true
  else
    am_err "health-check POST-commit en '$AM_TO' falló — el destino ES el propietario; repara EN destino: 'auth-move.sh repair $tx' (jamás restaurar al donante)"
    am_release_locks
    return 4
  fi

  # DONE: retirar freezes durably y cerrar.
  am_freeze_clear "$AM_FROM" "$AM_AGENT" || am_info "aviso: freeze del donante no retirado — retíralo a mano"
  am_freeze_clear "$AM_TO"   "$AM_AGENT" || am_info "aviso: freeze del destino no retirado — retíralo a mano"
  am_journal_write "$tx" "DONE" "transacción cerrada" || true
  am_release_locks
  am_info "MOVE $tx COMPLETO: $AM_CUENTA ($AM_AGENT) $AM_FROM → $AM_TO. Relanza el agente en el destino (launcher normal; el freeze ya no está)."
}

# ---------------------------------------------------------------------------
# rc FINAL del CLI por FASE del journal (TAL-8042, FAB-OBS-002). El rc de `am_move` puede mentir sobre
# el estado de la transacción: tras DONE, un fallo de ESCRITURA a la salida (tubería cerrada → SIGPIPE o
# EPIPE) devolvía 141/1 con el journal cerrado y el operador lo leía como "pre-commit" (copiar el login de
# vuelta = dos copias de un refresh de un solo uso → cascada de revocación). La verdad es el journal:
#   DONE                      → 0   (transacción cerrada; el rc original solo refleja la salida)
#   DEST_INSTALLED|VERIFIED   → 4   (COMMIT hecho, anomalía posterior: reparar EN destino con repair/resume)
#   cualquier otra / sin tx   → rc original (≠0): `am_move` ya reconcilió o dejó freezes fail-closed
# El tx se acota por PID e instante UTC de arranque (`mv<UTC>-<pid>-<rand>`). Pura: sin efectos.
# ---------------------------------------------------------------------------
am_move_final_rc() { # rc_original pid_del_cli inicio_utc
  local rc="${1:-1}" pid="${2:-$$}" inicio="${3:-}" jd f newest="" tx fase instante
  [ "$rc" -eq 0 ] 2>/dev/null && return 0
  [[ "$inicio" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || return "$rc"
  jd="$(am_journal_dir)"
  for f in "$jd"/mv*-"$pid"-*.json; do
    [ -f "$f" ] || continue
    instante="${f##*/mv}"; instante="${instante%%-*}"
    [[ "$instante" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || continue
    [[ "$instante" < "$inicio" ]] && continue
    newest="$f"
  done
  [ -n "$newest" ] || return "$rc"
  tx="$(basename "$newest" .json)"
  fase="$(am_journal_field "$tx" fase)"
  case "$fase" in
    DONE) return 0 ;;
    DEST_INSTALLED|VERIFIED) return 4 ;;
  esac
  return "$rc"
}

# ---------------------------------------------------------------------------
# RECONCILIACIÓN por fase + INSPECCIÓN (B2-r8). Devuelve el sistema a un estado
# sano tras crash/fallo. NUNCA restaura al donante si el auth llegó a ser
# visible-com-digest-esperado en destino. Contradicción → FAIL-CLOSED (rc 3).
# Requiere poseer los locks (am_move los tiene; repair/resume los readquiere).
# ---------------------------------------------------------------------------
am_reconcile() { # tx_id
  local tx="$1" fase cuenta agent from to digest snap
  fase="$(am_journal_field "$tx" fase)"
  cuenta="$(am_journal_field "$tx" cuenta)"; agent="$(am_journal_field "$tx" agent)"
  from="$(am_journal_field "$tx" donante)";  to="$(am_journal_field "$tx" destino)"
  digest="$(am_journal_field "$tx" digest)"; snap="$(am_journal_field "$tx" snapshot)"
  [ -n "$fase" ] || { am_err "reconcile: journal de '$tx' ilegible"; return 3; }
  local AM_CUENTA="$cuenta" AM_AGENT="$agent" AM_FROM="$from" AM_TO="$to" AM_DIGEST="$digest" AM_SNAPSHOT="$snap"
  local src_auth dst_auth dst_tmp consumed dd
  src_auth="$(am_ep_auth_path "$from" "$agent")"; dst_auth="$(am_ep_auth_path "$to" "$agent")"
  dst_tmp="${dst_auth}.mvtmp.${tx}"; consumed="${src_auth}.consumed.${tx}"

  case "$fase" in
    DONE|ABORTED) am_info "reconcile $tx: ya cerrado ($fase) — nada que hacer"; return 0 ;;
  esac

  # INSPECCIÓN de hechos: ¿el auth final está en destino con el digest esperado?
  local dst_state="ausente"
  if am_ep_exists "$to" "$dst_auth"; then
    dd="$(am_ep_sha256 "$to" "$dst_auth")"
    if [ -n "$digest" ] && [ "$dd" = "$digest" ]; then dst_state="commit"; else dst_state="contradictorio"; fi
  fi

  case "$dst_state" in
    commit)
      # COMMIT de facto (aunque el journal esté atrasado): completar hacia ADELANTE.
      am_info "reconcile $tx: auth con digest esperado en '$to' ⇒ COMMIT (journal estaba en $fase) — completando hacia adelante"
      am_ep_fsync "$to" "$dst_auth" || { am_err "reconcile: fsync del final falló — SIN cleanup"; return 1; }
      am_journal_write "$tx" "DEST_INSTALLED" "reconcile: commit por inspección" || return 1
      am_ledger_record "$tx" commit || true
      [ -n "$snap" ] && rm -f "$snap" && am_ep_fsync_dir "host:$(hostname)" "${snap%/*}" || true
      am_ep_exec "$to"   "rm -f $(printf '%q' "$dst_tmp")" 2>/dev/null || true
      am_ep_exec "$from" "rm -f $(printf '%q' "$consumed")" 2>/dev/null || true
      am_freeze_clear "$from" "$agent" || true
      am_freeze_clear "$to"   "$agent" || true
      am_journal_write "$tx" "DONE" "reconcile: cerrado hacia adelante (health-check pendiente si aplica)" || true
      am_info "reconcile $tx: destino '$to' es el propietario. Verifica salud con un arranque normal; si falla, repara EN destino."
      return 0
      ;;
    contradictorio)
      am_err "reconcile $tx: '$to' tiene $dst_auth con digest INESPERADO — estado contradictorio; FAIL-CLOSED: no toco nada (freezes permanecen). Resolución manual: compara digests (journal=$digest) y decide."
      return 3
      ;;
  esac

  # dst ausente ⇒ PRE-commit: restaurar al donante (desde snapshot o des-retirando
  # el .consumed), limpiar temporal, abortar la transacción, descongelar.
  am_info "reconcile $tx: destino sin auth ⇒ pre-commit — restaurando al donante '$from'"
  am_ep_exec "$to" "rm -f $(printf '%q' "$dst_tmp")" 2>/dev/null || true
  if ! am_ep_exists "$from" "$src_auth"; then
    if am_ep_exists "$from" "$consumed"; then
      am_ep_exec "$from" "mv $(printf '%q' "$consumed") $(printf '%q' "$src_auth")" || { am_err "reconcile: no pude des-retirar el .consumed"; return 1; }
    elif [ -n "$snap" ] && [ -f "$snap" ]; then
      am_push_from_host "$snap" "$from" "$src_auth" || { am_err "reconcile: restore del snapshot al donante falló"; return 1; }
    else
      am_err "reconcile $tx: donante sin auth, sin .consumed y sin snapshot — estado contradictorio; FAIL-CLOSED"
      return 3
    fi
    am_ep_fsync "$from" "$src_auth" || { am_err "reconcile: fsync del restore FALLÓ — reintenta"; return 1; }
  fi
  # Verificar digest del donante restaurado si tenemos referencia.
  if [ -n "$digest" ]; then
    dd="$(am_ep_sha256 "$from" "$src_auth")"
    [ "$dd" = "$digest" ] || { am_err "reconcile $tx: donante restaurado con digest inesperado — FAIL-CLOSED"; return 3; }
  fi
  # Restore durable confirmado → AHORA sí: cerrar y descongelar (orden B1-r10).
  am_journal_write "$tx" "ABORTED" "reconcile: donante restaurado (pre-commit)" || return 1
  [ -n "$snap" ] && [ -f "$snap" ] && { rm -f "$snap"; am_ep_fsync_dir "host:$(hostname)" "${snap%/*}" || true; }
  am_freeze_clear "$from" "$agent" || true
  am_freeze_clear "$to"   "$agent" || true
  am_info "reconcile $tx: ABORTED — donante '$from' restaurado y descongelado."
}

# ---------------------------------------------------------------------------
# repair/resume <tx_id> (B1-r10): readquiere los 3 locks EN EL MISMO ORDEN
# determinista y reconcilia; si el estado es commit-sin-salud, re-corre el
# health-check por la vía autorizada y cierra.
# ---------------------------------------------------------------------------
am_resume() { # tx_id
  local tx="$1" cuenta from to agent fase
  am_require_env || return 1
  cuenta="$(am_journal_field "$tx" cuenta)"; from="$(am_journal_field "$tx" donante)"
  to="$(am_journal_field "$tx" destino)";    agent="$(am_journal_field "$tx" agent)"
  [ -n "$cuenta" ] || am_die "resume: journal de '$tx' inexistente o ilegible"
  am_coordinator_guard || return 1
  am_acquire_locks "cuenta:$cuenta" "$from" "$to" || return 1
  fase="$(am_journal_field "$tx" fase)"
  case "$fase" in
    DEST_INSTALLED|VERIFIED)
      # Commit hecho: salud + cierre (nunca tocar al donante).
      local AM_CUENTA="$cuenta" AM_AGENT="$agent" AM_FROM="$from" AM_TO="$to"
      local snap src_auth consumed
      snap="$(am_journal_field "$tx" snapshot)"
      src_auth="$(am_ep_auth_path "$from" "$agent")"
      consumed="${src_auth}.consumed.${tx}"
      if am_health_oneshot "$to" "$agent" "$tx"; then
        am_journal_write "$tx" "VERIFIED" "resume: health-check OK" || true
        am_ledger_record "$tx" verified || true
        # CLEANUP de las copias de credencial (snapshot + .consumed del donante): en esta rama el
        # commit YA es durable (DEST_INSTALLED/VERIFIED), así que aplica el mismo cleanup que
        # am_reconcile — sin él, un MOVE reanudado dejaría credencial residual, violando el
        # invariante "MOVE sin secretos residuales" (TAL-2294). Idempotente: rm de algo ausente no
        # falla; el DONE solo se escribe DESPUÉS de limpiar ambos artefactos.
        [ -n "$snap" ] && rm -f "$snap" && am_ep_fsync_dir "host:$(hostname)" "${snap%/*}" || am_info "aviso: cleanup del snapshot en resume incompleto — bórralo a mano ($snap)"
        am_ep_exec "$from" "rm -f $(printf '%q' "$consumed")" && am_ep_fsync_dir "$from" "${src_auth%/*}" || am_info "aviso: .consumed del donante no eliminado en resume — bórralo a mano"
        am_freeze_clear "$from" "$agent" || true
        am_freeze_clear "$to"   "$agent" || true
        am_journal_write "$tx" "DONE" "resume: cerrado" || true
        am_release_locks; am_info "resume $tx: DONE — relanza el agente en '$to' (launcher normal)"; return 0
      else
        am_release_locks
        am_die "resume $tx: health-check en '$to' sigue fallando — repara EN destino (login interactivo bajo este mismo tx si hace falta) y re-corre 'auth-move.sh resume $tx'. JAMÁS restaurar al donante."
      fi
      ;;
    *)
      am_reconcile "$tx"; local rc=$?
      am_release_locks
      return "$rc"
      ;;
  esac
}
