#!/usr/bin/env bash
# rollout_status.sh
# Uso:
#   ./rollout_status.sh <ruta-repo> [<ruta-repo> ...]
#
# Utilidad generica del skill (NO parte de un rollout especifico). Dado uno
# o mas paths locales de repos, reporta el estado de integracion de
# CodeRabbit de cada uno:
#   - Tiene .coderabbit.yaml (o .yml)?
#   - El check "CodeRabbit" (el nombre real del status del GitHub App;
#     tambien es el contexto que puede quedar en FAILURE por rate limit —
#     ver references/rate-limits.md) esta en required status checks del
#     ruleset/branch protection vigente de main?
#
# NOTA (D1, 2026-09-05): este script cubria antes tambien SonarQube (columnas
# SQ/WF); esa parte se dio de baja junto con el resto de la extension
# SonarQube del skill (ADR-0029, retirada de SonarCloud). Lo que sigue es
# CodeRabbit-only.
#
# En ESTA casa (Example Project 2026) el gate requerido de `main` es el
# commit-status `local-gates` (no un check de CodeRabbit — ver CLAUDE.md
# reglas 12/16-17 y `docs/runbooks/local-gates.md`): la columna `enforce`
# de este script reporta si el propio REPO CONSULTADO tiene el check
# "CodeRabbit" como required — util para repos que SI lo usan como gate de
# GitHub Actions/App, no una prescripcion de que este repo deba tenerlo.
#
# Deriva el slug de cada repo dinamicamente con gh repo view (fallback a
# parseo de git remote get-url origin). NUNCA hardcodea owner/org.
#
# Requiere: gh CLI autenticado, jq.
#
# last_verified: 2026-09-05
set -euo pipefail

case "${1:-}" in
  -h|--help)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <ruta-repo> [<ruta-repo> ...]" >&2
  exit 1
fi

CANONICAL_CHECK="CodeRabbit"

derive_repo() {
  local dir="$1"
  local repo=""
  if command -v gh >/dev/null 2>&1; then
    # gh repo view no acepta -R <ruta-local>; se ejecuta con cwd=dir
    repo="$(cd "$dir" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
  if [[ -z "$repo" ]]; then
    local remote
    remote="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
    if [[ -n "$remote" ]]; then
      remote="${remote%.git}"
      # Todo lo que va despues de "github.com/" o "github.com:" es "owner/repo"
      # (el nombre del repo puede llevar puntos, p.ej. "repo.v2":
      # no restringir el patron a caracteres sin punto).
      repo="$(echo "$remote" | sed -E 's#.*github\.com[:/]##')"
    fi
  fi
  echo "$repo"
}

# Rama por defecto REAL del repo (no se presupone "main"). Falla (rc 1) si la
# consulta falla: un error de red/permisos/rate limit NO se disfraza de "main".
default_branch() {
  local repo="$1" def
  def="$(gh api "repos/$repo" --jq '.default_branch' 2>/dev/null)" || return 1
  [[ -n "$def" ]] || return 1
  echo "$def"
}

# gh api que distingue "no existe" (HTTP 404 → salida vacia, rc 0) de un fallo
# real (401/403/429/5xx/red → rc 1). Uso: gh_api_or_404 <endpoint> [args gh api...]
gh_api_or_404() {
  local out err rc=0
  err="$(mktemp)"
  out="$(gh api "$@" 2>"$err")" || rc=$?   # sin esto, set -e abortaria en el fallo
  if [[ $rc -ne 0 ]]; then
    if grep -q 'HTTP 404' "$err"; then rm -f "$err"; return 0; fi
    cat "$err" >&2; rm -f "$err"; return 1
  fi
  rm -f "$err"; printf '%s\n' "$out"
}

