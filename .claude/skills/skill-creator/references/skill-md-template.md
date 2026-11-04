# SKILL.md Template — Gold Standard

Complete template for creating a new SKILL.md entry point. Replace all `{{PLACEHOLDER}}`
values and follow the `<!-- INSTRUCTION -->` comments.

## Table of Contents

0. [Skill Loading Model (Progressive Disclosure)](#0-skill-loading-model-progressive-disclosure)
1. [YAML Frontmatter](#1-yaml-frontmatter)
2. [Title and Quick Orientation](#2-title-and-quick-orientation)
3. [Reference Files Table](#3-reference-files-table)
4. [Quick Start Sections](#4-quick-start-sections)
5. [Essential Patterns](#5-essential-patterns)
6. [Critical Gotchas](#6-critical-gotchas)
   - [Reference-Specific Error Handling (Gold Standard Checklist Item 11)](#reference-specific-error-handling-gold-standard-checklist-item-11)
7. [Cross-Skill Integration](#7-cross-skill-integration)
8. [Next Steps](#8-next-steps)

---

## 0. Skill Loading Model (Progressive Disclosure)

Every skill loads in three levels — keep this in mind when deciding what belongs in SKILL.md
versus a reference file:

```text
name + description (frontmatter)   ── always in context        (discovery)
        │
        ▼
SKILL.md (body)                    ── loaded on activation      (activation)
        │
        ▼
references/ · scripts/ · assets/   ── loaded on demand          (execution)
```

Only `name` and `description` are always in context (discovery) — not the full frontmatter.
`references/`, `scripts/`, and `assets/` are the three optional top-level directories loaded on
demand at execution time. `assets/` holds reusable **output resources** the skill copies into a
deliverable (templates, fixtures, reference images, binaries) — not documentation (that belongs
in `references/` or the SKILL.md body itself). Create `assets/` only when the skill has a real,
reusable asset; an empty `assets/` teaches the wrong lesson by example.

---

## 1. YAML Frontmatter

```yaml
---
name: {{SKILL_NAME}}
# kebab-case, matches directory name: e.g., stripe-skill, ga4-skill
description: >
  Use this skill whenever the user needs to work with {{SERVICE_NAME}} — both programmatically
  AND for architecture decisions. This includes: {{LIST_ALL_OPERATIONS}}.
  ALSO trigger for architecture decisions: {{LIST_ARCHITECTURE_DECISIONS}}.
  Trigger keywords: {{COMMA_SEPARATED_KEYWORDS}}.
  # MINIMUM 30 keywords. Include:
  #   - Service name and variations (e.g., "Stripe", "stripe-js")
  #   - Key objects/concepts (e.g., "PaymentIntent", "Checkout Session")
  #   - SDK/package names (e.g., "stripe npm", "stripe-python")
  #   - Common user intents in English AND Spanish
  #   - Action verbs: "create", "set up", "handle", "integrate", "configure"
  Even if the user just asks {{SIMPLE_TRIGGER_PHRASES}}, use this skill.
---
```

**Real example** (from stripe-skill, abbreviated):

```yaml
---
name: stripe-skill
description: >
  Use this skill whenever the user needs to work with Stripe — both programmatically
  AND for payment/billing architecture decisions. This includes: writing TypeScript/Python/Ruby
  code that calls the Stripe API, creating or managing PaymentIntents, Checkout Sessions...
  Trigger keywords: "Stripe", "PaymentIntent", "Checkout Session", "subscription"...
  Even if the user just asks "add payments", "set up billing", "charge a card"...
---
```

### 1.1 Optional Frontmatter Fields (Claude Code)

`name` and `description` are the only two fields most skills in this library document —
but Claude Code's `SKILL.md` frontmatter supports **14 additional optional fields** (16
documented total). `last_verified: 2026-07-15` against `code.claude.com/docs/en/skills`
("Frontmatter reference"):

| Field | When to Use |
|-------|-------------|
| `name` | Display name in skill listings; defaults to the directory name. |
| `description` | What the skill does + when to use it. **Cap: ≤1024 chars**, or ≤1536 combined with `when_to_use`. |
| `when_to_use` | Extra trigger phrases/examples, appended to `description` under the same combined cap. |
| `argument-hint` | Autocomplete hint for expected args, e.g. `[issue-number]`. |
| `arguments` | Named positional args for `$name` substitution in the body. |
| `disable-model-invocation` | `true` to make the skill user-only (`/name`), never model-auto-loaded — e.g. `/deploy`, `/send-slack-message`. |
| `user-invocable` | `false` to hide from the `/` menu (background-knowledge skills users shouldn't invoke directly). |
| `allowed-tools` | Tools usable without a permission prompt while this skill is active. |
| `disallowed-tools` | Tools removed from the pool while active (e.g. block `AskUserQuestion` in an autonomous loop). |
| `model` | Model override for the rest of the turn (accepts `/model` values or `inherit`). |
| `effort` | Effort-level override (`low`\|`medium`\|`high`\|`xhigh`\|`max`) for the turn. |
| `context` | `fork` to run the skill in an isolated subagent. |
| `agent` | Which subagent type to use when `context: fork` is set. |
| `hooks` | Hooks scoped to this skill's lifecycle. |
| `paths` | Glob patterns that gate automatic activation to matching files. |
| `shell` | `bash` (default) or `powershell` for inline `` !`command` `` blocks. |

**Naming convention**: gerund form (`processing-pdfs`, `creating-skills`) is Anthropic's
documented preference for skill directory names; noun-phrase (`stripe-skill`) and
action-oriented (`process-pdfs`) forms remain acceptable — this library uses noun-phrase for
its 39 existing skills and does not require retroactive renaming. `last_verified: 2026-07-15`
against `platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices`.

---

## 2. Title and Quick Orientation

```markdown
# {{SERVICE_NAME}} API & SDK — State of the Art ({{MONTH}} {{YEAR}})

## Quick Orientation

{{SERVICE_NAME}} is {{ONE_SENTENCE_DESCRIPTION}}.

<!-- Include a key metrics table: -->
| Property | Value |
|----------|-------|
| **API Base (Prod)** | `{{PROD_URL}}` |
| **API Base (Sandbox)** | `{{SANDBOX_URL}}` |
<!-- If no sandbox, omit that row -->
| **Current Version** | `{{API_VERSION}}` |
| **Authentication** | {{AUTH_DESCRIPTION}} |
| **Rate Limits** | {{RATE_LIMIT_SUMMARY}} |

**All official SDKs** ({{MONTH}} {{YEAR}}):

<!-- Include ONLY SDKs that actually exist. Verify on npm/PyPI/RubyGems -->
| SDK | Latest Stable | API Version | Min Runtime |
|-----|--------------|-------------|-------------|
| {{package_name}} ({{language}}) | v{{VERSION}} | {{API_VERSION}} | {{MIN_RUNTIME}} |

<!-- Then the reference files table intro: -->
**For deeper topics, read the appropriate reference file before writing code:**
```

---

## 3. Reference Files Table

```markdown
| Topic | Reference File | When to Read |
|-------|---------------|--------------|
| {{TOPIC_1}} | `references/{{filename-1}}.md` | {{WHEN_TO_READ_1}} |
| {{TOPIC_2}} | `references/{{filename-2}}.md` | {{WHEN_TO_READ_2}} |
<!-- One row per reference file. "When to Read" should be action-oriented:
     "Creating payments, handling declines" NOT "Payment information" -->
```

**Real example** (from nowpayments-skill):

```markdown
| Topic | Reference File | When to Read |
|-------|---------------|--------------|
| POST /payment, POST /invoice, payment statuses, partial payments | `references/payments-and-invoices.md` | Creating payments, invoices, checking status |
| IPN payload, HMAC-SHA512 verification, framework handlers | `references/webhooks-and-ipn.md` | Setting up webhook handlers |
```

---

## 4. Quick Start Sections

Provide **at minimum** TypeScript + Python. Add more languages if official SDKs exist.

```markdown
## {{Language}} Quick Start

<!-- Start with install command -->
\`\`\`bash
npm install {{package}}            # v{{VERSION}}
\`\`\`

<!-- Then a complete, runnable example covering 3+ operations -->
\`\`\`typescript
import {{Import}} from '{{package}}';

// --- Initialize client ---
const client = new {{Client}}(process.env.{{ENV_VAR}}!);

// --- Operation 1: {{DESCRIPTION}} ---
const result1 = await client.{{method1}}({
  // Include all required params with realistic values
});

// --- Operation 2: {{DESCRIPTION}} ---
const result2 = await client.{{method2}}({...});

// --- Operation 3: {{DESCRIPTION}} ---
// ...

// --- Error Handling ---
try {
  await client.{{method}}({...});
} catch (err) {
  if (err instanceof {{ErrorClass}}) {
    // Handle specific error types
  }
}
\`\`\`
```

**Rules**:

- Include `npm install` / `pip install` with exact version
- Show real parameter names and realistic values
- Include error handling with actual error classes from the SDK
- Show auto-pagination if the API supports listing
- Comment blocks with `// ---` separators for visual scanning

---

## 5. Essential Patterns

Include 3-5 ASCII diagrams. Common patterns:

```markdown
## Essential Patterns Quick Reference

### {{Object}} Lifecycle

\`\`\`
<!-- Status flow diagram showing transitions -->
state_a → (trigger) → state_b → (trigger) → state_c
                                               ↘ state_d (terminal)
\`\`\`

### {{Decision}} Decision Tree

\`\`\`
Q: {{Question}}?
├── YES → {{Option A}}
│         Best for: {{use case}}
└── NO → Q: {{Follow-up question}}?
         ├── YES → {{Option B}}
         └── NO → {{Option C}}
\`\`\`

### {{Process}} Flow (Compact)

\`\`\`typescript
// Key code pattern as compact reference
// CRITICAL: {{Important note}}
\`\`\`
```

---

## 6. Critical Gotchas

**Minimum 10 items.** Format: numbered, bold title, arrow, explanation.

```markdown
## Critical Gotchas

1. **{{Title}}** → {{Explanation of the specific failure mode and how to avoid it}}.

2. **{{Title}}** → {{Explanation}}.

<!-- Continue to at least 10. Source from:
     - Official documentation caveats
     - GitHub issues (common problems)
     - Stack Overflow top questions
     - Real production incidents
     NOT generic advice like "read the docs" or "handle errors" -->
```

### Reference-Specific Error Handling (Gold Standard Checklist Item 11)

This subsection is part of **§6 Critical Gotchas** above. As a `references/` file itself, this
template must model Item 11 of the Gold Standard References checklist ("Error handling — Each
reference covers error scenarios specific to that topic"). The failure modes specific to
**authoring a SKILL.md entry point** are:

1. **Malformed or incomplete frontmatter** → the skill is not discovered at all. This covers
   more than a missing opening `---`: a missing `description` field, a missing **closing** `---`
   delimiter (the frontmatter block never terminates), or YAML that fails to parse (bad
   indentation, unescaped colons, unquoted special characters) all silently break discovery.
   Fix: validate with a YAML parser before committing; confirm both `name` and `description` are
   present and the block opens **and closes** with `---`.
2. **`description` with too few trigger keywords** → the skill exists but never activates when
   it should (a silent discovery failure, not a crash). Fix: cover ES/EN keywords and enough
   user intents (see §1's 30-keyword minimum).
3. **Broken TOC anchor links** → readers follow a link that resolves nowhere. Fix: anchors are
   lowercase, spaces become hyphens, special characters are stripped; test every link.
4. **SKILL.md too long, no progressive disclosure** → the whole file loads into context on
   activation, causing context bloat. Fix: move depth to `references/`; keep SKILL.md itself in
   the ~250-400 line range (see Sizing Guide in the parent SKILL.md).
5. **`name` that does not match the skill's directory name** → ambiguous or failed discovery.
   Fix: `name` must be kebab-case and identical to the containing directory name.

---

## 7. Cross-Skill Integration

**Minimum 3 integrations**: `convex-skill`, `nextjs-web`, `supabase-skill`.

```markdown
## Cross-Skill Integration

### convex-skill
{{Service}} API calls MUST run in Convex **actions** (not queries or mutations) because
they make external HTTP calls. Store {{key_ids}} in Convex tables.

\`\`\`typescript
// convex/{{service}}.ts — Convex action
"use node";
import { action } from "./_generated/server";

export const {{actionName}} = action({
  args: { /* ... */ },
  handler: async (ctx, args) => {
    // API call here
  },
});
\`\`\`

### nextjs-web
<!-- Server Actions pattern, webhook route pattern, component pattern -->

### supabase-skill
<!-- Edge Function pattern, table storage, RLS considerations -->

### {{other-skill}} (if applicable)
<!-- Any additional integrations that make sense -->
```

---

## 8. Next Steps

```markdown
## Next Steps

Read the reference files based on your task:
- **{{Doing what}}?** → `references/{{file}}.md`
- **{{Doing what}}?** → `references/{{file}}.md`
<!-- One line per reference file, action-oriented trigger -->
```
