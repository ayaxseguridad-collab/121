#!/usr/bin/env bash
# CASO: exit 3 (MANUAL-PENDING) — A2 EN VIVO con «Upgrade to GitHub Pro»: se conserva el PENDING procedural.
# El error de gh no se reintenta (una sola lectura) y A2b, estable en lo pedido, pasa.
# shellcheck source=tests/fixtures/lectura-estable-base.sh
source "$(dirname "$0")/lectura-estable-base.sh"

secuencia proteccion pro
secuencia repo nuevo

correr_vivo
exige "rc=$RC_VIVO (esperado 3)" [ "$RC_VIVO" -eq 3 ]
exige "falta el PENDING de plan FREE" contiene 'A2: plan FREE — protección no enforced vía API (procedural, exit 3)'
exige "protección: $(lecturas proteccion) lecturas (esperada 1: el error de gh no se reintenta)" \
  [ "$(lecturas proteccion)" -eq 1 ]
exige "ajustes: $(lecturas repo) lecturas (esperadas 3)" [ "$(lecturas repo)" -eq 3 ]
exige "A2b no quedó en 4/4" contiene 'A2b: 4/4 valores correctos'
veredicto "Upgrade to GitHub Pro sigue en PENDING"
