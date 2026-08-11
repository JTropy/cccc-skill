---
name: cccc
description: Use when the user explicitly requests cccc/4C, asks to launch local Claude Code or Codex as a peer, or confirms a suggested local peer handoff for bounded implementation or a read-only second opinion. Do not use when the user or project rules prohibit external agents.
---

# cccc

Route one bounded request to the other installed local CLI. `delegate` permits scoped implementation; `consult` requests a read-only second opinion. The orchestrator validates the result and makes no unverified capability claim.

## 1. Authorization gate

- An explicit request naming cccc/4C, this wrapper, or a handoff to the installed local Claude Code or Codex peer authorizes that path within the user's scope.
- Bare `delegate` or `consult` terms are not launch authorization; treat them as a heuristic until the user confirms the local peer handoff.
- For a heuristic match, only suggest cccc. Confirm with the user before any external CLI launch.
- If user or project instructions prohibit external agents, do not launch a wrapper.

Discovery of this skill is not launch authorization. Apply this gate again immediately before invoking a wrapper.

## 2. Routing precedence

Use this order exactly:

`user instruction > project rules > verified local capability > heuristic`

The Codex orchestrator targets Claude; the Claude Code orchestrator targets Codex. Never target itself or infer identity from executable availability.

## 3. Choose one channel

| Need | Channel | Result |
|---|---|---|
| Bounded repository implementation with explicit editable paths | `delegate` | Peer changes plus a report and audit log |
| Analysis, critique, or decision support without repository edits | `consult` | Peer opinion plus an audit log |

Do not use `consult` as authorization to implement its recommendation. Do not use `delegate` when the user asked only for analysis.

## 4. Verify capability

Verify the selected CLI and authentication before launch. Follow [setup](references/setup.md) when a check fails.

For raster images, verify usable Codex `$imagegen` capability first. Do not promise image generation, a model, effort, cost, or network path.

## 5. Safety invariants

- Use only the canonical wrappers in this skill. Never construct a looser raw CLI fallback.
- Treat wrapper exit status `0` as the success authority; an existing report or opinion alone is not success.
- `DELEGATE_DEPTH` and wrapper prompts guard against accidental peer recursion; do not ask the peer to invoke another agent.
- Tool restrictions limit exposed operations. The post-run Git audit detects Git-visible changes; neither control is an OS sandbox. Use external isolation for an untrusted repository.
- The peer must not alter repository history, hide working state, discard files, publish changes, or broaden the requested scope.

## 6. Load only the chosen workflow

- For implementation, read [delegate workflow](references/delegate.md).
- For a second opinion, read [consult workflow](references/consult.md).
- For installation, migration, authentication, or optional capability checks, read [setup](references/setup.md).
- After a failed wrapper run, read [troubleshooting](references/troubleshooting.md).

Do not preload every reference. The selected workflow contains its card, invocation, and result checks.
