---
name: cccc
description: Use when the user explicitly requests cccc/4C, asks to launch local Claude Code or Codex as a peer, or confirms a suggested local peer handoff for bounded implementation or a read-only second opinion. Do not use when the user or project rules prohibit external agents.
---

# cccc

Route one bounded request to the other installed local CLI. `delegate` permits scoped implementation; `consult` requests an audited read-only second opinion. The orchestrator keeps the user relationship, validates the result, and makes no capability claims before checking them.

## 1. Authorization gate

- An explicit request naming cccc/4C, asking to invoke this wrapper, or clearly requesting a handoff to the installed local Claude Code or Codex peer authorizes the matching path within the user's stated scope.
- Bare `delegate` or `consult` terms are not launch authorization; treat them as a heuristic until the user confirms the local peer handoff.
- For a heuristic match, only suggest cccc. Confirm with the user before any external CLI launch.
- If user instructions prohibit delegation, or project rules prohibit external agents, do not launch either wrapper. A request to work without a peer has the same effect.

Discovery of this skill is not launch authorization. Apply this gate again immediately before invoking a wrapper.

## 2. Routing precedence

Use this order exactly:

`user instruction > project rules > verified local capability > heuristic`

The Codex orchestrator targets Claude. The Claude Code orchestrator targets Codex. It must never target itself. Do not infer the orchestrator identity from which executable happens to be available.

## 3. Choose one channel

| Need | Channel | Result |
|---|---|---|
| Bounded repository implementation with explicit editable paths | `delegate` | Peer changes plus a report and audit log |
| Analysis, critique, or decision support without repository edits | `consult` | Peer opinion plus an audit log |

Do not use `consult` as authorization to implement its recommendation. Do not use `delegate` when the user asked only for analysis.

## 4. Verify capability

Before launch, verify the selected CLI exists and its authentication status is usable. Follow [setup and authentication](references/setup.md) when a check fails.

For raster-image work, verify that the Codex peer actually exposes usable `$imagegen` capability before proposing that route. Do not promise image generation, a particular model, effort level, cost profile, or network access.

## 5. Safety invariants

- Use only the canonical wrappers in this skill. Never construct a looser raw CLI fallback.
- Treat wrapper exit status `0` as the success authority; an existing report or opinion alone is not success.
- `DELEGATE_DEPTH` blocks wrapper recursion. The task or discussion card must also tell the peer not to invoke another agent.
- Delegate allowed paths and consult read-only controls are Git-visible audits, not operating-system isolation. Keep work involving an untrusted repository outside this trust boundary.
- The peer must not alter repository history, hide working state, discard files, publish changes, or broaden the requested scope.

## 6. Load only the chosen workflow

- For implementation, read [delegate workflow](references/delegate.md).
- For a second opinion, read [consult workflow](references/consult.md).
- For installation, migration, authentication, or optional capability checks, read [setup](references/setup.md).
- After a failed wrapper run, read [troubleshooting](references/troubleshooting.md).

Do not load every reference preemptively. The selected workflow contains the card format, invocation, and result checks for that path.
