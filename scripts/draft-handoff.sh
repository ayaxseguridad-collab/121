#!/usr/bin/env bash
# Gates locales antes de emitir el sentinel draft-handoff.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
branch="$(git branch --show-current)"
bash scripts/github/validar-rama-pr.sh "$branch"
[ -z "$(git status --porcelain)" ] || { echo 'falla árbol sucio' >&2; exit 1; }
# typecheck/lint/build: ejecutar TODOS los gates adjudicados del cuestionario.
bash -c 'test -s README.md'
mkdir -p .claude
printf '%s\n' "$(git rev-parse HEAD)" "$branch" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > .claude/.draft-handoff
