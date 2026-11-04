# 06 — Migraciones y slots (doctrina)

Doctrina repo-agnóstica de la estación para PRs con migraciones. La mecánica ejecutable de
la instancia (Management API, comandos exactos) vive en el anexo
(`anexo-<proyecto>.md`, PROC-M13/M14/M15).

## Table of Contents

- [1. El ledger real de prod es la verdad](#1-el-ledger-real-de-prod-es-la-verdad)
- [2. Renumeración de slots (pre-merge)](#2-renumeración-de-slots-pre-merge)
- [3. Apply + advisors + ledger = gate de Done](#3-apply--advisors--ledger--gate-de-done)
- [4. Destructivas: GO del lead SIEMPRE](#4-destructivas-go-del-lead-siempre)

## 1. El ledger real de prod es la verdad

> **Cómo está protegida la regla de elegibilidad, y por quién.** Con exactitud, porque dos
> redacciones anteriores de esta nota afirmaron más de lo que el gate ejecuta.
>
> **Lo que comprueba la máquina, y es todo lo que comprueba:**
>
> 1. **Presencia de la formulación canónica positiva** — «CUALQUIER estación (M1-M5) mergea Y
>    aplica» — **en CADA UNA de sus SIETE ocurrencias**, ancladas una a una:
>    `ref 01` **dos** (`INV-ME-057` línea normativa, `INV-ME-237` cierre del histórico),
>    `ref 02` **una** (`INV-ME-069`), **este fichero dos** (`INV-ME-065` la línea normativa e
>    `INV-ME-243` la cita de esta misma nota) y `SKILL.md` **dos** (`INV-ME-070` pipeline,
>    `INV-ME-236` checklist). **Alterar cualquiera de ellas rompe el paquete.**
>    Dos correcciones de conteo, ambas de la misma clase: cada `MUST` exigía solo `>=1`
>    coincidencia por fichero, así que donde había dos ocurrencias se podía devolver la
>    autoridad a una lista fija en una de ellas y el gate seguía verde (par20-p1, MAYOR); y el
>    inventario decía **seis** cuando son **siete** — faltaba contar la cita de esta nota, que
>    es texto real y editable como cualquier otro (par21-p1, MAYOR). Si se añade una ocurrencia
>    nueva, **se ancla también**: el inventario solo es cierto si se mantiene.
>    Dos precisiones que salieron de contar de verdad: la séptima es **la cita de esta misma
>    nota**, y va **partida en dos líneas**, así que ningún patrón de línea la alcanza — la
>    ancla `INV-ME-244` por su encabezado. Y `CHANGELOG.md` tiene **dos menciones más** que
>    **no** se anclan a propósito: es histórico, no superficie normativa, y reescribirlo no
>    cambia lo que la fábrica ejecuta.
> ⚠ **DEUDA DECLARADA** (par22-p1, MAYOR 3 — sale por **techo de ronda**, no por no haberse
>    visto; dueño: issue de continuación abierta por el coordinador). **`INV-ME-244` NO ancla
>    la cita partida que dice proteger**: busca solo el encabezado «Presencia de la formulación
>    canónica positiva», que no depende de los bytes de la cita. Medido: invertir esa cita a una
>    restricción a M1/M2 deja el paquete en **967/0**. Es decir, **«alterar cualquiera de ellas
>    rompe el paquete» sigue siendo FALSO para la séptima**. Y el auditor contó una **octava**
>    formulación equivalente en `SKILL.md` (Essential Patterns, sin `(M1-M5)`) que tampoco está
>    anclada. **Hasta que esa issue cierre, el inventario de arriba describe la intención, no la
>    garantía.**
>
> 2. **Ausencia de las formulaciones retiradas CONOCIDAS**, una a una y literales
>    (`INV-ME-045/047/062/239/247/248/249`).
>
> **Lo que la máquina NO comprueba, y no lo va a comprobar:** que no exista *ninguna otra*
> redacción que devuelva la autoridad a una lista fija. Se intentó con expresiones regulares
> sobre la prosa y **falla en las dos direcciones a la vez** — deja pasar «…son las **únicas**
> que pueden aplicar…» y bloquea «Solo M1 documenta … mientras M2 aplica…», que no restringe a
> nadie. Un ERE no expresa «cuantificador + lista nombrada + verbo de autoridad ligado al
> sujeto», y un gate que se equivoca en los dos sentidos es ruido con autoridad.
>
> **Por tanto, y esta es la parte que hay que respetar: frente a una reformulación nueva, la
> doctrina la protege la REVISIÓN HUMANA, no el gate.** Quien revise un cambio en cualquiera de
> **las CUATRO superficies normativas** —`ref 01`, `ref 02`, este fichero y `SKILL.md`— **más
> `ref 07`**, tiene que leer si alguna frase restringe QUIÉN puede mergear o aplicar PRs con
> `supabase/migrations/`; el verde del paquete **no** responde esa pregunta. El alcance anterior
> decía «este fichero o `ref 07`» y dejaba fuera tres de las cuatro superficies que el párrafo
> de arriba declara normativas (par20-p1, MAYOR). Queda escrito en vez de fingir un ratchet que
> no existe (par19-p1, MAYOR).

- El estado de migraciones NO es `main` ni el working tree: es
  `supabase_migrations.schema_migrations` en producción (el "ledger").
- La sincronía se verifica comparando la **lista exacta de versiones en ambos sentidos**
  (`comm -3` bidireccional — anexo PROC-M13 paso 2), nunca por count + max: dos ledgers
  pueden compartir ambos y divergir en versiones intermedias.
- **Prod con versiones que `main` no conoce = divergencia grave** → no aplicar, escalar
  al lead.
- Como el Mergeador es el ÚNICO actor que aplica a prod (ADR-0043, amendment de la regla
  24), el ledger deja de tener carreras cross-coordinador. Lo que serializa el apply **no es
  «la estación»** —son cinco— sino el gate `APPLY-RUN`/`APPLY-DONE`/`APPLY-FAILED`
  fleet-wide (ref 01 §2): solo una estación tiene PROC-M13 en vuelo a la vez, aunque
  cualquiera pueda ser esa estación. La frase anterior conservaba el lenguaje del modelo de
  estación única y contradecía en pequeño la doctrina de las cinco (par17-p1, sugerencia).
- **Carrera de `main` durante el drain-burst**: mergeando en serie, `main` avanza entre el
  recycle y el preflight de un dispatch → un gate git "behind origin/main" es **transitorio y
  esperado** (es la propia estación drenando), NO un error. Reintentar el rebase/gate; nunca
  escalar por esto. Un coordinador de la 1ª estación que vea "behind origin/main" transitorio
  también reintenta — la verdad del ledger cross-flota la tiene el Orquestador.
- **CUALQUIER estación (M1-M5) mergea Y aplica PRs que tocan `supabase/migrations/`**
  (TAL-5170, ratificado por el CEO tras la ronda 12 — `CEO-DOCTRINA-MIGRACIONES-5-ESTACIONES`,
  ref 01 §2 "Apply de migraciones: protocolo SLOT-CLAIM del bus", `SUPABASE_ACCESS_TOKEN` en
  las 5) — no hay estación fija ni turno: el token `SLOT-CLAIM` sobre el flock compartido evita
  que dos migraciones compartan número de slot (renumerar contra ledger de prod ∪
  `origin/main` ∪ TODOS los PRs abiertos con enumeración COMPLETA, publicar el claim, colisión
  → renumerar al siguiente libre, §2 abajo). **`SLOT-CLAIM` NO es un mutex de apply, ni siquiera
  entre slots distintos** (corregido ronda 13, BLOQUEANTE): PROC-M13 (anexo §4) aplica el gap
  COMPLETO `main − ledger`, no "el slot de este PR" — dos estaciones con slots distintos pueden
  ambas intentar aplicar el MISMO slot anterior si una arranca su PROC-M13 antes de que el otro
  quede confirmado en el ledger. Por eso ejecutar PROC-M13 exige adquirir primero el gate
  `APPLY-RUN`/`APPLY-DONE`/`APPLY-FAILED` (ref 01 §2 punto 4: gana el PRIMER RUN tras el
  último cierre válido, nunca el más reciente) — solo una estación tiene PROC-M13 en vuelo a la
  vez, fleet-wide, aunque cualquiera pueda ser esa estación; un wrapper EXTERNO protege TODA
  la secuencia con `set +e`/`set -e` (leer `PIPESTATUS[0]` ANTES de reactivar `-e` — el orden
  inverso pisa el rc a `0` igual que un `|| true`; y ni evitar `pipefail` basta si `tee`
  mismo falla) y publica el cierre por código de salida con la categoría YA calculada
  leyendo `PROC_M13_CLASS_FILE` (`exit 0` → `APPLY-DONE`; cualquier otro código →
  `APPLY-FAILED ... <CATEGORIA>` ∈ TRANSITORIO/ESCALAR, nunca DEFECTO automático, durable
  en el flock, ronda 19) — NUNCA `$LOG`: PROC-M13 interpola cuerpos HTTP remotos en sus
  propios mensajes de error, y un tercero podría forjar un prefijo TRANSITORIO ajeno (ronda
  20, BLOQUEANTE) — PROC-M13 declara su clase con un literal fijo en su propio canal
  estructurado. La recuperación NO es siempre "migración nueva" (ronda 17): una
  lectura TRANSITORIA (token, Vault, `fetch_ledger`, advisors — sin mutación en vuelo) solo
  pide retry; el POST que SÍ muta, Paso 1 de contenido (una migración nueva no desbloquea una
  pendiente rota), advisors con `nerr` real, o cualquier fallo AMBIGUO/sin `class` explícito
  (divergencia, drift, default fail-closed) ESCALA con una Señal de quiescencia REAL —
  consulta a `pg_locks` sobre el ledger, con el lock adquirido EXPLÍCITAMENTE tras `begin;`
  ANTES del DDL (ronda 20, BLOQUEANTE), no una ventana de tiempo del cliente (ronda 19) —
  MÁS una revalidación DENTRO DE LA MISMA TRANSACCIÓN, tras el lock y antes del DDL, de que
  la versión sigue ausente (ronda 21, BLOQUEANTE: conteo `0` en `pg_locks` no demuestra que
  ningún POST esté a punto de pedirlo — un retry que gane el lock DESPUÉS de un POST antiguo
  se aborta solo al encontrar la versión ya aplicada, sin repetir el DDL) — antes de decidir;
  DEFECTO CONFIRMADO solo se alcanza SI esa investigación confirma que la
  terna `schema`+`name`+`type` de `.metadata` (fail-closed si falta alguna) coincide con un
  objeto que el investigador LEE en el `.sql` aplicado (ronda 20, MAYOR) — recién entonces
  exige
  publicar `APPLY-RECOVERS` con identidad verificada (SHA de merge real vía
  `gh pr view <PR>` SIN `#`,
  ancestría, diff que AÑADE por `status` un fichero en `supabase/migrations/`, HANDOFF que
  cite el PR fallido) — nunca un `git log --since` a solas (ref 01 §2, tabla de
  recuperación). Una migración que además depende
  del cuerpo post-apply de otra del mismo gap (§2 punto 5) verifica CONTRA EL LEDGER, no solo
  su `MERGED`, antes de foliar sobre su cuerpo. El merge y el apply sí son una sola operación
  indivisible que ejecuta la MISMA estación que mergeó (PROC-M13/M15, mismo turno) — quien
  mergea, aplica, nunca se delega ni se difiere. Las destructivas siguen exigiendo GO del lead
  SIEMPRE (§4 abajo), sin cambio.

## 2. Renumeración de slots (pre-merge)

1. El HANDOFF declara los slots del branch (`migration_slots`); son **provisionales** —
   el canal de producción los eligió contra el main de SU momento.
2. Antes del slot de merge, el Mergeador calcula el tope real (ledger ∪ `main` ∪ TODOS los PRs
   abiertos con migraciones, no solo los drafts de la propia cola — gotcha 7 del SKILL.md) y
   renumera si hay colisión: slots libres POR ENCIMA del tope, preservando el orden relativo de
   la rama (mecánica: anexo PROC-M14). **Enumeración COMPLETA obligatoria, `--limit` alto NO
   basta solo** (TAL-5170, `CEO-DOCTRINA-MIGRACIONES-5-ESTACIONES`, reforzado ronda 12):
   `gh pr list` devuelve 30 resultados por defecto — un `--limit` explícito (p. ej.
   `--limit 200`) solo mueve el techo, no demuestra que sea el total real. Contrastar el
   recuento devuelto
   contra un total AUTORITATIVO independiente — **ÚNICAMENTE** `gh api graphql` `issueCount`
   (corregido tras auditoría — ronda 13: `gh pr list --search "is:open" ... --jq length` NO
   sirve de contraste, hereda el mismo default de 30 sin `--limit` propio); si no coinciden, no
   se declara enumeración completa. Antes de pushear el renumber, publicar
   `# SLOT-CLAIM <slot> = #<PR> [<estación>] <ISO8601> <nonce> (<fichero>)` en el flock **desde escritura DIRECTA, nunca desde
   un espejo** (ref 01 §2)
   y RELEER tras el append para confirmar que el propio claim es el primero — sin claim
   confirmado no se pushea. El pre-check automatizado es
   `scripts/crosscheck-migration-slot.sh <pr>` (TAL-2273): valida además que el slot del
   HANDOFF coincide con el fichero del diff y que no hay históricas tocadas/malformadas ni
   timestamps duplicados; exit `3` = renumerar, `1` = integridad rota, `2` = fail-closed.
3. El rename es un commit → head nuevo → re-emitir HANDOFF completo (9 secciones) + re-gate
   (ref 02 §3). La renumeración la ejecuta el canal de refactorización (es un
   micro-encargo mecánico).
4. **Cross-check slot↔diff (fail-closed)**: cada archivo `supabase/migrations/2999*` del diff
   DEBE estar declarado en `migration_slots`; un standby en el diff no declarado es entrega
   inválida (gate 4 del AND, ref 02 §7). *(El enforcement automático en `verify-handoff.sh`
   —cruzar cada `2999*` del diff contra `migration_slots`— es issue follow-up a crear por el
   Orquestador; hoy se verifica a mano.)*
5. **`CREATE OR REPLACE` de función — foliar sobre el cuerpo REALMENTE VIVO, nunca sobre la
   base del repo** (TAL-5170, caso real TAL-5074 pisando TAL-5026): el pin "aplícate DESPUÉS
   de #N" que declara un HANDOFF garantiza el ORDEN de aplicación, no la BASE sobre la que el
   `CREATE OR REPLACE` razona — si dos migraciones en vuelo reemplazan la MISMA función
   (p. ej. `has_access` seat-aware), la segunda debe partir del cuerpo que estará REALMENTE
   vivo en prod tras la primera, no de la versión que el repo tenía cuando se escribió. Antes
   de aplicar un `CREATE OR REPLACE FUNCTION` en un slot con otras migraciones pendientes por
   delante, verificar el cuerpo real con `pg_get_functiondef('<schema>.<función>'::regprocedure)`
   contra prod (o contra el estado post-apply de las migraciones anteriores del mismo gap),
   nunca contra el `.sql` del repo a secas — TAL-5074 pisó silenciosamente la lógica
   seat-aware que TAL-5026 había añadido porque folió sobre la base del repo, no sobre el
   cuerpo vivo tras TAL-5026.

## 3. Apply + advisors + ledger = gate de Done

Secuencia post-merge (MISMO turno — regla dura 8), por cada PR que añada migraciones.
**`CLASS_FILE` y el claim de `APPLY-RUN` YA se hicieron — se movieron a ANTES del merge
(TAL-5170, ronda 25, BLOQUEANTE — corregido: un claim publicado DESPUÉS del merge deja una
ventana donde dos estaciones pueden mergear las dos antes de que ninguna reclame nada; ver
SKILL.md checklist paso 7)**: para cuando esta secuencia arranca, el gate ya está ganado y el
merge ya ocurrió — lo que sigue es la ejecución del turno ya reservado, no la adquisición.

0. **`git pull --rebase` del clon operativo (main con el merge), PRIMER paso de esta
   secuencia post-merge — su fallo aquí ya NO puede orfanar el gate silenciosamente
   (ronda 25): el gate se ganó ANTES del merge (arriba), así que un pull roto ocurre DENTRO
   de la ventana ya protegida por el wrapper `set +e`/`set -e`/`publish_close` de la
   Adquisición (ref 01 §2) — si `git pull --rebase` falla, clasificar TRANSITORIO (falla de
   lectura/sincronización local, ninguna mutación remota en vuelo) y publicar el cierre
   `APPLY-FAILED ... TRANSITORIO` de inmediato en vez de continuar o dejarlo colgado; la
   recuperación es un `APPLY-RUN` normal tras corregir la causa (mismo régimen TRANSITORIO de
   siempre, ref 01 §2 tabla de categorías)** — motivo del pull en sí, sin cambio: PROC-M13
   (anexo §4, Paso 2) lee `supabase/migrations/*.sql` del directorio de trabajo LOCAL, no de
   un `git fetch` propio, así que correr con un clon desactualizado calcularía el gap sobre
   una lista incompleta.
1. **Leer el runbook/docs que el PR trae, AHORA que el pull garantiza que están presentes en
   el clon local** (B4+b: leer el runbook ANTES de ejecutar el apply — p. ej.
   `docs/runbooks/phone-otp.md` si el PR añade un mecanismo de OTP o un nuevo secret de
   Vault; el diff/grep del `.sql` muestra CUÁNDO se lee la dependencia, no si la superficie
   está viva ni el contrato de fallo, matiz M2-1, ev #1225). Leerlo ANTES del pull arriesga
   leer una versión vieja si el runbook mismo cambió en el PR recién mergeado.
2. Apply del gap real (anexo PROC-M13): una transacción por migración con el insert del
   ledger en el MISMO commit (esquema y ledger no pueden divorciarse).
3. Advisors security + performance (anexo PROC-M15): `ERROR` bloquea; `WARN` sobre
   objetos tocados = hallazgo real. **El fix va SIEMPRE por migración nueva** (nunca
   edición manual en remoto) — como issue al pool si excede el micro-encargo.
4. Confirmación de sincronía final (comm -3 vacío bidireccional, con main RE-capturado
   fresco — no reutilizar snapshots).
5. Solo entonces el encargo está **Done** (los issues los cerró el `closes` del merge; la
   evidencia del apply va en comentario de cierre con SHA + versiones aplicadas).
6. **Publicar el cierre del gate — SIEMPRE, mismo run_id de la reserva pre-merge (SKILL.md
   checklist paso 7, ronda 25), vía un wrapper EXTERNO a PROC-M13, SIN trap** (nunca un
   `trap EXIT` dentro del script: PROC-M13 ya usa el suyo para limpiar `$WORKDIR`, anexo §4 —
   un segundo trap lo pisaría; el wrapper tampoco necesita uno propio, ronda 17):
   `CLASS_FILE`/`PROC_M13_CLASS_FILE` YA existen (creados ANTES de mergear y de publicar
   `APPLY-RUN`, per SKILL.md checklist paso 7 — fuera del `$WORKDIR` que PROC-M13 borra al
   salir); ahora
   `set +e; bash proc-m13.sh 2>&1 | tee "$LOG"; rc="${PIPESTATUS[0]}";
   set -e` — el `set +e`/`set -e` protege TODA la línea SIEMPRE, no solo bajo `pipefail`: ni
   siquiera evitar `pipefail` basta si `tee` mismo falla (disco lleno, ronda 19 BLOQUEANTE) —
   sin `pipefail` un `tee` que falla YA hace que la tubería se vea como fallida bajo `set -e`
   igual. `PIPESTATUS[0]` debe leerse ANTES de reactivar `-e` — reactivarlo primero PISA
   `PIPESTATUS` a `0` igual que un `|| true` (ref 01 §2, ronda 19 MAYOR). Clasificación por
   CÓDIGO DE SALIDA, sin adivinar la fase (el anexo §4 hace salir PROC-M13 con `exit 0`
   únicamente tras completar TODO el script limpio — gap aplicado, confirmación de sincronía y
   AMBOS advisors sin `ERROR` — así que `exit 0` ya implica por sí solo ledger completo y
   advisors limpios): `rc` es `0` → `# APPLY-DONE [<estación>] #<PR> <ISO8601> <nonce>`; `rc` es
   CUALQUIER OTRO valor → `# APPLY-FAILED [<estación>] #<PR> <ISO8601> <nonce> <CATEGORIA>`, con
   `<CATEGORIA>` CALCULADA leyendo `CLASS_FILE` — NUNCA `$LOG` (ronda 20, BLOQUEANTE: PROC-M13
   interpola cuerpos HTTP remotos en sus propios mensajes de error; un tercero podría forjar
   un prefijo TRANSITORIO ajeno grepeando el log — la clase ahora es un literal fijo que
   PROC-M13 escribe él mismo en un canal separado, nunca derivado de texto que un tercero
   controla), sin excepción.

Si el apply falla, la recuperación NO siempre exige una migración nueva (ronda 17,
BLOQUEANTE; categorías corregidas ronda 18 y 19): PROC-M13 sale `≠0` tanto por un defecto
real de contenido como por un fallo puramente operativo que nunca dejó la BD en un estado
incorrecto (token, Vault, algunas redes) — el paso 6 clasifica leyendo `CLASS_FILE` contra el
literal que PROC-M13 escribe en el Paso que falló (tabla completa en ref 01 §2), publicando
SIEMPRE TRANSITORIO o ESCALAR — nunca DEFECTO de forma automática (ronda 19, MAYOR: PROC-M13
cuenta TODOS los `ERROR` de advisors sin filtrar por objeto tocado, así que un `ERROR` ajeno
atribuiría el defecto al PR equivocado). Si `CLASS_FILE` NO contiene el literal `TRANSITORIO`
(fallo implícito de `set -euo pipefail` — `mktemp`, `chmod`, `jq`, señal — que nunca llegó a
ningún punto de salida con `class` explícito), la categoría por defecto es **ESCALAR**:
**TRANSITORIO** (lecturas de solo-consulta —
token/Vault/`fetch_ledger`/advisors, sin mutación en vuelo) → corregir la causa y publicar un
`APPLY-RUN` normal, sin `APPLY-RECOVERS`; **ESCALAR** (el POST que SÍ muta — Paso 4 red,
riesgo real de doble-apply porque un timeout de cliente NO cancela la transacción del
servidor, anexo §4 — Paso 1 de contenido, ya que una migración nueva no desbloquea una
pendiente rota, divergencia, drift, advisors con `nerr` real, HTTP/confirmación ambigua, o
default sin `class` explícito) → CEO/Orquestador decide antes de cualquier retry o migración,
obteniendo la Señal de quiescencia REAL (ref 01 §2: consulta a `pg_locks` sobre el ledger vía
el mismo endpoint que `fetch_ledger` — NUNCA dos lecturas separadas por tiempo del cliente,
que no prueban nada del lado del servidor, ronda 19 BLOQUEANTE). PROC-M13 adquiere ese lock
EXPLÍCITAMENTE tras `begin;`, ANTES del DDL de la migración (ronda 20, BLOQUEANTE: antes el
lock solo aparecía en el `insert` final, así que un DDL largo en curso podía leer lock-count
`0` con la mutación TODAVÍA viva) si hubo una mutación en
vuelo. **DEFECTO CONFIRMADO** se alcanza SOLO durante esa investigación de ESCALAR: si se
reconsulta el advisor directamente y se confirma que la terna `schema`+`name`+`type` de
`.metadata` (fail-closed si falta alguna) coincide con un objeto que el investigador LEE en
el `.sql` de la migración recién aplicada (paso humano, no un regex sobre el `.sql` — ronda
20, MAYOR; nunca asumido desde `CLASS_FILE` a solas) → publicar
`# APPLY-RECOVERS #<PR-fallido> <nonce-fallido> #<PR-nuevo> <nonce-nuevo> [<estación>]` con identidad
VERIFICADA (nunca un `git log --since` a solas, que solo prueba que algo aterrizó en esa
ventana, no que sea el fix real): (a) SHA de merge real del PR fallido — el NÚMERO SIN `#`
como argumento (`#` abre un comentario de shell) — vía `gh pr view <PR-fallido> --json
mergeCommit --jq .mergeCommit.oid` (el token `MERGED` del flock NO lleva SHA, no sirve de
alternativa); (b) `git merge-base --is-ancestor <sha-fallido> <head-del-PR-nuevo>`
confirmando que el nuevo PR desciende del fallido; (c) el diff del PR nuevo AÑADE (no solo
toca) un fichero en `supabase/migrations/`, por `status` — que `gh pr view --json files` no
expone — vía `files="$(gh api --paginate repos/<owner>/<repo>/pulls/<PR-nuevo>/files --jq
'.[] | select(.status == "added" and (.filename | startswith("supabase/migrations/"))) |
.filename')"; [ -n "$files" ] || exit 1` — con `--paginate` (el endpoint pagina, una
migración en página 2+ quedaba invisible sin él) y un check EXPLÍCITO de no-vacío (cero
coincidencias dejaba `rc=0` igual, corregido ronda 18); (d) el HANDOFF del PR nuevo declara
explícitamente que corrige `#<PR-fallido>`; (e) el objeto flageado por advisors coincide con
el `.sql` aplicado (condición extra SOLO para recuperaciones de advisors, ronda 19); (f) el
`APPLY-RUN` que sigue lleva EXACTAMENTE el `<nonce-nuevo>` del `APPLY-RECOVERS`, y el
`<nonce-fallido>` es EXACTAMENTE el nonce del `APPLY-FAILED` recuperado — el enlace es por NONCE,
no solo por `#<PR>` (ronda 29, BLOQUEANTE: transportar el nonce no es vincularlo); (g) esas dos
igualdades las comprueba la ESTACIÓN al publicar —comprobación HUMANA, como el resto de
condiciones de identidad—: **no hay gate ejecutable que las imponga**, y el ratchet que las
protege acredita que las palabras están, no que la oración las afirme (residuo acotado y
declarado en ref 01, «Límite conocido»); y (h) si hay MÁS DE UN `APPLY-RECOVERS` para el mismo
`#<PR-nuevo>`, si la autorización es de otra estación, o si hay duda sobre si ya se consumió, la
estación ESCALA — la cardinalidad, el consumo y el vínculo de ejecutor de la autorización son un
hueco de contrato ABIERTO elevado al lead (TAL-5296, sección «Límite conocido» de ref 01), que
ninguna estación resuelve por su cuenta. Sin las
condiciones aplicables, escalar a
CEO/Orquestador — nunca asumir (ref 01 §2), nunca
una reapertura automática ni un intento a ciegas sobre el gap todavía roto.

**Clarificación — el pre-arranque de la regla 24 es de la ESTACIÓN, no del canal**
(`CEO-RULING-TOKEN-CANALES-POR-DISENO`, 2026-07-29): por el amendment Fábrica v2 de la
regla 24 en CLAUDE.md, «el agente que ejecuta el trabajo» dentro del sistema de canales
**es el Mergeador** — los canales de producción declaran slots en el HANDOFF y NO aplican
a prod. La verificación de BD 100% sync antes de avanzar es responsabilidad de **esta
estación**, que es quien tiene el token y quien aplica a producción. **Un auditor de canal
NO debe exigir `SUPABASE_ACCESS_TOKEN`**: su ausencia en canales de producción es diseño de
mínimo privilegio, no un gap — un plan de canal puede declarar «pre-arranque N/A por
amendment Fábrica v2 (responsabilidad de estación)» citando este marcador, sin que el gate
lo bloquee por eso. **La contrapartida**: en esta estación el pre-arranque NO se delega ni
se da por hecho — se RE-MIDE en cada arranque de trabajo (evidencia: ledger de prod
verificado en cada arranque, comm -3 vacío bidireccional). Principio general: la ausencia
de una credencial en un perfil de menor privilegio no es un hallazgo de seguridad, es el
objetivo del perfil — antes de reportarla como gap, comprobar si ese actor debería tenerla.

## 4. Destructivas: GO del lead SIEMPRE

- Clasificación (tabla canónica en el anexo de `talent-channel-operation` §4): `DROP
  TABLE`/`DROP COLUMN`/`TRUNCATE`/`ALTER … TYPE` irreversible/`DELETE` batch top-level =
  destructivo; cuerpos de función y `REVOKE` de grants no lo son.
- **El detector automatizado NO cubre todo** (verificado contra la impl real,
  `tco_detect_destructive_migration`): su grep restringe el `DROP` a
  `(table|column|schema|type)` — **`DROP POLICY` / `DROP FUNCTION` / `DROP TRIGGER` /
  `DROP VIEW`** (y `DROP INDEX` standalone) **pasan SIN marcar**; `ALTER TABLE … DROP
  CONSTRAINT` SÍ la detecta (patrón alter-table-drop, verificado empíricamente). El gate REAL de
  destructivas es el **grep manual del diff de migraciones** por el Mergeador (todo
  `DROP …`, `TRUNCATE`, `DELETE`, `ALTER … TYPE`) clasificado con la tabla canónica — el
  detector es señal temprana, nunca el veredicto.
- Declarada en el HANDOFF (`destructive: true`) → GO del lead ANTES del slot de merge; el
  GO cubre merge + apply (y las precauciones PITR que el lead dicte).
- Detectada SIN declarar → PROC-M17 (ref 03 §5): entrega inválida.
- El GO se registra en el PR (comentario del lead o cita literal con fecha) — sin GO
  trazable no hay merge, por verde que esté todo lo demás.
