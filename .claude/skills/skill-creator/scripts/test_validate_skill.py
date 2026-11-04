#!/usr/bin/env python3
"""Tests deterministicos y hermeticos para validate_skill.py.

Cubre: el parser de fences por maquina de estados (backticks/tildes, indentacion 0-3,
cierre con espacios finales, fence sin cerrar hasta EOF, rechazo de backtick en el info
string de un opener de backticks), el matching exacto de variantes de heading (limites
de linea/palabra, sin cruzar un salto de linea, con indentacion 0-3 tolerada), el
conteo de gotchas por SECCION (no sobre todo el documento), el reparto crudo/estructural
(line-count y frontmatter siempre sobre el contenido crudo; headings y conteo de
gotchas sobre el cuerpo sin frontmatter y sin bloques de codigo), y el contrato
"validate_skill() nunca propaga excepciones" (SKILL.md ausente, bytes no-UTF8, OSError
determinista via mock).

Sin dependencias de red ni de los skills reales del repo: cada test escribe su propio
SKILL.md hermetico en un directorio temporal (tempfile.TemporaryDirectory).

Run:
    python -m unittest test_validate_skill -v
"""
from __future__ import annotations

import contextlib
import io
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import validate_skill as vs  # noqa: E402


DEFAULT_FRONTMATTER = "---\nname: demo-skill\ndescription: A demo skill for testing.\n---\n"


def _numbered_gotchas(n: int) -> str:
    return "\n".join(f"{i}. **Gotcha {i}** -> explicacion" for i in range(1, n + 1)) + "\n"


def _ap_gotchas(n: int) -> str:
    return "".join(f"### ❌ AP-{i}: Titulo\nFix: correccion\nWhy: motivo\n" for i in range(1, n + 1))


_DEFAULT_GOTCHAS_BODY = "## Critical Gotchas\n" + _numbered_gotchas(10)


def _skill_body(
    orientation: str = "## Quick Orientation\ntexto\n",
    gotchas: str = _DEFAULT_GOTCHAS_BODY,
    cross_skill: str = "## Cross-Skill Integration\ntexto\n",
    next_steps: str = "## Next Steps\ntexto\n",
    extra: str = "",
) -> str:
    """Cuerpo de un SKILL.md con las 4 secciones requeridas por defecto (gotchas
    incluye 10 entradas numeradas, suficiente para pasar gotchas-count). Cada
    parametro es sobreescribible; pasar "" quita esa seccion por completo."""
    return orientation + gotchas + cross_skill + next_steps + extra


class SkillWriterTestCase(unittest.TestCase):
    """Base con un directorio temporal hermetico + helpers de escritura/validacion."""

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.root = Path(self._tmpdir.name)

    def _write_skill_md(self, name: str, content: str) -> Path:
        skill_dir = self.root / ".claude" / "skills" / name
        skill_dir.mkdir(parents=True, exist_ok=True)
        (skill_dir / "SKILL.md").write_text(content, encoding="utf-8")
        return skill_dir

    def _validate_body(self, body: str, name: str = "demo-skill") -> list[vs.Finding]:
        content = DEFAULT_FRONTMATTER + "\n" + body
        skill_dir = self._write_skill_md(name, content)
        return vs.validate_skill(skill_dir)

    @staticmethod
    def _categories(findings: list[vs.Finding]) -> list[str]:
        return [f.category for f in findings]


