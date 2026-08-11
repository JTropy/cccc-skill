# cccc — Claude Code × Codex peer collaboration

`cccc` lets a local Claude Code CLI and Codex CLI act as bounded peers while the current agent remains the orchestrator. It has two channels:

| Channel | Use | Published artifacts |
|---|---|---|
| `delegate` | Scoped repository implementation inside card-defined paths | report and audit log |
| `consult` | Independent analysis or critique without authorizing implementation | opinion and audit log |

The wrappers provide no-clobber publication, process timeouts, repository serialization, and before/after Git-visible audits. They are not an operating-system sandbox. Git metadata, ignored paths, same-user readable files, secrets, and intentionally detached processes remain outside parts of this boundary. Wrapper exit status `0`—not the mere presence of an artifact—is the success signal.

Skill discovery is not permission to launch another CLI. A launch requires an explicit cccc/4C or local-peer request, or confirmation after the orchestrator suggests a peer handoff.

## Requirements

- Git, Bash 3.2+, and Python 3
- `claude` and `codex` available on `PATH`
- usable authentication for the selected peer CLI
- a Git repository containing a task or discussion card
- Git Bash on Windows

Model, effort, provider, network, and `$imagegen` availability are capabilities to verify, not guarantees made by this skill.

## Install on macOS or Linux

Keep one stable checkout and link only its canonical `skills/cccc` directory into both hosts:

```bash
install_root="${XDG_DATA_HOME:-$HOME/.local/share}/cccc-skill"
git clone https://github.com/JTropy/cccc-skill.git "$install_root"
mkdir -p "$HOME/.agents/skills" "$HOME/.claude/skills"
ln -s "$install_root/skills/cccc" "$HOME/.agents/skills/cccc"
ln -s "$install_root/skills/cccc" "$HOME/.claude/skills/cccc"
chmod +x "$install_root/skills/cccc/scripts/"*.sh
```

The canonical user paths are:

- Codex: `~/.agents/skills/cccc`
- Claude Code: `~/.claude/skills/cccc`

Project-local installs use `<repo>/.agents/skills/cccc` and `<repo>/.claude/skills/cccc`.

## Install on Windows

In PowerShell, clone a real target first, create both parent directories, then create two Junction entries:

```powershell
$InstallRoot = "$env:LOCALAPPDATA\cccc-skill"
git clone https://github.com/JTropy/cccc-skill.git $InstallRoot
New-Item -ItemType Directory -Force "$env:USERPROFILE\.agents\skills" | Out-Null
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\skills" | Out-Null
New-Item -ItemType Junction -Path "$env:USERPROFILE\.agents\skills\cccc" -Target "$InstallRoot\skills\cccc"
New-Item -ItemType Junction -Path "$env:USERPROFILE\.claude\skills\cccc" -Target "$InstallRoot\skills\cccc"
```

If a host version cannot follow a directory link, use a copy fallback for that host only:

```powershell
Copy-Item -Recurse "$InstallRoot\skills\cccc" "$env:USERPROFILE\.claude\skills\cccc"
```

Keep copied installations synchronized manually. Do not overlay a second `cccc` directory inside an existing one.

## Migrate from v1

v2 moved the installable entrypoint from the repository root to `skills/cccc` and moved Codex's canonical user location to `.agents`.

1. Resolve and record the current link or directory targets.
2. Create the stable v2 checkout without changing the current installation.
3. Create new temporary links/Junctions pointing to `<checkout>/skills/cccc`.
4. Run the validator and wrapper usage checks through those temporary paths.
5. Rename the old entries as backups, then move the verified entries into the canonical paths.

`~/.codex/skills/cccc` is legacy only. Keep it until `~/.agents/skills/cccc` is verified, then remove only that exact old link or copy. Never recursively remove a broad skills directory or an unresolved link target.

Skill changes are normally detected automatically. If the canonical files validate but `$cccc` is still absent, restart the affected host as a fallback, not as a mandatory update step.

## Update, rollback, and uninstall

Do not update the live checkout in place. Build and validate an independent candidate first; the current links and checkout remain the rollback:

