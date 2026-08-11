from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

try:
    from tests.validate_skill import validate_skill
except ImportError:
    validate_skill = None


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
VALID_OPENAI_YAML = '''\
interface:
  display_name: "cccc Peer Collaboration"
  short_description: "Delegate work or request a read-only peer review"
  default_prompt: "Use $cccc to route this task to the appropriate local peer agent."
'''


class ValidateSkillTests(unittest.TestCase):
    def validate(self, skill_path: Path) -> list[str]:
        self.assertIsNotNone(validate_skill, "the skill validator must be implemented")
        return validate_skill(skill_path)

    def make_skill(
        self,
        root: Path,
        *,
        directory: str = "cccc",
        frontmatter: str | None = None,
        body: str = "# cccc\n",
        openai_yaml: str = VALID_OPENAI_YAML,
    ) -> Path:
        skill_path = root / directory
        (skill_path / "agents").mkdir(parents=True)
        (skill_path / "SKILL.md").write_text(
            frontmatter
            if frontmatter is not None
            else "---\nname: cccc\ndescription: Valid description\n---\n" + body,
            encoding="utf-8",
        )
        (skill_path / "agents" / "openai.yaml").write_text(openai_yaml, encoding="utf-8")
        return skill_path

    def test_repository_skill_is_valid(self) -> None:
        self.assertEqual([], self.validate(REPOSITORY_ROOT / "skills" / "cccc"))

    def test_name_must_match_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(
                Path(temp_dir),
                frontmatter="---\nname: another-skill\ndescription: Valid description\n---\n",
            )
            self.assertIn("name must match its directory", "\n".join(self.validate(skill_path)))

    def test_rejects_unsupported_private_frontmatter(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(
                Path(temp_dir),
                frontmatter=(
                    "---\nname: cccc\ndescription: Valid description\n"
                    "disable-model-invocation: true\n---\n"
                ),
            )
            self.assertIn("unsupported frontmatter field", "\n".join(self.validate(skill_path)))

    def test_rejects_quoted_unsupported_private_frontmatter(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(
                Path(temp_dir),
                frontmatter=(
                    "---\nname: cccc\ndescription: Valid description\n"
                    '"disable-model-invocation": true\n---\n'
                ),
            )
            self.assertIn("unsupported frontmatter field", "\n".join(self.validate(skill_path)))

    def test_rejects_missing_frontmatter(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(Path(temp_dir), frontmatter="# cccc\n")
            self.assertIn("frontmatter", "\n".join(self.validate(skill_path)))

    def test_rejects_invalid_kebab_case_name(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(
                Path(temp_dir),
                directory="Invalid_Name",
                frontmatter="---\nname: Invalid_Name\ndescription: Valid description\n---\n",
            )
            self.assertIn("lower kebab-case", "\n".join(self.validate(skill_path)))

    def test_rejects_description_longer_than_1024_characters(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(
                Path(temp_dir),
                frontmatter="---\nname: cccc\ndescription: " + "x" * 1025 + "\n---\n",
            )
            self.assertIn("1..1024", "\n".join(self.validate(skill_path)))

    def test_accepts_description_at_exact_length_boundaries(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            shortest = self.make_skill(
                root / "shortest",
                frontmatter="---\nname: cccc\ndescription: x\n---\n",
            )
            longest = self.make_skill(
                root / "longest",
                directory="cccc-longest",
                frontmatter=(
                    "---\nname: cccc-longest\ndescription: " + "x" * 1024 + "\n---\n"
                ),
            )
            self.assertEqual([], self.validate(shortest))
            self.assertEqual([], self.validate(longest))

    def test_rejects_non_string_frontmatter_scalars(self) -> None:
        invalid_values = ("null", "true", "[cccc]", "{name: cccc}", "|", "&alias cccc")
        for field in ("name", "description"):
            for value in invalid_values:
                with self.subTest(field=field, value=value), tempfile.TemporaryDirectory() as temp_dir:
                    other_field = "description: Valid description" if field == "name" else "name: cccc"
                    skill_path = self.make_skill(
                        Path(temp_dir),
                        frontmatter=f"---\n{other_field}\n{field}: {value}\n---\n",
                    )
                    self.assertIn("single-line string scalar", "\n".join(self.validate(skill_path)))

    def test_rejects_malformed_quoted_frontmatter_scalar(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(
                Path(temp_dir),
                frontmatter='---\nname: cccc\ndescription: "unclosed\n---\n',
            )
            self.assertIn("single-line string scalar", "\n".join(self.validate(skill_path)))

    def test_rejects_non_string_interface_scalars(self) -> None:
        for field, value in (
            ("display_name", "true"),
            ("short_description", "[Route work]"),
            ("default_prompt", "!tag route"),
        ):
            with self.subTest(field=field, value=value), tempfile.TemporaryDirectory() as temp_dir:
                interface_values = {
                    "display_name": "cccc",
                    "short_description": "Route work",
                    "default_prompt": "Use $cccc to route this task.",
                }
                interface_values[field] = value
                skill_path = self.make_skill(
                    Path(temp_dir),
                    openai_yaml=(
                        "interface:\n"
                        f"  display_name: {interface_values['display_name']}\n"
                        f"  short_description: {interface_values['short_description']}\n"
                        f"  default_prompt: {interface_values['default_prompt']}\n"
                    ),
                )
                self.assertIn("single-line string scalar", "\n".join(self.validate(skill_path)))

    def test_ignores_skill_reference_inside_plain_yaml_comment(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(
                Path(temp_dir),
                openai_yaml=(
                    "interface:\n"
                    "  display_name: cccc\n"
                    "  short_description: Route work\n"
                    "  default_prompt: Route work # mention $cccc only in comment\n"
                ),
            )
            self.assertIn("must contain $cccc", "\n".join(self.validate(skill_path)))

    def test_rejects_description_that_is_only_a_plain_yaml_comment(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(
                Path(temp_dir),
                frontmatter="---\nname: cccc\ndescription: # comment only\n---\n",
            )
            self.assertIn("1..1024", "\n".join(self.validate(skill_path)))

    def test_rejects_default_prompt_that_is_only_a_plain_yaml_comment(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(
                Path(temp_dir),
                openai_yaml=(
                    "interface:\n"
                    "  display_name: cccc\n"
                    "  short_description: Route work\n"
                    "  default_prompt: # $cccc only in comment\n"
                ),
            )
            self.assertIn("interface.default_prompt", "\n".join(self.validate(skill_path)))

    def test_rejects_other_non_string_plain_scalars(self) -> None:
        invalid_values = (
            "0x10",
            "0o10",
            "0b10",
            ".inf",
            ".NaN",
            "- a-list-item",
            "? a-mapping-key",
            ": a-mapping-value",
            "nested: mapping",
        )
        for value in invalid_values:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as temp_dir:
                skill_path = self.make_skill(
                    Path(temp_dir),
                    frontmatter=f"---\nname: cccc\ndescription: {value}\n---\n",
                )
                self.assertIn("single-line string scalar", "\n".join(self.validate(skill_path)))

    def test_accepts_plain_scalar_with_literal_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(
                Path(temp_dir),
                frontmatter="---\nname: cccc\ndescription: C# skill\n---\n",
            )
            self.assertEqual([], self.validate(skill_path))

    def test_accepts_nested_metadata_keys(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(
                Path(temp_dir),
                frontmatter=(
                    "---\nname: cccc\ndescription: Valid description\nmetadata:\n"
                    "  private_key: allowed-as-metadata\n---\n"
                ),
            )
            self.assertEqual([], self.validate(skill_path))

    def test_rejects_unresolved_relative_markdown_link(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(Path(temp_dir), body="[missing](missing.md)\n")
            self.assertIn("does not exist", "\n".join(self.validate(skill_path)))

    def test_rejects_relative_link_that_escapes_skill_root(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(Path(temp_dir), body="[outside](../outside.md)\n")
            self.assertIn("escapes skill root", "\n".join(self.validate(skill_path)))

    def test_accepts_local_markdown_links_with_titles_parentheses_and_anchors(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(
                Path(temp_dir),
                body=(
                    '[titled](guide.md "A guide")\n'
                    '[parenthesized](reference (v2).md)\n'
                    '[anchor](guide.md#section)\n'
                ),
            )
            (skill_path / "guide.md").write_text("# Guide\n", encoding="utf-8")
            (skill_path / "reference (v2).md").write_text("# Reference\n", encoding="utf-8")
            self.assertEqual([], self.validate(skill_path))

    def test_checks_local_markdown_destination_with_apostrophe(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(Path(temp_dir), body="[missing](missing's.md)\n")
            self.assertIn("does not exist", "\n".join(self.validate(skill_path)))

    def test_ignores_only_odd_backslash_escaped_markdown_openers(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(
                Path(temp_dir),
                body="\\[ignored](missing.md)\n\\\\[checked](checked.md)\n",
            )
            (skill_path / "checked.md").write_text("# Checked\n", encoding="utf-8")
            self.assertEqual([], self.validate(skill_path))

    def test_ignores_arbitrary_external_markdown_uri_schemes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(
                Path(temp_dir),
                body=(
                    "[ftp](ftp://example.com/skill)\n"
                    "[custom](peer+agent://example/task)\n"
                    "[protocol-relative](//cdn.example.com/skill)\n"
                ),
            )
            self.assertEqual([], self.validate(skill_path))

    def test_reports_invalid_utf8_in_skill_markdown(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(Path(temp_dir))
            (skill_path / "SKILL.md").write_bytes(b"\xff")
            self.assertIn("cannot read SKILL.md", "\n".join(self.validate(skill_path)))

    def test_reports_invalid_utf8_in_referenced_markdown(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(Path(temp_dir), body="[notes](notes.md)\n")
            (skill_path / "notes.md").write_bytes(b"\xff")
            self.assertIn("cannot read notes.md", "\n".join(self.validate(skill_path)))

    def test_reports_invalid_utf8_in_openai_yaml(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(Path(temp_dir))
            (skill_path / "agents" / "openai.yaml").write_bytes(b"\xff")
            self.assertIn(
                "cannot read agents/openai.yaml", "\n".join(self.validate(skill_path))
            )

    def test_rejects_missing_default_prompt(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(
                Path(temp_dir),
                openai_yaml=(
                    "interface:\n"
                    "  display_name: cccc\n"
                    "  short_description: Route work\n"
                ),
            )
            self.assertIn("interface.default_prompt", "\n".join(self.validate(skill_path)))

    def test_rejects_missing_interface_mapping(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(
                Path(temp_dir),
                openai_yaml="display_name: cccc\nshort_description: Route work\n",
            )
            self.assertIn(
                "agents/openai.yaml is missing interface mapping",
                "\n".join(self.validate(skill_path)),
            )

    def test_rejects_default_prompt_without_skill_reference(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(
                Path(temp_dir),
                openai_yaml=(
                    "interface:\n"
                    "  display_name: cccc\n"
                    "  short_description: Route work\n"
                    "  default_prompt: Route this task to a peer.\n"
                ),
            )
            self.assertIn("$cccc", "\n".join(self.validate(skill_path)))


if __name__ == "__main__":
    unittest.main()
