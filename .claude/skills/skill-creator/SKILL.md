---
name: skill-creator
description: >
  Use this skill to create a new skill for the skill library, audit or update/iterate an
  existing skill against the Gold Standard, or understand the skill system architecture and
  how the skill library works internally. Defines the Gold Standard — SKILL.md structure,
  conventions, and quality checklist every skill must follow — with templates for SKILL.md,
  reference files, TypeScript/Python helper scripts, and CLAUDE.md registration.
when_to_use: >
  Trigger for: creating a skill from scratch, adding a new API/service/integration skill,
  auditing or updating/iterating an existing skill, verifying skill completeness,
  registering/validating a skill, or explaining how skills work. Trigger keywords:
  "crear skill", "nuevo skill", "actualizar skill", "skill template", "create skill",
  "new skill", "update skill", "add skill", "gold standard", "meta skill", "agregar skill",
  "skill para X", "make a skill", "build a skill", "skill structure", "skill format",
  "skill checklist", "skill audit", "skill quality", "skill standard", "how to create skill",
  "como crear skill", "skill system", "skill architecture", "how skills work",
  "cómo funcionan los skills", "add a new service", "new integration", "plantilla skill",
  "skill requirements", "registrar skill", "register skill", "skill validation",
  "verify skill", "verificar skill".
  Even if the user just asks "add support for X API", "create a skill for Y",
  "how does the skill system work?", or "what is the skill format?", use this skill.
---

# Skill Creator — Gold Standard Meta-Skill

## Quick Orientation

The **Gold Standard** is the quality baseline for every skill in this library, derived from
auditing and perfecting `stripe-skill` and `nowpayments-skill`, then propagated across all skills.

**System metrics**:

| Metric | Value | Last verified |
|--------|-------|----------------|
| Total skills | 39 (including this meta-skill) | 2026-07-18 |
| Total files | 532 across all skills | 2026-07-18 |
| Gold Standard items | 27 checklist items | — |
| Reference implementations | `stripe-skill`, `nowpayments-skill` | — |

**Philosophy**: Every skill must be born at 100% of the Gold Standard from the first commit —
this meta-skill gives Claude a repeatable, auditable process instead of guessed conventions.

**For the templates and detailed instructions, read the appropriate reference file:**

| Topic | Reference File | When to Read |
|-------|---------------|--------------|
| SKILL.md structure with all required sections, full frontmatter field table | `references/skill-md-template.md` | Step 2: Creating the SKILL.md entry point |
| Reference file format, TOC, naming conventions | `references/reference-file-template.md` | Step 3: Creating reference documentation |
| TypeScript helper script with CircuitBreaker | `references/typescript-helper-template.md` | Step 4: When the skill needs a TS helper |
| Python helper script with CircuitBreaker | `references/python-helper-template.md` | Step 4: When the skill needs a Python helper |
| How to register the skill in CLAUDE.md | `references/claude-md-registration.md` | Step 5: Registering the new skill |
| Bash scaffold + post-creation checklist + pointer to the packaged validator script | `references/quick-scaffold.md` | Quick Start: bootstrapping a new skill directory |
| Fail-closed webhook gating skeletons (Next.js + Supabase Edge Functions) | `references/cross-skill-webhook-patterns.md` | Cross-Skill Integration: when the new skill has webhooks |

---

## Workflow: Crear un Skill Nuevo

Follow these 6 steps in order. Each step references a template file to read.

### Paso 1 — Definir scope

Before writing any files, answer these questions:

```text
┌─────────────────────────────────────────────────┐
│          SCOPE DEFINITION CHECKLIST              │
├─────────────────────────────────────────────────┤
│ 1. What service/API does this skill cover?       │
│ 2. What is the current API version?              │
│ 3. Are there official SDKs? Which languages?     │
│ 4. How many endpoints / features?                │
│    → This determines sizing (see Sizing Guide)   │
│ 5. Does it need webhooks/callbacks?              │
│ 6. Does it need authentication beyond API keys?  │
│ 7. What other skills does it integrate with?     │
│ 8. Does it need a helper script?                 │
│    → See Decision Tree below                     │
└─────────────────────────────────────────────────┘
```

