#!/usr/bin/env bash
# resolve_thread.sh
# Uso: ./resolve_thread.sh <thread_id>
#
# Resuelve un review thread de CodeRabbit via GraphQL mutation
# `resolveReviewThread`. Idempotente: safe de llamar en threads ya resueltos.
#
# thread_id tiene formato PRRT_xxxxx, obtenido de fetch_cr_comments.sh
#
# Nota shellcheck: SC2016 (info) es esperado y no se corrige — la mutation
# GraphQL de abajo va en comillas simples A PROPOSITO (texto literal para
# -f query=, no debe expandir variables de shell).
#
# last_verified: 2026-09-05

set -euo pipefail

case "${1:-}" in
  -h|--help)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

THREAD_ID="${1:?Usage: $0 <thread_id>}"

MUTATION='
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread {
      id
      isResolved
    }
  }
}'

gh api graphql \
  -f query="$MUTATION" \
  -F threadId="$THREAD_ID" \
  --jq '.data.resolveReviewThread.thread | "Resolved: \(.id) (isResolved=\(.isResolved))"'
