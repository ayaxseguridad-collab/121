#!/usr/bin/env bash
# challenge_thread.sh
# Uso:
#   ./challenge_thread.sh <owner/repo> <pr_number> <comment_id> "<razon>"
#   ./challenge_thread.sh --graphql <thread_id> "<razon>"
#
# Responde a un comentario de CodeRabbit en desacuerdo, etiquetando al bot
# para que aprenda. La ruta --graphql ademas RESUELVE el thread en el acto
# (llama a resolve_thread.sh, que vive junto a este script); la ruta REST no
# conoce el thread_id y solo imprime como resolverlo. Esto entrena el learning
# del repo para que CR no re-sugiera el mismo issue en PRs futuros.
#
# Dos rutas equivalentes (ver references/graphql-api.md):
# - REST (default, requiere owner/repo + pr_number + comment_id=databaseId):
#   POST repos/{owner}/{repo}/pulls/{pr}/comments/{comment_id}/replies
# - GraphQL (--graphql, requiere solo el thread_id de fetch_cr_comments.sh):
#   mutation addPullRequestReviewThreadReply(threadId: ID!, body: String!)
#   Util cuando ya se tiene el thread_id (p. ej. tras un resolve_thread.sh
#   fallido) y no se quiere volver a resolver el databaseId del comentario.
#
# Requiere:
# - gh CLI autenticado
# - comment_id (ruta REST): databaseId del primer comentario del thread
#   (desde fetch_cr_comments.sh); thread_id (ruta --graphql): formato
#   PRRT_xxxxx, tambien desde fetch_cr_comments.sh
# - razon: explicacion breve de por que CR se equivoco
#
# Ejemplos:
#   ./challenge_thread.sh example-stack/eventbrite-sync 42 1234567890 \
#     "This check is intentional — the Eventbrite API returns 200 for deleted attendees"
#   ./challenge_thread.sh --graphql PRRT_kwDOAbC123 \
#     "This check is intentional — see gotcha X in .claude/memory/gotchas.md"
#
# Nota shellcheck: SC2016 (info) es esperado y no se corrige — la mutation
# GraphQL de abajo va en comillas simples A PROPOSITO (texto literal para
# -f query=, no debe expandir variables de shell).
#
# last_verified: 2026-09-22
set -euo pipefail

case "${1:-}" in
  -h|--help)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

if [ "${1:-}" = "--graphql" ]; then
  THREAD_ID="${2:?Usage: $0 --graphql <thread_id> <reason>}"
  REASON="${3:?Usage: $0 --graphql <thread_id> <reason>}"
  REPLY_BODY="@coderabbitai ${REASON}"

  MUTATION='
  mutation($threadId: ID!, $body: String!) {
    addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) {
      comment {
        id
        databaseId
        url
      }
    }
  }'

  gh api graphql \
    -f query="$MUTATION" \
    -F threadId="$THREAD_ID" \
    -f body="$REPLY_BODY" \
    --jq '.data.addPullRequestReviewThreadReply.comment.url' \
    | sed 's/^/Challenge posted (GraphQL): /'

  echo "Note: CodeRabbit will reply to this and learn from your feedback."
  # Resolver el thread ahora mismo (misma semantica que documenta la cabecera):
  # resolve_thread.sh esta junto a este script, no en el PATH.
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$SCRIPT_DIR/resolve_thread.sh" "$THREAD_ID"
  exit 0
fi

REPO="${1:?Usage: $0 <owner/repo> <pr_number> <comment_id> <reason>}"
PR="${2:?Usage: $0 <owner/repo> <pr_number> <comment_id> <reason>}"
COMMENT_ID="${3:?Usage: $0 <owner/repo> <pr_number> <comment_id> <reason>}"
REASON="${4:?Usage: $0 <owner/repo> <pr_number> <comment_id> <reason>}"

# Post reply al thread mencionando al bot — CR registra esto como learning
REPLY_BODY="@coderabbitai ${REASON}"

gh api \
  --method POST \
  "repos/${REPO}/pulls/${PR}/comments/${COMMENT_ID}/replies" \
  -f body="${REPLY_BODY}" \
  --jq '.html_url' \
  | sed 's/^/Challenge posted: /'

echo "Note: CodeRabbit will reply to this and learn from your feedback."
echo "      To also resolve the thread now, run: resolve_thread.sh <thread_id>"
