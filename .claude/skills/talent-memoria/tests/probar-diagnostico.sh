#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A&&ok||mal: ok()/mal() nunca fallan (printf+contador); comillas simples deliberadas (patrones literales)
# probar-diagnostico.sh — prueba DINAMICA y hermetica de que el diagnostico es
# solo-lectura: HOME temporal + canarios, comparacion antes/despues de lista de
# ficheros + hashes de TODO el arbol. Ademas: los hallazgos sembrados aparecen
# (casos-diagnostico.tsv) y la autodeteccion falla cerrado sin corpus.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
# shellcheck source=/dev/null
. "$SKILL/scripts/lib.sh"
PASA=0; FALLA=0
ok()   { echo "  OK    $*"; PASA=$((PASA+1)); }
mal()  { echo "  FALLO $*"; FALLA=$((FALLA+1)); }

echo "==== probar-diagnostico: hermetico + hallazgos + fail-closed ===="

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/data"
cp -r "$HERE/corpus-fake" "$T/data/corpus"
printf 'canario fuera del corpus\n' > "$T/data/canario.txt"
printf 'canario en el home\n' > "$T/home/canario-home.txt"

# foto ANTES: lista de ficheros + hash de todo el arbol hermetico
antes_lista="$(find "$T" -type f | sort)"
antes_hash="$( find "$T" -type f -print0 | sort -z | while IFS= read -r -d '' f; do tm_sha "$f"; done )"

# ejecutar el diagnostico con HOME secuestrado, capturando salida
SALIDA="$(cd "$T" && HOME="$T/home" bash "$SKILL/scripts/diagnostico.sh" "$T/data/corpus" 2>&1)"

# foto DESPUES
despues_lista="$(find "$T" -type f | sort)"
despues_hash="$( find "$T" -type f -print0 | sort -z | while IFS= read -r -d '' f; do tm_sha "$f"; done )"

[ "$antes_lista" = "$despues_lista" ] && ok "lista de ficheros identica (no creo ni borro nada)" || mal "la lista de ficheros CAMBIO"
[ "$antes_hash" = "$despues_hash" ]   && ok "hashes identicos (no modifico nada, canarios incluidos)" || mal "algun hash CAMBIO"

# hallazgos sembrados: cada fila de casos-diagnostico.tsv debe aparecer en la salida
while IFS=$'\t' read -r casonombre patron; do
  [ -z "$casonombre" ] && continue
  case "$casonombre" in \#*) continue;; esac
  if printf '%s' "$SALIDA" | grep -qF -- "$patron"; then
    ok "hallazgo '$casonombre' detectado"
  else
    mal "hallazgo '$casonombre' NO aparece (esperaba: $patron)"
  fi
done < "$HERE/casos-diagnostico.tsv"

# el reporte no vuelca contenido de notas (solo metricas y nombres)
if printf '%s' "$SALIDA" | grep -qF -- "merge los viernes"; then
  mal "el reporte vuelca contenido de una nota (privacidad)"
else
  ok "el reporte no vuelca contenido de notas"
fi

# autodeteccion fail-closed: sin corpus → exit 1 y mensaje accionable
mkdir -p "$T/vacio"
set +e
SAL2="$(cd "$T/vacio" && HOME="$T/home" bash "$SKILL/scripts/diagnostico.sh" 2>&1)"; RC2=$?
set -e
if [ "$RC2" -eq 1 ] && printf '%s' "$SAL2" | grep -qF "No encuentro un corpus"; then
  ok "autodeteccion fail-closed (exit 1 + pide la ruta)"
else
  mal "autodeteccion no fallo cerrado (rc=$RC2)"
fi

# symlink en el corpus (item 6) → exit 2 fail-closed. Antes del fix, un symlink
# no entraba en el censo (find -type f no lo inventaria) y podia retargetearse
# sin dejar delta; ahora diagnostico.sh falla cerrado como verificar.sh/salvaguarda.sh.
mkdir -p "$T/con-symlink"
cp -r "$HERE/corpus-fake" "$T/con-symlink/corpus"
if ln -s /etc/hostname "$T/con-symlink/corpus/enlace.md" 2>/dev/null; then
  set +e
  SAL3="$(bash "$SKILL/scripts/diagnostico.sh" "$T/con-symlink/corpus" 2>&1)"; RC3=$?
  set -e
  if [ "$RC3" -eq 2 ] && printf '%s' "$SAL3" | grep -qF "symlinks no soportados"; then
    ok "symlink en el corpus → diagnostico.sh exit 2 (fail-closed)"
  else
    mal "symlink NO rechazado (rc=$RC3)"
  fi
else
  echo "  OMIT  symlink en el corpus (ln no disponible)"
fi

# defensa secundaria: cero primitivas de escritura sobre el corpus en el codigo
if grep -nE '(^|[^>])>>?[[:space:]]*"?\$CORPUS' "$SKILL/scripts/diagnostico.sh" | grep -v '^\s*#' | grep -q .; then
  mal "diagnostico.sh contiene redirecciones de escritura hacia el corpus"
else
  ok "cero redirecciones de escritura hacia el corpus (defensa secundaria)"
fi

echo "---- resultado: PASA=$PASA FALLA=$FALLA ----"
[ "$FALLA" -eq 0 ]