### Paso 2 — Crear SKILL.md

Read `references/skill-md-template.md` and follow the template exactly.

The SKILL.md is the **entry point** — Claude reads it first, decides which reference files to drill into, and it must contain ALL Gold Standard sections.

### Paso 3 — Crear references/

Read `references/reference-file-template.md` for the format.

Create one reference file per logical topic group (use the Sizing Guide below to size it). Each reference file must have:

- Kebab-case filename (e.g., `payments-and-checkout.md`)
- TOC with working anchor links
- Numbered sections (`## 1. Section Name`)
- Runnable code in 2+ languages (where applicable)

### Paso 4 — Crear helper script (si aplica)

Check the Decision Tree below. If the skill needs a script:

- **TypeScript**: Read `references/typescript-helper-template.md`
- **Python**: Read `references/python-helper-template.md`

Create a `scripts/` directory inside the skill folder.

### Paso 5 — Registrar en CLAUDE.md

Read `references/claude-md-registration.md` for the exact procedure.

This step is **critical** — skills under `.claude/skills/` are auto-discovered from disk, but a skill
that isn't registered as a row in the `## Skills Obligatorios` table won't be treated as **mandatory
project policy** and may go unused when it should be loaded.

### Paso 6 — Verificar con Gold Standard Checklist

Run through the complete checklist below. Every item must pass.

---

## Quick Start: Crear un Skill desde Cero

El scaffold bash completo (estructura de directorios + `SKILL.md` mínimo + primer
reference file) y el checklist rápido de verificación post-creación viven en
`references/quick-scaffold.md` — léelo al llegar a este paso. La validación Gold Standard
se corre con el script empaquetado `scripts/validate_skill.py`
(`python3 .claude/skills/skill-creator/scripts/validate_skill.py <skill-name>`).

---

## Frontmatter Reference

`SKILL.md` frontmatter soporta `name` + `description` más **14 campos opcionales adicionales** (16 documentados en total): `when_to_use`, `argument-hint`, `arguments`, `disable-model-invocation`, `user-invocable`, `allowed-tools`, `disallowed-tools`, `model`, `effort`, `context`, `agent`, `hooks`, `paths`, `shell`.
**Gate de caracteres**: `description` ≤1024 caracteres, o ≤1536 combinado con `when_to_use` (fuente: `code.claude.com/docs/en/skills`, sección "Frontmatter reference", `last_verified: 2026-07-16`). Tabla completa con guía de cuándo usar cada campo → `references/skill-md-template.md#11-optional-frontmatter-fields-claude-code`.

---

## Evaluación (eval-driven development)

Anthropic estandarizó eval-driven development como el flujo oficial para crear e iterar skills (`platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices`, `last_verified: 2026-07-16`), en 5 pasos:

1. **Identify gaps** — correr el modelo SIN el skill en tareas representativas y documentar fallos/contexto faltante.
2. **Create evaluations** — construir 3+ escenarios que ejerciten esos gaps.
3. **Establish baseline** — medir el desempeño SIN el skill (comparación con-skill vs sin-skill: la base canónica, obligatoria SIEMPRE, incluso al iterar uno existente — comparar solo versiones puede declarar éxito aunque ambas sean igual de ineficaces). **Al ITERAR un skill YA EXISTENTE**, SUMAR además una comparación A/B ciega contra la VERSIÓN ANTERIOR del propio skill — nunca en lugar de la comparación con/sin skill.
4. **Write minimal instructions** — solo lo necesario para pasar las evaluaciones.
5. **Iterate** — ejecutar, comparar contra el baseline, refinar.

