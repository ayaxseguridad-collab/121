---
name: talent-docs
description: "Crear o actualizar documentación técnica en docs/ al completar desarrollos, features, fixes, refactors o decisiones técnicas, y al revisar PRs con documentación faltante. Aplica a ADRs, APIs y documentación incluida en el PR. Usa Diátaxis y documentación como código. No aplica a documentación externa/pública de producto ni a contenido de marketing."
---

# Documentación como Código

## Quick Orientation

| Property | Value |
|----------|-------|
| **Framework** | Diátaxis (4 tipos: Tutorial, How-to, Reference, Explanation) |
| **Formato** | Markdown con frontmatter YAML obligatorio |
| **ADRs** | MADR 4.0 format, inmutables, en `docs/decisions/` |
| **API Docs** | OpenAPI 3.1+ (YAML), AsyncAPI 3.0 para event-driven |
| **Lint Markdown** | `markdownlint-cli2` |
| **Lint Prosa** | `vale` (requiere `vale sync` para instalar styles) |
| **Links Rotos** | `lychee` (no verifica anchors — usar `markdown-link-check` para eso) |
| **Ortografía** | `cspell` (requiere diccionario custom en `cspell.json`) |
| **CI Pipeline** | GitHub Actions: lint + link check + spell check |

### Diátaxis 2×2 Quadrant

```
              PRACTICAL                    THEORETICAL
         ┌────────────────────┬────────────────────┐
         │                    │                    │
LEARNING │    TUTORIALS       │   EXPLANATION      │
         │    "Haz esto,      │   "Esto funciona   │
         │     luego esto"    │    porque..."      │
         │    docs/tutorials/ │   docs/explanation/│
         │                    │                    │
         ├────────────────────┼────────────────────┤
         │                    │                    │
WORKING  │    HOW-TO GUIDES   │   REFERENCE        │
         │    "Para lograr    │   "El endpoint     │
         │     X, haz Y"     │    acepta..."      │
         │    docs/guides/    │   docs/reference/  │
         │                    │                    │
         └────────────────────┴────────────────────┘
```

### docs/ Directory Structure

```
proyecto/
├── .github/workflows/docs.yml   # CI pipeline
├── docs/
│   ├── index.md                 # Entrada principal
│   ├── tutorials/               # Aprendizaje guiado
│   ├── guides/                  # How-to por tarea
│   ├── reference/               # Specs técnicas
│   ├── explanation/             # Contexto y diseño
│   ├── decisions/               # ADRs (NNNN-desc.md)
│   ├── api/                     # OpenAPI specs
│   ├── runbooks/                # Procedimientos ops
│   ├── assets/images/           # Diagramas
│   └── templates/               # Plantillas
├── README.md                    # Brief → apunta a docs/
├── CONTRIBUTING.md
├── CHANGELOG.md
└── SECURITY.md
```

### CI Pipeline Flow

```
┌──────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────┐
│  PR      │───▶│ markdownlint │───▶│    vale      │───▶│  lychee  │
│  opened  │    │ (format)     │    │ (prose style)│    │ (links)  │
└──────────┘    └──────┬───────┘    └──────┬───────┘    └────┬─────┘
                       │                   │                  │
                       ▼                   ▼                  ▼
                  Format OK?          Style OK?          Links OK?
                       │                   │                  │
                       └───────────────────┼──────────────────┘
                                           ▼
                                    ┌──────────────┐
                                    │   cspell     │
                                    │ (spelling)   │
                                    └──────┬───────┘
                                           ▼
                                      All pass?
                                      ├── YES → ✅ PR ready
                                      └── NO  → ❌ Fix issues
```

## Principio central

Toda documentación vive en `docs/` dentro del repositorio Git. Se escribe en Markdown, se revisa en PRs, se valida en CI, y se despliega automáticamente. La documentación es parte del "definition of done" de cada tarea.

## Paso 1: ¿Qué tipo de cambio hiciste?

Antes de escribir, identificar qué se necesita documentar. Usar esta tabla de decisión:

