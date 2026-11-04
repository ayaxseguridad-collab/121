#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A&&ok||mal: ok()/mal() nunca fallan (printf+contador); comillas simples deliberadas (patrones literales)
# probar-standalone.sh — gate de instalacion limpia (M5): SOLO la carpeta del
# skill copiada a un HOME temporal sin repo ni fabrica debe funcionar igual, en
# los 3 layouts soportados (incluida una ruta CON ESPACIOS), y sin una sola
# referencia runtime a rutas del repo de origen.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
PASA=0; FALLA=0
ok()  { echo "  OK    $*"; PASA=$((PASA+1)); }
mal() { echo "  FALLO $*"; FALLA=$((FALLA+1)); }

echo "==== probar-standalone: HOME limpio + 3 layouts + cero referencias internas ===="

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home"
cp -r "$SKILL" "$T/home/talent-memoria"
S="$T/home/talent-memoria"

# 0. cero referencias runtime a rutas/convenciones del repo de origen
# La seccion "## Paquete de fábrica" del SKILL.md es metadata del canon (nombra el repo
# motor por doctrina del paquete) y NO viaja en el artefacto del alumno: la publicacion
# la recorta del ZIP. El contrato de este gate es el artefacto instalable → se evalua el
# SKILL.md SIN esa seccion; scripts/ y references/ se grepan integros, sin excepcion.
awk '/^## Paquete de fábrica$/{exit} {print}' "$S/SKILL.md" > "$T/skill-instalable.md"
if grep -rlE 'Talent Engine|talent-factory|blackamp' "$S/scripts" "$S/references" "$T/skill-instalable.md" 2>/dev/null | grep -q .; then
  mal "hay referencias a rutas internas del repo de origen:"; grep -rlE 'Talent Engine|talent-factory|blackamp' "$S/scripts" "$S/references" "$T/skill-instalable.md" | sed 's/^/      /'
else
  ok "cero referencias a rutas internas en scripts/, references/ y SKILL.md instalable (sin seccion de paquete)"
fi

# layout 1: memoria de repositorio (.claude/memory bajo el cwd) via AUTODETECCION
mkdir -p "$T/home/proyecto/.claude"
cp -r "$HERE/corpus-fake" "$T/home/proyecto/.claude/memory"
SAL1="$(cd "$T/home/proyecto" && HOME="$T/home" bash "$S/scripts/diagnostico.sh" 2>&1)" \
  && printf '%s' "$SAL1" | grep -q "DIAGNOSTICO" \
  && ok "layout 1 (repo .claude/memory, autodetectado)" || mal "layout 1 fallo"

# layout 2: memoria general del harness (autodeteccion por slug del cwd)
mkdir -p "$T/home/proyecto2"
slug="$(cd "$T/home/proyecto2" && pwd | tr '/ ' '--')"
mkdir -p "$T/home/.claude/projects/$slug/memory"
cp "$HERE"/corpus-fake/*.md "$T/home/.claude/projects/$slug/memory/"
SAL2="$(cd "$T/home/proyecto2" && HOME="$T/home" bash "$S/scripts/diagnostico.sh" 2>&1)" \
  && printf '%s' "$SAL2" | grep -q "projects" \
  && ok "layout 2 (memoria general del harness, autodetectada)" || mal "layout 2 fallo"

# layout 3: ruta explicita CON ESPACIOS + ciclo completo salvaguarda→reparar→verificar
mkdir -p "$T/home/mi memoria con espacios"
cp -r "$HERE/corpus-fake" "$T/home/mi memoria con espacios/corpus"
printf -- '---\nname: nota con espacios\ndescription: nota cuyo nombre lleva espacios\n---\n2026-07-27. contenido.\n' \
  > "$T/home/mi memoria con espacios/corpus/nota con espacios.md"
C="$T/home/mi memoria con espacios/corpus"
HOME="$T/home" bash "$S/scripts/diagnostico.sh" "$C" >/dev/null 2>&1 && ok "layout 3: diagnostico sobre ruta con espacios" || mal "layout 3: diagnostico fallo"
HOME="$T/home" bash "$S/scripts/salvaguarda.sh" "$C" "$T/home/snap" >/dev/null 2>&1 && ok "layout 3: salvaguarda con espacios" || mal "layout 3: salvaguarda fallo"
# reparacion minima: anexo a una nota + fila intacto de la nota con espacios
printf 'Anexo standalone 2026-07-27.\n' > "$T/bloque.txt"
cat "$T/bloque.txt" >> "$C/decision-gestor-paquetes.md"
{ printf 'decision-gestor-paquetes.md\tsolo-adicion\t%s\n' "$T/bloque.txt"
  printf 'nota con espacios.md\tintacto\t-\n'; } > "$T/c.tsv"
if HOME="$T/home" bash "$S/scripts/verificar.sh" "$T/home/snap" "$C" "$T/c.tsv" > "$T/v.out" 2>&1; then
  grep -qF -- "intacto 'nota con espacios.md' (hash identico)" "$T/v.out" \
    && ok "layout 3: verificar en verde (incl. fichero con espacios)" || mal "layout 3: verificar no comprobo la nota con espacios"
else
  mal "layout 3: verificar fallo"; sed 's/^/      | /' "$T/v.out" | head -10
fi

# cero red: los scripts no invocan clientes de red
if grep -rnE '\b(curl|wget|nc|ssh|scp|rsync)\b' "$S/scripts" | grep -v '^\s*#' | grep -v 'allowlist' | grep -q .; then
  mal "los scripts invocan clientes de red"
else
  ok "cero clientes de red en scripts/"
fi

echo "---- resultado: PASA=$PASA FALLA=$FALLA ----"
[ "$FALLA" -eq 0 ]
