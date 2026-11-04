#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A&&ok||mal: ok()/mal() nunca fallan (printf+contador); comillas simples deliberadas (patrones literales)
# probar-verificar.sh — 52 casos rojo/verde del verificador (medido, no estimado):
# mundo cerrado, marca de anulacion ESTRUCTURAL (bloque completo + fecha valida
# y delimitada), h_antes por ruta exacta, altas declaradas + anti-circularidad,
# semantico:indice anclado, S3 estricto + asserts de gramatica (exit 2). Cada
# caso comprueba veredicto Y motivo.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
PASA=0; FALLA=0

# prepara un escenario: corpus copiado + salvaguarda. Deja CORPUS/SNAP/W globales.
prepara() {
  W="$(mktemp -d)"; CORPUS="$W/corpus"; SNAP="$W/snap"
  cp -r "$HERE/corpus-fake" "$CORPUS"
  bash "$SKILL/scripts/salvaguarda.sh" "$CORPUS" "$SNAP" >/dev/null
}
# corre el verificador capturando salida y rc (sin abortar el probador)
corre() { set +e; SALIDA="$(bash "$SKILL/scripts/verificar.sh" "$SNAP" "$CORPUS" "$1" 2>&1)"; RC=$?; set -e; }
caso() { # caso <nombre> <rc-esperado> <grep-que-debe-estar> [grep-que-NO-debe-estar]
  local nombre="$1" rc_esp="$2" debe="$3" nodebe="${4:-}"
  local ok=1
  [ "$RC" -eq "$rc_esp" ] || { echo "  FALLO [$nombre] rc=$RC (esperaba $rc_esp)"; ok=0; }
  printf '%s' "$SALIDA" | grep -qF -- "$debe" || { echo "  FALLO [$nombre] falta motivo: $debe"; ok=0; }
  if [ -n "$nodebe" ]; then
    printf '%s' "$SALIDA" | grep -qF -- "$nodebe" && { echo "  FALLO [$nombre] aparece lo que no debe: $nodebe"; ok=0; }
  fi
  if [ "$ok" -eq 1 ]; then echo "  OK    [$nombre]"; PASA=$((PASA+1)); else FALLA=$((FALLA+1)); printf '%s\n' "$SALIDA" | sed 's/^/      | /' | head -12; fi
  rm -rf "$W"
}

echo "==== probar-verificar: 52 casos + gramatica ===="

# 1. intacto: nada cambia, fila intacto → VERDE
prepara
printf 'decision-gestor-paquetes.md\tintacto\t-\n' > "$W/c.tsv"
corre "$W/c.tsv"; caso "1 intacto" 0 "intacto 'decision-gestor-paquetes.md' (hash identico)"

# 2. adicion exacta → VERDE
prepara
printf 'Anexo 2026-07-27: el flag --offline vive en package.json.\n' > "$W/bloque.txt"
cat "$W/bloque.txt" >> "$CORPUS/gotcha-tests-flaky-red.md"
printf 'gotcha-tests-flaky-red.md\tsolo-adicion\t%s\n' "$W/bloque.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "2 adicion exacta" 0 "lo anadido == bloque declarado"

# 3. eliminacion encubierta → ROJO S5
prepara
printf 'x\n' > "$W/bloque.txt"
grep -v 'workspaces' "$CORPUS/decision-gestor-paquetes.md" > "$W/tmp" && mv "$W/tmp" "$CORPUS/decision-gestor-paquetes.md"
printf 'decision-gestor-paquetes.md\tsolo-adicion\t%s\n' "$W/bloque.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "3 eliminacion" 1 "lineas ELIMINADAS (S5)"

# 4. sustitucion → ROJO S5 (una sustitucion = borrar + anadir; el diff ve el borrado)
prepara
printf 'linea nueva\n' > "$W/bloque.txt"
sed -i.bak 's/pnpm por los workspaces/otro motivo distinto/' "$CORPUS/decision-gestor-paquetes.md" && rm -f "$CORPUS/decision-gestor-paquetes.md.bak"
printf 'decision-gestor-paquetes.md\tsolo-adicion\t%s\n' "$W/bloque.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "4 sustitucion" 1 "lineas ELIMINADAS (S5)"

# 5. adicion extra no declarada dentro del fichero → ROJO S5
prepara
printf 'Anexo declarado.\n' > "$W/bloque.txt"
cat "$W/bloque.txt" >> "$CORPUS/gotcha-tests-flaky-red.md"
printf 'linea de mas que nadie declaro\n' >> "$CORPUS/gotcha-tests-flaky-red.md"
printf 'gotcha-tests-flaky-red.md\tsolo-adicion\t%s\n' "$W/bloque.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "5 adicion extra" 1 "NO coincide con el bloque declarado"

