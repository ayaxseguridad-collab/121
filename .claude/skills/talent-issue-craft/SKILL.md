---
name: talent-issue-craft
description: >
  Usar SIEMPRE que se cree, redacte, optimice, audite o revise una issue de Linear, o se
  prepare trabajo para agentes ejecutores/revisores: features, bugs, fixes, hotfix,
  operaciones de base de datos, chores, refactors, tests, docs, decisiones, spikes,
  auditorías y contenido/datos. Cubre: elegir tipo/variante (matriz de 14), plantilla gold,
  sellar decisiones, DoD ejecutable, invariantes, gate de despachabilidad, audit-issue
  (fail-closed) y calibración. Trigger keywords: "issue", "crear issue", "escribir issue",
  "optimizar issue", "auditar issue", "plantilla de issue", "issue template", "ticket",
  "historia de usuario", "user story", "bug report", "spec de tarea", "task spec",
  "definition of done", "DoD", "criterios de aceptación", "acceptance criteria", "backlog",
  "despachable", "refinamiento", "grooming", "Linear issue", "write an issue", "improve
  issue", "issue quality", "calidad de issues", "audit-issue", "despachar trabajo". Incluso
  si solo dicen "crea la issue" o "pásalo a Linear", usar este skill.
---

# Talent Issue Craft — Issues estado-del-arte para ejecución agéntica (julio 2026)

## Quick Orientation

Sistema de creación/optimización de issues derivado del análisis forense de un corpus real de ~2000 issues (rechazos de fusión, duplicadas, canceladas y bloqueadas incluidos): 9 tipos × variantes = **14 combinaciones**, un núcleo común de campos duros, rúbricas de verificación para ejecutor/revisores y un auditor con exit-code (`audit-issue`) como enforcement.

| Propiedad | Valor |
|-----------|-------|
| **Tracker objetivo** | Linear (API GraphQL `https://api.linear.app/graphql`) |
| **Autoridad de clasificación** | Marcador `issue-craft:v1` en el body (las etiquetas son cross-check) |
| **Enforcement** | `scripts/issue_craft_helper.ts` — checks duros fail-closed + score con umbral calibrable |
| **Gate operativo** | SOLO `--issue` + `classification_source=marker` + `operational_gate_eligible=true` + exit 0 |
| **Idioma del contenido** | Español neutro; portable a cualquier repo vía `templates/perfil-de-repo.md` |
| **Verificado** | Schema GraphQL vivo + docs oficiales de Linear · `last_verified: 2026-07-20` |

**Para profundizar, leer el reference adecuado antes de escribir:**

| Topic | Reference File | When to Read |
|-------|---------------|--------------|
| Núcleo, marcador, matriz 14, madurez, orígenes, gates, loop post-rechazo | `references/01-nucleo-y-despachabilidad.md` | Antes de escribir u optimizar cualquier issue |
| Baterías M/S/O/Q, matrices por superficie, rúbricas de plan/código, calibración | `references/02-verificaciones.md` | Al declarar rúbricas en una issue o revisar entregas |
| Mapeo a Linear, patrones GraphQL, solicitudes de cliente, auditoría remota | `references/03-linear-nativo.md` | Al crear/consultar issues por API o montar el flujo |
| 12 anti-patrones con evidencia y prevención | `references/04-antipatrones.md` | Al auditar backlogs o justificar el sistema |

## Routing: tipo/variante → plantilla (matriz sellada, 14 combinaciones)

