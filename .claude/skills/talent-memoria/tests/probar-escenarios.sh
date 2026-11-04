#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A&&ok||mal: ok()/mal() nunca fallan (printf+contador); comillas simples deliberadas (patrones literales)
# probar-escenarios.sh — 3 escenarios EXTREMO A EXTREMO del pipeline documentado
# (references/02), cada uno con su contra-variante naive. Frontera declarada sin
# adornos: esto ejercita el PROCEDIMIENTO con fixtures deterministas — NO es un
# eval de comportamiento del modelo (eso vive fuera del skill, en el plan de la
# ronda, con oraculo externo congelado).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
PASA=0; FALLA=0
ok()  { echo "  OK    $*"; PASA=$((PASA+1)); }
mal() { echo "  FALLO $*"; FALLA=$((FALLA+1)); }
# limpieza UNICA para los 3 escenarios: cada `trap ... EXIT` por separado
# pisaria al anterior, dejando sin limpiar todo menos el ultimo mktemp -d
cleanup() { rm -rf "${E1:-}" "${E2:-}" "${E3:-}"; }
trap cleanup EXIT

# corre verificar.sh capturando salida y rc (sin abortar el probador)
corre() { set +e; SALIDA="$(bash "$SKILL/scripts/verificar.sh" "$1" "$2" "$3" 2>&1)"; RC=$?; set -e; }

echo "==== probar-escenarios: E1/E2/E3 (procedimiento VERDE vs naive ROJO) ===="

# ============================================================================
# E1 · conflicto SIN FECHA (paso 5, references/02 seccion 10)
#   procedimiento: placeholder PENDIENTE nuevo declarado `alta`, las dos notas
#   en conflicto quedan INTACTAS (ninguna se adjudica) → VERDE
#   naive: pisar la nota sin fecha y adjudicar por intuicion → ROJO (S5)
# ============================================================================
E1="$(mktemp -d)"

# -- E1 procedimiento --
mkdir -p "$E1/proc/corpus"
cat > "$E1/proc/corpus/nota-a.md" <<'EOF'
---
name: nota-a
description: usamos el editor X para todo el equipo
---
2026-06-10. El equipo usa el editor X como estandar.
EOF
cat > "$E1/proc/corpus/nota-b.md" <<'EOF'
---
name: nota-b
description: el equipo prefiere el editor Y
---
El equipo prefiere el editor Y para las tareas de refactor grande.
EOF
bash "$SKILL/scripts/salvaguarda.sh" "$E1/proc/corpus" "$E1/proc/snap" >/dev/null
cat > "$E1/proc/corpus/pendiente-editor.md" <<'EOF'
---
description: "[PENDIENTE 2026-07-27] conflicto sin adjudicar: editor de equipo"
---
Conflicto: [[nota-a]] dice editor X (fechada) · [[nota-b]] dice editor Y (sin fecha).
Se resuelve: cuando se decida. Mientras tanto: NINGUNA de las dos se toca.
EOF
cp "$E1/proc/corpus/pendiente-editor.md" "$E1/proc/desc.txt"
printf 'pendiente-editor.md\talta\t%s\n' "$E1/proc/desc.txt" > "$E1/proc/c.tsv"
corre "$E1/proc/snap" "$E1/proc/corpus" "$E1/proc/c.tsv"
if [ "$RC" -eq 0 ] && printf '%s' "$SALIDA" | grep -qF -- "fichero nuevo == bloque declarado"; then
  ok "E1 procedimiento: placeholder PENDIENTE via alta, ambas notas intactas → VERDE"
else
  mal "E1 procedimiento NO dio VERDE (rc=$RC)"; printf '%s\n' "$SALIDA" | sed 's/^/      | /' | head -15
fi

# -- E1 naive: pisa nota-b.md (adjudica por intuicion) y lo declara solo-adicion --
mkdir -p "$E1/naive/corpus"
cp "$E1/proc/corpus/nota-a.md" "$E1/naive/corpus/nota-a.md"
cat > "$E1/naive/corpus/nota-b.md" <<'EOF'
---
name: nota-b
description: el equipo prefiere el editor Y
---
El equipo prefiere el editor Y para las tareas de refactor grande.
EOF
bash "$SKILL/scripts/salvaguarda.sh" "$E1/naive/corpus" "$E1/naive/snap" >/dev/null
cat > "$E1/naive/corpus/nota-b.md" <<'EOF'
---
name: nota-b
description: el equipo usa el editor X (adjudicado sin fecha, por intuicion)
---
El equipo usa el editor X, decidido sin mirar si nota-b tenia fecha.
EOF
printf 'El equipo usa el editor X, decidido sin mirar si nota-b tenia fecha.\n' > "$E1/naive/bloque.txt"
printf 'nota-b.md\tsolo-adicion\t%s\n' "$E1/naive/bloque.txt" > "$E1/naive/c.tsv"
corre "$E1/naive/snap" "$E1/naive/corpus" "$E1/naive/c.tsv"
if [ "$RC" -ne 0 ] && printf '%s' "$SALIDA" | grep -qF -- "lineas ELIMINADAS (S5)"; then
  ok "E1 naive: pisar nota-b.md y adjudicar por intuicion → ROJO (S5)"