# 6. indice con el one-liner viejo AUN presente → ROJO S6
prepara
printf -- '- [Indentacion](formato-indentacion-espacios.md) — 2 espacios (jul-2026)\n' > "$W/bloque.txt"
cat "$W/bloque.txt" >> "$CORPUS/MEMORY.md"   # anade el nuevo SIN quitar el viejo
{ printf 'MEMORY.md\tsolo-adicion\t%s\n' "$W/bloque.txt"
  printf 'INDEX\t- [Indentacion](formato-indentacion-espacios.md) — 2 espacios (jul-2026)\t- [Indentacion](formato-indentacion-tabs.md) — tabs siempre\n'; } > "$W/c.tsv"
corre "$W/c.tsv"; caso "6 indice viejo presente" 1 "el one-liner viejo SIGUE en el indice"

# 6b. el one-liner nuevo CITA al viejo como subcadena (alias-stub/reencuadre) y el
#     viejo esta ELIMINADO → VERDE (regresion: sin excluir la linea del nuevo, el
#     check S6 fallaba en falso sobre el patron central del skill)
prepara
VIEJO='- [Indentacion](formato-indentacion-tabs.md) — tabs siempre'
NUEVO='- [Indentacion](formato-indentacion-espacios.md) — 2 espacios; supersede a: - [Indentacion](formato-indentacion-tabs.md) — tabs siempre'
grep -F -x -v -- "$VIEJO" "$CORPUS/MEMORY.md" > "$W/mem.tmp"
printf '%s\n' "$NUEVO" >> "$W/mem.tmp"
mv "$W/mem.tmp" "$CORPUS/MEMORY.md"
{ printf 'MEMORY.md\tsemantico:indice\t-\n'
  printf 'INDEX\t%s\t%s\n' "$NUEVO" "$VIEJO"; } > "$W/c.tsv"
corre "$W/c.tsv"; caso "6b indice: nuevo cita al viejo, viejo eliminado" 0 "S6 indice: nuevo presente, viejo ausente"

# 6c. indice GRANDE con el viejo AUN presente (temprano) → ROJO (regresion SIGPIPE:
# con `| grep -q` bajo pipefail, el -q cerraba el pipe al primer match y el 141
# del grep -v caia al tm_ok — falso PASS exactamente cuando el viejo seguia vivo)
prepara
NUEVO='- [Indentacion](formato-indentacion-espacios.md) — 2 espacios (jul-2026)'
VIEJO='- [Indentacion](formato-indentacion-tabs.md) — tabs siempre'
# el viejo va AL PRINCIPIO y el relleno DESPUES: el -q mutante encuentra el match
# temprano, cierra el pipe, y el grep -v aun escribiendo recibe SIGPIPE → 141
{ printf '%s\n' "$NUEVO"; printf '%s\n' "$VIEJO"; seq 1 200000 | sed 's/^/- [Relleno] linea /'; } > "$CORPUS/MEMORY.md"
{ printf 'MEMORY.md\tsemantico:indice\t-\n'
  printf 'INDEX\t%s\t%s\n' "$NUEVO" "$VIEJO"; } > "$W/c.tsv"
corre "$W/c.tsv"; caso "6c indice grande: viejo temprano SIGUE → ROJO (anti-SIGPIPE)" 1 "el one-liner viejo SIGUE en el indice"

# 7. error de diff (fichero ilegible) → ROJO con rc de diff
prepara
printf 'x\n' > "$W/bloque.txt"
printf 'y\n' >> "$CORPUS/decision-gestor-paquetes.md"
chmod 000 "$CORPUS/decision-gestor-paquetes.md"
printf 'decision-gestor-paquetes.md\tsolo-adicion\t%s\n' "$W/bloque.txt" > "$W/c.tsv"
if [ "$(id -u)" -eq 0 ]; then
  echo "  OMIT  [7 error de diff] (root lee ficheros 000)"; rm -rf "$W"
else
  corre "$W/c.tsv"; chmod 644 "$CORPUS/decision-gestor-paquetes.md" 2>/dev/null || true
  caso "7 error de diff" 1 "error"
fi

# 8. fichero extra modificado NO declarado → ROJO mundo cerrado con el path
prepara
printf 'Anexo declarado.\n' > "$W/bloque.txt"
cat "$W/bloque.txt" >> "$CORPUS/gotcha-tests-flaky-red.md"
printf 'toque furtivo\n' >> "$CORPUS/preferencia-editor.md"
printf 'gotcha-tests-flaky-red.md\tsolo-adicion\t%s\n' "$W/bloque.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "8 mundo cerrado" 1 "mundo cerrado: 'preferencia-editor.md'"

