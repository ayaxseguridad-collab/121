# Quick Scaffold — Complete Reference

Runnable bash scaffold for a brand-new skill directory, plus the post-creation quick
checklist and a pointer to the packaged Gold Standard validator script referenced from
`SKILL.md`'s Workflow steps 2-6.

## Table of Contents

1. [Bash — Scaffold de Directorios y Archivos](#1-bash--scaffold-de-directorios-y-archivos)
2. [Verificación — Checklist Rápida Post-Creación](#2-verificación--checklist-rápida-post-creación)
3. [Validación del Gold Standard](#3-validación-del-gold-standard)
4. [Gotchas & Cross-References](#4-gotchas--cross-references)

---

## 1. Bash — Scaffold de Directorios y Archivos

```text
┌──────────────────┐     ┌────────────────────┐     ┌─────────────────────┐
│ mkdir references/ │────→│ cat > SKILL.md      │────→│ cat > references/   │
│                    │     │ (frontmatter mínimo)│     │ getting-started.md  │
└──────────────────┘     └────────────────────┘     └─────────────────────┘
                                                                │
                                                                ▼
                                                     ┌─────────────────────┐
                                                     │ verificar estructura │
                                                     │ + frontmatter        │
                                                     └─────────────────────┘
```

```bash
# 1. Crear estructura (este repo descubre skills desde .claude/skills/, no skills/ en la raíz)
SKILL_NAME="mi-nuevo-skill"

# Validar kebab-case seguro ANTES de construir cualquier ruta o interpolar con sed: rechaza
# path traversal (p. ej. ../../tmp/x) y caracteres que romperían la sustitución (/, &, \).
if [[ ! "$SKILL_NAME" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
  echo "ERROR: SKILL_NAME debe ser kebab-case seguro: ^[a-z0-9]+(-[a-z0-9]+)*\$ (recibido: '$SKILL_NAME')." >&2
  return 1 2>/dev/null || exit 1
fi

# ABORTAR antes de escribir nada si el destino ya existe — mkdir -p tiene éxito igual con un
# directorio existente, y los `cat > ...` de abajo TRUNCAN en silencio cualquier SKILL.md o
# getting-started.md ya presente (incluido trabajo sin commitear) si SKILL_NAME se repite o
# se copia mal.
if [ -e ".claude/skills/${SKILL_NAME}" ]; then
  echo "ERROR: .claude/skills/${SKILL_NAME} ya existe — aborta para no sobrescribir. Elige otro SKILL_NAME." >&2
  return 1 2>/dev/null || exit 1
fi
mkdir -p ".claude/skills/${SKILL_NAME}/references"

# 2. Crear SKILL.md con frontmatter mínimo. El heredoc va QUOTED ('SKILLEOF') para que el
# backtick de "`references/`" no se interprete como command substitution; por eso el
# nombre real se interpola DESPUÉS con sed, nunca como `name: mi-nuevo-skill` literal.
cat > ".claude/skills/${SKILL_NAME}/SKILL.md" << 'SKILLEOF'
---
name: __SKILL_NAME__
description: >
  Use this skill whenever the user needs to work with Mi Nuevo Service.
  Trigger keywords: "mi servicio", "my service", "__SKILL_NAME__".
---

# Mi Nuevo Service — State of the Art ({{MONTH}} {{YEAR}})

## Quick Orientation

<!-- Completar con datos reales del servicio -->

## Next Steps

- Read `references/` files for deeper topics.
SKILLEOF
# sed -i difiere entre GNU y BSD (BSD exige argumento de sufijo); usar un temporal portable
# y ABORTAR si la sustitución falla, para no dejar el placeholder __SKILL_NAME__ en el archivo.
_ta_tmp="$(mktemp)"
if sed "s/__SKILL_NAME__/${SKILL_NAME}/" ".claude/skills/${SKILL_NAME}/SKILL.md" > "$_ta_tmp"; then
  mv "$_ta_tmp" ".claude/skills/${SKILL_NAME}/SKILL.md"
else
  echo "ERROR: interpolación de SKILL_NAME con sed falló." >&2
  rm -f "$_ta_tmp"
  return 1 2>/dev/null || exit 1
fi

# 3. Crear primer reference file
cat > ".claude/skills/${SKILL_NAME}/references/getting-started.md" << 'REFEOF'
# Getting Started — Complete Reference

## Table of Contents

1. [Setup](#1-setup)
2. [Gotchas & Cross-References](#2-gotchas--cross-references)

---

## 1. Setup

<!-- Completar -->

---

## 2. Gotchas & Cross-References

1. **TODO** → Replace with real gotchas.
REFEOF

# 4. Verificar estructura
echo "=== Estructura creada ==="
find ".claude/skills/${SKILL_NAME}" -type f | sort

# 5. Verificar frontmatter (debe mostrar name: ${SKILL_NAME}, no el placeholder)
head -5 ".claude/skills/${SKILL_NAME}/SKILL.md"
```

---

## 2. Verificación — Checklist Rápida Post-Creación

```bash
# Verificar que SKILL.md tiene YAML frontmatter
head -1 ".claude/skills/${SKILL_NAME}/SKILL.md"  # Debe mostrar "---"

# Verificar kebab-case en references
ls ".claude/skills/${SKILL_NAME}/references/"  # Todo lowercase con hyphens

# Verificar registro en la tabla "## Skills Obligatorios" de CLAUDE.md
# Scoped a ESA sección Y a una FILA DE TABLA (línea que empieza con "|") con el skill entre
# backticks — evita falsos verdes por menciones en prosa, árboles de archivos u otras secciones:
awk '/^## Skills Obligatorios/{f=1; next} /^## /{f=0} f' CLAUDE.md | grep -E "^\|.*\`${SKILL_NAME}\`"  # 1+ fila ⇒ registrado; vacío ⇒ NO registrado

# Contar archivos totales del sistema
find .claude/skills/ -type f | wc -l
```

---

## 3. Validación del Gold Standard

El validador vive como **script real empaquetado** en
`.claude/skills/skill-creator/scripts/validate_skill.py` — no como bloque de código
embebido en este reference. Un script real es más confiable, no consume contexto en cada
carga del skill, y evita que la lógica de validación se desincronice del repo (el
prototipo embebido anterior tenía un bug de base path que el script empaquetado ya no
tiene).

```bash
python3 .claude/skills/skill-creator/scripts/validate_skill.py <skill-name>
```

Cubre hoy 11 checks (enumerados abajo). Los checks de estructura del CUERPO
(`heading-*`, `gotchas-count`, `reference-missing`) operan sobre el documento sin frontmatter
ni bloques de código fenceados — parser de fences por máquina de estados: backticks/tildes,
indentación 0-3, cierre con espacios finales, fence sin cerrar hasta EOF, rechazo de backtick
en el info string de un opener de backticks; los checks `frontmatter`/`yaml`/
`description-length`/`skill-md-lines`/`skill-md-read` operan sobre el archivo o su frontmatter
directamente:

- **frontmatter** (`name`/`description` presentes y de tipo string) y **yaml** (frontmatter
  parseable)
- **description-length**: `description` ≤1024 caracteres
- **heading-quick-orientation** / **heading-gotchas** / **heading-cross-skill** /
  **heading-next-steps**: las 4 secciones requeridas, con matching exacto de las variantes
  de heading aceptadas (ver "Acceptable Variations" en `SKILL.md`) por línea, sin cruzar
  saltos de línea y tolerando indentación 0-3
- **gotchas-count**: la sección de gotchas tiene, dentro de su propio cuerpo, al menos 10
  entradas numeradas (`N. **Título**`) o al menos 5 entradas antipattern (`### ❌ AP-N`)
- **reference-missing**: cada archivo listado en la Reference Files Table existe
- **skill-md-lines**: `SKILL.md` tiene menos de 500 líneas (sobre el contenido crudo,
  bloques de código incluidos — el límite mide el archivo real)
- **skill-md-read**: `SKILL.md` es legible como UTF-8 (nunca lanza ante bytes inválidos o
  fallo de E/S)

Tests deterministas y herméticos en `scripts/test_validate_skill.py`
(`cd .claude/skills/skill-creator/scripts && python3 -m unittest test_validate_skill -v`).

---

## 4. Gotchas & Cross-References

1. **`find .claude/skills/ -type f | wc -l`** cuenta archivos de TODOS los skills, no solo el
   nuevo — útil para refrescar la métrica "Total files" de `SKILL.md`, no como conteo del
   skill individual.
2. **El validador solo verifica estructura, no contenido real** → un skill puede pasar
   `scripts/validate_skill.py` (frontmatter, longitud de `description`, las 4 secciones
   requeridas con sus variantes, mínimo de gotchas, existencia de los reference files,
   tamaño de `SKILL.md` y legibilidad UTF-8) y aun así documentar versiones de API
   alucinadas o URLs rotas —
   combinar siempre con la sección "Verification of Reality" del Gold Standard Checklist
   en `SKILL.md`.
3. **Ubicación real de los skills** → este scaffold crea en `.claude/skills/`, no en un
   `skills/` de raíz (convención de este repo, ver `CLAUDE.md`). Un scaffold genérico
   reutilizado en otro repo debe re-verificar dónde vive su propio directorio de skills.
4. **Heredoc quoted + `sed` para interpolar el nombre** → el heredoc de `SKILL.md` usa el
   delimitador entre comillas (`<< 'SKILLEOF'`) a propósito, porque su cuerpo tiene un
   backtick (`` `references/` ``) que un heredoc SIN comillas interpretaría como command
   substitution. Por eso `${SKILL_NAME}` no se puede expandir dentro del heredoc — se escribe
   un placeholder (`__SKILL_NAME__`) y se interpola después con `sed -i`, nunca dejando
   `name: mi-nuevo-skill` literal en el archivo generado.

**Related reference files:**

- Para el formato completo de `SKILL.md` (incluida la tabla de campos de frontmatter) →
  `skill-md-template.md`
- Para el formato de archivos `references/*.md` → `reference-file-template.md`
- Para registrar el skill nuevo en `CLAUDE.md` → `claude-md-registration.md`