class StripCodeBlocksTest(unittest.TestCase):
    """El parser de fences por maquina de estados, en aislamiento (sin tocar disco)."""

    def test_three_backtick_fence_content_is_stripped(self) -> None:
        text = "## Real\n```text\n## Fake\n```\nafter"
        stripped = vs.strip_code_blocks(text)
        self.assertNotIn("## Fake", stripped)
        self.assertIn("## Real", stripped)
        self.assertIn("after", stripped)

    def test_four_backtick_fence_not_closed_by_three_backticks(self) -> None:
        text = "````text\n## Fake\n```\nstill inside\n````\n## Real"
        stripped = vs.strip_code_blocks(text)
        self.assertNotIn("## Fake", stripped)
        self.assertNotIn("still inside", stripped)
        self.assertIn("## Real", stripped)

    def test_tilde_fence_is_stripped(self) -> None:
        text = "~~~text\n## Fake\n~~~\n## Real"
        stripped = vs.strip_code_blocks(text)
        self.assertNotIn("## Fake", stripped)
        self.assertIn("## Real", stripped)

    def test_tilde_fence_not_closed_by_backticks(self) -> None:
        text = "~~~text\n## Fake\n```\nstill inside\n~~~\n## Real"
        stripped = vs.strip_code_blocks(text)
        self.assertNotIn("## Fake", stripped)
        self.assertNotIn("still inside", stripped)
        self.assertIn("## Real", stripped)

    def test_fence_indented_zero_to_three_spaces_is_a_fence(self) -> None:
        for indent in range(4):
            prefix = " " * indent
            text = f"{prefix}```text\n{prefix}## Fake\n{prefix}```\n## Real"
            with self.subTest(indent=indent):
                stripped = vs.strip_code_blocks(text)
                self.assertNotIn("## Fake", stripped)
                self.assertIn("## Real", stripped)

    def test_four_space_indent_is_not_a_fence_opener(self) -> None:
        text = "    ```text\n    ## Fake\n    ```\n## Real"
        stripped = vs.strip_code_blocks(text)
        self.assertNotIn("## Fake", stripped)
        self.assertIn("## Real", stripped)

    def test_closing_fence_tolerates_trailing_whitespace(self) -> None:
        text = "```text\n## Fake\n```   \n## Real"
        stripped = vs.strip_code_blocks(text)
        self.assertNotIn("## Fake", stripped)
        self.assertIn("## Real", stripped)

    def test_closing_fence_rejects_trailing_text(self) -> None:
        text = "```text\n## Fake\n```bash\nstill inside\n## Real"
        stripped = vs.strip_code_blocks(text)
        self.assertNotIn("## Fake", stripped)
        self.assertNotIn("still inside", stripped)
        self.assertNotIn("## Real", stripped)

    def test_unclosed_fence_consumes_to_eof(self) -> None:
        text = "before\n```text\n## Fake\nmore stuff"
        stripped = vs.strip_code_blocks(text)
        self.assertIn("before", stripped)
        self.assertNotIn("## Fake", stripped)
        self.assertNotIn("more stuff", stripped)

    def test_backtick_opener_with_backtick_in_info_string_is_not_a_fence(self) -> None:
        text = "```typescript`oops\n## Real"
        stripped = vs.strip_code_blocks(text)
        self.assertIn("```typescript`oops", stripped)
        self.assertIn("## Real", stripped)

    def test_tilde_opener_with_backtick_in_info_string_is_a_fence(self) -> None:
        text = "~~~ts`oops\n## Fake\n~~~\n## Real"
        stripped = vs.strip_code_blocks(text)
        self.assertNotIn("## Fake", stripped)
        self.assertIn("## Real", stripped)

    def test_closing_marker_longer_than_opener_closes(self) -> None:
        text = "```text\n## Fake\n`````\n## Real"
        stripped = vs.strip_code_blocks(text)
        self.assertNotIn("## Fake", stripped)
        self.assertIn("## Real", stripped)

    def test_text_without_fences_is_unchanged(self) -> None:
        text = "## A\ntexto\n## B"
        self.assertEqual(vs.strip_code_blocks(text), text)


