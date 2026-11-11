# El gate CLI del repo (`scripts/cr-review.sh` + `.githooks/pre-push`)

> `last_verified: 2026-09-22`

Este repo exige el CLI de CodeRabbit como **gate obligatorio pre-push** (ABC-1518). Esta referencia
documenta el contrato real del gate — leído directamente de `scripts/cr-review.sh` (950 líneas) y
`.githooks/pre-push` (464 líneas) al 2026-09-22, citando por **nombre de función/variable** (verificado
con `grep -n` hoy) en vez de número de línea siempre que existe un ancla — sin modificar ninguno de los
dos scripts. Ambos scripts crecieron mucho desde la v3 original (ABC-5477 resolvió el riesgo de `--type`;
ABC-5574 añadió el consumo de `.claude/.audit-go` dentro de este mismo hook) — cualquier cita por número
de línea de una versión anterior de este fichero está DESFASADA y no se reutiliza sin re-verificar.

## Tabla de contenidos

1. [Panorama: qué hace el hook y qué hace el script](#1-panorama-qué-hace-el-hook-y-qué-hace-el-script)
2. [Contrato de artefactos `.claude/.cr-review-*`](#2-contrato-de-artefactos-claudecr-review-)
3. [Los sentinels y el binding OID+rama](#3-los-sentinels-y-el-binding-oidrama)
4. [`seat_fp`: huella del asiento en uso](#4-seat_fp-huella-del-asiento-en-uso)
5. [Invocación real del CLI — ABC-5477 (`--type`) YA RESUELTO](#5-invocación-real-del-cli--abc-5477---type-ya-resuelto)
6. [Known debt (ABC-2272): aceptar findings por huella](#6-known-debt-abc-2272-aceptar-findings-por-huella)
7. [Ledger append-only y fencing por generación](#7-ledger-append-only-y-fencing-por-generación)
8. [Paridad fail-closed](#8-paridad-fail-closed)
9. [Concurrencia: `flock` por host y reconciliación de huérfanos](#9-concurrencia-flock-por-host-y-reconciliación-de-huérfanos)
10. [Modos de solo lectura: `--list-findings` y `--accept-debt`](#10-modos-de-solo-lectura---list-findings-y---accept-debt)
11. [Doctrina de la estación (puntero, no duplicado)](#11-doctrina-de-la-estación-puntero-no-duplicado)
12. [Gotchas y referencias cruzadas](#12-gotchas-y-referencias-cruzadas)

## 1. Panorama: qué hace el hook y qué hace el script

**El hook NO corre el CLI.** `.githooks/pre-push` solo **valida sentinels pre-existentes** para el OID
que Git realmente empuja (leído de stdin, no de `HEAD`) — quien corre el CLI y produce el sentinel de
Ruta B es `scripts/cr-review.sh`; el de Ruta A lo produce `scripts/draft-handoff.sh` (sin CodeRabbit).
Desde ABC-5574 (fundida 2026-09-09) el mismo hook además lee `.claude/.audit-go` (Gate 1, el GO humano
de reglas 9+12 — lo crea `scripts/audit-go.sh`), aunque solo lo exige para la Ruta B.

```text
  git push
     │
     ▼
  .githooks/pre-push  ──valida SENTINELS para el OID de cada ref empujada (stdin)──┐
     │                                                                              │
     ├─ refs/heads/main? ── sí ─▶ RECHAZO incondicional (bloque `case "$remote_ref" in refs/heads/main)`,
     │                             verificado hoy en la línea 344; regla 10)
     ├─ draft_valid_for(oid, ref)? ── sí ─▶ push OK (Ruta A: CR lo corre el Mergeador; .audit-go NO se
     │                                              evalúa en esta rama del if/elif)
     ├─ sentinel_valid_for(oid)? ── no ─▶ push BLOQUEADO (diagnóstico A+B)
     │        └─ sí (Ruta B) ─┬─ audit_corrupt? ────────────────────── sí ─▶ push BLOQUEADO (Gate 1)
     │                        ├─ audit_disputed_for(oid, ref)? ─────── sí ─▶ push BLOQUEADO (Gate 1)
     │                        └─ si no ─▶ push OK (audit_valid_for(oid,ref)? marca audit_used=1)
     └─ (ninguna ref matcheó) ─▶ push BLOQUEADO (salida consciente: --no-verify)

  Productores del sentinel (el hook NUNCA los invoca):
    Ruta A  →  scripts/draft-handoff.sh      → .claude/.draft-handoff  (OID + rama, ABC-2288)
    Ruta B  →  scripts/cr-review.sh          → .claude/.cr-review-ok   (OID + estado ok|deferred)
    Gate 1  →  scripts/audit-go.sh (OK lead) → .claude/.audit-go       (SHA + rama, ABC-5574)
```

`draft_valid_for`, `sentinel_valid_for`, `audit_valid_for`, `audit_disputed_for` son los nombres REALES
de las funciones del hook (`grep -n '^audit_valid_for\|^audit_disputed_for\|^sentinel_valid_for\|^draft_valid_for' .githooks/pre-push`,
verificado 2026-09-22 — líneas 232/245/264/312 en el head actual, pero cítalas por nombre, no por línea).
Fuente: `.githooks/pre-push` completo (464 líneas), releído 2026-09-22.

## 2. Contrato de artefactos `.claude/.cr-review-*`

Todos gitignored, locales, nacen `0600`/`0700` (`umask 077`, ancla verificada `grep -n 'umask 077'
scripts/cr-review.sh` → línea 113 hoy, 2026-09-22):

| Artefacto | Contenido | Ancla (variable en `cr-review.sh`) |
|---|---|---|
| `.claude/.cr-review-ok` | Sentinel: línea 1 SHA, línea 3 estado (`ok`/`deferred`), línea 5 timestamp | `SENTINEL`; consumido por `sentinel_valid_for()` en `.githooks/pre-push` |
| `.claude/.cr-review-result.json` | Snapshot runtime, escrito ATÓMICAMENTE en todos los caminos de salida. Estados: `running\|ok\|findings\|deferred\|blocked\|error`. Campos: `state, reason, head_sha, base_sha, gen{epoch,value}, run_id, blocking_findings` (redactado: solo severity+file), `known_debt` (redactado), `seat_fp` | `RESULT` |
| `.claude/.cr-review-findings.jsonl` (ABC-2245) | Findings accionables, solo en `state=findings`: un JSON por línea (`severity+file+line+title+description+prompt`) — permite al Mergeador leer/rutar un finding **sin re-correr el CLI** | `FINDINGS` |
| `.claude/.cr-review-known-debt.jsonl` (ABC-2272) | Deuda aceptada, durable multi-run, binding `{tree_sha,base_sha,head_sha}` + huella `fp` + nota obligatoria | `KNOWN_DEBT` |
| `.claude/.cr-review-history.jsonl` (ABC-2816) | Ledger APPEND-ONLY por run/SHA — **todo run entra**, incluidos error/deferred/blocked/orphaned; retención por rama (`CR_REVIEW_HISTORY_RETENTION`, default 20) | `HISTORY` |
| `.claude/.cr-review-raw-<run_id>.jsonl` (final) / `.jsonl.partial` (en curso) | Crudo del CLI preservado como evidencia; a lo sumo uno de los dos existe por run | `RAW` / `RAW_PARTIAL` |
| `.claude/.cr-review-runlock-<run_id>` | `flock` sostenido por el proceso dueño toda su vida; contiene `{branch,pid}` | `RUN_LOCK` |
| `.claude/.cr-review-ledger.lock` | Lock que serializa TODA mutación de estado por-SHA | `LEDGER_LOCK` |
| `.claude/.cr-review-gen` | Generación no-reutilizable `{epoch, value}` — el fencing token de ownership real | `GEN_FILE` |

Todas las variables anteriores se declaran juntas cerca del arranque del script (`grep -n
'^SENTINEL=\|^RESULT=\|^FINDINGS=\|^KNOWN_DEBT=\|^HISTORY=\|^LEDGER_LOCK=\|^GEN_FILE=\|^RUN_LOCK='
scripts/cr-review.sh`, verificado 2026-09-22) — citarlas por nombre sobrevive a que el script se
reordene entre auditorías; un número de línea no.

## 3. Los sentinels y el binding OID+rama

El sentinel de la Ruta B (`.cr-review-ok`) solo ata **OID** (función `sentinel_valid_for()`): compara
línea 1 contra el OID empujado y valida el estado (`ok` sin TTL; `deferred` con TTL de 2h vía la
constante `TTL_DEFERRED=7200`, declarada junto a `SENTINEL`/`DRAFT_SENTINEL` cerca del arranque del
hook).

El sentinel de la Ruta A (**draft**) y el de **Gate 1** (`.audit-go`, ABC-5574) atan **OID + RAMA de
destino**, no solo OID (ABC-2288 originó el patrón para draft; cierra la clase «sentinel válido solo por
OID»): la función `draft_valid_for()` exige que la línea 2 del sentinel (la rama que `draft-handoff.sh`
escribió en su origen) coincida con la ref real de destino del push (`refs/heads/$draft_branch" !=
"$2"`); `audit_valid_for()`/`audit_disputed_for()` hacen la comparación equivalente contra `.audit-go`
(línea 1 SHA, línea 2 rama). Si el sentinel existe y el OID coincide pero la rama no, el push **sigue
bloqueado** — no es un bug del hook, es el diseño (para `.audit-go` esto es una DISPUTA explícita, con
mensaje propio, no un simple "sentinel inválido").

`refs/heads/main` se rechaza **incondicionalmente**, antes de evaluar cualquier sentinel (bloque `case
"$remote_ref" in refs/heads/main) fail …`, dentro del `while read` principal) — ningún sentinel
(draft/CR/audit-go) autoriza push ni delete de `main`.

El sentinel draft se consume **one-shot**, solo después de validar TODAS las refs del push (bloque `if [
"$draft_used" -eq 1 ]` tras el `while`) — un fallo parcial no lo quema. Desde ABC-5574, `.audit-go`
sigue el MISMO patrón one-shot post-validación-completa (bloque `if [ "$audit_used" -eq 1 ]`), pero con
un fencing adicional: antes de borrarlo, el hook re-hashea el fichero completo (sha256) y compara contra
el hash capturado al decidir — si algo lo tocó fuera del `flock` entre la decisión y el consumo, el hook
DENIEGA en vez de borrar un GO que ya no es el que validó (defensa en profundidad; el candado del punto
1 ya debería hacer esto inalcanzable en producción).

## 4. `seat_fp`: huella del asiento en uso

`SEAT_FP` (ABC-3562) es un sha256 **truncado a 12 caracteres** calculado sobre un **snapshot inmutable**
de `~/.coderabbit/`, jamás sobre la credencial en sí (regla 18, sin secrets):

```text
  arranque del run                          (pasos localizados por su nombre en scripts/cr-review.sh)
     │
     ├─ SNAP_HOME=$(mktemp -d "${TMPDIR:-/tmp}/cr-snap-home.XXXXXX"); chmod 700
     ├─ symlink de los DOTFILES del HOME real (`.[!.]*` y `..?*`, con `nullglob`) salvo .coderabbit;
     │  las entradas sin punto NO se enlazan                (bucle `ln -s`)
     ├─ cp -aL ~/.coderabbit → SNAP_HOME/.coderabbit        (dereferencia symlinks)
     ├─ verificación: auth.json debe ser fichero regular, no symlink colgante
     ├─ auth status --agent  CONTRA HOME=$SNAP_HOME
     ├─ SEAT_FP = sha256(SNAP_HOME/.coderabbit/auth.json)[0:12]
     └─ review --agent  CONTRA EL MISMO HOME=$SNAP_HOME
              (auth status, SEAT_FP y review leen los TRES del mismo snapshot — sin ventana
               de rotación de credencial entre la huella y la corrida real)
```

Por qué el snapshot (y no un sondeo directo del `auth.json` real): un sondeo del fichero compartido es,
a lo sumo, probabilístico — una rotación de credencial más rápida que el intervalo de muestreo no se
detecta. La única relación determinista posible es que la huella y la lectura del CLI sean,
literalmente, el mismo fichero — de ahí el snapshot congelado ANTES de la primera lectura que cuenta
para la atribución. Fuente: bloque `SNAP_HOME=""` … `review --agent` de `scripts/cr-review.sh`, releído
completo 2026-09-22 (variable `SNAP_HOME`, declarada junto a `SEAT_FP=""` cerca del arranque).

`SEAT_FP` queda persistido en `.cr-review-result.json` y en cada entrada del ledger
(`.cr-review-history.jsonl`) — permite reconstruir después qué identidad gastó una corrida concreta, útil
en máquinas con múltiples asientos rotando.

## 5. Invocación real del CLI — ABC-5477 (`--type`) YA RESUELTO

```bash
# scripts/cr-review.sh, invocación real (verificado 2026-09-22, línea 865 en el head actual)
HOME="$SNAP_HOME" coderabbit review --agent --base origin/main "${SCOPE_FLAG_ARGS[@]}" >> "$RAW_PARTIAL" 2>/dev/null || true
```

`SCOPE_FLAG_ARGS` NO es literal `--type committed` — se resuelve en vivo por `cr_scope_flag()` /
`cr_scope_flag_for_version()` (funciones definidas cerca de la línea 166 hoy; cítalas por nombre): leen
`coderabbit --version` y devuelven `--committed` si el binario es ≥0.7.0, o `--type committed` si es
<0.7.0 — **fail-closed** (`state=error`, sin sentinel) si la versión no parsea como `N.N.N`.

**Historia del riesgo (contexto, ya no aplica)**: la CLI retiró `--type` en la versión **0.7.0**
(2026-07-22); en versiones ≥0.7.0, `coderabbit review` **ignora la flag en silencio** en vez de fallar —
el review amplía su alcance a *todos* los cambios trackeados. Verificado en vivo por última vez
2026-09-22 contra el binario 0.8.0: `coderabbit review --help` sigue sin listar `--type`; `coderabbit
config validate` sigue fallando con `unknown option '--type'` si se le pasa (asimetría sin cambios desde
0.7.6).

**RESUELTO en este repo — ABC-5477, PR #2290, fundida 2026-09-07**: `cr_scope_flag()` reemplazó el
`--type committed` hardcodeado por la resolución dinámica de arriba. El golden de canales
(`talent-channels/scripts/02-golden.sh`, variable `CR_CLI_VERSION`) sigue pineando la CLI en **0.6.5**
(verificado hoy) — subir ese pin ya NO está bloqueado por este riesgo (es ABC-5480, Todo, por otras
razones de la subida en sí). `docs/runbooks/coderabbit-cli-pre-pr.md` (fuera de este skill) documenta el
mismo fix con su propia cita — no se duplica el detalle aquí.

## 6. Known debt (ABC-2272): aceptar findings por huella

Findings que la doctrina de la fábrica decide NO arreglar (flip-flop waiveado, deuda gated) necesitan
registro — sin él, cada re-run los re-reporta y bloquea el sentinel para siempre.

```bash
bash scripts/cr-review.sh --list-findings           # listado numerado del último run
bash scripts/cr-review.sh --accept-debt 1,3 "nota"  # acepta SOLO esos índices (granular)
```

- **Huella `fp`**: función `fp_of()` — `sha256(tojson([file, lineStart, lineEnd, title, category,
  fpMaterial]))`, donde `fpMaterial = [description, comment, codegenInstructions, suggestions, prompt]`
  — captura TODAS las fuentes textuales del finding, no solo la primera que colapsa.
- **Binding triple**: la supresión exige `tree_sha == HEAD^{tree}` actual **Y** `base_sha ==
  origin/main` actual **Y** `fp` idéntica — cualquier commit, rebase o avance de `main` expira la
  deuda (fail-closed, re-triage). Dos findings del mismo archivo/título pero distinta línea tienen
  huellas distintas: aceptar uno nunca suprime el otro.
- **Sin atajo bulk**: la selección es SIEMPRE por índice explícito contra el listado revisable (bloque
  `case` de `--list-findings`/`--accept-debt`, ver §10) — un "aceptar todo" podría colar un finding real
  junto a la deuda.
- **Un finding textless/phantom NO es waiveable por política** — el filtro compartido +
  la paridad (§8) impiden que llegue siquiera a `$FINDINGS`; si el CLI reporta bloqueantes que no
  normalizan a texto real, el gate aborta con `state=error` antes de que haya nada que aceptar.
- **Límite conocido**: si el CLI **reformula el mismo finding con redacción distinta** entre corridas
  (no-determinismo observado: 7 rondas en un caso real), la huella no coincide y la deuda no lo
  captura — el finding se re-reporta. Tratamiento: triage real + waiver explícito del lead, tope de
  corridas — nunca "una corrida más" (ver `references/troubleshooting.md` §10).

## 7. Ledger append-only y fencing por generación

`.claude/.cr-review-history.jsonl` (ABC-2816, variable `HISTORY`) es un ledger **append-only**: todo run
entra, incluidos `error/deferred/blocked/orphaned` y los que nunca llegaron a correr el CLI — el
universo solo se afirma para runs `ok`/`findings` que pasaron la paridad.

Toda mutación de estado por-SHA va bajo `.claude/.cr-review-ledger.lock` (`LEDGER_LOCK`), ordenada por
una **generación no-reutilizable** `{epoch aleatorio, value creciente}` en `.claude/.cr-review-gen`
(`GEN_FILE`) — el fencing token de ownership real: un run más viejo que termine tarde NUNCA pisa el
veredicto de uno más nuevo. La generación se valida ANTES de tocar cualquier artefacto; si no matchea,
el run queda `superseded` con universo vacío. `start_run()` invalida el sentinel PRIMERO y `commit_run()`
lo publica el ÚLTIMO, solo si todo persistió. Sin `flock` (util-linux) el script **falla cerrado** —
ningún fallback hand-rolled se considera seguro (un timeout no es un fencing token).

## 8. Paridad fail-closed

```bash
# scripts/cr-review.sh, bloque de paridad (verificado hoy: líneas 874/891-906 en el head actual —
# cítalo por el nombre de la variable `blockers`/`NORMALIZE_JQ`, no por línea)
blockers="$(jq -rs '[...]|length' "$RAW_PARTIAL" ...)"  # conteo crudo de bloqueantes reportados por el CLI
CAND="$(jq -c -f "$NORMALIZE_JQ" "$RAW")"       # filtro compartido cr-finding-normalize.jq (ABC-2610)
normalized="$(printf '%s' "$CAND" | grep -c '[^[:space:]]')"
[ "$normalized" -eq "$blockers" ] || abortar     # normalized DEBE igualar el conteo crudo de bloqueantes
```

El filtro compartido `scripts/lib/cr-finding-normalize.jq` (soporta schemas 0.6.4 y 0.6.5, ver
`references/cli-review.md` §6) solo emite findings **triageables** (con cuerpo textual real). La
paridad garantiza que TODOS los bloqueantes que reportó el CLI salieron con texto real — un
textless-phantom, un fallo parcial de `jq`, o un schema no reconocido deja `normalized < blockers` y
**aborta el gate con `state=error`** antes de tocar known-debt: cero falso GO, cero finding
intriageable. El crudo queda en `$RAW` para triage manual.

## 9. Concurrencia: `flock` por host y reconciliación de huérfanos

Cada run **sostiene** un `flock` sobre su `$RUN_LOCK` durante toda su vida, adquirido ANTES de crear
cualquier crudo — invariante: si existe un crudo, su lock ya está tomado. Si el proceso muere (SIGKILL/
OOM), el kernel libera el lock. El reconciliador (`reconcile_orphaned_raws()`) prueba la muerte con
`flock -n` (no-bloqueante) en vez de heurísticas de PID+mtime, vía la función `_owner_is_dead()`: si
adquiere el lock, el dueño murió; si no, sigue vivo. Este barrido corre en cada arranque, ANTES de
`start_run()`, y es best-effort (housekeeping, no la autorización del sentinel).

**Ventana git-quiet**: en máquinas multi-worktree, un `git fetch` de OTRA sesión durante la ventana del
review puede invalidar el snapshot de la corrida en curso (revisión→commit) — pedir una ventana
"git-quiet" (~12 min) antes de correr el gate en entornos multi-agente (gotcha vivido, ABC-4130).

## 10. Modos de solo lectura: `--list-findings` y `--accept-debt`

Ambos modos son **fail-closed sobre un typo**: un primer argumento desconocido aborta con error (mensaje
"argumento desconocido") en vez de quemar una corrida del bucket — bloque `case "$1" in --list-findings)
… --accept-debt) … *) …esac`, verificado hoy con `grep -n -- '--list-findings)\|--accept-debt)'
scripts/cr-review.sh`. No requieren red, CLI ni auth — leen artefactos locales ya persistidos:

```bash
bash scripts/cr-review.sh --list-findings
# Findings del último run (head <sha>):
#   [1] [major] src/lib/foo.ts:42-45 — Missing null check
#   ...
# Known debt: N entrada(s) vigente(s) para este árbol/base (M en el store).

bash scripts/cr-review.sh --accept-debt 1,3 "flip-flop no reproducible, waiver ABC-N"
```

`--list-findings` no gasta cuota del bucket CLI — es la forma barata de leer un finding sin re-correr
el review, algo que un agente que solo lea `SKILL.md`/v2 no sabía que existía (gap H3 del informe 08).

## 11. Doctrina de la estación (puntero, no duplicado)

La mecánica operativa fina de la ESTACIÓN de merge (escalera de doble identidad, protocolo de
desempate flip-flop, PROC-M04/M05/M07/M18/M21, mutex `flock /tmp/cr-host.lock` entre corridas
concurrentes del CLI en el mismo HOME, la receta de escritura atómica de `~/.coderabbit/auth.json`) es
propiedad de `talent-merger` y vive en `talent-merger/references/04-coderabbit-cli-y-app.md` — este
skill apunta a esa referencia, no la duplica. Consultarla antes de operar el gate fuera del contexto
del Mergeador.

## 12. Gotchas y referencias cruzadas

1. **El hook nunca corre el CLI** (§1) — si el push falla, el diagnóstico está en la salida del propio
   hook (bloque `if [ "$blocked" -ne 0 ]` tras el `while`), no en re-ejecutar el push a ciegas.
2. **El sentinel draft y el de Gate 1 (`.audit-go`) atan OID+RAMA; el de CR-CLI solo OID** (§3) — un
   sentinel válido para otra rama no autoriza el push a esta, y un `.audit-go` de otra rama DISPUTA
   (bloquea) un push que de otro modo pasaría por CR-CLI.
3. **`--type` ya NO es un riesgo activo en este repo** (§5, ABC-5477 resuelto 2026-09-07) — no
   reintroduzcas la flag hardcodeada; `cr_scope_flag()` la resuelve por versión.
4. **La huella de known-debt no captura reformulación de texto** (§6) — triage real, no re-correr sin
   fin.
5. **Sin `flock`, el script falla cerrado** (§7, §9) — nunca asumas que hay un fallback silencioso; esto
   aplica tanto al `flock` del ledger de `cr-review.sh` como al de `.claude/.audit-go.lock` en el hook.
6. **`.audit-go` no bloquea la Ruta A (draft)** (§1, §3) — solo la Ruta B lo evalúa; si un push por
   draft se comporta distinto a lo esperado respecto a un GO vigente, no es un bug, es el diseño.

**Referencias relacionadas:**

- Para el binario `coderabbit` en sí (versiones, flags, auth, comandos) → `references/cli-review.md`
- Para diagnosticar un push bloqueado paso a paso → `references/troubleshooting.md`
- Para la doctrina de estación del Mergeador → `talent-merger/references/04-coderabbit-cli-y-app.md`
