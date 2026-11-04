#!/usr/bin/env bash
# cr-review.sh — Genera el sentinel del review CR-CLI pre-PR (modelo CR 2.0, TAL-1518).
# Enforcement repo-wide: el git hook .githooks/pre-push EXIGE un sentinel válido para el
# SHA que se pushea. Este script corre el CLI de CodeRabbit sobre lo que va al PR y, según
# el resultado, emite (o no) el sentinel `.claude/.cr-review-ok`.
#
# CR es el GATE FINAL pre-PR: córrelo cuando ya tienes el OK para abrir el PR (tras la aprobación
# del revisor autorizado), NO al codificar — el bucket CLI es escaso (correrlo antes desperdicia
# corridas si la revisión pide cambios).
#
# ENTREGA DRAFT (Fábrica v2, ADR-0043 / TAL-2193): los canales de producción NO corren este
# script — entregan PR DRAFT + HANDOFF con `scripts/draft-handoff.sh` (sentinel
# `.claude/.draft-handoff`, exención de este gate en el hook pre-push) y el consumo de
# CodeRabbit (CLI y App) lo centraliza el Mergeador. Este gate queda para el flujo no-draft
# (Mergeador, sesiones de dev fuera del sistema de canales). Ver
# docs/runbooks/coderabbit-cli-pre-pr.md § «Entrega draft».
#
# Sentinel `.claude/.cr-review-ok` (línea 3 = estado):
#   ok        — el CLI revisó el commit y quedó limpio (0 critical|major NUEVOS; los findings
#               aceptados como known debt para este árbol no bloquean — ver TAL-2272 abajo).
#               La razón (línea 4) distingue `review_completed` de `review_completed_known_debt(N)`.
#   deferred  — el CLI NO estaba disponible (sin auth / red / rate-limit). SOLO se emite si
#               existe un PR para la rama y se le verifica el label `cr-review` (App backstop).
#               En primer push (sin PR) NO se emite → el push queda bloqueado.
#
# Resultado runtime `.claude/.cr-review-result.json` — escrito ATÓMICAMENTE en TODOS los caminos
# de salida (nunca ausente ni stale). Estados: running (transitorio inicial) | ok | findings |
# deferred | blocked | error. Campos: state, reason, head_sha, base_sha, gen{epoch,value}, run_id,
# blocking_findings (redacted: solo severity+file, sin body/snippets/secrets), known_debt (redacted),
# seat_fp (TAL-3562: huella sha256 truncada del asiento CR en uso — jamás la credencial).
#
# Findings accionables `.claude/.cr-review-findings.jsonl` (TAL-2245) — SOLO en state=findings:
# un objeto JSON por línea con severity+file+line+title+description+prompt, para que el
# Mergeador ROUTE/ARREGLE un finding SIN re-correr el CLI (leer un finding dejaba de costar una
# re-review del bucket escaso). Local + gitignored (patrón .claude/.cr-review-*); se limpia al
# arrancar y solo se (re)escribe cuando hay findings bloqueantes NUEVOS.
#
# HISTORIAL + CRUDO + CONCURRENCIA (TAL-2816) — evidencia para adjudicar phantoms sin quemar bucket:
#   `.claude/.cr-review-history.jsonl`  — ledger APPEND-ONLY por run/SHA. **TODO run entra (M-01
#       ronda 3)**: 1 línea por run, incluidos error/deferred/blocked/interrupted/superseded y los que
#       nunca llegaron a correr el CLI — universo vacío salvo ok/findings autorizados. Campos
#       sanitizados (allowlist): run_id, gen{epoch,value}, sha, base_sha, ts, branch, state,
#       seat_fp (TAL-3637: la MISMA huella truncada que el `result`, `null` si el run no llegó al
#       guard de auth — el `result` lo PISA la corrida siguiente, así que sin esto la atribución de
#       asiento falta justo donde hace falta al investigar una colisión: el ledger es el único que
#       sobrevive), finding_count, findings[{severity,file,lineStart,lineEnd,title,category,fp}]. NO persiste
#       description/prompt (snippets). Normalizado por el filtro compartido `cr-finding-normalize.jq`
#       (TAL-2610), solo triageables → sin campo `textless` (el universo solo se afirma para runs que
#       pasaron la paridad, donde no hay phantoms). fp == la del known-debt (misma huella).
#   `.claude/.cr-review-raw-<run_id>.jsonl` (final, solo runs que completaron el review) o
#       `.claude/.cr-review-raw-<run_id>.jsonl.partial` (en curso o incompleto/rate-limited/
#       interrumpido — a lo sumo UNO de los dos existe por run), con su lock por-run
#       `.cr-review-runlock-<run_id>` (flock sostenido por el proceso dueño toda su vida; contiene
#       {branch} para atribución) — CRUDO del CLI preservado (evidencia objetiva); crudo Y lockfile
#       podados cuando su run_id es evictado por retención (CR_REVIEW_HISTORY_RETENTION, default
#       20/rama), vía el MISMO diff before/after para escrituras normales Y reconciliaciones (ninguna
#       expulsión deja crudo/lockfile inalcanzable). Un crudo HUÉRFANO (proceso muerto por SIGKILL/OOM
#       antes de `commit_run`, sin entrada en el historial — la poda por retención no lo alcanza) se
#       reconcilia en cada arranque, escaneando AMBAS formas (`.partial` de crash pre-promoción Y
#       `.jsonl` final de crash post-promoción). La MUERTE se PRUEBA por flock (el reconciliador
#       adquiere el `runlock` con `flock -n`: si lo toma, el dueño murió y el kernel liberó el lock —
#       SIGKILL incluido; si no lo toma, el dueño sigue vivo y el crudo queda intacto, sin heurística
#       de PID ni de mtime). El invariante «el lock precede al crudo» elimina toda ventana. Se registra
#       como `orphaned` con la rama del lockfile (nunca la del reconciliador; sin lockfile legible,
#       `_orphaned_unknown`) y SOLO se poda si el registro se confirmó persistido (un fallo conserva el
#       crudo para reintentar, nunca pierde evidencia sin su registro) — ya no se acumulan crudos sin
#       límite ni siquiera ante un crash abrupto, en cualquiera de las dos fases.
#   Concurrencia FAIL-CLOSED: toda mutación del estado por-SHA (RESULT/FINDINGS/SENTINEL/HISTORY) va
#       bajo el lock `.claude/.cr-review-ledger.lock` y ordenada por una GENERACIÓN NO-reutilizable
#       `.claude/.cr-review-gen` = {epoch aleatorio, value creciente} — el fencing token de ownership
#       real. Un run más viejo que termine tarde NUNCA pisa el verdict de uno más nuevo: la generación
#       se valida ANTES de tocar CUALQUIER artefacto (incluido el historial); si no matchea, el run
#       queda `superseded` y su entrada de historial persiste con universo VACÍO (nunca afirma los
#       findings de una revisión ya no-autorizada). El `epoch` cierra el ABA ante borrado/reset del
#       contador. `start_run` INVALIDA el sentinel PRIMERO; `commit_run` revalida bajo lock (tras el
#       gate de generación) un fingerprint de snapshot con reflog (detecta cambio-y-restauración A→B→A
#       de HEAD/base durante el review; una revisión stale tampoco afirma universo) y publica el
#       sentinel el ÚLTIMO, solo si todo persistió. TOCTOU (B-01 ronda 2): `REVIEW_HEAD` se lee EN
#       VIVO (no se copia de `HEAD_SHA`, capturado al arrancar) y se valida contra `HEAD_SHA` ANTES de
#       gastar la corrida del CLI; en `commit_run`, justo antes de publicar, se re-lee HEAD/tree en
#       vivo y se exige que coincidan con `REVIEW_HEAD`/`REVIEW_TREE` Y con `HEAD_SHA` — el sentinel
#       nunca autoriza un SHA distinto del que realmente se auditó. Sin `flock` (util-linux) el script
#       FALLA CERRADO (ningún fallback hand-rolled es seguro: un timeout no es un fencing token).
#
# KNOWN DEBT (TAL-2272) — findings aceptados ligados al árbol auditado:
#   La doctrina de la fábrica (talent-merger ref 04: flip-flop waiveado, deuda aceptada/gated)
#   deja findings que NO se van a arreglar; sin registro, cada re-run los re-reporta y bloquea
#   el sentinel para siempre. Automatización:
#     bash scripts/cr-review.sh --list-findings           # listado numerado del último run
#     bash scripts/cr-review.sh --accept-debt 1,3 "nota"  # acepta SOLO esos índices (granular)
#   Registro en `.claude/.cr-review-known-debt.jsonl` (local + gitignored, durable multi-run):
#   una línea por finding aceptado con binding {tree_sha, base_sha, head_sha} + nota obligatoria
#   (waiver documentado) + huella `fp` = sha256(tojson([file, lineStart, lineEnd, title, category,
#   fpMaterial])), donde `fpMaterial` = [description, comment, codegenInstructions, suggestions,
#   prompt] normalizadas por el filtro compartido (B-02 ronda 2 · M-01 síntesis r1): captura TODAS
#   las fuentes textuales — no solo la primera que description/prompt colapsan — y serializa
#   suggestions no-string vía tojson, cerrando el dedupe fail-open donde dos findings idénticos salvo
#   por codegenInstructions/suggestions compartían huella. La supresión exige
#   triple match: tree_sha == HEAD^{tree} actual,
#   base_sha == origin/main actual y fp idéntica → cualquier commit, rebase o avance de main
#   EXPIRA la deuda (fail-closed, re-triage). Dos findings del mismo archivo con el mismo
#   título pero distintas líneas tienen huellas distintas: aceptar uno NUNCA suprime el otro.
#   NO existe aceptación bulk (sin atajo "all"): la selección es SIEMPRE por índice explícito
#   contra el listado revisable — un bulk podría registrar un finding real junto a la deuda y
#   degradar el gate a bypass. Si el CLI varía líneas/description entre runs (no-determinismo),
#   la huella no matchea y el finding se RE-REPORTA (jamás se suprime de más). Sin sha256
#   disponible, el registro se rechaza y la supresión no aplica (se re-reporta todo).
#   Un finding TEXTLESS/phantom NO es waiveable por política (doctrina): la impone el filtro
#   compartido + la PARIDAD del flujo principal (un phantom deja normalized < blockers → gate abortado
#   con state=error, nunca llega a $FINDINGS ni a --accept-debt); su crudo queda en $RAW como
#   evidencia, jamás se silencia.
set -euo pipefail
umask 077   # M-b: todo artefacto nuevo (temps, RAW, historial, sentinel, lock, gen) nace 0600/0700.