| type | variant | Plantilla | Trigger de uso |
|------|---------|-----------|----------------|
| feat | none | `templates/01-feat.md` | Capacidad nueva de producto (UI y/o backend) |
| feat | db | `templates/01-feat.md` (+ Bloque DB) | La feature toca esquema/migraciones |
| fix | none | `templates/02-fix.md` | Comportamiento roto contra contrato |
| fix | seguridad | `templates/02-fix.md` (variante) | El defecto toca auth/pagos/credenciales/datos personales |
| fix | sev1 | `templates/02-fix.md` (variante) | Producción degradada o caída — urgente |
| fix | seguridad+sev1 | `templates/02-fix.md` (variante) | Incidente urgente DE seguridad (unión de baterías) |
| db-ops | none | `templates/03-db-ops.md` | Operación de datos/esquema sin feature (índices, backfill, tareas, permisos) |
| chore | none | `templates/04-chore.md` | Infra, tooling, configuración, operación |
| chore | doc-vivo | `templates/04-chore.md` (variante) | El artefacto es doctrina que otros ejecutarán |
| refactor | none | `templates/05-refactor.md` | Cambio de estructura sin cambio de comportamiento |
| test | none | `templates/06-test.md` | Añadir o cablear red de pruebas |
| docs-adr | none | `templates/07-docs-adr.md` | Documentación, registros de decisión, guías |
| spike-auditoria | none | `templates/08-spike-auditoria.md` | Investigación/barrido/decisión — DIFF-CERO |
| contenido-datos | none | `templates/09-contenido-datos.md` | Escribir contenido/datos de producto en producción, sin PR |

Rutas hermanas: núcleo canónico → `templates/00-nucleo.md` · manifest de cláusulas → `templates/nucleo-manifest.txt` · gate de paridad → `scripts/check_nucleo_parity.sh` · parametrización por repo → `templates/perfil-de-repo.md` · ejemplos rellenos → `examples/gold-feat-db.md`, `examples/gold-fix.md`, `examples/gold-spike.md` · auditor → `scripts/issue_craft_helper.ts`.

## TypeScript Quick Start (auditor)

Sin dependencias más allá de un runtime de TypeScript (p. ej. `tsx`); el helper usa solo builtins de Node ≥ 22.

```bash
cd <ruta-de-instalacion-del-skill>/talent-issue-craft   # la raíz del skill

# Matriz de tipos (local, sin credenciales)
npx tsx scripts/issue_craft_helper.ts --action list-types

# Pre-check de autoría sobre un borrador (body-only; nunca acredita el gate)
npx tsx scripts/issue_craft_helper.ts --action audit-issue --file mi-borrador.md

# Gate operativo (evidencia remota completa; exige LINEAR_API_KEY en env o .env.local)
npx tsx scripts/issue_craft_helper.ts --action audit-issue --issue ABC-123 --min-score 70
```

```typescript
// Como módulo:
import { auditBody, parseMarker, TYPE_MATRIX, summarize } from "./scripts/issue_craft_helper";

const body = "<!-- issue-craft:v1 type=fix variant=none madurez=despachable -->\n## Contexto y origen\n…";
const marker = parseMarker(body);
if (!("error" in marker)) {
  const checks = auditBody(body, marker, "marker");
  const report = summarize(checks, "marker", "file", false, 70, marker);
  console.log(report.score, report.hardFailures, report.eligible); // eligible=false: body-only
}
```

## Bash Quick Start (API directa de Linear)

```bash
# Crear una issue con el body de una plantilla rellenada (la key va por header, NUNCA en argv)
cfg=$(mktemp); chmod 600 "$cfg"; trap 'rm -f "$cfg"' EXIT INT TERM
printf 'header = "Authorization: %s"\n' "$LINEAR_API_KEY" > "$cfg"
jq -n --rawfile d issue-rellena.md '{query:"mutation($i:IssueCreateInput!){issueCreate(input:$i){success issue{identifier url}}}",variables:{i:{teamId:"<team>",title:"Imperativo qué (dónde)",description:$d,estimate:3,priority:2,labelIds:["<label>"],projectId:"<proyecto>"}}}' \
  | curl -sS --config "$cfg" -H "Content-Type: application/json" -d @- https://api.linear.app/graphql
# Patrones completos (dedupe, relaciones, solicitudes de cliente): references/03-linear-nativo.md
```

(Quick Start en 2 lenguajes: TypeScript + bash/curl — la API es GraphQL puro y el auditor es TS; no existe SDK adicional que justifique un tercer lenguaje.)

## Essential Patterns

### Flujo crear-issue (de idea a despachable)

```text
idea/propuesta/hallazgo
   │  (origen tipificado: dedupe / agrupar-por-vehículo / estructura mínima)
   ▼
¿horizonte lejano? ── sí ──> PLACEHOLDER (5 líneas máx, madurez=placeholder)
   │ no                              │ (entra en ventana)
   ▼                                 ▼
routing (matriz 14) ──> copiar templates/NN ──> rellenar + sellar decisiones
   ▼
audit-issue --file borrador.md        (pre-check body-only)
   ▼
crear en Linear (estimate+prioridad+etiquetas+proyecto+relaciones)
   ▼
audit-issue --issue <ID>  ──>  marker + eligible=true + exit 0  ──>  DESPACHABLE
```

