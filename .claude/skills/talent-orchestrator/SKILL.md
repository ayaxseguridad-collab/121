---
name: talent-orchestrator
description: >
  Orquestador que sustituye al lead en el despacho: analiza Linear de PRODUCTO, cura batches de
  issues (pueden cruzar milestones), los agrupa en ENCARGOS/BUNDLES cohesivos (Fábrica v2,
  ADR-0043: bundle = 1..N issues = una rama = un PR draft + HANDOFF) y los reparte a los
  Coordinadores como ÓRDENES DE TRABAJO vía el proyecto Linear "Coordinación Multi Canal".
  Token-only, NO MCP. NO maneja canales ni mergea. Recibe bounce-to-pool. Trigger: "orquestador",
  "orchestrator", "talent-orchestrator", "curar batch", "curar bundle", "encargo", "bundling",
  "repartir issues", "orden de trabajo", "proyecto coordinación", "registro de flota", "bounce to
  pool", "cola del Mergeador", "torre de control", "torre-sweep", "torre-relay", "torre-compact",
  "torre-resume", "compact-60", "sweep de panes", "resume canonico", "ghost text", "exit fantasma".
---

# Talent Orchestrator — Reparte batches de issues a los Coordinadores vía Linear

*v2.12 (TAL-3650, 2026-07-30) — capa META con PM: jerarquía PM ⇄ CEO como contrapartes
(el PM define la carga; rol en el skill `talent-pm`, 12.º miembro del paquete), tabla de modelos
con CEO=Opus vigente y PM=Sonnet vigente — todo en ref 11; detalle en
`CHANGELOG.md` §v2.12. Base v2.11 (TAL-3394, 2026-07-23) — reconciliación guardia 15-16 jul: D7 ownership de limpieza de
refs + umbral de reciclaje <10 min (ref 05), D8 issue ya-satisfecha sin makework (ref 08),
compact-60 canónico en `talent-context`; detalle en `CHANGELOG.md` §v2.11. Base
v2.10 (TAL-3265, 2026-07-22) — loop issue-craft en el curado: gate `audit-issue` pre-bundle
(issue-craft:v1, umbral del perfil, comentario en issue rechazada), solape por caso (estimado para
issues sin PR / medido con `gh pr view` para PRs abiertos), adopción de drafts huérfanos, deslinde
Templates-de-producto vs órdenes-meta, contrato de formato flock en Monitor, barrido
`issue-craft-gap`. Absorbe saneamiento del validador (`description` ≤1024 + `## Critical Gotchas`).
Base v2.9 (TAL-1974, 2026-07-18). Base v2 (TAL-2253, 2026-07). Base v1 (TAL-2193 / ADR-0043).*

Automatiza el dedo del lead eligiendo issues. El **Orquestador** lee Linear de PRODUCTO, **cura un
batch** (agrupado en **encargos/bundles** — ref 08) y crea **una orden de trabajo** en el proyecto
Linear **"Coordinación Multi Canal"** para un **Coordinador**, que la **lee y despacha a mano**
(`dispatch.sh <carril> <TAL-id>`, encargo a encargo) con su cuadrilla de canales — no hay consumidor
automático.

## Quick Orientation

| | |
|---|---|
| **Versión** | v2.12 (TAL-3650, 2026-07-30; base v2.11 TAL-3394) |
| **As of** | julio 2026 |
| **`last_verified`** | 2026-07-18 — endpoint Linear GraphQL + modelo de rate-limiting por complejidad (fuente oficial; incluye la contradicción NO resuelta de conteo de requests/hora, ver `references/02-convenciones-linear.md` §Límites de la API) |
| **Endpoint Linear** | `https://api.linear.app/graphql` (único público, sin versión en el path) |
| **Cap de batch por defecto** | `TORC_DEFAULT_CAP=4` (`scripts/00-config.sh`, ≤ cuadrilla, 4-6) |
| **Schema de la orden** | `TORC_SCHEMA_VERSION=1` (bloque machine-readable) |
| **References** | 11 (`01`–`11`) |
| **Modo** | Token-only (Linear API directa vía `LINEAR_API_KEY`) · **NO MCP** |

