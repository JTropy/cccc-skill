# Consult workflow

Use this path only after the authorization gate in `SKILL.md` has passed and the user wants analysis, critique, or decision support without repository implementation.

## Prepare the discussion card

Copy [the discussion-card template](../assets/discussion-card.md) to `docs/discussions/<name>.md`. Include the decision, constraints, evidence already gathered, explicit questions, and requested response structure. Do not include a `cccc-allowed-paths` block: consult has no implementation boundary.

The peer is cold-started. Put all necessary repository-relative evidence in the card, but do not put credentials or secrets in it.

## Isolation modes and boundary

Claude runs with a read-only tool allowlist, a private empty MCP configuration, and an absolute repository path. Codex starts from a private cwd and receives the absolute repository path in its prompt.

For Codex, `CCCC_CODEX_CONFIG_MODE=strict` is the default. It disables user/project discovery and known optional side-effect surfaces, requires noninteractive approval and a read-only sandbox, and fails closed when required CLI flags or feature declarations are missing. `CCCC_CODEX_CONFIG_MODE=inherit` keeps the private cwd and read-only controls but permits configured provider behavior; the wrapper warns that inherited connectors, plugins, hooks, or providers can have external side effects.

These controls and the before/after Git audit are not an OS sandbox. The audit covers tracked and non-ignored Git-visible paths; Git metadata and Git-ignored paths are outside it. Read-only does not mean repository-only: globally readable same-UID files may still be readable, and containment of an intentionally detached same-UID process is not guaranteed. Background or detached processes are forbidden by the card prompt. For an untrusted repository or hostile peer input, use an external container and an isolated worktree with no secrets available.

## Invoke

```bash
bash /absolute/path/to/skills/cccc/scripts/consult.sh \
  <claude|codex> docs/discussions/<name>.md
```

Optional controls are `CCCC_TIMEOUT` (`1800` seconds by default, `0` for no deadline), `CCCC_MODEL`, and target-valid `CCCC_EFFORT`. `CCCC_ALLOW_DIRTY=1` admits and fingerprints an existing dirty baseline; without it, consult refuses to start from a dirty repository.

The wrapper publishes `<card-stem>-<target>-opinion.md` and `<card-stem>-<target>.log` without overwriting an existing file. It also serializes against delegate and consult work for the same physical repository.

## Use the opinion

Exit status 0 is the success authority. Read both artifacts, verify cited repository evidence, and integrate the peer's view into your own recommendation. A consultation does not authorize implementation and does not guarantee consensus.

If interrupted after one artifact is published, the wrapper prints the exact path requiring manual cleanup or verification. Treat every nonzero return as incomplete and follow [troubleshooting](troubleshooting.md).