| Hice esto... | Documenta esto → | Ubicación |
|---|---|---|
| Feature nueva | How-to guide + referencia API (si aplica) | `docs/guides/` + `docs/reference/` |
| Endpoint/API nueva o modificada | OpenAPI spec + ejemplo uso | `docs/api/` + `docs/reference/` |
| Decisión de arquitectura | ADR (Architecture Decision Record) | `docs/decisions/` |
| Fix de bug complejo | Nota en runbook o how-to existente | `docs/guides/` o `docs/runbooks/` |
| Nuevo servicio/módulo | Tutorial de setup + explicación arquitectura | `docs/tutorials/` + `docs/explanation/` |
| Refactor significativo | Actualizar docs afectados + ADR si cambió arquitectura | Varios |
| Configuración infra/deploy | Runbook operacional | `docs/runbooks/` |
| Onboarding de tecnología | Tutorial paso a paso | `docs/tutorials/` |
| Cambio breaking | Entrada en CHANGELOG.md + migración en guides | Raíz + `docs/guides/` |

## Paso 2: Estructura del repositorio

Todos los repositorios del proyecto siguen esta estructura:

```
proyecto/
├── .github/workflows/docs.yml    # CI para docs
├── docs/
│   ├── index.md                  # Entrada principal, mapa de docs
│   ├── tutorials/                # Aprendizaje paso a paso (Diátaxis)
│   ├── guides/                   # How-to orientados a tareas (Diátaxis)
│   ├── reference/                # Material técnico preciso (Diátaxis)
│   ├── explanation/              # Contexto, porqués, diseño (Diátaxis)
│   ├── decisions/                # ADRs numerados
│   ├── api/                      # OpenAPI specs (.yaml)
│   ├── runbooks/                 # Procedimientos operacionales
│   ├── assets/images/            # Imágenes y diagramas
│   └── templates/                # Plantillas reutilizables (copiar de aquí)
├── src/                          # Código fuente
├── README.md                     # Overview del proyecto (breve, apunta a docs/)
├── CONTRIBUTING.md               # Cómo contribuir
├── CHANGELOG.md                  # Cambios por versión (Conventional Commits)
└── SECURITY.md                   # Política de seguridad
```

## Paso 3: Escribir el documento

### Reglas generales de escritura

1. **Español para prosa, inglés para código** — Documentación en español. Nombres de variables, comandos, paths en inglés
2. **Un tema por archivo** — Si un doc cubre dos temas distintos, dividirlo
3. **Frontmatter YAML obligatorio** en cada .md:

```yaml
---
title: "Título descriptivo"
created: 2026-02-06
updated: 2026-02-06
author: nombre-github
status: draft | active | deprecated
---
```

4. **Diagramas en Mermaid** — Usar bloques ```mermaid (renderea en GitHub)
5. **Links relativos** — Siempre `../reference/api-auth.md`, nunca URLs absolutas internas
6. **Nombres de archivo** — kebab-case: `configurar-webhook-eventos.md`

### Framework Diátaxis — Qué tipo de doc escribir

Leer `references/diataxis.md` para las reglas completas de cada tipo. Resumen rápido:

| Tipo | Propósito | Tono | Ejemplo |
|---|---|---|---|
| **Tutorial** | Enseñar haciendo | "Haz esto, luego esto" | `tutorials/primer-evento-api.md` |
| **How-to** | Resolver problema específico | "Para lograr X, haz Y" | `guides/configurar-webhook.md` |
| **Referencia** | Describir el sistema tal como es | Preciso, austero | `reference/api-endpoints.md` |
| **Explicación** | Dar contexto y razonamiento | Conversacional | `explanation/arquitectura-example-service.md` |

**Error más común**: mezclar tutorial con how-to. Tutorial = experiencia guiada completa para aprender. How-to = receta para resolver algo asumiendo que ya sabes lo básico.

### ADRs (Architecture Decision Records)

Para decisiones técnicas significativas. Usar template MADR 4.0. Ver template completo en `references/templates.md`.

Formato del nombre: `docs/decisions/NNNN-descripcion-corta.md` (numeración secuencial: 0001, 0002, etc.)

Crear ADR cuando:
- Se elige una tecnología o framework
- Se cambia patrón de arquitectura
- Se decide sobre infraestructura
- Hay trade-offs importantes que el equipo futuro necesita entender

Los ADRs son **inmutables**. Si una decisión cambia, crear nuevo ADR con status `supersedes [ADR-NNNN]`.

### Documentación de APIs

- Formato: OpenAPI 3.1+ en YAML
- Ubicación: `docs/api/openapi.yaml` (o dividido por dominio)
- Para APIs event-driven (Kafka, WebSockets): AsyncAPI 3.0
- Generar automáticamente cuando sea posible (FastAPI → `/openapi.json`, etc.)

### Runbooks

Para procedimientos operacionales. Cada runbook debe responder: ¿Quién ejecuta? ¿Cuándo? ¿Qué pasos exactos? ¿Cómo verificar que funcionó? ¿Qué hacer si falla?

## Paso 4: Validar antes del PR

Antes de crear el PR, verificar localmente:

```bash
# Lint de Markdown (formato)
npx markdownlint-cli2 "docs/**/*.md"