class HeadingChecksTest(SkillWriterTestCase):
    """Los 4 checks de heading, sus variantes exactas, y los 2 bugs corregidos del
    H2_LINE_RE heredado del prototipo (finding 1a/1b de la auditoria)."""

    def test_s1_heading_satisfies_quick_orientation(self) -> None:
        body = _skill_body(orientation="## S1 — Architecture\ntexto\n")
        cats = self._categories(self._validate_body(body))
        self.assertNotIn("heading-quick-orientation", cats)

    def test_s10_heading_does_not_satisfy_quick_orientation(self) -> None:
        body = _skill_body(orientation="## S10 — Something\ntexto\n")
        cats = self._categories(self._validate_body(body))
        self.assertIn("heading-quick-orientation", cats)

    def test_bare_quick_reference_satisfies_orientation(self) -> None:
        body = _skill_body(orientation="## Quick Reference\ntexto\n")
        cats = self._categories(self._validate_body(body))
        self.assertNotIn("heading-quick-orientation", cats)

    def test_quick_reference_which_file_to_read_is_next_steps_not_orientation(self) -> None:
        # Sin heading de orientation valido: si el patron "Quick Reference" bare
        # matcheara por \b en vez de \s*$, esta variante colonada satisfaria
        # orientation por error y heading-quick-orientation NO aparaceria.
        body = _skill_body(orientation="", next_steps="## Quick Reference: Which File to Read\ntexto\n")
        cats = self._categories(self._validate_body(body))
        self.assertIn("heading-quick-orientation", cats)
        self.assertNotIn("heading-next-steps", cats)

    def test_orientation_variants_accepted(self) -> None:
        variants = [
            "## Quick Orientation\ntexto\n",
            "## Quick Context\ntexto\n",
            "## Info Basica\ntexto\n",
            "## Quick Start\ntexto\n",
            "## 1. Quick Start\ntexto\n",
        ]
        for variant in variants:
            with self.subTest(variant=variant):
                body = _skill_body(orientation=variant)
                cats = self._categories(self._validate_body(body))
                self.assertNotIn("heading-quick-orientation", cats)

    def test_next_steps_variants_accepted(self) -> None:
        variants = [
            "## Next Steps\ntexto\n",
            "## When to Read Reference Files\ntexto\n",
            "## Cuando Leer Archivos de Referencia\ntexto\n",
            "## Decision Workflows\ntexto\n",
            "## 6. Reference Files\ntexto\n",
            "## Reference Files Guide\ntexto\n",
            "## Quick Reference: Which File to Read\ntexto\n",
        ]
        for variant in variants:
            with self.subTest(variant=variant):
                body = _skill_body(next_steps=variant)
                cats = self._categories(self._validate_body(body))
                self.assertNotIn("heading-next-steps", cats)

    def test_h3_heading_does_not_count_as_h2(self) -> None:
        body = _skill_body(orientation="### Quick Orientation\ntexto\n")
        cats = self._categories(self._validate_body(body))
        self.assertIn("heading-quick-orientation", cats)

    def test_headings_inside_code_fence_do_not_count(self) -> None:
        fenced = (
            "```text\n"
            "## Quick Orientation\n"
            "## Critical Gotchas\n"
            "## Cross-Skill Integration\n"
            "## Next Steps\n"
            "```\n"
        )
        cats = self._categories(self._validate_body(fenced))
        self.assertIn("heading-quick-orientation", cats)
        self.assertIn("heading-gotchas", cats)
        self.assertIn("heading-cross-skill", cats)
        self.assertIn("heading-next-steps", cats)
        self.assertNotIn("gotchas-count", cats)  # heading-gotchas ya reporta, sin doble-conteo

    def test_gotchas_heading_variants_accepted(self) -> None:
        variants = [
            "## §3 The 10 Commandments of Convex\ntexto\n",
            "## 5. Android Antipatterns\ntexto\n",
        ]
        for variant in variants:
            with self.subTest(variant=variant):
                body = _skill_body(gotchas=variant)
                cats = self._categories(self._validate_body(body))
                self.assertNotIn("heading-gotchas", cats)

    def test_cross_skill_integration_missing_is_reported(self) -> None:
        body = _skill_body(cross_skill="## Something Unrelated\ntexto\n")
        cats = self._categories(self._validate_body(body))
        self.assertIn("heading-cross-skill", cats)

    def test_complete_skill_md_has_no_findings(self) -> None:
        findings = self._validate_body(_skill_body())
        self.assertEqual(findings, [])

    def test_heading_glued_by_newline_does_not_satisfy_orientation(self) -> None:
        # finding 1a: el prototipo usaba \s+ (cruza \n) -> "##\nQuick Orientation" se
        # extraia como heading fantasma. Una linea "##" sola no tiene "[ \t]" tras el
        # marcador -> no matchea H2_LINE_RE -> el texto siguiente es prosa normal.
        glued = "##\nQuick Orientation\ntexto\n"
        body = glued + _skill_body(orientation="")
        cats = self._categories(self._validate_body(body))
        self.assertIn("heading-quick-orientation", cats)

    def test_heading_indented_one_to_three_spaces_satisfies_orientation(self) -> None:
        # finding 1b: el prototipo anclaba "^##" sin tolerar indentacion -> omitia H2
        # validos de CommonMark con 1-3 espacios iniciales.
        body = "   ## Quick Orientation\ntexto\n" + _skill_body(orientation="")
        cats = self._categories(self._validate_body(body))
        self.assertNotIn("heading-quick-orientation", cats)