### Decisiones: régimen de 3 estados

```text
¿Decisión detectada al escribir la issue?
├── Ya tomada        → tabla SELLADAS (valor + quién + fecha)
├── Se tomará luego  → tabla DIFERIDAS (dueño + trigger + ¿bloquea? + default)
│      ├── Bloquea TODO  → issue-decisión asignada + blockedBy → NO despacha
│      ├── Bloquea PARTE → esa parte sale a issue hija bloqueada
│      └── No bloquea    → default seguro; el ejecutor NO la resuelve
└── No se decidirá   → tabla NO-SE-DECIDIRÁ (por qué + quién registró)
GATE: cero decisiones abiertas sin régimen.
```

### Elegibilidad del gate operativo (clasificación ≠ evidencia)

```text
                      ┌───────────────┬──────────────────┐
                      │ --file (body) │ --issue (remota) │
┌─────────────────────┼───────────────┼──────────────────┤
│ marcador válido     │ pre-check OK  │ GATE si exit 0   │
│                     │ eligible=false│ eligible=true    │
├─────────────────────┼───────────────┼──────────────────┤
│ override --type     │ calibración   │ auditoría retro  │
│                     │ eligible=false│ eligible=false   │
├─────────────────────┼───────────────┼──────────────────┤
│ sin marcador        │ exit≠0        │ exit≠0           │
└─────────────────────┴───────────────┴──────────────────┘
Respuesta remota parcial/errores → eligible=false + exit≠0 (fail-closed).
```

### Pipeline de optimización de una issue existente

```text
audit-issue (--issue o --file) → lista de duros rotos + score
   ▼
reescribir con la plantilla del tipo (routing) → sellar decisiones → DoD ejecutable
   ▼
re-audit → comparar score antes/después → adjuntar como evidencia de la mejora
```

## Critical Gotchas

1. **Longitud ≠ calidad** → en el corpus analizado, las issues más largas (13-30k) fueron rechazadas igual que las cortas; lo que previene el rechazo son los campos duros (decisiones selladas, invariantes con suite, DoD ejecutable acotado, artefactos tocados), no la prosa.

2. **La decisión huérfana es el modo de fallo más caro** → sin dueño/trigger/régimen, el ejecutor la resuelve de facto a mitad de vuelo. El gate "cero decisiones abiertas sin régimen" existe por esto.

3. **`variant=none` es explícito** → la AUSENCIA del campo variant hace el marcador malformado (fail-closed). No hay "sin variante implícito".

4. **Las etiquetas del tracker NO clasifican** → no son biyectivas con la taxonomía (comprobado en corpus: issues de datos con etiqueta "chore", de seguridad con "fix"). El marcador es la autoridad; etiquetas = cross-check.

5. **Un body perfecto no acredita el gate** → clasificación y evidencia son contratos separados: sin propiedades y relaciones observables (`--issue`), `operational_gate_eligible=false` SIEMPRE.

6. **Issue bloqueada ≠ issue mal escrita** → una relación `blocks` ACTIVA (bloqueador no completado/cancelado) veta el despacho aunque la issue sea gold. No se relaja ese duro para "hacer pasar" nada.

7. **El score no salva duros** → cualquier check 🔴 aplicable roto → exit ≠ 0 aunque el score sea 95. `--min-score` es condición ADICIONAL.

8. **`labelIds` reemplaza el array completo** → no existe "añadir etiqueta" en la API de Linear: leer las actuales, unir, reenviar. El error clásico borra etiquetas existentes.

9. **Issue-por-hallazgo genera dedupe masivo** → 77% de las duplicadas del corpus. Agrupar hallazgos por vehículo de implementación (mismos archivos = misma issue).

10. **El placeholder con detalle caro caduca en bloque** → ~78% de las canceladas del corpus fueron specs de lujo escritas meses antes del pivote. 5 líneas máximo hasta la ventana de despacho.

