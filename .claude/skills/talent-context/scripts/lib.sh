#!/usr/bin/env bash
# lib.sh — Helpers PUROS de higiene de contexto (talent-context).
#
# Doctrina: SKILL.md + references/{01-doctrina,04-ctx-watcher}. Repo-agnóstico, token-only, sin MCP.
# Se "source-ea" (`. lib.sh`); no ejecuta acciones por sí solo.
#
# Dos naturalezas:
#   - Funciones PURAS: stdin = una captura de pane (texto); sin tmux ni red. Testeables por
#     tests/run-tests.sh. Son el corazón del ctx-watcher.
#   - Helper de log: tc_say/tc_info/tc_err a stderr (no contaminan el stdout parseable).
#
# Anti-fantasma (ref 04 §parseo + gotcha 6 del SKILL.md): una captura con `capture-pane -e`
# conserva los códigos ANSI, lo que permite distinguir ghost-text (dim `^[[2m`, autocompletado del
# CLI que NO es cola real) de una cola de mensajes real ("Press up to edit queued messages" en
# brillo pleno). Nunca se actúa sobre ghost.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Log a stderr (el stdout queda limpio para el valor parseable, p.ej. el ctx%).
# ---------------------------------------------------------------------------
tc_say()  { printf '── %s\n' "$*" >&2; }
tc_info() { printf '   %s\n' "$*" >&2; }
tc_err()  { printf 'ERROR: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# PURAS — parsers y clasificadores (stdin = captura; sin tmux)
# ---------------------------------------------------------------------------

# Quita TODOS los códigos ANSI (SGR) de una captura.
tc_strip_ansi() { # stdin -> texto plano
  local esc; esc="$(printf '\033')"
  sed -E -e "s/${esc}\[[0-9;]*m//g"
}

# Quita los tramos DIM (ghost-text del autocomplete) de una captura CON -e. Un tramo dim abierto sin
# cierre se descarta hasta el fin de línea (el TUI re-emite los códigos por línea).
tc_strip_ghost() { # stdin = captura CON -e -> misma captura sin ghost
  local esc; esc="$(printf '\033')"
  sed -E -e "s/${esc}\[2m[^${esc}]*(${esc}\[(22|0)m)?//g"
}

# Porcentaje de contexto de la barra de estado ('ctx: NN%'). ÚLTIMO match (la barra vive abajo).
# Sin match -> rc 1 (UNKNOWN fail-closed: JAMÁS asumir 0 ni 100 — ref 01 §3, gotcha 8).
tc_ctx_pct() { # stdin = captura -> N ; rc 1 si no legible
  local pct
  pct="$(tc_strip_ansi | grep -oiE 'ctx[:= ][[:space:]]*[0-9]{1,3}[[:space:]]*%' \
    | tail -1 | grep -oE '[0-9]{1,3}')" || return 1
  [ -n "$pct" ] || return 1
  printf '%s\n' "$pct"
}

# ¿El ctx% de la captura cruza el umbral? rc EXACTOS (contrato del ctx-watcher, ref 04):
#   0 = ctx < umbral (OK) · 2 = ctx >= umbral (COMPACT REQUERIDO) · 3 = UNKNOWN (ilegible, fail-closed).
tc_ctx_over() { # umbral (stdin = captura) -> rc 0|2|3
  local thr="${1:?umbral}" pct
  printf '%s' "$thr" | grep -qE '^[0-9]+$' || { tc_err "umbral no numérico: $thr"; return 3; }
  if pct="$(tc_ctx_pct)"; then
    [ "$pct" -ge "$thr" ] && { printf '%s\n' "$pct"; return 2; }
    printf '%s\n' "$pct"; return 0
  fi
  return 3
}

# Región del COMPOSER: desde la ÚLTIMA línea-prompt ('> ' — las anteriores son eco del historial)
# hasta el final de la captura. Conserva líneas RAW (incluye borde inferior/barra de estado si los
# hay: el CORTE real de contenido lo hace tc_composer_text, no esta función). rc 1 si no hay prompt.
tc_composer_region() { # stdin = captura -> líneas raw ; rc 1 si no hay prompt
  local esc; esc="$(printf '\033')"
  awk -v esc="$esc" '
    { raw[NR]=$0; c=$0; gsub(esc"\\[[0-9;]*m","",c); gsub(/│/,"|",c)
      if (c ~ /^[[:space:]]*[|]?[[:space:]]*>([[:space:]]|$)/) last=NR }
    END { if(!last) exit 1; for(i=last;i<=NR;i++) print raw[i] }'
}

# Contenido REAL del composer, sin borde/barra de estado: la línea-prompt ('> …') MÁS sus líneas de
# continuación bordeadas (│…│) — se CORTA en la PRIMERA línea NO bordeada (borde inferior del box,
# p.ej. '╰────╯', o la barra de estado, p.ej. '? for shortcuts · ctx: NN%'), así ni el borde ni la
# barra cuentan JAMÁS como contenido pendiente (gap detectado: un composer vacío con caja completa
# se clasificaba como 'text' sin este corte).
tc_composer_text() { # stdin = captura -> contenido del composer (multilínea) ; vacío si no hay prompt
  tc_composer_region | tc_strip_ansi | sed -e 's/│/|/g' | awk '
    NR==1 { sub(/^[[:space:]]*[|]?[[:space:]]*>[[:space:]]?/,""); sub(/[[:space:]]*[|]?[[:space:]]*$/,""); print; next }
    /^[[:space:]]*\|/ { l=$0; sub(/^[[:space:]]*\|[[:space:]]?/,"",l); sub(/[[:space:]]*[|]?[[:space:]]*$/,"",l); print l; next }
    { exit }'
}

# Clasifica el estado del INPUT a partir de una captura CON -e (doctrina ref 04 §parseo):
#   queued — "Press up to edit queued messages" en brillo pleno (cola REAL: no reintentar a ciegas)
#   text   — contenido REAL pendiente en el composer (no es nuestro: no clobbear)
#   ghost  — solo autocomplete dim: se IGNORA (no se "neutraliza")
#   empty  — composer vacío (o pane sin composer identificable), incluido borde/barra sin contenido
tc_input_state() { # stdin = captura CON -e -> imprime el estado (rc 0 siempre que lea)
  local cap qline line gline
  cap="$(cat)"
  qline="$(printf '%s\n' "$cap" | grep -i 'press up to edit queued messages' | tail -1)" || true
  if [ -n "$qline" ] && printf '%s\n' "$qline" | tc_strip_ghost \
      | grep -qi 'press up to edit queued messages'; then
    printf 'queued\n'; return 0
  fi
  line="$(printf '%s\n' "$cap" | tc_composer_text)" || line=""
  [ -n "${line//[[:space:]]/}" ] || { printf 'empty\n'; return 0; }
  gline="$(printf '%s\n' "$cap" | tc_strip_ghost | tc_composer_text)" || gline=""
  if [ -n "${gline//[[:space:]]/}" ]; then printf 'text\n'; else printf 'ghost\n'; fi
}