class GotchaCountTest(SkillWriterTestCase):
    """El conteo de gotchas, con scope de SECCION (finding 2 de la auditoria) y los
    dos formatos (numbered-bold / AP-N) con sus umbrales distintos."""

    def test_nine_numbered_gotchas_reported(self) -> None:
        body = _skill_body(gotchas="## Critical Gotchas\n" + _numbered_gotchas(9))
        findings = self._validate_body(body)
        match = next(f for f in findings if f.category == "gotchas-count")
        self.assertIn("9", match.message)
        self.assertIn("10", match.message)

    def test_ten_numbered_gotchas_accepted(self) -> None:
        body = _skill_body(gotchas="## Critical Gotchas\n" + _numbered_gotchas(10))
        cats = self._categories(self._validate_body(body))
        self.assertNotIn("gotchas-count", cats)

    def test_five_ap_entries_accepted(self) -> None:
        body = _skill_body(gotchas="## Critical Gotchas (Antipatterns)\n" + _ap_gotchas(5))
        cats = self._categories(self._validate_body(body))
        self.assertNotIn("gotchas-count", cats)

    def test_four_ap_entries_reported(self) -> None:
        body = _skill_body(gotchas="## Antipatterns\n" + _ap_gotchas(4))
        findings = self._validate_body(body)
        match = next(f for f in findings if f.category == "gotchas-count")
        self.assertIn("4", match.message)
        self.assertIn("5+", match.message)

    def test_ap_format_wins_when_both_formats_present(self) -> None:
        mixed = _ap_gotchas(5) + _numbered_gotchas(2)
        body = _skill_body(gotchas="## Antipatterns\n" + mixed)
        cats = self._categories(self._validate_body(body))
        self.assertNotIn("gotchas-count", cats)

    def test_gotchas_inside_code_fence_are_not_counted(self) -> None:
        fenced = "```text\n" + _numbered_gotchas(10) + "```\n"
        body = _skill_body(gotchas="## Critical Gotchas\n" + fenced)
        findings = self._validate_body(body)
        match = next(f for f in findings if f.category == "gotchas-count")
        self.assertIn("0", match.message)

    def test_ap_marker_must_be_h3(self) -> None:
        not_h3 = ("❌ AP-1: Titulo\nFix: x\nWhy: y\n") * 5
        body = _skill_body(gotchas="## Antipatterns\n" + not_h3)
        cats = self._categories(self._validate_body(body))
        self.assertIn("gotchas-count", cats)

    def test_empty_gotchas_section_with_numbered_bold_elsewhere_still_reported(self) -> None:
        # finding 2: el prototipo contaba sobre TODO structural_content, asi que una
        # seccion de gotchas vacia pasaba si OTRA seccion (aqui Workflow) tenia 10+
        # entradas numbered-bold. El conteo debe ser SOLO del cuerpo de la seccion.
        noise = "## Workflow\n" + _numbered_gotchas(10)
        body = noise + _skill_body(gotchas="## Critical Gotchas\n(sin entradas)\n")
        cats = self._categories(self._validate_body(body))
        self.assertIn("gotchas-count", cats)


