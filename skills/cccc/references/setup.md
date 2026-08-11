# Setup, authentication, and migration

The canonical skill entrypoint is the `skills/cccc/` directory in this repository. Keep one neutral checkout as the source of truth and link that directory into both hosts.

## Requirements

- Git, Bash 3.2 or newer, and Python 3.
- Current `claude` and `codex` CLIs on `PATH`.
- Authentication for the peer CLI you intend to launch.
- On Windows, Git Bash for the shell wrappers. Windows CI must pass before release; a macOS run cannot verify native Windows behavior.

## macOS and Linux

```bash
install_root="${XDG_DATA_HOME:-$HOME/.local/share}/cccc-skill"
git clone https://github.com/JTropy/cccc-skill.git "$install_root"
mkdir -p "$HOME/.agents/skills" "$HOME/.claude/skills"
ln -s "$install_root/skills/cccc" "$HOME/.agents/skills/cccc"
ln -s "$install_root/skills/cccc" "$HOME/.claude/skills/cccc"
chmod +x "$install_root/skills/cccc/scripts/"*.sh
```

Stop if either destination already exists. Inspect whether it is a directory or link before replacing it. To update later, fast-forward the neutral checkout and rerun validation; do not copy a second nested `cccc` directory over an existing installation.

## Windows Junction installation

In PowerShell, clone the repository first, create both parent directories, then create a Junction for each host:

```powershell
$InstallRoot = "$env:LOCALAPPDATA\cccc-skill"
git clone https://github.com/JTropy/cccc-skill.git $InstallRoot
New-Item -ItemType Directory -Force "$env:USERPROFILE\.agents\skills" | Out-Null
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\skills" | Out-Null
New-Item -ItemType Junction -Path "$env:USERPROFILE\.agents\skills\cccc" -Target "$InstallRoot\skills\cccc"
New-Item -ItemType Junction -Path "$env:USERPROFILE\.claude\skills\cccc" -Target "$InstallRoot\skills\cccc"
```

If Junction creation is unavailable, copy `skills\cccc` separately to both destinations and update both copies together.

## Authentication checks

Prefer each CLI's credential store. Never place a token in this repository, a task card, a discussion card, or wrapper arguments.

```bash
codex login status
printenv OPENAI_API_KEY | codex login --with-api-key
claude auth status
```

The pipe is an optional API-key login path; avoid terminal history that contains the value itself. Claude deployments may use `ANTHROPIC_API_KEY`; bearer-token gateways may use `ANTHROPIC_AUTH_TOKEN`. A custom endpoint may also require its documented base-URL setting. Verify with `claude auth status` without printing credential values.

Model and effort support are provider-dependent. `xhigh`, a particular model name, and `$imagegen` must be checked against the active CLI, account, provider, and workspace before routing work that depends on them.

## v1 migration and rollback

Codex's canonical user path is `~/.agents/skills/cccc`. An existing `~/.codex/skills/cccc` installation is a legacy path: leave it untouched until the new link validates, then remove only that known legacy link or copy. Claude's user path remains `~/.claude/skills/cccc`.

For rollback, preserve the previous directory or link target before switching. Restore that exact target if validation fails; do not recursively delete an unresolved link or broad skills directory.

Both hosts normally detect skill changes automatically. If `$cccc` does not appear after the link and files validate, restart the affected host as a fallback.

## Self-check

```bash
codex login status
claude auth status
bash "$HOME/.agents/skills/cccc/scripts/delegate.sh"
bash "$HOME/.agents/skills/cccc/scripts/consult.sh"
```

The last two commands should print their usage diagnostics and return nonzero because no card was supplied. Run the repository validator before treating an updated installation as ready.
