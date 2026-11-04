# 11 — Multi-fábrica y capa CEO

## Table of Contents

- [Jerarquía](#jerarquía)
- [Doctrina de modelos (multi-fábrica)](#doctrina-de-modelos-multi-fábrica)
- [Retarget de una fábrica = drain + recycle + manifiesto](#retarget-de-una-fábrica--drain--recycle--manifiesto)
- [Supervisión multi-repo: release-to-lead y ruta directa](#supervisión-multi-repo-release-to-lead-y-ruta-directa)
- [Conducción ACTIVA (doctrina de la corrida F1, 2026-07-14)](#conducción-activa-doctrina-de-la-corrida-f1-2026-07-14)
- [Intake de proyectos desde la matriz](#intake-de-proyectos-desde-la-matriz)

Doctrina de la fábrica portátil (`fabrica-portatil-matriz-talent-factory`, TAL-2282): un mismo motor
(`talent-factory` — skills + scripts + manifiestos) sirve a **varias fábricas** en paralelo, cada una
apuntando a un proyecto/repo distinto. El Orquestador **NO es la cúspide**: por encima hay una
**capa META** con dos contrapartes — el **CEO**, que reparte proyectos a orquestadores, y el **PM**,
que define la carga y los criterios de cada producto (rol: skill `talent-pm`; las fábricas nacen
con CEO y PM — orden del lead 2026-07-29). Esta referencia fija la jerarquía, la doctrina de
modelos y el ciclo de retarget de una fábrica.

## Jerarquía

```text
LEAD ── decisiones y GO ──►  capa META:  PM (producto)  ⇄  CEO (fábrica)
CEO ── reparte PROYECTOS ──► ORQUESTADOR (uno por fábrica/proyecto activo)
                                   │ cura batches → órdenes de trabajo (este skill)
                    COORDINADOR(es) + MERGEADOR (por fábrica)
                                   │ 1ª estación (drafts) · 2ª estación (merge)
                              CANALES (vibe-channel-*)
```

- **CEO**: capa META de orquestación (proyecto Linear `Coordinación Multi Canal` / initiative meta
  `Talent Engine`, ver regla 21 EXCEPCION meta). Reparte **proyectos** a orquestadores, recibe
  bounce-to-pool escalado, decide retargets. Es interino hoy (`project-ceo-orquestador-interino-f1`:
  el CEO hace de orquestador de F1 hasta nombrar uno dedicado). Es la interfaz de FÁBRICA con el
  lead; la de PRODUCTO es el PM.
- **PM**: contraparte del CEO en la capa META (rol: skill `talent-pm`). Define y prioriza la
  CARGA de cada producto (intake, criterios de aceptación, dictámenes sobre entregas, fronteras
  bilaterales con terceros) y es la interfaz de PRODUCTO con el lead. NO manda sobre canales ni
  estaciones y NO supervisa la ejecución en vuelo — «el PM no puede ser un freno» (doctrina del
  lead 2026-07-30, TAL-3650): encarga, atiende dudas del CEO y revisa entregas.
- **Orquestador** (este skill): **uno por fábrica/proyecto activo**. Cura batches del proyecto que le
  asignó el CEO; no cruza a otro proyecto sin reasignación del CEO.
- **Coordinadores + Mergeador**: por fábrica (frontera en `references/01`). Un coordinador = un repo.

## Doctrina de modelos (multi-fábrica)

`doctrina-modelos-multifabrica` (lead 2026-07-09; **modelo-por-fase de canales** amplía la doctrina,
TAL-2675, 2026-07-13), en cascada por toda la flota:

| Actor | Modelo |
|---|---|
| **CEO** | **Opus vigente** del registro del usuario |
| **PM** | **Sonnet vigente** del registro del usuario |
| Orquestador · Coordinadores · Mergeador | **`Sonnet vigente` `high`** (política rodante; `max` PROHIBIDO — regla 0) |
| Canales — **PLAN mode** | **`Opus vigente` `xhigh`** |
| Canales — **CODING** | **`Sonnet vigente` `high`** (ahorro de cuota, TAL-2675; IDs completos por regla 0) |
| Canales — **fallback** si el code-gate NO converge en **5 rondas** sobre el mismo fix | sube ESE fix a **`Opus vigente` `high`** |
| Auditor | Codex (sin cambio — no es Claude, fuera de esta doctrina) |

- **CEO usa Opus vigente; PM y coordinación usan Sonnet vigente** — política rodante.
  Cada actor verifica el modelo de su rol. Un actor que hereda otro modelo del
  default de la cuenta se **corrige al ID COMPLETO del modo (p. ej. `Opus vigente`; alias desnudos prohibidos — regla 0)** (ver `references/09` §`tco_ensure_model`; los canales
  ARRANCAN en Opus vigente para el plan, coherente con este corrective).
- Para **Orquestador · Coordinadores · Mergeador** el effort sigue la Regla 0 por MODO (plan `xhigh` /
  coding `high`) independientemente del modelo — modelo y effort son ejes distintos, sin cambio. Para
  **Canales**, el MODELO también depende de la fase: arrancan en Opus vigente (plan `xhigh`) y el
  coordinador los conmuta a Sonnet vigente (coding `high`) en el GO — detalle de la coreografía del switch y
  el contrato de rondas del fallback en `talent-channel-operation` ref 11
  (`references/11-modelo-effort-y-recycle.md` §5/§6).

## Retarget de una fábrica = drain + recycle + manifiesto

Reapuntar una fábrica a otro proyecto NO es re-provisionar la máquina: es un ciclo de tres pasos
(motor portátil, `fabrica-portatil-matriz-talent-factory`):

1. **Drain**: cerrar el trabajo en vuelo del proyecto saliente — órdenes a `Done`, drafts entregados,
   nada a medias. No se retargetea una fábrica con encargos abiertos.
2. **Recycle**: reciclar los actores (contexto fresco con texto de regreso; los canales conservan su
   working tree pero se re-briefean — la mecánica de credenciales/rotación es de `talent-channels`).
3. **Manifiesto**: apuntar el motor al **manifiesto** del proyecto nuevo (`TF_PROJECT`/repo/claves
   consumidas). El manifiesto es el contrato entre el motor y la fábrica; su validación standalone
   vive en `talent-channels` (`scripts/validate-manifest.sh`) — claves consumidas presentes, sin
   duplicados, `TF_PROJECT`/repo coinciden.

## Supervisión multi-repo: release-to-lead y ruta directa

Cuando la fábrica opera un repo NUEVO (sin Mergeador establecido) o un canal debe liberarse con
trabajo en vuelo, el Orquestador supervisa dos flujos especiales (su cara de coordinador vive en
`talent-channel-operation` ref 02 §8):

- **Ruta directa (onboarding de repo)**: la entrega es un **PR normal con los gates corridos y
  sus resultados VERBATIM en el body** (comando + exit code) → **doble spot-check**
  (coordinador y CEO/lead) → **merge del CEO**. El Orquestador verifica que el body trae la
  evidencia de gates ANTES de encolar el spot-check — un PR "confía en mí" no entra en la cola.
- **Release-to-lead**: el canal liberado deja en el issue Linear el plan vigente + los
  **FLAGS/estado VERBATIM** (comentario vía `tco_linear_gql`/`commentCreate`) — el Orquestador
  valida que ese volcado existe antes de dar el canal por liberado; sin él, el retome del lead
  arranca a ciegas.

## Conducción ACTIVA (doctrina de la corrida F1, 2026-07-14)

El fallo dominante de una corrida larga es la orquestación PASIVA: leer snapshots entre ticks sin
CONDUCIR. La fábrica solo "vuela" con orquestación atenta:

- **Cada barrido termina en ACCIÓN** (nudge / gate / entrega / re-cred / reciclaje), no en un
  reporte. Cadencia ~10-15 min; en los huecos entre reportes SE TRABAJA (conducir cada canal a
  entrega). "Nadie ocioso" INCLUYE al orquestador.
- **Coordinador degradado = coste real**: un coordinador cuyo `monitor.sh` murió se PARA cada
  ~25 min (no despierta cuando un canal emite STOP-AUDIT). Síntoma: idle recurrente con trabajo
  committeado sin entregar en sus canales. Fix doble: (a) el coordinador relanza su monitor tras
  cada compact/reinicio; (b) el orquestador monta un AUTO-NUDGE de red (watcher).
- **Watcher 24h — diseño verificado**: vigila cred muerta · caps de uso · canal idle sostenido
  (hash de pane sin cambio ×N + sin spinner) · coordinador parado · mergeador hambriento con
  drafts en cola · contexto ≥75% · cadencia de status stale. **Guarda anti-menú**: JAMÁS
  auto-nudgear si el pane tiene "Enter to select"/"shift+tab to approve"/"Press up" (mensajes
  encolados) o spinner — nunca auto-aprobar un plan. Un shell de background NO exime del nudge
  (un pane congelado con shell de fondo SÍ lo necesita). Nudge por rol: coordinador y Mergeador
  reciben mensajes distintos.
- **Reciclaje inmediato post-entrega**: canal idle tras entregar = capacidad ociosa; reciclarlo al
  siguiente encargo en el mismo barrido. Mantener SIEMPRE una ola adicional pre-curada.
- **La re-run de un gate FAIL es de la ESTACIÓN (Mergeador)**: el orquestador NO lanza una re-run
  paralela "para ayudar" — colisionan en los ficheros `/tmp/lg-$RG` del runner (visto en vivo:
  slate-rm + push pisándose con la re-run del Mergeador).

## Intake de proyectos desde la matriz

Los proyectos nuevos se **depositan en la matriz** (el árbol `Talent Engine/` de sesiones, launcher
`fabrica <proyecto>`). El CEO los recoge de ahí y los asigna a un orquestador con su manifiesto;
el **PM** del proyecto entrega por su lado el intake y la carga priorizada con sus criterios
(skill `talent-pm`) — el CEO asigna la fábrica, el PM la alimenta. El
Orquestador **no inventa proyectos**: trabaja el que el CEO le asignó, contra el manifiesto que
acompaña al retarget. Si el trabajo no encaja en la initiative del proyecto asignado, PARA y escala al
CEO/lead (regla 21).

> **Sync-espejo RESUELTO (paquete v1, 2026-07-23)**: el README del motor ya la documenta.
> La coherencia README↔skill es **SUPERFICIE SENSIBLE de revisión** en todo PR que toque
> cualquiera de los dos lados — SIN enforcement mecánico: los `invariants.tsv` solo alcanzan
> archivos DENTRO de cada skill, no el README del motor (límite declarado del ratchet).
> Nota histórica original: esta doctrina (jerarquía CEO, tabla de modelos,
> ciclo drain+recycle+manifiesto, intake desde la matriz, **regla Mergeador-se-apaga-último bajo
> drenaje-a-cero — TAL-2750**) debe reflejarse también en el README del repo motor `talent-factory`
> — es la fuente compartida por todas las fábricas. Este skill la documenta desde la óptica del
> Orquestador; el README del motor la documenta desde la óptica del operador de la matriz. Mantener
> ambas coherentes. El motor no vive en este repo (clon hermano externo): el edit del README queda
> como follow-up fuera de PRs de producto.

Registro de modelos: `~/.config/talent-channel-operation/modelos.conf` del usuario del rol; CEO y plan/fallback usan Opus vigente, los demás roles y salud Sonnet vigente. Resolver tras acreditar Claude con `talent-channel-operation/scripts/resolver-modelos.sh`.
