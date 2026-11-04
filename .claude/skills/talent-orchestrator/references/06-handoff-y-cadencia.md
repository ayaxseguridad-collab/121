# 06 — Handoff y cadencia

## Table of Contents

- [Lectura, no consumo automático](#lectura-no-consumo-automático)
- [Ciclo de una orden](#ciclo-de-una-orden)
- [Reserva e idempotencia](#reserva-e-idempotencia)
- [Re-estrategia](#re-estrategia)
- [Intención-stale en resume (verify-before-dispatch)](#intención-stale-en-resume-verify-before-dispatch)
- [Cierre (manual)](#cierre-manual)
- [Regímenes de operación y drenaje-a-cero (T7 — doctrina canónica)](#regímenes-de-operación-y-drenaje-a-cero-t7--doctrina-canónica)
  - [Cola Dependabot bajo drenaje (T10 — doctrina canónica)](#cola-dependabot-bajo-drenaje-t10--doctrina-canónica)

## Lectura, no consumo automático

El Orquestador **no maneja carriles ni paneles**. Crea la orden en Linear y el **Coordinador la LEE**
cuando su cuadrilla se libera y **despacha cada issue a mano** (`dispatch.sh <carril> <TAL-id>`, uno a
uno). No hay consumidor automático: la orden es un **artefacto de lectura humana** (más un bloque JSON que
el Orquestador usa para su reserva). Esto desacopla y tolera fallos: si un coordinador cae, no se pierde
estado — todo está en Linear.

## Ciclo de una orden

```text
Orquestador crea orden (To Do) — issues agrupados en ENCARGOS (bundles, ref 08)
        │ el coordinador la LEE
Coordinador: In Progress → despacha cada encargo a mano con su cuadrilla
        │  (si se bloquea: Needs Input + pregunta exacta → lead responde → reanuda)
        │  (encargo de spec/ADR sobre base ambigua → GO-bloqueo: NO redactar, escalar UNA
        │   pregunta de contrato al lead — salida VÁLIDA, no fallo; ver ref 09 D3)
Coordinador: entrega cada encargo como PR DRAFT + HANDOFF verificado → mueve la orden a Done
        │
Orquestador ve Done → compone el SIGUIENTE batch (Linear ya actualizado)
        ⋯ en paralelo, el Mergeador consume los drafts y mergea (la cadencia de batches
          queda DESACOPLADA del merge — ADR-0043)
```

## Reserva e idempotencia

Una issue de producto no debe entrar en dos órdenes a la vez. La **reserva vive en Linear**:
`select-work` excluye lo que ya está en órdenes abiertas; antes de crear, `orchestrate` corre un chequeo
**fail-closed** (`torc_precreate_check` sobre un fetch común fail-closed) con un token **tri-state**:
**una orden abierta por coordinador** (rehúsa un segundo batch mientras la anterior no esté Done —
respeta la cadencia; `--allow-multiple` salta **solo** ese guard), **idempotency-key** (no duplica una
orden idéntica) y **solape** de `issue_ids`. **Garantía y su límite**: este guard es fail-closed **bajo la
asunción operativa `un orquestador a la vez`** (guard de instancia única por coordinador vía lock
host-local); endurece el caso común (doble-run en el mismo host, o re-componer sin cerrar la orden previa)
pero **no** es atomicidad cross-host — dos orquestadores en máquinas distintas podrían ambos leer "sin
orden" y crear dos (Linear no da lock transaccional). Esa race residual se acepta bajo el supuesto.

## Re-estrategia

El Orquestador re-prioriza en las **fronteras de batch** (cuando una orden cierra). La preempción a
mitad (P0 entrante) es una decisión del lead, no del scheduler.

## Intención-stale en resume (verify-before-dispatch)

Un `claude --resume` o un `/compact` **rehidratan intenciones muertas**: el contexto
conversacional y el **TaskList del harness** pueden resucitar un issue ya Done/mergeado (visto
en el piloto: TaskList mostrando un `TAL-…` Done hace días — casi se re-despacha). **El
TaskList del harness NO es fuente de verdad; Linear + la orden curada sí.** Por eso:

- Toda **orden de trabajo** lleva el **estado Linear actual** de cada issue en el momento de
  curar (además del `issue_ids`), y un recordatorio explícito **"verify-before-dispatch"**.
- El **coordinador re-chequea el estado Linear del issue** (no terminal) al despachar (su gate
  pre-issue) — esta doble verificación aguas arriba↔aguas abajo es la que evita el near-miss.
- Tras cualquier resume/compact del Orquestador: re-derivar el estado desde Linear, nunca
  confiar en el spinner/TaskList (ver el runbook de la Torre, `references/09-torre-de-control.md`).
- **Race cross-torre al despachar = mitigación PARCIAL, no garantía**: re-verificar que el issue
  sigue `Backlog` INMEDIATAMENTE antes del dispatch **reduce** la ventana pero **no la elimina** — es
  check-then-act **no atómico**: dos torres pueden leer `Backlog` a la vez y ambas continuar (visto:
  `TAL-1901` reclamado y trabajado DOS veces). El preflight no detecta el "recién reclamado por otra
  torre" porque **Linear no da lock transaccional** (misma limitación que §Reserva reconoce para la
  creación de órdenes). Un **lock de claim cross-torre** sería el fix real, pero **no existe hoy** —
  se menciona como ideal, no se opera como si estuviera disponible.

## Cierre (manual)

El Coordinador cierra la orden **a mano** moviéndola a **Done** cuando su batch queda
**entregado**: todos los encargos como PR draft + HANDOFF verificado + issues In Review
(DoD Fábrica v2, ref 04). Opcionalmente deja una línea con los PRs entregados. El merge y
la BD prod son del Mergeador y NO gatean el cierre de la orden. No hay artefacto de cierre
escrito por máquina: el estado `Done` en Linear es la señal que el Orquestador observa para
componer el siguiente batch.

## Regímenes de operación y drenaje-a-cero (T7 — doctrina canónica)

La fábrica opera en UNO de tres regímenes; el Orquestador lo declara y los coordinadores lo
aplican (su lado: `talent-channel-operation` invariante 12):

| Régimen | Qué significa | Dispatch |
|---|---|---|
| **Alta cadencia** | Producción intensiva: cero-idle, sweep agresivo, ola pre-curada | Continuo, PULL al cerrar cada encargo |
| **Tranquilo** | Ritmo sostenible: idle aceptable, sin presión de cola | Normal, sin exigencia de cero-ociosidad |
| **PARO** | Parada ordenada (fin de ciclo, incidente, decisión del lead) | **NINGÚN dispatch nuevo** — la única excepción son los **re-fixes de PRs rebotados** ya en vuelo |

**Protocolo de drenaje-a-cero** (transición a PARO / cierre de ciclo): la cola de PRs abiertos se
lleva a CERO clasificando cada PR en una de tres salidas —

1. **Limpio y vigente** → mergear (vía Mergeador, cola priorizada).
2. **WIP stale de varios días** → **cerrar-con-nota** (reabrible: la nota documenta estado exacto
   y cómo retomar; cerrar NO es cancelar el trabajo).
3. **Conflictivo con main** → rebase si el residual vale, o cierre (superseded-vs-residual, ref 08).

**El Mergeador es la última estación que se apaga**: el Orquestador secuencia el drenaje para que
la estación de merge siga viva hasta sellar el último PR limpio. El Orquestador no asume el merge
(no tiene `CODERABBIT_API_KEY`; la separación de credenciales ES la separación de estaciones —
ADR-0043).

**GO-heads-unpushed bloquean el drenaje**: un canal puede tener commits con GO de auditoría **sin
pushear** — origin no los ve, el Mergeador no puede sellar un head no-auditado-visible, y el
drenaje se atasca. Drenar exige **autorizar la publicación del GO head** por la vía normal del
canal (regla 13 + sentinel draft), no dejarlo morir en el working tree.

**Reactivación tras un PARO — la CONDUCE el CEO**: reactivar autores en paralelo exige re-brief
por canal (estado, rama, qué sigue); un `continuemos` suelto NO reanuda nada útil. Además, al
reactivar autores sobre PRs cedidos a la estación: **re-verificar `headRefOid` + `isDraft` en
vivo ANTES de entregar** — si el Mergeador avanzó el PR durante el paro, **stand-down** (doctrina
T5 en `talent-channel-operation` ref 05).

### Cola Dependabot bajo drenaje (T10 — doctrina canónica)

Al drenar, los PRs de Dependabot se triagean con estas reglas:

- **Major sin parche de seguridad** → **cerrar con nota** (el bump se retoma como issue curada,
  no como PR automático colgado).
- **Grupo que INCLUYE un parche de seguridad** → **NUNCA cerrar**: se prioriza para merge.
- **Los group-bumps MEZCLAN severidades** → inspeccionar el **DIFF** (qué paquetes y a qué
  versiones), no el título del PR.
- **Build-break por desync de `pnpm.overrides`** → es un fix de 1 línea en el lockfile, no una
  migración — arreglarlo en el propio PR, no cerrarlo por "roto".
- **CI verde NO cubre majors de runtime**: un major de una lib de charts/UI puede compilar y pasar
  gates sin renderizar bien — los majors de superficie visual van a **hold** (verificación manual)
  aunque el CI esté verde.
- **Fallo del step de install en ~9 s** = firma de **peer-deps/lockfile** (resolución imposible),
  no un flake de red — diagnosticar el árbol de dependencias, no re-lanzar.
- **Excepción de nombre de rama**: la exención de `validar-rama-pr` para ramas `dependabot/*` es
  **por AUTOR del PR** (estable ante pushers) en el workflow de referencia — un commit a mano de
  otro actor NO la rompe ahí; si un gate local homólogo falla en una rama dependabot con
  hand-commits, tratarlo como **falso-positivo con resolución trazada** y verificar la
  implementación del motor (no verificable desde el repo de producto).