# Lint de prosa (estilo, claridad)
vale docs/

# Links rotos
lychee --verbose docs/**/*.md

# Ortografía
npx cspell "docs/**/*.md"
```

Ver `references/ci-pipeline.md` para la configuración completa de CI/CD.

## Paso 5: PR y review

### Checklist de documentación en cada PR

Agregar al PR template (`.github/pull_request_template.md`):

```markdown
## Documentación
- [ ] ¿El cambio requiere documentación? Si no, explicar por qué
- [ ] Docs nuevos/actualizados incluidos en este PR
- [ ] Frontmatter YAML completo (title, created/updated, author, status)
- [ ] Links internos verificados
- [ ] Diagramas actualizados si cambió arquitectura
- [ ] ADR creado si hubo decisión técnica significativa
- [ ] CHANGELOG.md actualizado si es release-worthy
```

### Quién escribe, quién revisa

- **Desarrollador**: Escribe el primer borrador como parte de la tarea
- **Reviewer del PR**: Verifica que la documentación sea clara y completa
- **Tech Lead**: Revisa ADRs y docs de arquitectura

## Paso 6: Mantenimiento

### Cada sprint

- Revisar docs con status `draft` → mover a `active` o eliminar
- Verificar que docs marcados `active` sigan siendo precisos

### Cada quarter

- Buscar docs sin actualizar en 90+ días → revisar vigencia
- Verificar cobertura: ¿hay features sin documentar?
- Auditar links rotos con lychee

### Señales de doc desactualizado

- Código referenciado ya no existe
- Screenshots no coinciden con UI actual
- Pasos de tutorial fallan al seguirlos
- Preguntas frecuentes en Slack/Discord sobre algo que debería estar documentado

---

## Critical Gotchas — Gotchas Críticos

1. **Links rotos que CI no detecta porque apuntan a anchors generados** — `lychee` valida que el archivo destino exista, pero no verifica anchors (`#seccion-especifica`) dentro de archivos Markdown. Un refactor que renombra un heading rompe todos los links a ese anchor sin que CI falle. Usar `markdown-link-check` con `--check-anchors` o `remark-validate-links` para validar anchors internos.

2. **Docs desactualizados que nadie detecta hasta que causan incidentes** — Un runbook que dice "reiniciar el servicio con `systemctl restart app`" cuando la infra migró a Kubernetes causa downtime real. Configurar una búsqueda trimestral de docs sin actualizar en 90+ días (`git log --diff-filter=M --since="90 days ago" -- docs/`). Marcar docs sin commits recientes como candidatos a revisión.

3. **Frontmatter YAML faltante o inválido rompe generadores de sitio** — Si un `.md` no tiene el bloque `---` con `title`, `created`, `author`, `status`, herramientas como MkDocs, Docusaurus o scripts internos fallan silenciosamente o generan páginas sin metadatos. Validar frontmatter en CI con `gray-matter` o un script custom que rechace PRs sin frontmatter válido.

4. **Mermaid syntax inválido se renderiza como bloque de código en GitHub** — GitHub renderiza Mermaid, pero errores de sintaxis (un `-->` extra, un nodo sin cerrar) simplemente muestran el código fuente sin error visible. El autor piensa que el diagrama se ve bien porque "no hay error". Previsualizar siempre con `mermaid.live` o el plugin de VS Code antes de hacer commit.

5. **Docs que solo existen en PRs y nunca se mergean** — Documentación creada en branches de feature que se abandonan o se mergean con squash (perdiendo los commits de docs). La documentación queda en un PR cerrado que nadie encuentra. Regla: la documentación va en el mismo PR que el código, nunca en un PR separado que puede quedarse en review limbo.

