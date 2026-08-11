# Task card

## Objective

State the one concrete outcome the delegated agent must deliver.

## Context

List the relevant repository paths, constraints, prior decisions, and facts the agent must preserve.

## Acceptance checks

- Give exact commands or observable checks that prove the task is complete.
- Include negative checks for behavior that must not change.

## Boundaries

The paths below are a post-run Git-visible audit boundary, not operating-system write isolation. The delegated agent must not commit, stash, reset, checkout, clean, push, or invoke another agent. Git metadata and Git-ignored paths remain outside the wrapper's audit boundary.

Replace the example with the smallest repository-relative file or directory prefixes needed by the task. Do not use globs, absolute paths, `..`, symlinks, or Git metadata paths.

<!-- cccc-allowed-paths
path/to/file-or-directory/
-->