El plugin oficial `skill-creator@claude-plugins-official` automatiza el loop (`evals/evals.json`, subagente aislado por caso, `grading.json`, `benchmark.json` con-skill vs sin-skill, comparación de versiones A/B ciega, tuning de `description`). Es COMPLEMENTARIO al checklist de abajo: el checklist mide calidad estructural; los evals miden comportamiento real. La **validación estructural** contra el Gold Standard se corre con el script real empaquetado `scripts/validate_skill.py` (no como bloque embebido — invocación y alcance en `references/quick-scaffold.md` §3).

---

## Gold Standard Checklist

### SKILL.md (8 items)

- [ ] **YAML frontmatter** — `name`, `description` with 30+ trigger keywords, trigger phrases in both English and Spanish. **Character gate**: `description` ≤1024 chars, or ≤1536 combined with `when_to_use` — see `references/skill-md-template.md#11-optional-frontmatter-fields-claude-code` for the full field table
- [ ] **Quick Orientation** — Service overview, version table (API version, SDK versions, min runtimes), key metrics
- [ ] **Reference Files Table** — `| Topic | Reference File | When to Read |` with one row per reference file
- [ ] **Quick Start** — Runnable code in 2+ languages (TypeScript + Python minimum), with `npm install` / `pip install` commands
- [ ] **Essential Patterns** — 3-5 ASCII diagrams showing key lifecycles, decision trees, or status flows. **May be satisfied in distributed form** for meta-skills like this one, whose diagrams already live inline across the doc (Scope Definition Checklist, Sizing Guide box, Decision Tree) instead of under one consolidated heading — acceptable as long as each is easy to locate from the section headings
- [ ] **Critical Gotchas** — 10+ numbered items, format: `N. **Title** → Explanation`. Real-world failure modes, not generic advice
- [ ] **Cross-Skill Integration** — At minimum: `convex-skill`, `nextjs-web`, `supabase-skill`, `talent-docs-skill`. Include code examples
- [ ] **Next Steps** — Bulleted list pointing to each reference file with "Doing X? → `references/file.md`" format

### References (7 items)

- [ ] **TOC with anchor links** — Every reference file starts with `## Table of Contents` using `[Section Name](#anchor)` links
- [ ] **Runnable code** — Code blocks have language tags, are copy-pasteable, include imports and setup
- [ ] **Error handling** — Each reference covers error scenarios specific to that topic
- [ ] **ASCII diagrams** — At least 1 diagram per reference showing flows, architectures, or decision trees
- [ ] **Webhook patterns** — If the API has webhooks, a dedicated reference file covers signature verification per framework
- [ ] **Kebab-case filenames** — All lowercase, hyphens only: `payments-and-checkout.md`, NOT `Payments_And_Checkout.md`
- [ ] **Proportional coverage** — Reference files cover the full API surface, not just the happy path

### Scripts (6 items)

- [ ] **Shebang line** — `#!/usr/bin/env npx tsx` (TS) or `#!/usr/bin/env python3` (Python)
- [ ] **JSDoc / docstring** — Module description, usage examples (both import and CLI), dependencies, env vars
- [ ] **Type definitions** — TypeScript: `interface` + `type` + `enum`. Python: `@dataclass` + `TypeVar` + type hints
- [ ] **CircuitBreaker + retry** — Full CircuitBreaker class (3 states) + `retryWithBackoff` / `with_retry` function
- [ ] **CLI entry point** — `parseArgs` (TS) or `argparse` (Python) with `--action` subcommands and `--help`
- [ ] **Dual export** — TS: `export { ... }` + `if (process.argv[1]...)` guard. Python: classes/functions + `if __name__ == "__main__"`

### Verification of Reality (6 items)

- [ ] **API versions** — Verified against official docs, not hallucinated
- [ ] **SDK versions** — Checked via npm/PyPI/RubyGems, not guessed
- [ ] **URLs** — Base URLs, dashboard URLs, and doc URLs are real and current
- [ ] **Features** — Only document features that actually exist in the API
- [ ] **Package names** — Exact package names from registries (e.g., `stripe` not `stripe-sdk`)
- [ ] **Pricing** — Fee structures verified against the service's pricing page

