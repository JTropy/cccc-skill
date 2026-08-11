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

    def test_rejects_unresolved_relative_markdown_link(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(Path(temp_dir), body="[missing](missing.md)\n")
            self.assertIn("does not exist", "\n".join(self.validate(skill_path)))

    def test_rejects_relative_link_that_escapes_skill_root(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            skill_path = self.make_skill(Path(temp_dir), body="[outside](../outside.md)\n")
            self.assertIn("escapes skill root", "\n".join(self.validate(skill_path)))

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