# 9. MIXTO: un intacto + un modificado legitimo + un extra no declarado
#    → rechaza SOLO el tercero (el intacto y el legitimo dan OK)
prepara
printf 'Anexo legitimo.\n' > "$W/bloque.txt"
cat "$W/bloque.txt" >> "$CORPUS/gotcha-tests-flaky-red.md"
printf 'toque furtivo\n' >> "$CORPUS/preferencia-editor.md"
{ printf 'decision-gestor-paquetes.md\tintacto\t-\n'
  printf 'gotcha-tests-flaky-red.md\tsolo-adicion\t%s\n' "$W/bloque.txt"; } > "$W/c.tsv"
corre "$W/c.tsv"
SALIDA_9="$SALIDA"; RC_9=$RC
ok9=1
[ "$RC_9" -eq 1 ] || ok9=0
printf '%s' "$SALIDA_9" | grep -qF -- "mundo cerrado: 'preferencia-editor.md'" || ok9=0
printf '%s' "$SALIDA_9" | grep -qF -- "OK    intacto 'decision-gestor-paquetes.md'" || ok9=0
printf '%s' "$SALIDA_9" | grep -qF -- "OK    solo-adicion 'gotcha-tests-flaky-red.md'" || ok9=0
[ "$(printf '%s\n' "$SALIDA_9" | grep -c 'FALLO')" -eq 2 ] || ok9=0  # 1 fallo + linea de veredicto
if [ "$ok9" -eq 1 ]; then echo "  OK    [9 mixto: rechaza SOLO el extra]"; PASA=$((PASA+1)); else echo "  FALLO [9 mixto]"; printf '%s\n' "$SALIDA_9" | sed 's/^/      | /'; FALLA=$((FALLA+1)); fi
rm -rf "$W"

# gramatica: 4 columnas → exit 2 · modo invalido → exit 2 · descriptor de intacto != '-' → exit 2
prepara
printf 'a.md\tintacto\t-\tsobra\n' > "$W/c.tsv"
corre "$W/c.tsv"; caso "gramatica 4 columnas" 2 "columnas"
prepara
printf 'a.md\tmodo-inventado\t-\n' > "$W/c.tsv"
corre "$W/c.tsv"; caso "gramatica modo invalido" 2 "modo invalido"
prepara
printf 'a.md\tintacto\talgo.txt\n' > "$W/c.tsv"
corre "$W/c.tsv"; caso "gramatica intacto exige '-'" 2 "exige descriptor '-'"

# fail-closed nuevos: snapshot-dir ambiguo y travesia de rutas → exit 2
prepara
cp "$SNAP"/snapshot-*.tar.gz "$SNAP/snapshot-99990101T000000Z.tar.gz"
printf 'decision-gestor-paquetes.md\tintacto\t-\n' > "$W/c.tsv"
corre "$W/c.tsv"; caso "snapshot-dir ambiguo (2 tars)" 2 "baseline ambiguo"
prepara
printf '../fuera-del-corpus.md\tintacto\t-\n' > "$W/c.tsv"
corre "$W/c.tsv"; caso "ruta con travesia .." 2 "fuera del corpus"
prepara
printf '/etc/passwd\tintacto\t-\n' > "$W/c.tsv"
corre "$W/c.tsv"; caso "ruta absoluta" 2 "fuera del corpus"

# SEMANTICOS EN NEGATIVO (M1 de la auditoria de F3-F5): solo-description NO pasa
# anulacion con estado SOLO en el description (cuerpo sin marca) → ROJO
prepara
printf 'se indenta con tabs, siempre\n' > "$W/frag.txt"
sed -i.bak 's|description: indentamos con tabs|description: "[ANULADA 2026-07-27] → sucesora: formato-indentacion-espacios — tabs"|' "$CORPUS/formato-indentacion-tabs.md" && rm -f "$CORPUS/formato-indentacion-tabs.md.bak"
printf 'formato-indentacion-tabs.md\tsemantico:anulacion\t%s\n' "$W/frag.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "anulacion solo-description" 1 "sin marca de estado EN EL CUERPO"

# alias-stub con marca SOLO en el description → ROJO
prepara
printf 'politica-commits\n' > "$W/suc.txt"
sed -i.bak 's|description: notas sobre commits (parecida a politica-commits)|description: "[ALIAS-STUB 2026-07-27] → sucesora: politica-commits — notas"|' "$CORPUS/politica-commits-notas.md" && rm -f "$CORPUS/politica-commits-notas.md.bak"
printf 'politica-commits-notas.md\tsemantico:alias-stub\t%s\n' "$W/suc.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "alias-stub solo-description" 1 "sin marca ALIAS-STUB en el cuerpo"

# fusion con descriptor VACIO → exit 2 (fail-closed en el parser)
prepara
: > "$W/vacio.txt"
printf 'algo\n' >> "$CORPUS/politica-commits.md"
printf 'politica-commits.md\tsemantico:fusion\t%s\n' "$W/vacio.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "fusion descriptor vacio" 2 "descriptor VACIO"

