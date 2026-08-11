from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
import re
from pathlib import Path

try:
    from tests.validate_skill import validate_skill
except ImportError:
    validate_skill = None


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
CANONICAL_SKILL = REPOSITORY_ROOT / "skills" / "cccc"
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

    def canonical_text(self, relative: str = "SKILL.md") -> str:
        path = CANONICAL_SKILL / relative
        self.assertTrue(path.is_file(), f"missing canonical file: {relative}")
        return path.read_text(encoding="utf-8")

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
        self.assertEqual([], self.validate(CANONICAL_SKILL))

    def test_repository_skill_is_a_concise_progressive_router(self) -> None:
        text = self.canonical_text()
        self.assertLessEqual(len(text.splitlines()), 500)
        description = re.search(r"^description:\s*(.+)$", text, re.MULTILINE)
        self.assertIsNotNone(description)
        self.assertLessEqual(len(description.group(1)), 1024)
        self.assertTrue(description.group(1).startswith("Use when"))
        for reference in ("delegate.md", "consult.md", "setup.md", "troubleshooting.md"):
            self.assertIn(f"references/{reference}", text)
            self.assertTrue((CANONICAL_SKILL / "references" / reference).is_file())

    def test_repository_skill_requires_explicit_authorization_or_confirmation(self) -> None:
        text = self.canonical_text().lower()
        self.assertIn("explicit request", text)
        self.assertIn("bare `delegate` or `consult`", text)
        self.assertRegex(text, r"bare `delegate` or `consult`[\s\S]{0,180}not launch authorization")
        self.assertRegex(text, r"heuristic[\s\S]{0,300}confirm")
        self.assertIn("external cli", text)
        self.assertRegex(text, r"user[\s\S]{0,200}prohibit")
        self.assertRegex(text, r"project[\s\S]{0,200}prohibit")
        self.assertIn("do not launch", text)

    def test_repository_skill_routes_only_to_a_verified_peer(self) -> None:
        text = self.canonical_text().lower()
        self.assertIn(
            "user instruction > project rules > verified local capability > heuristic",
            text,
        )
        self.assertIn("codex orchestrator targets claude", text)
        self.assertIn("claude code orchestrator targets codex", text)
        self.assertIn("never target itself", text)
        self.assertIn("verify", text)
        self.assertIn("$imagegen", text)
        self.assertIn("do not promise image generation", text)

    def test_canonical_docs_contain_no_unsafe_claims_or_git_mutation_instructions(self) -> None:
        markdown = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(CANONICAL_SKILL.rglob("*.md"))
        )
        for forbidden in (
            "latest GPT",
            "成本不设限",
            "机制级",
            "mechanism-level read-only",
            "guaranteed consensus",
            "writes are impossible",
        ):
            self.assertNotIn(forbidden.lower(), markdown.lower())
        self.assertIsNone(
            re.search(r"\bgit\s+(?:commit|stash|reset|clean|push)\b", markdown, re.IGNORECASE)
        )

    def test_delegate_reference_states_audit_boundary_modes_and_success_contract(self) -> None:
        text = self.canonical_text("references/delegate.md")
        lower = text.lower()
        for required in (
            "tracked",
            "non-ignored untracked",
            "git metadata",
            "git-ignored",
            "not an os sandbox",
            "cccc_allow_dirty=1",
            "cccc_allow_full=1",
            "edit",
            "auto",
            "full",
            "exit status 0",
        ):
            self.assertIn(required, lower)
        self.assertIn("../assets/task-card.md", text)
        self.assertIn("scripts/delegate.sh", text)
        self.assertIn("for codex", lower)
        self.assertIn("network_access=false", lower)
        self.assertRegex(lower, r"claude[\s\S]{0,180}does not establish network isolation")

    def test_consult_reference_states_real_boundary_and_codex_has_no_add_dir(self) -> None:
        text = self.canonical_text("references/consult.md")
        lower = text.lower()
        for required in (
            "strict",
            "inherit",
            "private cwd",
            "absolute repository path",
            "not an os sandbox",
            "same-uid",
            "not guaranteed",
            "globally readable",
            "external container",
            "isolated worktree",
            "exit status 0",
        ):
            self.assertIn(required, lower)
        self.assertNotIn("--add-dir", text)
        self.assertIn("../assets/discussion-card.md", text)
        self.assertIn("scripts/consult.sh", text)

        design = (REPOSITORY_ROOT / "docs/superpowers/specs/2026-08-11-cccc-v2-design.md").read_text(encoding="utf-8")
        design_consult = design.split("## consult 设计", 1)[1].split("## 超时与进程清理", 1)[0]
        plan = (REPOSITORY_ROOT / "docs/superpowers/plans/2026-08-11-cccc-v2.md").read_text(encoding="utf-8")
        plan_consult = plan.split("## Task 5:", 1)[1].split("## Task 6:", 1)[0]
        self.assertNotIn("--add-dir", design_consult)
        self.assertNotIn("--add-dir", plan_consult)

    def test_setup_and_troubleshooting_cover_required_operations_without_secrets(self) -> None:
        setup = self.canonical_text("references/setup.md")
        for required in (
            "codex login status",
            "codex login --with-api-key",
            "claude auth status",
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "~/.claude/skills/cccc",
            "~/.agents/skills/cccc",
            "~/.codex/skills/cccc",
            "Junction",
            "rollback",
        ):
            self.assertIn(required, setup)
        self.assertRegex(setup, r"(?m)^.*\|\s*codex login --with-api-key\s*$")
        self.assertIn("Windows CI must pass before release", setup)
        self.assertNotIn("is verified by the repository's Windows CI", setup)
        troubleshooting = self.canonical_text("references/troubleshooting.md").lower()
        for required in (
            "124",
            "python",
            "authentication",
            "model",
            "effort",
            "output collision",
            "policy failure",
            "legacy path",
        ):
            self.assertIn(required, troubleshooting)
        self.assertRegex(troubleshooting, r"\| `5` \|[^\n]*(?:empty|unsafe)")
        self.assertRegex(troubleshooting, r"\| `70` \|[^\n]*peer[^\n]*(?:exit|signal)")

    def test_legacy_root_skill_entrypoints_are_removed(self) -> None:
        for legacy in ("SKILL.md", "agents/openai.yaml", "references/setup.md"):
            self.assertFalse((REPOSITORY_ROOT / legacy).exists(), legacy)
        metadata = self.canonical_text("agents/openai.yaml")
        self.assertNotIn("allow_implicit_invocation: false", metadata)
        self.assertIn("$cccc", metadata)

    def test_repository_line_endings_are_portable(self) -> None:
        attributes = (REPOSITORY_ROOT / ".gitattributes").read_text(encoding="utf-8")
        self.assertIn("* text=auto", attributes)
        self.assertIn("*.sh text eol=lf", attributes)
        self.assertIn("*.py text eol=lf", attributes)

    def test_ci_runs_the_complete_cross_platform_suite(self) -> None:
        workflow_path = REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml"
        self.assertTrue(workflow_path.is_file())
        workflow = workflow_path.read_text(encoding="utf-8")
        for runner in ("ubuntu-latest", "macos-latest", "windows-latest"):
            self.assertIn(runner, workflow)
        for command in (
            "unittest discover -s tests -p 'test_*.py' -v",
            "bash tests/test_common.sh",
            "bash tests/test_delegate.sh",
            "bash tests/test_consult.sh",
        ):
            self.assertIn(command, workflow)
        self.assertRegex(workflow, r"(?m)^\s*shell:\s*bash\s*$")
        self.assertIn("CCCC_REQUIRE_WINDOWS_NATIVE", workflow)
        self.assertIn("actions/checkout@", workflow)
        self.assertIn("actions/setup-python@", workflow)
        self.assertNotRegex(workflow, r"(?m)^\s*(?:pip|pip3|uv)\s+install\b")

        for shell_suite in ("test_delegate.sh", "test_consult.sh"):
            suite = (REPOSITORY_ROOT / "tests" / shell_suite).read_text(encoding="utf-8")
            self.assertIn("CCCC_REQUIRE_WINDOWS_NATIVE", suite)

    def test_readme_uses_canonical_install_and_safe_migration(self) -> None:
        readme = (REPOSITORY_ROOT / "README.md").read_text(encoding="utf-8")
        lower = readme.lower()
        for required in (
            "skills/cccc",
            "~/.agents/skills/cccc",
            "~/.claude/skills/cccc",
            "junction",
            "rollback",
            "uninstall",
            "restart",
            "fallback",
        ):
            self.assertIn(required, lower)
        self.assertRegex(lower, r"~/.codex/skills/cccc[\s\S]{0,120}legacy")
        self.assertIn("git clone", lower)
        self.assertGreaterEqual(lower.count("new-item -itemtype junction"), 2)
        self.assertRegex(lower, r"restart[\s\S]{0,120}fallback|fallback[\s\S]{0,120}restart")
        self.assertRegex(lower, r"uninstall[\s\S]{0,500}(?:keep|preserve|do not delete)")
        update = lower.split("## update, rollback, and uninstall", 1)[1]
        self.assertNotIn("pull --ff-only", update)
        self.assertIn("candidate", update)
        self.assertIn("readlink", update)
        self.assertIn(".rollback", update)
        self.assertRegex(update, r"candidate[\s\S]+validate[\s\S]+switch")
        self.assertRegex(update, r"validation fails[\s\S]+(?:keep|preserve)")
        update_script = update.split("```bash", 1)[1].split("```", 1)[0]
        self.assertIn("set -eu", update_script)
        self.assertLess(update_script.index("set -eu"), update_script.index("validate_skill.py"))
        self.assertRegex(update_script, r"release_id=.*(?:date|\$\$)")
        self.assertRegex(update_script, r"candidate=.*\$release_id")
        self.assertIn("recover_switch", update_script)
        self.assertIn("trap 'recover_switch $?' exit", update_script)
        self.assertLess(
            update_script.index("trap 'recover_switch $?' exit"),
            update_script.index('mv "$codex_live" "$codex_backup"'),
        )
        self.assertNotIn('candidate="$base/cccc-skill.candidate"', update_script)
        for reference in ("delegate", "consult", "setup", "troubleshooting"):
            self.assertIn(f"skills/cccc/references/{reference}.md", readme)
        for forbidden in (
            "latest GPT",
            "成本不设限",
            "机制级",
            "writes are impossible",
            "guaranteed consensus",
        ):
            self.assertNotIn(forbidden.lower(), lower)

    @unittest.skipIf(os.name == "nt", "requires POSIX symlink semantics")
    def test_readme_update_recovers_signal_after_completed_link_move(self) -> None:
        readme = (REPOSITORY_ROOT / "README.md").read_text(encoding="utf-8")
        update = readme.split("## Update, rollback, and uninstall", 1)[1]
        script = update.split("```bash", 1)[1].split("```", 1)[0]
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            home = root / "home"
            data = root / "data"
            fake_bin = root / "bin"
            marker = root / "mv-signaled"
            codex_live = home / ".agents" / "skills" / "cccc"
            claude_live = home / ".claude" / "skills" / "cccc"
            old_codex = root / "old-codex" / "skills" / "cccc"
            old_claude = root / "old-claude" / "skills" / "cccc"
            for path in (codex_live.parent, claude_live.parent, old_codex, old_claude, data, fake_bin):
                path.mkdir(parents=True, exist_ok=True)
            codex_live.symlink_to(old_codex)
            claude_live.symlink_to(old_claude)
            (root / "update.sh").write_text(script, encoding="utf-8")
            (fake_bin / "git").write_text(
                "#!/usr/bin/env bash\nset -eu\n"
                "[ \"$1\" = clone ]\nmkdir -p \"$3/skills/cccc\" \"$3/tests\"\n",
                encoding="utf-8",
            )
            (fake_bin / "python3").write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            (fake_bin / "mv").write_text(
                "#!/usr/bin/env bash\nset -eu\n/bin/mv \"$@\"\n"
                "if [ ! -e \"$CCCC_MV_SIGNAL_MARKER\" ]; then\n"
                "  : >\"$CCCC_MV_SIGNAL_MARKER\"\n"
                "  kill -HUP \"$PPID\"\n"
                "fi\n",
                encoding="utf-8",
            )
            for executable in (fake_bin / "git", fake_bin / "python3", fake_bin / "mv"):
                executable.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                HOME=str(home),
                XDG_DATA_HOME=str(data),
                CCCC_MV_SIGNAL_MARKER=str(marker),
                PATH=f"{fake_bin}:/usr/bin:/bin",
            )
            result = subprocess.run(
                ["bash", str(root / "update.sh")],
                capture_output=True,
                text=True,
                env=environment,
                timeout=10,
            )
            self.assertEqual(129, result.returncode, result.stderr)
            self.assertTrue(marker.is_file(), "mv signal injection did not fire")
            self.assertTrue(codex_live.is_symlink(), "Codex live link was not restored")
            self.assertTrue(claude_live.is_symlink(), "Claude live link was not preserved")
            self.assertEqual(old_codex.resolve(), codex_live.resolve())
            self.assertEqual(old_claude.resolve(), claude_live.resolve())

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
