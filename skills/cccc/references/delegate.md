# Delegate workflow

Use this path only after the authorization gate in `SKILL.md` has passed and the user wants a bounded repository implementation. The orchestrator remains responsible for reviewing the diff and reporting the result.

## Prepare the task card

1. Copy [the task-card template](../assets/task-card.md) to `docs/tasks/<name>.md`.
2. State one concrete objective, the context the cold-start peer needs, and exact acceptance checks.
3. Fill the machine-readable `cccc-allowed-paths` block with the smallest repository-relative files or directory prefixes. Do not use globs, absolute paths, `..`, symlinks, Git metadata paths, or a rule covering the task card or one of its ancestors.
4. Tell the peer not to invoke another agent or alter repository history.

Allowed paths are a post-run Git-visible audit boundary. The snapshot covers tracked files and non-ignored untracked files. Git metadata and Git-ignored paths are outside the audit. This is not an OS sandbox, so use an external isolation boundary for an untrusted task or repository.

## Choose a mode

`CCCC_MODE` accepts exactly these values:

- `edit`: the narrowest implementation mode. For Codex it explicitly sets `network_access=false`; for Claude, `acceptEdits` controls tool permission but does not establish network isolation.
- `auto` (default): workspace writes with the peer CLI's automatic approval mode; Codex delegated network access is enabled.
- `full`: bypasses the peer CLI's normal approval or sandbox controls. It is rejected unless this invocation also has explicit `CCCC_ALLOW_FULL=1` authorization from the user.

The wrapper rejects a dirty worktree by default. `CCCC_ALLOW_DIRTY=1` is an explicit escape hatch: it fingerprints the admitted baseline and detects a second change, but Git metadata and Git-ignored paths remain outside the audit.

Optional controls are `CCCC_TIMEOUT` in seconds (`0` means no deadline), `CCCC_MODEL`, and target-valid `CCCC_EFFORT`. Do not promise that a configured model, provider, effort, network path, or image capability exists; verify it first.

## Invoke

From the repository to be changed:

```bash
bash /absolute/path/to/skills/cccc/scripts/delegate.sh \
  <claude|codex> docs/tasks/<name>.md
```

An optional third argument selects the worktree. Always pass the peer target: a Codex orchestrator targets Claude; a Claude Code orchestrator targets Codex.

The wrapper serializes delegate and consult operations for the same physical repository, records the before/after HEAD and Git-visible snapshot, rejects changes outside the allowed policy, and publishes `<card-stem>-report.md` plus `<card-stem>.log` without overwriting existing paths.

## Accept the result

Exit status 0 is the success authority. A report or log that exists after a nonzero return may be a partial publication and is not proof of success.

After status 0:

1. Read the report and log.
2. Inspect every changed path against the card and the user's scope.
3. Run the acceptance checks yourself.
4. Report discrepancies to the user; do not silently broaden the allowed boundary or relax a safety mode.

For a nonzero return, stop and use [troubleshooting](troubleshooting.md). Do not retry a collision or integrity failure until the named artifact or repository state has been inspected.