export PATH="$HOME/.local/bin:$PATH"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || { echo "cr-review: no estás en un repo git." >&2; exit 1; }
cd "$ROOT"

BRANCH="$(git branch --show-current 2>/dev/null || true)"
[ -n "$BRANCH" ] || { echo "cr-review: HEAD detached (sin rama). Cambia a una rama antes de revisar/pushear." >&2; exit 1; }
HEAD_SHA="$(git rev-parse HEAD)"
SENTINEL=".claude/.cr-review-ok"
RESULT=".claude/.cr-review-result.json"
FINDINGS=".claude/.cr-review-findings.jsonl"     # TAL-2245: findings accionables (JSONL, gitignored)
KNOWN_DEBT=".claude/.cr-review-known-debt.jsonl" # TAL-2272: findings aceptados (JSONL, gitignored, durable)
HISTORY=".claude/.cr-review-history.jsonl"       # TAL-2816: ledger append-only por run/SHA (gitignored)
NORMALIZE_JQ="$ROOT/scripts/lib/cr-finding-normalize.jq"  # TAL-2610: filtro de normalización compartido
                                                  # (mismo filtro que el test unit → sin drift jq↔test);
                                                  # soporta schemas CR-CLI 0.6.4 y 0.6.5, solo emite
                                                  # findings critical|major TRIAGEABLES (con cuerpo real).
LEDGER_LOCK=".claude/.cr-review-ledger.lock"     # TAL-2816: lock que serializa mutaciones por-SHA
GEN_FILE=".claude/.cr-review-gen"                # TAL-2816: generación no-reutilizable {epoch,value}
BASE_SHA=""                                      # se resuelve tras el fetch; "" en el emit transitorio
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"           # único por invocación (timestamp + PID)
RAW=".claude/.cr-review-raw-${RUN_ID}.jsonl"     # TAL-2816: crudo del CLI preservado (per-run); nombre
                                                  # FINAL — solo existe tras el rename atómico post-review
RAW_PARTIAL="${RAW}.partial"                     # TAL-2816: destino real de la escritura del CLI (en curso)
RUN_LOCK=".claude/.cr-review-runlock-${RUN_ID}"  # M-01/M-02/M-03 ronda 6: lock flock por-run (FD fijo 8,
                                                  # distinto del ledger FD 9) — el kernel lo libera al morir
                                                  # el proceso (SIGKILL incl.); prueba de vivacidad
                                                  # AUTORITATIVA (no heurística PID+mtime). Contiene {branch}
                                                  # para atribución del huérfano. El reconciliador prueba con FD 7.
HISTORY_RETENTION="${CR_REVIEW_HISTORY_RETENTION:-20}"  # runs retenidos por rama
# Estado por-run (se fija más adelante):
RUN_EPOCH=""; RUN_GEN=""                          # generación de ESTE run (start_run)
REVIEW_HEAD=""; REVIEW_TREE=""; REVIEW_BASE=""; REVIEW_FP=""  # snapshot revisado (antes del CLI)
COMMITTED=""                                      # flag: estado terminal ya escrito (disciplina de trap)
RUN_BLOCKING="[]"; RUN_KNOWN="[]"; RUN_FINDINGS_LINES=""      # payload EN-PROCESO para commit_run
RUN_UNIVERSE_LINES=""                             # M-02: universo normalizado+validado por PARIDAD (reuso fail-closed)
SEAT_FP=""                                        # TAL-3562: huella (sha256 truncada) del asiento CR en uso; vacía hasta el guard de auth
SNAP_HOME=""                                      # TAL-3562: HOME privado con el snapshot inmutable de .coderabbit de este run

# --- Known debt (TAL-2272): helpers de huella ---------------------------------------------
# sha256 portable (Linux: sha256sum; macOS: shasum -a 256). Sin ninguno → rc 1 (fail-closed:
# el registro se rechaza y la supresión no aplica).
sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else return 1; fi
}
have_sha256() { command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; }

# Huella de identidad de un finding NORMALIZADO (shape que emite `cr-finding-normalize.jq`).
# Serializado con `tojson` sobre el array [file, lineStart, lineEnd, title, category, fpMaterial]
# (B-02 ronda 2 · M-01 síntesis r1): `fpMaterial` = [description, comment, codegenInstructions,
# suggestions, prompt] normalizadas por el filtro — captura TODAS las fuentes textuales, no solo la
# primera que `description`/`prompt` colapsan. Esto cierra el fail-open donde dos findings idénticos
# salvo por codegenInstructions/suggestions (con igual description+prompt) compartían huella y una
# deuda aceptada suprimía otro finding materialmente distinto. `tojson` es injectivo (escapa
# comillas/control, distingue string/array/objeto → serializa suggestions no-string). `severity`
# queda FUERA (un flip critical↔major no re-abre la deuda). MISMA forma en --accept-debt y en el
# historial → huellas idénticas entre ambos (ambos consumen el shape del filtro).
fp_of() { # $1 = objeto JSON del finding (una línea del JSONL normalizado por el filtro compartido)
  printf '%s' "$1" | jq -j '[(.file // ""), ((.lineStart // "")|tostring), ((.lineEnd // "")|tostring), (.title // ""), (.category // ""), (.fpMaterial // [])] | tojson' 2>/dev/null | sha256_hex
}

# TEXTLESS/phantom — la triageabilidad la define AHORA una sola fuente de verdad: el filtro
# compartido `cr-finding-normalize.jq` (TAL-2610), que SOLO emite findings con cuerpo textual real, y
# el gate de PARIDAD del flujo principal (`normalized == blockers`) que FALLA-CERRADO si algún
# bloqueante no salió triageable. Un textless-phantom nunca llega a known-debt ni al universo del
# historial: aborta el gate con `state=error` (universo vacío) y su crudo queda preservado en `$RAW`
# como evidencia. Por eso ya NO existe un predicado `is_textless` propio (evita el drift jq↔filtro que
# TAL-2610 fue creado para cerrar): la doctrina «phantom no waiveable» la impone la paridad, aguas
# arriba de --accept-debt.

# --- Concurrencia (TAL-2816): lock del kernel, SIN fallback hand-rolled (B-03 ronda 2) -----
# Serializa TODA mutación read-modify-write del estado por-SHA. Captura el rc de `"$@"` y libera
# SIEMPRE el lock (los callees RETORNAN, nunca `exit` dentro del lock → estas líneas siempre corren).
# NO existe fallback "portable" sin `flock`: un lock mkdir con robo por timeout/mtime puede robar
# el directorio de un propietario que sigue VIVO (solo tardó >1min) y dejar DOS ejecuciones dentro
# de la sección crítica a la vez — el timeout no es un fencing token, es solo un reloj. Un lock
# "seguro" sin `flock` requeriría un fencing token verificado antes de cada `rm`, que ningún primitivo
# POSIX de shell puede garantizar atómicamente contra el propio dueño vivo. Por eso: sin `flock`
# disponible, FAIL-CLOSED (se niega a serializar) en vez de fingir seguridad con un lock inseguro.
with_ledger_lock() {
  mkdir -p .claude
  command -v flock >/dev/null 2>&1 || {
    echo "cr-review: 'flock' (util-linux) es OBLIGATORIO para serializar el ledger sin carreras. Ningún fallback hand-rolled (mkdir+timeout) es fail-closed ante un propietario vivo que tarda >1min — no disponible → fail-closed. Instala util-linux o corre donde flock exista." >&2
    return 1
  }
  exec 9>"$LEDGER_LOCK" || return 1             # FD fijo 9 → compat bash 3.2
  flock -w 30 9 || { echo "cr-review: no pude tomar el lock del ledger (30s)." >&2; exec 9>&-; return 1; }
  "$@"; local rc=$?; flock -u 9; exec 9>&-; return "$rc"  # kernel libera el FD-lock si el proceso muere
}

# --- Snapshot binding (R5-B2/R6-B1): fingerprint tamper-evidente con reflog -----------------
# reflog ON? (core.logAllRefUpdates; unset en repo no-bare = default true = OK).
reflog_enabled() {
  local v
  v="$(git config --get core.logAllRefUpdates 2>/dev/null || true)"
  case "$v" in
    false) return 1 ;;
    true|always) return 0 ;;
    "") [ "$(git rev-parse --is-bare-repository 2>/dev/null)" = "false" ] && return 0 || return 1 ;;
    *) return 1 ;;
  esac
}
# Hashea el CONTENIDO CRUDO del reflog (fichero, NO la salida de `git reflog` que sale 0 y vacía si
# no existe — R6-B1) + HEAD + base. Cada mutación de HEAD añade una línea al reflog → el hash cambia
# aunque el árbol vuelva al mismo SHA (A→B→A detectado). rc no-cero (fail-closed) si el reflog está
# deshabilitado o `logs/HEAD` está ausente/VACÍO.
snapshot_fp() {
  reflog_enabled || return 1
  local head base hlog blog
  head="$(git rev-parse HEAD 2>/dev/null)" || return 1
  base="$(git rev-parse origin/main 2>/dev/null || true)"
  hlog="$(git rev-parse --git-path logs/HEAD 2>/dev/null)"
  [ -s "$hlog" ] || return 1                     # reflog de HEAD ausente/VACÍO → fail-closed (R6-B1)
  blog="$(git rev-parse --git-path logs/refs/remotes/origin/main 2>/dev/null || true)"
  { printf '%s\n%s\n' "$head" "$base"; cat "$hlog"; [ -n "$blog" ] && [ -s "$blog" ] && cat "$blog"; } | sha256_hex
}

