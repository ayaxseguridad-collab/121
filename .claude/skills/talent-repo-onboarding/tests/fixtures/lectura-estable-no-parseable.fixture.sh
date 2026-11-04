#!/usr/bin/env bash
# CASO: exit 1 (FAIL) — respuesta no JSON en A2b EN VIVO: se evalúa tal cual (FAIL, como antes) y no se reintenta.
# shellcheck source=tests/fixtures/lectura-estable-base.sh
source "$(dirname "$0")/lectura-estable-base.sh"

secuencia proteccion nuevo
secuencia repo roto

correr_vivo
exige "rc=$RC_VIVO (esperado 1)" [ "$RC_VIVO" -eq 1 ]
exige "falta el FAIL de respuesta no parseable" contiene 'A2b: respuesta de GitHub no parseable; se evalúa tal cual'
exige "falta el FAIL de A2b(1/4) sobre la respuesta" contiene "A2b(1/4): allow_squash_merge='' (esperado true)"
exige "ajustes: $(lecturas repo) lecturas (esperada 1: no se reintenta)" [ "$(lecturas repo)" -eq 1 ]
veredicto "respuesta no parseable sigue siendo FAIL"