class RawVsStructuralTest(SkillWriterTestCase):
    """El reparto crudo/estructural: line-count y frontmatter operan SIEMPRE sobre el
    contenido crudo; headings/gotchas/reference-table operan sobre el cuerpo sin
    frontmatter y sin bloques de codigo (finding R2-1 de la auditoria)."""

    def test_line_count_uses_raw_content_including_code_blocks(self) -> None:
        fence_lines = "x\n" * 500
        content = (
            DEFAULT_FRONTMATTER + "\n"
            + "## Quick Orientation\ntexto\n"
            + "```text\n" + fence_lines + "```\n"
            + "## Critical Gotchas\n" + _numbered_gotchas(10)
            + "## Cross-Skill Integration\ntexto\n"
            + "## Next Steps\ntexto\n"
        )
        skill_dir = self._write_skill_md("big-skill", content)
        cats = self._categories(vs.validate_skill(skill_dir))
        self.assertIn("skill-md-lines", cats)

    def test_frontmatter_is_parsed_from_raw_content_even_with_fences_in_body(self) -> None:
        long_desc = "A" * 1100
        content = (
            f"---\nname: x\ndescription: {long_desc}\n---\n\n"
            "## Quick Orientation\n```text\nnoise\n```\n"
        )
        skill_dir = self._write_skill_md("long-desc", content)
        cats = self._categories(vs.validate_skill(skill_dir))
        self.assertIn("description-length", cats)

    def test_reference_table_inside_code_fence_is_ignored(self) -> None:
        fenced_table = (
            "```markdown\n"
            "| Topic | Reference File | When to Read |\n"
            "|---|---|---|\n"
            "| X | `references/no-existe.md` | always |\n"
            "```\n"
        )
        body = _skill_body(extra=fenced_table)
        cats = self._categories(self._validate_body(body))
        self.assertNotIn("reference-missing", cats)

    def test_real_reference_table_outside_fence_still_reported(self) -> None:
        real_table = (
            "| Topic | Reference File | When to Read |\n"
            "|---|---|---|\n"
            "| X | `references/no-existe.md` | always |\n"
        )
        body = _skill_body(extra=real_table)
        cats = self._categories(self._validate_body(body))
        self.assertIn("reference-missing", cats)

    def test_heading_like_line_in_frontmatter_description_does_not_satisfy_headings(self) -> None:
        # finding R2-1: strip_code_blocks no toca el frontmatter, asi que sin excluir
        # su rango ANTES de extraer H2, una linea "## Critical Gotchas" dentro de un
        # scalar block del description se colaria como heading real -> falso PASS.
        content = (
            "---\n"
            "name: demo\n"
            "description: >\n"
            "  Use this skill for X.\n"
            "  ## Critical Gotchas\n"
            "  1. **Foo** rule.\n"
            "---\n\n"
            + _skill_body(gotchas="")
        )
        skill_dir = self._write_skill_md("fm-heading", content)
        cats = self._categories(vs.validate_skill(skill_dir))
        self.assertIn("heading-gotchas", cats)