# Epoch aleatorio 128-bit (no-reutilizable). FAIL-CLOSED sin /dev/urandom (M-02 ronda 3): un fencing
# token que promete "no-reutilizable" no puede degradar a $RANDOM+PID+timestamp (predecible/de baja
# entropía) — eso reabriría exactamente la clase ABA que el epoch existe para cerrar. Sin los 128 bits
# exactos (32 hex de `od`), `start_run` aborta (ver _start_run_locked) en vez de fenceear con una fuente
# débil.
_mint_epoch() {
  local e
  e="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
  { [ -n "$e" ] && [ "${#e}" -eq 32 ]; } || return 1   # 128 bits EXACTOS o fail-closed; sin degradar
  printf '%s' "$e"
}

# --- Primitivos UNLOCKED de escritura (atómicos; DEVUELVEN no-cero si algo falla — R3-B2) ---
# NUNCA se llaman fuera de una sección `with_ledger_lock` (excepto la lectura del gen en start_run).
_emit_result() { # state reason [blocking_json] [known_json]
  local tmp
  tmp="$(mktemp .claude/.cr-review-result.XXXXXX 2>/dev/null)" || return 1
  jq -n --arg s "$1" --arg r "$2" --arg h "$HEAD_SHA" --arg b "$BASE_SHA" \
    --arg ep "$RUN_EPOCH" --argjson gv "${RUN_GEN:-0}" --arg rid "$RUN_ID" \
    --argjson f "${3:-[]}" --argjson k "${4:-[]}" --arg seat "$SEAT_FP" \
    '{state:$s, reason:$r, head_sha:$h, base_sha:$b, gen:{epoch:$ep,value:$gv}, run_id:$rid, blocking_findings:$f, known_debt:$k, seat_fp:$seat, ts:(now|todateiso8601)}' > "$tmp" 2>/dev/null \
    || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$RESULT" || { rm -f "$tmp"; return 1; }
}
# Contrato del sentinel (H-7 del spike TAL-3568 · PNR-3): son SIEMPRE 5 líneas en este orden.
#   L1 = HEAD_SHA   ← lo parsea `.githooks/pre-push` (compara contra el OID que se empuja)
#   L2 = base_sha   ← RESERVADO: se escribe y NADIE lo lee (ningún hook, ningún script)
#   L3 = state      ← lo parsea el hook (`ok` | `deferred`)
#   L4 = reason     ← RESERVADO: se escribe y NADIE lo lee
#   L5 = ts         ← lo parsea el hook (solo si L3=`deferred`, para el TTL de 2 h)
# L2/L4 quedan como RESERVADOS a propósito: eliminarlos o reordenar cualquier línea rompería DOS
# hooks a la vez (producto y motor parsean por número de línea) y bloquearía todo push en ambos
# repos. Punto de no retorno sin ventana de fallo: se añade al final o no se toca.
_emit_sentinel() { # estado razón [base_sha]  — formato del hook: L1=HEAD_SHA L2=base L3=state L4=reason L5=ts
  local tmp
  tmp="$(mktemp .claude/.cr-review-ok.XXXXXX 2>/dev/null)" || return 1
  printf '%s\n%s\n%s\n%s\n%s\n' "$HEAD_SHA" "${3:-$BASE_SHA}" "$1" "$2" "$(date -u +%FT%TZ)" > "$tmp" \
    || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$SENTINEL" || { rm -f "$tmp"; return 1; }
}
_write_findings() { # persiste RUN_FINDINGS_LINES estampado run_id/gen (fp_of ignora esos campos)
  [ -n "$RUN_FINDINGS_LINES" ] || return 0
  local tmp
  tmp="$(mktemp .claude/.cr-review-findings.XXXXXX 2>/dev/null)" || return 1
  printf '%s' "$RUN_FINDINGS_LINES" \
    | jq -c --arg rid "$RUN_ID" --arg ep "$RUN_EPOCH" --argjson gv "${RUN_GEN:-0}" \
        '. + {run_id:$rid, gen:{epoch:$ep,value:$gv}}' > "$tmp" 2>/dev/null \
    || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$FINDINGS" || { rm -f "$tmp"; return 1; }
}

# Universo SANITIZADO (allowlist) de findings, con fp. NO persiste description/prompt (snippets).
# M-02 (síntesis r2): REUTILIZA el conjunto YA normalizado+validado por PARIDAD del flujo principal
# (`RUN_UNIVERSE_LINES` = el mismo `CAND` que emitió `cr-finding-normalize.jq`), en vez de re-normalizar
# `$RAW` en un 2º pase — elimina el doble pase y el fail-OPEN donde un jq/fp fallido silenciado por
# `|| true` dejaba `findings:[]` tras una paridad válida (historial incompleto con push autorizado).
# Solo se construye para estados ok/findings ya validados (sin phantoms; por eso no hay campo
# `textless`). FAIL-CLOSED: cualquier fallo de fp_of/proyección/agregación PROPAGA (return 1) →
# `_write_history` falla → `_commit_locked` aborta SIN sentinel (jamás un historial incompleto+autorizado).
_history_universe() {
  local line fp rec recs=""
  [ -n "$RUN_UNIVERSE_LINES" ] || { printf '[]'; return 0; }   # 0 findings validados → universo vacío legítimo
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    fp="$(fp_of "$line")" || return 1
    rec="$(printf '%s' "$line" | jq -c --arg fp "$fp" '{severity, file, lineStart, lineEnd, title, category, fp:$fp}')" || return 1
    [ -n "$rec" ] || return 1
    recs+="$rec"$'\n'
  done <<< "$RUN_UNIVERSE_LINES"
  printf '%s' "$recs" | jq -c -s '.' || return 1
}

# Historial append-only: reescritura ATÓMICA (read+temp+rename, nunca `>>` — R2-B3) con poda por
# rama (R2-B1..) en la MISMA pasada; poda los crudos EVICTADOS, finales Y `.partial` (nunca crudos
# en vuelo). M-01 ronda 3: TODO run entra al historial, exista o no `$RAW` final — antes, un run
# incompleto/interrumpido/rate-limited (que solo deja `.partial`, nunca se promueve) se saltaba el
# ledger por completo (`[ -s "$RAW" ] || return 0`), dejando huecos en la evidencia Y evitando que su
# `.partial` entrara jamás en el barrido de retención (acumulación sin límite). Ahora TODOS los runs
# quedan sujetos a la MISMA ventana de retención por rama, y su evidencia cruda (final o parcial) se
# poda cuando su `run_id` es evictado — no antes.
# IMPORTANTE (R13-B1/R14-B1): $1 es el estado EFECTIVO (post-gate de generación/snapshot en
# _commit_locked), NUNCA el estado reclamado por el run sin validar. El universo SOLO se afirma
# cuando el estado efectivo es ok/findings Y existe `$RAW` final — un run `superseded`, con snapshot
# stale (rebajado a `error`), o simplemente sin review completo (error/deferred/blocked/interrupted)
# persiste con universo VACÍO: el ledger nunca publica findings de una revisión que el gate no
# autorizó, así el run haya visto/creído tener un veredicto distinto.
# Fusiona UNA entrada JSON ya construida en `$HISTORY` con poda por retención + diff de run_ids
# EVICTADOS en la MISMA pasada (M-02 ronda 5: extraído de `_write_history` para que la reconciliación
# de huérfanos, `_reconcile_orphaned_raws_locked`, aplique la MISMA disciplina de poda — antes su
# propia reescritura podía expulsar entradas por retención SIN podar su crudo/lockfile, dejándolos
# inalcanzables para siempre). Poda por run_id evictado el crudo final `.jsonl`, el `.partial` (a lo
# sumo uno de los dos existe por run) y el lockfile por-run `runlock-<id>` (rm inocuo si no existe).
_merge_history_entry() { # $1 = entry JSON (una línea)
  local entry="$1" htmp before_ids after_ids rid
  [ -n "$entry" ] || return 1
  before_ids="$( { [ -f "$HISTORY" ] && jq -r '.run_id // empty' "$HISTORY" 2>/dev/null; true; } | sort -u)"
  htmp="$(mktemp .claude/.cr-review-history.XXXXXX 2>/dev/null)" || return 1
  { [ -f "$HISTORY" ] && cat "$HISTORY"; printf '%s\n' "$entry"; } \
    | jq -c -s --argjson n "$HISTORY_RETENTION" 'group_by(.branch)|map(.[([length-$n,0]|max):])|add|.[]' > "$htmp" 2>/dev/null \
    || { rm -f "$htmp"; return 1; }
  after_ids="$(jq -r '.run_id // empty' "$htmp" 2>/dev/null | sort -u)"
  mv -f "$htmp" "$HISTORY" || { rm -f "$htmp"; return 1; }
  # Poda de crudos EVICTADOS (presentes antes / ausentes después). comm exige entradas ordenadas.
  while IFS= read -r rid; do
    [ -n "$rid" ] || continue
    rm -f ".claude/.cr-review-raw-${rid}.jsonl" ".claude/.cr-review-raw-${rid}.jsonl.partial" \
      ".claude/.cr-review-runlock-${rid}" 2>/dev/null || true
  done < <(comm -23 <(printf '%s\n' "$before_ids") <(printf '%s\n' "$after_ids"))
  return 0
}

