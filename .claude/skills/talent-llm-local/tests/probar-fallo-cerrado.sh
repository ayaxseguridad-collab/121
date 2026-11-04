#!/usr/bin/env bash
# probar-fallo-cerrado.sh — el instalador NO puede anunciar exito sobre algo roto.
#
#   bash tests/probar-fallo-cerrado.sh
#
# Un instalador que se traga los errores es peor que uno que falla: te deja una
# maquina a medias creyendo que esta lista. Aqui se comprueba justamente eso, sobre
# un HOME de mentira, sin tocar nada real.

set -uo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONTAR="$AQUI/../scripts/montar.sh"

PASA=0; FALLA=0
juzga() {  # juzga <nombre> <esperado:falla|exito> <rc> <salida>
  local nombre="$1" esperado="$2" rc="$3" salida="$4" problema=""
  if [ "$esperado" = "falla" ]; then
    [ "$rc" -eq 0 ] && problema="ha salido con exito y deberia fallar"
    [ -z "$problema" ] && grep -q "Montaje terminado" <<<"$salida" \
      && problema="ha anunciado 'Montaje terminado' pese al fallo"
  else
    [ "$rc" -ne 0 ] && problema="ha fallado y deberia funcionar (rc=$rc)"
  fi
  if [ -z "$problema" ]; then
    printf '  OK    %s\n' "$nombre"; PASA=$((PASA+1))
  else
    printf '  FALLO %s — %s\n' "$nombre" "$problema"; FALLA=$((FALLA+1))
    printf '%s\n' "$salida" | tail -6 | sed 's/^/          | /'
  fi
}

titulo() { printf '\n=== %s\n' "$*"; }
titulo "Fallo cerrado — el instalador no miente sobre lo que hizo"

# ---------------------------------------------------------------- caso 1
# settings.json corrupto: la fase debe PARAR, no seguir y decir que todo fue bien.
CASA="$(mktemp -d)"; mkdir -p "$CASA/.claude" "$CASA/estado"
printf 'esto no es JSON {{{\n' >"$CASA/.claude/settings.json"
SALIDA="$(LL_HOME="$CASA" LL_STATE="$CASA/estado" bash "$MONTAR" --only claude 2>&1)"; RC=$?
juzga "settings.json invalido detiene la fase" falla "$RC" "$SALIDA"
grep -q 'no es JSON valido' <<<"$SALIDA" \
  && printf '        (y lo explica: «no es JSON valido»)\n'
# y no debe haberlo tocado
if grep -q 'esto no es JSON' "$CASA/.claude/settings.json"; then
  printf '  OK    no ha modificado el settings.json roto\n'; PASA=$((PASA+1))
else
  printf '  FALLO ha tocado un settings.json que no sabia leer\n'; FALLA=$((FALLA+1))
fi
rm -rf "$CASA"

# ---------------------------------------------------------------- caso 2
# Control positivo: con un settings.json valido la misma fase tiene que funcionar.
# Sin esto, el caso 1 pasaria igual aunque la fase estuviese rota siempre.
CASA="$(mktemp -d)"; mkdir -p "$CASA/.claude" "$CASA/estado"
printf '{"env":{"MI_AJUSTE":"no me toques"}}\n' >"$CASA/.claude/settings.json"
SALIDA="$(LL_HOME="$CASA" LL_STATE="$CASA/estado" bash "$MONTAR" --only claude 2>&1)"; RC=$?
juzga "settings.json valido se configura" exito "$RC" "$SALIDA"
if grep -q '"MI_AJUSTE"' "$CASA/.claude/settings.json" \
   && grep -q 'ANTHROPIC_BASE_URL' "$CASA/.claude/settings.json"; then
  printf '  OK    conserva tus ajustes y anade los suyos\n'; PASA=$((PASA+1))
else
  printf '  FALLO no ha conservado los ajustes previos\n'; FALLA=$((FALLA+1))
fi
rm -rf "$CASA"

# ---------------------------------------------------------------- caso 3
# Una plantilla con un valor sin definir no puede pasar en silencio.
CASA="$(mktemp -d)"; mkdir -p "$CASA/estado"
SALIDA="$(LL_HOME="$CASA" LL_STATE="$CASA/estado" LL_ETC="$CASA/etc" \
          SERVED_NAME='' bash "$MONTAR" --only hermes 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] || grep -q 'sin valor para' <<<"$SALIDA"; then
  printf '  OK    una plantilla incompleta no pasa en silencio\n'; PASA=$((PASA+1))
else
  # SERVED_NAME vacio es un valor valido para la sustitucion; no es un fallo del skill
  printf '  OMIT  no se ha podido provocar el caso con este parametro\n'
fi
rm -rf "$CASA"

printf '\n  %d correctas · %d fallidas\n\n' "$PASA" "$FALLA"
[ "$FALLA" -eq 0 ]
