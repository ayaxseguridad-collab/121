# CLAUDE.md Registration

How to register a new skill so it is treated as required in this repo (Producto Ejemplo).

## Table of Contents

1. [Overview](#1-overview)
2. [Step 1: Add a Row to the Required Skills Table](#2-step-1-add-a-row-to-the-required-skills-table)
3. [Step 2 (Optional): Add a Path Entry to check-skill.sh](#3-step-2-optional-add-a-path-entry-to-check-skillsh)
4. [Verification Commands](#4-verification-commands)

---

## 1. Overview

Skills under `.claude/skills/` are **already auto-discovered** by Claude Code from disk — a skill
folder with a valid `SKILL.md` frontmatter doesn't need any registration step to be found and
loaded on demand.

What "registering" a skill in `CLAUDE.md` actually does is different: it declares **project policy**
— which skills are **mandatory** for which kind of work, and **when** to load them. That policy lives
in the `## Skills Obligatorios` table in the root `CLAUDE.md`, with three columns: `Dominio`, `Skill`,
`Notas`.

Two different lifecycles must not be confused here (factory package v1):

- **Skill content propagation.** The nine skills of the factory package (manifest:
  `skill-creator/assets/package.manifest`) are canonical in the `talent-factory` engine repo and
  PROPAGATE from there into each product repo via `skill-creator/scripts/sync-package.sh`
  (core+overlay contract) — for those skills, a product repo is NOT where core content gets
  edited: engine-first, then sync. Skills outside the package still live and run only in their
  own repo, with no generator exporting them anywhere.
- **Root registration (this file's subject).** Declaring a skill as required policy in the root
  `CLAUDE.md`/`AGENTS.md` of a repo is a LOCAL edit of that repo and STAYS local: it is owned by
  the repo-onboarding flow (skill `talent-repo-onboarding`) and is never touched by the package
  sync (root files live outside the skills tree).

Registration is a single edit: **add one row** to the table (Step 1). Optionally, if the skill has
a characteristic file path of its own, a path entry can also be added to the `check-skill.sh`
reminder hook (Step 2) — see the truthful caveat about that hook's current state before relying
on it.

---

## 2. Step 1: Add a Row to the Required Skills Table

The table lives under the `## Skills Obligatorios` heading in the root `CLAUDE.md`. Each row has
three columns:

| Column | Meaning |
|--------|---------|
| `Dominio` | The subject area the skill covers, e.g. "Supabase (DB, Auth, RLS, Storage, Realtime, Edge Functions)" |
| `Skill` | The skill's **invocable name** — its directory name under `.claude/skills/` |
| `Notas` | When to load it, e.g. "Antes de cualquier query, migracion o cambio de auth" |

**Directory name, not the `name:` frontmatter field.** For project skills, Claude Code resolves the
invocable skill by its **directory name**; the `name:` field in `SKILL.md` frontmatter is a
presentation label and can differ. Real example: `.claude/skills/linear-skill/SKILL.md` declares
`name: linear-talent-engine`, but the directory is `linear-skill`, and that is exactly what
`CLAUDE.md` registers — not `linear-talent-engine`:

```markdown
| Linear (issues, sprints, projects) | `linear-skill` | Antes de tocar Linear o referenciar issues |
```

Always use the directory name in the `Skill` column.

**Real example — the existing `supabase-skill` row (verbatim, `CLAUDE.md`):**

```markdown
| Supabase (DB, Auth, RLS, Storage, Realtime, Edge Functions) | `supabase-skill` | Antes de cualquier query, migracion o cambio de auth |
```

Add the new skill's row using that same shape: a concrete `Dominio` description, the skill's real
`Skill` name in backticks, and a concrete `Notas` describing the trigger condition — not a generic
placeholder like "Use when needed".

---

## 3. Step 2 (Optional): Add a Path Entry to check-skill.sh

The repo has a `PreToolUse` hook (matcher `Edit|Write`, registered in `.claude/settings.json`) at
`.claude/hooks/check-skill.sh`. Its `case` blocks map an edited file path to the skill(s) that should
be loaded for it, e.g.:

```bash
case "$MATCH_PATH" in
  */src/lib/supabase/*.ts|*/supabase/migrations/*.sql|*/supabase/functions/*|*/supabase/config.toml)
    SKILLS="$SKILLS supabase-skill" ;;
esac
```

If the new skill has a characteristic path of its own (e.g. a dedicated directory under `src/lib/`),
adding a matching `case` block is the intended way to wire it into this reminder mechanism.

**Truthful caveat — the hook does not currently fire.** `check-skill.sh` reads the edited file's path
from `file_path` at the **root** of the hook's JSON input. Claude Code's actual `PreToolUse` payload
nests it at **`tool_input.file_path`** instead (confirmed against the official hooks documentation).
With the real payload shape, the script's `file_path` lookup is empty, so it exits `0` with **no**
output — the reminder never prints. Fixing `check-skill.sh` to read `tool_input.file_path` is a
separate, non-documentation change, out of scope for this file — it needs its own dedicated issue
(none currently tracks it; do not assume one exists without checking). Until that fix lands, adding a
`case` block here records the intended mapping for when the hook is corrected, but does not make the
reminder fire today.

---

## 4. Verification Commands

```bash
SKILL="<skill-name>"  # the directory name, e.g. "supabase-skill"

# Verify the new row was added to the Required Skills Table.
# Three things a naive `grep "$SKILL" CLAUDE.md` gets wrong:
#   1. Scope — the whole file is a false-green trap: the skill's directory name
#      may already appear elsewhere in CLAUDE.md (prose, another table) even if
#      the table row was never added. Scope the search to the
#      "## Skills Obligatorios" section itself.
#   2. Column — a match anywhere on the row is a false-green trap too: the
#      `Notas` column can legitimately contain unrelated backtick-quoted names
#      (e.g. the `talent-quiz-builder` row's Notas mentions the DB table
#      `` `transcripts` ``). The check must read the **Skill column only**
#      (the row's 3rd `|`-delimited field: `| Dominio | Skill | Notas |`).
#   3. Exactness — within that column, a substring match is a false-green trap:
#      searching "skill" or "linear" would match `linear-skill`'s cell without
#      the exact name being registered. Require an exact match against the
#      column's content, split on `,` to support multi-skill cells like
#      `` `meta-ads-api`, `google-ads-api` ``.
awk -F'|' '
  /^## Skills Obligatorios/{flag=1; next}
  /^## /{flag=0}
  flag && NF>=4 {print $3}
' CLAUDE.md \
  | tr ',' '\n' \
  | sed 's/`//g; s/^[[:space:]]*//; s/[[:space:]]*$//' \
  | grep -Fxq "$SKILL" \
  && echo "registered" \
  || { echo "NOT registered"; false; }
# The `&& echo ... || { echo ...; false; }` tail matters: it makes the exit code
# of this ENTIRE block equal the check's real result (0 = registered, 1 = not) —
# no subshell, no trailing `echo "rc=$?"` that would reset it back to 0 by being
# the last command run. Safe to paste as-is at an interactive prompt or chain in
# a script (`... && next-step` only runs if the skill is actually registered).

# If a path entry was added to the hook, verify it's present
grep -F "$SKILL" .claude/hooks/check-skill.sh

# Verify the skill directory and SKILL.md exist
ls -la ".claude/skills/$SKILL/"
head -5 ".claude/skills/$SKILL/SKILL.md"
```

If the first `grep` returns nothing, the skill is not yet registered as required policy.
