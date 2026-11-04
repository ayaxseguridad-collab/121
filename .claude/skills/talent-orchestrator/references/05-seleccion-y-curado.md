# 05 — Selección y curado (`select-work.sh`)

## Table of Contents

- [Pipeline](#pipeline)
- [Criterio (alineado con el repo)](#criterio-alineado-con-el-repo)
- [Dependencias reales, no de memoria (`blockedBy` de Linear)](#dependencias-reales-no-de-memoria-blockedby-de-linear)
- [Ola pre-curada (cero ociosidad aguas arriba)](#ola-pre-curada-cero-ociosidad-aguas-arriba)
- [Gotchas cubiertos por tests](#gotchas-cubiertos-por-tests)

Produce un JSON `{issue_ids:[ordenados], precedence:[[child,parent]], excluded:{reserved,blocked,cycle}}`.
El pipeline completo (accionables → reserva → prioridad → blockers/cascada → topo-sort → cap) tiene su
diagrama en `SKILL.md` §Garantías; aquí el diagrama cubre la parte más delicada — de dónde sale la
**dirección** de una dependencia:

```text
Fuente de precedencia: SIEMPRE hechos, nunca memoria del turno

  1) relations blockedBy/blocks REALES de Linear ──► dirección PRIMARIA
                    │ (si no declarada pero el código/milestone dice que sí)
                    ▼
  2) código + milestones (evidencia objetiva) ──► fija precedencia igual de vinculante
                    │
                    ▼
  memoria de una sesión previa ──► NUNCA fuente (rehidrata stale tras resume/compact)
```

## Pipeline

1. **Lee** issues del proyecto (paginado) con `priority`, `state.type`, `assignee`,
   `projectMilestone`, y `relations{type, relatedIssue{identifier, state.type}}`.
2. **Accionables**: `state.type` ∈ {`backlog`,`unstarted`} **y** sin `assignee` (+ milestones si se
   pasaron). Multi-milestone: `--milestones "uuid uuid"` (vacío = todo el proyecto).
3. **Reserva** [idempotencia]: lee `issue_ids` de las órdenes **abiertas** del proyecto Coordinación
   y **excluye** esos TAL del batch. Sin `--coord-project` no puede excluir (solo OK en dry-run).
4. **Orden de prioridad**: remapeo `0(None)→99` → Urgent(1) primero; desempate por `sortOrder`.
5. **Dependencias** [topo-sort]:
   - `blockedBy R` → arista `(this, R)`; `blocks R` → arista `(R, this)`.
   - Blocker **externo** al batch y **no completado** → el issue se marca **blocked** y se excluye.
   - Topo-sort (Kahn) determinista; **ciclo → exit 3** (escala, no emite batch).
6. **Cap**: `--cap N` (default = #canales `dev` de la cuadrilla, o `TORC_DEFAULT_CAP`).

## Criterio (alineado con el repo)

Excluir Done/In-Progress/asignadas; priorizar piezas mergeables de forma autónoma; issues con
`estimate>5` deberían venir descompuestas (regla 21). El Orquestador **no fabrica scope**: solo
ordena lo que ya está en Linear. Selección ≠ arranque (el coordinador y su gate pre-issue deciden
el arranque real).

## Dependencias reales, no de memoria (`blockedBy` de Linear)

El grafo de precedencia se deriva de **hechos**, nunca de la memoria del turno (que rehidrata stale
tras resume/compact — ver `references/06` §Intención-stale). Dos fuentes de verdad, en este orden:

1. **Relaciones `blockedBy`/`blocks` reales de Linear** (`relations.nodes[].type` — ya las lee el
   pipeline, paso 5). Son la fuente primaria de la **dirección** de dependencia.
2. **El código y los milestones**: cuando dos issues del batch **no** declaran `blockedBy` en Linear
   pero el código dice que una es cimiento de la otra (una RPC que la UI consume; un contrato/tipo
   que otra issue toca; un milestone que gate a otro — ver `project-roadmap-pipeline-proyectos`), el
   Orquestador **fija la precedencia** por esa evidencia (milestones + paths esperables), **no por
   recuerdo** de una sesión previa. Si la dependencia es de código pero el código aún no existe
   (spec/ADR sin aprobar), la issue se cura **plan-only, código gated**: entra al batch para
   PLANIFICAR, con nota explícita de que el arranque de implementación queda gated hasta el GO del
   contrato (el coordinador lo respeta en su gate pre-issue; casa con D3 de `references/09`).

   Para **follow-ups** (issue que depende de que otro encargo ya esté mergeado): el prerequisito debe
   estar **verificado en `origin/main`** antes de despachar — no basta que el PR esté aprobado o
   merged localmente. Confirmar el HEAD remoto (`git ls-remote origin refs/heads/main` +
   `git log origin/main --oneline -1`) **NO basta por sí solo**: eso solo prueba que `origin/main`
   existe y tiene un HEAD, no que el commit/PR específico del follow-up esté DENTRO de esa historia.
   El chequeo que realmente confirma que el follow-up aplica es
   `git merge-base --is-ancestor <sha-del-follow-up> origin/main` (rc=0 ⇒ el commit referenciado
   ya está mergeado en main; rc≠0 ⇒ **no asumir** que aplica — el follow-up se queda plan-only/gated
   hasta que el prerequisito real aparezca en `origin/main`).

**Solape de archivos/contrato entre issues del batch** — **dos casos distintos, nunca fundir**:

- **(a) Candidatas frescas SIN PR (flujo por defecto de este §)**: el solape se **estima** por
  **paths/contratos esperables** (dominio del título/descripción) + evidencia de código/milestone +
  precedencia. Es el mecanismo por defecto del curado pre-dispatch. Dos issues que van a pisar el
  **mismo archivo o el mismo contrato** (tipo, RPC, columna, config) **no son concurrentes**: o se
  serializan por `precedence`, o se funden en un mismo encargo, o se separan a olas distintas. Un
  solape no declarado en Linear pero visible en el código es tan vinculante como un `blockedBy`
  explícito — la dirección la da el milestone/código, no la memoria.

- **(b) Encargos con PR/draft YA ABIERTO** (encargos en vuelo o draft adoptable): la comparación es
  **medida real** — `gh pr view <N> --json files | jq '[.files[].path]'` para cada PR del par.
  **Fórmula exacta** (evita ambigüedad de qué cuenta como "70%"):

  ```text
  paths(A) y paths(B): sets de paths NORMALIZADOS (deduplicados; un rename cuenta por el path
  NUEVO reportado por gh pr view, nunca como dos entradas distintas)

  overlap_ratio = |paths(A) ∩ paths(B)| / min(|paths(A)|, |paths(B)|)
  ```

  El **denominador es el MENOR de los dos conjuntos**, no la unión ni el mayor: un PR pequeño
  casi totalmente contenido dentro de uno grande debe disparar consolidación aunque el PR grande
  tenga muchos archivos propios adicionales — usar la unión diluiría ese caso y lo dejaría bajo
  el umbral pese a ser el mismo problema (evidencia #1111×#1187: PR pequeño de 8 archivos, 7
  compartidos con el otro PR → `overlap_ratio = 7/8 = 0.875`, el denominador es el 8 del PR
  chico, no el total combinado de ambos). `overlap_ratio ≥ 0.70` → consolidar; `< 0.70` →
  declarar por qué no solapan. Nunca se exige `gh pr view` sobre candidatas sin PR.

Complementa la disjunción de encargos de `references/08`.

**Decisión 7 — ownership de limpieza de refs va al canal que YA toca el archivo** (Ev: TAL-2022
vs TAL-2020): cuando una issue implica **limpiar/actualizar referencias** (imports, callers,
tipos, docs de contrato) a algo que OTRA issue del batch está a la vez modificando en el mismo
archivo, la limpieza NO se cura como encargo independiente que pisaría el fichero en paralelo. Se
**reasigna al canal que YA toca ese archivo** por la otra issue, con:

- **Dependencia dura** (`precedence`) del que limpia hacia el que modifica — la limpieza corre
  DESPUÉS, sobre el archivo ya en su forma final, nunca concurrente.
- **`closes` SOLO con la issue COMPLETA**: el PR que absorbe la limpieza usa `closes ABC-N` de la
  issue de refs ÚNICAMENTE si con ese PR la issue queda resuelta ENTERA. Si la issue abarca más
  superficie que la que el canal toca, el PR usa **`refs ABC-N`** (la issue queda ABIERTA con el
  residual anotado en comentario), o el residual se **materializa ANTES del merge en una issue
  follow-up trazable** (relación `blocks`/`parent` según caso) y solo entonces el PR puede cerrar
  la original. Motivo: `closes` parcial cierra la issue COMPLETA al merge (GitHub/Linear no saben
  de porcentajes) y el residual desaparece de la cola accionable — un `closes` inflado que finge
  cerrar refs en ficheros que el PR no abre es exactamente eso.

Serializar+absorber la limpieza en el dueño del archivo evita el merge-collision y el `closes`
deshonesto de dos PRs pisándose el mismo fichero.

**Cola de reserva del SLA-transición: curar CROSS-PROJECT dentro de la initiative, con blocked-by
paginado/fail-closed**: el pool accionable de un SOLO proyecto se agota, así que la reserva que
alimenta el SLA de transición se cura **cross-project dentro de la initiative** (cualquier project de
`Producto Ejemplo`, elegido por afinidad — regla 21 de CLAUDE.md), no de un único proyecto. Y el
filtro blocked-by por `inverseRelations` **NO** puede ser un `first:N` fijo: `inverseRelations(first:8)`
**no pagina ni falla** ante `hasNextPage`, así que un blocker más allá del 8º queda OCULTO y el issue
se despacharía sin prerequisito. Aplicar la MISMA regla fail-closed que a `relations`
(`references/07-gotchas.md`): **paginar hasta agotar la conexión** (`hasNextPage`/`endCursor`) **o
abortar** la selección si quedan páginas sin leer — un blocker omitido crea una orden no accionable.

**Fábrica v2**: sobre las candidatas ya seleccionadas/ordenadas por este pipeline se aplica
el **curado de encargos/bundles** — `references/08-bundling.md` (capa encima, no sustituye
la selección).

## Ola pre-curada (cero ociosidad aguas arriba)

El Orquestador **SIEMPRE mantiene una ola adicional pre-curada** por delante de la que se
está ejecutando: cuando un coordinador libera su cuadrilla y tira del siguiente encargo
(cero ociosidad, ver `## Protocolos del lead` del SKILL), la orden ya debe existir — nunca
un coordinador esperando a que el Orquestador cure. Práctica:

- Mantener un **milestone / plan-maestro** del proyecto activo (Funnel 2.0, Go a Producción,
  etc. — ver `project-roadmap-pipeline-proyectos`) del que salen las olas en orden.
- Al crear una orden, tener ya identificado (aunque no escrito) el batch siguiente; si la
  cadencia "una orden abierta por coordinador" (ref 06) impide crearla aún, dejarla lista
  para emitir en cuanto la anterior cierre.
- Si la cola de un coordinador se vacía y no hay ola pre-curada → es un fallo del Orquestador
  (equivalente aguas arriba a la ociosidad de un canal).

**Umbral de reciclaje <10 min**: un canal que ENTREGA es capacidad ociosa desde el segundo en
que suelta el draft. El objetivo operativo es que ese canal reciba su siguiente encargo en
**menos de 10 min** (casa con `references/11` §«Reciclaje inmediato post-entrega»). Cómo se
sostiene ese umbral:

- **Backlog del coordinador vivo** → el coordinador tira del siguiente encargo ya escrito (la
  ola pre-curada), sin pasar por el Orquestador. Camino normal, latencia ~0.
- **Backlog del coordinador SECO** → el Orquestador cura del pool **en minutos**, no en la
  siguiente frontera de batch. Para que ese curado sea de minutos y no de arranque en frío, cada
  torre mantiene **candidatos pre-curados en su COMPACT-READY** (issues ya accionables, ordenadas
  y con precedencia estimada, listas para emitir en cuanto haga falta) — el Orquestador las emite
  como orden sin re-derivar el grafo desde cero.
- Superar los 10 min de ociosidad post-entrega se lee como el mismo fallo que la cola vacía sin
  ola pre-curada: capacidad quemada aguas arriba.

## Gotchas cubiertos por tests

- Prioridad `0=None` al final (no primero).
- `torc_exclude` robusto ante reserva **vacía** (no comerse todos los candidatos).
- Topo-sort detecta ciclos.
