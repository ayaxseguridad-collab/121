#!/usr/bin/env bash
# fetch_cr_comments.sh
# Uso:
#   ./fetch_cr_comments.sh <owner/repo> <pr_number>
#   ./fetch_cr_comments.sh <owner/repo> <pr_number> --sources all
#
# Obtiene review threads de un PR via GitHub GraphQL API, filtra los de
# CodeRabbit, y los emite como JSON con shape accionable para Claude Code:
#   {thread_id, path, line, category, is_committable, has_ai_prompt, body, resolved}
#   (+ has_committable_suggestion, alias del nombre que usaba la v2, con el mismo valor)
# (mas los campos adicionales resolved/outdated/first_comment_*/created_at/
# severity/is_coderabbit ya presentes desde v2 — no se quitan, solo se anaden).
#
# `category` reconoce DOS sistemas de taxonomia de CodeRabbit (ver
# references/comment-taxonomy.md): la matriz heredada de 4 badges
# (Security/Potential issue/Refactor suggestion/Nitpick) y los seis
# "review types" oficiales vigentes (Security & Privacy, Stability &
# Availability, Data Integrity & Integration, Functional Correctness,
# Performance & Scalability, Maintainability & Code Quality). Cuando el
# comentario trae ademas un badge de severidad oficial (Critical/Major/
# Minor/Trivial/Info), se emite en el campo `severity` (null si no aplica).
#
# --sources all (opcional): ademas de los review threads inline, incluye
# como entradas con `thread_id: null` los "issue comments" (walkthrough) y
# los cuerpos de "reviews" (resumen) de CodeRabbit en el PR — tres fuentes
# REST del App, ver references/graphql-api.md. Sin este flag, el
# comportamiento es identico al de siempre (solo review threads inline).
#
# Requiere: gh CLI autenticado con scope `repo`.
#
# Nota shellcheck: SC2016 (info) es esperado y no se corrige — la query GraphQL
# de abajo va en comillas simples A PROPOSITO (es texto literal para -f
# query=, no debe expandir variables de shell).
#
# last_verified: 2026-09-22
set -euo pipefail

case "${1:-}" in
  -h|--help)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

REPO="${1:?Usage: $0 <owner/repo> <pr_number> [--sources all]}"
PR="${2:?Usage: $0 <owner/repo> <pr_number> [--sources all]}"
SOURCES="inline"
# Forma completa de argumentos: <owner/repo> <pr> [--sources all]; cualquier otra
# cosa (flag desconocida, valor distinto de all, argumentos de mas) es un error de uso.
case "$#" in
  2) ;;
  4) if [ "$3" = "--sources" ] && [ "$4" = "all" ]; then SOURCES="all"; else
       echo "Usage: $0 <owner/repo> <pr_number> [--sources all]" >&2; exit 2; fi ;;
  *) echo "Usage: $0 <owner/repo> <pr_number> [--sources all]" >&2; exit 2 ;;
esac
OWNER="${REPO%/*}"
NAME="${REPO#*/}"

# Query GraphQL: obtiene TODOS los review threads con sus comentarios y metadata
# de resolucion, paginando con pageInfo.endCursor/hasNextPage (100 por pagina).
QUERY='
query($owner: String!, $name: String!, $pr: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          startLine
          comments(first: 20) {
            nodes {
              id
              databaseId
              author { login }
              body
              createdAt
              url
            }
          }
        }
      }
    }
  }
}'