class ContractTest(SkillWriterTestCase):
    """El contrato de la funcion publica: nunca propaga excepciones, orden estable de
    findings, y el set de categorias documentado en el docstring del modulo."""

    def test_missing_skill_md_returns_single_frontmatter_finding(self) -> None:
        skill_dir = self.root / ".claude" / "skills" / "missing"
        skill_dir.mkdir(parents=True)
        findings = vs.validate_skill(skill_dir)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0].category, "frontmatter")

    def test_validate_skill_never_raises_on_garbage(self) -> None:
        garbage_cases = {
            "empty": "",
            "no_frontmatter": "# just a heading\ntexto\n",
            "broken_yaml": "---\nname: [unclosed\n---\n",
        }
        for label, content in garbage_cases.items():
            with self.subTest(case=label):
                skill_dir = self._write_skill_md(f"garbage-{label}", content)
                try:
                    findings = vs.validate_skill(skill_dir)
                except Exception as e:  # noqa: BLE001 - el contrato es "nunca lanza"
                    self.fail(f"validate_skill raised {e!r} for case {label}")
                self.assertIsInstance(findings, list)

    def test_non_utf8_bytes_are_caught_without_raising(self) -> None:
        skill_dir = self.root / ".claude" / "skills" / "bad-encoding"
        skill_dir.mkdir(parents=True)
        (skill_dir / "SKILL.md").write_bytes(b"\xff\xfe\x00\x01garbage")
        findings = vs.validate_skill(skill_dir)
        self.assertEqual(self._categories(findings), ["skill-md-read"])

    def test_os_error_on_read_is_caught_deterministically(self) -> None:
        # mock.patch.object(Path, "read_text", ...) es determinista; chmod para forzar
        # un permiso denegado NO es fiable bajo un usuario privilegiado (root).
        skill_dir = self._write_skill_md("os-error-skill", DEFAULT_FRONTMATTER + "\n" + _skill_body())
        with mock.patch.object(Path, "read_text", side_effect=OSError("boom")):
            findings = vs.validate_skill(skill_dir)
        self.assertEqual(self._categories(findings), ["skill-md-read"])

    def test_finding_order_is_stable(self) -> None:
        long_desc = "A" * 1100
        ref_table = (
            "| Topic | Reference File | When to Read |\n"
            "|---|---|---|\n"
            "| X | `references/missing.md` | always |\n"
        )
        content = (
            f"---\nname: x\ndescription: {long_desc}\n---\n\n"
            + ref_table
            + ("filler\n" * 500)
        )
        skill_dir = self._write_skill_md("fails-everything", content)
        findings = vs.validate_skill(skill_dir)
        self.assertEqual(
            self._categories(findings),
            [
                "description-length",
                "heading-quick-orientation",
                "heading-gotchas",
                "heading-cross-skill",
                "heading-next-steps",
                "reference-missing",
                "skill-md-lines",
            ],
        )

    def test_main_returns_0_and_prints_pass(self) -> None:
        content = DEFAULT_FRONTMATTER + "\n" + _skill_body()
        self._write_skill_md("pass-skill", content)
        with mock.patch.object(vs, "find_repo_root", return_value=self.root):
            with contextlib.redirect_stdout(io.StringIO()) as out:
                rc = vs.main(["pass-skill"])
        self.assertEqual(rc, 0)
        self.assertTrue(out.getvalue().startswith("PASS"))

    def test_main_returns_1_and_prints_fail(self) -> None:
        skill_dir = self.root / ".claude" / "skills" / "fail-skill"
        skill_dir.mkdir(parents=True)
        with mock.patch.object(vs, "find_repo_root", return_value=self.root):
            with contextlib.redirect_stdout(io.StringIO()) as out:
                rc = vs.main(["fail-skill"])
        self.assertEqual(rc, 1)
        self.assertTrue(out.getvalue().startswith("FAIL"))

    def test_category_names_match_docstring_contract(self) -> None:
        # Escanea el CODIGO FUENTE real (no una lista hardcodeada de un solo lado) -
        # si alguien renombra/agrega/quita una categoria sin actualizar el set
        # documentado, este test lo cachea.
        import inspect

        source = inspect.getsource(vs)
        found = set(re.findall(r'Finding\(\s*"([a-z\-]+)"', source))
        expected = {
            "frontmatter",
            "yaml",
            "description-length",
            "heading-quick-orientation",
            "heading-gotchas",
            "heading-cross-skill",
            "heading-next-steps",
            "gotchas-count",
            "reference-missing",
            "skill-md-lines",
            "skill-md-read",
        }
        self.assertEqual(found, expected)


if __name__ == "__main__":
    unittest.main()
