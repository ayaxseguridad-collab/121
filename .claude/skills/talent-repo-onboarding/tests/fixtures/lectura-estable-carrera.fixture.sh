#!/usr/bin/env bash
# CASO: exit 0 (PASS) — carrera nuevo → VIEJO → nuevo en A2 y A2b EN VIVO (rojo F4 del ensayo 174d).
# f4-proteccion ya leyó «nuevo» (la primera ficha, la lee el fixture); el verificador cae después en la réplica
# vieja. Con la lectura estable sale VERDE, y la cuenta se reinicia tras cada «viejo»:
#   protección: viejo · nuevo nuevo nuevo                → 4 lecturas del verificador;
#   ajustes:    viejo · nuevo · viejo · nuevo nuevo nuevo → 6 (la racha de 1 se pierde con el segundo viejo).
# Una lectura única (el código anterior) se queda con «viejo» y sale ROJA.
# shellcheck source=tests/fixtures/lectura-estable-base.sh
source "$(dirname "$0")/lectura-estable-base.sh"

secuencia proteccion nuevo viejo nuevo nuevo nuevo
secuencia repo nuevo viejo nuevo viejo nuevo nuevo nuevo
gh_doble api "repos/$TEST_SLUG/branches/main/protection" > /dev/null
gh_doble api "repos/$TEST_SLUG" > /dev/null

correr_vivo
exige "rc=$RC_VIVO (esperado 0)" [ "$RC_VIVO" -eq 0 ]
exige "A2 no quedó en 12/12" contiene 'A2: 12/12 valores correctos'
exige "A2b no quedó en 4/4" contiene 'A2b: 4/4 valores correctos'
exige "protección: $(( $(lecturas proteccion) - 1 )) lecturas del verificador (esperadas 4)" [ "$(lecturas proteccion)" -eq 5 ]
exige "ajustes: $(( $(lecturas repo) - 1 )) lecturas del verificador (esperadas 6: la cuenta se reinicia tras el viejo)" \
  [ "$(lecturas repo)" -eq 7 ]
exige "solo GET (gh api <endpoint>)" no_contiene 'orden no permitida'
exige "esperas reales o sin reloj simulado" sin_esperas_reales
veredicto "nuevo → viejo → nuevo estabiliza en verde y reinicia la cuenta"
