#!/usr/bin/env bash
# statusline-ctx.sh — barra de estado de Claude Code que emite `[modelo] ctx: NN%` (talent-context, TAL-8038).
# Es la ÚNICA fuente de la señal `ctx: NN%` que leen `tc_ctx_pct` / `torc_torre_ctx_pct` (compact-60): sin una
# statusLine, el pane no la emite y el sensor queda ciego. Claude Code la invoca con un JSON por stdin
# (`.model.display_name`, `.context_window.used_percentage`).
# Contrato: SIEMPRE rc 0 y UNA línea. Porcentaje = entero redondeado; ausente, no numérico o fuera de 0-100 →
# `ctx: N/A` (jamás un valor inventado: el parser de ctx% lo lee como «ilegible», fail-closed). El nombre del modelo se
# sanea (solo [A-Za-z0-9 ._-]) para que nunca pueda falsificar un `ctx: NN%`. Solo requiere `jq`.
in="$(cat 2>/dev/null || true)"
model=""; pct=""
if command -v jq >/dev/null 2>&1 && [ -n "$in" ]; then
  model="$(printf '%s' "$in" | jq -r '(.model.display_name // empty) | strings' 2>/dev/null | head -1 | tr -cd 'A-Za-z0-9 ._-')"
  pct="$(printf '%s' "$in" | jq -r '.context_window.used_percentage
    | if type == "number" and . >= 0 and . <= 100 then ((. + 0.5) | floor) else empty end' 2>/dev/null | head -1)"
fi
case "$pct" in ''|*[!0-9]*) pct="" ;; esac
[ -n "$model" ] && printf '[%s] ' "$model"
if [ -n "$pct" ]; then printf 'ctx: %s%%\n' "$pct"; else printf 'ctx: N/A\n'; fi
exit 0