# Deteccion de rulesets de rama activos que APLIQUEN a la rama por defecto.
# Un ruleset aplica si alguno de sus patrones include cubre esa rama
# (~ALL, ~DEFAULT_BRANCH, el ref exacto o un glob como refs/heads/*,
# refs/heads/**) y ningun patron exclude la cubre.
# Sale con rc 1 si alguna consulta falla por algo que no sea 404.
ruleset_required_checks() {
  local repo="$1" def ids rs
  def="refs/heads/$(default_branch "$repo")" || return 1
  ids="$(gh_api_or_404 "repos/$repo/rulesets" --paginate --jq '
    .[] | select(.target == "branch" and .enforcement == "active") | .id')" || return 1
  for RS_ID in $ids; do
      rs="$(gh_api_or_404 "repos/$repo/rulesets/$RS_ID")" || return 1
      [[ -n "$rs" ]] || continue
      printf '%s' "$rs" | jq -r --arg def "$def" '
        # glob de GitHub -> regex: primero se escapan los metacaracteres literales (., +, ?, ^, $, (), {}, |, \\)
        # y despues se traducen ** (cualquier ruta), * (un segmento) y ? (un caracter); los corchetes [...]
        # se dejan tal cual (misma semantica de clase de caracteres en fnmatch y en regex).
        def glob_re: gsub("\\*\\*"; "__DS__") | gsub("\\*"; "__S__") | gsub("\\?"; "__Q__")
          | gsub("(?<m>[.+^${}()|\\\\])"; "\\" + .m)
          | gsub("__DS__"; ".*") | gsub("__S__"; "[^/]*") | gsub("__Q__"; "[^/]") | "^" + . + "$";
        def covers($ref): . as $p
          | ($p == "~ALL" or $p == "~DEFAULT_BRANCH" or $p == $ref or ($ref | test($p | glob_re)));
        select(
          ((.conditions.ref_name.include // []) | any(covers($def)))
          and (((.conditions.ref_name.exclude // []) | any(covers($def))) | not)
        )
        | .rules[]?
        | select(.type == "required_status_checks")
        | .parameters.required_status_checks[]?
        | .context'
  done
}

# 404 = la rama no tiene branch protection (salida vacia, rc 0); otro fallo → rc 1.
branch_protection_required_checks() {
  local repo="$1" def
  def="$(default_branch "$repo")" || return 1
  gh_api_or_404 "repos/$repo/branches/$def/protection" --jq '
    .required_status_checks.contexts // [] | .[]'
}

printf "%-40s | %-8s | %-9s | %-s\n" \
  "repo" "CR yaml" "enforce" "ruta"
echo "-------------------------------------------------------------------"

for DIR in "$@"; do
  if [[ ! -d "$DIR" ]]; then
    printf "%-40s | %-8s | %-9s | %s\n" \
      "(no dir)" "-" "-" "$DIR"
    continue
  fi

  REPO="$(derive_repo "$DIR")"
  [[ -z "$REPO" ]] && REPO="(no remote)"

  CR="no"
  [[ -f "$DIR/.coderabbit.yaml" || -f "$DIR/.coderabbit.yml" ]] && CR="yes"

  ENFORCE="no"
  if [[ "$REPO" != "(no remote)" ]]; then
    # Primero ruleset; "no" SOLO si ambas consultas confirmaron la ausencia.
    # Un fallo de red/permisos/rate limit se reporta como "unknown", nunca como "no".
    if ! RS_CHECKS="$(ruleset_required_checks "$REPO")"; then
      ENFORCE="unknown"
    elif echo "$RS_CHECKS" | grep -qxF "$CANONICAL_CHECK"; then
      ENFORCE="ruleset"
    elif ! BP_CHECKS="$(branch_protection_required_checks "$REPO")"; then
      ENFORCE="unknown"
    elif echo "$BP_CHECKS" | grep -qxF "$CANONICAL_CHECK"; then
      ENFORCE="branch-prot"
    fi
  fi

  printf "%-40s | %-8s | %-9s | %s\n" \
    "$REPO" "$CR" "$ENFORCE" "$DIR"
done

echo ""
echo "Leyenda:"
echo "  CR yaml = existe .coderabbit.yaml o .coderabbit.yml"
echo "  enforce = '${CANONICAL_CHECK}' en required status checks del repo consultado:"
echo "    - ruleset: ruleset de rama activo que aplica a la rama por defecto"
echo "    - branch-prot: branch protection clasica de la rama por defecto"
echo "    - no: shadow mode (check no bloqueante) o repo sin ese required check"
echo "    - unknown: no se pudo consultar (permisos, red o rate limit) — no significa 'no'"
echo "  Nota: un status 'CodeRabbit' en FAILURE puede deberse a rate limit,"
echo "  no a un veredicto de review (ver references/rate-limits.md)."