## Nomenclatura (no confundir)

- **Orquestador** = ESTE skill. Top **de ejecución** (la capa META PM ⇄ CEO queda por encima; el PM define la carga). Decide *qué*, *agrupado cómo* y *en qué orden*. Solo escribe en Linear.
- **Coordinador** = `talent-channel-operation` (1ª estación). Maneja la **cuadrilla de canales**.
  **Uno por proyecto/repo**. **Lee** las órdenes y **despacha a mano**; su pipeline termina en la
  **entrega** (PR draft + HANDOFF). NO lo invoca este skill.
- **Mergeador** = `talent-merger` (2ª estación). Consume los drafts, corre CodeRabbit y **mergea**.
  Recibe de aquí la prioridad de su cola; devuelve aquí los bounce-to-pool (ref 08).
- **Canales** = `vibe-channel-XY` (los provisiona `talent-channels`). «Carril» es sinónimo
  histórico de «canal».

```text
ORQUESTADOR (este skill) ── crea orden (encargos) ──► proyecto Linear "Coordinación Multi Canal"
                                              │ (el coordinador la LEE)
              COORDINADOR (talent-channel-operation) ─► despacha a mano ─► PR DRAFT + HANDOFF
                                              │ (cola curada por el Orquestador)
                          MERGEADOR (talent-merger) ─► CodeRabbit → gates AND → merge → Done
```

**Modo dual**: la fábrica opera en **manual** (actores en terminales sueltas, el lead hace de relay)
o bajo la **Torre de Control** (sesiones en tmux que el Orquestador cosecha con capture-pane/send-keys).
La Torre es optimización, no dependencia — ver `references/09-torre-de-control.md`.

## Dos capas de Linear

| Capa | Qué vive ahí | Quién la mueve |
|---|---|---|
| **Producto** (Academia Ejemplo…) | Issues reales `TAL-…` | Coordinador + cuadrilla |
| **Coordinación Multi Canal** (proyecto dedicado) | **Órdenes de trabajo** + **issue-registro** de la flota | Orquestador crea · Coordinador lee y despacha a mano |

**Principio**: la issue-registro es **config lenta** (binding canal→coordinador); el estado
libre/ocupado en vivo es del Coordinador, **no** de Linear.

## Orden de trabajo (lo que cruza la frontera)

Estilo "Open Engine": contexto + dueño + DoD + dónde parar + qué mostrar. Cumple higiene Linear:
**título imperativo** + labels obligatorios `vertical/*` y `actor/ai` (+ `agent-instructions`, `coord-<x>`).
Lleva **prosa legible** + un **bloque ```json machine-readable** (`schema_version`, `coordinador`,
`coordination_project_id`, `product_project`, `issue_ids`, `precedence`, `dod`, `idempotency_key`).
Ese bloque es **obligatorio** en toda orden que crea el Orquestador: la **reserva/idempotencia** lo
parsea (`select-work.sh` + `torc_precreate_check` → `torc_extract_issue_ids`). Es **opcional** solo para el
humano/coordinador que lee la orden (no lo necesita para despachar a mano; puede extraer `issue_ids` con `jq`).

**Eco de cumplimiento** (paso de cierre del despacho, 2026-07-28): toda orden de trabajo a un
coordinador/canal se cierra con un eco del receptor que nombra (a) el skill cargado y (b) las
cadencias/gates de ese skill YA ARMADOS Y CORRIENDO — no prometidos. Sin ese eco el despacho no
se da por entregado y el Orquestador lo persigue (detalle del lado de lectura obligatorio del
bus/entrada propia en `references/09-torre-de-control.md`).

## Garantías (gates incorporados)

```text
select-work.sh — pipeline de curado (references/05-seleccion-y-curado.md)

  issues del proyecto (paginado, first:100)
        │
        ▼
  accionables (state backlog/unstarted, sin assignee)
        │
        ▼
  − reserva (issues ya en órdenes ABIERTAS del proyecto Coordinación) ──► excluded.reserved
        │
        ▼
  orden por prioridad (0→99, Urgent primero) + sortOrder de milestone
        │
        ▼
  blockers externos no resueltos + cascada de bloqueo transitivo ────► excluded.blocked
        │
        ▼
  topo-sort (Kahn) ── ¿ciclo? ──► exit 2, ESCALAR (nunca ordena a ciegas)
        │
        ▼
  cap (head -n CAP)
        │
        ▼
  { issue_ids, precedence, excluded }