# POSITIVOS de las 3 categorias (marca corporal correcta → VERDE)
prepara
printf 'se indenta con tabs, siempre\n' > "$W/frag.txt"
cat > "$CORPUS/formato-indentacion-tabs.md" <<'FIX'
---
name: formato-indentacion-tabs
description: "[ANULADA 2026-07-27] → sucesora: formato-indentacion-espacios — pedia tabs"
---
> ANULADA 2026-07-27 — adjudicada por recencia.
> Linea muerta: "se indenta con tabs, siempre"
> Linea vigente: [[formato-indentacion-espacios]]
> Autoridad: decision propia, 27-jul.

2026-05-01. En este proyecto se indenta con tabs, siempre.
FIX
printf 'formato-indentacion-tabs.md\tsemantico:anulacion\t%s\n' "$W/frag.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "anulacion positiva" 0 "marca corporal antes del texto muerto + S3"

# anulacion positiva con etiquetas ACENTUADAS ("Línea muerta:") → VERDE
# (regresion: la clase ERE [ií] bajo LC_ALL=C matchea BYTES, no el codepoint
# multibyte de la í — un bloque legitimo con acentos fallaba en verde ajeno)
prepara
printf 'se indenta con tabs, siempre\n' > "$W/frag.txt"
cat > "$CORPUS/formato-indentacion-tabs.md" <<'FIX'
---
name: formato-indentacion-tabs
description: "[ANULADA 2026-07-27] → sucesora: formato-indentacion-espacios — pedia tabs"
---
> ANULADA 2026-07-27 — adjudicada por recencia.
> Línea muerta: "se indenta con tabs, siempre"
> Línea vigente: [[formato-indentacion-espacios]]
> Autoridad: decision propia, 27-jul.

2026-05-01. En este proyecto se indenta con tabs, siempre.
FIX
printf 'formato-indentacion-tabs.md\tsemantico:anulacion\t%s\n' "$W/frag.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "anulacion acentuada (Línea con tilde)" 0 "marca corporal antes del texto muerto + S3"

prepara
printf 'politica-commits\n' > "$W/suc.txt"
cat > "$CORPUS/politica-commits-notas.md" <<'FIX'
---
name: politica-commits-notas
description: "[ALIAS-STUB 2026-07-27] → sucesora: politica-commits — consolidada"
---
**[ALIAS-STUB 2026-07-27]** Consolidado en [[politica-commits]] (clausula URGENTE migrada).
FIX
printf 'Los commits de hotfix llevan ademas la etiqueta URGENTE en el cuerpo.\n' >> "$CORPUS/politica-commits.md"
printf 'Los commits de hotfix llevan ademas la etiqueta URGENTE en el cuerpo.\n' > "$W/clau.txt"
{ printf 'politica-commits-notas.md\tsemantico:alias-stub\t%s\n' "$W/suc.txt"
  printf 'politica-commits.md\tsemantico:fusion\t%s\n' "$W/clau.txt"; } > "$W/c.tsv"
corre "$W/c.tsv"; caso "alias-stub + fusion positivos" 0 "clausulas preservadas"

# S3 ESTRICTO: estado en OTRO campo (status:) + description SIN estado → ROJO
# (marca corporal correcta: el unico defecto es donde vive el estado del frontmatter)
prepara
printf 'se indenta con tabs, siempre\n' > "$W/frag.txt"
cat > "$CORPUS/formato-indentacion-tabs.md" <<'FIX'
---
name: formato-indentacion-tabs
description: indentamos con tabs
status: ANULADA
---
> ANULADA 2026-07-27 — adjudicada por recencia.
> Linea muerta: "se indenta con tabs, siempre"
> Linea vigente: [[formato-indentacion-espacios]]
> Autoridad: decision propia, 27-jul.

2026-05-01. En este proyecto se indenta con tabs, siempre.
FIX
printf 'formato-indentacion-tabs.md\tsemantico:anulacion\t%s\n' "$W/frag.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "S3 estricto: estado en status:, description limpio" 1 "description sin estado (S3)"

# S3 ESTRICTO (item 3): el estado aparece DE PASADA en el description, no
# abriendolo. Marca corporal correcta (bloque + cita antes del fix del item 4,
# que aun no exige el bloque completo): el UNICO defecto es que el estado no
# esta al inicio del description. Antes del fix daba VERDE (falso positivo);
# ahora debe dar ROJO "description sin estado (S3)".
prepara
printf 'se indenta con tabs, siempre\n' > "$W/frag.txt"
cat > "$CORPUS/formato-indentacion-tabs.md" <<'FIX'
---
name: formato-indentacion-tabs
description: "politica de indentacion vigente; la anterior quedo ANULADA en mayo"
---
> ANULADA 2026-07-27 — adjudicada por recencia.
> Linea muerta: "se indenta con tabs, siempre"
> Linea vigente: [[formato-indentacion-espacios]]
> Autoridad: decision propia, 27-jul.