```bash
set -eu
base="${XDG_DATA_HOME:-$HOME/.local/share}"
release_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
candidate="$base/cccc-skill.candidate.$release_id"
codex_live="$HOME/.agents/skills/cccc"
claude_live="$HOME/.claude/skills/cccc"
codex_next="$codex_live.next.$release_id"
claude_next="$claude_live.next.$release_id"
codex_backup="$codex_live.rollback.$release_id"
claude_backup="$claude_live.rollback.$release_id"
codex_failed="$codex_live.failed.$release_id"
claude_failed="$claude_live.failed.$release_id"

[ -L "$codex_live" ] && [ -L "$claude_live" ]
readlink "$codex_live"
readlink "$claude_live"
recover_switch() {
  rc=$1
  trap - EXIT HUP INT TERM
  if [ -L "$claude_backup" ]; then
    [ ! -L "$claude_live" ] || mv "$claude_live" "$claude_failed" || true
    if [ ! -e "$claude_live" ] && [ ! -L "$claude_live" ]; then
      mv "$claude_backup" "$claude_live" || true
    fi
  fi
  if [ -L "$codex_backup" ]; then
    [ ! -L "$codex_live" ] || mv "$codex_live" "$codex_failed" || true
    if [ ! -e "$codex_live" ] && [ ! -L "$codex_live" ]; then
      mv "$codex_backup" "$codex_live" || true
    fi
  fi
  [ ! -L "$codex_next" ] || unlink "$codex_next"
  [ ! -L "$claude_next" ] || unlink "$claude_next"
  printf 'cccc update failed; inspect preserved candidate and versioned links\n' >&2
  exit "$rc"
}
trap 'recover_switch $?' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

git clone https://github.com/JTropy/cccc-skill.git "$candidate"
python3 "$candidate/tests/validate_skill.py" "$candidate/skills/cccc"
ln -s "$candidate/skills/cccc" "$codex_next"
ln -s "$candidate/skills/cccc" "$claude_next"

mv "$codex_live" "$codex_backup"
mv "$codex_next" "$codex_live"
mv "$claude_live" "$claude_backup"
mv "$claude_next" "$claude_live"
trap - EXIT HUP INT TERM
```

The versioned names make later updates independent of earlier candidates and backups. If validation fails, fail-fast handling keeps the live links unchanged and preserves the candidate. If clone, staging, or a switch fails, it keeps or restores the live links, removes only this run's staged links, and preserves the candidate plus any `.failed` link for diagnosis.

To rollback after the switch, rename each live link to `.failed` and move its corresponding `.rollback` link back to the canonical name. The old checkout and failed candidate remain available for inspection. Windows follows the same candidate-first sequence with two staged Junctions and `Rename-Item`; never update the target behind live Junctions before validation.

Do not delete task cards, discussion cards, reports, opinions, logs, or any project repository.

For uninstall, first resolve each path and confirm it is the cccc link/Junction or copied skill directory. Remove only `~/.agents/skills/cccc` and `~/.claude/skills/cccc` (plus the exact legacy path if present). Keep or archive the neutral checkout and preserve all project data by default.

## Minimal use

Create a task card from [`task-card.md`](skills/cccc/assets/task-card.md), then delegate to the other installed CLI:

```bash
bash /absolute/path/to/skills/cccc/scripts/delegate.sh \
  <claude|codex> docs/tasks/T-001.md
```

Create a discussion card from [`discussion-card.md`](skills/cccc/assets/discussion-card.md), then request a second opinion:

```bash
bash /absolute/path/to/skills/cccc/scripts/consult.sh \
  <claude|codex> docs/discussions/D-001.md
```

Use the target that is not the current orchestrator. Review every result yourself; a consult opinion is advisory and does not authorize code changes.

## Canonical documentation

- [Skill router and authorization](skills/cccc/SKILL.md)
- [Delegate workflow](skills/cccc/references/delegate.md)
- [Consult workflow](skills/cccc/references/consult.md)
- [Setup and authentication](skills/cccc/references/setup.md)
- [Troubleshooting](skills/cccc/references/troubleshooting.md)

## License

[MIT](LICENSE)