```

- **Reserva/idempotencia [Linear]**: `select-work.sh` excluye issues ya presentes en órdenes
  abiertas; antes de crear, `orchestrate.sh` corre un chequeo **fail-closed** (`torc_precreate_check`
  sobre un fetch fail-closed común) que resuelve, en un solo lugar, un token **tri-state**: **una orden
  abierta por coordinador** (respeta la cadencia; salta con `--allow-multiple`), **idempotency-key**
  determinística (no duplica) y **solape** de `issue_ids`. La reserva vive en Linear, no en locks locales
  (el lock host-local solo asegura *un orquestador a la vez* en la misma máquina).

  ```text
  torc_precreate_check → torc_route_precreate  (precedencia: noop > overlap > block > create)

    idempotency-key ya en orden abierta? ──sí──► noop <TAL-id>  ──► SKIP (no duplica)
          │no
          ▼
    issue_ids solapan con otra orden abierta? ──sí──► overlap <ids> ──► ABORT:solape
          │no
          ▼
    ya hay orden abierta de ESTE coordinador? ──sí (sin --allow-multiple)──► block <TAL-id> ──► ABORT:orden-abierta
          │no
          ▼
    create ──► PROCEED (se crea la orden)

    fetch/parse falla en cualquier paso ──► return≠0 ──► ABORT:fallo-duro (fail-closed; NUNCA "create" por defecto)
  ```

- **Orden topológico real**: dependencias `blocks`/`blockedBy` → topo-sort + detección de ciclos
  (ciclo → escala). Issues con blocker externo no resuelto → se excluyen del batch.
- **Prioridad correcta**: remapeo `0(None)→99` (Urgent primero). Replica el patrón ya corregido en
  `talent-channel-operation/scripts/select-issues.sh`.
- **Seguridad GraphQL**: toda query/mutation con **variables** (`jq -n`), nunca interpolación;
  inputs validados (UUID/`TAL-…`/`coord-…`/canal/repo).
- **Setup gated**: el proyecto Coordinación Multi Canal, estados, labels e issue-registro los crea el lead
  (acción sensible); `orchestrate.sh` corre un **preflight** que valida y **falla ruidoso** si falta.
- **Verify-before-dispatch**: toda orden lleva el **estado Linear actual** de cada issue al curar; un
  resume/compact rehidrata intenciones stale (el TaskList del harness NO es fuente de verdad). El
  coordinador re-verifica el estado (no terminal) al despachar (ref 06 §Intención-stale).

## Protocolos del lead (transversales a toda la fábrica)

Protocolos permanentes del lead (2026-07-08), en cascada por toda la fábrica — el Orquestador los
aplica a su capa y los propaga a coordinadores y Mergeador:

- **Cero ociosidad**: ningún actor ni canal queda ocioso. Al liberar → siguiente encargo por **pull**
  de la orden/cola; orden vacía → avisar al Orquestador. El Orquestador **SIEMPRE mantiene una ola
  adicional pre-curada** (ref 05 §Ola pre-curada) para que ningún coordinador espere asignación.
  - **El supervisor es DUEÑO de la ocupación de sus subordinados** (finding del CEO,
    `feedback-ociosidad-subordinado-culpa-orquestador`): la ociosidad de un subordinado es **culpa
    del supervisor**, no del subordinado. Disciplina operativa del Orquestador sobre sus
    coordinadores (y de cada coordinador sobre sus canales, en cascada), en **DOS pasos SEPARADOS
    (observar ≠ actuar)**:
    - **(1) OBSERVAR** — barrido de subordinados cada ~15 min que solo **LEE** estado (busy/ctx/idle) y
      **emite candidatos**. En modo Torre es `torre-sweep.sh` (ref 09 §Sweep), **read-only** (cosecha +
      resumen, NO toca paneles); en manual, el barrido periódico es igual de obligatorio. El sweep
      **no ejecuta** el protocolo de disponibilidad — solo detecta.
    - **(2) ACTUAR** — sobre los candidatos con **idle REAL**, el supervisor aplica
      EXPLÍCITAMENTE el **nudge/reasignación/cierre** como paso propio (`send-keys`/relay, `torre-relay`;
      nunca el sweep read-only): destrabar/reasignar, no esperar a que avisen. **El disparador NO es
      un umbral de tiempo a secas** (un thinking pesado va 2-9 min sin output con 0 procesos, y un
      gate e2e con migración tarda 40-60 min): es **idle sobre un watcher/gate MUERTO** — contexto
      del pane idéntico en 3+ cortes + 0 procesos de trabajo + gate/watch terminado sin acción
      posterior (clasificación trabajo-genuino-vs-idle-real en ref 09 §Supervisión sin interrumpir).
      Los turnos **terminan cosechando** (pull del siguiente encargo, cerrar órdenes `Done`,
      re-pickear `bounced`), **nunca esperando pasivo**.
- **Compact-60 (en cascada)**: al llegar el contexto de un actor (o del propio Orquestador) al **60 %**
  (supersede el >70 % previo), y solo en checkpoint limpio: (1) el supervisor exige al actor el
  **fichero de regreso** (estado exacto, en-vuelo, próximos pasos, IDs/refs) escrito FUERA de la
  sesión y VERIFICADO (nunca "copiar fuera→`/compact`→pegar" a secas — ese resumen omite el gate);
  (2) `/compact`; (3) al volver, **paso-0 como primer acto**, nunca autoevaluado por el actor
  recién compactado, que retoma del fichero. En modo Torre lo vigila el Orquestador (barra `ctx:`
  del pane); en modo manual, cada actor se auto-vigila y avisa al lead. Coordinadores y Mergeador
  aplican el MISMO protocolo con sus canales (dev y auditor). Complementa (no sustituye) la
  verificación de identidad y la purga de TaskList stale del post-resume (ref 09 + runbook Torre).
  Doctrina canónica en `talent-context`; implementación ejecutable en `scripts/torre-*`
  (ctx-watcher `torre-compact.sh check`).

## Quick Start

```bash
# 0) Estado read-only (setup + órdenes abiertas + registro de flota)
bash scripts/status.sh

