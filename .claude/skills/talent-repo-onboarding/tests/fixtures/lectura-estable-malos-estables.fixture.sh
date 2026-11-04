#!/usr/bin/env bash
# CASO: exit 1 (FAIL) — valores MALOS y ESTABLES en A2 y A2b EN VIVO: la lectura estable no ablanda nada.
# Ninguna lectura coincide con lo exigido; al llegar al tope (60 s de reloj simulado = 13 lecturas, una cada
# 5 s) cada bloque falla con el motivo claro, y las comprobaciones de siempre fallan sobre la última respuesta.
# shellcheck source=tests/fixtures/lectura-estable-base.sh
source "$(dirname "$0")/lectura-estable-base.sh"

secuencia proteccion viejo
secuencia repo viejo

correr_vivo
exige "rc=$RC_VIVO (esperado 1)" [ "$RC_VIVO" -eq 1 ]
exige "protección: $(lecturas proteccion) lecturas (esperadas 13, el tope)" [ "$(lecturas proteccion)" -eq 13 ]
exige "ajustes: $(lecturas repo) lecturas (esperadas 13, el tope)" [ "$(lecturas repo)" -eq 13 ]
exige "falta el FAIL de lectura sin estabilizar de A2" contiene 'A2: lectura de GitHub sin estabilizar en el tope'
exige "falta el FAIL de lectura sin estabilizar de A2b" contiene 'A2b: lectura de GitHub sin estabilizar en el tope'
exige "falta el motivo con el endpoint de A2b" contiene "sin estabilizar en lo pedido: repos/$TEST_SLUG;"
exige "falta el motivo con el tope" contiene '13 lecturas y 60 s (tope 60 s)'
exige "falta la indicación de repetir la fase" contiene 'puede repetir la fase'
exige "A2(3/12) no evalúa la última respuesta" contiene "A2(3/12): enforce_admins='true' (esperado false)"
exige "A2b(2/4) no evalúa la última respuesta" contiene "A2b(2/4): allow_merge_commit='false' (esperado true)"
exige "A2b(4/4) no evalúa la última respuesta" contiene "A2b(4/4): delete_branch_on_merge='true' (esperado false)"
exige "esperas reales o sin reloj simulado" sin_esperas_reales
veredicto "valores malos y estables fallan en el tope, sin bucle y con motivo claro"
