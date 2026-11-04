# Referencia 01 — Capas y contratos de la fábrica

> **Fuente de verdad**: la config viva (GitHub API) y los canónicos @`origin/main` del repo TA
> mandan sobre cualquier doc. Siempre verificar contra el estado real AL EJECUTAR.

## Modelo de 5 capas

| Capa | Nombre | Qué cubre | Fuente canónica |
|------|--------|-----------|-----------------|
| **0** | Identidad del repo | Nombre, slug, workspace Linear, team-key, linear_team_key | Anexo por repo |
| **A** | Branch protection + repo settings | Protección de `main` (A2) + configuración del repo GitHub (A2b) | `setup-branch-protection.sh` + GET /repos |
| **B** | Hooks, scripts y plantillas | Artefactos byte-idénticos al repo TA (pre-push, verify-handoff, cr-review, etc.) | `git show origin/main:<path>` del repo TA |
| **C** | Reglas y configuración equivalente | CLAUDE.md/AGENTS.md (bloque de reglas), .coderabbit.yaml, settings.json, PR template, .gitignore | Contratos estructurales del manifiesto |
| **D** | Entorno del clon | `core.hooksPath`, skill talent-issue-craft, perfil del repo | Estado del clon / presencia en disco |

---

## Capa A2 — Branch protection (`main`)

**Fuente**: PUT canónico en `scripts/setup-branch-protection.sh` (repo TA).
**Verificación**: `gh api repos/<slug>/branches/main/protection` — los 12 valores deben coincidir.

| # | Campo | Valor canónico |
|---|-------|---------------|
| 1 | `required_status_checks.checks[].context` | `["local-gates"]` (único) |
| 2 | `required_status_checks.strict` | `true` |
| 3 | `enforce_admins.enabled` | `false` |
| 4 | `required_pull_request_reviews.required_approving_review_count` | `0` |
| 5 | `required_pull_request_reviews.dismiss_stale_reviews` | `true` |
| 6 | `required_pull_request_reviews.require_code_owner_reviews` | `false` |
| 7 | `required_pull_request_reviews.require_last_push_approval` | `false` |
| 8 | `restrictions` | `null` |
| 9 | `required_linear_history.enabled` | `true` |
| 10 | `allow_force_pushes.enabled` | `false` |
| 11 | `allow_deletions.enabled` / `block_creations.enabled` | `false` / `false` |
| 12 | `required_conversation_resolution.enabled` | `true` |

**Caso plan-Free**: si GitHub responde 403 "Upgrade to GitHub Pro" → la protección no está enforced
vía API (el plan no lo permite). El checker emite MANUAL-PENDING (exit 3) y el lead debe verificar
y aplicar la protección proceduralmente.

---

## Capa A2b — Repo settings

**Fuente**: `GET /repos/<slug>` (GitHub REST).
**Los 4 valores canónicos**:

| Campo | Valor |
|-------|-------|
| `allow_squash_merge` | `true` |
| `allow_merge_commit` | `true` |
| `allow_rebase_merge` | `true` |
| `delete_branch_on_merge` | `false` |

---

## Capa B — Artefactos IDÉNTICOS (byte-idénticos)

Verificación: `hash de bytes + tipo de archivo + modo del índice (git ls-files -s) + test -x`.

| Artefacto | Path en repo TA | Modo git |
|-----------|----------------|----------|
| `pre-push` | `.githooks/pre-push` | `100755` |
| `verify-handoff` | `scripts/verify-handoff.sh` | `100755` |
| `cr-review` | `scripts/cr-review.sh` | `100755` |
| `audit-go` | `scripts/audit-go.sh` | `100755` |
| `check-push-audit` | `scripts/check-push-audit.sh` | `100755` |
| `setup-githooks` | `scripts/setup-githooks.sh` | `100755` |
| `handoff-template` | `docs/templates/handoff-pr-draft.md` | `100644` |
| `validar-rama-pr` | `scripts/github/validar-rama-pr.sh` | `100755` |
| `lib-handoff` | `scripts/lib/handoff.sh` | `100755` |
| `cr-finding-normalize` | `scripts/lib/cr-finding-normalize.jq` | `100644` |

**Cierre transitivo** (derivado por grep de invocaciones, no lista manual):

- `verify-handoff.sh` → `scripts/github/validar-rama-pr.sh` + `scripts/lib/handoff.sh`
- `scripts/draft-handoff.sh` → `scripts/github/validar-rama-pr.sh`
- `scripts/cr-review.sh` → `scripts/lib/cr-finding-normalize.jq`

**Regla**: copiar SIEMPRE desde `git show origin/main:<path>` del repo TA — nunca el working tree.
Si el repo TA actualiza un canónico, el repo destino debe re-copiar para mantener paridad.

---

## Capa C — Artefactos EQUIVALENTES (contrato estructural)

No paridad de bytes — cada repo tiene sus propios gates/reglas. Se verifica estructura cerrada.

| Artefacto | Contrato estructural mínimo |
|-----------|----------------------------|
| `scripts/draft-handoff.sh` | shebang + referencia a `validar-rama-pr` + emisión de sentinel `draft-handoff` + gate (typecheck/lint/build) |
| `.coderabbit.yaml` | `drafts: false` + `request_changes_workflow: true` + bloque `auto_review` |
| `CLAUDE.md` | Referencias a `draft-handoff`, `local-gates`, `cr-review` o `coderabbit` |
| `AGENTS.md` | Ídem |
| `.github/PULL_REQUEST_TEMPLATE.md` | Magic word `Closes <KEY>-N` (key del team Linear del repo) |
| `.gitignore` | Ignora LOS 6 patrones como líneas literales sin comentar que git ignore de verdad (decide `git check-ignore`: una negación posterior falla): `.claude/.cr-review-ok` (vale también cubierto por `.claude/.cr-review-*`), `.claude/.draft-handoff`, `.claude/.audit-go`, `.claude/tf-manifest.conf`, `.claude/.motor-go`, `.claude/.cr-review-*` (TAL-8040) |
| `.claude/settings.json` | Registra ambos hooks: `check-skill.sh` y `check-push-audit.sh` |
| `.claude/hooks/check-skill.sh` | Presente, ejecutable, lee `tool_input.file_path`, cableado en settings.json |

---

## Capa D — Contratos de entorno

| Contrato | Cómo verificar |
|----------|---------------|
| `core.hooksPath == .githooks` | `git config --local core.hooksPath` en el repo destino |
| Skill `talent-issue-craft` presente | `ls .claude/skills/talent-issue-craft/` |
| Perfil del repo presente | `ls docs/reference/issue-craft-perfil*.md` |

---

## Magic word — dos gramáticas separadas

| Contexto | Gramática | Implementación |
|----------|-----------|---------------|
| Template PR | Literal `Closes <KEY>-N` | `grep -E "Closes[[:space:]]+<KEY>-[0-9]+"` |
| PR body / receipts | ERE POSIX insensible | `command grep -iE "(closes|fixes|resolves)[[:space:]]+<KEY>-[0-9]+"` |

**Siempre usar `command grep`** en matchers de scripts — el harness de tests puede delegar en
`ugrep` (alias), produciendo falsos verdes con `\d` o `(?i)`. ERE POSIX: `[0-9]`, nunca `\d`; `-i`,
nunca `(?i)`.

**Ejemplo de falso positivo documentado**: `.github/PULL_REQUEST_TEMPLATE.md` del repo TA contiene
`Closes ENG-...` (deuda separada). Un check de «presencia de `Closes`» daría verde incluso con
key `TAL`. Por eso el checker valida POR KEY.