else
  mal "E1 naive NO dio ROJO S5 (rc=$RC)"; printf '%s\n' "$SALIDA" | sed 's/^/      | /' | head -15
fi

# ============================================================================
# E2 · contradiccion FECHADA (paso 2, references/02 seccion 7)
#   procedimiento: bloque de 4 campos (ANULADA) + S3 en la perdedora, la
#   ganadora queda intacta → VERDE
#   naive: borrar la nota vieja sin declarar la baja → ROJO (mundo cerrado)
# ============================================================================
E2="$(mktemp -d)"

mkdir -p "$E2/base/corpus"
cat > "$E2/base/corpus/politica-vieja.md" <<'EOF'
---
name: politica-vieja
description: usamos pnpm para instalar dependencias
---
2026-05-01. instala las dependencias con pnpm install, siempre.
EOF
cat > "$E2/base/corpus/politica-nueva.md" <<'EOF'
---
name: politica-nueva
description: usamos npm para instalar dependencias (decision de julio)
---
2026-07-20. instala las dependencias con npm install; dejamos pnpm.
EOF

# -- E2 procedimiento --
cp -r "$E2/base/corpus" "$E2/proc-corpus"
bash "$SKILL/scripts/salvaguarda.sh" "$E2/proc-corpus" "$E2/proc-snap" >/dev/null
cat > "$E2/proc-corpus/politica-vieja.md" <<'EOF'
---
name: politica-vieja
description: "[ANULADA 2026-07-20] → sucesora: politica-nueva — cambio de gestor de paquetes"
---
> ANULADA 2026-07-20 — se cambio de gestor de paquetes.
> Linea muerta: "instala las dependencias con pnpm install, siempre"
> Linea vigente: [[politica-nueva]]
> Autoridad: decision propia, sesion del 20-jul.

2026-05-01. instala las dependencias con pnpm install, siempre.
EOF
printf 'instala las dependencias con pnpm install, siempre\n' > "$E2/frag.txt"
printf 'politica-vieja.md\tsemantico:anulacion\t%s\n' "$E2/frag.txt" > "$E2/proc-c.tsv"
corre "$E2/proc-snap" "$E2/proc-corpus" "$E2/proc-c.tsv"
if [ "$RC" -eq 0 ] && printf '%s' "$SALIDA" | grep -qF -- "marca corporal antes del texto muerto + S3"; then
  ok "E2 procedimiento: bloque de 4 campos + S3, ganadora intacta → VERDE"
else
  mal "E2 procedimiento NO dio VERDE (rc=$RC)"; printf '%s\n' "$SALIDA" | sed 's/^/      | /' | head -15
fi

# -- E2 naive: borra politica-vieja.md sin declarar la baja --
cp -r "$E2/base/corpus" "$E2/naive-corpus"
bash "$SKILL/scripts/salvaguarda.sh" "$E2/naive-corpus" "$E2/naive-snap" >/dev/null
rm -f "$E2/naive-corpus/politica-vieja.md"
printf 'politica-nueva.md\tintacto\t-\n' > "$E2/naive-c.tsv"
corre "$E2/naive-snap" "$E2/naive-corpus" "$E2/naive-c.tsv"
if [ "$RC" -ne 0 ] && printf '%s' "$SALIDA" | grep -qF -- "mundo cerrado: 'politica-vieja.md'"; then
  ok "E2 naive: borrar la nota vieja sin declarar → ROJO (mundo cerrado, baja no declarada)"
else
  mal "E2 naive NO dio ROJO mundo cerrado (rc=$RC)"; printf '%s\n' "$SALIDA" | sed 's/^/      | /' | head -15
fi

# ============================================================================
# E3 · duplicado + indice (pasos 1 y 9, references/02 secciones 6 y 13)
#   procedimiento: superconjunto intacto + perdedora → ALIAS-STUB + fila INDEX
#   (nuevo presente, viejo ausente) → VERDE
#   naive: anade el nuevo one-liner al indice SIN quitar el viejo → ROJO (S6)
# ============================================================================
E3="$(mktemp -d)"

