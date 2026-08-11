#!/usr/bin/env python3
"""Validate the portable cccc skill package without third-party dependencies."""

from __future__ import annotations

import argparse
import json
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
URI_SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
NON_STRING_SCALARS = {"~", "null", "true", "false", "yes", "no", "on", "off"}
NUMERIC_SCALAR = re.compile(
    r"[-+]?(?:[0-9][0-9_]*)(?:\.[0-9_]*)?(?:[eE][-+]?[0-9_]+)?$"
)
BASE_NUMBER_SCALAR = re.compile(r"[-+]?0(?:x[0-9a-f_]+|o[0-7_]+|b[01_]+)$", re.IGNORECASE)
SPECIAL_FLOAT_SCALAR = re.compile(r"[-+]?\.(?:inf|nan)$", re.IGNORECASE)
REQUIRED_INTERFACE_FIELDS = ("display_name", "short_description", "default_prompt")


def _parse_scalar(value: str) -> str:
    """Return an optionally quoted YAML key scalar."""
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def _strip_plain_scalar_comment(value: str) -> str:
    """Remove a YAML comment marker only when whitespace precedes it."""
    for index, character in enumerate(value):
        if character == "#" and (index == 0 or value[index - 1].isspace()):
            return value[:index].rstrip()
    return value


def _parse_string_scalar(value: str) -> str | None:
    """Accept only the single-line YAML scalar forms that resolve to strings."""
    value = value.strip()
    if not value:
        return ""
    if value.startswith('"'):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            return None
        return parsed if isinstance(parsed, str) else None
    if value.startswith("'"):
        if not value.endswith("'"):
            return None
        content = value[1:-1]
        if "'" in content.replace("''", ""):
            return None
        return content.replace("''", "'")
    value = _strip_plain_scalar_comment(value)
    if not value:
        return ""
    if value.endswith(("'", '"')):
        return None
    if (
        value[0] in "|>[{&*!,"
        or (value[0] in "-?:" and (len(value) == 1 or value[1].isspace()))
        or ": " in value
        or value.lower() in NON_STRING_SCALARS
        or NUMERIC_SCALAR.fullmatch(value) is not None
        or BASE_NUMBER_SCALAR.fullmatch(value) is not None
        or SPECIAL_FLOAT_SCALAR.fullmatch(value) is not None
    ):
        return None
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
        elif key in {"name", "description"}:
            parsed_value = _parse_string_scalar(value or "")
            if parsed_value is None:
                errors.append(
                    f"frontmatter {key} must be a valid single-line string scalar"
                )
            else:
                fields[key] = parsed_value
        else:
            fields[key] = value or ""
    return fields, errors


def _is_inside(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def _link_destination(contents: str) -> str:
    """Extract a Markdown link destination, excluding any optional title."""
    contents = contents.strip()
    if contents.startswith("<"):
        closing_index = contents.find(">", 1)
        if closing_index != -1:
            return contents[1:closing_index].strip()
    title_match = re.match(
        r"^(?P<destination>.+?)\s+(?:\"(?:[^\"\\]|\\.)*\"|'(?:[^']|'')*')\s*$",
        contents,
    )
    if title_match is not None:
        return title_match.group("destination")
    return contents


def _markdown_destinations(text: str) -> list[str]:
    """Extract Markdown link destinations with balanced parentheses."""
    destinations: list[str] = []
    index = 0
    while True:
        opening_index = text.find("[", index)
        if opening_index == -1:
            return destinations
        backslashes = 0
        for backslash_index in range(opening_index - 1, -1, -1):
            if text[backslash_index] != "\\":
                break
            backslashes += 1
        if backslashes % 2 == 1:
            index = opening_index + 1
            continue
        label_end = text.find("](", opening_index + 1)
        if label_end == -1:
            return destinations

        depth = 1
        quoted: str | None = None
        escaped = False
        contents_start = label_end + 2
        for closing_index in range(contents_start, len(text)):
            character = text[closing_index]
            if escaped:
                escaped = False
                continue
            if character == "\\":
                escaped = True
                continue
            if quoted is not None:
                if character == quoted:
                    quoted = None
                continue
            if (
                character in {"'", '"'}
                and depth == 1
                and closing_index > contents_start
                and text[closing_index - 1].isspace()
            ):
                quoted = character
            elif character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
                if depth == 0:
                    destinations.append(
                        _link_destination(text[contents_start:closing_index])
                    )
                    index = closing_index + 1
                    break
        else:
            index = contents_start


def _validate_markdown_links(skill_root: Path) -> list[str]:
    errors: list[str] = []
    resolved_root = skill_root.resolve()
    for markdown_file in skill_root.rglob("*.md"):
        try:
            text = markdown_file.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            errors.append(f"cannot read {markdown_file.name}: {error}")
            continue

        for target in _markdown_destinations(text):
            target_without_anchor = target.split("#", 1)[0]
            if (
                not target_without_anchor
                or target_without_anchor.startswith("//")
                or URI_SCHEME.match(target_without_anchor) is not None
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


def _interface_fields(openai_yaml: str) -> tuple[bool, dict[str, str], list[str]]:
    """Parse direct scalar children of the top-level interface mapping."""
    lines = openai_yaml.splitlines()
    interface_index = next(
        (index for index, line in enumerate(lines) if line == "interface:"), None
    )
    if interface_index is None:
        return False, {}, []

    fields: dict[str, str] = {}
    errors: list[str] = []
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
            if key in REQUIRED_INTERFACE_FIELDS:
                parsed_value = _parse_string_scalar(value or "")
                if parsed_value is None:
                    errors.append(
                        "agents/openai.yaml interface."
                        f"{key} must be a valid single-line string scalar"
                    )
                else:
                    fields[key] = parsed_value
            else:
                fields[key] = value or ""
    return True, fields, errors


def validate_skill(path: Path) -> list[str]:
    """Return structural errors for a skill directory, or an empty list when valid."""
    skill_root = path.resolve()
    errors: list[str] = []
    skill_file = skill_root / "SKILL.md"
    if not skill_file.is_file():
        return ["SKILL.md is missing"]

    try:
        fields, frontmatter_errors = _frontmatter(skill_file.read_text(encoding="utf-8"))
    except (OSError, UnicodeError) as error:
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
        has_interface, interface, interface_errors = _interface_fields(
            openai_file.read_text(encoding="utf-8")
        )
    except (OSError, UnicodeError) as error:
        errors.append(f"cannot read agents/openai.yaml: {error}")
        return errors

    if not has_interface:
        errors.append("agents/openai.yaml is missing interface mapping")
    errors.extend(interface_errors)
    for field in REQUIRED_INTERFACE_FIELDS:
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