_write_history() { # eff_state
  local state="$1" universe entry
  if { [ "$state" = ok ] || [ "$state" = findings ]; } && [ -s "$RAW" ]; then
    universe="$(_history_universe)" || return 1        # M-02: propaga el fallo (no defaultea a []) → sin sentinel
  else
    universe='[]'
  fi
  # TAL-3637: `seat_fp` viaja al ledger, no solo al `result` (slot que la corrida siguiente PISA).
  # `null` —no cadena vacía— cuando el run terminó antes del guard de auth (deferred/blocked/error
  # temprano, huérfanos): "no hubo asiento" y "el asiento fue ''" no son lo mismo para quien audita.
  entry="$(jq -c -n --arg rid "$RUN_ID" --arg ep "$RUN_EPOCH" --argjson gv "${RUN_GEN:-0}" \
     --arg sha "$HEAD_SHA" --arg base "$BASE_SHA" --arg br "$BRANCH" --arg st "$state" \
     --arg seat "$SEAT_FP" --argjson u "$universe" \
     '{run_id:$rid, gen:{epoch:$ep,value:$gv}, sha:$sha, base_sha:$base, ts:(now|todateiso8601), branch:$br, state:$st, seat_fp:(if $seat == "" then null else $seat end), finding_count:($u|length), findings:$u}' 2>/dev/null)" || return 1
  _merge_history_entry "$entry"
}

# --- Reconciliación de RAWs HUÉRFANOS (M-01 r4 · corregido r5 · rediseño flock r6: M-01/M-02/M-03) --
# La poda de `_write_history`/`_merge_history_entry` solo alcanza run_ids que YA estaban en
# `$HISTORY`: un crudo cuyo proceso murió por SIGKILL/OOM ANTES de llegar a `commit_run` nunca entró
# al historial, así que la retención (diff before/after) nunca lo alcanza — queda indefinidamente.
# Ningún trap de bash captura SIGKILL, así que NO se resuelve con más traps: se resuelve con un
# barrido de reconciliación en cada arranque, bajo lock, ANTES de `start_run`.
#
# VIVACIDAD AUTORITATIVA POR flock (ronda 6, reemplaza la heurística PID+mtime de r5): cada run
# SOSTIENE un `flock` sobre su `$RUN_LOCK` durante TODA su vida (adquirido ANTES de crear cualquier
# crudo — invariante clave: si existe un crudo, su lock ya está tomado; si el proceso muere, el kernel
# libera el lock, SIGKILL incluido). El reconciliador PRUEBA la muerte adquiriendo ese lock
# (`flock -n` no-bloqueante) en vez de adivinar con PID+mtime:
#   - `RUN_LOCK` ausente ⟹ NO es un run vivo (invariante: un run vivo siempre tiene su lockfile) ⟹ muerto.
#   - `flock -n` ADQUIERE ⟹ nadie lo sostiene ⟹ dueño MUERTO ⟹ reconcilia.
#   - `flock -n` NO adquiere ⟹ dueño VIVO (aunque su CLI lleve horas silencioso) ⟹ intacto.
# Sin ventana (el lock precede al crudo), sin mtime, sin ambigüedad de reutilización de PID — el
# kernel es la fuente de verdad. (M-01 y M-03 caen juntos: la protección de proceso vivo ya no es
# opcional ni best-effort ni temporal.)
#   M-02 (crudos finales + poda de evictados): el barrido escanea AMBAS formas — `.partial` (crash
#   pre-promoción) Y `.jsonl` final (crash POST-promoción, antes de `commit_run` — deja un RAW final
#   sin historial que el escaneo solo-`.partial` de r5 jamás veía). El registro pasa por
#   `_merge_history_entry` (misma poda con diff before/after que `_write_history`), así que una
#   entrada `orphaned` que expulse a otra por retención poda el crudo de la expulsada igual que
#   cualquier escritura normal. La rama del huérfano viene del CONTENIDO de su `$RUN_LOCK` (`{branch}`),
#   NUNCA de `$BRANCH` del reconciliador; sin contenido legible → `_orphaned_unknown`.
#   M-01 (no perder evidencia si falla la persistencia): el crudo y su lockfile SOLO se borran si
#   `_merge_history_entry` confirma que la entrada `orphaned` quedó persistida; si falla (disco lleno,
#   historial corrupto), se CONSERVAN intactos para reintentar en el próximo arranque.
# Best-effort: un fallo aquí NO aborta el run normal — es housekeeping, no la autorización del sentinel.
#
# `_owner_is_dead <runlock>`: rc 0 = muerto (o sin lockfile) · rc 1 = vivo (o incierto). Abre el
# lockfile en un FD propio (7) en modo append (NUNCA trunca el contenido del dueño vivo) y prueba
# `flock -n`. SESGO CONSERVADOR: solo devuelve "muerto" cuando puede PROBARLO (lockfile ausente por
# el invariante, o flock adquirido). Cualquier incertidumbre (no puedo abrir el lockfile) → "vivo"
# (skip): nunca se borra evidencia sin prueba de muerte — un orphan real siempre es openable (0600
# propio), así que este sesgo no deja basura acumulándose en la práctica.
_owner_is_dead() {
  local rl="$1"
  [ -e "$rl" ] || return 0                          # sin lockfile ⟹ no hay run vivo (invariante) ⟹ muerto
  exec 7>>"$rl" 2>/dev/null || return 1             # no puedo abrir ⟹ INCIERTO ⟹ trátalo como vivo (no borrar)
  if flock -n 7 2>/dev/null; then
    flock -u 7 2>/dev/null; exec 7>&- 2>/dev/null; return 0   # adquirido ⟹ dueño muerto
  fi
  exec 7>&- 2>/dev/null; return 1                    # no adquirido ⟹ dueño vivo
}

reconcile_orphaned_raws() { with_ledger_lock _reconcile_orphaned_raws_locked; }
_reconcile_orphaned_raws_locked() {
  set +e
  local known_ids f base rid rl orig_branch entry any=0
  known_ids="$( { [ -f "$HISTORY" ] && jq -r '.run_id // empty' "$HISTORY" 2>/dev/null; true; } | sort -u)"
  # AMBAS formas: `.partial` (pre-promoción) y `.jsonl` final (post-promoción). Disjuntas (una termina
  # en `.partial`, la otra en `.jsonl`), así que ningún run se procesa dos veces.
  for f in .claude/.cr-review-raw-*.jsonl.partial .claude/.cr-review-raw-*.jsonl; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    rid="${base#.cr-review-raw-}"; rid="${rid%.jsonl.partial}"; rid="${rid%.jsonl}"
    [ -n "$rid" ] || continue
    printf '%s\n' "$known_ids" | grep -qx "$rid" && continue          # ya tiene entrada: retención lo maneja
    rl=".claude/.cr-review-runlock-${rid}"
    _owner_is_dead "$rl" || continue                                  # dueño VIVO (flock sostenido) ⟹ intacto
    orig_branch="$( [ -s "$rl" ] && jq -r '.branch // empty' "$rl" 2>/dev/null || true)"
    [ -n "$orig_branch" ] || orig_branch="_orphaned_unknown"          # M-02: rama del lockfile, nunca del reconciliador
    # TAL-3637: `seat_fp:null` explícito — el reconciliador no sabe (ni puede saber) qué asiento gastó
    # un run cuyo proceso murió; el campo existe en TODA entrada para no partir el shape del ledger.
    entry="$(jq -c -n --arg rid "$rid" --arg br "$orig_branch" \
      '{run_id:$rid, gen:{epoch:null,value:null}, sha:null, base_sha:null, ts:(now|todateiso8601), branch:$br, state:"orphaned", seat_fp:null, finding_count:0, findings:[]}' 2>/dev/null)"
    if [ -n "$entry" ] && _merge_history_entry "$entry"; then
      known_ids="$(printf '%s\n%s' "$known_ids" "$rid" | sort -u)"
      rm -f "$f" "$rl" 2>/dev/null                    # M-01: solo se borra si la persistencia SE CONFIRMÓ
      any=1
    else
      echo "cr-review: no pude registrar el crudo huérfano ${rid} en el historial — lo conservo para reintentar en el próximo arranque (fail-closed: nunca se pierde evidencia sin su registro)." >&2
    fi
  done
  [ "$any" -eq 1 ] && echo "cr-review: reconciliados crudos huérfanos (dueño muerto probado por flock, sin entrada en el historial — evidencia de crash/SIGKILL previo)." >&2
  return 0
}

