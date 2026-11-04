#!/usr/bin/env bash
# fake-codex.sh / fake-claude.sh — shim del agente para el arnés (TAL-2294).
# Comportamiento controlado por env:
#   FAKE_AGENT_RC    (default 0) rc a devolver.
#   FAKE_AGENT_SLEEP (default 0) segundos a dormir (para probar el timeout duro del one-shot).
# Simula 'codex exec …' / 'claude -p …'. No hace nada real.
set -uo pipefail
s="${FAKE_AGENT_SLEEP:-0}"; [ "$s" -gt 0 ] 2>/dev/null && sleep "$s"
exit "${FAKE_AGENT_RC:-0}"
