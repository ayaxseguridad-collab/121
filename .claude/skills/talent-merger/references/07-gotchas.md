# 07 — Gotchas: índice de diagnóstico

Primer lugar ante un síntoma raro: síntoma → causa → salida. Los PROC-M viven en la ref
indicada; los gotchas numerados del SKILL.md se citan como G-n.

## Table of Contents

- [1. Intake y HANDOFF](#1-intake-y-handoff)
- [2. CodeRabbit](#2-coderabbit)
- [3. Merge y checks](#3-merge-y-checks)
- [4. Migraciones](#4-migraciones)
- [5. Proceso y hooks de push](#5-proceso-y-hooks-de-push)
- [6. Lado de lectura del bus (regla dura 16)](#6-lado-de-lectura-del-bus-regla-dura-16)
- [7. Detectores que se envenenan solos (regla dura 17)](#7-detectores-que-se-envenenan-solos-regla-dura-17)

## 1. Intake y HANDOFF

| Síntoma | Causa probable | Salida |
|---|---|---|
| `verify-handoff.sh` falla con "HANDOFF stale" | El canal (o un refacto propio) pushéo después de emitir el bloque | Re-emitir el bloque con el head vigente (G-6); si vino stale de fábrica → PROC-M01 (ref 02) |
| El draft declara `sensitive: false` pero el diff toca paths sensibles | Clasificación errónea del productor | Entrega inválida → PROC-M01; operar como sensible NUNCA "corrige" una declaración de menos (G-10, ref 03 §4) |
| Destructiva en el diff sin `destructive: true` | El code-audit de la 1ª estación la dejó pasar | PROC-M17 (ref 03 §5): parar + rechazo + aviso al coordinador |
| El HANDOFF no alcanza para operar (invariantes vagos, sin verificación) | Entrega pobre | PROC-M01; la solución NUNCA es preguntar al canal productor (ref 01 §3) |
| PR del mismo `TAL-N` YA mergeado + shortstat con borrado masivo | Rama duplicada brutalmente stale (dos-deliveries) | **PROC-M20** (ref 05 §6): NO rebasar; cerrar superseded; residual → PR fresco vía Orquestador |
| PR de Dependabot en la cola (sin HANDOFF) | No pasa por la 1ª estación | Triage por el DIFF, no el título (ref 02 §1): grupo con security → merge prioritario; major sin security → cerrar-con-nota; `pnpm.overrides` desync → fix 1 línea |
| La estación toma un PR que el flock registra como `BOUNCED` o `CLAIM`ado | No se corrió el pre-claim grep antes del intake | `command grep -E "(CLAIM|BOUNCED) #${pr}([^0-9]|$)" <flock>` ANTES de cualquier acción (límite numérico OBLIGATORIO: `#12` ≠ `#123`; ref 01 §2); un PR `BOUNCED` NO se re-intakea |

## 2. CodeRabbit

| Síntoma | Causa probable | Salida |
|---|---|---|
| App muda tras rebase ("Review skipped" / comment / solo check) | APPROVED anclado al head viejo | PROC-M04 (ref 04): PR nuevo desde la misma rama, body limpio |
| Label puesto pero el App no revisa | `gh pr edit --add-label` falló silencioso (G-2) o el PR sigue draft | Label por REST verificado (ref 04 §5) + orden label→ready (G-1) |
| APPROVED "de hace 20 min" pero el gate falla | Flip APPROVED→CHANGES_REQUESTED (G-4) o head nuevo | Re-verificar el ÚLTIMO review @head exacto; no discutir con el gate |
| "Usage spending cap reached" | Cap de facturación del App | PROC-M05 (taxonomía); persiste ~1 h → lead |
| CLI devuelve findings y "no hay bucket para re-correr" | Confusión findings/rate-limit (G-8) | Findings → refacto (ref 05); el fallback App es SOLO para rate-limit |
| Varios PRs esperando evidencia a la vez | Fair Usage degradando el App | PROC-M18 (ref 04): escalera CLI-A→App-A→cambio de usuario→PROC-M18; cadenciar, no parar la estación |
| CLI da findings en un run y limpio en el siguiente (mismo head) | No-determinismo del CR-CLI (flip-flop) | Protocolo de desempate: re-correr, mayoría ≥2/3 ANTES de refacto; un run aislado = waiver, no defecto (ref 04 §1) |
| No se puede leer el texto del finding sin re-correr el CLI | Rama legacy (predata #830): no persiste `.cr-review-findings.jsonl` | Overlay sin commitear de `cr-review.sh` desde main antes de correr CR (ref 04 §2) |
| El App degradado no da acuse en minutos | Identidad recalentada (Fair Usage por identidad) | Descenso por SEÑAL: sin acuse ~2-3 min → cambio de usuario (escalera, ref 04 §1); no esperar por reloj |
| `cr-review.sh` termina con `exit 124` sin emitir findings | TIMEOUT del CLI (PR >2k LOC): la corrida muere antes de completar | Re-lanzar con `CR_TIMEOUT_SECONDS` mayor (≥1200 s; piso 540 típicos); jamás adjudicar como limpio (ev #1108; ref 04 §2) |
| `.cr-review-result.json` vacío o 0 B en host con dos corridas concurrentes | Mutex violado: una corrida clobbeó `auth.json` de la otra | `flock /tmp/cr-host.lock` antes de escribir `auth.json` y correr; anunciar `# CR-RUN [host:<name>]` en el flock (ev #1170×#1142; ref 04 §2) |

## 3. Merge y checks

| Síntoma | Causa probable | Salida |
|---|---|---|
| `validar-flujo-pr` rojo sin relación con el contenido | Rama con mayúsculas | PROC-M07 (ref 04); NUNCA close/reopen tras el rename |
| Shard e2e rojo | Flake vs real | PROC-M19 (ref 02 §9): head vigente + log real + tabla de decisión. Señal fuerte de flake: el spec rojo es de un ÁREA AJENA al diff del PR (p. ej. foro en un PR de gamificación) |
| Re-run sellado falla con `permission denied` en el push | OTRO actor lanzó una re-run paralela del mismo gate (colisión en `/tmp/lg-$RG` del runner) | La re-run es EXCLUSIVA de la estación; teardown por **PIDs EXACTOS del `run_group` huérfano** (receta canónica ref 08 §2: árbol por `run_group` → PIDs exactos en las DOS capas → confirmar muerte → `docker rm -f` de SU stack efímero — JAMÁS `pkill` por usuario/patrón: mata gates concurrentes) y relanzar UNA sola (ref 08 §5) |
| "Crítico" de CodeRabbit en money-path que huele a falso | Etiqueta ≠ contenido | Leer el CR REAL y verificar en capas (coerción/allowlist) ANTES de bounce; FP verificado → merge con nota; real → bounce-to-pool |
| La estación lleva >15 min en un item meta (issue de proceso, doc) con drafts en cola | Distracción de meta-work | FOCO: drenar la cola de merges primero; el meta-work se difiere a hueco sin cola |
| `mergeStateStatus != CLEAN` con checks verdes | PR BEHIND (main avanzó) o conflicto | Rebase fresco (ref 02 §3) + spot-check gate 3 |
| `mergeStateStatus == UNSTABLE` justo tras `gh pr ready` | Recompute transitorio (~5 s) aunque los 4 required estén verdes | Esperar ~5 s y re-leer; mergear solo sobre CLEAN (ref 02 §7); no `--admin` |
| Gate git "behind origin/main" a mitad del drain | Carrera de `main` (la propia estación drenando) | Transitorio, NO error: reintentar rebase/gate; nunca escalar (ref 06 §1) |
| Puerta PR re-dispara al flip a ready | Rama predata #827 (pr-gate viejo en su head) | Rebasar sobre main ANTES de ready (trae pr-gate corregido); re-emitir HANDOFF completo (ref 02 §3) |
| El merge cerró el PR pero los issues no pasaron a Done | `closes TAL-N` ausente/editado en el body (G-11) | Verificar el body pre-merge (lo cubre `verify-handoff.sh`); post-hoc: cerrar en Linear con comentario + SHA |
| El rebase/gate opera un árbol que no coincide con el PR | Worktree STALE de una ronda anterior (Ev #942) | Verificar `HEAD` del worktree == `headRefOid` antes de operar; divergencia → recrear el worktree limpio (ref 02 §3) |
| Force-push desde worktree dropeó commits del autor (árbol roto publicado) | `git worktree add` resolvió a la rama LOCAL stale en vez del commit-ish de origen (Ev #1162 — distinto de #942) | Secuencia sellada EXPECTED_OID: capturar headRefOid por API → `worktree add` desde `origin/<branch>` o commit-ish exacto, NUNCA rama local → assert HEAD==OID → `push --force-with-lease=<rama>:$OID` (ref 02 §3) |
| Conflictos en `messages/*.json` al rebasar rama behind | Merge "a ojo" de ficheros i18n (Ev F4 #257) | Lado de main + re-aplicar claves propias; validar 0 marcadores + JSON válido + claves intactas (ref 02 §3) |
| Comentario del PR quedó con `@/dev/fd/63` como cuerpo | `gh api -f body=@<(...)` no expande process-substitution | Re-stamp con `-F body=@<fichero>` real (ref 02 §2) |
| `main` avanzó entre el gate y el merge | base_tip mismatch | Excepción ACOTADA (documental/manifiesto) o re-gate — ref 08 §8; intersección de ficheros vacía NUNCA basta sola |
| La estación publica al bus pero no reacciona a lo que otras publican | Tiene lado de ESCRITURA (sellar.sh/latidos) pero ningún lado de LECTURA | Ver §6 — todo actor de fábrica necesita lado de lectura del bus, no solo escritura |
| Un `pgrep`/guard/watcher dispara sobre su propio patrón o sobre prosa ajena que lo cita | El detector busca su patrón dentro de contenido donde ese patrón puede aparecer legítimamente | Ver §7 — guarda de plausibilidad + anclaje estructural, nunca textual |

## 4. Migraciones

| Síntoma | Causa probable | Salida |
|---|---|---|
| Slot declarado ya existe en prod | Ledger avanzó tras la entrega (G-5) | Renumerar contra el ledger real (ref 06 §2 + anexo PROC-M14) |
| Dos drafts de la cola declaran el mismo slot | Colisión intra-cola (G-7) | El gate 4 del AND compara también contra los drafts en preparación |
| Advisor WARN post-apply sobre objeto tocado | Hallazgo real (no telemetría) | Anexo PROC-M15: fix por migración nueva, re-validar que el WARN desaparece |
| Apply falla a mitad del gap | Migración defectuosa | Ref 06 §3: reanudar desde la fallida vía pipeline; slot de merge bloqueado hasta cerrar el gap |
| `db-guards` local rojo tras migración con SECURITY DEFINER | Baseline de advisors desactualizado (fichero compartido) | Anexo §7: receta determinista de keys secdef + re-rebase si otro PR tocó el baseline |
| Renumerar un slot de migración con `gh pr list` sin `--limit`, o con `--limit` pero sin contrastar el total | Default de 30 (o el `--limit` elegido) oculta PRs abiertos con migraciones fuera de rango — «sin colisión» declarado sobre lista TRUNCADA sin saberlo | Enumeración COMPLETA: `--limit` alto + contraste contra un recuento AUTORITATIVO (`gh api graphql` `issueCount`) antes de publicar `SLOT-CLAIM` (ref 01 §2, `CEO-DOCTRINA-MIGRACIONES-5-ESTACIONES`) |
| Dos estaciones arrancan PROC-M13 casi a la vez con slots distintos (M1=100, M2=101, 100 aún no en ledger) | PROC-M13 aplica el gap COMPLETO `main − ledger`, no "mi slot" — M2 también intenta aplicar 100 (ronda 13, BLOQUEANTE) | Adquirir `APPLY-RUN`/`APPLY-DONE`/`APPLY-FAILED` ANTES de invocar PROC-M13: solo una estación lo ejecuta a la vez, fleet-wide (ref 01 §2 punto 4, ref 06 §3 paso 0) |
| Dos `APPLY-RUN` casi simultáneos, cada estación ve el ajeno y ambas esperan | El patrón publicar→releer no elige ganador sin identificador (ronda 14, BLOQUEANTE) | El token lleva el run_id (`#<PR>`+timestamp+`<nonce>`, único por el `<nonce>` — ronda 27, BLOQUEANTE: `#<PR>`+timestamp podían repetirse en el mismo tick) — pero el desempate es "primero tras el último cierre", NUNCA "el más reciente" (ronda 15, BLOQUEANTE: "más reciente gana" dejaba que un publicador tardío se creyera ganador sin revocar al que ya corría) (ref 01 §2 punto 4) |
| Un apply falla a mitad de gap y otra estación arranca PROC-M13 igual, reintentando la migración rota | `APPLY-DONE` genérico no distingue éxito de fallo (ronda 14, BLOQUEANTE) | Cierre por CÓDIGO DE SALIDA de PROC-M13: `exit 0` → `APPLY-DONE` (el anexo §4 garantiza que solo sale `0` tras gap completo + advisors sin `ERROR`); cualquier otro código → `APPLY-FAILED`, sin adivinar la fase (ronda 16, BLOQUEANTE: la clasificación preflight/mid-gap/post-apply de la ronda 15 era irreproducible contra los códigos reales del script y además innecesaria) (ref 01 §2 punto 4) |
| Tratar CUALQUIER `APPLY-FAILED` como si exigiera una migración nueva, dejar que el POST que SÍ muta (Paso 4) se trate como retry seguro, o dejar que un advisor `ERROR` auto-publique DEFECTO sin comprobar el objeto | PROC-M13 sale `≠0` por motivos MUY distintos — token ausente/Vault (BD intacta), un POST cuyo timeout de cliente NO cancela la transacción del servidor (anexo §4, riesgo de doble-apply), una migración PENDIENTE rota que una migración nueva NO desbloquea, y PROC-M13 cuenta TODOS los `ERROR` de advisors sin filtrar por objeto tocado — un `ERROR` ajeno atribuiría el defecto al PR equivocado (ronda 17 BLOQUEANTE; recategorizado ronda 18, 2× BLOQUEANTE; DEFECTO deja de auto-publicarse ronda 19, MAYOR) | Clasificar leyendo `CLASS_FILE` — el literal fijo que PROC-M13 escribe él mismo en el Paso que falló (tabla en ref 01 §2), NUNCA `$LOG` (ronda 20, BLOQUEANTE: un cuerpo HTTP remoto interpolado en el propio log puede forjar un prefijo TRANSITORIO ajeno); `<CATEGORIA>` publicada SIEMPRE es TRANSITORIO o ESCALAR, nunca DEFECTO automático: TRANSITORIO SOLO lecturas de solo-consulta (token/Vault/`fetch_ledger`/advisors) → corregir la causa y publicar un `APPLY-RUN` normal; ESCALAR el POST de Paso 4, Paso 1 (ambos subcasos), divergencia, drift, advisors con `nerr` real, HTTP ambiguo y el default sin `class` explícito → Señal de quiescencia REAL (`pg_locks`, lock adquirido EXPLÍCITAMENTE tras `begin;` ANTES del DDL — ronda 20, BLOQUEANTE — no tiempo del cliente; MÁS una revalidación DENTRO DE LA MISMA TRANSACCIÓN tras el lock y antes del DDL, porque conteo `0` no demuestra que ningún POST esté a punto de pedirlo — ronda 21, BLOQUEANTE) antes de decidir; DEFECTO CONFIRMADO se alcanza SOLO si, durante esa investigación, se confirma que la terna `schema`+`name`+`type` de `.metadata` (fail-closed si falta alguna) coincide con un objeto que el investigador LEE en el `.sql` aplicado (paso humano, no regex — ronda 20, MAYOR) — recién entonces `APPLY-RECOVERS` |
| Crear `CLASS_FILE` con `mktemp` DESPUÉS de ganar `APPLY-RUN`, no antes | Si `mktemp` falla ahí (disco lleno, permisos, inodos, `TMPDIR` inválido) el wrapper muere bajo `set -e` sin ejecutar PROC-M13 NI publicar ningún cierre — el gate queda huérfano hasta el timeout de 30 min en vez de fallar limpio (ronda 21, MAYOR) | `CLASS_FILE="$(mktemp)"; export PROC_M13_CLASS_FILE="$CLASS_FILE"` es el paso **0 de "Adquisición"** (ref 01 §2), ANTES de siquiera intentar publicar `APPLY-RUN` — si falla ahí, no se reclama ningún gate que huérfanar |
| Recuperar un `APPLY-FAILED` citando solo un `git log --since=<timestamp>` sobre `main`, o los comandos `gh pr view #<PR>`/`--json files` de la ronda 16, o un `gh api .../files` sin `--paginate` con cero coincidencias tratado como pasado | El timestamp es el de INICIO del RUN fallido, no el de fallo; `#<PR>` como argumento de shell abre un comentario (`gh` solo recibe `pr view`); el token `MERGED` no lleva SHA; `--json files` no expone `status`; y el endpoint REST de ficheros ES PAGINADO — sin `--paginate` una migración en página 2+ queda invisible, y cero coincidencias deja `rc=0` igual si no se comprueba explícitamente (ronda 16 BLOQUEANTE; comandos ronda 17 MAYOR; paginación+check ronda 18 MAYOR) | Publicar `# APPLY-RECOVERS #<PR-fallido> <nonce-fallido> #<PR-nuevo> <nonce-nuevo> [<estación>]` **solo tras verificar la lista COMPLETA de condiciones de `references/06-migraciones-y-slots.md`** —hoy (a)-(h), cuenta citada como ilustración y no como definición—, que es su ÚNICA fuente — incluye la coincidencia EXACTA de nonce entre el `APPLY-FAILED` recuperado y el `APPLY-RUN` nuevo (f) y la comprobación de duplicado, autorización ajena y consumo previo (h). Aquí NO se re-enumeran: esta fila enumeraba CUATRO al lado de una lista de OCHO, y cuatro condiciones escritas a mano junto a una lista de ocho son cuatro oportunidades de divergir — se derivan de la fuente única, no se copian (ronda 28, MAYOR — hallazgo de revisión externa). Si falta CUALQUIERA de las aplicables, escalar a CEO/Orquestador — fail-closed, nunca asumir (ref 01 §2 punto 4) |
| Un `APPLY-DONE`/`APPLY-FAILED` tardío o duplicado de un ciclo anterior aparece como "el último evento" | El gate-check no correlacionaba el cierre con el run_id del RUN activo (ronda 15, MAYOR) | El cierre solo cuenta si su `#<PR>`+timestamp+`<nonce>` coincide EXACTO con el run_id del RUN activo (el `<nonce>` es la clave única — ronda 27), nunca "el último cierre visto" a secas (ref 01 §2 punto 4) |
| La categoría de recuperación (TRANSITORIO/ESCALAR/DEFECTO) vive solo en `$LOG`, local a la estación que corrió PROC-M13 | Otra estación, o la misma tras un reinicio, no puede reconstruir de forma determinista qué transición está autorizada leyendo solo el flock (ronda 18, MAYOR) | `APPLY-FAILED` lleva la categoría como ÚLTIMO campo (el quinto, tras el `<nonce>` — ronda 27, antes era el cuarto), publicada en el mismo acto que el cierre: `# APPLY-FAILED [<estación>] #<PR> <ISO8601> <nonce> <CATEGORIA>` — durable y compartida, cualquier lector la ve sin acceso al `CLASS_FILE`/`$LOG` original (ref 01 §2) |
| Un wrapper que promete `trap 'publish_close "$?"' EXIT` sin que `publish_close` esté definida en ningún fichero del paquete, o una `publish_close` que se define pero nunca lee `CLASS_FILE` ni calcula `<CATEGORIA>`, o un `classify_log` que grepea `$LOG` (texto libre, con cuerpos HTTP remotos interpolables — ronda 20, BLOQUEANTE) en vez de leer el literal que PROC-M13 escribe en su propio canal | Ejecutado literalmente termina en `command not found` sin publicar ningún cierre (ronda 17, BLOQUEANTE); y aunque esté definida, si solo imprime token/estación/PR/timestamp sin la categoría, TODO fallo real publica un token de formato inválido — irreconstruible desde el flock (ronda 19, BLOQUEANTE); y si clasifica grepeando `$LOG`, un cuerpo HTTP forjado por un tercero puede simular un prefijo TRANSITORIO ajeno — verificado ejecutando el caso literal (ronda 20, BLOQUEANTE) | `publish_close` Y `classify_log` definidas y verificadas juntas (ref 01 §2; `proc-m13.selftest.sh` T21, 12 asserts incluyendo la reproducción adversarial del cuerpo forjado): `classify_log` lee `CLASS_FILE` — NUNCA `$LOG` — contra el literal `TRANSITORIO`, default ESCALAR; `publish_close` arma `# APPLY-DONE ...` o `# APPLY-FAILED ... <CATEGORIA>` con el resultado — sin nada fallible entre el fin del hijo y la publicación, un trap no protege nada que la secuencia no proteja ya (ref 01 §2 punto 4) |
| El wrapper activa `pipefail`, rescata la tubería con `\|\| true`, o confía en evitar `pipefail` como protección SUFICIENTE contra un fallo de `tee` | Con `pipefail`, `set -e` aborta el wrapper en la línea del pipe ANTES de leer `PIPESTATUS`; `\|\| true` "arregla" el abort pero PISA `PIPESTATUS` con el de `true` (0) — publica `APPLY-DONE` para un fallo real; y SIN `pipefail`, si `tee` (el ÚLTIMO comando) falla por su cuenta (disco lleno, verificado con `tee /dev/full`), la tubería YA se ve fallida y `set -e` aborta igual, antes de `publish_close` — el rediseño de la ronda 17 no cerraba este caso (ronda 17 MAYOR; tee sigue sin cerrar ronda 18; cerrado ronda 19, MAYOR) | El wrapper SIEMPRE protege la línea completa con `set +e` ANTES de la tubería y `set -e` DESPUÉS de leer `PIPESTATUS` — nunca condicionado a si hay `pipefail` o no, nunca con `\|\| true`, y NUNCA reactivando `-e` antes de copiar `PIPESTATUS` a una variable (eso también lo pisa a `0`, ref 01 §2 punto 4) |
| Una `CREATE OR REPLACE` folia sobre el cuerpo pre-apply de otra migración del mismo gap | La dependencia de contenido no la cierra el gate de ejecución por sí solo | La dependiente verifica CONTRA EL LEDGER, no solo `MERGED`, que la migración de la que depende ya está aplicada (ref 06 §2 punto 5, ref 01 §2 punto 5) |
| Una estación sin `SUPABASE_ACCESS_TOKEN`/escritura directa al flock intenta mergear un PR con migraciones | El espejo remoto cubre **LEER, y nada más**: publicar un token o decidir sobre la exclusividad de uno exige escritura directa al flock canónico (**fuente única: ref 01 §2 «Acceso directo al flock canónico»** — esta fila NO repite la enumeración a propósito: cuando la repetía se desincronizó de las de ref 01, ronda 25, MAYOR de revisión externa) | Rebotar el PR a una estación con escritura directa al flock canónico (ref 01 §2 "Acceso directo al flock canónico obligatorio") |
| Un `APPLY-RUN` lleva minutos sin `APPLY-DONE`/`APPLY-FAILED` | Posible estación caída a mitad de PROC-M13 | Tras ~30 min sin cierre, escalar al CEO/Orquestador para verificar el estado real — NUNCA forzar otro `APPLY-RUN` sin confirmar que el primero murió (ref 01 §2 punto 4) |
| Un RUN queda huérfano tras confirmar que la estación murió (SIGKILL/host caído entre el fin de PROC-M13 y la publicación del cierre) | Ningún trap ni secuencia sobrevive un `SIGKILL` del proceso que lo ejecuta — el timeout de arriba solo decía "investigar", no cómo cerrar (ronda 17, BLOQUEANTE); leer el ledger UNA sola vez justo tras confirmar la muerte es un TOCTOU — la muerte del cliente no prueba que la transacción del último POST haya terminado del lado del servidor, y DOS lecturas separadas por el `--max-time` del CLIENTE tampoco lo prueban — el propio contrato reconoce que ese timeout no cancela ni acota la transacción del SERVIDOR (ronda 18, BLOQUEANTE; corregido de raíz ronda 19, BLOQUEANTE: hacía falta una señal del lado que realmente decide, no una ventana de tiempo) | El CEO/Orquestador (nunca una estación sola) obtiene la Señal de quiescencia REAL antes de publicar nada — consulta a `pg_locks` sobre `supabase_migrations.schema_migrations` vía el mismo endpoint `database/query` que `fetch_ledger` (ref 01 §2; lock adquirido EXPLÍCITAMENTE por PROC-M13 tras `begin;`, ANTES del DDL — ronda 20, BLOQUEANTE: antes solo aparecía en el `insert` final, y un DDL largo en curso podía leer `0` con la mutación viva — verificado contra Postgres real, nunca prod; y si un POST de la estación muerta seguía en cola tras esta lectura, la revalidación DENTRO de su propia transacción — ronda 21, BLOQUEANTE — lo aborta solo al encontrar la versión ya aplicada, sin depender de lo que el CEO haya decidido mientras tanto): lock exclusivo en `0` → gap completo + advisors 0 ERROR → publica `APPLY-DONE` citando el run_id EXACTO del huérfano; incompleto → `APPLY-FAILED ... ESCALAR` con el mismo run_id (nunca TRANSITORIO, sin `CLASS_FILE` de la estación muerta que clasificar); lock `> 0` → NO publicar todavía, repetir la consulta — reusa los tokens existentes, no hace falta uno nuevo (ref 01 §2 punto 4) |
| `gh pr view <PR> --json state,merged` falla | `merged` no es un campo válido de la CLI instalada (ronda 14, MAYOR) | Usar `--json state,mergedAt` — `state=CLOSED` con `mergedAt=null` = PR cerrado sin mergear (ref 01 §2) |

## 5. Proceso y hooks de push

| Síntoma | Causa probable | Salida |
|---|---|---|
| `git push` bloqueado con diagnóstico del hook aunque el sentinel existe | **D16 (TAL-2288)**: el hook de push-audit (`check-push-audit.sh`) BLOQUEA comandos COMPUESTOS que contienen `git push` (`;`, `&&`, `(`, pipes) | El `git push` va SIEMPRE como llamada Bash **atómica standalone**; obtener heads/`--force-with-lease` refs en una llamada PREVIA separada — nunca encadenar `fetch && push` ni `push; algo` |
| El push desde la estación falla/bloquea aunque sea una sola llamada | Un pipe/redirección PEGADO al `git push` (`\| tee`, `> log`) también cuenta como compuesto para el hook; y el cwd pudo resetearse entre llamadas Bash de la estación (regla dura 15, 2026-07-28: `check-push-audit.sh` DENIEGA además opciones globales entre `git` y el verbo — `-C`, `--git-dir`, `--work-tree`, `-c` — y wrappers `sudo`/`env`/`command` antes de `git`, clase sentinel-bypass) | **Un campo `cwd`/`workdir` estructurado del tool call NO cierra la ventana por sí solo** (ronda 3, 2026-07-31): solo es seguro SI el propio hook se ejecuta bajo ESE MISMO workdir — y `check-push-audit.sh` no lee ningún campo `cwd`/`workdir`, resuelve HEAD/branch contra SU PROPIO cwd de invocación. Evidencia en contra en este repo: el hook se registra por **ruta relativa** (`.claude/settings.json`: `bash scripts/check-push-audit.sh`), lo que sugiere un cwd fijo del harness, NO atado al workdir del comando gateado — el hook podría autorizar el repo A mientras el push corre en el repo B. **Precondición obligatoria**: probar en el harness concreto que el hook valida contra el MISMO workdir del campo antes de confiar en él; sin esa prueba (y hoy la evidencia apunta a que no se cumple), **no existe forma de un solo acto segura y compatible con el guard**. La corrección estructural real es que el GUARD MISMO lea ese campo y resuelva ahí sentinel/HEAD/branch — cambio de `scripts/check-push-audit.sh`, fuera de alcance de este doc-vivo, declarado como deuda/follow-up. Hasta entonces: tratar TODO push automatizado como inseguro sin esa verificación y escalar, nunca asumir que cd-luego-push o un campo estructurado sin prueba resuelven el problema. `--no-verify` **NO es la vía de rutina**: queda RESERVADO a un **break-glass explícito y trazado** (motivo + SHA + quién). Los cuerpos de texto que citen el verbo de push van SIEMPRE por fichero, nunca inline (el guard matchea la cadena en TODO el comando, payloads incluidos) |

## 6. Lado de lectura del bus (regla dura 16)

**Todo actor de fábrica tiene lado de LECTURA del bus además del de escritura**
(2026-07-28). El vigilante que solo publica (sellar.sh, latidos) y nunca escucha es una
ventana ciega estructural, no un despiste — la estación de merge estuvo así hasta el
28-jul. Consecuencia medida: intakes duplicados en paralelo, reclamos nulos sobre PRs ya
arbitrados, arranques de pool sobre premisas caducadas. El lado de lectura cumple tres
condiciones: **(1)** cursor persistido FUERA del proceso (fichero en disco: un reinicio no
abre ventana ciega ni re-emite lo ya visto); **(2)** latido explícito (un monitor sin
latido no se distingue de uno muerto); **(3)** cobertura por defecto amplia (más ruido, no
menos — un monitor ruidoso molesta, uno mudo miente).

**Matiz — DOS canales, no uno** (2026-07-29): el bus (`/tmp/merge-claims.txt`) **y** la
entrada propia del agente (su composer/canal de órdenes). Una estación con lado de lectura
del bus correcto perdió órdenes del lead ~40 min por no vigilar su propia entrada — las
torres corren detached (cero clientes tmux), así que si el relay manda texto+Enter en la
misma llamada, el Enter puede no aterrizar: la orden queda escrita y sin someter, y el
agente no se entera de que existe. **Doble salvaguarda obligatoria (dueño explícito)**:
**(a) emisor** — Enter en llamada SEPARADA y verificar el EFECTO (composer vacío) antes de
dar la orden por entregada; **(b) receptor** — vigilante de la propia entrada con
**anclaje estructural a la línea del prompt** (nunca al pane entero: el propio texto del
agente sobre el problema dispararía el detector, regla 17) y **guarda de plausibilidad que
elimine el NBSP** `\xc2\xa0` (el pane viene relleno de espacios no-rompibles que
`[[:space:]]` bajo `LC_ALL=C` no recorta → falso positivo permanente).

**Matiz — el muestreo REDUCE el riesgo, no lo elimina**: una orden capturada por la trampa
ya había desaparecido del composer al ir a limpiarla, arrastrada por el envío siguiente —
un texto atascado no siempre persiste hasta que alguien lo lee. Un vigilante que muestrea
cada N segundos puede perder por completo un evento efímero que aparece y desaparece entre
dos ticks. **No se declara el canal «cubierto» por tener vigilante**: el vigilante es red
de seguridad, la corrección real vive en el emisor; bajar el intervalo de muestreo estrecha
el agujero, no lo cierra.

### Corolario A — la trampa de implementación del watcher

**NUNCA poner `awk`/`sed`/`python` con estado en un pipeline de `tail -f`**: `mawk`
bufferiza su ENTRADA, `fflush()` solo controla la salida, y como `tail -f` no cierra el
pipe, las líneas quedan retenidas indefinidamente (comprobado: sin `awk` sale al instante,
con `awk` no sale ni acumulando 8 KB). **Falso negativo que lo enmascara**: en modo batch
(`sed -n 'a,bp'`) el mismo filtro SÍ emite (el input termina y el buffer se vacía) → **un
filtro validado en batch puede estar muerto en streaming**. Síntoma traicionero: el proceso
VIVE, `/proc/<pid>/fdinfo/<fd>` muestra `pos` == tamaño del fichero, y aun así no sale
nada — indistinguible de «no hay novedades». El arreglo NO es cambiar `mawk` por `gawk`
(misma clase de riesgo): es sacar el proceso con estado del camino en streaming — polling
con cursor en disco + `awk` en modo batch sobre un trozo finito.

### Corolario B — dos formas válidas según harness

Según el harness de la estación, el lado de lectura toma una de dos formas, ambas válidas
y hay que documentar cuál aplica: **(a) harness que solo notifica al TERMINAR un proceso de
fondo** — el watcher se auto-termina al detectar el evento (su propia muerte ES la
notificación) y se re-arma tras cada disparo (coste: ventana entre disparo y re-armado);
**(b) harness con notificación por línea emitida** (monitor persistente) — el watcher vive
y emite por evento (coste: ventana de hasta un tick, que NO es ceguera mientras el cursor
persista).

**Anti-patrón**: un sello NO reserva nada — el bus documenta, la máquina manda; la
verificación por efecto va en la MISMA invocación que el lanzamiento, nunca en una llamada
previa.

## 7. Detectores que se envenenan solos (regla dura 17)

**Un detector cuyo patrón puede aparecer en el contenido que analiza se envenena solo**
(2026-07-28). No es un bug de implementación: es una propiedad del
diseño del detector, y por eso reaparece en herramientas que no comparten una línea de
código. Tres instancias medidas el mismo día: `pgrep`/`pkill` que matchea su propio waiter
(el patrón viaja en el `argv` del proceso que lo invoca — mató el propio shell, rc=144, y
reportó «en vuelo» un gate ya terminado); un guard de push que matchea su payload (busca la
cadena del verbo en TODO el comando, incluidos los cuerpos de texto — bloqueó la redacción
de la corrección de esa misma doctrina, regla 15); un watcher que parsea prosa sobre su
propio formato (el filtro anti-self buscaba una cadena de prosa que aparece cuando OTROS
citan a esa estación → suprime bloques ajenos, y un marcador citado dispara el filtro de
emergencia por contener la palabra en mayúsculas).

**La regla operativa**: patrón del detector **DISJUNTO** del contenido analizado. Donde la
disyunción sea imposible (el detector vive en el mismo espacio que su objeto), exigir **las
DOS** salvaguardas: **(1) guarda de plausibilidad** — descartar el propio invocador antes
de decidir (excluir el PID propio y su árbol; comparar `cwd`/`fdinfo` en vez de la línea de
comando); **(2) anclaje estructural, no textual** — anclar a una marca que SOLO puede
producir el emisor legítimo (un delimitador de formato, un campo de un fichero
estructurado, una estampa generada por la herramienta), nunca a prosa que cualquiera puede
citar.

**Familia completa de principios de evidencia** (los tres se citan juntos, son la misma
idea en tres capas): **(a) evidencia por CLAVE exacta** — nunca por «último fichero» ni por
agregado (ledger por `sha` exacto §2 arriba, no el slot único que cualquiera pisa;
commit-status filtrado por CONTEXTO §Gate 2, no el roll-up); **(b) detección por EFECTO** —
nunca por nombre (sondear procesos dentro del contenedor, no `pgrep` en el host; esperar
por CAMBIO, no por existencia — ref 08 §pool); **(c) patrón del detector DISJUNTO del
contenido** (esta regla).

**Addendum — cuarta instancia y endurecimiento de patrones destructivos** (2026-07-29): el
verificador de patrones destructivos marcó 1 coincidencia sobre el diff de #1409; al
atribuirla resultó ser la palabra `raw_truncated` DENTRO de un comentario de
`markdown-renderer.tsx` — el patrón casaba subcadena dentro de un identificador, sin límite
de palabra ni contexto SQL. Un falso positivo de ese grep, sin atribuir a fichero/línea,
para un PR sano invocando PROC-M17 (destructiva no declarada) — el coste no es ruido, es un
rebote injustificado. **Endurecimiento**: límite de palabra (`\b`/`[^A-Za-z0-9_]`, para que
`raw_truncated` no case `truncate` ni `deleted_at` case `delete from`) + contexto SQL
(exigir que la coincidencia viva en un fichero SQL o cadena SQL, no en prosa/comentarios) +
**la guarda que ya es doctrina**: atribuir SIEMPRE el patrón a su fichero y línea ANTES de
invocar PROC-M17 — el endurecimiento reduce falsos positivos, no sustituye la atribución.

## Anti-duplicado del bus — invariante con oráculo (TAL-5449, ley del 2026-09-07)

Sellar un marcador en el bus **se deduplica por la estampa exacta del marcador, nunca por el nombre
desnudo**: dos sellos distintos del mismo rol comparten nombre y no son el mismo hecho, así que
comparar por nombre suprime sellos legítimos y comparar por estampa exacta es lo único que identifica
el hecho.

**Oráculo corrido con control**: `talent-ceo/scripts/bus-sellar.sh` devuelve **`rc 3`** ante el
marcador repetido y **`rc 0`** ante uno distinto; el duplicado no se escribe. La búsqueda del marcador
y el `append` ocurren **dentro de la misma sección crítica**: buscar fuera del lock permite que dos
escritores concurrentes del mismo marcador vean ambos «no está» y sellen los dos.