11. **Afirmaciones de terceros sin fuente + fecha** → las issues más largas rebotadas fallaron por versiones/semántica de API incorrectas. Vendor-claims: URL oficial + fecha, y lo no verificable SE ELIMINA.

12. **Cambiar el núcleo sin propagarlo** → canon + manifest + 9 plantillas van en el MISMO cambio; `scripts/check_nucleo_parity.sh` (bidireccional, exit ≠ 0) lo fuerza. Correrlo desde la raíz del skill.

13. **El gate mide estructura, NO satisfacibilidad del contrato** → un DoD internamente contradictorio (p. ej. un registro-de-ensayo obligado a contener evidencia nacida de su propio commit final — paradoja de autorreferencia) pasa `audit-issue` con score alto: las rúbricas verifican campos duros, no que el contrato sea cumplible. Ese límite es DELIBERADO (satisfacibilidad no es decidible por checker) y es exactamente lo que cubre el segundo gate del circuito (auditoría adversarial del plan). Cazado en vivo: ensayo DeFi 2026-07-29, score 100 + NO-GO del auditor por contrato insatisfacible. Guardrail de frontera de evidencia en plantilla 07.

## Cross-Skill Integration

Este skill es deliberadamente **independiente de stack y de repo** (se publica como skill de uso libre): no asume framework, base de datos ni proveedor. Las integraciones se declaran GENÉRICAS y cada repo las concreta en su `perfil-de-repo.md` (desviación consciente del mínimo habitual de esta biblioteca, sellada por esa decisión de independencia):

### Tu capa API del tracker

Si tu biblioteca tiene un skill de operación de Linear (patrones GraphQL, paginación, rate limits), este skill delega ahí el "cómo llamar al API" y aporta el "qué escribir". Sin ese skill, `references/03-linear-nativo.md` + el helper bastan (GraphQL directo con fetch).

```bash
# El contrato mínimo que este skill necesita del tracker:
# crear issue con body+propiedades · relaciones blocks/duplicate · comentarios · lectura completa (§6 de 03)
```

### Tu skill de documentación

Los references de este skill siguen el patrón referencia-con-TOC; si tu repo usa un framework de docs (p. ej. Diataxis), el perfil del repo y sus guías canónicas absorben los procedimientos pesados que las issues de tipo `contenido-datos` referencian por linaje.

### Tu skill/proceso de revisión

Las rúbricas de `02-verificaciones.md` (plan §7, código §8) son la vara de los revisores — humanos o agentes. Si tu repo tiene revisor automático de PRs, mapea sus hallazgos al loop post-rechazo ("¿la issue pudo haberlo prevenido?") para que las plantillas iteren con datos.

## Next Steps

- **¿Vas a escribir u optimizar una issue?** → `references/01-nucleo-y-despachabilidad.md`
- **¿Vas a declarar rúbricas o revisar una entrega?** → `references/02-verificaciones.md`
- **¿Vas a crear/consultar issues por API o montar el flujo en Linear?** → `references/03-linear-nativo.md`
- **¿Vas a auditar un backlog o justificar el sistema?** → `references/04-antipatrones.md`
- **¿Vas a adoptar el skill en un repo nuevo?** → rellena `templates/perfil-de-repo.md` y calibra el umbral (`02` §10)
- **¿Vas a cambiar el núcleo?** → `templates/00-nucleo.md` §mantenimiento + `bash scripts/check_nucleo_parity.sh`

## Paquete de fábrica

Este skill es miembro del **paquete de skills de fábrica** (16): linear-skill · skill-creator · talent-buzz ·
talent-ceo · talent-channel-operation · talent-channels · talent-context · talent-coordination ·
talent-issue-craft · talent-llm-local · talent-memoria · talent-merger · talent-orchestrator · talent-pm · talent-prd · talent-repo-onboarding. El paquete viaja JUNTO y
**motor-primero**: canónico en el repo motor `talent-factory` (`skills/`), propagado como núcleo
a los repos de producto con `skill-creator/scripts/sync-package.sh` (overlays por repo intactos)
y validado con `skill-creator/scripts/validate-package.sh` + `<skill>/invariants.tsv`.
Manifiesto: `skill-creator/assets/package.manifest` · doctrina y ratchet (D6): `skill-creator/references/09-paquete-de-fabrica.md`.
