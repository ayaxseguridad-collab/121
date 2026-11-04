# 01 — Modelo y roles

## Table of Contents

- [1. Topología](#1-topología)
- [2. Carriles de desarrollo 1-4 [M1]](#2-carriles-de-desarrollo-1-4-m1)
- [3. Carriles de auditoría 5-6 [M3]](#3-carriles-de-auditoría-5-6-m3)
- [4. Actor post-merge según repo](#4-actor-post-merge-según-repo)
- [5. Skills obligatorios por fase [B8]](#5-skills-obligatorios-por-fase-b8)
- [6. Identidad y discreción](#6-identidad-y-discreción)

## 1. Topología

- **Coordinador**: el agente principal de esta sesión. **Orquesta; JAMÁS codifica, audita
  (código/planes) ni ejecuta el git/gh del encargo** (commit, push, PR create — eso es del
  canal). Consulta Linear / GitHub / el backend del repo por **token directo** (NO MCP) en modo
  lectura, aplica gates y decide el despacho.
  - **git del encargo vs git operativo del coordinador** [Mayor 3]: la prohibición es sobre el
    git **del trabajo del encargo**. El coordinador **SÍ** hace su git **operativo** en su
    propio repo local (`git pull --rebase` de `main` + `git stash` del WIP). No
    commit/push/PR del encargo.
  - **Actor de merge (v6.0, ADR-0043)**: *NADIE de esta estación mergea — ni el canal ni el
    coordinador. El único actor de merge es el **Mergeador** (`talent-merger`); esta
    estación entrega PR DRAFT + HANDOFF y pasa al siguiente encargo.*
  - La única "auditoría" del coordinador es la **validación de la entrega** (regla 13),
    reformulada como **verificación de trazabilidad** [Cond. 7]: `verify-handoff.sh` en
    verde + cada hallazgo del code-audit con evidencia objetiva de resolución (commit que lo
    toca + GO de auditoría sobre el head final); **sin proponer código ni emitir juicio
    técnico propio**.
- **Carriles**: contenedores Incus `vibe-channel-NN` (prefijo `TCO_PREFIX`), accedidos con
  `incus exec <contenedor> -- su - vivecoder -c '…'` **sin sudo** (grupo `incus-admin`). Dentro
  de cada uno corre una sesión tmux `v` (`TCO_TMUX`).

Helpers de direccionamiento en `00-config.sh`: `tco_container`, `tco_pane_dev` (`v:.0`),
`tco_pane_audit` (`v:.1`), `tco_repo_path`.

**Modo dual (manual / Torre)**: el coordinador opera en **manual** (su sesión en una terminal
suelta; el lead hace de relay de decisiones y ve el estado por mensaje) o bajo la **Torre de
Control** (su sesión vive en tmux `torre-<coordinador>` y el Orquestador la cosecha con
capture-pane/send-keys, monitorizándola en background). La Torre es **optimización, no
dependencia** — el pipeline y los gates de este skill son idénticos en ambos modos; solo cambia
quién releva y cómo se cosechan los reportes. En modo Torre, las decisiones DURABLES (rulings,
entregas, veredictos de gate) igualmente se dejan en Linear. Mecánica de migración y
switchover: runbook `docs/runbooks/torre-de-control.md` + `talent-orchestrator` ref 09.

## 2. Carriles de desarrollo 1-4 [M1]

`TCO_DEV_CARRILES="01 02 03 04"`. Dos paneles por carril:

- **pane `.0` — equipo de desarrollo** (`TCO_DEV_CLI` + `TCO_DEV_FLAGS`, configurables en
  `agents.conf`; los flags activan el bypass de permisos confinado al contenedor). Implementa el
  encargo: plan, código, entrega (draft-handoff → push → PR draft + HANDOFF).
- **pane `.1` — equipo de auditoría** (`TCO_AUDIT_CLI` + `TCO_AUDIT_FLAGS`, configurables en
  `agents.conf`). Inspecciona plan y diff; emite GO / NO-GO. **Nunca escribe código ni sube a
  GitHub.**
- **`TCO_DEV_CLI` y `TCO_AUDIT_CLI` son UN solo ejecutable** (el nombre de un lanzador —`claude-root`,
  `codex-root`, `claude`, `codex`— o una ruta absoluta). Los flags y opciones van en `TCO_*_FLAGS` y las
  variables de entorno en el lanzador del canal; asignaciones `VAR=valor`, `env`, espacios, metacaracteres
  y rutas relativas se rechazan antes de lanzar nada (ref 03 §3c).

Invariante: **un único issue por carril a la vez**. El carril no avanza de fase sin GO de su
auditoría (Fases A y B).

## 3. Carriles de auditoría 5-6 [M3]

`TCO_AUDIT_CARRILES="05 06"`. **Solo reportan**, no implementan ni crean issues solos:

- **05 — ciberseguridad**: OWASP, controles de acceso en funciones del backend del repo,
  secretos, authz.
- **06 — sistema + Playwright**: build/types, flujos E2E (los flujos concretos los define el
  **anexo del repo**; el coordinador los **releva a mano** al lanzar el carril), regresiones de UX.

Producen un **reporte de findings** (evidencia + severidad + dedupe + cap). La creación de
cada issue en Linear **siempre** pasa por auditoría + autorización explícita del lead — incluso
en modo desatendido (ver `references/07-carriles-auditoria.md`).

## 4. Actor post-merge según repo

**(v6.0 — ADR-0043)** El pipeline de esta estación (A → B → C) termina en la **entrega**;
el merge y el post-merge son del **Mergeador** en todos los repos operados bajo Fábrica v2:

| Repo | Actor post-merge | Detalle |
|---|---|---|
| Academia Ejemplo | **el MERGEADOR** | apply de migraciones + advisors + ledger (`talent-merger`, anexo TA, PROC-M13/M15) |
| Bootcamp Cripto | — | anexo **SUSPENDIDO** hasta propagar Fábrica v2 (ver `anexo-bootcamp-cripto.md`) |

La verificación post-apply sigue siendo **GATE, no cortesía** — ahora del Mergeador
(`talent-merger` ref 06 §3); esta estación cierra en In Review (ref 02 §6).

## 5. Skills obligatorios por fase [B8]

El orquestador **no duplica** otros skills; hace que cada carril los **cargue** en su momento:

| Cuándo (en el carril) | Skill a cargar |
|---|---|
| Toda operación Linear (estados, comentarios, crear issue) | `linear-skill` |
| La entrega (draft-handoff → PR draft + HANDOFF) | plantilla `docs/templates/handoff-pr-draft.md` + runbook `coderabbit-cli-pre-pr.md` § «Entrega draft» (CodeRabbit es del Mergeador — v6.0) |
| Cualquier DB / query / schema del backend | **skill de backend del repo** (según anexo: `convex-skill` en Bootcamp Cripto / el equivalente Supabase en Academia Ejemplo) |
| Si el issue toca docs | `talent-docs` |

Los skills **específicos del repo** (p. ej. el de dominio con carga SIEMPRE-PRIMERO en Bootcamp
Cripto) los lista el anexo activo — el coordinador verifica en el plan de Fase A que el carril
los cargó.

## 6. Identidad y discreción

- **Nunca revelar identidades** entre paneles: el relevo siempre habla de "equipo de
  desarrollo" / "equipo de auditoría" (invariante 2), no de binarios ni personas.
- Diseño **agente-agnóstico**: los binarios reales se parametrizan en `TCO_DEV_CLI` /
  `TCO_AUDIT_CLI` (override en `$SECRET_DIR/agents.conf`). [B1] está WAIVED — nombrar al agente
  está permitido, pero el flujo prefiere los roles.
