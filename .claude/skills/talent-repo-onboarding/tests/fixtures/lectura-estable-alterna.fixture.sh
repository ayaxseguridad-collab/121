#!/usr/bin/env bash
# CASO: exit 1 (FAIL) — GitHub ALTERNA sin parar entre la réplica nueva y la vieja, en A2 y A2b EN VIVO.
# Nunca hay 3 lecturas seguidas iguales a lo pedido: cada «viejo» pone la cuenta a cero. Al tope (13 lecturas,
# 60 s de reloj simulado) los dos bloques fallan con el motivo claro y SIN bucle infinito (el doble corta en
# 200 lecturas con rc 92). A2b falla aunque su última respuesta sea la buena: sin estabilizar no hay verde.
# shellcheck source=tests/fixtures/lectura-estable-base.sh
source "$(dirname "$0")/lectura-estable-base.sh"

alterna proteccion viejo nuevo
alterna repo nuevo viejo

correr_vivo
exige "rc=$RC_VIVO (esperado 1)" [ "$RC_VIVO" -eq 1 ]
exige "protección: $(lecturas proteccion) lecturas (esperadas 13, el tope)" [ "$(lecturas proteccion)" -eq 13 ]
exige "ajustes: $(lecturas repo) lecturas (esperadas 13, el tope)" [ "$(lecturas repo)" -eq 13 ]
exige "bucle sin tope" no_contiene 'bucle sin tope'
exige "falta el FAIL de lectura sin estabilizar de A2" contiene 'A2: lectura de GitHub sin estabilizar en el tope'
exige "falta el FAIL de lectura sin estabilizar de A2b" contiene 'A2b: lectura de GitHub sin estabilizar en el tope'
exige "falta el motivo con el endpoint de A2" \
  contiene "sin estabilizar en lo pedido: repos/$TEST_SLUG/branches/main/protection;"
exige "falta la racha: 1 de 3" contiene 'la racha más larga fue de 1 de 3 lecturas seguidas iguales a lo pedido'
exige "falta la indicación de repetir la fase" contiene 'puede repetir la fase'
exige "A2b no evaluó la última respuesta (la buena)" contiene 'A2b: 4/4 valores correctos'
exige "esperas reales o sin reloj simulado" sin_esperas_reales
veredicto "alternancia sin fin falla en el tope, sin bucle infinito y con motivo claro"