# --- Arranque del run: sentinel invalidado PRIMERO, luego generación no-reutilizable (R4-B2/R5-B1) ---
start_run() { with_ledger_lock _start_run_locked; }
_start_run_locked() {
  set +e
  rm -f "$SENTINEL" 2>/dev/null || true          # 1. INVALIDAR el sentinel ANTES de nada (R4-B2)
  [ ! -e "$SENTINEL" ] || return 1
  # 2. generación NO-reutilizable {epoch,value}
  local prev_epoch prev_value gtmp
  prev_epoch="$( [ -s "$GEN_FILE" ] && jq -r '.epoch // empty' "$GEN_FILE" 2>/dev/null || true)"
  prev_value="$( [ -s "$GEN_FILE" ] && jq -r '.value // empty' "$GEN_FILE" 2>/dev/null || true)"
  if [ -n "$prev_epoch" ] && printf '%s' "$prev_value" | grep -qE '^[0-9]+$'; then
    RUN_EPOCH="$prev_epoch"; RUN_GEN="$((prev_value + 1))"
  else
    RUN_EPOCH="$(_mint_epoch)" || return 1        # ausente/corrupto → epoch NUEVO (fencea a runs viejos)
    RUN_GEN=1
  fi
  gtmp="$(mktemp .claude/.cr-review-gen.XXXXXX 2>/dev/null)" || return 1
  jq -c -n --arg e "$RUN_EPOCH" --argjson v "$RUN_GEN" '{epoch:$e, value:$v}' > "$gtmp" 2>/dev/null \
    || { rm -f "$gtmp"; return 1; }
  mv -f "$gtmp" "$GEN_FILE" || { rm -f "$gtmp"; return 1; }
  [ "$(jq -r '.epoch // empty' "$GEN_FILE" 2>/dev/null)" = "$RUN_EPOCH" ] || return 1  # verifica la escritura
  # 3. RESULT=running + limpiar FINDINGS de una corrida previa
  _emit_result running started || return 1
  rm -f "$FINDINGS" 2>/dev/null || true
  return 0
}

# --- Commit transaccional (R2/R3/R4/R5): todo el estado por-SHA en UNA sección crítica --------
# Paso 0: desarma TODOS los traps y marca COMMITTED (el `exit` final no re-dispara ningún trap).
# _commit_locked RETORNA un rc (NUNCA `exit` dentro del lock) → with_ledger_lock siempre libera.
commit_run() { # want_rc state reason
  trap - EXIT INT TERM
  # TAL-3562: si el snapshot inmutable del asiento sigue vivo (una señal interrumpió el run entre
  # crearlo y la limpieza normal tras `review`), no dejarlo huérfano en /tmp — nunca contuvo más que
  # una copia de la sesión, pero es material sensible igual (regla 18). No-op si ya se limpió o si
  # nunca llegó a crearse.
  [ -n "$SNAP_HOME" ] && rm -rf "$SNAP_HOME" 2>/dev/null; true
  COMMITTED=1
  set +e
  local rc
  with_ledger_lock _commit_locked "$1" "$2" "$3"
  rc=$?
  # Liberación del lock por-run (ronda 6): la historia YA quedó escrita salvo en el fallo específico
  # de persistencia (`_write_history` → rc 30). Solo entonces se conserva `$RUN_LOCK` para que un
  # arranque futuro reintente la reconciliación de este crudo (sin lockfile, el reconciliador lo daría
  # por muerto y lo podaría — correcto, pero preferimos que su re-registro pase por la vía normal). En
  # cualquier otro rc, la entrada de historial existe → soltamos y borramos el lockfile (limpieza). El
  # `exec 8>&-` cierra el FD (redundante ante el `exit`, pero explícito) liberando el flock del kernel.
  if [ "$rc" -ne 30 ]; then rm -f "$RUN_LOCK" 2>/dev/null || true; fi
  exec 8>&- 2>/dev/null || true
  exit "$rc"
}
_commit_locked() { # want_rc state reason -> rc final del proceso
  set +e
  local want_rc="$1" state="$2" reason="$3"
  # 1. Gate de generación NO-reutilizable FAIL-CLOSED (R5-B1/R4-B1/R13-B1) — EL FENCING TOKEN.
  #    Se valida ANTES de tocar CUALQUIER artefacto, incluido el historial: un run cuyo {epoch,value}
  #    ya no coincide con GEN_FILE no es el owner vigente y NUNCA publica el estado que reclama (evita
  #    que un escritor obsoleto pise a uno más nuevo, aunque su review haya "terminado" después).
  local cur_epoch cur_value eff_state="$state"
  cur_epoch="$( [ -s "$GEN_FILE" ] && jq -r '.epoch // empty' "$GEN_FILE" 2>/dev/null || true)"
  cur_value="$( [ -s "$GEN_FILE" ] && jq -r '.value // empty' "$GEN_FILE" 2>/dev/null || true)"
  if ! { [ -n "$cur_epoch" ] && printf '%s' "$cur_value" | grep -qE '^[0-9]+$' \
         && [ "$cur_epoch" = "$RUN_EPOCH" ] && [ "$cur_value" = "$RUN_GEN" ]; }; then
    eff_state="superseded"                        # discriminador de TOPE (R14-B1): gana a todo lo demás
  # 2. Revalidación del snapshot BAJO LOCK (R5-B2/R6-B1/B-01 ronda 2) — solo si la generación quedó
  #    autorizada arriba, y solo para estados con universo real (ok/findings). Una revisión stale
  #    (repo cambió a mitad del review) tampoco llega a publicar/afirmar su veredicto. B-01: además
  #    del hash opaco con reflog, comprueba EXPLÍCITAMENTE que el HEAD/tree LIVE en este instante —
  #    justo antes de emitir el sentinel — sigue siendo el mismo que se revisó (`REVIEW_HEAD`/
  #    `REVIEW_TREE`) Y el mismo que se va a autorizar (`HEAD_SHA`, el valor horneado en sentinel/
  #    result): cierra la ventana TOCTOU completa, no solo la mitad que cubre el fingerprint del reflog.
  elif { [ "$state" = ok ] || [ "$state" = findings ]; } && [ -s "$RAW" ]; then
    local now_fp now_head now_tree
    now_fp="$(snapshot_fp 2>/dev/null || true)"
    now_head="$(git rev-parse HEAD 2>/dev/null || true)"
    now_tree="$(git rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
    if [ -z "$REVIEW_FP" ] || [ -z "$now_fp" ] || [ "$now_fp" != "$REVIEW_FP" ] \
       || [ -z "$REVIEW_HEAD" ] || [ "$now_head" != "$REVIEW_HEAD" ] || [ "$now_head" != "$HEAD_SHA" ] \
       || [ -z "$REVIEW_TREE" ] || [ "$now_tree" != "$REVIEW_TREE" ]; then
      eff_state="error"; reason="stale-repo-state"
    fi
  fi
  # 3. HISTORIAL con el estado EFECTIVO (R13-B1): el ledger nunca persiste un universo que el gate
  #    de generación/snapshot no autorizó — jamás el estado tal como lo reclama una revisión obsoleta.
  _write_history "$eff_state" || return 30
  # 4. Autorización — MISMOS discriminadores y MISMO orden que arriba (nunca toca RESULT/FINDINGS/
  #    SENTINEL si no está autorizado: superseded no publica NADA; stale publica solo el error).
  if [ "$eff_state" = superseded ]; then
    echo "cr-review: run supersedido/incierto (generación no coincide) — no se publica verdict. Re-corre." >&2
    return 1                                      # superseded/uncertain: NO toca artefactos autorizantes
  fi
  if [ "$eff_state" = error ] && [ "$reason" = stale-repo-state ]; then
    rm -f "$SENTINEL" 2>/dev/null || true
    _emit_result error "stale-repo-state" "$RUN_BLOCKING" "$RUN_KNOWN" 2>/dev/null || true
    echo "cr-review: el repo cambió durante la revisión (snapshot no coincide) — no se autoriza. Re-corre." >&2
    return 40
  fi
  # 5. Publicación: sentinel invalidado PRIMERO, autorizador ÚLTIMO, verificando cada paso
  rm -f "$SENTINEL" 2>/dev/null || true
  if [ "$state" = findings ]; then
    _write_findings || { rm -f "$SENTINEL" 2>/dev/null || true; return 31; }
  else
    rm -f "$FINDINGS" 2>/dev/null || true
  fi
  _emit_result "$state" "$reason" "$RUN_BLOCKING" "$RUN_KNOWN" || { rm -f "$SENTINEL" 2>/dev/null || true; return 32; }
  if [ "$state" = ok ]; then
    _emit_sentinel ok "$reason" "$BASE_SHA" || { rm -f "$SENTINEL" 2>/dev/null || true; return 33; }
  elif [ "$state" = deferred ]; then
    _emit_sentinel deferred "$reason" "$BASE_SHA" || { rm -f "$SENTINEL" 2>/dev/null || true; return 33; }
  fi
  # 6. Contrato de exit — M7: `interrupted` JAMÁS propaga rc=0. Un exit inesperado sin estado
  #    terminal committeado (want_rc llegó en 0) no debe leerse nunca como éxito (fail-closed real,
  #    no un exit engañoso que el hook/CI pueda confundir con un gate autorizado).
  if [ "$state" = ok ] || [ "$state" = deferred ]; then return 0; fi
  if [ "$state" = interrupted ] && [ "$want_rc" -eq 0 ] 2>/dev/null; then return 1; fi
  return "$want_rc"
}

# Disciplina de traps (R5-B3): el trap NUNCA pisa un estado terminal ya escrito. M7: si no hay
# estado terminal committeado, un exit inesperado con rc=0 NUNCA se interpreta como éxito — se fuerza
# a 1 (fail-closed) antes de commitear `interrupted` (defensa en profundidad junto al blindaje
# equivalente en `_commit_locked`).
on_exit() { local rc=$?; [ -n "${COMMITTED:-}" ] && exit "$rc"; [ "$rc" -ne 0 ] 2>/dev/null || rc=1; commit_run "$rc" interrupted interrupted; }
on_signal() { commit_run 130 interrupted interrupted; }

