# Troubleshooting

Start with the wrapper exit status and stderr. Exit status 0 alone marks success; existing output after any other status can be partial.

| Status | Meaning | First check |
|---|---|---|
| `2` | Usage, card, environment, mode, effort, or policy configuration is invalid | Re-read the exact diagnostic; do not relax the boundary automatically. |
| `3` | Recursion guard rejected a nested wrapper | Keep the current orchestrator in control; remove the nested delegation request. |
| `4` | Git, HEAD, card identity, snapshot, or path policy failure | Inspect the repository and policy failure before retrying. |
| `5` | Lock, output collision, empty or unsafe result artifact, or publication failure | Preserve existing paths; inspect any orphan log named by stderr. |
| `70` | The peer child reported a nonzero exit or signal | Read stderr and verify the peer model/provider request. |
| `124` | Confirmed wrapper timeout | Increase `CCCC_TIMEOUT` only when the task and process behavior are understood. |
| `125` | Cleanup or trusted-state integrity failure | Stop. Check for a surviving process, replaced temporary namespace, or incomplete cleanup. |
| `127` | Required executable/helper missing or peer launch failure | Check Python 3, Bash, Git, the target CLI, and `PATH`. |
| `129`, `130`, `143` | HUP, INT, or TERM interruption | Verify descendants and the repository lock are gone before retrying. |

## Authentication

Run `codex login status` or `claude auth status`. If a custom provider is configured, verify its documented environment and endpoint without printing secrets. An authentication failure is not fixed by weakening the wrapper sandbox.

## Model or effort failure

Model names and effort levels are provider-dependent. Delegate leaves effort unset. Claude consult leaves effort unset; Codex consult defaults to `xhigh`. Claude accepts `low`, `medium`, `high`, `xhigh`, or `max`; Codex accepts `minimal`, `low`, `medium`, `high`, or `xhigh`. Choose a supported value explicitly when the provider rejects the default or requested value.

## Output collision or partial publication

The wrappers never overwrite a report, opinion, or log. An existing regular file, symlink, FIFO, Junction/reparse point, or changed parent identity causes an output collision or fail-closed publication error. Inspect the exact destination. If stderr names an orphan log for manual cleanup, verify its identity and contents before removing only that file or choosing a fresh card name.

## Policy failure

Delegate audits tracked and non-ignored untracked paths against the task card. Consult audits them for any change. Git metadata and Git-ignored paths are outside the audit boundary. With `CCCC_ALLOW_DIRTY=1`, the admitted dirty baseline is fingerprinted, but a second change can still fail policy.

## Python or timeout helper failure

The wrappers require Python 3 and invoke helpers in isolated mode. Check `python3 --version` and ensure the canonical helper files are regular, unchanged files inside the installed skill. Status `124` means the wrapper authenticated a timeout outcome; a peer that naturally returns the number 124 is mapped as a peer failure instead.

## Legacy path or stale installation

Codex uses `~/.agents/skills/cccc`. `~/.codex/skills/cccc` is a legacy path and can leave an older copy active during migration. Resolve both links, verify which `SKILL.md` and scripts they reference, and follow the rollback procedure in [setup](setup.md). If metadata still looks stale after paths are correct, restart the host once.

Legacy delegate variables are deprecated compatibility fallbacks. Consult does not accept them and rejects `DELEGATE_SANDBOX`; use the documented `CCCC_*` controls instead.

## Unsafe or hostile input

The wrappers are not an OS sandbox and do not provide secret isolation from same-UID readable files or intentionally detached processes. Stop using the local workflow for an untrusted repository; reproduce it in an external container and isolated worktree without credentials.
