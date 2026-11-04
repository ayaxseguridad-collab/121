#!/usr/bin/env bash
# lib/handoff.sh — Extractor ÚNICO del bloque machine-readable del HANDOFF (Fábrica v2, ADR-0043).
#
# Fuente canónica del contrato: docs/templates/handoff-pr-draft.md (schema_version 1).
# Este lib evita lógica/regex paralela: lo sourcean tanto scripts/verify-handoff.sh (validador
# del contrato completo) como scripts/crosscheck-migration-slot.sh (cross-check slot↔diff↔ledger).
# Un solo extractor ⇒ el awk de fences ```json no puede divergir entre scripts.
#
# Uso:
#   source "$(git rev-parse --show-toplevel)/scripts/lib/handoff.sh"
#   handoff_extract "$pr_json"     # $pr_json = salida de `gh pr view <pr> --json ...,comments`
#   # tras la llamada:
#   #   $HANDOFF_BLOCK    → el objeto JSON del último comentario con schema_version ("" si ninguno)
#   #   $HANDOFF_COMMENT  → el cuerpo COMPLETO del comentario que lo contiene ("" si ninguno)
#
# Por qué DOS valores: el bloque JSON solo NO es entrega. verify-handoff.sh valida sobre
# $HANDOFF_COMMENT las 9 cabeceras humanas de la plantilla (rechaza HANDOFF JSON-only). Perder
# $HANDOFF_COMMENT regresaría ese gate — de ahí que el extractor exponga ambos.

# handoff_extract <pr_json>
# Recorre .comments[].body en orden; de cada body extrae el ÚLTIMO fence ```json y se queda con
# el último objeto parseable que tenga schema_version, conservando el comentario que lo contiene.
handoff_extract() {
  local pr_json="${1:-}"
  HANDOFF_BLOCK=""
  HANDOFF_COMMENT=""
  local encoded_body body block
  while IFS= read -r encoded_body; do
    body="$(jq -r . <<<"$encoded_body")"
    block="$(awk '/^[[:space:]]*```json[[:space:]]*$/{inb=1; buf=""; next}
                  /^[[:space:]]*```[[:space:]]*$/{if(inb){last=buf; inb=0}; next}
                  inb{buf = buf $0 "\n"} END{printf "%s", last}' <<<"$body")"
    if [ -n "$block" ] && jq -e 'type == "object" and has("schema_version")' <<<"$block" >/dev/null 2>&1; then
      HANDOFF_BLOCK="$block"
      HANDOFF_COMMENT="$body"
    fi
  done < <(jq -c '.comments[].body' <<<"$pr_json")
}