---

## Acceptable Variations

The Gold Standard defines the required CONTENT, but some FORMAT variations are acceptable
based on skill type. These were identified from auditing all skills in the library (24 at
the time of the original audit, 39 today) and propagated as documented alternatives.

### 1. Gotchas Format: Antipatterns (AP-N)

Platform/framework skills (`kotlin-android`, `swift-ios`, `nextjs-web`, `expo-mobile`,
`cross-platform-design-system`) may use the Antipattern format instead of numbered
gotchas:

```text
❌ AP-1: Title of the antipattern
Fix: The correct approach
Why: Explanation of why the antipattern is harmful
```

This is acceptable for platform/framework skills where the "don't do this / do this
instead" format is more actionable. API/service skills should prefer the standard
`N. **Title** → Explanation` format. **Minimum: 5+ AP-N entries** (lower than the 10+ of
standard/Commandments — real entries are denser to write; the 5 skills above range 7-14,
`last_verified: 2026-07-16`). A single antipattern is not adequate coverage.

### 2. Gotchas Format: Commandments

Skills with a strong opinionated workflow (`convex-skill`, `supabase-skill`,
`hyperliquid-api`) may use a "Commandments" section that doubles as gotchas:

```text
## 10 Commandments
1. **Rule statement** — Explanation of why this is non-negotiable.
```

Acceptable when the rules ARE the gotchas (e.g., "No trailing zeros" in Hyperliquid).
The skill must still have 10+ items covering real failure modes.

### 3. Quick Orientation Naming

The section MUST contain a version table + key metrics, but the heading can vary:

