#!/usr/bin/env bash
# CASO: exit 2 (ERROR) — gh falla en A2b EN VIVO: sigue siendo ERROR, con la salida de gh, y no se reintenta.
# shellcheck source=tests/fixtures/lectura-estable-base.sh
source "$(dirname "$0")/lectura-estable-base.sh"

secuencia proteccion nuevo
secuencia repo fallo

correr_vivo
exige "rc=$RC_VIVO (esperado 2)" [ "$RC_VIVO" -eq 2 ]
exige "falta el ERROR de gh en A2b" contiene "A2b: gh api repos/$TEST_SLUG falló: gh: Not Found (HTTP 404)"
exige "ajustes: $(lecturas repo) lecturas (esperada 1: el error de gh no se reintenta)" [ "$(lecturas repo)" -eq 1 ]
exige "A2 no quedó en 12/12" contiene 'A2: 12/12 valores correctos'
veredicto "error de gh sigue siendo ERROR"