mkdir -p "$E3/base/corpus"
cat > "$E3/base/corpus/politica-tests-completa.md" <<'EOF'
---
name: politica-tests-completa
description: politica de tests del equipo (version completa)
---
2026-06-12. Todo PR corre unit + integracion antes de mergear.
Los hotfix llevan ademas la etiqueta URGENTE en el cuerpo del PR.
EOF
cat > "$E3/base/corpus/politica-tests-duplicada.md" <<'EOF'
---
name: politica-tests-duplicada
description: politica de tests (version parecida, mas corta)
---
2026-06-01. Todo PR corre unit + integracion antes de mergear.
EOF
cat > "$E3/base/corpus/MEMORY.md" <<'EOF'
# MEMORY — indice del corpus de escenarios

- [Tests](politica-tests-duplicada.md) — vigente (jun-2026)
EOF

# -- E3 procedimiento --
cp -r "$E3/base/corpus" "$E3/proc-corpus"
bash "$SKILL/scripts/salvaguarda.sh" "$E3/proc-corpus" "$E3/proc-snap" >/dev/null
cat > "$E3/proc-corpus/politica-tests-duplicada.md" <<'EOF'
---
name: politica-tests-duplicada
description: "[ALIAS-STUB 2026-07-27] → sucesora: politica-tests-completa — consolidada (superconjunto)"
---
**[ALIAS-STUB 2026-07-27]** Consolidado en [[politica-tests-completa]] (superconjunto:
ya incluye el contenido de esta nota). Este archivo existe para no romper enlaces y
greps entrantes.
EOF
cat > "$E3/proc-corpus/MEMORY.md" <<'EOF'
# MEMORY — indice del corpus de escenarios

- [Tests](politica-tests-completa.md) — vigente (jul-2026)
EOF
printf 'politica-tests-completa\n' > "$E3/suc.txt"
{ printf 'politica-tests-duplicada.md\tsemantico:alias-stub\t%s\n' "$E3/suc.txt"
  printf 'MEMORY.md\tsemantico:indice\t-\n'
  printf 'INDEX\t- [Tests](politica-tests-completa.md) — vigente (jul-2026)\t- [Tests](politica-tests-duplicada.md) — vigente (jun-2026)\n'
} > "$E3/proc-c.tsv"
corre "$E3/proc-snap" "$E3/proc-corpus" "$E3/proc-c.tsv"
if [ "$RC" -eq 0 ] && printf '%s' "$SALIDA" | grep -qF -- "S6 indice: nuevo presente, viejo ausente"; then
  ok "E3 procedimiento: ALIAS-STUB + indice (nuevo presente, viejo ausente) → VERDE"
else
  mal "E3 procedimiento NO dio VERDE (rc=$RC)"; printf '%s\n' "$SALIDA" | sed 's/^/      | /' | head -15
fi

# -- E3 naive: anade el nuevo one-liner SIN quitar el viejo (politica-tests-duplicada.md
# se deja intacta: el error naive es puramente de indice, para aislar S6) --
cp -r "$E3/base/corpus" "$E3/naive-corpus"
bash "$SKILL/scripts/salvaguarda.sh" "$E3/naive-corpus" "$E3/naive-snap" >/dev/null
cat > "$E3/naive-corpus/MEMORY.md" <<'EOF'
# MEMORY — indice del corpus de escenarios

- [Tests](politica-tests-duplicada.md) — vigente (jun-2026)
- [Tests](politica-tests-completa.md) — vigente (jul-2026)
EOF
printf -- '- [Tests](politica-tests-completa.md) — vigente (jul-2026)\n' > "$E3/naive-bloque.txt"
{ printf 'MEMORY.md\tsolo-adicion\t%s\n' "$E3/naive-bloque.txt"
  printf 'INDEX\t- [Tests](politica-tests-completa.md) — vigente (jul-2026)\t- [Tests](politica-tests-duplicada.md) — vigente (jun-2026)\n'
} > "$E3/naive-c.tsv"
corre "$E3/naive-snap" "$E3/naive-corpus" "$E3/naive-c.tsv"
if [ "$RC" -ne 0 ] && printf '%s' "$SALIDA" | grep -qF -- "el one-liner viejo SIGUE en el indice"; then
  ok "E3 naive: anade one-liner nuevo SIN quitar el viejo → ROJO (S6)"
else
  mal "E3 naive NO dio ROJO S6 (rc=$RC)"; printf '%s\n' "$SALIDA" | sed 's/^/      | /' | head -15
fi

echo "---- resultado: PASA=$PASA FALLA=$FALLA ----"
[ "$FALLA" -eq 0 ]