2026-05-01. En este proyecto se indenta con tabs, siempre.
FIX
printf 'formato-indentacion-tabs.md\tsemantico:anulacion\t%s\n' "$W/frag.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "S3 estricto: estado DE PASADA en description (no abre)" 1 "description sin estado (S3)"

# SYMLINK en el corpus (alta/retarget post-snapshot) → exit 2 fail-closed
prepara
printf 'x\n' > "$W/fuera.txt"
( cd "$CORPUS" && command -v ln >/dev/null && ln -s "$W/fuera.txt" enlace.md ) 2>/dev/null || true
if [ -L "$CORPUS/enlace.md" ]; then
  printf 'decision-gestor-paquetes.md\tintacto\t-\n' > "$W/c.tsv"
  corre "$W/c.tsv"; caso "symlink en corpus" 2 "symlinks no soportados"
else
  echo "  OMIT  [symlink en corpus] (ln no disponible)"; rm -rf "$W"
fi

# DESCRIPTOR con 1a LINEA EN BLANCO → exit 2 fail-closed (NO falso PASS).
# Regresion: `frag="$(head -1 "$desc")"` vacio convierte el `grep -F` de abajo en
# un patron que matchea TODAS las lineas, con lo que el guard del texto muerto
# ausente nunca dispara. El descriptor pasa el guard de "VACIO" porque SI tiene
# un no-blanco... en la linea 2. Aqui el texto muerto NO esta en la nota (fue
# borrado): sin este check el verificador daria VERDE a un borrado append-only.
prepara
printf '\nse indenta con tabs, siempre\n' > "$W/frag.txt"
cat > "$CORPUS/formato-indentacion-tabs.md" <<'DEL'
---
name: formato-indentacion-tabs
description: ANULADA — indentamos con tabs
---
> ANULADA 2026-07-27 — adjudicada por recencia.
> Linea vigente: [[formato-indentacion-espacios]]

2026-05-01. (el texto muerto declarado ya no esta en el cuerpo)
DEL
printf 'formato-indentacion-tabs.md\tsemantico:anulacion\t%s\n' "$W/frag.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "descriptor con 1a linea en blanco" 2 "NO este en blanco"

# semantico:indice sobre una ruta que NO es el indice → exit 2 fail-closed.
# Regresion: antes de este fix, S6 (mas abajo) verifica UNICAMENTE
# $CORPUS/$TM_INDEX_FILE, asi que declarar este modo sobre otro fichero (p. ej.
# preferencia-editor.md) lo marcaba tm_ok sin que NADIE lo comprobara jamas.
prepara
printf 'preferencia-editor.md\tsemantico:indice\t-\n' > "$W/c.tsv"
corre "$W/c.tsv"; caso "semantico:indice sobre ruta que no es el indice" 2 "solo aplica a"

# ============================================================================
# ITEM 4 — marca de anulacion ESTRUCTURAL: la marca es el BLOQUE COMPLETO,
# acotado al estado correcto y con payload correlacionado. 1 positivo + 15
# negativos (16 total).
# ============================================================================

# 4-POS: ACOTADA VERBATIM de references/02 §4 (calificador entre parentesis en
# "Linea muerta" + "Alcance residual" en vez de "Autoridad") → VERDE: el gate
# no debe rechazar lo que la propia documentacion enseña.
prepara
printf 'si el test pasa aislado, es un flake\n' > "$W/frag.txt"
cat > "$CORPUS/formato-indentacion-tabs.md" <<'FIX'
---
name: gotcha-rerun-general
description: "[ACOTADA 2026-07-27] → sucesora: gotcha-rerun-aislado-evidencia-debil — matiz de alcance"
---
> ACOTADA 2026-07-27 — de criterio general a caso particular.
> Linea muerta (como criterio GENERAL): "si el test pasa aislado, es un flake"
> Linea vigente: [[gotcha-rerun-aislado-evidencia-debil]]
> Alcance residual: SOLO para sospecha de fallo de infraestructura; NUNCA adjudica
> el resultado de un fix.

2026-04-10. Regla: si el test pasa aislado, es un flake.
FIX
printf 'formato-indentacion-tabs.md\tsemantico:anulacion\t%s\n' "$W/frag.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "4-POS ACOTADA verbatim (parentesis + Alcance residual)" 0 "marca corporal antes del texto muerto + S3"

# 4-N1: prosa con la palabra de estado, SIN blockquote → sin marca en el cuerpo
prepara
printf 'contenido original que sigue vivo\n' > "$W/frag.txt"
cat > "$CORPUS/formato-indentacion-tabs.md" <<'FIX'
---
name: formato-indentacion-tabs
description: "[ANULADA 2026-07-27] → sucesora: formato-indentacion-espacios — prosa, no bloque"
---
Esta politica quedo ANULADA hace tiempo, sustituida por la nueva convencion.