6. **README.md duplica contenido de `docs/index.md`** — El README del proyecto y el `docs/index.md` empiezan siendo iguales, pero divergen con el tiempo. Uno se actualiza y el otro no. El README debe ser un overview breve (max 50 líneas) que apunte a `docs/` para todo lo demás. Nunca duplicar instrucciones de setup o arquitectura entre ambos.

7. **ADRs modificados en lugar de superseded** — Los ADRs (Architecture Decision Records) son inmutables por diseño. Si una decisión cambia, se crea un nuevo ADR con status `supersedes [ADR-NNNN]`. Editar un ADR existente destruye el registro histórico de por qué se tomó la decisión original y elimina contexto valioso para el equipo futuro.

8. **Vale (lint de prosa) no funciona sin instalar los styles** — Ejecutar `vale docs/` sin haber instalado los paquetes de estilo (`vale sync` o descarga manual a `styles/`) produce cero warnings, dando falsa sensación de que la prosa es correcta. Agregar `vale sync` al paso de setup del proyecto y verificar en CI que `styles/` no esté vacío.

9. **cspell rechaza términos técnicos legítimos sin diccionario custom** — `cspell` marca como errores palabras como "tRPC", "Turborepo", "KMP", "Zustand", "pnpm" que son perfectamente válidas en el contexto del proyecto. Mantener un archivo `cspell.json` con un diccionario custom (`words: [...]`) en la raíz del repo. Actualizar el diccionario cada vez que se adopta una nueva tecnología.

10. **Docs largos (>500 líneas) que nadie lee completos** — Un how-to de 800 líneas que cubre 5 escenarios diferentes no se lee ni se mantiene. Dividir en documentos individuales por escenario: `guides/configurar-webhook-stripe.md`, `guides/configurar-webhook-github.md`, etc. Cada doc debe poder leerse en 5-10 minutos (200-400 líneas máximo).

---

## Cross-Skill Integration

### Todos los skills
Cada skill del sistema sigue la convención docs-as-code: tiene un `SKILL.md` como punto de entrada y un directorio `references/` con archivos organizados según el framework Diátaxis (tutoriales, how-tos, referencia, explicación). Cuando se documenta un feature que involucra múltiples skills, crear cross-references entre los `SKILL.md` correspondientes usando links relativos.

### creative-multimedia
Los assets creativos (imágenes, videos, audio) generados por el skill de multimedia deben documentarse con versionado y metadata. Cada asset en `docs/assets/` debe tener un registro en `docs/reference/` indicando: fuente, fecha de generación, herramienta utilizada, y versión. Esto asegura trazabilidad cuando los assets se actualizan o reemplazan.

### cross-platform-monorepo
La documentación del proyecto vive como un workspace dentro del monorepo. En Path B (Expo + Turborepo), agregar `"docs"` al `pnpm-workspace.yaml` para que los scripts de validación de docs (`markdownlint`, `vale`, `lychee`) se ejecuten como parte del pipeline de CI del monorepo. En Path A, incluir la tarea de docs en `turbo.json` para que `turbo run lint` incluya validación de documentación.

> **Nota**: El enfoque docs-as-code aplica a TODOS los skills del sistema. Cada vez que se crea o modifica un skill, la documentación asociada (`SKILL.md` + `references/`) debe actualizarse en el mismo PR que el cambio de código. La documentación no es un paso posterior — es parte del "definition of done".

## Reference Files — Referencia rápida de archivos

| Necesito... | Ver archivo |
|---|---|
| Templates de cada tipo de doc | `references/templates.md` |
| Reglas Diátaxis detalladas | `references/diataxis.md` |
| Config CI/CD para docs | `references/ci-pipeline.md` |

## Paquete de fábrica

Este skill es miembro del **paquete de skills de fábrica** (13): coderabbit-talent · linear-skill · talent-ceo · talent-channel-operation · talent-channels · talent-context · talent-docs-skill · talent-issue-craft · talent-medidor · talent-merger · talent-orchestrator · talent-pm · talent-sentry-guard. El paquete viaja JUNTO.
Manifiesto: `scripts/paquete/package.manifest`.
Validación: `scripts/paquete/validate-package.sh` e `invariants.tsv`.
Doctrina y ratchet: `scripts/paquete/PAQUETE.md`.