# §Backstop: un `deferred` SOLO es válido con un PR existente cuyo label cr-review quede VERIFICADO.
# Sin PR (primer push) → state=blocked, NO sentinel (el hook bloqueará el push). Sin race con gh pr create.
defer_or_block() { # razón
  local reason="$1"
  if command -v gh >/dev/null 2>&1 && gh pr view "$BRANCH" --json number >/dev/null 2>&1; then
    if gh pr edit "$BRANCH" --add-label cr-review >/dev/null 2>&1 \
       && gh pr view "$BRANCH" --json labels --jq '.labels[].name' 2>/dev/null | grep -qx 'cr-review'; then
      echo "cr-review: deferred ($reason) — PR de '$BRANCH' etiquetado cr-review (el App lo revisará). Sentinel emitido; push permitido."
      commit_run 0 deferred "$reason"
    fi
    echo "cr-review: deferred ($reason) pero NO pude garantizar el label cr-review en el PR. No se emite sentinel." >&2
    commit_run 1 error "deferred-$reason-label-failed"
  fi
  cat >&2 <<EOF
cr-review: CR-CLI no disponible ($reason) y NO hay PR para '$BRANCH' todavía.
El PRIMER push exige un review CLI limpio (sin PR no se puede garantizar el backstop del App sin race).
Salidas:
  (a) consigue CLI/red y re-corre:  bash scripts/cr-review.sh
  (b) emergencia consciente:        git push --no-verify   (salta el gate; queda en el reflog)
      y luego abre el PR con:        gh pr create --label cr-review ...
EOF
  commit_run 1 blocked "$reason"
}

# --- Modos known debt (TAL-2272) — ANTES de los efectos laterales del run normal -----------
# (el run normal escribe `running` en el result y borra el findings JSONL: exactamente lo que
# estos modos necesitan leer). No requieren red, CLI ni auth. Primer arg desconocido → error
# (fail-closed: un typo no debe quemar una corrida del bucket).
case "${1:-}" in
  "" ) : ;;  # sin args → run normal
  --list-findings)
    if [ ! -s "$FINDINGS" ]; then
      echo "cr-review: no hay findings persistidos del último run ($FINDINGS ausente o vacío)."
      exit 0
    fi
    rhead="$(jq -r '.head_sha // empty' "$RESULT" 2>/dev/null || true)"
    echo "Findings del último run (head ${rhead:-desconocido}):"
    n=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      n=$((n+1))
      printf '%s' "$line" | jq -r --arg n "$n" \
        '"  [\($n)] [\(.severity // "?")] \(.file // "?"):\((.lineStart // "?")|tostring)-\((.lineEnd // "?")|tostring) — \(.title // "(sin título)")"' \
        || printf '  [%d] (línea no parseable)\n' "$n"
    done < "$FINDINGS"
    if [ -s "$KNOWN_DEBT" ]; then
      tree="$(git rev-parse 'HEAD^{tree}')"
      rbase="$(jq -r '.base_sha // empty' "$RESULT" 2>/dev/null || true)"
      [ -n "$rbase" ] || rbase="$(git rev-parse origin/main 2>/dev/null || echo '')"
      vig="$(jq -s -r --arg t "$tree" --arg b "$rbase" '[.[]|select(.tree_sha==$t and .base_sha==$b)]|length' "$KNOWN_DEBT" 2>/dev/null || echo 0)"
      tot="$(grep -c '' "$KNOWN_DEBT" 2>/dev/null || echo 0)"
      echo "Known debt: ${vig} entrada(s) vigente(s) para este árbol/base (${tot} en el store)."
    else
      echo "Known debt: store vacío."
    fi
    echo "Aceptar deuda (granular, por índice): bash scripts/cr-review.sh --accept-debt <n>[,<n>...] \"<nota>\""
    exit 0
    ;;
  --accept-debt)
    IDX_ARG="${2:-}"; NOTE="${3:-}"
    usage_debt() { echo "cr-review: uso: bash scripts/cr-review.sh --accept-debt <n>[,<n>...] \"<nota del waiver>\" (índices de --list-findings; sin atajo 'all' — la aceptación es granular por diseño)." >&2; exit 1; }
    printf '%s' "$IDX_ARG" | grep -qE '^[0-9]+(,[0-9]+)*$' || usage_debt
    [ -n "$NOTE" ] || { echo "cr-review: la NOTA es obligatoria (waiver documentado: motivo, p.ej. \"flip-flop 1/3 no reproducible\" o \"deuda gated TAL-N\")." >&2; usage_debt; }
    have_sha256 || { echo "cr-review: sin sha256sum/shasum disponible — no se puede calcular la huella del finding. Registro rechazado (fail-closed)." >&2; exit 1; }
    [ -f "$RESULT" ] || { echo "cr-review: no hay $RESULT — corre primero 'bash scripts/cr-review.sh' y triage los findings." >&2; exit 1; }
    rstate="$(jq -r '.state // empty' "$RESULT" 2>/dev/null || true)"
    [ "$rstate" = "findings" ] || { echo "cr-review: el último run no terminó en state=findings (state='${rstate:-?}') — no hay nada que aceptar." >&2; exit 1; }
    rhead="$(jq -r '.head_sha // empty' "$RESULT" 2>/dev/null || true)"
    [ "$rhead" = "$HEAD_SHA" ] || { echo "cr-review: el head del último run (${rhead:0:12}) NO es el HEAD actual (${HEAD_SHA:0:12}) — commiteaste después del review. Re-corre 'bash scripts/cr-review.sh' y re-triage." >&2; exit 1; }
    rbase="$(jq -r '.base_sha // empty' "$RESULT" 2>/dev/null || true)"
    [ -n "$rbase" ] || { echo "cr-review: el result no trae base_sha (run de una versión previa del script). Re-corre 'bash scripts/cr-review.sh' antes de aceptar deuda (sin fallback: el binding debe ser exacto)." >&2; exit 1; }
    [ -s "$FINDINGS" ] || { echo "cr-review: no hay $FINDINGS del último run — nada que aceptar." >&2; exit 1; }
    total="$(grep -c '' "$FINDINGS")"
    TREE_SHA="$(git rev-parse 'HEAD^{tree}')"
    ts="$(date -u +%FT%TZ)"
    new_entries=""
    for i in $(printf '%s' "$IDX_ARG" | tr ',' '\n' | sort -un); do
      { [ "$i" -ge 1 ] && [ "$i" -le "$total" ]; } 2>/dev/null \
        || { echo "cr-review: índice ${i} fuera de rango (findings del último run: 1..${total}). Nada registrado." >&2; exit 1; }
      line="$(sed -n "${i}p" "$FINDINGS")"
      # (Doctrina «phantom no waiveable»: ya NO se comprueba aquí — el filtro compartido + la paridad
      # del flujo principal impiden que un textless-phantom llegue siquiera a `$FINDINGS`; si hubiera
      # uno, el run habría abortado con state=error y no habría nada que aceptar. La defensa vive
      # aguas arriba, no en este guard redundante.)
      fp="$(fp_of "$line" || true)"
      [ -n "$fp" ] || { echo "cr-review: no pude calcular la huella del finding ${i}. Nada registrado (fail-closed)." >&2; exit 1; }
      entry="$(printf '%s' "$line" | jq -c --arg t "$TREE_SHA" --arg b "$rbase" --arg h "$HEAD_SHA" --arg ts "$ts" --arg note "$NOTE" --arg fp "$fp" \
        '{tree_sha:$t, base_sha:$b, head_sha:$h, accepted_at:$ts, note:$note, fp:$fp, severity:(.severity // null), file:(.file // null), lineStart:(.lineStart // null), lineEnd:(.lineEnd // null), title:(.title // null)}')" \
        || { echo "cr-review: finding ${i} no parseable. Nada registrado." >&2; exit 1; }
      new_entries+="$entry"$'\n'
    done
    # Merge atómico BAJO LOCK con dedupe por (tree_sha, base_sha, fp) + revalidación HEAD/árbol
    # (R1-B2: comprobación-y-aceptación atómicas; si HEAD/árbol se movió durante el triage → abort).
    _accept_merge() {
      set +e
      [ "$(git rev-parse HEAD 2>/dev/null)" = "$HEAD_SHA" ] \
        || { echo "cr-review: HEAD se movió durante el triage — nada registrado. Re-corre." >&2; return 1; }
      [ "$(git rev-parse 'HEAD^{tree}' 2>/dev/null)" = "$TREE_SHA" ] \
        || { echo "cr-review: el árbol cambió durante el triage — nada registrado. Re-corre." >&2; return 1; }
      local dtmp
      dtmp="$(mktemp .claude/.cr-review-known-debt.XXXXXX 2>/dev/null)" || return 1
      { [ -f "$KNOWN_DEBT" ] && cat "$KNOWN_DEBT"; printf '%s' "$new_entries"; } \
        | jq -c -s 'group_by(.tree_sha + "|" + .base_sha + "|" + .fp) | map(last) | .[]' > "$dtmp" 2>/dev/null \
        || { rm -f "$dtmp"; echo "cr-review: fallo fusionando el store de known debt. Nada registrado." >&2; return 1; }
      mv -f "$dtmp" "$KNOWN_DEBT" || { rm -f "$dtmp"; return 1; }
    }
    mkdir -p .claude
    with_ledger_lock _accept_merge || exit 1
    echo "cr-review: known debt registrada para el árbol ${TREE_SHA:0:12} (base ${rbase:0:12}):"
    printf '%s' "$new_entries" | jq -r '"  [\(.severity // "?")] \(.file // "?"):\((.lineStart // "?")|tostring) — \(.title // "(sin título)") (fp \(.fp[0:8])…) — nota: \(.note)"'
    echo "Re-corre 'bash scripts/cr-review.sh': los findings aceptados ya no bloquearán MIENTRAS árbol y base no cambien."
    exit 0
    ;;
  *)
    echo "cr-review: argumento desconocido '${1}'. Modos: (sin args) run normal · --list-findings · --accept-debt <n>[,<n>...] \"<nota>\"." >&2
    exit 1
    ;;
esac