2026-05-01. contenido original que sigue vivo.
FIX
printf 'formato-indentacion-tabs.md\tsemantico:anulacion\t%s\n' "$W/frag.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "4-N1 prosa con la palabra de estado (sin blockquote)" 1 "sin marca de estado EN EL CUERPO"

# 4-N2: bloque sin Linea vigente/Autoridad (se corta tras Linea muerta)
prepara
printf 'el fragmento que corresponde\n' > "$W/frag.txt"
cat > "$CORPUS/formato-indentacion-tabs.md" <<'FIX'
---
name: formato-indentacion-tabs
description: "[ANULADA 2026-07-27] → sucesora: formato-indentacion-espacios — bloque incompleto"
---
> ANULADA 2026-07-27 — motivo real aqui.
> Linea muerta: "el fragmento que corresponde"

2026-05-01. el fragmento que corresponde, tal cual.
FIX
printf 'formato-indentacion-tabs.md\tsemantico:anulacion\t%s\n' "$W/frag.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "4-N2 bloque sin Linea vigente/Autoridad" 1 "falta 'Linea vigente:'"

# 4-N3: ACOTADA sin Alcance residual (el 4o campo condicionado al estado)
prepara
printf 'regla general X\n' > "$W/frag.txt"
cat > "$CORPUS/formato-indentacion-tabs.md" <<'FIX'
---
name: formato-indentacion-tabs
description: "[ACOTADA 2026-07-27] → sucesora: formato-indentacion-espacios — falta alcance"
---
> ACOTADA 2026-07-27 — matiz de alcance.
> Linea muerta: "regla general X"
> Linea vigente: [[nota-sucesora]]

2026-05-01. regla general X sigue citada aqui.
FIX
printf 'formato-indentacion-tabs.md\tsemantico:anulacion\t%s\n' "$W/frag.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "4-N3 ACOTADA sin Alcance residual" 1 "falta 'Alcance residual:'"

# 4-N4: apertura sin fecha ISO
prepara
printf 'dato historico X\n' > "$W/frag.txt"
cat > "$CORPUS/formato-indentacion-tabs.md" <<'FIX'
---
name: formato-indentacion-tabs
description: "[ANULADA 2026-07-27] → sucesora: formato-indentacion-espacios — sin fecha en la apertura"
---
> ANULADA — sin fecha en esta apertura, vaya defecto.
> Linea muerta: "dato historico X"
> Linea vigente: [[otra-nota]]
> Autoridad: decision propia.

2026-05-01. dato historico X permanece citado.
FIX
printf 'formato-indentacion-tabs.md\tsemantico:anulacion\t%s\n' "$W/frag.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "4-N4 apertura sin fecha ISO" 1 "apertura sin fecha ISO valida"

# 4-N5: apertura sin motivo real (pelado: solo estado + fecha + guion)
prepara
printf 'dato historico Y\n' > "$W/frag.txt"
cat > "$CORPUS/formato-indentacion-tabs.md" <<'FIX'
---
name: formato-indentacion-tabs
description: "[ANULADA 2026-07-27] → sucesora: formato-indentacion-espacios — motivo pelado"
---
> ANULADA 2026-07-27 —
> Linea muerta: "dato historico Y"
> Linea vigente: [[otra-nota]]
> Autoridad: decision propia.

2026-05-01. dato historico Y permanece citado.
FIX
printf 'formato-indentacion-tabs.md\tsemantico:anulacion\t%s\n' "$W/frag.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "4-N5 apertura sin motivo (pelado)" 1 "apertura sin motivo real"

# 4-N6: ALIAS-STUB declarado como semantico:anulacion → no cuenta (estados acotados)
prepara
printf 'contenido consolidado\n' > "$W/frag.txt"
cat > "$CORPUS/formato-indentacion-tabs.md" <<'FIX'
---
name: formato-indentacion-tabs
description: "[ALIAS-STUB 2026-07-27] → sucesora: formato-indentacion-espacios — consolidada"
---
> ALIAS-STUB 2026-07-27 — consolidado en otra nota.

2026-05-01. contenido consolidado.
FIX
printf 'formato-indentacion-tabs.md\tsemantico:anulacion\t%s\n' "$W/frag.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "4-N6 ALIAS-STUB declarado como semantico:anulacion" 1 "sin marca de estado EN EL CUERPO"