# Acumula las paginas de reviewThreads en NODES (array JSON). Un fallo de gh api
# (red, auth, rate limit) aborta el script por set -e: nunca se emite un listado
# parcial como si fuera completo.
NODES='[]'
CURSOR=''
while :; do
  if [ -n "$CURSOR" ]; then
    PAGE=$(gh api graphql -f query="$QUERY" -F owner="$OWNER" -F name="$NAME" -F pr="$PR" -f cursor="$CURSOR")
  else
    PAGE=$(gh api graphql -f query="$QUERY" -F owner="$OWNER" -F name="$NAME" -F pr="$PR")
  fi
  # Repo o PR inexistentes (o sin acceso) llegan como pullRequest: null con HTTP 200;
  # no se confunden con "PR sin hilos".
  if [ "$(printf '%s' "$PAGE" | jq -r '.data.repository.pullRequest | if . == null then "null" else "ok" end')" != "ok" ]; then
    echo "fetch_cr_comments: el PR #$PR de $REPO no existe o no es accesible con este token" >&2
    exit 2
  fi
  NODES=$(jq -n --argjson acc "$NODES" --argjson page "$PAGE" \
    '$acc + ($page.data.repository.pullRequest.reviewThreads.nodes // [])')
  if [ "$(printf '%s' "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')" != "true" ]; then
    break
  fi
  CURSOR=$(printf '%s' "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
  [ -n "$CURSOR" ] && [ "$CURSOR" != "null" ] || break
done

# jq: funciones compartidas de categoria/severidad sobre el body de un comentario.
JQ_COMMON='
  # La clasificacion mira SOLO el bloque de badges del comentario (las lineas anteriores a la
  # primera linea en blanco: categoria/severidad), ni el titulo ni el cuerpo: asi "security check"
  # o "Major version" en el titulo o la descripcion no cambian el resultado.
  def hdr: split("\n") | (index("") // length) as $n | .[0:$n] | join(" ");
  def category: hdr |
    if test("🛡️|Security|vulnerabilidad"; "i") or test("🔒"; "") then "security"
    elif test("🩺"; "") or test("Stability & Availability"; "i") then "stability"
    elif test("🗄️"; "") or test("Data Integrity & Integration"; "i") then "data"
    elif test("🎯"; "") or test("Functional Correctness"; "i") then "functional"
    elif test("⚠️ Potential issue|Potential bug|bug potencial"; "i") then "bug"
    elif test("🛠️ Refactor suggestion|Refactor"; "i") then "refactor"
    elif test("🧹 Nitpick|nitpick \\(optional\\)"; "i") then "nitpick"
    elif test("🚀"; "") or test("Performance & Scalability"; "i") or test("⚡|Performance|performance"; "i") then "performance"
    elif test("📐"; "") or test("Maintainability & Code Quality"; "i") then "maintainability"
    elif test("📝 Documentation|Documentation"; "i") then "docs"
    else "other"
    end;
  def severity: hdr |
    if test("🔴|Critical"; "") then "critical"
    elif test("🟠|Major"; "") then "major"
    elif test("🟡|Minor"; "") then "minor"
    elif test("🔵|Trivial"; "") then "trivial"
    elif test("⚪|\\bInfo\\b"; "") then "info"
    else null
    end;
'

# Filtrar threads donde el primer comentario es de CodeRabbit,
# extraer categoria/severidad del cuerpo, y normalizar.
THREADS_JSON=$(printf '%s' "$NODES" | jq -r "
  $JQ_COMMON
  .[]
  | select(.comments.nodes[0].author.login | test(\"coderabbitai\"; \"i\"))
  | {
      thread_id: .id,
      resolved: .isResolved,
      outdated: .isOutdated,
      path: .path,
      line: (.line // .startLine),
      first_comment_id: .comments.nodes[0].databaseId,
      first_comment_url: .comments.nodes[0].url,
      created_at: .comments.nodes[0].createdAt,
      body: .comments.nodes[0].body,
      category: (.comments.nodes[0].body | category),
      severity: (.comments.nodes[0].body | severity),
      is_committable: (.comments.nodes[0].body | test(\"\`\`\`suggestion\")),
      has_committable_suggestion: (.comments.nodes[0].body | test(\"\`\`\`suggestion\")),
      has_ai_prompt: (.comments.nodes[0].body | test(\"Prompt for AI Agents|🤖\")),
      is_coderabbit: true
    }
")

if [ "$SOURCES" != "all" ]; then
  echo "$THREADS_JSON"
  exit 0
fi

# --sources all: suma issue comments (walkthrough) y bodies de review (resumen)
# del App como entradas sin thread_id — no son hilos resolubles por GraphQL.
# Los fallos de gh api se propagan (set -e + pipefail): un 401/403/429 no se
# confunde con "este PR no tiene comentarios".
ISSUE_COMMENTS_JSON=$(gh api "repos/${REPO}/issues/${PR}/comments" --paginate \
  | jq -r "
      $JQ_COMMON
      .[]?
      | select(.user.login | test(\"coderabbitai\"; \"i\"))
      | {
          thread_id: null,
          resolved: null,
          outdated: null,
          path: null,
          line: null,
          first_comment_id: .id,
          first_comment_url: .html_url,
          created_at: .created_at,
          body: .body,
          category: (.body | category),
          severity: (.body | severity),
          is_committable: (.body | test(\"\`\`\`suggestion\")),
          has_committable_suggestion: (.body | test(\"\`\`\`suggestion\")),
          has_ai_prompt: (.body | test(\"Prompt for AI Agents|🤖\")),
          is_coderabbit: true,
          source: \"issue_comment\"
        }
    ")

REVIEW_BODIES_JSON=$(gh api "repos/${REPO}/pulls/${PR}/reviews" --paginate \
  | jq -r "
      $JQ_COMMON
      .[]?
      | select((.user.login | test(\"coderabbitai\"; \"i\")) and (.body // \"\" | length > 0))
      | {
          thread_id: null,
          resolved: null,
          outdated: null,
          path: null,
          line: null,
          first_comment_id: .id,
          first_comment_url: .html_url,
          created_at: .submitted_at,
          body: .body,
          category: (.body | category),
          severity: (.body | severity),
          is_committable: (.body | test(\"\`\`\`suggestion\")),
          has_committable_suggestion: (.body | test(\"\`\`\`suggestion\")),
          has_ai_prompt: (.body | test(\"Prompt for AI Agents|🤖\")),
          is_coderabbit: true,
          source: \"review_body\"
        }
    ")

jq -s 'add' \
  <(printf '%s' "$THREADS_JSON" | jq -s '.') \
  <(printf '%s' "$ISSUE_COMMENTS_JSON" | jq -s '.') \
  <(printf '%s' "$REVIEW_BODIES_JSON" | jq -s '.') \
  | jq -c '.[]'
