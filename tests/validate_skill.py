#!/usr/bin/env python3
"""Validate the portable cccc skill package without third-party dependencies."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


ALLOWED_FRONTMATTER_FIELDS = {
    "name",
    "description",
    "license",
    "compatibility",
    "metadata",
    "allowed-tools",
}
KEBAB_CASE = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*$")
TOP_LEVEL_KEY = re.compile(
    r"^(?P<key>[A-Za-z][A-Za-z0-9_-]*|\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^']|'')*')"
    r":(?:[ \t]*(?P<value>.*))?$"
)
MARKDOWN_LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")


def _parse_scalar(value: str) -> str:
    """Return a simple YAML scalar, accepting quoted and unquoted values."""
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def _frontmatter(text: str) -> tuple[dict[str, str], list[str]]:
    """Read the first YAML frontmatter block using only the needed YAML subset."""
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        return {}, ["SKILL.md is missing opening frontmatter"]

    try:
        closing_index = lines.index("---", 1)
    except ValueError:
        return {}, ["SKILL.md is missing closing frontmatter"]

    fields: dict[str, str] = {}
    errors: list[str] = []
    for line in lines[1:closing_index]:
        if not line or line[0].isspace() or line.lstrip().startswith("#"):
            continue
        match = TOP_LEVEL_KEY.match(line)
        if match is None:
            errors.append(f"invalid top-level frontmatter entry: {line}")
            continue
        key = _parse_scalar(match.group("key"))
        value = match.group("value")
        if key not in ALLOWED_FRONTMATTER_FIELDS:
            errors.append(f"unsupported frontmatter field: {key}")
        else:
            fields[key] = _parse_scalar(value or "")
    return fields, errors


def _is_inside(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def _validate_markdown_links(skill_root: Path) -> list[str]:
    errors: list[str] = []
    resolved_root = skill_root.resolve()
    for markdown_file in skill_root.rglob("*.md"):
        try:
            text = markdown_file.read_text(encoding="utf-8")
        except OSError as error:
            errors.append(f"cannot read {markdown_file.name}: {error}")
            continue

        for match in MARKDOWN_LINK.finditer(text):
            target = match.group(1).strip()
            if target.startswith("<") and target.endswith(">"):
                target = target[1:-1].strip()
            target_without_anchor = target.split("#", 1)[0]
            if (
                not target_without_anchor
                or target_without_anchor.lower().startswith(("http://", "https://", "mailto:"))
            ):
                continue

            candidate = (markdown_file.parent / target_without_anchor).resolve()
            display_source = markdown_file.relative_to(skill_root)
            if not _is_inside(candidate, resolved_root):
                errors.append(
                    f"{display_source}: local link {target!r} escapes skill root"
                )
            elif not candidate.exists():
                errors.append(f"{display_source}: local link {target!r} does not exist")
    return errors


def _interface_fields(openai_yaml: str) -> tuple[bool, dict[str, str]]:
    """Parse direct scalar children of the top-level interface mapping."""
    lines = openai_yaml.splitlines()
    interface_index = next(
        (index for index, line in enumerate(lines) if line == "interface:"), None
    )
    if interface_index is None:
        return False, {}

    fields: dict[str, str] = {}
    child_indent: int | None = None
    for line in lines[interface_index + 1 :]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[0].isspace():
            break
        indent = len(line) - len(line.lstrip(" "))
        if child_indent is None:
            child_indent = indent
        if indent != child_indent:
            continue
        match = TOP_LEVEL_KEY.match(line.lstrip(" "))
        if match is not None:
            key = _parse_scalar(match.group("key"))
            value = match.group("value")
            fields[key] = _parse_scalar(value or "")
    return True, fields


def validate_skill(path: Path) -> list[str]:
    """Return structural errors for a skill directory, or an empty list when valid."""
    skill_root = path.resolve()
    errors: list[str] = []
    skill_file = skill_root / "SKILL.md"
    if not skill_file.is_file():
        return ["SKILL.md is missing"]

    try:
        fields, frontmatter_errors = _frontmatter(skill_file.read_text(encoding="utf-8"))
    except OSError as error:
        return [f"cannot read SKILL.md: {error}"]
    errors.extend(frontmatter_errors)

    name = fields.get("name")
    if not name:
        errors.append("frontmatter name is required")
    elif KEBAB_CASE.fullmatch(name) is None:
        errors.append("frontmatter name must use lower kebab-case")
    elif name != skill_root.name:
        errors.append("frontmatter name must match its directory")

    description = fields.get("description")
    if description is None or not 1 <= len(description) <= 1024:
        errors.append("frontmatter description length must be 1..1024 characters")

    errors.extend(_validate_markdown_links(skill_root))

    openai_file = skill_root / "agents" / "openai.yaml"
    if not openai_file.is_file():
        errors.append("agents/openai.yaml is missing")
        return errors
    try:
        has_interface, interface = _interface_fields(
            openai_file.read_text(encoding="utf-8")
        )
    except OSError as error:
        errors.append(f"cannot read agents/openai.yaml: {error}")
        return errors

    if not has_interface:
        errors.append("agents/openai.yaml is missing interface mapping")
    for field in ("display_name", "short_description", "default_prompt"):
        if not interface.get(field):
            errors.append(f"agents/openai.yaml is missing interface.{field}")
    default_prompt = interface.get("default_prompt", "")
    if default_prompt and "$cccc" not in default_prompt:
        errors.append("interface.default_prompt must contain $cccc")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate a skill directory")
    parser.add_argument("path", type=Path, help="skill directory")
    args = parser.parse_args()

    errors = validate_skill(args.path)
    if errors:
        for error in errors:
            print(f"{args.path}: {error}", file=sys.stderr)
        return 1
    print(f"{args.path}: valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