# 1) Ver el registro de flota / la cuadrilla de un coordinador
bash scripts/registry.sh --coordinador coord-talent

# 2) Curar un batch (solo lectura): JSON con issue_ids ordenados + precedencia + exclusiones.
#    --coord-project excluye la RESERVA (issues ya en órdenes abiertas del proyecto Coordinación); sin
#    él (ni TORC_COORD_PROJECT_ID en el entorno) la reserva NO se excluye — solo válido en dry-run pre-setup.
bash scripts/select-work.sh --project <uuid-proyecto-producto> --coord-project <uuid-coordinacion> --milestones "<uuid> <uuid>" --cap 4

# 3) PREVIEW de la orden que se crearía (no escribe en Linear)
bash scripts/orchestrate.sh --dry-run --project <uuid> --coordinador coord-talent --cap 4

# 4) Crear la orden de trabajo (la escribe en Linear; el coordinador la LEE y despacha a mano).
#    Rehúsa fail-closed si ya hay una orden abierta del mismo coordinador (respeta la cadencia
#    "siguiente batch al cerrar la anterior"); --allow-multiple salta SOLO ese guard (no la idempotencia/solape).
bash scripts/orchestrate.sh --project <uuid> --coordinador coord-talent --cap 4 [--allow-multiple]

# 5) Torre de Control (TAL-2278; doctrina en ref 09 + runbook torre-de-control):
bash scripts/torre-resume.sh <actor> --cwd <pwd-exacto> [--list|--uuid <uuid>|--dry-run]  # resume canónico
bash scripts/torre-sweep.sh [actor…] [--ansi]                    # cosecha read-only + resumen busy/ctx/flags
bash scripts/torre-relay.sh <actor> --text '…'|--file <ruta>     # relevo anti-fantasma (post-paste verificado)
bash scripts/torre-compact.sh check|run <actor>                  # protocolo compact-60 (nonce anti-stale)
```

Config en `scripts/00-config.sh`; los IDs del setup gated van en el escrow
`~/.config/talent-orchestrator/agents.conf` (gitignored). Helpers en `scripts/lib.sh`.

*Quick Start bash-only (Acceptable Variation 6 del Gold Standard): este skill ES una operación de
CLI/Linear por token, no una API multi-lenguaje.*

## References

| Archivo | Contenido |
|---|---|
| `references/01-rol-y-modelo.md` | Rol delgado, dos capas Linear, frontera con el Coordinador |
| `references/02-convenciones-linear.md` | Proyecto Coordinación Multi Canal, estados, labels, IDs, setup gated |
| `references/03-registro-de-flota.md` | Issue-registro, tabla, sin secretos, normalización de canal |
| `references/04-orden-de-trabajo.md` | Anatomía, prosa + bloque JSON, DoD, cierre |
| `references/05-seleccion-y-curado.md` | Criterio, reserva, topo-sort, prioridad, cap, **dependencias reales (`blockedBy` de Linear vs memoria) + solape de archivos/contrato** |
| `references/06-handoff-y-cadencia.md` | El coordinador lee y despacha a mano; cadencia desacoplada del merge |
| `references/07-gotchas.md` | Trampas (prioridad 0=None, FNR==NR vacío, ID! vs String!, sin secretos) |
| `references/08-bundling.md` | **Fábrica v2**: algoritmo de curado de encargos/bundles, **cross-declaration cross-milestone + qué queda FUERA + pre-flag editorial-GO + allowlist-a-lead**, prioridad de la cola del Mergeador, **bounce-to-pool (Decisión 6: Backlog + label `bounced` + comentario)**, heads-up pre-emptivo, findings-por-origen |
| `references/09-torre-de-control.md` | **Torre de Control** (capa opcional): modo dual, detección de sesión, sweep, send-keys anti-fantasma, **postura host vs contenedor + sin MCP heredado + Regla 0 extendida (`tco_ensure_model`) + "Press up" dos causas**, monitor, doctrinas D1/D2/D3; helpers versionados `scripts/torre-*.sh` (TAL-2278) |
| `references/10-cuentas-y-pozos.md` | **Cuentas y pozos** (TAL-2294): ledger como fuente de verdad, pozos derivados de las claves (nunca enumerar), cosecha=MOVE un-login-un-lugar (Codex), política reset-7d-más-cercano, los 4 muros (puntero), coordinador único; **§7 (VIGENTE 2026-09-01): tokens de larga duración por cuenta en escrow + lectores de cuota + rotación automática por reset semanal (`scripts/pozos-*.sh`)** |
| `references/11-multi-fabrica-y-ceo.md` | **Multi-fábrica + capa CEO** (TAL-2296): jerarquía CEO→orquestadores→(coordinadores+mergeador), doctrina de modelos (CEO Opus vigente, PM Sonnet vigente; coordinación `Sonnet vigente` `high`; **canales por fase** — plan Opus-`xhigh` / coding Sonnet-`high` / fallback Opus vigente`high` a 5 rondas, TAL-2675), retarget = drain+recycle+manifiesto, intake de proyectos desde la matriz; sync-espejo con el README del motor |

## Next Steps

- ¿Necesitas el rol delgado del Orquestador y la frontera con el Coordinador? → `references/01-rol-y-modelo.md`
- ¿Vas a tocar el setup de Linear (proyecto Coordinación, estados, labels, IDs base)? → `references/02-convenciones-linear.md`
- ¿Necesitas leer o editar el issue-registro de la flota? → `references/03-registro-de-flota.md`
- ¿Necesitas la anatomía exacta del cuerpo de una orden (prosa + JSON)? → `references/04-orden-de-trabajo.md`
- ¿Vas a tocar el criterio de curado, la reserva o el topo-sort? → `references/05-seleccion-y-curado.md`
- ¿Dudas sobre cadencia, cierre manual o los regímenes de drenaje? → `references/06-handoff-y-cadencia.md`
- ¿Depurando un comportamiento inesperado? → `references/07-gotchas.md`
- ¿Curando un encargo/bundle multi-issue (Fábrica v2)? → `references/08-bundling.md`
- ¿Operando la Torre de Control (sweep/relay/compact/resume)? → `references/09-torre-de-control.md`
- ¿Tocando credenciales, cuentas o pozos de la flota? → `references/10-cuentas-y-pozos.md`
- ¿El lead pide la «tabla de pozos»? → `bash scripts/pozos-cuotas.sh` y pegar la salida (uso 5h/7d/Fable por cuenta, orden por reset semanal, CDMX)
- ¿Un canal/torre sin cuenta activa, «session limit», o compact/cambio de cuenta? → `references/10-cuentas-y-pozos.md` §7 (paso-0 en §7.6; `scripts/pozos-cuotas.sh` + `pozos-rotador.sh`)
- ¿Trabajando en la jerarquía multi-fábrica o la capa CEO? → `references/11-multi-fabrica-y-ceo.md`

## Critical Gotchas

1. **Prioridad `0 = No priority`** — no la más alta; remapear `0→99` para que Urgent (1) quede primero. → [ref 07](references/07-gotchas.md)
2. **`FNR==NR` falla con archivo vacío** — `torc_exclude` usa `BEGIN{getline}`; sin ello un archivo vacío se come todos los candidatos. → [ref 07](references/07-gotchas.md)
3. **Tipos GraphQL: `ID!` vs `String!`** — `project:{id:{eq:$pid}}` espera `$pid:ID!`; con variable `String!` Linear da 400; `project(id:)`/`issue(id:)` sí son `String!`. → [ref 07](references/07-gotchas.md)
4. **`${2:-{} }` en bash está mal parseado** — el primer `}` cierra la expansión; usar `${2:-}` + chequeo aparte para evitar JSON inválido. → [ref 07](references/07-gotchas.md)
5. **Variables GraphQL siempre, nunca interpolación** — todo con `jq -n --arg/--argjson`; inputs validados (UUID/`TAL-…`/`coord-…`). → [ref 07](references/07-gotchas.md)
6. **Setup gated: no auto-crear proyecto/labels/estados** — el preflight valida y falla ruidoso; los IDs van en `agents.conf` del escrow. → [ref 07](references/07-gotchas.md)
7. **CERO secretos en Linear** — la issue-registro mapea identificadores, nunca guarda credenciales (regla 18). → [ref 07](references/07-gotchas.md)
8. **Idempotencia: la reserva vive en Linear** — no en locks locales del coordinador; `torc_precreate_check` es el guard fail-closed. → [ref 07](references/07-gotchas.md)
9. **Relations: shape real es `relations.nodes[].type`** — no `relations[].type`; verificado contra API; el cheatsheet local solo documenta la creación. → [ref 07](references/07-gotchas.md)
10. **Truncación de relaciones = fail-closed SOLO si `pageInfo.hasNextPage=true`** — `relations(first:50)`; si se alcanzan 50 nodos y `hasNextPage=true` hay más páginas sin leer y se aborta la selección (un blocker omitido crea una orden no accionable). Si `hasNextPage=false` con exactamente 50, esas 50 SON el total real — no es truncación, no se aborta. → [ref 07](references/07-gotchas.md)
11. **Bloqueo transitivo: cascada a punto fijo ANTES del topo-sort** — si un parent se excluye por blocker externo, `torc_cascade_blocked` propaga la exclusión a sus children. → [ref 07](references/07-gotchas.md)
12. **Gate oculto en la descripción de la issue** — un candidato sin `blocked-by` en Linear puede tener un gate del lead en el body; releer antes de asignar canal. → [ref 07](references/07-gotchas.md)
13. **`state`+`labels` insuficiente para decidir despacho** — el bloqueo puede vivir en prosa del body (`BLOQUEADA por`, `depende de`, `descopado`); leer la descripción entera. → [ref 07](references/07-gotchas.md)

## Cross-Skill Integration

| Skill | Frontera |
|---|---|
| `linear-skill` | Mismas convenciones GraphQL que este skill reimplementa en paralelo (variables tipadas vía `jq -n`, nunca interpolación; `ID!` vs `String!`; paginación por cursor `hasNextPage`/`endCursor`) — riesgo de divergencia silenciosa si Linear cambia su schema; consultar `linear-skill` antes de tocar cualquier query GraphQL de `scripts/lib.sh`. |
| `talent-channels` | Provisiona la topología física (Incus + Tailscale) que el registro de flota (`references/03-registro-de-flota.md`) referencia por `channel_id`/`container`/`machine` — el Orquestador NUNCA provisiona canales, solo lee el registro. |
| `talent-channel-operation` | Coordinador (1ª estación): LEE la orden de trabajo que este skill crea y despacha cada issue a mano (`dispatch.sh <carril> <TAL-id>`); su pipeline termina en la entrega (PR draft + HANDOFF). |
| `talent-merger` | Mergeador (2ª estación): consume los drafts+HANDOFF del Coordinador, corre CodeRabbit y mergea; el Orquestador cura la prioridad de su cola y recibe los bounce-to-pool (`references/08-bundling.md`). |

## Out of scope

- **Ejecutar el batch / manejar canales** → es el Coordinador (`talent-channel-operation`), cuyo
  pipeline termina en la entrega draft.
- **Mergear / correr CodeRabbit / aplicar migraciones** → es el Mergeador (`talent-merger`).
  **El Mergeador es lo último que se apaga en un drenaje**: el Orquestador secuencia el
  drenaje-a-cero (ref 06 §Regímenes) para que la estación de merge siga viva hasta el último merge.
  El Orquestador **JAMÁS mergea** ni recibe `CODERABBIT_API_KEY` — la separación de credenciales ES
  la separación de estaciones (ADR-0043). (Ruling del lead 2026-07-14: la excepción de merge del
  Orquestador bajo drenaje/PARO queda RECHAZADA — cierra la ratificación abierta 1 de TAL-2658.)
- **Crear el setup de Linear** (proyecto/labels/estados/registro) → acción gated del lead.
- **Provisionar la flota** → es `talent-channels`.
- **Ejecutar/despachar la orden**: leerla y lanzar cada encargo a mano (`dispatch.sh`), la
  validación del HANDOFF y el cierre de la orden son del Coordinador (`talent-channel-operation`).

## Paquete de fábrica

Este skill es miembro del **paquete de skills de fábrica** (16): linear-skill · skill-creator · talent-buzz ·
talent-ceo · talent-channel-operation · talent-channels · talent-context · talent-coordination ·
talent-issue-craft · talent-llm-local · talent-memoria · talent-merger · talent-orchestrator · talent-pm · talent-prd · talent-repo-onboarding. El paquete viaja JUNTO y
**motor-primero**: canónico en el repo motor `talent-factory` (`skills/`), propagado como núcleo
a los repos de producto con `skill-creator/scripts/sync-package.sh` (overlays por repo intactos)
y validado con `skill-creator/scripts/validate-package.sh` + `<skill>/invariants.tsv`.
Manifiesto: `skill-creator/assets/package.manifest` · doctrina y ratchet (D6): `skill-creator/references/09-paquete-de-fabrica.md`.

Registro de modelos: `~/.config/talent-channel-operation/modelos.conf` del usuario del rol; CEO y plan/fallback usan Opus vigente, los demás roles y salud Sonnet vigente. Resolver tras acreditar Claude con `talent-channel-operation/scripts/resolver-modelos.sh`.
