# 09 — Trenes

Doctrina repo-agnóstica de la estación para lotes cohesivos que se integran en UN PR padre en
vez de N drafts individuales (AMENDMENT Trenes, CLAUDE.md regla 10 / AGENTS.md regla 3,
TAL-4563, ADR-0043). La mecánica de CodeRabbit sobre el tren vive en `coderabbit-talent`
§Trenes; la cláusula de issue que declara los contratos cross-pieza vive en
`talent-issue-craft` (núcleo, `## Contratos cross-pieza (si va en tren)`, convención
documentada — gate humano, no automático).

## Table of Contents

- [1. Cuándo un lote va en tren](#1-cuándo-un-lote-va-en-tren)
- [2. Entrada: las piezas entregan RAMA](#2-entrada-las-piezas-entregan-rama)
- [3. Ensamblaje del padre](#3-ensamblaje-del-padre)
- [4. Contratos SEMÁNTICOS cross-pieza](#4-contratos-semánticos-cross-pieza)
- [5. CodeRabbit: una sola pasada sobre el bundle integrado](#5-coderabbit-una-sola-pasada-sobre-el-bundle-integrado)
- [6. Bounce de findings al canal DUEÑO](#6-bounce-de-findings-al-canal-dueño)
- [7. Cierre](#7-cierre)
- [8. Exclusiones absolutas y cota de tamaño](#8-exclusiones-absolutas-y-cota-de-tamaño)

## 1. Cuándo un lote va en tren

Un **lote cohesivo** — 2 o más encargos del mismo dominio/proyecto, coordinados y producidos
en paralelo por canales distintos — va por **TREN PADRE por defecto**. La alternativa (draft +
HANDOFF individual por encargo) queda para piezas sueltas sin relación.

Dos reglas distintas limitan qué entra a un tren — **no son lo mismo y no se mezclan** (ver
[sección 8](#8-exclusiones-absolutas-y-cota-de-tamaño) para el detalle completo):

- **Exclusiones absolutas**: ciertos tipos de cambio NUNCA entran a un tren, sin importar
  dominio ni tamaño.
- **Cota de tamaño**: un lote que SÍ califica por dominio pero excede 60 ficheros o 5 piezas se
  **parte en sub-trenes** — esto es una regla de PARTICIÓN, no una exclusión.

## 2. Entrada: las piezas entregan RAMA

A diferencia del flujo estándar (PR **DRAFT** + comentario **HANDOFF**, ver checklist §1
Intake), cada pieza de un tren:

1. Corre sus gates locales verdes y su propio ciclo adversarial (dev + auditor,
   CORTAFUEGOS DE RONDA 2 — ver SKILL.md, «el pase del ensamblador es sobre el bundle
   INTEGRADO, no sobre la pieza suelta»).
2. **Entrega RAMA** — sin abrir PR propio, sin comentario HANDOFF propio.
3. Declara en su issue Linear (vía `talent-issue-craft`, cláusula «Contratos cross-pieza (si va
   en tren)») los contratos semánticos que otras piezas del mismo tren deben respetar
   ([sección 4](#4-contratos-semánticos-cross-pieza)).

El Mergeador (o el canal designado como ensamblador) arma el **PR padre** integrando las N
ramas. La regla dura 2 del SKILL.md («sin HANDOFF válido no hay intake») se excepciona
explícitamente para este caso: el intake NO exige un HANDOFF por pieza — exige UN HANDOFF
consolidado en el PR padre, que enumera invariantes, superficies y slots de las N piezas.

**Ruta pre-push de pieza de tren — TAL-5185, TODAVÍA NO OPERATIVA**: `scripts/draft-handoff.sh
--pieza-de-tren` existe como flag reconocido (parser cerrado: cero argumentos o exactamente ese
flag, cualquier otra cosa sale con error) pero está **deshabilitado fail-closed a propósito** —
sale con error ANTES de correr ningún gate local o emitir el sentinel `.claude/.draft-handoff`.
Motivo (hallazgo BLOQUEANTE de auditoría adversarial interna del canal, TAL-5158): un flag
booleano autodeclarado, sin evidencia emitida por el dispatcher que vincule issue + rama + tren
padre, sería una vía OFICIAL para saltarse PR+HANDOFF en cualquier cambio — indistinguible de
una pieza legítima para el hook o para cualquier consumidor aguas abajo. TAL-5185 sigue
**abierta** hasta diseñar ese mecanismo de evidencia (verificable, no autodeclarado) y cablearlo
tanto en `draft-handoff.sh` como en `verify-handoff.sh` v3.

**Diseño acordado para cuando TAL-5185 cierre** (doctrina, no mecánica ya operativa): la pieza
correrá los mismos gates locales que el modo normal, emitirá el sentinel que `.githooks/pre-push`
ya acepta (el hook no exige que exista un PR — solo que OID+ref coincidan con el sentinel), y
tras el push publicará un **HANDOFF-PIEZA** como comentario en su propia issue Linear (y en el
bus de coordinación): nombre de la rama, `head_sha` exacto, la RUTA del fichero de veredicto de
la auditoría adversarial interna del canal (nunca el nombre de la herramienta ni del modelo —
regla 6), y el MANIFEST con los slots de migración declarados si los hay. El Mergeador integrará
la rama en el PR padre.

**Criterio de ancla de veredicto — DOS modos, ningún tercero** (arbitraje de doctrina
compartido con `talent-issue-craft`/`verify-handoff.sh` v3, TAL-5156; gate y doctrina deben
decir LO MISMO):

- **Modo PR** (entrega con pull request): el `sha` del veredicto debe ser IGUAL al `headRefOid`
  del PR citado en el HANDOFF, Y debe ser ANCESTRO de la rama de ese PR.
- **Modo pieza de tren** (entrega de rama SIN pull request): el `sha` del veredicto debe ser
  IGUAL a `git rev-parse origin/<rama-entregada>` — el **TIP REMOTO, no el local** —, Y debe
  ser ANCESTRO de esa rama. El HANDOFF-PIEZA cita rama y sha; la validación exige que AMBOS
  coincidan con el remoto. Motivo del matiz remoto-no-local: contra el tip LOCAL, un commit
  hecho después de auditar y NUNCA subido pasaría el check, aunque lo que llega al Mergeador
  sea otra cosa distinta de lo auditado — el remoto es lo único que el Mergeador puede ver.
- Mensajes de fallo, literales, en LOS DOS modos: `VEREDICTO-AJENO` (el sha no es el head que
  corresponde) y `VEREDICTO-CADUCO` (el sha no es ancestro de la rama).

**Verificación de las N ramas**: antes de ensamblar, confirmar que cada rama declarada aparece
en el git log del padre (`git log --merges` tras el merge de las N ramas, o equivalente si se
usa squash-por-pieza dentro del padre) — ejemplo real: TREN D (#1872) lista sus 4 hijas con
`#PR rama — TAL-N` y el criterio «ramas verificables en el git log del padre,
`git log --merges`».

## 3. Ensamblaje del padre

**Unión de `supabase/tests/MANIFEST.md` sin duplicados.** Si dos o más piezas del tren añaden
pgTAP nuevo, el ensamblador toma la unión de las filas nuevas de las N ramas — nunca una
resolución `union`/automática de merge sin revisar. El peligro es el mismo que ya doctrina el
anexo §7 (B8b, silent-drop del union-rebase sobre listas aditivas de `run-db-guards-local.sh`):
un rebase o merge automático puede conservar solo un lado y dropear filas del otro en
silencio. Tras ensamblar: re-verificar `bash scripts/check-tests-manifest.sh` sobre el estado
final del padre — debe reportar cero huérfanos y paridad exacta con la allowlist de CI.

**Renumeración de los N slots por NOMBRE, EN ORDEN.** No se renumera contra el ledger de prod
en solitario: el tope real es **`ledger de prod ∪ origin/main ∪ slots declarados por los
drafts de la cola ya en preparación`** (doctrina completa: ref 06 §2, mecánica ejecutable:
anexo `PROC-M14`). "Por nombre EN ORDEN" significa: se preserva el orden relativo original
entre las N migraciones del tren (el orden en que las piezas las escribieron), y se les
asignan slots libres por encima del tope, uno por uno, en ese mismo orden — nunca por
timestamp original, que puede colisionar entre piezas hermanas. Caso real de colisión evitable
con esta disciplina: TREN-FUNDAE (#2089) sufrió una 2ª renumeración de slots
`344-348→348-352` por colisión con un PR ajeno (#2072/TAL-5074) detectada tarde.

**Contratos SEMÁNTICOS cross-pieza**: ver [sección 4](#4-contratos-semánticos-cross-pieza).

## 4. Contratos SEMÁNTICOS cross-pieza

Motivación real (coordinación de 5 piezas PostHog en paralelo, 1-sep-2026): dos piezas
definieron el MISMO export (un resolver) como «seam provisional». Sin un contrato explícito de
quién es el DUEÑO, el ensamblaje termina con dos definiciones vivas del mismo símbolo.

Cada issue Linear de una pieza que vaya a tren declara, en la cláusula de núcleo
`## Contratos cross-pieza (si va en tren)` (`talent-issue-craft` — convención documentada, gate
humano de revisión al ensamblar, sin enforcement automático del auditor de issue-craft):

- **Dueño de cada símbolo/export/tabla/migración compartida** con otra pieza del mismo lote —
  UNA sola pieza es la DUEÑA (la que lo define/crea); el resto la CONSUME, nunca la redefine.
- **Qué SELLA** esta issue: qué decisión o comportamiento queda fijo al mergear el tren — no se
  reabre sin una issue nueva.
- **Qué SUPERSEDE**: qué decisión o issue previa queda obsoleta por este cambio — declarado
  explícitamente, no implícito. (Caso real: un plan chocó contra un issue SELLADO porque otra
  pieza del lote lo había superseded sin escribirlo.)
- **Slot de migración propuesto** — a título informativo; el ensamblador SIEMPRE renumera
  contra `ledger ∪ main ∪ drafts` ([sección 3](#3-ensamblaje-del-padre)), nunca asume el slot
  propuesto como definitivo.

**Verificación del ensamblador (fail-closed)**: antes de abrir el PR padre, confirmar que
ningún símbolo compartido tiene dos piezas reclamándose dueñas. Si hay conflicto → bounce al
canal en conflicto para resolver el dueño ANTES del ensamblaje, nunca decidirlo unilateralmente
el ensamblador.

## 5. CodeRabbit: una sola pasada sobre el bundle integrado

Doctrina completa en `coderabbit-talent` §Trenes (incluida la bifurcación de trazabilidad
CLI/App de la corrida que autoriza el merge); resumen aquí: CLI y App corren **solo sobre el
diff agregado del PR padre** (el bundle integrado), nunca por pieza — ni durante el ensamblaje
ni después. Esto ya está parcialmente doctrinado (SKILL.md, cortafuegos de ronda 2): «en
trenes, el pase del ensamblador es sobre el bundle INTEGRADO (los findings cross-pieza salen
del ensamblaje, no de las piezas)». Un tren de 5 piezas consume **1** invocación de CodeRabbit,
no 5.

## 6. Bounce de findings al canal DUEÑO

Un finding del CR sobre el PR padre **nunca se arregla in-situ** por el Mergeador ni por el
ensamblador (regla dura 5/10 del SKILL.md: «El Mergeador jamás re-desarrolla el encargo»). Se
hace bounce del finding literal al canal que produjo la pieza afectada — mismo mecanismo que
`references/05` §1 (brief con el finding verbatim + invariantes del HANDOFF + instrucción de
alcance quirúrgico). Si el finding es cross-pieza (toca código de dos piezas a la vez), el
bounce va al canal DUEÑO del símbolo según el contrato declarado en la issue
([sección 4](#4-contratos-semánticos-cross-pieza)) — nunca al canal consumidor.

## 7. Cierre

El PR padre cierra las N issues del lote, una por una, con `closes TAL-N` por cada issue
(ejemplo real, TREN COMMERCE-2 #2104: `closes TAL-5023` · `closes TAL-5010` ·
`closes TAL-4447`). Si alguna pieza tenía un PR individual previo, ese PR queda marcado
«superseded por padre #N» — comentario de cierre explícito, nunca solo abandonado.

`talent-issue-craft` (`references/01-nucleo-y-despachabilidad.md` §4.12) admite este cierre
como un tercer régimen junto a «PR + revisión + fusión» (default) y «cierre manual con
evidencia»: la issue de una pieza de tren se cierra vía el `closes` del PR padre, nunca en un
PR propio. El tipo `contenido-datos` (`templates/09-contenido-datos.md`, SIN PR por contrato)
NO participa en trenes — su cierre siempre es manual con evidencia, independiente de si otras
piezas del mismo lote sí van en tren.

## 8. Exclusiones absolutas y cota de tamaño

Dos categorías distintas — no se fusionan en una sola lista (ver [sección 1](#1-cuándo-un-lote-va-en-tren)):

**(a) Exclusiones absolutas — nunca entran a un tren, sin importar tamaño ni dominio:**

- **Migración/operación destructiva** (`DROP`/`ALTER` irreversible/`DELETE` batch) → PR solo +
  GO explícito del lead (CLAUDE.md regla 24).
- **Money-path SEV urgente** → exprés solo, por decisión directa CEO/lead — nunca automático.
- **Dominios sin relación** — un tren agrupa por afinidad real de dominio/proyecto, no por
  coincidencia temporal de la cola.

**(b) Cota de tamaño — regla de PARTICIÓN, no de exclusión:**

Un lote que SÍ califica por dominio/proyecto pero excede **60 ficheros** de diff combinado o
**5 piezas** se **parte en sub-trenes** que cumplan AMBOS límites cada uno — el ensamblaje y el
review de CodeRabbit sobre un bundle demasiado grande dejan de ser auditable en una sola
pasada. Si no existe una partición válida (ejemplo: 2 piezas cuyo diff combinado ya supera 60
ficheros — no hay forma de partir en sub-trenes de al menos 2 piezas cada uno), las piezas que
no quepan **vuelven al flujo individual** — draft + HANDOFF por encargo, como si no hubiera
lote cohesivo — nunca se fuerza un tren sobredimensionado.