# 4-N7: token de cuerpo (ANULADA) != token de description (ACOTADA)
prepara
printf 'dato historico Z\n' > "$W/frag.txt"
cat > "$CORPUS/formato-indentacion-tabs.md" <<'FIX'
---
name: formato-indentacion-tabs
description: "[ACOTADA 2026-07-27] → sucesora: formato-indentacion-espacios — token distinto"
---
> ANULADA 2026-07-27 — motivo real valido.
> Linea muerta: "dato historico Z"
> Linea vigente: [[otra-nota]]
> Autoridad: decision propia.

2026-05-01. dato historico Z permanece citado.
FIX
printf 'formato-indentacion-tabs.md\tsemantico:anulacion\t%s\n' "$W/frag.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "4-N7 token de cuerpo != token de description" 1 "no coincide con el de description"

# 4-N8: etiqueta con payload VACIO (Linea vigente: sin nada detras)
prepara
printf 'fragmento test payload\n' > "$W/frag.txt"
cat > "$CORPUS/formato-indentacion-tabs.md" <<'FIX'
---
name: formato-indentacion-tabs
description: "[ANULADA 2026-07-27] → sucesora: formato-indentacion-espacios — payload vacio"
---
> ANULADA 2026-07-27 — motivo real valido aqui.
> Linea muerta: "fragmento test payload"
> Linea vigente:
> Autoridad: decision propia.

2026-05-01. fragmento test payload sigue citado.
FIX
printf 'formato-indentacion-tabs.md\tsemantico:anulacion\t%s\n' "$W/frag.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "4-N8 etiqueta con payload vacio (Linea vigente:)" 1 "falta 'Linea vigente:'"

# 4-N9: cita de "Linea muerta" que NO correlaciona con el fragmento del descriptor
prepara
printf 'el fragmento REAL que si esta declarado en el descriptor\n' > "$W/frag.txt"
cat > "$CORPUS/formato-indentacion-tabs.md" <<'FIX'
---
name: formato-indentacion-tabs
description: "[ANULADA 2026-07-27] → sucesora: formato-indentacion-espacios — cita que no correlaciona"
---
> ANULADA 2026-07-27 — motivo valido.
> Linea muerta: "un fragmento distinto que no es el declarado"
> Linea vigente: [[otra-nota]]
> Autoridad: decision propia.

2026-05-01. el fragmento REAL que si esta declarado en el descriptor.
FIX
printf 'formato-indentacion-tabs.md\tsemantico:anulacion\t%s\n' "$W/frag.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "4-N9 cita de Linea muerta que no correlaciona" 1 "no correlaciona con el fragmento del descriptor"

# 4-N10..13: fecha FUERA DE RANGO en la apertura (MAY-01: mes/dia invalidos)
for fecha_mala in "2026-00-39" "2026-13-01" "2026-02-00" "2026-12-32"; do
  prepara
  printf 'dato fechado incorrectamente\n' > "$W/frag.txt"
  cat > "$CORPUS/formato-indentacion-tabs.md" <<FIX
---
name: formato-indentacion-tabs
description: "[ANULADA 2026-07-27] → sucesora: formato-indentacion-espacios — fecha invalida"
---
> ANULADA $fecha_mala — motivo real valido aqui.
> Linea muerta: "dato fechado incorrectamente"
> Linea vigente: [[otra-nota]]
> Autoridad: decision propia.

2026-05-01. dato fechado incorrectamente sigue citado.
FIX
  printf 'formato-indentacion-tabs.md\tsemantico:anulacion\t%s\n' "$W/frag.txt" > "$W/c.tsv"
  corre "$W/c.tsv"; caso "4-N10..13 fecha fuera de rango: $fecha_mala" 1 "apertura sin fecha ISO valida"
done

# 4-N14..15: fecha SIN DELIMITAR — cuela como subcadena valida (MAY-01 bis)
for fecha_mala in "2026-12-310" "12026-12-31"; do
  prepara
  printf 'dato con fecha mal delimitada\n' > "$W/frag.txt"
  cat > "$CORPUS/formato-indentacion-tabs.md" <<FIX
---
name: formato-indentacion-tabs
description: "[ANULADA 2026-07-27] → sucesora: formato-indentacion-espacios — fecha sin delimitar"
---
> ANULADA $fecha_mala — motivo real valido aqui.
> Linea muerta: "dato con fecha mal delimitada"
> Linea vigente: [[otra-nota]]
> Autoridad: decision propia.

2026-05-01. dato con fecha mal delimitada sigue citado.
FIX
  printf 'formato-indentacion-tabs.md\tsemantico:anulacion\t%s\n' "$W/frag.txt" > "$W/c.tsv"
  corre "$W/c.tsv"; caso "4-N14..15 fecha sin delimitar (subcadena valida): $fecha_mala" 1 "apertura sin fecha ISO valida"
done

