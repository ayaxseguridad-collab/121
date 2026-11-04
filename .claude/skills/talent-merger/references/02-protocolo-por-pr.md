# 02 — Protocolo por PR (el corazón de la estación)

Secuencia completa intake → merge → Done para UN PR de la cola. El Checklist de vuelo del
SKILL.md es el resumen; esto es el drill-down con comandos.

## Table of Contents

- [1. Intake de la cola](#1-intake-de-la-cola)
- [2. Validación del HANDOFF (PROC-M01)](#2-validación-del-handoff-proc-m01)
- [3. Rebase sobre main](#3-rebase-sobre-main)
- [4. Slots de migración](#4-slots-de-migración)
- [5. CodeRabbit CLI (budget-aware)](#5-coderabbit-cli-budget-aware)
- [6. Rutas A/B](#6-rutas-ab)
- [7. Gates AND del merge (comandos por gate)](#7-gates-and-del-merge-comandos-por-gate)
- [8. Merge + post-merge + Done](#8-merge--post-merge--done)
- [9. PROC-M19 — Check rojo: ¿flake o real?](#9-proc-m19--check-rojo-flake-o-real)
- [10. Nota histórica — GitHub Actions (hoy N/A): firma del presupuesto agotado](#10-nota-histórica--github-actions-hoy-na-firma-del-presupuesto-agotado)

## 1. Intake de la cola

```bash
gh pr list --draft --json number,title,headRefName,createdAt,labels
```

> **RUTA APAGADA (fail-closed)** — ruling `CEO-RULING-MAJOR4-T05-BATCHING-OFF-PARALELA-NO-ES-BATCHING-1625`. **El
> batching está DESACTIVADO**: **CADA PR corre su suite COMPLETA sobre su propio head**, disjunto o
> no. El párrafo siguiente describe la ventana; **no autoriza fundir una pieza sin su suite**.

Orden de proceso: la prioridad curada por el Orquestador (bugs > mes-objetivo > resto;
agrupados por hot-file). El ACTO de merge lo serializa **GitHub mismo** vía `strict=true`
(§3 abajo: un merge sobre base stale es rechazado por la API, no un lock propio); la
preparación (pasos 2-6) avanza en paralelo DENTRO de cada estación sobre SU propio PR, y con
M1-M5 (TAL-5170) hay 5 instancias de esa disciplina corriendo a la vez — §3 sigue
gobernando, sin cambio, la disciplina DENTRO de cada estación individual (un PR cada vez POR
estación, nunca N PRs simultáneos en la MISMA estación). Los PRs con migraciones NO son la
excepción: no se resuelven con un lock, un protocolo async de tokens, un árbitro humano con
handoff bilateral, una excepción de urgencia tipo GO-del-lead, un merge-ahora/apply-después,
fijando una sola estación como aplicadora, ni tratando slots distintos como aplicables en
paralelo sin más (los siete fallaron auditoría o no describían lo que la fábrica hace — rondas
5-13) — la Management API no tiene equivalente al `strict=true` de GitHub.
**CUALQUIER estación (M1-M5) mergea Y aplica**, como una sola operación indivisible en el
mismo turno (ref 01 §2,
ratificado por el CEO en la ronda 12, `CEO-DOCTRINA-MIGRACIONES-5-ESTACIONES`); el token
`SLOT-CLAIM` sobre el flock compartido evita que dos migraciones compartan número de slot, y el
gate `APPLY-RUN`/`APPLY-DONE`/`APPLY-FAILED` (mismo flock; gana el PRIMER RUN tras el último
cierre válido — nunca el más reciente, ronda 15) serializa la EJECUCIÓN de PROC-M13 — que
aplica el gap COMPLETO `main − ledger`, no solo "mi slot", así que slots distintos NO pueden
ejecutarse en paralelo (ref 01 §2, ronda 13). Un wrapper EXTERNO protege TODA la secuencia
con `set +e`/`set -e` (leer `PIPESTATUS[0]` ANTES de reactivar `-e` — reactivarlo antes lo
pisa a `0` igual que un `|| true`, ref 01 §2; y ni siquiera evitar `pipefail` basta si `tee`
falla por su cuenta) y publica el cierre por código de salida con su categoría YA calculada
leyendo `PROC_M13_CLASS_FILE` — NUNCA `$LOG`, que puede traer un cuerpo HTTP remoto
interpolado y forjable (ronda 20, BLOQUEANTE); PROC-M13 declara su propia clase con un
literal fijo en ese canal estructurado — `exit 0` → `APPLY-DONE`, cualquier otro código →
`APPLY-FAILED ... <CATEGORIA>` ∈ TRANSITORIO/ESCALAR (nunca DEFECTO automático), durable en
el flock (ronda 19) — sin adivinar la fase del fallo. La recuperación NO es siempre
"migración nueva" (ronda 17): una lectura TRANSITORIA (token, Vault, `fetch_ledger`,
advisors — solo consulta, sin mutación en vuelo) solo pide corregir la causa y publicar un
`APPLY-RUN` normal; el POST que SÍ muta, Paso 1 de contenido (una migración nueva no
desbloquea una pendiente rota), divergencia, drift, advisors con `nerr` real, o cualquier
fallo sin `class` explícito (default fail-closed) ESCALA a CEO/Orquestador con una Señal de
quiescencia REAL — consulta a `pg_locks` sobre el ledger vía el mismo endpoint que
`fetch_ledger`, nunca una ventana de tiempo del cliente (ronda 19: dos lecturas separadas por
el `--max-time` del cliente no prueban nada del servidor). PROC-M13 adquiere ese lock
EXPLÍCITAMENTE tras `begin;`, ANTES del DDL (ronda 20, BLOQUEANTE: antes solo se adquiría en
el `insert` final, así que un DDL largo en curso podía leer lock-count `0` con la mutación
viva) — pero conteo `0` NO demuestra que ningún POST esté a punto de pedirlo (ronda 21,
BLOQUEANTE: `pg_locks` solo ve lo YA solicitado); el cierre real es revalidar DENTRO DE LA
MISMA TRANSACCIÓN, tras el lock y antes del DDL, que la versión sigue ausente — un retry que
gane el lock DESPUÉS de un POST antiguo se aborta solo al encontrarla ya aplicada, sin
repetir el DDL — antes de decidir; DEFECTO CONFIRMADO solo se alcanza SI esa investigación confirma
que la terna `schema`+`name`+`type` de `.metadata` (fail-closed si falta alguna) del objeto
flageado por advisors coincide con un objeto que el investigador LEE en el `.sql` aplicado
(paso humano, no un regex — ronda 20, MAYOR) — recién entonces exige publicar
`APPLY-RECOVERS` con
identidad verificada (SHA de merge real vía `gh pr view <PR>` SIN `#`, ancestría, diff que
AÑADE por `status` con `--paginate` y check fail-closed un fichero en
`supabase/migrations/`, HANDOFF que cite el PR fallido), nunca un
`git log --since` a solas (ref 01 §2, tabla de recuperación).
Una colisión de slot se resuelve renumerando al siguiente
libre, no rebotando a una estación fija.

**RUTA APAGADA (fail-closed)** — ruling `CEO-RULING-MAJOR4-T05-BATCHING-OFF-PARALELA-NO-ES-BATCHING-1625`:
el batching está **DESACTIVADO** y **cada PR corre su suite COMPLETA sobre su head**; lo que
sigue describe la ventana, **no autoriza saltarse una suite**. **La escritura sobre `main` es serializada** —no se funden dos cosas a la
vez— pero eso **no es «un solo PR por turno»**: dentro de una **ventana** abierta sobre el mismo tip,
las piezas verdes con ficheros **disjuntos** de las ya fundidas se funden **una tras otra, cada una
con su suite COMPLETA sobre su propio head**. La exención de suite que esta línea prescribía es la
ruta APAGADA: queda **registrada** como lo que la vía preveía, y **no es operable**
(ley y literal: `references/10-estaciones-en-paralelo.md`). La preparación (pasos 2-6) puede avanzar
en paralelo para varios PRs.

**Cola Dependabot (detalle de estación; doctrina canónica T10 en `talent-orchestrator`
ref 06)**: los PRs de Dependabot no traen HANDOFF ni pasan por la 1ª estación — se triagean
por el DIFF (no por el título: los group-bumps mezclan severidades). Grupo con parche de
seguridad → prioridad de merge, NUNCA cerrar; major sin seguridad → cerrar-con-nota (vuelve
como issue curada); build-break por `pnpm.overrides` desync → fix de 1 línea en el lockfile
dentro del propio PR. **Gotcha del hand-commit**: commitear a mano en una rama `dependabot/*`
puede romper la excepción POR ACTOR de `validar-rama-pr.sh` (según la implementación del gate:
el workflow de referencia clava en el AUTOR del PR — estable —, pero un gate que evalúe al
actor del push falla) → si `branch-name` se pone rojo tras el hand-commit, es **falso positivo**:
diagnóstico + resolución trazada (motivo + SHA + quién), no forzar ni renombrar la rama.

**Pre-claim grep (anti-doble-intake)**: antes de TOMAR un PR concreto,
`command grep -E "(CLAIM|BOUNCED) #${pr}([^0-9]|$)" "$TM_FLOCK_CANONICO_TRUSTED"` — si el PR aparece como
`BOUNCED` o `CLAIM`ado por otra estación, NO procesar (ref 01 §2).

**Y es `$TM_FLOCK_CANONICO_TRUSTED`, no «un flock» (ronda 32, MAYOR)**: este grep existe para impedir el
doble intake, y **sobre un espejo con lag no lo impide** — el `CLAIM` de otra estación puede estar
publicado y no haber llegado a la copia. Correrlo sobre cualquier fichero que se le pase da un
verde que **no significa «nadie lo ha tomado», sino «no lo he visto»**. La ruta la **declara el
anexo por repo** y se acredita con `flock_acreditado` (`apply-gate.sh`), que compara por FICHERO
—mismo dispositivo e inodo— y no por cadena. **Sin declaración no hay intake**: fail-closed.

**PR duplicado/stale de una issue ya mergeada** → fence **PROC-M20** (ref 05): NO rebasar,
escalar superseded-vs-residual.

## 2. Validación del HANDOFF (PROC-M01)

```bash
bash scripts/verify-handoff.sh <pr>    # desde la raíz del repo — fail-closed
```

El contrato completo (secciones + bloque machine-readable) vive en
`docs/templates/handoff-pr-draft.md` — este skill NO re-lista los campos.

### PROC-M01 — Entrega inválida (rechazo del draft)

**Cuándo**: `verify-handoff.sh` != 0 · HANDOFF ausente/stale · superficie declarada de
menos (ref 03 §4) · destructiva no declarada (ref 03 §5).

1. NO procesar el PR (no rebase, no CR — no gastar bucket en entregas inválidas).
2. Comentario de rechazo en el PR: qué check falló (salida del script) + puntero a la
   plantilla. El PR queda en draft.
3. Aviso al coordinador de la 1ª estación (su regla 13 debió atraparlo antes de reciclar
   el canal): el arreglo del HANDOFF es de la 1ª estación — texto/bloque del comentario se
   puede re-emitir sin canal (es un comentario), pero cambios de CÓDIGO exigen su pipeline.
4. Registrar el rechazo (métrica del piloto: % drafts rechazados en intake).

**Ventana de gracia del draft recién nacido** (regla dura 7, 2026-07-28): un
`verify-handoff.sh` en FAIL durante el primer ~minuto de vida del PR **NO es entrega
inválida**: es una **carrera** con el comentario del HANDOFF, que se publica DESPUÉS de
crear el draft. **Re-verificar con espera acotada antes de rechazar** (sondeo cada ~20s
hasta ~3 min); solo si sigue en FAIL al agotarla se aplica PROC-M01. Evidencia: #1404 se
creó a las 15:38:34Z; `verify-handoff.sh` dio FAIL a los 12s y **VÁLIDO a los 40s** —
rechazarlo en el primer intento habría sido un falso PROC-M01 con rebote y ronda perdida.

### Re-stamp del HANDOFF por la estación (Ev #942/#885)

Cuando el head cambió por acción de la PROPIA estación (rebase, renumeración) y el canal ya
está reciclado, la estación re-estampa el HANDOFF ella misma:

- **`gh api -F body=@<fichero>`** — NUNCA `-f body=@<(...)`: el `-f` manda el literal
  `@/dev/fd/63` como body (no expande process-substitution) y **corrompe el comentario**.
- Con **múltiples comentarios HANDOFF**, `verify-handoff.sh` reconcilia contra el **ÚLTIMO**
  (el más reciente con bloque JSON válido) → re-estampar siempre el VIGENTE y con los
  **valores REALES** del head/slots actuales (un re-stamp con valores copiados del viejo
  reintroduce el stale que se quería arreglar).
- Tras el re-stamp: `verify-handoff.sh <pr>` == 0 de nuevo (poll si tarda en reconciliar).

**Un re-stamp actualiza IDENTIDAD, nunca EVIDENCIA HISTÓRICA** (regla dura 18, 2026-07-28):
compañera exacta de la distinción de arriba — PROC-M01 (stale-de-fábrica → rechazo) dice
CUÁNDO re-estampar; esta dice QUÉ se puede tocar al hacerlo. El campo `head_sha` del
bloque machine-readable **se actualiza** (es identidad). **Cualquier afirmación de
EVIDENCIA que el canal hizo sobre SU commit se conserva verbatim** (es una medición);
reescribirla con un head que el canal nunca validó produce un HANDOFF que afirma algo que
nadie comprobó — la evidencia sobre el head nuevo la aporta la estación por separado (su
propia suite + su propia corrida de CR), no falsificando la del productor. Procedimiento:
(1) localizar TODAS las ocurrencias del sha viejo (`grep -n`) antes de sustituir, nunca a
ciegas; (2) clasificar cada una: ¿campo de identidad (se actualiza) o afirmación de
evidencia (se conserva)?; (3) sustituir SOLO las de identidad; (4) declarar en la nota del
re-stamp qué se tocó, qué no, y dónde vive la evidencia del head nuevo. Aplica igual a
otras identidades del bloque (p. ej. renumeración de `migration_slots`). Evidencia
(2026-07-28): PR #1407 (`head_sha` `b76e6b5c…`→`abfa5cb3…`, 1 sola ocurrencia del sha viejo,
solo el campo) vs PR #1409 (`7dce2bb8…`→`4f9b31f2…`, 2 ocurrencias — campo + la afirmación
*«AC-5: los 7 gates … exit 0 sobre `7dce2bb8`»*, que se dejó INTACTA). Un `sed` global del
sha viejo habría "arreglado" el verificador y roto la verdad del documento.

## 3. Rebase sobre main

Todo PR se rebasa sobre `main` fresco antes de CR (el review debe ver el diff real contra
el estado que va a recibir el merge):

```bash
git fetch origin main && git checkout <rama> && git rebase origin/main
```

- **Conflictos mecánicos** (imports, vecindad, renames): los resuelve el canal de
  refactorización del Mergeador como micro-encargo (ref 05) — el auditor verifica que la
  resolución no toca los invariantes del HANDOFF.
- **Conflictos de DISEÑO** (el rebase invalida decisiones del plan: otra rama pisó el
  mismo dominio con otra semántica): → bounce-to-pool (PROC-M16, ref 05).
- El push post-rebase cambia el head → **re-emitir el HANDOFF COMPLETO (las 9 secciones en
  el MISMO comentario)**, no solo el bloque machine-readable: `verify-handoff.sh` exige las 9
  secciones canónicas en el comentario que gana (el más reciente con bloque JSON válido); un
  comentario json-only NO valida (verificado en #819). Re-correr `verify-handoff.sh` tras
  re-emitir (gotcha 6 del SKILL.md). El push del canal de refactorización usa su propio
  `draft-handoff.sh` (gates locales verdes) — la exención draft aplica igual en la estación.
- **Ramas que predatan #827 (pr-gate viejo)**: GitHub lee el workflow del **head del PR** →
  una rama con el `pr-gate.yml` viejo **re-dispara toda la Puerta PR al flip a ready**
  (espera muerta; visto en #818/#819). Rebasar sobre `main` **ANTES** de flip ready trae el
  `pr-gate.yml` corregido (el rebase corre CI una vez por `synchronize`). Alternativa: si la
  rama es trivial, absorber el re-trigger de una sola vez. (Post-TAL-2241/#827 el flip a
  ready ya NO re-dispara.)
- **Carrera de main durante el drain** (el propio Mergeador avanzando en paralelo): `main`
  puede moverse ENTRE el rebase y el gate → un gate transitorio "behind origin/main" **NO es
  error**, es serialización normal. Reintentar el rebase/gate, no escalar (ref 06 §1). El
  coordinador de la 1ª estación que vea "behind origin/main" transitorio también reintenta.
- **Orden obligatorio con `strict=true` y cola viva** (regla dura 12, 2026-07-28 — con M1-M5,
  TAL-5170: esta disciplina se aplica DENTRO de cada estación individual, no como un único
  slot global — cada una de las 5 corre su propia instancia de este orden en paralelo con las
  demás, nunca dos PRs a la vez EN LA MISMA estación):
  `update-branch` (head LOCAL de la estación — **especulativo por definición, nunca
  "asentado"**, ver por qué abajo) → **CR y suite EN PARALELO** sobre ESE head → **merge**.
  **RUTA APAGADA (fail-closed)** — ruling `CEO-RULING-MAJOR4-T05-BATCHING-OFF-PARALELA-NO-ES-BATCHING-1625`: el batching
  está **DESACTIVADO** y **cada PR corre su suite COMPLETA sobre su head**; la frase que sigue
  describe la ventana, **no autoriza saltarse una suite**.
  **Un merge cada vez** —la escritura es serializada—, que no es lo mismo que un PR por ventana:
  varias piezas **disjuntas** pueden fundirse en la misma ventana, una tras otra, **cada una con su
  suite COMPLETA**. La exención que esta línea prescribía pertenece a la ruta APAGADA de arriba:
  registrada, no operable.
  Un PR cada vez POR ESTACIÓN.
  El head de un PR que NO está en el slot de SU estación es **PROVISIONAL por
  definición**: con `strict=true`, cualquier merge ajeno lo deja BEHIND, el `update-branch`
  le cambia el `sha`, y toda evidencia de Gate 1 atada al head viejo deja de valer. **El head
  local no basta**: la condición es SER EL SIGUIENTE del slot — un head que hoy no está
  behind se vuelve obsoleto en cuanto funde cualquier otro PR (con cola viva, eso es lo
  normal). **Con M1-M5 en paralelo, "`main` no se va a mover antes" NO es una condición
  verificable por una estación individual** (corregido tras auditoría — cualquiera de las
  otras 4 puede moverlo en cualquier momento, sin aviso previo a esta): la precondición real
  para adelantar CR es únicamente **ser el siguiente del slot de TU PROPIA estación** —
  adelantar CR sobre esa base es **SIEMPRE especulativo por diseño**, nunca condicionado a una
  promesa de estabilidad de `main` que ninguna estación puede dar sola. El tiempo muerto se
  llena primero con lo que NO caduca (intake, clasificación de superficie, verificación de
  HANDOFF); CR adelantado es la SIGUIENTE prioridad, asumido como gasto especulativo que puede
  perderse — no una apuesta a que main se quedará quieto. **Con `strict=true` el segundo
  SIEMPRE pierde su CR** — el desperdicio es 1 en cualquier orden; lo que cambia es de quién.
  **El scoping por estación (M1-M5) NO produce ningún head globalmente asentado**:
  `main` sigue siendo GLOBAL a las 5 — "ser el siguiente del slot" es una condición LOCAL a la
  propia estación, no un arbitraje global de quién es el siguiente merge real; un merge de
  CUALQUIERA de las 5 invalida por igual la preparación en vuelo de las otras 4, exactamente
  el mismo "cualquier merge ajeno" del párrafo anterior, ahora con 5 fuentes posibles en vez
  de 1. El scoping por estación solo evita que la MISMA estación prepare 2 PRs simultáneos
  (desperdicio interno); no protege ni pretende proteger contra la invalidación cross-estación,
  que sigue sin
  excepción las reglas de arriba. Criterio de prioridad de cola: va primero quien **menos
  evidencia VÁLIDA destruye** (lo pagado y cierto, nunca lo pendiente e incierto) — una suite
  YA LANZADA es
  un compromiso, abortarla a mitad destruye más que cualquier CR. Un CR adelantado no se
  pierde entero: su valor de GATE (atado al sha) muere al cambiar el head, pero su valor de
  CONOCIMIENTO (¿el contenido está limpio?) sobrevive un `update-branch` (no cambia el diff).
- **Worktree stale (Ev #942)**: si la estación opera el PR en un worktree propio, verificar
  ANTES de cualquier operación que `HEAD` del worktree == `headRefOid` del PR — un worktree
  de una ronda anterior rebasea/gatea el árbol EQUIVOCADO en silencio. Ante divergencia:
  **recrear el worktree limpio** desde origin, no "arreglarlo".
- **Secuencia sellada para worktrees — EXPECTED_OID [M4]#1162**: capturar
  `EXPECTED_OID=$(gh api repos/{owner}/{repo}/pulls/<n> --jq .head.sha)` → `git worktree add`
  DESDE ese commit (`origin/<branch>` explícito o commit-ish, JAMÁS la rama local stale) →
  assert `HEAD == EXPECTED_OID` → relectura INMEDIATA antes del push →
  `git push --force-with-lease=<rama>:$EXPECTED_OID`. Un force-push desde worktree stale
  DROPEA commits del autor (ev #1162: 2 dropeados y recuperados).
- **Diagnóstico n — conflicto en rebase**: antes de resolver un conflicto sobre un fichero,
  correr `git log origin/main -- <fichero>`. Si un hermano reescribió ese fichero con OTRA
  semántica y mergeó DESPUÉS de la base del PR → conflicto de DISEÑO → bounce (ev
  #1170×#1127). No resolver el conflicto: hacer bounce.
- **Conflictos i18n al rebasar una rama behind (Ev F4 #257)**: en conflictos sobre
  `messages/*.json`, tomar el **lado de main** como base y re-aplicar SOLO las claves
  propias del PR; validar al cerrar: **0 marcadores de conflicto**, **JSON válido**
  (`jq . messages/*.json`), y las **claves propias intactas** en los tres locales. Un
  merge "a ojo" de estos ficheros rompe `i18n:check` o pierde claves ajenas.
- **Date-bombs (TAL-5170)**: un fixture que sale **verde HOY** no es robusto a la fecha de
  ejecución del gate — un test con una fecha hardcodeada, un rango relativo mal anclado, o un
  "vence en N días" calculado contra `Date.now()`/`now()` del momento de escribirlo puede
  ponerse rojo semanas después sin que nadie tocara el código. Ante un rojo sin relación con
  el diff del PR: verificar si la causa es una fecha vencida ANTES de asumir flake o
  regresión real (PROC-M19, §9). El fix correcto ancla el fixture a `now()` en tiempo de
  ejecución o delega la validación temporal al gate downstream — nunca una fecha futura fija
  que solo pospone el mismo problema.

## 4. Slots de migración

Si `migration_slots` no está vacío: renumerar contra el **ledger real de prod** ANTES del
slot de merge (doctrina en ref 06; mecánica exacta en anexo PROC-M14). `destructive: true`
→ GO del lead ANTES de seguir (regla dura 7).

## 5. CodeRabbit CLI (budget-aware)

```bash
bash scripts/cr-review.sh    # desde el clon del canal del Mergeador (auth per-canal)
```

- Salidas: **limpio** (sentinel `ok`) → paso 6 · **findings** → protocolo de desempate
  flip-flop (≥2/3 reproducible) ANTES de refacto (ref 04 §1); refacto → ref 05 (NUNCA
  fallback al App por findings — gotcha 8) · **rate-limit/error** → ruta B (fallback).
- **Ramas legacy (predatan #830)**: overlay sin commitear de `cr-review.sh` desde main antes
  de correr CR (persiste el JSONL de findings) — receta en ref 04 §2.
- Escalera de doble identidad, programación contra el bucket y taxonomías de fallo: ref 04.

## 6. Rutas A/B

**El CLI limpio AUTORIZA el merge** (ruling del lead 2026-07-08): con aprobación CLI no se
gasta review del App — nunca, en ninguna superficie. Clasificación de superficie
verificada contra el diff (ref 03; gobierna cuidado operativo, no la ruta).

| Ruta | Condición | Secuencia |
|---|---|---|
| **A** | CLI limpio (CUALQUIER superficie) | confirmar SIN label `cr-review` (borrar el heredado si existe: `gh api -X DELETE .../issues/<n>/labels/cr-review` + re-lectura) → `gh pr ready <pr>` → gates AND (§7) → merge. Cero consumo del bucket App |
| **B (fallback)** | CLI `deferred`/caído — única situación que gasta App | label `cr-review` por REST verificado (ref 04 §5) **ANTES** de `gh pr ready` → disparo explícito `@coderabbitai review` → **APPROVED@head** → gates AND → merge; sin acuse en ~2-3 min o rate-limit → **cambio de usuario** (escalera, ref 04 §1); 4 buckets agotados → PROC-M18 |

La **escalera de doble identidad** (ref 04 §1) es el método canónico cuando una identidad se
degrada: CLI-A → App-A → cambio de usuario (CLI-B → App-B) → PROC-M18. Los `findings` NUNCA
bajan la escalera (van a refacto); el descenso es por SEÑAL, no por reloj.

## 7. Gates AND del merge (comandos por gate)

Los CUATRO gates, verificables por API, fail-closed. Se corren INMEDIATAMENTE antes del
merge (no valen fotos de hace una hora).

```bash
PR=<n>
STATE="$(gh pr view "$PR" --json mergeStateStatus,headRefOid,reviews,statusCheckRollup,labels)"
HEAD="$(jq -r '.headRefOid' <<<"$STATE")"
```

**Gate 1 — Evidencia de review** (una de las TRES vías — la formulación previa listaba
solo dos; la 3ª vía es code-audit adversarial GO donde no hay CodeRabbit — TAL-2286):

```bash
# Vía CLI (ruta A — la normal). La evidencia se verifica contra el ledger append-only
# .claude/.cr-review-history.jsonl (un registro por corrida), buscando por sha EXACTO —
# NUNCA contra .claude/.cr-review-result.json, que es UN SOLO SLOT que cualquier corrida
# posterior PISA (regla 10, 2026-07-28): solo es válido si el merge ocurre INMEDIATAMENTE
# después de su propia corrida, sin ninguna otra revisión ni rebase en medio. Copia de
# respaldo por corrida (regla 19, fuera de /tmp — ver ref 08 §backup): `<sha>` es la clave,
# no el número de PR (un mismo PR tiene varios heads si se actualiza).
jq -e --arg h "$HEAD" 'select(.sha==$h) | .state=="ok" and .finding_count==0' \
  .claude/.cr-review-history.jsonl
# El fichero de un solo slot NUNCA es la fuente; a lo sumo una nota adicional en el mismo turno.

# Vía App (SOLO ruta B de fallback, cuando no hay aprobación CLI):
# el ÚLTIMO review del App @head exacto es APPROVED (el APPROVED puede voltearse — gotcha 4).
jq -e --arg h "$HEAD" '[.reviews[] | select(.commit.oid == $h)] | last | .state == "APPROVED"' <<<"$STATE"

# Vía C — code-audit adversarial GO (SOLO con revisor=code-audit, TCO_REVISOR): el GO del auditor
# adversarial sobre ESE sha exacto autoriza el merge. merge-gate.sh lo exige archivado en el PR y
# lo comprueba con el verificador (fail-closed: otro SHA, otro run_id, NO-GO, ausente, autor ajeno,
# futuro o caducado = «no»). Con revisor=coderabbit el GO NO sustituye a CodeRabbit.
bash .claude/skills/talent-channel-operation/scripts/verify-code-audit-go.sh "$PR" "$HEAD"   # yes <run_id> | no <motivo>
```

El registro lo publica el coordinador del canal con
`verify-code-audit-go.sh --archivar <pr> <canal> <literal>` sobre el commit que será el head
(solo si el último gate del canal fue de tipo `code` y el literal re-verifica como GO). La salida del
gate es `M8=yes via=code-audit run_id=…`. **⚠ Vía NO recomendable**: sin capa externa de revisión,
C1 administra Incus, desarrollador y auditor comparten usuario y el veredicto no lleva firma
verificable de autoría; la mitigación es CodeRabbit.

**Waiver del lead como excepción trazada** (regla dura 4 SKILL.md — NO es una 4ª vía de
este Gate): cada uso exige, escrito en el PR ANTES del merge, los tres campos —
**motivo · SHA exacto · quién autoriza**. Sin los tres campos el waiver no autoriza nada, y
un waiver previo (p.ej. #1400) **no sienta precedente** para el siguiente PR.

**Gate 2 — `local-gates=success` @head + corrida PROPIA** (TAL-2286/TAL-2288; sustituye
al "required checks de Actions verdes" — el required check canónico vive en
`scripts/setup-branch-protection.sh`, hoy solo `local-gates`):

```bash
# (a) El commit-status local-gates @head EXACTO es success
gh api "repos/{owner}/{repo}/commits/$HEAD/status" \
  --jq '.statuses[] | select(.context=="local-gates") | .state' | grep -qx "success"

# (b) Verificación de que la corrida es PROPIA (anti-self-report, ref 08 §6):
#     el run_group/receipts de ese head existen en el registro de la estación —
#     un status que la estación no puede casar con receipts sellados propios NO es
#     evidencia (podría ser un post ajeno o un break-glass sin traza) → FAIL.
```

El status lo produce SOLO `talent-factory/scripts/post-local-gates.sh` (agregación de
receipts de runners sin credenciales, fail-closed — ref 08 §5). Rojo → tratar como gate
real: leer el receipt FAIL (razón + log protegido del runner), refacto (1 ronda → 1
re-run), nunca bypass. `local-gates-test` es el contexto de rollout/dry-run: NO satisface
el gate. **Un PR skills-only NO reduce el conjunto de gates** (no hay fast-path por
contenido del diff — ref 08 §8); un avance de main entre gate y merge solo se absorbe por
la excepción ACOTADA de base_tip (ref 08 §8), nunca por defecto.

**El Gate 2 se lee por CONTEXTO, nunca del agregado** (regla dura 11, 2026-07-28): `.state`
de `/commits/<sha>/status` es un ROLL-UP de los statuses PRESENTES — vale `success` aunque
el contexto requerido **no exista**, si hay cualquier otro status verde. El comando de
arriba ya filtra `select(.context=="local-gates")` por esta razón; queda **PROHIBIDO**
leer el Gate 2 tomando el campo `.state` del endpoint de status directamente, sin ese
filtro de contexto. **Ausente ≠ pendiente ≠ rojo**: los tres
se tratan como **NO aprobado**. Evidencia (2026-07-28, PR #1405 con su suite aún corriendo):
un head tenía un único status — `context=CodeRabbit`, `state=success`,
`desc="Review skipped: excluded by label configuration"` — y `local-gates` AUSENTE; el
roll-up decía `success`. Un Gate 2 leído del agregado habría aprobado un PR con CERO gates
corridos, avalado por la misma señal débil que la regla dura 4 ya prohíbe como evidencia.

**Gate 3 — Spot-check de disjunción / hot-files**: los archivos del PR contra lo mergeado
desde su branch-point y contra los OTROS PRs en preparación (hot-files del anexo:
`next.config.ts`, `proxy.ts`, `messages/*.json`, `.env.example`, `globals.css`…):

```bash
gh pr diff "$PR" --name-only | sort > /tmp/pr-files.txt
git fetch origin main --quiet
git diff --name-only "$(git merge-base origin/main FETCH_HEAD)"..origin/main | sort > /tmp/main-files.txt
comm -12 /tmp/pr-files.txt /tmp/main-files.txt   # solape con main ⇒ el rebase de §3 era obligatorio (¿se hizo sobre ESTE main?)
```

Solape en hot-file no resuelto por rebase fresco → volver a §3. Nunca mergear un PR
BEHIND con solape.

- **Bajo `branch protection strict=false`**: un PR mergea sin rebase **solo si sus archivos
  son DISJUNTOS** de lo mergeado desde su branch-point (`comm -12` vacío). El verificador de
  arriba es fiable para esto.
- **Secuenciación de hot-files** (con el merge serial de la estación): cuando varios PRs
  tocan cores calientes (p. ej. commerce: checkout-core, gateway cores), **ordenarlos** para
  que se mantengan disjuntos entre sí (mergear el core antes que sus dependientes) minimiza
  reconciles. La curación de la cola por hot-file la aporta el Orquestador; la estación
  respeta ese orden.
- **Guarda cruzada de invariantes entre encargos** (regla dura 13, ratificado por CEO
  `M2-GUARDA-4-SITIOS-Y-SELLO-OBSOLETO`, 2026-07-28): cuando un lote de encargos hermanos
  comparte un invariante de dominio (una fuente única de verdad, un cálculo que no debe
  duplicarse), este Gate se amplía: al fundir **cada PR posterior al primero del lote**,
  verificar el invariante **contra lo ya fundido en `main`**, no solo dentro del diff propio.
  Un invariante que cada PR cumple por separado puede romperse por la SUMA (caso real: una
  gracia de 72 h aplicada en dos capas ⇒ 144 h efectivas). El lote y su invariante se
  declaran al intake del primer PR y se arrastran hasta el último.

**Gate 4 — Slot de migración sin colisión** (solo PRs con migraciones): el slot declarado
sigue libre en ledger + `main` + los drafts en preparación de la propia cola (anexo
PROC-M14; gotcha 7). Check automatizado (TAL-2273): `bash scripts/crosscheck-migration-slot.sh <pr>`
cruza el slot del HANDOFF contra el diff (detecta inmutabilidad rota, nombre malformado,
timestamps duplicados) y contra el tope `ledger ∪ origin/main ∪ drafts`. **Exit `0`** = Gate 4 verde
(`gate_valid:true` en el `SUMMARY`); **`3`** = renumerar (PROC-M14, NO defecto); **`1`** = integridad
rota → bounce; **`2`** = precondición (token/ledger/enumeración) → fail-closed, no declarar el gate.
Los modos `--no-ledger`/`--no-queue` son diagnóstico (`gate_valid:false`), NO válidos para el gate.

**Además**: `mergeStateStatus == "CLEAN"`. Tras `gh pr ready` el mstate pasa por **UNSTABLE
~5 s** (recompute) aunque los 4 required estén verdes (visto en #833/#829) → **no mergear
sobre UNSTABLE**: esperar ~5 s y re-leer; mergear solo sobre CLEAN (evita falsos NO-GO y
`--admin` innecesario). Si `destructive: true`, el GO del lead registrado. Cualquier gate
ambiguo = FAIL → diagnosticar (Playbook), jamás "probar a mergear".

## 8. Merge + post-merge + Done

**Si el PR trae `supabase/migrations/*`, el gate `APPLY-RUN` se RECLAMA antes de mergear — no
basta comprobarlo**: un releer-y-luego-mergear sigue siendo check-then-act sin reserva, y dos
estaciones pueden ver el gate libre y mergear las DOS. El claim cubre TODA la ventana
merge→pull→apply como reserva única, no el instante de invocar PROC-M13. Contrato normativo
completo en SKILL.md «Checklist de vuelo §7», ref 01 §2 punto 4 y ref 06 §1.

```bash
set -euo pipefail        # sin esto, una precondición rota NO aborta y el merge sigue adelante

# La receta CARGA lo que invoca. Un comentario que remita a ref 01 no crea alcance de función en
# Bash: sin este `source`, `publish_close` es `command not found` con el APPLY-RUN ya abierto
# (par8-p1, BLOQUEANTE).
#
# LO ACREDITADO Y LO EJECUTADO SALEN DE UNA SOLA LECTURA, Y SU EQUIVALENCIA SE DEMUESTRA.
#
# Y la equivalencia se nombra CON EXACTITUD, que es donde este bloque ya falló: el artefacto son
# 5744 bytes y la cadena que recibe `eval` son 5743 — difieren en el salto final que `$(…)`
# descarta y que Bash ignora como terminador. Decir «los mismos bytes» era, otra vez, afirmar de
# más sobre el mecanismo (par15-p1, MAYOR). Lo cierto y lo comprobado en cada ejecución es esto:
# **lo evaluado, más los N saltos finales recortados, reconstruye byte a byte el artefacto
# acreditado** — y si no lo reconstruye, no se evalúa nada.
#
# QUÉ SE ACREDITA: **los bytes del artefacto, tal cual**. Sin normalizar, y sin un segundo nombre
# para el mismo hash. La versión anterior de este bloque leía el fichero a una variable con
# `$(cat …)` y hasheaba eso llamándolo «los mismos bytes», y era FALSO (par11-p1, MAYOR): Bash
# descarta los NUL y elimina TODOS los saltos finales, así que el fichero canónico, ese mismo sin
# salto final, con un salto de más y con un NUL añadido tienen sha256 distintos y producían el
# MISMO digest. Un hash que no identifica lo que dice identificar no acredita nada, por muy fija
# que sea el ancla. Y el intento intermedio de rebautizarlo «cadena canónica» tapaba el síntoma
# sin cerrar el hueco: si hay que normalizar para otra cosa, ese es OTRO hash con OTRO nombre.
#
# Por eso el artefacto se lee UNA sola vez a memoria: de esa lectura salen el sha de los bytes
# crudos y la cadena que se evalúa. Ningún fichero se vuelve a abrir, así que no queda instante
# en el que un tercero pueda cambiar lo que se va a ejecutar.
#
# Este bloque ya falló DOS veces por acreditar un PROXY de lo que corre:
#   · par9-p1: se comprobaba que el `source` hubiera ido bien — el HECHO de cargar, no el QUÉ.
#     Una biblioteca vacía, truncada a una función o sustituida por `TM_GATE_LIB` reservaba igual.
#   · par10-p1: se comparaban DOS `declare -f` y después se cargaba UN PROGRAMA. Lo acreditado y
#     lo ejecutado no eran el mismo objeto: una candidata con los dos cuerpos canónicos MÁS un
#     `readonly FLOCK_FILE=…` de nivel superior pasaba la comparación y redirigía el recurso
#     compartido — el APPLY-RUN acababa en OTRO flock y el previsto se quedaba sin RUN. Y la
#     acreditación EJECUTABA la candidata (un `source` en subproceso) para poder mirarla: si era
#     hostil, ya había corrido antes de que nadie la autorizara.
#
# La lección de las dos: mientras haya dos lecturas de la RUTA CANÓNICA —una para acreditar y
# otra para ejecutar— queda un hueco donde meter un objeto distinto. Eso está cerrado: la ruta
# canónica se lee una sola vez, y lo que se acredita y lo que se evalúa salen de esa lectura.
# Tampoco hay alcance parcial (se acredita el fichero ENTERO, comentarios incluidos) ni se
# ejecuta nada antes de acreditarlo: se decide sobre los bytes, no sobre el efecto de ejecutarlos.
# `TM_GATE_LIB` deja de ser sustituible por entorno: no hay más objeto que el canónico.
#
# LO QUE ESTO **NO** CIERRA, y hay que decirlo aquí y no en un acta:
#   · La ventana entre acreditar y ejecutar **ya no existe** — se eliminó quitando la segunda
#     apertura, no vigilándola. Se deja escrito porque una versión anterior de este comentario
#     afirmaba «no hay TOCTOU» cuando SÍ lo había (dos aperturas de un temporal), y peor: lo
#     justificaba diciendo que quien pudiera escribir ese temporal «no ganaba nada» por compartir
#     UID. Era falso. Al llegar ahí el ancla ya está en el proceso y editar los ficheros
#     versionados no cambia lo ejecutado, mientras que tocar el temporal lo cambia al instante y
#     **deja el árbol de git limpio**, esquivando revisión y ratchet. Misma capacidad, distinta
#     trazabilidad. La lección se queda aquí para que nadie reintroduzca el atajo.
#   · El ancla vive en el mismo repositorio que el fichero: esto cierra la sustitución por
#     ENTORNO, el alcance parcial y el prefijo inyectado, pero NO a quien pueda escribir el
#     repositorio y cambiar ambos. Eso lo cubren la revisión, el ratchet de `invariants.tsv` y
#     el historial de git — no este bloque.
TM_GATE_LIB='.claude/skills/talent-merger/references/apply-gate.sh'
TM_GATE_SHA='4ed209e5e566e37d09c4cdb298dbf1e8cbdf371edbd42502775bdbdd97b3b084'
# NO se materializa a un fichero: se lee UNA vez a memoria y se acredita y evalua ESA cadena.
# La version anterior copiaba el artefacto a un temporal, lo hasheaba y volvia a ABRIRLO para
# cargarlo — dos aperturas del mismo fichero, y entre ambas otro proceso del mismo UID podia
# reescribirlo: se ejecutaban bytes distintos de los comparados (par13/par14, BLOQUEANTE).
#
# Yo habia argumentado que esa ventana «no concede nada porque quien escriba el temporal comparte
# UID y podria editar el artefacto y su ancla». Era FALSO, y el porque importa: al llegar a ese
# punto el ancla YA esta cargada en el proceso y el artefacto YA esta leido, asi que editar
# los ficheros versionados no cambia lo que se ejecuta — mientras que tocar el temporal lo cambia
# de inmediato Y deja el arbol de git limpio, esquivando la revision y el ratchet. Misma capacidad
# Unix, trazabilidad distinta: no son rutas equivalentes.
#
# `base64` es lo que permite tener los BYTES en una variable: Bash no puede guardar NUL y recorta
# los saltos finales, pero su representacion en base64 es ASCII y sobrevive intacta. De ahi salen
# las dos cosas de UNA sola lectura: el sha de los bytes CRUDOS y la cadena que se evalua. Como no
# se vuelve a abrir NINGUN fichero, no existe instante en el que un tercero pueda cambiar lo que
# se va a ejecutar: el TOCTOU no se declara, se ELIMINA. Y sin temporal desaparecen tambien su
# limpieza y su ventana de senal.
# `-w0` es una extension de GNU coreutils: no existe en BSD/macOS ni en busybox, y ahi la receta
# aborta con «invalid option» ANTES de reservar — o sea, la puerta deja de funcionar entera en una
# maquina que no es la del autor. Es la MISMA clase que la ERE que `awk -v` destrozaba en busybox,
# cerrada en la v10 de este mismo tren: el arnes corre en contenedores, no en el portatil de quien
# lo escribio. Se separa en dos etapas —codificar y quitar los saltos— porque asi ninguna de las
# dos depende de una bandera no portable. El `|| { … exit 2; }` sigue cubriendo el pipeline entero
# bajo `pipefail`: si cualquiera de las dos etapas falla, NO se reserva.
_gate_b64="$(base64 < "$TM_GATE_LIB" | tr -d '\n')" \
  || { echo "no pude leer $TM_GATE_LIB: sin publish_close NO se reserva" >&2; exit 2; }
_gate_src="$(printf '%s' "$_gate_b64" | base64 -d)"   # exactamente lo que se va a evaluar
[ "$(printf '%s' "$_gate_b64" | base64 -d | sha256sum | cut -d' ' -f1)" = "$TM_GATE_SHA" ] \
  || { echo "$TM_GATE_LIB NO es el artefacto anclado (sha256 de sus bytes distinto): ABORTAR sin" \
            "reservar. Si el cambio es legitimo, actualiza el ancla y el ratchet en el MISMO commit" >&2; exit 2; }
# Lo unico que `$(…)` recorta de la cadena a evaluar son SALTOS FINALES. En vez de afirmarlo, se
# DEMUESTRA: se reconstruyen los bytes crudos como «lo evaluado + N saltos» y se exige que ESO
# hashee al ancla. Con un NUL, un salto de mas o sin salto final, la reconstruccion no cuadra y no
# se evalua nada. Asi «lo acreditado es lo que corre, salvo saltos finales que Bash ignora» es una
# propiedad COMPROBADA en cada ejecucion, no una promesa del comentario.
_n_dif=$(( $(printf '%s' "$_gate_b64" | base64 -d | wc -c) - $(printf '%s' "$_gate_src" | wc -c) ))
[ "$_n_dif" -ge 0 ] && [ "$( { printf '%s' "$_gate_src"; [ "$_n_dif" -gt 0 ] && head -c "$_n_dif" /dev/zero | tr '\0' '\n'; } | sha256sum | cut -d' ' -f1)" = "$TM_GATE_SHA" ] \
  || { echo "lo que se evaluaria NO reconstruye el artefacto anclado (la diferencia no son solo" \
            "saltos finales): ABORTAR sin reservar" >&2; exit 2; }
eval "$_gate_src" \
  || { echo "el artefacto anclado no evalua: sin publish_close NO se reserva" >&2; exit 2; }

CLAIM_GANADO=0
# UN SOLO trap de salida: dos `trap … EXIT` no se suman, el segundo SUSTITUYE al primero. El
# `CLASS_FILE` es SCRATCH hasta ganar el turno y EVIDENCIA despues; esa polaridad es la que
# protege `INV-ME-207`. Lo que NINGUN trap de espacio de usuario cubre es `SIGKILL` ni la perdida
# del host: eso se declara, no se finge.
trap 'if [ "${CLAIM_GANADO:-0}" -ne 1 ] && [ -n "${CLASS_FILE:-}" ]; then rm -f "$CLASS_FILE"; fi' EXIT

# ADQUISICIÓN VERIFICADA POR EJECUCIÓN (selftest T24): los controles negativos de
#   uuidgen/flock en rc=1 y de cierre ajeno corren contra ESTE fence, extraído de ESTE .md.
# 8.0) SOLO si el PR trae supabase/migrations/* — y ese «solo si» SE COMPRUEBA, no se comenta.
#      Antes esas dos líneas eran texto y el bloque reservaba SIEMPRE: un PR sin migraciones que
#      siguiera la receta al pie de la letra reclamaba `APPLY-RUN` —el gate de EJECUCIÓN de
#      PROC-M13, fleet-wide— para NO aplicar nada, serializando a las CINCO estaciones por un PR
#      que jamás va a tocar prod. Es la guarda T23 aplicada contra su propio autor: el predicado
#      mira COMANDOS EFECTIVOS, no cadenas; mencionar no es reclamar, y comentar no es comprobar.
#
#      La forma importa. `... | grep -c '^supabase/migrations/'` NO sirve aquí: bajo el
#      `set -euo pipefail` de arriba, `grep` devuelve rc=1 cuando no casa nada y `pipefail`
#      propaga ese rc, así que la receta ABORTARÍA justo en el caso sin migraciones que este
#      bloque existe para servir (medido: rc=1, y añadir `| wc -l` al final NO lo salva, porque
#      pipefail mira TODA la tubería). Con pathspec no hay grep: `git diff` devuelve rc=0 y una
#      lista vacía, y `wc -l` cuenta 0.
#      TRES ESTADOS, no dos. `N_MIG=-1` es INDETERMINADO y NO es lo mismo que cero:
#        · cero        → el diff se pudo calcular y NO hay migraciones  ⇒ no se reserva
#        · positivo    → hay migraciones                                 ⇒ se reserva
#        · -1          → NO se pudo determinar                           ⇒ SE RESERVA (fail-closed)
#      El fallo peligroso no es reservar de más —eso cuesta una serialización— sino NO reservar
#      habiendo migración: eso aplica a PROD sin turno. Por eso lo indeterminado reserva.
#      Dos formas de indeterminación, las dos medidas:
#        (a) el bloque se evalúa FUERA de un repo git (el arnés T24 lo extrae y lo ejecuta en un
#            `mktemp -d`): sin esta rama, `git` fallaba en la PRIMERA línea y el bloque entero
#            dejaba de ejecutarse — los casos que esperaban NO-MERGE seguían pasando por la razón
#            equivocada y sólo los de MERGE LOCK delataban que la guarda estaba muerta.
#        (b) `BASE_PR == HEAD` (PR ya fundido, `origin/main` fetcheado después): el diff sale
#            VACÍO siendo el PR portador de una migración. Un vacío DEGENERADO no es un vacío
#            legítimo, y leerlo como «no hay migraciones» se salta el gate justo cuando importa.
N_MIG=-1
if git rev-parse --git-dir >/dev/null 2>&1 \
   && BASE_PR="$(git merge-base origin/main "$HEAD" 2>/dev/null)" \
   && [ -n "$BASE_PR" ] && [ "$BASE_PR" != "$HEAD" ]; then
  N_MIG=$(git diff --name-only "$BASE_PR" "$HEAD" -- supabase/migrations | wc -l)
fi
if [ "$N_MIG" -eq 0 ]; then
  echo "PR #$PR sin migraciones ($N_MIG): NO se reclama APPLY-RUN — se salta a 8.1" >&2
elif [ "$N_MIG" -lt 0 ]; then
  echo "PR #$PR: NO se pudo determinar el diff de migraciones — se RESERVA igualmente (fail-closed)" >&2
fi
if [ "$N_MIG" -ne 0 ]; then
CLASS_FILE=$(mktemp) || { echo "mktemp falló" >&2; exit 2; }
# Hasta que el turno se gana, este fichero es SCRATCH, no evidencia — y TODAS las salidas
# anteriores al claim lo dejaban en el TMPDIR del operador (par9-p1, MAYOR): con una estación
# inválida la receta salía con rc=2, cero RUN y cero merge, y el inodo se quedaba. En uso
# repetido el goteo puede acabar tumbando el propio `mktemp` que protege el gate. Enumerar cada
# `exit` para limpiarlo sería volver a la lista de casos; la estrategia es ÚNICA y cubre TODAS
# las salidas pre-claim, incluidas las que se añadan después. Ganado el turno, la polaridad de
# `CLAIM_GANADO` desarma esa limpieza. El `trap` que lo hace se registra ARRIBA, junto al del
# artefacto del gate, porque un segundo `trap … EXIT` habría sustituido al primero.
export PROC_M13_CLASS_FILE="$CLASS_FILE"   # OBLIGATORIO (ref 01 §2): una variable NO exportada
                                           # no llega al hijo `bash proc-m13.sh`, y entonces un
                                           # fallo TRANSITORIO se clasifica como ESCALAR.
LOG="${LOG:-$CLASS_FILE.log}"   # canal durable que `publish_close` (ref 01) usa si el flock falla
RUN_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ) || { echo "date falló" >&2; exit 2; }
RUN_NONCE=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen) \
  || { echo "no se pudo generar el nonce" >&2; exit 2; }   # MISMA expresion que ref 01 paso 0:
     # `uuidgen` no existe en toda maquina, y a secas la receta abortaba antes de reservar nada.

# VALIDADOR CANÓNICO ÚNICO — fail-closed, ANTES del append. NO son cinco comprobaciones
# sueltas: es UNA función que solo acepta la forma canónica y rechaza TODO lo demás.
# Por qué existe: `set -e` solo cubre `rc != 0`. Un comando puede ACERTAR y devolver basura
# —`date` con rc=0 y salida vacía, `mktemp` con rc=0 y salida vacía, `ESTACION` sin
# valor— y entonces se publica `# APPLY-RUN [] …`, que es un token fuera de contrato: no se
# puede correlacionar ni cerrar. Validar el rc es medir un PROXY; lo que hay que validar es
# el VALOR.
# UN SOLO validador canónico, compartido por el PRODUCTOR y el PARSER. Dos validadores que no
# coinciden son peor que uno malo: decide el que pase primero. Estas cuatro ERE son la ÚNICA
# definición de «token canónico» y se le pasan al `awk` de abajo con `-v`.
# `[[]` y `[]]` en vez de `\[` y `\]`: esta ERE viaja al `awk` de abajo por `-v`, y `-v`
# PROCESA ESCAPES. Con backslashes, la implementación decide qué llega: mawk y nawk los
# conservan, pero `busybox awk` los BORRA y la ERE se convierte en `^[M[1-5]]$` — una
# expresión de corchetes que deja de casar una identidad válida. La consecuencia iba por el
# lado bueno (el parser hace `!~ RE_EST -> bloq(...)`: rechaza todo, fail-closed y ruidoso),
# pero la puerta dejaba de funcionar ENTERA en cualquier host con busybox — que es lo normal
# en Alpine, y la fábrica corre en contenedores. Sin backslashes no hay nada que procesar:
# el arreglo quita la CLASE en origen y no depende de qué awk haya, en vez de escapar para
# una implementación concreta. Se mantiene UNA sola definición, compartida con el `grep -E`
# del productor, que acepta la misma forma.
RE_EST='^[[]M[1-5][]]$'
RE_PR='^#[1-9][0-9]*$'
RE_ISO='^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$'
RE_NONCE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
# Autoridad que puede publicar un `APPLY-ESCALAR-GO`: SOLO CEO u Orquestador, nunca una estación
# (`RE_EST` es `M1-M5` y no cruza con ésta: son conjuntos disjuntos por construcción, que es lo que
# impide que el interesado se autorice). Mismas clases `[[]`/`[]]` en vez de `\[`/`\]`: viaja al
# `awk` por `-v` y `-v` PROCESA ESCAPES — busybox los borraría.
RE_GO='^[[](CEO|Orquestador)[]]$'

# `[[ =~ ]]` en vez de `printf … | grep -Eq …`, y el motivo NO es estético — se midió:
# `grep` ancla por LÍNEA, así que un valor con un `\n` EMBEBIDO cuya PRIMERA línea satisface la ERE
# PASA la validación. Medido: `HEAD='deadbeef\nbasura'` → `printf | grep -Eq` devuelve **0**, o sea
# ACEPTADO, y esa identidad se publica en el `APPLY-RUN` — un token multilínea dentro de un flock
# que se parsea por líneas. Con un payload GRANDE el mismo caso da 141 (SIGPIPE) y falla cerrado,
# que es benigno; el peligroso es el CORTO, que entra. `[[ =~ ]]` compara la cadena ENTERA, así que
# el `$` no se deja engañar por un salto interno, y de paso no hay tubería que pueda recibir
# SIGPIPE ni fork por campo. Medido: 11/11 casos, incluidos los tres de `\n` embebido.
identidad_canonica() {   # $1=CLASS_FILE $2=estación $3=PR $4=sello ISO $5=nonce $6=HEAD
  # LC_ALL=C EN ESTE ÁMBITO (B-02 v24, ronda 37, BLOQUEANTE — la 6.ª comparación): sin él,
  # `[[ "[$2]" =~ $RE_EST ]]` (la clase de estación M1-M5, definida UNA vez arriba) casa dígitos
  # unicode como `M٣`/`M²` bajo `en_US.utf8` (rango de COLACIÓN, no "dígitos 1-5") y una estación
  # FORJADA entra como identidad canónica —
  # el `awk` de abajo la rechaza tras el append, dejando un token fuera de contrato. Esta función
  # heredaba el `LC_ALL=C` del `export` del módulo `apply-gate.sh`, retirado en v23; ahora fija su
  # propio ámbito, como el resto. La enumeración COMPLETA la vigila el check T36 del arnés.
  local LC_ALL=C
  [ -n "${1:-}" ] && [ -f "$1" ] && [ -w "$1" ]                    || return 1
  [[ "[${2:-}]" =~ $RE_EST ]]                                      || return 1
  [[ "#${3:-}" =~ $RE_PR ]]                                        || return 1
  [[ "${4:-}"  =~ $RE_ISO ]]                                       || return 1
  [[ "${5:-}"  =~ $RE_NONCE ]]                                     || return 1
  # HEAD se valida AQUI, ANTES del claim: se expande despues en `gh pr merge`, y si falta, `set -u`
  # mata el shell CON EL TURNO YA GANADO y deja el gate huerfano por una precondicion local.
  [[ "${6:-}"  =~ ^[0-9a-fA-F]{7,40}$ ]]                            || return 1
  # El PRODUCTOR añade una comprobación MÁS sobre lo que él mismo crea: que el sello sea un
  # INSTANTE REAL, no solo una forma con rangos válidos — `2026-02-31T12:00:00Z` pasa los rangos
  # y no existe. Es un refuerzo del productor, NO una definición distinta: la forma canónica
  # sigue siendo la misma ERE que usa el parser (que valida forma, no calendario — declarado).
  #
  # SIN `date -d`, y el motivo se MIDIÓ (ronda 29, MAYOR): `date -u -d "<sello>"` es una extensión
  # GNU. En **BusyBox** —que es lo normal en Alpine, y la fábrica corre en contenedores— `date -d`
  # con este formato falla, así que la comparación NO cuaja ni para un sello VÁLIDO: la función
  # devolvía 1 SIEMPRE y el llamador hacía `exit 2`. **La adquisición no se podía completar NUNCA.**
  # Falla CERRADO —no es un agujero de datos— pero la receta NO CORRE en ese entorno, que es una
  # indisponibilidad total, no una degradación. Es la MISMA clase que la ERE con backslashes que la
  # ronda 25 quitó de `-v`: no se escapa para una implementación concreta, se quita la dependencia.
  #
  # El calendario se valida por ARITMÉTICA, que no depende de ninguna implementación de `date`.
  # La ERE de arriba ya garantizó la FORMA (mes 01-12, día 01-31), así que aquí solo queda el
  # único caso que la forma no puede decidir: si ESE día existe en ESE mes de ESE año.
  local _y _m _d _max
  # `10#` es OBLIGATORIO: sin él, `08` y `09` se leen como OCTAL y `$((...))` aborta con
  # «value too great for base» — dos meses del año romperían la adquisición.
  _y=$((10#${4:0:4})); _m=$((10#${4:5:2})); _d=$((10#${4:8:2}))
  case "$_m" in
    1|3|5|7|8|10|12) _max=31 ;;
    4|6|9|11)        _max=30 ;;
    2) if { [ $((_y % 4))   -eq 0 ] && [ $((_y % 100)) -ne 0 ]; } \
          || [ $((_y % 400)) -eq 0 ]; then _max=29; else _max=28; fi ;;
    *) return 1 ;;                        # inalcanzable tras la ERE, pero el default es CERRADO
  esac
  [ "$_d" -ge 1 ] && [ "$_d" -le "$_max" ] || return 1
}
identidad_canonica "$CLASS_FILE" "${ESTACION:-}" "${PR:-}" "$RUN_ISO" "$RUN_NONCE" "${HEAD:-}" \
  || { echo "identidad NO canónica (campo vacío o malformado): ABORTAR — nunca reservar" \
            "con una identidad que después no se puede correlacionar ni cerrar" >&2; exit 2; }

# Y la identidad se compara ENTERA, por igualdad exacta, jamás por contención:
# UNA CADENA VACÍA ESTÁ CONTENIDA EN TODO — `*$X*` con `$X` vacío no dice "no encontré nada",
# dice "encontré todo", y convertía la línea de OTRA estación en un falso ganador.
RUN_LINE="# APPLY-RUN [$ESTACION] #$PR $RUN_ISO $RUN_NONCE"

# LA PROCEDENCIA SE ACREDITA ANTES DE ESCRIBIR, NO SOLO ANTES DE CERRAR (CRITICAL — CR de M2 sobre
# la v18, confirmado por caminos independientes: `flock_acreditado` existía desde la ronda 32 para
# la guarda de CIERRE (`publish_close`) y nadie la puso delante de la ADQUISICIÓN. El `FLOCK_FILE`
# de esta receta llega del entorno de la estación igual que `TM_FLOCK_CANONICO_TRUSTED` (anexo por repo) y
# nada, en ninguna línea previa, compara que sean el MISMO fichero.
#
# El cierre miente sobre el PASADO —«este turno se cerró»—; el claim miente sobre el PERMISO —«este
# turno es mío»—. Guardar el cierre y dejar el claim sin guardar es la asimetría peligrosa: con un
# `FLOCK_FILE` no canónico la estación escribe su reserva en un fichero que no gobierna la exclusión
# de nadie, se relee A SÍ MISMA bajo ESE mismo fichero, se ve titular sin oposición y sigue hasta
# mergear — la ausencia de guarda no falla cerrado, falla ABIERTO, porque el escritor y el lector
# de la comprobación son el mismo proceso sobre el mismo fichero equivocado.
flock_acreditado \
  || { echo "FLOCK_FILE (${FLOCK_FILE:-<vacio>}) NO acredita ser el flock canónico" \
            "(${TM_FLOCK_CANONICO_TRUSTED:-<sin declarar>}): ABORTAR sin reservar — un claim sobre un" \
            "fichero que no gobierna la exclusión no reserva nada, y hace creer que sí" >&2; exit 3; }

# PUBLICAR el claim y RELEER bajo el MISMO flock. Esto NO es una nota: es la reserva. El fd vive
# dentro del subshell — no se apropia de un descriptor del proceso que invoca (fue uno de los
# defectos del gate retirado, TAL-5307). El rc de CADA paso se valida: un `flock` que falla y
# sigue escribiendo es una reserva que no reserva.
titular="$(
  exec 9>>"$FLOCK_FILE" || exit 3
  flock -x 9            || exit 3
  printf '%s\n' "$RUN_LINE" >&9 || exit 3
  # RECONSTRUCCIÓN SECUENCIAL — no por conjuntos. Pertenencia a un conjunto NO es una
  # secuencia: reducir el log a "run_ids cerrados" perdía ORDEN (un DONE ANTERIOR al RUN lo
  # cerraba), FORMA (un FAILED truncado sin categoría contaba como cierre) y TRANSICIÓN (un
  # FAILED ESCALAR dejaba ganar al claim siguiente sobre un gap roto). Y perdía el VOID: los
  # perdedores son VOID PARA SIEMPRE (ref 01), así que un DONE del titular NO puede promover
  # a un perdedor anterior — si lo hiciera, ese perdedor quedaría de titular permanente
  # esperando un cierre que nunca publicará, y bloquearía la flota entera.
  # Ante CUALQUIER cosa que no se pueda determinar: BLOQUEAR. Nunca «no vi cierre ⇒ libre».
  # AUTÓMATA TOTAL sobre su espacio de estados. UN SOLO DEFAULT PARA TODO LO NO ENUMERADO:
  # BLOQUEAR — nunca mergear. Estados: LIBRE · OCUPADO(t) · ROTO_T(g) · ROTO_E(g) ·
  # AUTORIZADO(a). Todo estado tiene camino de salida DEFINIDO (un bloqueo del que ninguna
  # secuencia legal pueda sacarte no es fail-closed, es un bug):
  #   OCUPADO   --DONE-->            LIBRE            (rid CERRADO, terminal permanente)
  #   OCUPADO   --FAILED TRANSITORIO-> ROTO_T --RUN del MISMO gap (cualquier estación)--> OCUPADO --DONE--> LIBRE
  #   OCUPADO   --FAILED ESCALAR----> ROTO_E --ESCALAR-GO (CEO/Orq)--> ROTO_E+GO --RECOVERS--> AUTORIZADO --RUN autorizado--> OCUPADO
  #     ROTO_E sin GO NO tiene salida automatica, y eso es DELIBERADO: el coste escrito es que una
  #     estacion que muera tras publicar ESCALAR deja el gate TOMADO hasta que intervenga un humano.
  # Un RUN perdedor es VOID permanente; un rid CERRADO no se resucita repitiéndolo.
  # La identidad del cierre incluye la ESTACIÓN validada, no solo el run_id.
  # `LC_ALL=C awk` (B-02 v24, ronda 37): el parser casa `RE_EST`/`RE_ISO`/`RE_NONCE` con `~`, y el
  # `~` de awk usa la colación del locale — bajo `en_US.utf8`, `RE_EST` `[1-5]` casaría un `M٣` en
  # un token del log. El prefijo fija C SOLO para este subproceso (no filtra al resto del bloque);
  # heredaba el C del `export` del módulo, retirado en v23. Vigilado por el check T36 del arnés.
  LC_ALL=C awk -v RE_EST="$RE_EST" -v RE_PR="$RE_PR" -v RE_ISO="$RE_ISO" -v RE_NONCE="$RE_NONCE" \
      -v RE_GO="$RE_GO" -v DRY="${TM_GATE_DRY:-0}" '
    BEGIN { estado = "LIBRE" }          # el estado inicial es EXPLICITO, no el vacio de awk
    function bloq(m){ print "BLOQUEADO: " m; salir=1; exit }
    function iso_ok(s){ return s ~ RE_ISO }        # MISMA definicion que el productor (-v)
    function nonce_ok(s){ return s ~ RE_NONCE }
    {
      linea = $0; sub(/^[[:space:]]+/, "", linea)
      if (linea !~ /^#[[:space:]]*APPLY-/) next        # no es de la familia APPLY: irrelevante
      sub(/^#[[:space:]]*/, "# ", linea); $0 = linea   # normaliza (un espacio inicial ocultaba el token)
      tok = $2
      if (tok == "APPLY-ESCALAR-GO") {
        # RULING CEO (ronda 29): un gap ESCALAR NO se recupera sin autorizacion EXPLICITA. Antes,
        # `APPLY-RECOVERS` solo exigia que la estacion fuera la DEL GAP — o sea que la misma
        # estacion cuyo apply dejo el estado remoto incierto se autorizaba a si misma. La prosa ya
        # mandaba escalar; el contrato ejecutable no pedia acreditacion, y el que se opera es este.
        # NF 6 = sin transferencia · NF 8 = con sufijo `-> <estacion>` (ruling ronda 30). El
        # `else` es CERRADO a proposito: escribir «acepta 6, acepta 8 bien formado» y no cerrar el
        # resto dejaria pasar un NF=7 como si no llevara sufijo — un sufijo a medias es justo la
        # forma que hay que rechazar.
        if (!(NF == 6 || NF == 8) || $3 !~ RE_PR || !nonce_ok($4) || $5 !~ RE_GO || !iso_ok($6))
          bloq("APPLY-ESCALAR-GO fuera de contrato (linea " NR ")")
        # El sufijo es un DATO y se valida por FORMA. La estacion viaja SIN corchetes aqui (`-> M5`)
        # y CON ellos en el resto de tokens, asi que se envuelve para medirla con la MISMA `RE_EST`
        # — una segunda definicion de «estacion» seria la divergencia que este fichero ya cerro.
        if (NF == 8 && ($7 != "->" || ("[" $8 "]") !~ RE_EST))
          bloq("APPLY-ESCALAR-GO con sufijo de transferencia malformado (linea " NR ")")
        if (estado != "ROTO_E") bloq("APPLY-ESCALAR-GO sin un gap ESCALAR abierto (linea " NR ")")
        # Cita el gap EXACTO por identidad, no por nombre de estacion: un GO generico autorizaria
        # cualquier gap posterior de la misma estacion.
        if ($3 != gpr || $4 != gnonce) bloq("APPLY-ESCALAR-GO no cita el gap roto (linea " NR ")")
        go_ok = 1
        # Vacio = sin transferencia (la original conserva la recuperacion). Con valor = la
        # recuperacion cambia de dueno, y SOLO uno: «una recuperacion tiene un dueno, nunca dos».
        go_dest = (NF == 8) ? $8 : ""
        next
      }
      if (tok == "APPLY-RECOVERS") {
        # MISMAS ERE compartidas: rehardcodearlas aqui reabria la divergencia que este bloque
        # dice cerrar — una segunda definicion de estacion y PR fuera del validador unico.
        if (NF != 7 || $3 !~ RE_PR || !nonce_ok($4) || $5 !~ RE_PR || !nonce_ok($6) || $7 !~ RE_EST)
          bloq("APPLY-RECOVERS fuera de contrato (linea " NR ")")
        if (estado != "ROTO_E") bloq("APPLY-RECOVERS sin un ESCALAR abierto que autorizar (linea " NR ")")
        if ($3 != gpr || $4 != gnonce) bloq("APPLY-RECOVERS no cita el gap roto (linea " NR ")")
        # La acreditacion va PRIMERO: si no hay GO, esa es LA razon, y decir «estacion distinta»
        # cuando lo que falta es la autorizacion manda a leer el sitio equivocado.
        if (!go_ok) bloq("APPLY-RECOVERS sin APPLY-ESCALAR-GO previo para este gap (linea " NR ")")
        # QUIEN puede recuperar depende de si el GO transfirio o no. Los dos mensajes son DISTINTOS
        # a proposito: rechazar a la original tras una transferencia es un caso LEGITIMO del ruling,
        # no el mismo error que rechazar a un tercero — mismo veredicto, motivos opuestos.
        if (go_dest == "") {
          if ($7 != gest) bloq("APPLY-RECOVERS de estacion distinta a la del gap (linea " NR ")")
        } else {
          if ($7 != "[" go_dest "]")
            bloq("APPLY-RECOVERS de estacion distinta a la TRANSFERIDA por el GO (linea " NR ")")
        }
        estado = "AUTORIZADO"; apr = $5; anonce = $6; aest = $7
        next
      }
      if (tok != "APPLY-RUN" && tok != "APPLY-DONE" && tok != "APPLY-FAILED")
        bloq("token APPLY-* desconocido (linea " NR ")")
      if ($3 !~ RE_EST || $4 !~ RE_PR) bloq("identidad fuera de contrato (linea " NR ")")
      if (!iso_ok($5)) bloq("sello no canonico (linea " NR ")")
      if (!nonce_ok($6)) bloq("nonce no canonico (linea " NR ")")
      ident = $3 " " $4 " " $5 " " $6          # identidad COMPLETA: incluye la estacion
      if (tok == "APPLY-RUN") {
        if (NF != 6) bloq("APPLY-RUN con campos de mas (linea " NR ")")
        # Muere la IDENTIDAD, no el GATE: un replay de una identidad terminal (ya cerrada) o VOID
        # (perdio la adquisicion) NO puede volver a ser titular, pero NO detiene el parseo. Como
        # el flock es append-only, abortar aqui dejaba inalcanzable cualquier token legal
        # posterior y congelaba la flota: eso es un bloqueo absorbente, no fail-closed.
        if ((ident in terminal) || (ident in void)) next
        if (estado == "LIBRE")           { estado="OCUPADO"; titular=$0; tident=ident; next }
        if (estado == "OCUPADO")         { void[ident]=1; next }   # PERDEDOR: VOID registrado
        if (estado == "ROTO_T")          { if ($4 != gpr) bloq("RUN de otro PR con un gap TRANSITORIO pendiente (linea " NR ")")
                                           estado="OCUPADO"; titular=$0; tident=ident; next }
        if (estado == "ROTO_E")          bloq("RUN sobre un gap ESCALAR sin APPLY-RECOVERS previo (linea " NR ")")
        if (estado == "AUTORIZADO")      { if ($4 != apr || $6 != anonce || $3 != aest) bloq("RUN no es el autorizado por el APPLY-RECOVERS (linea " NR ")")
                                           estado="OCUPADO"; titular=$0; tident=ident; next }
        bloq("estado desconocido en APPLY-RUN (linea " NR ")")
      }
      if (tok == "APPLY-FAILED") {
        if (NF != 7) bloq("APPLY-FAILED truncado o sin categoria (linea " NR ")")
        if ($7 != "TRANSITORIO" && $7 != "ESCALAR") bloq("categoria no canonica (linea " NR ")")
      } else if (NF != 6) bloq("APPLY-DONE con campos de mas (linea " NR ")")
      cierre_actual = (tok == "APPLY-DONE") ? "DONE" : ("FAILED " $7)
      if (ident in terminal) {
        # IDEMPOTENCIA es repetir el MISMO cierre, no aceptar uno OPUESTO para el mismo run_id.
        # Un DONE seguido de un FAILED ESCALAR de la misma identidad es un historial durable
        # CONTRADICTORIO: no puede declararse el gate libre mientras el flock afirma que el
        # apply fallo. Cae en el default BLOQUEAR.
        if (cierre[ident] != cierre_actual) bloq("cierre CONTRADICTORIO de una identidad ya terminal (linea " NR ")")
        next
      }
      if (estado != "OCUPADO" || ident != tident)
        bloq("cierre sin RUN abierto que le corresponda — identidad COMPLETA (linea " NR ")")
      # La identidad del RUN queda GASTADA en CUALQUIER cierre, DONE o FAILED. Diferirlo a un
      # unico `gident` perdia las identidades fallidas anteriores en una cadena con mas de un
      # fallo (A fallido, B fallido, C cerrado): A dejaba de ser terminal y su replay volvia a
      # ser titular, acreditando un turno ya extinguido.
      terminal[ident]=1; cierre[ident]=cierre_actual
      if (tok == "APPLY-DONE") { estado="LIBRE"; titular=""; tident=""; gpr=""; gest=""; gnonce=""; next }
      gest=$3; gpr=$4; gnonce=$6                       # el gap queda ROTO: nadie mas mergea
      # Cada gap nuevo arranca SIN autorizacion. Si `go_ok` sobreviviera de un gap anterior, un GO
      # gastado autorizaria un gap distinto — que es la misma clase de fallo que el nonce cierra
      # en la cadena de sucesion: la generacion importa, no el nombre.
      go_ok = 0; go_dest = ""
      estado = ($7 == "TRANSITORIO") ? "ROTO_T" : "ROTO_E"
      titular=""; tident=""
      next
    }
    END {
      # OBSERVABILIDAD — modo seco (`TM_GATE_DRY=1`). El resolvedor publica su ESTADO, no solo su
      # veredicto. Sin esto un arnes solo ve MERGE/NO-MERGE y NO puede distinguir «bloqueado porque
      # el gap sigue roto» de «bloqueado porque faltaba el GO»: dos rojos identicos por razones
      # DISTINTAS, que es lo que hacia inalcanzable el caso «con GO del CEO SI autoriza».
      # Va a STDERR A PROPOSITO: stdout lo captura el `$( … )` como `titular`, y contaminarlo
      # convertiria la observabilidad en un fallo de adquisicion.
      if (DRY == "1")
        print "# GATE-ESTADO estado=" estado \
              " gap=" (gpr == "" ? "-" : gpr) "/" (gnonce == "" ? "-" : gnonce) \
              " go=" (go_ok ? 1 : 0) \
              " goest=" (go_dest == "" ? "-" : go_dest) > "/dev/stderr"
      if (!salir) if (estado != "OCUPADO") print "BLOQUEADO: mi claim no quedo como titular (estado " estado ")"; else print titular
    }
  ' "$FLOCK_FILE"
)" || { echo "adquisición abortada (rc != 0 en lock/escritura): NO se mergea" >&2; exit 3; }

# DECIDIR por IDENTIDAD COMPLETA, con igualdad exacta. Fail-closed: BLOQUEADO, titular ajeno,
# vacío o ilegible ⇒ NO se mergea.
if [ "$titular" != "$RUN_LINE" ]; then
  echo "gate NO ganado — ${titular:-<lectura vacia>}." \
       "RUN ajeno activo, gap roto sin recuperación, log fuera de contrato o lectura ambigua:" \
       "ESPERAR su resolución o ESCALAR al CEO/Orquestador — jamás mergear" >&2
  rm -f "$CLASS_FILE"   # el intento se abandona: no dejar el temporal huerfano (fuga de inodos)
  exit 1
fi

# Turno GANADO. A partir de aquí el CLASS_FILE deja de ser scratch y pasa a ser EVIDENCIA del
# intento: se desarma la limpieza pre-claim para no borrar lo que `publish_close` necesita.
CLAIM_GANADO=1
fi   # ← cierra el `if [ "$N_MIG" -ne 0 ]` de 8.0. Aquí se llega por DOS caminos y conviene no
     #   confundirlos: con `N_MIG > 0` (hay migraciones) y con `N_MIG = -1` (INDETERMINADO), que
     #   **también entra y también reserva** por fail-closed. Sólo el caso `N_MIG = 0` salta el
     #   bloque entero: ahí no se ha reservado nada y `CLAIM_GANADO` sigue en 0, que es lo que la
     #   limpieza pre-claim del trap espera. Decir aquí «sin migraciones no se ha reservado nada»
     #   describiría el caso 0 y mentiría sobre el -1 — el mismo defecto que este bloque existe
     #   para cerrar, cometido en el comentario que lo documenta.

# 8.1) Merge — DENTRO del turno ya reservado (o PR sin migraciones, que no reserva nada).
#      El rc se CAPTURA con `errexit` desactivado SOLO en esta llamada: bajo `set -e`, un
#      `gh pr merge` con rc != 0 mataba el shell en esta línea y la reconciliación de 8.2 —el
#      caso EXACTO para el que existe— no llegaba a ejecutarse nunca, dejando el APPLY-RUN
#      abierto y, si el merge remoto sí ocurrió, `main` por delante de prod.
set +e
gh pr merge "$PR" --squash --delete-branch --match-head-commit "$HEAD"
rc_merge=$?
set -e

# 8.2) Un rc != 0 del cliente NO prueba que GitHub no mergeara: RECONCILIAR SIEMPRE el estado
#      autoritativo. Esto se ejecuta con `rc_merge` 0 o != 0 — es su razón de existir.
set +e
estado_pr="$(gh pr view "$PR" --json state,mergedAt --jq '.state + " " + (.mergedAt // "null")')"
rc_view=$?
set -e
# DEFAULT INVERTIDO: no se enumeran las combinaciones que se escapan —eso deja vivas las que
# no hemos imaginado (una cola de merge queue, por ejemplo)—. Se enumera lo que ACREDITA cada
# desenlace, y TODO lo demás cae en INDETERMINADO conservando el gate. Un fail-open no se
# arregla listando fugas: se arregla cambiando de qué lado está el default.
if [ "$rc_view" -eq 0 ] && [ "${estado_pr%% *}" = "MERGED" ]; then
  # ACREDITA MERGE: lo dice el estado AUTORITATIVO. El `rc` del cliente es irrelevante aquí —
  # «cliente con error» != «no mergeado» es justo la razón de ser de esta reconciliación, y
  # exigir además `rc_merge=0` convertía ese caso documentado en INDETERMINADO. Continuar NO
  # libera el gate, así que la rama es segura: lo que exige acreditación estricta es CERRAR.
  # Conservar el MISMO turno
  # (mismo RUN_NONCE), NO cerrar; seguir a pull -> runbook -> apply. El cierre del turno lo
  # publicará PROC-M13 con su propio rc: aquí no se cierra nada.
  :
elif [ "$rc_merge" -ne 0 ] && [ "$rc_view" -eq 0 ] && [ "$estado_pr" = "OPEN null" ]; then
  # ACREDITA NO-MERGEADO: el cliente falló Y el estado autoritativo dice OPEN sin mergedAt.
  #
  # PERO ANTES: si NO se reservó turno (`N_MIG = 0`, PR sin migraciones), aquí no hay nada que
  # cerrar — y además `CLASS_FILE` NO EXISTE, porque se crea dentro del bloque de reserva. Sin
  # esta guarda, bajo el `set -u` de la primera línea la receta REVIENTA con «unbound variable»
  # justo en la rama de diagnóstico: el camino feliz de un PR sin migraciones pasaba, y el
  # fallo aparecía solo cuando el merge fallaba — el peor momento para descubrir un crash.
  # Publicar un cierre tampoco valdría: cerrar un turno que nunca se abrió es peor que el crash.
  if [ "${CLAIM_GANADO:-0}" -ne 1 ]; then
    echo "no-mergeado CONFIRMADO (rc_merge=$rc_merge) y SIN turno reservado (PR sin migraciones):" \
         "no hay gate que cerrar; reintentar el merge cuando se corrija la causa" >&2
    exit 1
  fi
  # `rc_merge != 0` está GARANTIZADO por esta rama, así que `publish_close` no puede derivar
  # un `APPLY-DONE` de un cero. Escribir la clase NO es publicar el cierre: sin el
  # `APPLY-FAILED` en el flock el APPLY-RUN queda abierto hasta el timeout de estación muerta.
  printf 'TRANSITORIO\n' > "$CLASS_FILE" \
    || { echo "no se pudo escribir CLASS_FILE: NO se libera a ciegas, ESCALAR" >&2; exit 4; }
  # El rc se CAPTURA y la limpieza va por la MISMA vía en los DOS desenlaces, ANTES de
  # propagar (ronda 28, MAYOR — hallazgo de revisión externa). Antes, un `publish_close` que
  # devolvía 1 saltaba al `|| { … exit 4; }` y el `rm -f` de abajo NO se ejecutaba nunca: con
  # `CLAIM_GANADO=1` el trap de salida ya está DESARMADO a propósito (el CLASS_FILE es
  # evidencia desde que se gana el turno), así que nadie más lo recogía — cada cierre fallido
  # dejaba un temporal huérfano en el TMPDIR del operador, justo en el incidente en el que
  # menos se mira. Su contenido ya está consumido en ambos casos: publicado en la línea de
  # cierre, o volcado por `publish_close` a `$LOG` y a stderr dentro del aviso de escalado.
  set +e; publish_close "$rc_merge"; rc_close=$?; set -e
  rm -f "$CLASS_FILE"
  [ "$rc_close" -eq 0 ] \
    || { echo "publish_close falló: el turno queda SIN CIERRE, ESCALAR YA" >&2; exit 4; }
  echo "no-mergeado CONFIRMADO (rc_merge=$rc_merge): turno liberado; recuperar con" \
       "update-branch y re-ganar el gate con un nonce NUEVO (intento nuevo)" >&2
  exit 1
else
  # TODO LO DEMÁS es INDETERMINADO: vista ilegible, estados contradictorios (rc=0 con PR OPEN),
  # MERGED con el cliente en error pero vista no leída, cola de merge queue, o cualquier
  # combinación futura. FAIL-CLOSED: NO se libera la reserva; se escala. «No sé» != «no ocurrió».
  # Nunca esperar al timeout de 30 min: ese es para estación MUERTA, no para duda.
  echo "estado INDETERMINADO (rc_merge=$rc_merge, rc_view=$rc_view, vista='"'"'${estado_pr:-<vacia>}'"'"'):" \
       "NO se libera la reserva — ESCALAR al CEO/Orquestador" >&2
  exit 4
fi
```

- NO editar título/body al mergear (el body lleva los `closes TAL-N` — gotcha 11).
- **Post-merge en el MISMO turno** (gate de Done, regla dura 8): migraciones → apply +
  advisors + confirmación de ledger (ref 06 + anexo PROC-M13/M15). Sin migraciones →
  verificar Done de los issues (via `closes`) y liberar el slot.
- Liberar el slot de merge → siguiente PR de la cola.
  **RUTA APAGADA (fail-closed)** — ruling `CEO-RULING-MAJOR4-T05-BATCHING-OFF-PARALELA-NO-ES-BATCHING-1625`. Esto es
  **procedimiento operativo**, no doctrina, así que se dice aquí y no solo en la ley: con el batching
  DESACTIVADO **el siguiente PR corre su suite COMPLETA sobre su propio head**, sea disjunto o no.
  **Si hay ventana abierta**, el siguiente puede
  ser una pieza **disjunta por FICHERO** de las ya fundidas en ella, y entra **corriendo su suite
  COMPLETA** — la entrada sin ella es lo que preveía la vía APAGADA, y se registra como tal, no se
  instruye; con intersección de ficheros, espera y re-mide **los gates afectados** (ref 10).
  **Disjunción de ficheros ≠ disjunción de INSUMOS**: la primera evita conflictos de merge; la
  segunda, la caducidad de un gate cuyo veredicto depende de un fichero que ninguna de las dos piezas
  comparte por nombre pero que ambas alimentan (contraejemplo medido: #2301 era disjunto de #2295 por
  fichero —`LC_ALL=C comm` y `grep -Fxf`, intersección 0— y aun así caducó el gate `skills-package`
  al tocar `.claude/skills/talent-channel-operation/scripts/00-config.sh`, insumo de ese gate). No
  omitir el re-cómputo de un gate solo por disjunción de ficheros sin comprobar también sus insumos
  reales — mismo patrón que `TF_INPUTS_UNIVERSAL` (ref 10 §6), pero **sin catálogo propio hoy**:
  a diferencia de `TF_INPUTS_UNIVERSAL` (lista explícita de globs), no existe un registro
  gate→insumos consultable; ante duda, tratar el gate afectado como si tuviera insumos ocultos y
  re-medirlo. Catalogarlos es trabajo aparte, no de esta pieza.

## 9. PROC-M19 — Check rojo: ¿flake o real?

> **Con Actions OFF (TAL-2286)**, el "check rojo" es un gate local: la evidencia es el
> receipt FAIL del runner + su log protegido, y el "rerun" es re-asignar ESE gate/shard a
> un runner (mismo head, run_group nuevo o re-asignación dentro del run) — la heurística
> de abajo aplica igual, cambiando `gh run` por receipts. Los comandos `gh run` quedan
> para el histórico y para cualquier org que aún corra Actions.

Heurística heredada de la operación multi-canal (verificada en producción):

1. **¿La run es del head actual?** `gh run list --branch <rama> --limit 5 --json databaseId,headSha,conclusion`
   — un FAIL de un head viejo no dice nada del vigente.
2. **Leer el error real** antes de asumir flake: `gh run view <id> --log-failed | head -40`.
3. **Heurística alcance-vs-shards**: comparar el ALCANCE del cambio contra el nº de shards
   rojos. Un cambio de **alcance global** (`proxy.ts`, `next.config.ts`, `globals.css`) que
   rompe **1 solo shard** con el resto verde = **flake** (una regresión real de un cambio
   global golpearía MUCHOS shards, no uno quirúrgico). Confirmación barata:
   `gh run rerun <id> --failed` (re-run solo del shard; verificado en #818, rerun verde).
   Un cambio **quirúrgico** de un dominio cuyo shard de ESE dominio se rompe = sospechar real.
4. Tabla de decisión (e2e por shards):

| Señal | Diagnóstico | Acción |
|---|---|---|
| Shard rojo de dominio NO tocado por el PR + shards individuales verdes | Flake de timing | `gh run rerun <id> --failed` |
| Shard rojo del dominio DEL PR | Posible regresión real | → canal de refactorización (ref 05); si toca invariantes → bounce |
| FAIL reproducido tras el rerun | Real | NUNCA re-lanzar en bucle; refacto o bounce |
| `db-guards` rojo | Puede ser REAL (guards de grants) | Leer el guard exacto; fix = migración nueva vía refacto |
| `db-guards` rojo por un **test que el PR AÑADE** (vs trigger/seed de la base) | El fix vive DENTRO del PR, no en la base | Fix en el **fixture** (from-scratch-safe: que funcione en `db reset` limpio) — ni baseline-accept ni park (Ev #899 `funnel_overview`) |

**Flakes CONOCIDOS del repo** (`gamif-ranking`; `foro-981`): la salida es **re-run del
shard**, NO refacto ni bounce — pero la clasificación como "flake conocido" exige que **la
FIRMA del fallo COINCIDA** con la registrada (mismo spec, mismo assert/síntoma, mismo
patrón de timing). Un fallo NUEVO en el mismo spec NO hereda la etiqueta de flake: se
diagnostica desde cero (pasos 1-3). El re-run es acotado (1, máximo 2) — reproducido tras
eso, se trata como real. **La firma vigente de cada flake vive en `notes` de su shard en
`scripts/ci/e2e-shards.json`** — ese registro es la sede operativa del dato y el
consumidor natural de los receipts rojos que produzca la ley 40 de las estaciones.
`visibility-race` (citado aquí en versiones previas) NUNCA existió: `git log -S` sobre
toda la historia solo encuentra el commit que lo introdujo como artefacto de redacción
(TAL-2658/#949) — retirado, no fue renombrado. `foro-1032` **sale** de la lista activa
(sin ejecución fallida observada tras su estabilización TAL-2760, 2026-07-17); su
**criterio de re-entrada** explícito está en `notes` de su shard, no aquí.

**Caso o — test FAIL fuera del diff del PR sobre fichero que el PR toca**: el PR no
modifica el test que falla, pero sí modifica un fichero que el test cubre → estado
combinado **nunca probado antes** (el test era verde sin el cambio; con el cambio falla).
NO es flake ni es bounce: la responsabilidad es **fix mecánico de la estación** (ajustar
mock, setup o fixture para el estado nuevo), verificando ANTES que los guardas e
implementación del PR son correctos. Solo si ese fix exige cambiar el contrato declarado
en el HANDOFF → bounce (ev #1108×#1160).

## 10. Nota histórica — GitHub Actions (hoy N/A): firma del presupuesto agotado

Gotcha de diagnóstico preservado de la sesión 2026-07-09 (TAL-2288, findings C12-C15 del
Mergeador). **Hoy N/A** (Actions OFF, gate = `local-gates`) — vale para cualquier org que
aún corra Actions y como vacuna contra el misdiagnóstico que ya ocurrió.

- **C12 — Firma de PRESUPUESTO ACTIONS AGOTADO** (distinta de flake/zombie): jobs que
  fallan en **~2 s** con `runner_name` **vacío**, `steps == 0`, `conclusion == failure`,
  **SIN logs ni anotaciones**, en **TODOS los PRs a la vez**, **persistente entre
  reruns**. Verificación: `gh api .../actions/jobs/<id> -q .runner_name` (vacío) +
  `-q '.steps|length'` (0). Confirmado → es **infra/billing, NO el PR**: escalar al
  billing admin, no depurar el diff. (Así agotó org-ejemplo sus $200 — reset 1-ago —
  y nació la migración a gates locales.)
- **C13 — Los reruns de shards flaky QUEMAN presupuesto**: los full-reruns de flakes
  recurrentes (quiz-timer `tal-1560`, foro-983) contribuyeron al agotamiento. Disciplina:
  `rerun --failed` (nunca full), tope de reintentos; en la e2e local, paralelizar por
  shard en runners en vez de reintentar.
- **C14 — Staleness de `rerun --failed`**: si el shard rerun pasa, el aggregator
  (`needs: shard`) puede seguir mostrando el resultado VIEJO (needs-context stale); solo
  un full rerun o close+reopen dan contexto limpio. Este staleness hizo misdiagnosticar
  un fallo de aggregator como bug del PR cuando era el blip de presupuesto — **no
  atribuir a un PR sin descartar infra primero**.
- **C15 — `gh run rerun` sobre un run in-progress** falla con "cannot be rerun; workflow
  file may be broken": esperar a que el run complete antes del rerun.
