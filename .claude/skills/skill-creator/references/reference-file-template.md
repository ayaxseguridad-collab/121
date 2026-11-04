# Reference File Template — Gold Standard

Template for creating reference files inside `references/`. Each reference file covers
one logical topic group of the API/service.

## Table of Contents

1. [Filename Conventions](#1-filename-conventions)
2. [Required Structure](#2-required-structure)
3. [TOC Anchor Format](#3-toc-anchor-format)
4. [Code Block Rules](#4-code-block-rules)
5. [Complete Template](#5-complete-template)

---

## 1. Filename Conventions

**All reference files use kebab-case, lowercase only.**

```
✅ CORRECT                          ❌ WRONG
payments-and-checkout.md            Payments_And_Checkout.md
webhooks-and-ipn.md                 WEBHOOKS.md
error-handling-and-rate-limits.md   ErrorHandling.md
sdk-and-plugins.md                  SDKs & Plugins.md
auth-and-setup.md                   AUTH_SETUP.md
```

**Naming pattern**: `{primary-topic}[-and-{secondary-topic}].md`

Common groupings:
- `auth-and-setup.md` — Authentication, initialization, env vars
- `payments-and-checkout.md` — Core payment operations
- `webhooks-and-ipn.md` — Webhook/callback handling
- `subscriptions-and-billing.md` — Recurring payment logic
- `error-handling-and-rate-limits.md` — Errors, retries, limits
- `testing-and-tooling.md` — Dev tools, sandbox, CI/CD
- `sdk-and-plugins.md` — SDK choices, plugins, widgets

---

## 2. Required Structure

Every reference file must have these sections in order:

```
1. Title line (# Topic — Complete Reference)
2. Subtitle (one line: what it covers, API version)
3. Table of Contents (## Table of Contents)
4. Numbered sections (## N. Section Name)
5. Each section has:
   - Prose explanation (2-5 paragraphs)
   - Code examples (2+ languages where applicable)
   - Error handling for that topic
   - At least 1 ASCII diagram per reference file
6. Final section: Gotchas & Cross-References
```

---

## 3. TOC Anchor Format

GitHub-flavored markdown anchor rules:
- Lowercase everything
- Replace spaces with hyphens
- Strip special characters (parentheses, slashes, ampersands, periods)
- Keep numbers

```markdown
## Table of Contents

1. [PaymentIntents API — Complete Lifecycle](#1-paymentintents-api--complete-lifecycle)
2. [Checkout Sessions — Hosted & Embedded](#2-checkout-sessions--hosted--embedded)
3. [Payment Methods Catalog](#3-payment-methods-catalog)
4. [3D Secure / SCA](#4-3d-secure--sca)
5. [Gotchas & Cross-References](#5-gotchas--cross-references)
```

**Mapping examples:**

| Section Title | Anchor |
|---------------|--------|
| `## 1. PaymentIntents API — Complete Lifecycle` | `#1-paymentintents-api--complete-lifecycle` |
| `## 2. Checkout Sessions — Hosted & Embedded` | `#2-checkout-sessions--hosted--embedded` |
| `## 3. 3D Secure / SCA` | `#3-3d-secure--sca` |
| `## 4. Error Handling & Rate Limits` | `#4-error-handling--rate-limits` |

---

## 4. Code Block Rules

1. **Language tag required**: Always specify ` ```typescript `, ` ```python `, ` ```bash `, etc.
2. **Copy-pasteable**: Include imports, initialization, and the full operation
3. **Realistic values**: Use realistic parameter values, not `"foo"` or `"bar"`
4. **Comment separators**: Use `// ---` or `# ---` between logical blocks
5. **Error handling**: Show try/catch with actual error types from the SDK
6. **Two languages minimum**: TypeScript + Python for every code example (where applicable)

```typescript
// ✅ CORRECT: Complete, runnable, realistic
import Stripe from 'stripe';
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!);

const pi = await stripe.paymentIntents.create({
  amount: 2000,
  currency: 'usd',
  automatic_payment_methods: { enabled: true },
});
```

```typescript
// ❌ WRONG: Missing imports, fake values, no error handling
const result = await api.create({ amount: "foo" });
```

---

## 5. Complete Template

Use this template as the starting point for every reference file:

````markdown
# {{Topic}} — Complete Reference

Covers {{brief description of what this reference covers}}. API version `{{API_VERSION}}`,
{{SDK_NAME}} v{{SDK_VERSION}}.

## Table of Contents

1. [{{Section 1 Title}}](#1-{{anchor-1}})
2. [{{Section 2 Title}}](#2-{{anchor-2}})
3. [{{Section 3 Title}}](#3-{{anchor-3}})
4. [{{Section N Title}}](#n-{{anchor-n}})
5. [Gotchas & Cross-References](#{{n+1}}-gotchas--cross-references)

---

## 1. {{Section 1 Title}}

### 1.1 {{Subsection}}

{{Prose explanation: what it is, when to use it, key concepts.}}

```typescript
// {{Operation description}}
import {{Import}} from '{{package}}';

const client = new {{Client}}(process.env.{{ENV_VAR}}!);
const result = await client.{{method}}({
  {{param1}}: {{value1}},
  {{param2}}: {{value2}},
});
```

```python
# Same operation in Python
from {{package}} import {{Client}}

client = {{Client}}("{{env_var}}")
result = client.{{method}}(
    {{param1}}={{value1}},
    {{param2}}={{value2}},
)
```

### 1.2 {{Subsection}}

```
<!-- ASCII diagram showing flow, architecture, or decision tree -->
┌──────────┐     ┌──────────┐     ┌──────────┐
│ Step 1   │────→│ Step 2   │────→│ Step 3   │
└──────────┘     └──────────┘     └──────────┘
```

---

## 2. {{Section 2 Title}}

<!-- Continue with same structure: prose + code + diagrams -->

---

## {{N}}. Gotchas & Cross-References

**Common mistakes in this area:**

1. **{{Gotcha title}}** → {{Explanation}}.
2. **{{Gotcha title}}** → {{Explanation}}.

**Related reference files:**
- For {{topic}} → `{{other-reference}}.md`
- For {{topic}} → `{{other-reference}}.md`
````
