#!/usr/bin/env bash
# probar-verificar.sh — casos rojo/verde unitarios de verificar-prd.sh sobre fixtures
# construidos al vuelo. Cada caso negativo comprueba veredicto Y MOTIVO: un rojo por
# la razon equivocada es un falso verde disfrazado.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
V="$SKILL/scripts/verificar-prd.sh"
CORPUS="$HERE/corpus-fake"
PASA=0; FALLA=0
ok()  { echo "  OK    $*"; PASA=$((PASA+1)); }
mal() { echo "  FALLO $*"; FALLA=$((FALLA+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# guarda anti-falso-verde: sin corpus no hay probador
[ -f "$CORPUS/greenfield/prd.md" ] || { echo "FALLO: corpus-fake ausente" >&2; exit 1; }

# corre <dir> [args...] — captura SALIDA y RC sin abortar
corre() { set +e; SALIDA="$(bash "$V" "$@" 2>&1)"; RC=$?; set -e; }

# caso <nombre> <rc-esperado> <fragmento-que-debe-aparecer>
caso() {
  local nombre="$1" rc_esp="$2" frag="$3"
  if [ "$RC" -ne "$rc_esp" ]; then
    mal "$nombre — rc=$RC, se esperaba $rc_esp"; printf '%s\n' "$SALIDA" | sed 's/^/      | /' | head -8
  elif [ "$frag" != "-" ] && ! printf '%s' "$SALIDA" | grep -qF -- "$frag"; then
    mal "$nombre — rc correcto pero sin el motivo esperado ('$frag')"
    printf '%s\n' "$SALIDA" | sed 's/^/      | /' | head -8
  else
    ok "$nombre"
  fi
}

echo "==== probar-verificar: rojo/verde de verificar-prd.sh ===="

# --- verdes sobre el corpus real ------------------------------------------------------
corre "$CORPUS/greenfield";  caso "verde greenfield (prd+wayfinder+backlog)" 0 "PASA=6 FALLA=0"
corre "$CORPUS/brownfield" --codigo "$CORPUS/brownfield"
caso "verde brownfield con as-is contra codigo" 0 "rutas citadas existen"

# --- rojos construidos por mutacion ---------------------------------------------------
m() { rm -rf "$T/m"; cp -r "$CORPUS/greenfield" "$T/m"; }

m; sed -i '1s/.*/<!-- prd: estado=VIGENTE version=1.0 supersedes=- appetite=lite -->/' "$T/m/prd.md"
corre "$T/m"; caso "cabecera con estado invalido -> ROJO" 1 "cabecera"

m; sed -i 's/^## 7\. No-gos$/## Nogos sueltos/' "$T/m/prd.md"
corre "$T/m"; caso "H2 sin numerar -> ROJO" 1 "H2 sin numerar"

m; sed -i 's/^## 7\. No-gos$/## 9. No-gos/' "$T/m/prd.md"
corre "$T/m"; caso "numeracion con salto -> ROJO" 1 "no consecutiva"

m; sed -i '/^- PASA si:/d' "$T/m/prd.md"
corre "$T/m"; caso "sin criterio PASA -> ROJO" 1 "PASA si"

# los fences no cuentan: un heading falso dentro de un ejemplo no rompe la numeracion...
m; printf '\n```text\n## 99. Heading falso de ejemplo\n```\n' >> "$T/m/prd.md"
corre "$T/m"; caso "heading dentro de fence -> ignorado, sigue VERDE" 0 "numeracion consecutiva"

# ...y un criterio de ejemplo dentro de un fence no satisface el check real
m; sed -i '/^- PASA si:/d' "$T/m/prd.md"; printf '\n```text\n- PASA si: esto es un ejemplo\n```\n' >> "$T/m/prd.md"
corre "$T/m"; caso "criterio PASA solo dentro de fence -> ROJO igualmente" 1 "los ejemplos en fences no cuentan"

m; sed -i 's/^tipo: grilling$/tipo: corazonada/' "$T/m/wayfinder/frecuencia-variable.md"
corre "$T/m"; caso "ficha wayfinder con tipo invalido -> ROJO" 1 "tipo invalido"

m; sed -i 's/^bloqueos: \[\]$/bloqueos: [motor-de-avisos]/' "$T/m/wayfinder/frecuencia-variable.md"
corre "$T/m"; caso "bloqueos como lista con elementos -> VERDE" 0 "wayfinder consistente"

m; sed -i 's/^bloqueos: \[\]$/bloqueos: -/' "$T/m/wayfinder/frecuencia-variable.md"
corre "$T/m"; caso "bloqueos como escalar '-' (no lista YAML) -> ROJO" 1 "bloqueos debe ser lista"

m; rm "$T/m/wayfinder/motor-de-avisos.md"
corre "$T/m"; caso "indice apunta a ficha ausente -> ROJO" 1 "ficha ausente"

m; printf -- '- [fantasma-x](fantasma-x.md) — task — abierta — bloquea §1\n' >> "$T/m/wayfinder/INDICE.md"
corre "$T/m"; caso "entrada de indice sin ficha -> ROJO" 1 "ficha ausente: fantasma-x.md"

m; printf -- '- [externa](../externa.md) — task — abierta — bloquea §1\n' >> "$T/m/wayfinder/INDICE.md"
corre "$T/m"; caso "indice enlazando fuera del wayfinder -> ROJO sin resolver" 1 "enlaza fuera del directorio"

m; sed -i 's/^decision: frecuencia-variable$/decision: otra-cosa/' "$T/m/wayfinder/frecuencia-variable.md"
corre "$T/m"; caso "ficha con decision distinta del nombre del fichero -> ROJO" 1 "no coincide con el nombre"

m; sed -i '1d' "$T/m/wayfinder/frecuencia-variable.md"
corre "$T/m"; caso "ficha sin frontmatter delimitado -> ROJO" 1 "la linea 1 no es"

m; sed -i '6s/^---$/./' "$T/m/wayfinder/frecuencia-variable.md"
corre "$T/m"; caso "ficha con frontmatter sin cierre -> ROJO" 1 "sin '---' de cierre"

m; echo 'contenido externo' > "$T/fuera.md"; ln -s "$T/fuera.md" "$T/m/wayfinder/atajo.md"
printf -- '- [atajo](atajo.md) — task — abierta — bloquea §1\n' >> "$T/m/wayfinder/INDICE.md"
corre "$T/m"; caso "indice apuntando a un symlink -> ROJO" 1 "apunta a un symlink"

m; cat > "$T/m/wayfinder/huerfana.md" <<'EOF'
---
decision: huerfana
tipo: task
estado: abierta
bloqueos: -
---
# Ficha fuera del indice
EOF
corre "$T/m"; caso "ficha fuera del indice -> ROJO" 1 "sin entrada en el indice: huerfana.md"

m; sed -i '/^DoD: cierra/d' "$T/m/backlog.md"
corre "$T/m"; caso "issue de backlog sin DoD -> ROJO" 1 "falta DoD"

m; sed -i 's/^Surfaced by §8$//' "$T/m/backlog.md"
corre "$T/m"; caso "issue sin Surfaced by -> ROJO" 1 "falta Surfaced by"

# --- as-is: la ruta citada no existe --------------------------------------------------
rm -rf "$T/b"; cp -r "$CORPUS/brownfield" "$T/b"; rm "$T/b/codigo/exportar.sh"
corre "$T/b" --codigo "$T/b"
caso "as-is citando ruta borrada -> ROJO" 1 "ruta citada inexistente"

# --- as-is: un componente .. no puede escapar del repo --------------------------------
rm -rf "$T/b2"; cp -r "$CORPUS/brownfield" "$T/b2"
sed -i 's|`codigo/exportar.sh`|`../fuera-del-repo.txt`|' "$T/b2/prd.md"
corre "$T/b2" --codigo "$T/b2"
caso "as-is citando ruta con .. -> ROJO sin resolverla" 1 "componente .. prohibida"

# --- as-is: un fichero citado en la RAIZ del repo (sin '/') tambien se verifica -------
rm -rf "$T/b3"; cp -r "$CORPUS/brownfield" "$T/b3"
sed -i 's|`codigo/exportar.sh`|`prd.md`|' "$T/b3/prd.md"
corre "$T/b3" --codigo "$T/b3"
caso "as-is citando fichero de raiz sin barra -> VERDE (el extractor no exige '/')" 0 "rutas citadas existen"

# --- precondiciones -------------------------------------------------------------------
corre "$T/no-existe"; caso "dir inexistente -> rc 2" 2 "no existe"
rm -rf "$T/vacio"; mkdir -p "$T/vacio"
corre "$T/vacio"; caso "dir sin prd.md -> ROJO" 1 "prd.md — ausente"

echo "---- resultado: PASA=$PASA FALLA=$FALLA ----"
[ "$FALLA" -eq 0 ]