| Acceptable Name | Used By |
|----------------|---------|
| `## Quick Orientation` | Most skills (preferred) |
| `## Quick Context` | meta-ads-api |
| `## Quick Reference` | (legacy, acceptable) |
| `## Info Basica` | whapi-cloud-skill |
| `## S1 — Architecture` | hyperliquid-api (numbered sections style) |
| `## Quick Start` (as the skill's entry point) | `kotlin-android`, `swift-ios`, `nextjs-web`, `expo-mobile` — these AP-N skills (variation 1) fold orientation into the required Quick Start section itself, with version/stack info in the numbered section right after it (e.g. `## 1. Stack & Versions`), instead of a separate named heading. `cross-platform-design-system` (also AP-N) is a documented **exception with no orientation-equivalent heading at all** — a pre-existing gap in that skill, `last_verified: 2026-07-16`, out of scope for this meta-skill to fix |

`scripts/validate_skill.py` checks for any of the acceptable heading variants above (not the presence of a table) — see its module docstring for the exact list per section.

### 4. Next Steps Naming

The section MUST point readers to reference files, but the heading can vary:

| Acceptable Name | Used By |
|----------------|---------|
| `## Next Steps` | Most skills (preferred) |
| `## When to Read Reference Files` | tiktok-ads-api |
| `## Cuando Leer Archivos de Referencia` | creative-multimedia |
| `## Decision Workflows` | meta-ads-api (inline guidance) |
| `## Reference Files` | gtm-manager (simple list), `kotlin-android`, `expo-mobile`, `nextjs-web` |
| `## Reference Files Guide` | swift-ios |
| `## Quick Reference: Which File to Read` | cross-platform-design-system |

### 5. Ads Skills: Creative-Multimedia Integration

All 5 advertising skills (`meta-ads-api`, `google-ads-api`, `tiktok-ads-api`,
`x-ads-api`, `linkedin-ads-api`) MUST include a `## Integracion con Skill
creative-multimedia` section documenting:

- Which placements are generated by `asset_adapter.py`
- Upload flow (how assets go from creative-multimedia to the platform)
- Cross-reference table (which files in each skill relate to the other)

This is in addition to the standard `## Cross-Skill Integration` section.

### 6. Quick Start: Single Language for Niche Skills

The checklist says "2+ languages where applicable". Some skills legitimately
only support 1 language:

| Skill | Language | Reason |
|-------|----------|--------|
| `gtm-manager` | Python only | Google API client lib is Python-centric, CLI wrapper |
| `ses-manager` | Python + bash | AWS CLI is primary interface, boto3 for SDK |
| `talent-docs-skill` | bash only | CLI tools (markdownlint, vale, lychee) |

Single-language Quick Start is acceptable when the SDK/tool only exists in that
language. Document why in the skill's Quick Start section.

### 7. Naming Convention: Gerund vs Noun-Phrase

Anthropic's official guidance recommends **gerund form** for skill directory names
(`processing-pdfs`, `creating-skills`) since it clearly names the activity or capability.
Noun-phrase (`stripe-skill`, `skill-creator` — used by this library's 39 existing skills)
and action-oriented (`process-pdfs`) forms remain acceptable. No retroactive migration of
existing directories — this is guidance for **new** skills going forward, at the author's
discretion.

### 8. CHANGELOG.md: Optional for High-Rotation Skills

`CHANGELOG.md` is **NOT mandatory** in the Gold Standard. It's an acceptable (not required)
variation for operational skills with **semantic versioning and version-dependent consumers**
(canonical example: `talent-channel-operation` v5.0, which already carries one; also
`talent-channels`, `talent-merger`, `talent-orchestrator`). No retroactive backfill of the other
existing skills. **Operational warning**: skill `CHANGELOG.md` files are merge **hot-files** — they
collide across parallel channel waves. Touching one in a PR loses disjoint-train eligibility
(mandatory serialization at the merge station, not automatic trivial rebase). Ruling: lead, TAL-1962
(see the comment trace in this change's PR body and HANDOFF).

---

## Sizing Guide

The number of reference files and total line count depends on the API surface:

```text
┌──────────────────────────────────────────────────────────────────┐
│                        SIZING GUIDE                              │
├──────────────┬──────────┬──────────┬─────────────────────────────┤
│ API Size     │ Refs     │ Lines    │ Examples                    │
├──────────────┼──────────┼──────────┼─────────────────────────────┤
│ Small        │ 2-4      │ 3K-5K   │ ses-manager,                │
│ (5-20 endpts)│          │          │ gtm-manager                 │
├──────────────┼──────────┼──────────┼─────────────────────────────┤
│ Medium       │ 5-8      │ 5K-8K   │ nowpayments-skill, ga4-skill│
│ (20-50 endp) │          │          │ whapi-cloud-skill           │
├──────────────┼──────────┼──────────┼─────────────────────────────┤
│ Large        │ 8-12     │ 8K-12K  │ stripe-skill, convex-skill  │
│ (50+ endpts) │          │          │ supabase-skill              │
└──────────────┴──────────┴──────────┴─────────────────────────────┘
```

**Rules of thumb:**

- 1 reference file per major API group (e.g., payments, subscriptions, webhooks)
- Each reference file: 300-800 lines
- SKILL.md itself: 250-400 lines
- Helper script: 400-1600 lines depending on operation count

---

## Decision Tree: ¿Necesita script?

```text
                    ┌─────────────────────────┐
                    │ Does the skill cover an  │
                    │ API with programmatic    │
                    │ operations?              │
                    └────────┬────────────────┘
                             │
                    ┌────────▼────────┐
                    │   YES           │ NO → No script needed
                    └────────┬────────┘      (e.g., talent-docs-skill,
                             │                cross-platform-design-system)
                    ┌────────▼────────────────┐
                    │ Are there official SDKs? │
                    └────────┬────────────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
         TS/JS SDK     Python SDK      Both/Neither
              │              │              │
              ▼              ▼              ▼
        Create .ts     Create .py     Create .ts (preferred)
        helper         helper         or .py based on
                                      primary audience

        Examples:      Examples:      Examples:
        stripe_helper  ga4_helper     nowpayments_helper.ts
        convex_helper  google_ads_h.  (direct fetch, no SDK)
        supabase_h.    meta_ads_h.
                       hyperliquid_h.
```

**Script naming**: `{service}_helper.{ts|py}` — always snake_case with `_helper` suffix.

---

## Critical Gotchas

1. **YAML frontmatter is mandatory** → Without `name` and `description` fields, the skill won't be discoverable. The description must contain 30+ trigger keywords covering both English and Spanish variants.

2. **Never hallucinate API versions** → Always verify the current API version, SDK versions, and base URLs against official documentation. Outdated or invented versions destroy trust in the entire skill.

3. **Reference file TOC anchors must work** → GitHub/markdown anchor format: lowercase, spaces become hyphens, strip special chars. `## 1. PaymentIntents API` → `#1-paymentintents-api`. Test every link.

4. **Quick Start must be copy-pasteable** → Include `npm install` / `pip install` commands, import statements, env var setup, and a complete working example. Not pseudo-code — real code.

5. **Gotchas must be real failure modes** → Not generic advice like "read the docs". Each gotcha should describe a specific way things break in production. Source them from official docs, GitHub issues, Stack Overflow, and real-world experience.

6. **Cross-Skill Integration needs code** → Don't just say "works with Convex". Show the exact pattern: Convex action with `"use node"`, the import, the API call, the data flow back to mutations. Para webhooks, "el patrón exacto" es la **estructura de rechazo**, no un esquema de firma universal (los gateways firman de formas incompatibles y con contratos distintos — síncrono, asíncrono, o que lanza): body con cota en streaming, header ausente → 400, config ausente → 5xx, verificación **provider-específica** (apuntando al verificador real del gateway) → 401/5xx, idempotencia `processed_at` antes de procesar, 200 solo al final. Un ejemplo que responde 200 incondicionalmente enseña a aceptar webhooks falsificados.

7. **Kebab-case is non-negotiable for references** → `payments-and-checkout.md`, never `Payments_And_Checkout.md` or `PAYMENTS.md`. This was the single most common audit finding across all skills.

8. **Scripts must have ALL 6 required elements** → Shebang, JSDoc/docstring, types, CircuitBreaker+retry, CLI, dual export. Missing any one fails the audit. The CircuitBreaker class alone is ~100-170 lines.

9. **Register as a row in `## Skills Obligatorios` or the skill isn't mandatory policy** → Skills are auto-discovered from disk, but a skill without its row in that `CLAUDE.md` table (+ optional `check-skill.sh` path entry) isn't enforced as required project policy. See `references/claude-md-registration.md`.

10. **Proportional reference coverage** → Don't create one 2000-line reference file. Split by topic: 300-800 lines each. Don't skip error handling, rate limits, or edge cases — these are where real value lives.

11. **Two-language Quick Start minimum** → TypeScript + Python at minimum. If the API has a Ruby, Go, or other popular SDK, add that too. Each Quick Start must include install, init, and at least 3 operations.

12. **ASCII diagrams over prose** → Status flows, decision trees, and architectures should be ASCII diagrams, not paragraphs. Diagrams are scanned 10x faster and reduce hallucination risk.

---

## Cross-Skill Integration

### convex-skill

When the new skill wraps a Convex-called API, its Cross-Skill Integration section MUST show the Convex action pattern:

```typescript
// convex/{{service}}.ts — Convex action
"use node";
import { action } from "./_generated/server";
import { v } from "convex/values";

export const {{operationName}} = action({
  args: { /* typed args from skill's API */ },
  handler: async (ctx, args) => {
    const res = await fetch("{{BASE_URL}}/{{endpoint}}", {
      method: "POST",
      headers: { "x-api-key": process.env.{{ENV_VAR}}!, "Content-Type": "application/json" },
      body: JSON.stringify({ /* params */ }),
    });
    return res.json();
  },
});
```

### nextjs-web / supabase-skill (webhooks)

Cuando el nuevo skill involucra webhooks, su sección Cross-Skill Integration DEBE mostrar el patrón
de ruta con gating falla-cerrado — tanto para Next.js App Router como para Supabase Edge Functions.
Invariante común (no hay verificador criptográfico universal; cada gateway firma distinto):

```text
header ausente → 400  ·  config ausente → 5xx  ·  body excede la cota → 413 (streaming, no Content-Length)
verify provider-específico → 401 (inválida) / 5xx (transitoria)  ·  idempotencia processed_at → 200
```

Los dos esqueletos completos (Next.js route + Supabase Edge Function), **ILUSTRATIVOS falla-cerrado**
(lanzan antes de responder 200 a propósito — no son copy-paste ejecutable, ver su propia justificación
de seguridad) con punteros a las implementaciones reales del repo, viven en
`references/cross-skill-webhook-patterns.md` — **excepto la serialización de idempotencia** (lock de
fila / lease), que hoy es un gap conocido en los 5 webhooks de cobro (stripe/paypal/mercadopago/
nowpayments/hotmart), trackeado en TAL-2992 y señalado explícitamente junto a cada puntero. Para
payment/commerce skills, mostrar también el patrón de Server Action para crear recursos.

### talent-docs-skill

When creating a skill that generates documentation artifacts (ADRs, API docs, runbooks),
coordinate with `talent-docs-skill` for Diataxis framework alignment. The new skill's
reference files ARE documentation — apply Diataxis categories:

```text
┌──────────────────────────────────────────────────────────┐
│          DIATAXIS MAPPING FOR SKILL FILES                 │
├──────────────────────────┬───────────────────────────────┤
│ Skill Component          │ Diataxis Category             │
├──────────────────────────┼───────────────────────────────┤
│ SKILL.md Quick Start     │ Tutorial                      │
│ Reference files          │ Reference                     │
│ Critical Gotchas         │ How-to guide (troubleshooting)│
│ Cross-Skill Integration  │ Explanation                   │
└──────────────────────────┴───────────────────────────────┘
```

### CLAUDE.md (root)

Every new skill MUST be registered as a row in the `## Skills Obligatorios` table of the root
`CLAUDE.md` — see `references/claude-md-registration.md` for the exact procedure and the
false-green traps a naive `grep` falls into (scope, column, exactness).

---

## Next Steps

Read the reference files based on your current step:

- **Creating the SKILL.md entry point?** → `references/skill-md-template.md`
- **Creating reference documentation?** → `references/reference-file-template.md`
- **Creating a TypeScript helper script?** → `references/typescript-helper-template.md`
- **Creating a Python helper script?** → `references/python-helper-template.md`
- **Registering the skill in CLAUDE.md?** → `references/claude-md-registration.md`
- **Bootstrapping a skill directory or running the Gold Standard validators?** → `references/quick-scaffold.md`
- **Writing the Cross-Skill Integration webhook example?** → `references/cross-skill-webhook-patterns.md`

## Paquete de fábrica

Este skill es miembro del **paquete de skills de fábrica** (16): linear-skill · skill-creator · talent-buzz ·
talent-ceo · talent-channel-operation · talent-channels · talent-context · talent-coordination ·
talent-issue-craft · talent-llm-local · talent-memoria · talent-merger · talent-orchestrator · talent-pm · talent-prd · talent-repo-onboarding. El paquete viaja JUNTO y
**motor-primero**: canónico en el repo motor `talent-factory` (`skills/`), propagado como núcleo
a los repos de producto con `skill-creator/scripts/sync-package.sh` (overlays por repo intactos)
y validado con `skill-creator/scripts/validate-package.sh` + `<skill>/invariants.tsv`.
Manifiesto: `skill-creator/assets/package.manifest` · doctrina y ratchet (D6): `skill-creator/references/09-paquete-de-fabrica.md`.
