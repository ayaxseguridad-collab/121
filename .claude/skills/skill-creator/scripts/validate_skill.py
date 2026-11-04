#!/usr/bin/env python3
"""
validate_skill.py - Valida un skill contra el Gold Standard de skill-creator.

Verifica, contra <repo>/.claude/skills/<skill-name>/SKILL.md:
  (a) el frontmatter YAML es un mapping valido con `name` y `description`, ambos string
      y no vacios tras strip()
  (b) `description` no excede 1024 caracteres tras strip() - tope duro, sin excepcion.
      Alineado con el validador canonico de referencia
      (~/.codex/skills/.system/skill-creator/scripts/quick_validate.py), cuyo
      `allowed_properties` no incluye `when_to_use`: la activacion de un skill vive
      entera en `description`.
  (c) cada archivo `references/*.md` listado en la Reference Files Table
      (`| Topic | Reference File | When to Read |`) existe realmente en references/
  (d) SKILL.md tiene menos de 500 lineas
  (e) seccion Quick Orientation presente (o una variante aceptada - ver
      QUICK_ORIENTATION_PATTERNS y "Acceptable Variations" en SKILL.md)
  (f) seccion Critical Gotchas / Commandments / Antipatterns presente
  (g) seccion Cross-Skill Integration presente
  (h) seccion Next Steps presente (o una variante aceptada - ver NEXT_STEPS_PATTERNS)
  (i) la seccion de gotchas (f) tiene, DENTRO de su propio cuerpo (hasta el siguiente
      heading H2), al menos 10 entradas en formato numerado ("N. **Titulo**") o al
      menos 5 entradas en formato antipattern ("### ❌ AP-N"); el formato con mas
      entradas AP-N gana el umbral 5 en cuanto aparece una sola entrada AP-N

Los checks (e)-(i) operan sobre el CUERPO del documento (sin frontmatter, sin bloques
de codigo fenceados) para no contar headings/gotchas ilustrativos dentro de ejemplos
embebidos en un meta-skill como este. Los checks (a)-(d) operan sobre el contenido
crudo tal cual esta en disco (el frontmatter es sintaxis del archivo, no prosa, y el
limite de lineas mide el archivo real).

Dependencias:
    pip install pyyaml
    (ya viene instalado en este entorno; si falta, el script imprime un mensaje
    accionable y sale con exit 1 en vez de un traceback)

Uso CLI:
    python3 .claude/skills/skill-creator/scripts/validate_skill.py <skill-name>
    python3 .claude/skills/skill-creator/scripts/validate_skill.py --help

Tests:
    cd .claude/skills/skill-creator/scripts && python3 -m unittest test_validate_skill -v

Salida: primera linea PASS o FAIL, seguida de una linea "  - [categoria] problema" por
cada hallazgo. Categorias: frontmatter, yaml, description-length, heading-quick-orientation,
heading-gotchas, heading-cross-skill, heading-next-steps, gotchas-count, reference-missing,
skill-md-lines, skill-md-read. Exit code 0 si pasa, 1 si falla o hay un error de entrada
(skill inexistente, nombre invalido, etc. - impreso en stderr como ERROR, sin traceback).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: falta la dependencia PyYAML.", file=sys.stderr)
    print("Instalala con: pip install pyyaml  (o: pip3 install --user pyyaml)", file=sys.stderr)
    sys.exit(1)

MAX_DESCRIPTION_LENGTH = 1024
MAX_SKILL_MD_LINES = 500
MIN_GOTCHAS_NUMBERED = 10
MIN_GOTCHAS_AP = 5

FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---", re.DOTALL)
REFERENCE_FILE_RE = re.compile(r"`(references/[\w.\-]+\.md)`")

# Linea de heading H2 real: "##" NO seguido de un 3er "#" (excluye H3+), con al menos un
# espacio/tab tras el marcador (ATX valido), indentado 0-3 espacios (limite CommonMark de
# fence/heading). El grupo de captura devuelve el heading YA NORMALIZADO sin la indentacion
# inicial - se usa SIEMPRE con finditer()+.group(1), nunca con findall() a secas: el punto es
# recortar el prefijo de espacios para que los patrones de variante (anclados a "^##") sigan
# matcheando igual con o sin indentacion. [ \t] (no \s) evita que el "espacio" cruce un salto
# de linea: un "##" solo en su propia linea (p. ej. dentro de un YAML scalar block) NO cuenta
# como apertura de heading.
H2_LINE_RE = re.compile(r"^ {0,3}(##(?!#)[ \t].*)$", re.MULTILINE)

# Variantes aceptadas por "Acceptable Variations" en SKILL.md. Cada patron matchea contra UNA
# linea de heading ya extraida (IGNORECASE, sin MULTILINE - se evalua por linea, nunca sobre
# el documento entero de una vez, o el `^` deja de anclar donde se espera).
QUICK_ORIENTATION_PATTERNS = [
    re.compile(r"^##\s+Quick Orientation\b", re.IGNORECASE),
    re.compile(r"^##\s+Quick Context\b", re.IGNORECASE),
    re.compile(r"^##\s+Quick Reference\s*$", re.IGNORECASE),  # bare only - con ":" es Next Steps
    re.compile(r"^##\s+Info Basica\b", re.IGNORECASE),
    re.compile(r"^##\s+S1\b(?!\d)", re.IGNORECASE),            # "S1" pero no "S10"/"S11"
    re.compile(r"^##\s+(?:\d+\.\s*)?Quick Start\b", re.IGNORECASE),
]
NEXT_STEPS_PATTERNS = [
    re.compile(r"^##\s+Next Steps\b", re.IGNORECASE),
    re.compile(r"^##\s+When to Read Reference Files\b", re.IGNORECASE),
    re.compile(r"^##\s+Cuando Leer Archivos de Referencia\b", re.IGNORECASE),
    re.compile(r"^##\s+Decision Workflows\b", re.IGNORECASE),
    re.compile(r"^##\s+(?:\d+\.\s*)?Reference Files\b", re.IGNORECASE),  # tolera "## 6. Reference Files"
    re.compile(r"^##\s+Quick Reference:\s*Which File to Read\b", re.IGNORECASE),
]
GOTCHAS_HEADING_RE = re.compile(r"\b(critical gotchas|commandments|antipatterns?)\b", re.IGNORECASE)
CROSS_SKILL_HEADING_RE = re.compile(r"\bcross-skill integration\b", re.IGNORECASE)

# Entradas de gotchas dentro del CUERPO de la seccion de gotchas (no del documento entero -
# ver _section_body). "❌" es un literal no-ASCII deliberado; el marcador AP exige "###".
NUMBERED_GOTCHA_RE = re.compile(r"^\d+\.\s+\*\*", re.MULTILINE)
AP_GOTCHA_RE = re.compile(r"^###\s*❌\s*AP-\d+", re.MULTILINE)

# Fence CommonMark: marcador de apertura backtick o tilde, longitud >= 3, indentado 0-3.
_OPEN_FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")


class Finding:
    """Un hallazgo de validacion, con su categoria."""

    def __init__(self, category: str, message: str) -> None:
        self.category = category
        self.message = message

    def __str__(self) -> str:
        return f"  - [{self.category}] {self.message}"


def find_repo_root(start: Path) -> Path:
    """Sube desde `start` hasta encontrar un `.git`, o falla explicitamente.

    Corrige el prototipo embebido anterior, que asumia una base `skills/<nombre>`
    en vez de la convencion real de este repo, `.claude/skills/<nombre>`.
    """
    for candidate in (start, *start.parents):
        if (candidate / ".git").exists():
            return candidate
    raise RuntimeError(f"no se encontro la raiz del repo (.git) subiendo desde {start}")


def resolve_skill_dir(repo_root: Path, skill_name: str) -> Path:
    """Resuelve <repo>/.claude/skills/<skill_name>, rechazando path traversal."""
    if not skill_name or "/" in skill_name or "\\" in skill_name or skill_name in (".", ".."):
        raise ValueError(
            f"nombre de skill invalido: {skill_name!r} "
            "(no debe contener '/', '\\' ni ser '.' o '..')"
        )
    skills_root = (repo_root / ".claude" / "skills").resolve()
    skill_dir = (skills_root / skill_name).resolve()
    if skill_dir.parent != skills_root:
        raise ValueError(f"el nombre de skill resuelve fuera de {skills_root}: {skill_name!r}")
    return skill_dir


TABLE_HEADER_RE = re.compile(r"^\|.*\bReference File\b.*\|[ \t]*$", re.MULTILINE)


def extract_reference_files(content: str) -> list[str]:
    """Extrae las rutas `references/*.md` mencionadas dentro de la Reference Files
    Table (la tabla `| Topic | Reference File | When to Read |`), no de todo el
    archivo - evita falsos positivos/negativos con menciones sueltas en prosa.

    Ancla en la FILA de tabla real (linea que empieza y termina en '|' y contiene
    'Reference File' como columna), no en cualquier mencion de esa frase - un
    heading de seccion como "## Reference Files" (p. ej. convex-skill) contiene
    'Reference File' como substring y NO es la tabla; anclar por substring simple
    hacia esa mencion devolvia una tabla vacia con un `find()` que paraba en el
    heading, antes de llegar a la tabla real dos parrafos despues."""
    match = TABLE_HEADER_RE.search(content)
    if match is None:
        return []
    table_start = match.start()
    rest = content[table_start:]
    end_match = re.search(r"\n[ \t]*\n|\n#{1,6}[ \t]", rest)
    table_block = rest[: end_match.start()] if end_match else rest
    return sorted(set(REFERENCE_FILE_RE.findall(table_block)))


def strip_code_blocks(text: str) -> str:
    """Elimina el contenido de los bloques de codigo fenceados (y las lineas de
    apertura/cierre), preservando el resto tal cual - para que un meta-skill lleno de
    ejemplos (p. ej. un heading "## 10 Commandments" o una entrada de gotcha dentro de
    un fence ```text de ejemplo) no cuente como estructura real.

    Implementa las reglas de fence de CommonMark con una maquina de estados linea a
    linea, no una regex sobre el documento entero (una regex simple sobre "```" pierde
    4+ backticks, `~~~`, indentacion 0-3, un cierre con espacios finales, y un fence sin
    cerrar que debe consumir hasta EOF):
      - apertura: backtick o tilde, longitud >= 3, indentado 0-3 espacios.
      - cierre: el MISMO caracter, longitud >= la de apertura, tambien indentado 0-3,
        tolera espacio en blanco final (pero no texto arbitrario tras el marcador).
      - un fence sin cerrar consume el resto del documento (correcto, no es un bug).
      - CommonMark: el info string de un fence de BACKTICKS no puede contener un
        backtick (p. ej. "```typescript`oops" no es un opener valido) - se rechaza y la
        linea se conserva como contenido normal, para no entrar en un fence fantasma que
        se tragaria todo el documento hasta EOF. Los fences de tilde no tienen esa
        restriccion.
    """
    result: list[str] = []
    in_fence = False
    fence_char = ""
    fence_len = 0
    close_re: re.Pattern[str] | None = None

    for line in text.split("\n"):
        if not in_fence:
            m = _OPEN_FENCE_RE.match(line)
            info_string_has_stray_backtick = (
                bool(m) and m.group(1)[0] == "`" and "`" in line[m.end() :]
            )
            if m and not info_string_has_stray_backtick:
                fence_char = m.group(1)[0]
                fence_len = len(m.group(1))
                close_re = re.compile(r"^ {0,3}" + re.escape(fence_char) + "{" + str(fence_len) + ",}\\s*$")
                in_fence = True
                continue  # la linea de apertura misma no es contenido del documento
            if re.match(r"^(?: {4}|\t)", line):
                continue  # bloque de codigo indentado (ajeno a los fences)
            result.append(line)
        else:
            if close_re is not None and close_re.match(line):
                in_fence = False
            # toda linea mientras in_fence es True se descarta (incluido el propio
            # marcador de cierre); si nunca llega un cierre, el fence - correctamente -
            # consume hasta EOF
    return "\n".join(result)


def _split_body(content: str) -> str:
    """Devuelve el contenido SIN el bloque de frontmatter YAML.

    strip_code_blocks() no toca el frontmatter (no es un fence), asi que una linea de
    un scalar block del `description` como "## Critical Gotchas" o "  ## Quick
    Orientation" se colaria como heading H2 real en el analisis estructural - un falso
    PASS de esa seccion (o, peor, una seccion de gotchas fantasma). Los checks
    estructurales (headings, conteo de gotchas, tabla de referencias) parten SIEMPRE de
    este cuerpo sin frontmatter, nunca del contenido crudo completo. Si el frontmatter
    esta mal formado (FRONTMATTER_RE no matchea), se devuelve el contenido entero - el
    check de frontmatter ya reporta el problema por su lado."""
    match = FRONTMATTER_RE.match(content)
    return content[match.end() :] if match else content


def _extract_h2_lines(structural_content: str) -> list[str]:
    return [m.group(1) for m in H2_LINE_RE.finditer(structural_content)]


def _has_heading(heading_lines: list[str], patterns: list[re.Pattern[str]]) -> bool:
    return any(p.search(line) for line in heading_lines for p in patterns)


def _section_body(structural_content: str, heading_re: re.Pattern[str]) -> str | None:
    """Devuelve el cuerpo (texto) de la PRIMERA seccion H2 cuyo heading matchea
    `heading_re`, desde el final de esa linea de heading hasta el siguiente heading H2
    (o el final del documento). Devuelve None si no existe tal seccion - distinto de
    una seccion vacia (cuerpo == "")."""
    matches = list(H2_LINE_RE.finditer(structural_content))
    for i, m in enumerate(matches):
        if heading_re.search(m.group(1)):
            end = matches[i + 1].start() if i + 1 < len(matches) else len(structural_content)
            return structural_content[m.end() : end]
    return None


def _check_structure(structural_content: str) -> list[Finding]:
    """Los 4 checks de heading requeridos por el Gold Standard, contra el cuerpo
    estructural (sin frontmatter, sin bloques de codigo)."""
    findings: list[Finding] = []
    heading_lines = _extract_h2_lines(structural_content)

    if not _has_heading(heading_lines, QUICK_ORIENTATION_PATTERNS):
        findings.append(
            Finding(
                "heading-quick-orientation",
                "falta la seccion Quick Orientation (o una variante aceptada: "
                "Quick Context, Quick Reference, Info Basica, S1, Quick Start)",
            )
        )
    if not any(GOTCHAS_HEADING_RE.search(line) for line in heading_lines):
        findings.append(
            Finding(
                "heading-gotchas",
                "falta la seccion Critical Gotchas (o la variante Commandments/Antipatterns)",
            )
        )
    if not any(CROSS_SKILL_HEADING_RE.search(line) for line in heading_lines):
        findings.append(Finding("heading-cross-skill", "falta la seccion Cross-Skill Integration"))
    if not _has_heading(heading_lines, NEXT_STEPS_PATTERNS):
        findings.append(
            Finding(
                "heading-next-steps",
                "falta la seccion Next Steps (o una variante aceptada: When to Read "
                "Reference Files, Cuando Leer Archivos de Referencia, Decision "
                "Workflows, Reference Files, Quick Reference: Which File to Read)",
            )
        )
    return findings


def _check_gotchas_count(structural_content: str) -> list[Finding]:
    """Cuenta las entradas de gotchas DENTRO del cuerpo de la seccion de gotchas (no en
    todo el documento - una seccion vacia con numbered-bold en otra seccion, p. ej.
    Workflow, no debe pasar). Si no existe la seccion, no emite nada aqui:
    heading-gotchas ya reporta su ausencia, evitando doble-reporte."""
    body = _section_body(structural_content, GOTCHAS_HEADING_RE)
    if body is None:
        return []

    ap_entries = AP_GOTCHA_RE.findall(body)
    numbered_entries = NUMBERED_GOTCHA_RE.findall(body)
    uses_ap_format = len(ap_entries) > 0
    count = len(ap_entries) if uses_ap_format else len(numbered_entries)
    threshold = MIN_GOTCHAS_AP if uses_ap_format else MIN_GOTCHAS_NUMBERED

    if count < threshold:
        need = f"{MIN_GOTCHAS_AP}+ entradas AP-N" if uses_ap_format else (
            f"{MIN_GOTCHAS_NUMBERED}+ (o el formato antipattern AP-N con {MIN_GOTCHAS_AP}+ entradas)"
        )
        return [Finding("gotchas-count", f"solo {count} gotchas (se necesitan {need})")]
    return []


def validate_skill(skill_dir: Path) -> list[Finding]:
    """Corre los checks del Gold Standard contra un directorio de skill ya resuelto y
    validado. Nunca propaga excepciones: cada rama de fallo (archivo ausente, no
    legible, YAML invalido, estructura incompleta) se captura y se convierte en un
    Finding."""
    findings: list[Finding] = []

    skill_md = skill_dir / "SKILL.md"
    if not skill_md.is_file():
        findings.append(Finding("frontmatter", f"{skill_md} no existe"))
        return findings

    try:
        content = skill_md.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        findings.append(Finding("skill-md-read", f"no se pudo leer {skill_md}: {e}"))
        return findings

    lines = content.splitlines()

    if not content.startswith("---"):
        findings.append(Finding("frontmatter", "SKILL.md no empieza con '---' (sin frontmatter YAML)"))
    else:
        match = FRONTMATTER_RE.match(content)
        if match is None:
            findings.append(Finding("frontmatter", "formato de frontmatter invalido (falta el '---' de cierre)"))
        else:
            frontmatter_text = match.group(1)
            try:
                frontmatter = yaml.safe_load(frontmatter_text)
            except yaml.YAMLError as e:
                findings.append(Finding("yaml", f"YAML invalido en el frontmatter: {e}"))
            else:
                if not isinstance(frontmatter, dict):
                    findings.append(Finding("frontmatter", "el frontmatter debe ser un diccionario YAML"))
                else:
                    name = frontmatter.get("name")
                    if name is None or (isinstance(name, str) and not name.strip()):
                        findings.append(Finding("frontmatter", "falta 'name' en el frontmatter"))
                    elif not isinstance(name, str):
                        findings.append(
                            Finding("frontmatter", f"'name' debe ser string, es {type(name).__name__}")
                        )

                    description = frontmatter.get("description")
                    if description is None or (isinstance(description, str) and not description.strip()):
                        findings.append(Finding("frontmatter", "falta 'description' en el frontmatter"))
                    elif not isinstance(description, str):
                        findings.append(
                            Finding(
                                "frontmatter",
                                f"'description' debe ser string, es {type(description).__name__}",
                            )
                        )
                    else:
                        desc_len = len(description.strip())
                        if desc_len > MAX_DESCRIPTION_LENGTH:
                            findings.append(
                                Finding(
                                    "description-length",
                                    f"description tiene {desc_len} caracteres "
                                    f"(maximo {MAX_DESCRIPTION_LENGTH})",
                                )
                            )

    structural_content = strip_code_blocks(_split_body(content))

    findings.extend(_check_structure(structural_content))
    findings.extend(_check_gotchas_count(structural_content))

    for ref in extract_reference_files(structural_content):
        if not (skill_dir / ref).is_file():
            findings.append(
                Finding("reference-missing", f"la Reference Files Table menciona '{ref}' pero no existe")
            )

    if len(lines) >= MAX_SKILL_MD_LINES:
        findings.append(
            Finding(
                "skill-md-lines",
                f"SKILL.md tiene {len(lines)} lineas (maximo {MAX_SKILL_MD_LINES - 1})",
            )
        )

    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Valida un skill de .claude/skills/<skill-name>/ contra el Gold Standard: "
            "frontmatter (name/description), longitud de description (<=1024 "
            "caracteres), las 4 secciones estructurales requeridas (Quick "
            "Orientation, Critical Gotchas, Cross-Skill Integration, Next Steps - o "
            "sus variantes aceptadas), minimo de entradas de gotchas (10 numeradas o "
            "5 antipattern AP-N), existencia de los reference files listados en la "
            "Reference Files Table, y tamano de SKILL.md (<500 lineas)."
        )
    )
    parser.add_argument("skill_name", help="Nombre del directorio del skill bajo .claude/skills/")
    args = parser.parse_args(argv)

    try:
        repo_root = find_repo_root(Path(__file__).resolve())
        skill_dir = resolve_skill_dir(repo_root, args.skill_name)
    except (RuntimeError, ValueError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1

    if not skill_dir.is_dir():
        print(f"ERROR: directorio de skill no encontrado: {skill_dir}", file=sys.stderr)
        return 1

    findings = validate_skill(skill_dir)
    print("PASS" if not findings else "FAIL")
    for finding in findings:
        print(finding)
    return 0 if not findings else 1


if __name__ == "__main__":
    sys.exit(main())