# Reconciliación de arranque (M-01 ronda 4, flock ronda 6): housekeeping best-effort, NUNCA bloquea el
# run normal (a diferencia de `start_run`, cuyo fallo SÍ es fail-closed — aquí no hay verdict que
# autorizar). Corre ANTES de que este run cree su propio `$RUN_LOCK`/crudo, así que jamás se toca a sí
# mismo.
reconcile_orphaned_raws || true

# Arranque transaccional: invalida el sentinel PRIMERO + asigna generación + RESULT=running.
# Si falla, fail-closed (el sentinel ya quedó ausente): sin gen fiable no hay serialización.
start_run || { echo "cr-review: start_run falló (fail-closed): no se pudo inicializar el run." >&2; exit 1; }
# Traps instalados TRAS start_run (fuera del case de modos). El trap respeta COMMITTED (R5-B3).
trap 'on_exit' EXIT
trap 'on_signal' INT TERM

# 1) origin/main fresco (el review se hace contra la base real del PR, no stale).
git fetch origin main --quiet 2>/dev/null || defer_or_block no-network
BASE_SHA="$(git rev-parse origin/main 2>/dev/null || echo '')"

# 2) auth del CLI (NO lee la key del entorno; usa $HOME/.coderabbit/auth.json — ver TAL-1512). El
# ASIENTO lo selecciona quien invoca, vía HOME (1 key por asiento); el script no lo elige ni lo escribe.
# SIN auth.json el CLI intenta login interactivo y se CUELGA → chequear el archivo primero (rápido,
# evita el cuelgue) ANTES de tocar nada más.
[ -f "$HOME/.coderabbit/auth.json" ] || defer_or_block no-cli-auth
# TAL-3562 (ronda 4 de auditoría): un sondeo del auth.json COMPARTIDO (rondas 2/3) es, a lo sumo,
# PROBABILÍSTICO — una rotación A->B->A más rápida que el intervalo de muestreo sigue sin detectarse,
# así que `seat_fp` nunca queda DETERMINÍSTICAMENTE ligado a la credencial que `coderabbit review`
# lee de verdad. La única relación determinista posible es que ambos —la huella y la lectura del
# CLI— sean, literalmente, EL MISMO fichero, no dos lecturas separadas de un original mutable ajeno.
# Snapshot INMUTABLE: se congela `.coderabbit/` en un directorio privado de este run (nace vacío,
# nadie más conoce su ruta, muere con el run) ANTES de la primera lectura que cuenta para la
# atribución; el resto del HOME real se enlaza tal cual (`.ssh`, `.gitconfig`, etc. — el CLI puede
# necesitarlos y no son el recurso en disputa). `auth status`, el cálculo de SEAT_FP y `review` se
# invocan los TRES contra `HOME=$SNAP_HOME` — ninguna escritura concurrente al HOME real (otra torre
# rotando su asiento, incluida una secuencia A->B->A) puede alcanzar esta copia tras tomada: la
# relación dejó de ser una ventana que sondear para ser estructuralmente imposible de romper.
SNAP_HOME="$(mktemp -d)" || defer_or_block no-cli-auth
chmod 700 "$SNAP_HOME" 2>/dev/null || true
( shopt -s dotglob nullglob
  for entry in "$HOME"/*; do
    base="$(basename "$entry")"
    [ "$base" = ".coderabbit" ] && continue
    ln -s "$entry" "$SNAP_HOME/$base" 2>/dev/null
  done
) 2>/dev/null || true

# TAL-3562 (ronda 5 de auditoría): `cp -a` PRESERVA symlinks — si `auth.json` (o `.coderabbit/` en
# sí) es un enlace hacia una ubicación compartida (p.ej. un almacén de credenciales entre torres),
# el guard `-f` de arriba lo sigue y lo acepta, pero una copia sin dereferenciar recrearía el MISMO
# enlace dentro del snapshot: ambas invocaciones seguirían leyendo el original mutable, reabriendo
# exactamente el TOCTOU que el snapshot existe para cerrar. `-L` (dereference) fuerza a MATERIALIZAR
# el contenido apuntado como fichero regular en destino, para CUALQUIER symlink dentro del árbol.
if ! cp -aL "$HOME/.coderabbit" "$SNAP_HOME/.coderabbit" 2>/dev/null; then
  rm -rf "$SNAP_HOME" 2>/dev/null || true; SNAP_HOME=""
  defer_or_block no-cli-auth
fi
# Verificación explícita (no confiar ciegamente en que `-L` hizo su trabajo): si el resultado NO es
# un fichero regular —symlink colgante que `-L` no pudo resolver, o cualquier otra cosa— fail-closed.
if [ -L "$SNAP_HOME/.coderabbit/auth.json" ] || [ ! -f "$SNAP_HOME/.coderabbit/auth.json" ]; then
  rm -rf "$SNAP_HOME" 2>/dev/null || true; SNAP_HOME=""
  defer_or_block no-cli-auth
fi
# El EXIT CODE de `auth status` NO sirve de guard: sale rc=0 tanto autenticado como `signed out`
# (TAL-3562, medido en 0.6.5) y el texto humano lleva padding variable → se consume el contrato
# machine-readable `--agent` (NDJSON) exigiendo el POSITIVO `authenticated:true`. Fail-closed: sesión
# cerrada, flag ausente, salida ilegible o jq roto → defer (jamás gasta el bucket de otro asiento).
HOME="$SNAP_HOME" coderabbit auth status --agent 2>/dev/null \
  | jq -e -s 'any(.[]?; type == "object" and .phase == "auth" and .authenticated == true)' >/dev/null 2>&1 \
  || { rm -rf "$SNAP_HOME" 2>/dev/null || true; SNAP_HOME=""; defer_or_block no-cli-auth; }
# Huella del ASIENTO en uso: sha256 TRUNCADA del snapshot congelado, jamás su contenido (regla 18).
# Deja en el log y en el `result` QUÉ identidad gastó la corrida — hoy irreconstruible tras colisión.
SEAT_FP="$(sha256_hex < "$SNAP_HOME/.coderabbit/auth.json" 2>/dev/null || true)"; SEAT_FP="${SEAT_FP:0:12}"
echo "cr-review: asiento CR en uso (snapshot inmutable) — HOME=$HOME huella=${SEAT_FP:-desconocida}"

# 3) review de lo que va al PR (--type committed evita el ruido de untracked/uncommitted).
# Crudo escrito a un `.partial` (per-run, gitignored, evidencia — TAL-2816): NUNCA escritura directa
# al nombre final. Solo se PROMUEVE a $RAW con rename atómico si el review completa limpio (M1/
# R11-B1) — error/rate-limit/incompleto salen ANTES de promover, conservando el `.partial` como
# evidencia sin publicar nunca un "final" a medio escribir.
# B-01 ronda 2 (TOCTOU): `HEAD_SHA` (línea ~88) es una lectura VIEJA — si HEAD ya se movió antes de
# llegar aquí, revisar "lo que hay ahora" y luego emitir el sentinel para `HEAD_SHA` autorizaría un
# commit que NUNCA se revisó (el hook solo compara el SHA del sentinel contra el HEAD del momento del
# push; si HEAD volvió a coincidir por casualidad, cuela). Por eso `REVIEW_HEAD` es una lectura FRESCA
# (no una copia de `$HEAD_SHA`) validada contra `HEAD_SHA` ANTES de gastar la corrida del CLI en el
# commit equivocado. El snapshot con reflog (R5-B2) cierra la otra mitad de la ventana (revisión→commit);
# esta validación cierra la mitad previa (arranque→revisión).
REVIEW_HEAD="$(git rev-parse HEAD 2>/dev/null || true)"
if [ -z "$REVIEW_HEAD" ] || [ "$REVIEW_HEAD" != "$HEAD_SHA" ]; then
  echo "cr-review: HEAD cambió antes de iniciar la revisión (arrancó en ${HEAD_SHA:0:12}, ahora es ${REVIEW_HEAD:0:12}) — no se revisa un commit distinto del que autorizaría el sentinel. Re-corre." >&2
  commit_run 1 error "head-moved-before-review"
fi
REVIEW_TREE="$(git rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
# REVIEW_BASE es un campo RESERVADO del snapshot: se captura pero hoy no lo consume ningún gate (la
# base la revalida `snapshot_fp` vía el reflog de origin/main). Se conserva por simetría con
# REVIEW_HEAD/REVIEW_TREE y porque el arnés lo fija en sus escenarios; eliminarlo sería un cambio de
# contrato del snapshot, no una limpieza. De ahí el disable — que va en su PROPIA línea, pegado a la
# asignación que anota: ni un comentario intermedio ni un `;` con otra asignación delante lo aplican.
# shellcheck disable=SC2034
REVIEW_BASE="$BASE_SHA"
REVIEW_FP="$(snapshot_fp 2>/dev/null || true)"
# M-01/M-03 ronda 6: adquiere y SOSTIENE el lock por-run ANTES de crear el `.partial` (invariante:
# si existe un crudo, su flock ya está tomado — no hay ventana donde un crudo quede sin protección de
# vivacidad). Contenido `{branch,pid}` PRIMERO (pid informativo; la vivacidad la prueba el flock, no el
# PID), luego se abre el FD 8 en APPEND (`>>`, NO trunca el contenido recién escrito) y se toma el
# flock. FAIL-CLOSED: si no se puede establecer el lock (proof de vivacidad), NO se crea un crudo
# desprotegido — se aborta el review, en vez de dejar un `.partial` que un reconciliador daría por
# muerto mientras seguimos vivos. El FD 8 se sostiene hasta el `exit` de `commit_run` (o hasta que el
# kernel lo libere al morir el proceso, SIGKILL incluido).
jq -c -n --arg br "$BRANCH" --argjson pid "$$" '{branch:$br, pid:$pid}' > "$RUN_LOCK" 2>/dev/null || true
chmod 600 "$RUN_LOCK" 2>/dev/null || true
# H-6 (spike TAL-3568): el `2>/dev/null` NO puede ir pegado al `exec` — un `exec` sin comando aplica
# sus redirecciones al SHELL, así que `exec 8>>… 2>/dev/null` dejaba FD 2 apuntando a /dev/null para
# el RESTO del proceso y silenciaba todo diagnóstico posterior (incluidos los abort de
# `stale-repo-state` y `superseded`, que son la única observabilidad de H-1/H-2). El grupo `{ …; }`
# acota la redirección de FD 2 a la propia llamada; FD 8 lo sigue fijando el `exec` en el shell.
if ! { exec 8>>"$RUN_LOCK"; } 2>/dev/null || ! flock -n 8 2>/dev/null; then
  echo "cr-review: no pude establecer el lock por-run de vivacidad ($RUN_LOCK) — fail-closed: no se crea un crudo desprotegido. Re-corre." >&2
  commit_run 1 error "runlock-acquire-failed"
fi
: > "$RAW_PARTIAL"; chmod 600 "$RAW_PARTIAL" 2>/dev/null || true
# El review lee del snapshot INMUTABLE, no del HOME real: idéntico asiento que auth status/SEAT_FP,
# sin ventana de rotación que sondear (ronda 4 — reemplaza el sondeo probabilístico de la ronda 3).
HOME="$SNAP_HOME" coderabbit review --agent --base origin/main --type committed >> "$RAW_PARTIAL" 2>/dev/null || true
# El snapshot ya cumplió su propósito (auth status + SEAT_FP + review leyeron los tres de él) — se
# destruye de inmediato, no hace falta sobrevivir más allá de esta invocación.
rm -rf "$SNAP_HOME" 2>/dev/null || true; SNAP_HOME=""

ratelimit="$(jq -rs '[.[]|select(.type=="error")|select((.message//"")|test("rate limit";"i"))]|length' "$RAW_PARTIAL" 2>/dev/null || echo 0)"
errcount="$(jq -rs '[.[]|select(.type=="error")]|length' "$RAW_PARTIAL" 2>/dev/null || echo 1)"
completed="$(jq -rs '[.[]|select(.type=="complete" and (.status=="review_completed"))]|length' "$RAW_PARTIAL" 2>/dev/null || echo 0)"
skipped="$(jq -rs '[.[]|select(.type=="complete" and (.status=="review_skipped"))]|length' "$RAW_PARTIAL" 2>/dev/null || echo 0)"
blockers="$(jq -rs '[.[]|select(.type=="finding")|select(((.severity//.level//"")|ascii_downcase)|test("critical|major"))]|length' "$RAW_PARTIAL" 2>/dev/null || echo 1)"

# Rate-limit específico → deferred (degrada al App). Cualquier OTRO error → fail-closed. Ninguno de
# los dos promueve: el `.partial` queda como evidencia, sin `$RAW` final.
[ "${ratelimit:-0}" -ge 1 ] 2>/dev/null && defer_or_block cli-rate-limit
if [ "${errcount:-1}" -ne 0 ] || [ "${skipped:-0}" -ne 0 ] || [ "${completed:-0}" -lt 1 ]; then
  echo "cr-review: el review NO completó limpio (errors=$errcount skipped=$skipped completed=$completed). Fail-closed: no se emite sentinel. Re-intenta." >&2
  commit_run 1 error "review-incomplete(errors=${errcount} skipped=${skipped} completed=${completed})"
fi
# Review completó limpio → PROMOCIÓN GATEADA (M1/R11-B1): rename atómico del `.partial` al nombre
# final. `$RAW` (final) existe SOLO si hubo review completo; todo lo de abajo (CAND, historial) lee
# ya el nombre final. El `$RUN_LOCK` se SIGUE sosteniendo hasta `commit_run` — así, un SIGKILL/OOM en
# la ventana promoción→commit_run (M-02) deja un RAW final que el reconciliador cubre igual (escanea
# `.jsonl` finales) y cuya muerte prueba por flock; `commit_run` lo libera/borra tras escribir historia.
mv -f "$RAW_PARTIAL" "$RAW" 2>/dev/null || commit_run 1 error "raw-promote-failed"
# Findings bloqueantes → partición known debt (TAL-2272) → si quedan NUEVOS, no sentinel
# (arreglar/aceptar y re-correr). Redacción estricta en el result: solo severity+file.
if [ "${blockers:-1}" -ne 0 ]; then
  # Candidatos NORMALIZADOS por el filtro COMPARTIDO `cr-finding-normalize.jq` (TAL-2610) — mismo
  # shape que consumen --accept-debt y el historial (huella fp idéntica en todos). El filtro SOLO
  # emite findings TRIAGEABLES (con cuerpo textual real) y soporta los schemas 0.6.4 y 0.6.5. Sin
  # `|| true` silencioso: se captura el rc de jq para el chequeo de PARIDAD.
  if CAND="$(jq -c -f "$NORMALIZE_JQ" "$RAW" 2>/dev/null)"; then cand_rc=0; else cand_rc=$?; fi
  # PARIDAD fail-closed (TAL-2610): normalized DEBE igualar el conteo crudo de bloqueantes. Como el
  # filtro solo emite triageables, la paridad garantiza que TODOS los bloqueantes salieron con texto
  # real; un textless-phantom, un fallo parcial de jq o un schema no reconocido deja normalized <
  # blockers → aborta el gate ANTES de tocar known debt (cero falso GO, cero finding intriageable; el
  # crudo queda en $RAW para triage). Integrado con TAL-2816: el abort va por commit_run (historial +
  # fencing + limpieza del runlock), no por un `exit` directo.
  normalized="$(printf '%s' "$CAND" | grep -c '[^[:space:]]' || true)"
  if [ "$cand_rc" -ne 0 ] || [ "${normalized:-0}" -ne "${blockers}" ]; then
    echo "cr-review: el CLI reportó ${blockers} bloqueante(s) pero solo normalicé ${normalized:-0} triageable(s) (jq rc=${cand_rc}). Schema cambió o hay findings sin texto. Fail-closed: no se emite sentinel. Crudo en ${RAW} para triage." >&2
    commit_run 1 error "findings-parse-mismatch(blockers=${blockers} normalized=${normalized:-0} rc=${cand_rc})"
  fi
  # M-02: reutiliza el universo YA normalizado+validado por PARIDAD (CAND) para el historial — el mismo
  # conjunto que se particiona abajo (new + known). `_history_universe` lo consume sin re-normalizar $RAW.
  RUN_UNIVERSE_LINES="$CAND"
  # Deuda vigente: triple binding (tree actual + base actual + fp). Sin sha256 → sin supresión.
  debt_fps=""
  if [ -s "$KNOWN_DEBT" ] && have_sha256; then
    TREE_SHA="$(git rev-parse 'HEAD^{tree}')"
    debt_fps="$(jq -r --arg t "$TREE_SHA" --arg b "$BASE_SHA" 'select(.tree_sha==$t and .base_sha==$b) | .fp // empty' "$KNOWN_DEBT" 2>/dev/null || true)"
  fi
  new_lines=""; known_lines=""; new_count=0; known_count=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    fp=""
    if [ -n "$debt_fps" ]; then fp="$(fp_of "$line" 2>/dev/null || true)"; fi
    if [ -n "$fp" ] && printf '%s\n' "$debt_fps" | grep -qx "$fp"; then
      known_lines+="$line"$'\n'; known_count=$((known_count+1))
    else
      new_lines+="$line"$'\n'; new_count=$((new_count+1))
    fi
  done <<< "$CAND"
  kd="$(printf '%s' "$known_lines" | jq -c -s 'map({severity, file})' 2>/dev/null || echo '[]')"
  if [ "$new_count" -gt 0 ]; then
    bf="$(printf '%s' "$new_lines" | jq -c -s 'map({severity, file})' 2>/dev/null || echo '[]')"
    if [ "$known_count" -gt 0 ]; then
      echo "cr-review: CR-CLI encontró ${new_count} finding(s) critical|major NUEVOS (${known_count} suprimido(s) como known debt). Arréglalos (o acéptalos con --accept-debt), commitea y re-corre. No se emite sentinel:" >&2
    else
      echo "cr-review: CR-CLI encontró ${new_count} finding(s) critical|major. Arréglalos, commitea y re-corre. No se emite sentinel:" >&2
    fi
    printf '%s' "$bf" | jq -r '.[]|"  [\(.severity)] \(.file)"' 2>/dev/null >&2 || true
    RUN_BLOCKING="$bf"; RUN_KNOWN="$kd"; RUN_FINDINGS_LINES="$new_lines"
    commit_run 1 findings "critical-major"
  fi
  # Solo known debt → limpio módulo deuda aceptada: sentinel ok con razón distintiva (state=ok, R3-B3).
  echo "✓ cr-review: CR-CLI limpio módulo known debt (${known_count} finding(s) aceptados suprimidos) para ${HEAD_SHA:0:12}. Sentinel ok emitido; push permitido. Suprimidos:"
  printf '%s' "$kd" | jq -r '.[]|"  [\(.severity)] \(.file)"' 2>/dev/null || true
  RUN_BLOCKING="[]"; RUN_KNOWN="$kd"
  commit_run 0 ok "review_completed_known_debt(${known_count})"
fi

# Limpio → sentinel ok.
echo "✓ cr-review: CR-CLI limpio (review_completed, 0 critical|major) para ${HEAD_SHA:0:12}. Sentinel ok emitido; push permitido."
RUN_BLOCKING="[]"; RUN_KNOWN="[]"
commit_run 0 ok review_completed
