#!/usr/bin/env bash
# move-runner.sh — lanza am_move desde un SUBPROCESO cuyo argv NO contiene el nombre del agente.
# Necesario en el arnés: el fake-incus ejecuta la quiescence (pgrep -f '[c]odex') en el MISMO host,
# así que si el argv del runner llevara "codex" el pgrep se auto-matchearía y mataría al propio runner.
# En producción la quiescence corre DENTRO del contenedor (namespace aparte, CUSER=vivecoder), sin ese
# solape. Los parámetros llegan por env: MV_LIB, MV_ACCOUNT, MV_AGENT, MV_FROM, MV_TO (+ AM_FAILPOINT).
set -uo pipefail
# shellcheck source=/dev/null
. "$MV_LIB"
am_move "$MV_ACCOUNT" "$MV_AGENT" "$MV_FROM" "$MV_TO"