# ITEM 5 — h_antes por RUTA EXACTA, no subcadena: un directorio "a." (termina en
# punto) contiene un "nota.md" cuyo path relativo "./a./nota.md" CONTIENE la
# subcadena "./nota.md" como TEXTO — antes del fix, `grep -F -- "./$ruta"` casaba
# esa linea senuelo (y ordena antes en colacion C) y el hash pisado pasaba por
# "intacto" (verde falso).
W="$(mktemp -d)"; CORPUS="$W/corpus"; SNAP="$W/snap"
mkdir -p "$CORPUS/a."
printf 'contenido B (senuelo, vive en a./nota.md)\n' > "$CORPUS/a./nota.md"
printf 'contenido A (nota.md real, original)\n' > "$CORPUS/nota.md"
bash "$SKILL/scripts/salvaguarda.sh" "$CORPUS" "$SNAP" >/dev/null
printf 'contenido B (senuelo, vive en a./nota.md)\n' > "$CORPUS/nota.md"   # PISA nota.md con el contenido del senuelo
printf 'nota.md\tintacto\t-\n' > "$W/c.tsv"
corre "$W/c.tsv"; caso "5 h_antes por ruta exacta (subcadena './a./nota.md' ya no casa)" 1 "el hash CAMBIO"

# ============================================================================
# ITEM 8 — modo `alta` (altas declaradas): el placeholder del paso 5 (nota
# NUEVA) pasa a ser verificable por su propio verificador. 7 tests.
# ============================================================================

# 8-1: alta declarada y EXACTA → VERDE
prepara
printf 'contenido de la nota nueva.\n' > "$W/nueva.txt"
cp "$W/nueva.txt" "$CORPUS/nota-nueva.md"
printf 'nota-nueva.md\talta\t%s\n' "$W/nueva.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "8-1 alta declarada y exacta" 0 "fichero nuevo == bloque declarado"

# 8-2: contenido REAL distinto del descriptor declarado → ROJO
prepara
printf 'contenido declarado.\n' > "$W/nueva.txt"
printf 'contenido REAL distinto.\n' > "$CORPUS/nota-nueva.md"
printf 'nota-nueva.md\talta\t%s\n' "$W/nueva.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "8-2 alta con contenido distinto al descriptor" 1 "NO coincide con el descriptor declarado"

# 8-3: alta NO declarada → ROJO (mundo cerrado, con el path)
prepara
printf 'contenido nuevo sin declarar.\n' > "$CORPUS/nota-sin-declarar.md"
printf 'decision-gestor-paquetes.md\tintacto\t-\n' > "$W/c.tsv"
corre "$W/c.tsv"; caso "8-3 alta NO declarada (mundo cerrado)" 1 "mundo cerrado: 'nota-sin-declarar.md'"

# 8-4: alta de un fichero que YA estaba en el snapshot → ROJO (reescritura disfrazada)
prepara
printf 'contenido cualquiera.\n' > "$W/desc.txt"
printf 'decision-gestor-paquetes.md\talta\t%s\n' "$W/desc.txt" > "$W/c.tsv"
corre "$W/c.tsv"; caso "8-4 alta de fichero YA en el snapshot" 1 "YA estaba en el snapshot"

# 8-5: descriptor == el propio fichero del corpus (identidad de ruta) → exit 2
prepara
printf 'decision-gestor-paquetes.md\talta\t%s\n' "$CORPUS/decision-gestor-paquetes.md" > "$W/c.tsv"
corre "$W/c.tsv"; caso "8-5 descriptor == el propio fichero (identidad)" 2 "MISMO fichero"

# 8-6: descriptor es un SYMLINK → exit 2 (fail-closed, anti-circularidad)
if command -v ln >/dev/null 2>&1; then
  prepara
  printf 'contenido cualquiera.\n' > "$W/real.txt"
  ln -s "$W/real.txt" "$W/descriptor-symlink.txt"
  printf 'nota-nueva.md\talta\t%s\n' "$W/descriptor-symlink.txt" > "$W/c.tsv"
  corre "$W/c.tsv"; caso "8-6 descriptor es un symlink" 2 "descriptor es un symlink"
else
  echo "  OMIT  [8-6 descriptor symlink] (ln no disponible)"
fi

# 8-7: descriptor es un HARDLINK al fichero del corpus (mismo inodo, otro nombre) → exit 2
prepara
if ln "$CORPUS/decision-gestor-paquetes.md" "$W/hardlink-descriptor.txt" 2>/dev/null; then
  printf 'decision-gestor-paquetes.md\talta\t%s\n' "$W/hardlink-descriptor.txt" > "$W/c.tsv"
  corre "$W/c.tsv"; caso "8-7 descriptor es un hardlink al fichero del corpus" 2 "MISMO fichero"
else
  echo "  OMIT  [8-7 descriptor hardlink] (ln no disponible o cross-device)"; rm -rf "$W"
fi

echo "---- resultado: PASA=$PASA FALLA=$FALLA ----"
[ "$FALLA" -eq 0 ]
