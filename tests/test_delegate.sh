#!/usr/bin/env bash
set -u

TEST_DIR=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
ROOT_DIR=$(CDPATH= cd -P -- "$TEST_DIR/.." && pwd) || exit 1
DELEGATE="$ROOT_DIR/skills/cccc/scripts/delegate.sh"
ORIGINAL_PATH=$PATH

# shellcheck source=tests/test_helper.bash
. "$TEST_DIR/test_helper.bash"
trap test_cleanup EXIT
trap 'test_signal_cleanup 1' HUP
trap 'test_signal_cleanup 2' INT
trap 'test_signal_cleanup 15' TERM

run_test() {
  local name=$1
  local output rc
  if [ -n "${CCCC_TEST_FILTER-}" ]; then
    case "$name $2" in *"$CCCC_TEST_FILTER"*) ;; *) return 0 ;; esac
  fi
  TEST_COUNT=$((TEST_COUNT + 1))
  output=$("$2" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'ok %d - %s\n' "$TEST_COUNT" "$name"
  elif [ "$rc" -eq 77 ]; then
    printf 'ok %d - %s # SKIP %s\n' "$TEST_COUNT" "$name" "${output:-unsupported on this platform}"
  else
    printf 'not ok %d - %s\n' "$TEST_COUNT" "$name"
    if [ -n "$output" ]; then
      while IFS= read -r line; do printf '# %s\n' "$line"; done <<EOF
$output
EOF
    fi
    TEST_FAILED=$((TEST_FAILED + 1))
  fi
}

write_card() {
  local repo=$1 card=$2 policy=${3:-src/}
  mkdir -p "$repo/$(dirname -- "$card")" || return 1
  {
    printf '# Delegate test\n\n'
    printf '<!-- cccc-allowed-paths\n'
    printf '%s\n' "$policy"
    printf '%s\n' '-->'
  } >"$repo/$card"
}

install_fake_agents() {
  local directory=$1 fake
  mkdir -p "$directory" || return 1
  fake="$directory/fake-agent"
  cat >"$fake" <<'FAKE'
#!/usr/bin/env bash
set -u

if [ -n "${CCCC_FAKE_ARGV_FILE-}" ]; then
  : >"$CCCC_FAKE_ARGV_FILE"
  for argument in "$@"; do
    printf '%s\0' "$argument" >>"$CCCC_FAKE_ARGV_FILE"
  done
fi
if [ -n "${CCCC_FAKE_ENV_FILE-}" ]; then
  {
    printf 'DELEGATE_DEPTH=%s\n' "${DELEGATE_DEPTH-<unset>}"
    printf 'BASH_ENV=%s\n' "${BASH_ENV-<unset>}"
    printf 'ENV=%s\n' "${ENV-<unset>}"
  } >"$CCCC_FAKE_ENV_FILE"
fi
if [ -n "${CCCC_FAKE_LAUNCH_FILE-}" ]; then
  printf 'launched\n' >>"$CCCC_FAKE_LAUNCH_FILE"
fi

output=
previous=
for argument in "$@"; do
  if [ "$previous" = --output-last-message ]; then
    output=$argument
    break
  fi
  previous=$argument
done

if [ -n "$output" ] && [ -n "${CCCC_FAKE_RUN_MODE_FILE-}" ]; then
  directory=$(dirname -- "$output")
  mode=$(stat -f '%Lp' "$directory" 2>/dev/null || stat -c '%a' "$directory" 2>/dev/null || true)
  printf '%s\n' "$mode" >"$CCCC_FAKE_RUN_MODE_FILE"
fi

printf 'fake-agent stderr marker\n' >&2

case ${CCCC_FAKE_SCENARIO:-success} in
  success) ;;
  write-allowed)
    mkdir -p src
    printf 'allowed change\n' >>src/changed.txt
    ;;
  write-outside)
    mkdir -p bad
    printf 'outside change\n' >>bad/outside.txt
    ;;
  write-prefix-trick)
    mkdir -p src-evil
    printf 'prefix trick\n' >>src-evil/outside.txt
    ;;
  write-md-suffix)
    printf 'suffix trick\n' >>src/allowed.md.evil
    ;;
  rename-outside)
    mkdir -p bad
    mv src/allowed.txt bad/renamed.txt
    ;;
  dirty-twice)
    printf 'second mutation\n' >>bad/dirty.txt
    ;;
  untracked-dirty-twice)
    printf 'second mutation\n' >>bad/untracked.txt
    ;;
  index-only)
    "${CCCC_FAKE_REAL_GIT:-git}" add bad/dirty.txt
    ;;
  newline-outside)
    newline_path=$(printf 'bad/line\nforged-agent_rc=0')
    printf 'outside change\n' >"$newline_path"
    ;;
  modify-card)
    printf '\nchild changed card\n' >>"${CCCC_FAKE_CARD:-docs/tasks/T-test.md}"
    ;;
  replace-card-parent)
    mkdir -p "$CCCC_FAKE_EXTERNAL"
    mv docs/tasks "$CCCC_FAKE_EXTERNAL/original-tasks"
    mkdir docs/tasks
    cp "$CCCC_FAKE_EXTERNAL/original-tasks/T-test.md" docs/tasks/T-test.md
    ;;
  replace-docs-ancestor)
    mkdir -p "$CCCC_FAKE_EXTERNAL"
    mv docs "$CCCC_FAKE_EXTERNAL/original-docs"
    mkdir -p docs/tasks
    cp "$CCCC_FAKE_EXTERNAL/original-docs/tasks/T-test.md" docs/tasks/T-test.md
    ;;
  commit)
    printf 'commit change\n' >>src/allowed.txt
    "${CCCC_FAKE_REAL_GIT:-git}" add src/allowed.txt
    "${CCCC_FAKE_REAL_GIT:-git}" commit -q -m fake-agent-commit
    ;;
  empty) ;;
  nonzero) ;;
  natural-124)
    CCCC_FAKE_NATURAL_RC=124
    printf 'cccc-timeout: command exceeded 1 seconds\n' >&2
    ;;
  natural-status)
    printf 'cccc-timeout: command exceeded %s seconds\n' "${CCCC_TIMEOUT:-3600}" >&2
    ;;
  timeout-outside)
    mkdir -p bad
    printf 'outside before timeout\n' >bad/timeout-outside.txt
    sleep 10
    ;;
  nonzero-outside)
    mkdir -p bad
    printf 'outside before failure\n' >bad/nonzero-outside.txt
    ;;
  background-writer)
    (sleep 0.5; printf 'late\n' >"$CCCC_FAKE_SENTINEL") >/dev/null 2>&1 &
    ;;
  timeout)
    sleep 10
    ;;
  inject-symlink)
    ln -s "$CCCC_FAKE_REFERENT" "$CCCC_FAKE_DEST"
    ;;
  inject-fifo)
    mkfifo "$CCCC_FAKE_DEST"
    ;;
  report-symlink)
    printf 'symlink report\n' >"$CCCC_FAKE_REFERENT"
    ln -s "$CCCC_FAKE_REFERENT" "$output"
    ;;
  report-fifo)
    mkfifo "$output"
    ;;
  *)
    printf 'unknown fake scenario: %s\n' "$CCCC_FAKE_SCENARIO" >&2
    exit 98
    ;;
esac

if [ -n "${CCCC_FAKE_BARRIER_DIR-}" ]; then
  mkdir -p "$CCCC_FAKE_BARRIER_DIR"
  : >"$CCCC_FAKE_BARRIER_DIR/ready.$$"
  while [ ! -e "$CCCC_FAKE_BARRIER_DIR/release" ]; do
    sleep 0.02
  done
fi

case ${CCCC_FAKE_SCENARIO:-success} in
  empty) ;;
  nonzero)
    if [ -n "$output" ]; then
      printf '%s\n' "${CCCC_FAKE_REPORT:-fake report}" >"$output"
    else
      printf '%s\n' "${CCCC_FAKE_REPORT:-fake report}"
    fi
    exit "${CCCC_FAKE_RC:-19}"
    ;;
  natural-124)
    if [ -n "$output" ]; then
      printf '%s\n' "${CCCC_FAKE_REPORT:-fake report}" >"$output"
    else
      printf '%s\n' "${CCCC_FAKE_REPORT:-fake report}"
    fi
    exit 124
    ;;
  natural-status)
    if [ -n "$output" ]; then
      printf '%s\n' "${CCCC_FAKE_REPORT:-fake report}" >"$output"
    else
      printf '%s\n' "${CCCC_FAKE_REPORT:-fake report}"
    fi
    exit "${CCCC_FAKE_NATURAL_RC:-2}"
    ;;
  timeout|timeout-outside) ;;
  report-symlink|report-fifo) ;;
  nonzero-outside)
    if [ -n "$output" ]; then
      printf '%s\n' "${CCCC_FAKE_REPORT:-fake report}" >"$output"
    else
      printf '%s\n' "${CCCC_FAKE_REPORT:-fake report}"
    fi
    exit "${CCCC_FAKE_RC:-19}"
    ;;
  *)
    if [ -n "$output" ]; then
      printf '%s\n' "${CCCC_FAKE_REPORT:-fake report}" >"$output"
    else
      printf '%s\n' "${CCCC_FAKE_REPORT:-fake report}"
    fi
    ;;
esac
exit 0
FAKE
  chmod +x "$fake" || return 1
  cp "$fake" "$directory/claude" || return 1
  cp "$fake" "$directory/codex" || return 1
  chmod +x "$directory/claude" "$directory/codex" || return 1
}

prepare_case() {
  CASE_DIR=$(new_test_dir) || return 1
  CASE_REPO="$CASE_DIR/repo"
  CASE_BIN="$CASE_DIR/bin"
  CASE_TMP="$CASE_DIR/tmp"
  CASE_ARGV="$CASE_DIR/argv.bin"
  CASE_ENV="$CASE_DIR/env.txt"
  CASE_LAUNCH="$CASE_DIR/launched.txt"
  CASE_CARD=docs/tasks/T-test.md
  mkdir -p "$CASE_REPO/src" "$CASE_REPO/bad" "$CASE_TMP" || return 1
  init_test_repo "$CASE_REPO" || return 1
  printf 'baseline\n' >"$CASE_REPO/src/allowed.txt"
  printf 'baseline\n' >"$CASE_REPO/bad/dirty.txt"
  write_card "$CASE_REPO" "$CASE_CARD" src/ || return 1
  printf '*.log\n' >"$CASE_REPO/.gitignore"
  git -C "$CASE_REPO" add . || return 1
  git -C "$CASE_REPO" commit -q -m baseline || return 1
  install_fake_agents "$CASE_BIN" || return 1
}

run_delegate() {
  local target=${1:-claude} card=${2:-$CASE_CARD} workdir=${3:-$CASE_REPO}
  local old_path=$PATH
  PATH="$CASE_BIN:$ORIGINAL_PATH"
  export PATH
  export TMPDIR="$CASE_TMP"
  export CCCC_FAKE_ARGV_FILE="$CASE_ARGV"
  export CCCC_FAKE_ENV_FILE="$CASE_ENV"
  export CCCC_FAKE_LAUNCH_FILE="${CASE_LAUNCH_FILE:-$CASE_LAUNCH}"
  CASE_OUTPUT=$("$DELEGATE" "$target" "$card" "$workdir" 2>&1)
  CASE_RC=$?
  PATH=$old_path
  export PATH
}

invoke_delegate_explicit() {
  local repo=$1 bin=$2 tmp=$3 argv_file=$4 env_file=$5 launch_file=$6
  local target=$7 card=$8 output_file=$9 rc_file=${10}
  (
    export PATH="$bin:$ORIGINAL_PATH"
    export TMPDIR="$tmp"
    export CCCC_FAKE_ARGV_FILE="$argv_file"
    export CCCC_FAKE_ENV_FILE="$env_file"
    export CCCC_FAKE_LAUNCH_FILE="$launch_file"
    "$DELEGATE" "$target" "$card" "$repo" >"$output_file" 2>&1
    printf '%s\n' "$?" >"$rc_file"
  )
}

exec_delegate_with_signal_defaults() {
  local launcher_python=$1
  shift
  exec "$launcher_python" -I -c '
import os
import signal
import sys
for name in ("SIGHUP", "SIGINT", "SIGTERM"):
    if hasattr(signal, name):
        signal.signal(getattr(signal, name), signal.SIG_DFL)
os.execv(sys.argv[1], sys.argv[1:])
' "$DELEGATE" "$@"
}

normalize_argv() {
  python3 - "$1" <<'PY'
import os
import sys

raw = open(sys.argv[1], "rb").read()
arguments = raw.split(b"\0")
if arguments and arguments[-1] == b"":
    arguments.pop()
for argument in arguments:
    text = os.fsdecode(argument)
    if text.endswith("/report.md") and "/cccc." in text:
        text = "<RUN_REPORT>"
    elif text.startswith("You are the cccc delegated agent."):
        text = "<PROMPT>"
    print(text)
PY
}

assert_argv_equals() {
  local expected=$1 actual
  actual=$(normalize_argv "$CASE_ARGV") || return 1
  assert_eq "$expected" "$actual" 'exact agent argv'
}

assert_not_launched() {
  if [ -s "$CASE_LAUNCH" ]; then
    test_diag 'agent was launched unexpectedly'
    return 1
  fi
}

require_symlink_capability() {
  local directory=$1 target link
  target="$directory/cap-target"
  link="$directory/cap-link"
  printf 'capability\n' >"$target" || return 77
  ln -s "$target" "$link" 2>/dev/null || return 77
  [ -L "$link" ] || return 77
  unlink "$link" || return 77
  unlink "$target" || return 77
}

require_fifo_capability() {
  local fifo="$1/cap-fifo"
  mkfifo "$fifo" 2>/dev/null || return 77
  [ -p "$fifo" ] || return 77
  unlink "$fifo" || return 77
}

require_posix_inode_capability() {
  case ${OS-}:$(uname -s 2>/dev/null || true) in
    Windows_NT:*) return 77 ;;
    *:Darwin|*:Linux) return 0 ;;
    *) return 77 ;;
  esac
}

assert_success_outputs() {
  local card=${1:-$CASE_CARD} report log
  report="$CASE_REPO/${card%.md}-report.md"
  log="$CASE_REPO/${card%.md}.log"
  assert_eq 0 "$CASE_RC" 'wrapper status' || return 1
  [ -s "$report" ] || { test_diag 'report was not published'; return 1; }
  [ -s "$log" ] || { test_diag 'log was not published'; return 1; }
  [ ! -L "$report" ] && [ -f "$report" ] || { test_diag 'report is not a regular non-symlink'; return 1; }
  [ ! -L "$log" ] && [ -f "$log" ] || { test_diag 'log is not a regular non-symlink'; return 1; }
}

test_exact_claude_edit_argv() {
  prepare_case || return 1
  CCCC_MODE=edit run_delegate claude
  assert_success_outputs || return 1
  assert_argv_equals "$(cat <<'EOF'
-p
<PROMPT>
--output-format
text
--permission-mode
acceptEdits
EOF
)"
}

test_exact_claude_auto_argv() {
  prepare_case || return 1
  CCCC_MODE=auto run_delegate claude
  assert_success_outputs || return 1
  assert_argv_equals "$(cat <<'EOF'
-p
<PROMPT>
--output-format
text
--permission-mode
auto
EOF
)"
}

test_exact_claude_full_argv() {
  prepare_case || return 1
  CCCC_MODE=full CCCC_ALLOW_FULL=1 run_delegate claude
  assert_success_outputs || return 1
  assert_argv_equals "$(cat <<'EOF'
-p
<PROMPT>
--output-format
text
--dangerously-skip-permissions
EOF
)"
}

test_exact_codex_edit_argv() {
  prepare_case || return 1
  CCCC_MODE=edit run_delegate codex
  assert_success_outputs || return 1
  assert_argv_equals "$(cat <<'EOF'
exec
--output-last-message
<RUN_REPORT>
--sandbox
workspace-write
-c
sandbox_workspace_write.network_access=false
<PROMPT>
EOF
)"
}

test_exact_codex_auto_argv() {
  prepare_case || return 1
  CCCC_MODE=auto run_delegate codex
  assert_success_outputs || return 1
  assert_argv_equals "$(cat <<'EOF'
exec
--output-last-message
<RUN_REPORT>
--sandbox
workspace-write
--approve-for-me
-c
sandbox_workspace_write.network_access=true
<PROMPT>
EOF
)"
}

test_exact_codex_full_argv() {
  prepare_case || return 1
  CCCC_MODE=full CCCC_ALLOW_FULL=1 run_delegate codex
  assert_success_outputs || return 1
  assert_argv_equals "$(cat <<'EOF'
exec
--output-last-message
<RUN_REPORT>
--dangerously-bypass-approvals-and-sandbox
<PROMPT>
EOF
)"
}

test_full_requires_explicit_gate() {
  prepare_case || return 1
  CCCC_MODE=full run_delegate claude
  assert_eq 2 "$CASE_RC" || return 1
  assert_not_launched || return 1
  case "$CASE_OUTPUT" in *CCCC_ALLOW_FULL=1*) return 0 ;; esac
  test_diag 'missing full-mode gate diagnostic'
  return 1
}

test_configuration_validation_and_defaults() {
  prepare_case || return 1
  CCCC_ALLOW_FULL=yes run_delegate claude
  assert_eq 2 "$CASE_RC" 'invalid allow-full status' || return 1
  assert_not_launched || return 1

  prepare_case || return 1
  CCCC_ALLOW_DIRTY=yes run_delegate claude
  assert_eq 2 "$CASE_RC" 'invalid allow-dirty status' || return 1
  assert_not_launched || return 1

  prepare_case || return 1
  CCCC_MODE=unsafe run_delegate claude
  assert_eq 2 "$CASE_RC" 'invalid mode status' || return 1
  assert_not_launched || return 1

  prepare_case || return 1
  CCCC_TIMEOUT=01 run_delegate claude
  assert_eq 2 "$CASE_RC" 'noncanonical timeout status' || return 1
  assert_not_launched || return 1

  prepare_case || return 1
  run_delegate claude
  assert_success_outputs || return 1
  grep -q '^timeout=3600$' "$CASE_REPO/docs/tasks/T-test.log" || {
    test_diag 'delegate timeout default was not 3600'
    return 1
  }
  grep -q '^mode=auto$' "$CASE_REPO/docs/tasks/T-test.log"
}

test_timeout_zero_and_safe_maximum_validation() {
  prepare_case || return 1
  CCCC_TIMEOUT=0 run_delegate claude
  assert_success_outputs || return 1
  grep -q '^timeout=0$' "$CASE_REPO/docs/tasks/T-test.log" || return 1

  prepare_case || return 1
  CCCC_TIMEOUT=999999999999999999999999 run_delegate claude
  assert_eq 2 "$CASE_RC" 'oversized timeout status' || return 1
  assert_not_launched
}

test_depth_validation_and_child_scope() {
  prepare_case || return 1
  DELEGATE_DEPTH=1 run_delegate claude
  assert_eq 3 "$CASE_RC" 'nested status' || return 1
  assert_not_launched || return 1

  prepare_case || return 1
  DELEGATE_DEPTH='1+0' run_delegate claude
  assert_eq 2 "$CASE_RC" 'arithmetic depth status' || return 1
  assert_not_launched || return 1

  prepare_case || return 1
  DELEGATE_DEPTH=0 run_delegate codex
  assert_success_outputs || return 1
  grep -Fxq 'DELEGATE_DEPTH=1' "$CASE_ENV" || return 1
  assert_eq 0 "${DELEGATE_DEPTH:-0}" 'caller depth was changed'
}

test_exact_arity_and_empty_workdir() {
  prepare_case || return 1
  CASE_OUTPUT=$(PATH="$CASE_BIN:$ORIGINAL_PATH" "$DELEGATE" 2>&1)
  CASE_RC=$?
  assert_eq 2 "$CASE_RC" 'zero-argument status' || return 1

  CASE_OUTPUT=$(PATH="$CASE_BIN:$ORIGINAL_PATH" "$DELEGATE" claude 2>&1)
  CASE_RC=$?
  assert_eq 2 "$CASE_RC" 'one-argument status' || return 1

  CASE_OUTPUT=$(PATH="$CASE_BIN:$ORIGINAL_PATH" "$DELEGATE" claude "$CASE_CARD" "$CASE_REPO" extra 2>&1)
  CASE_RC=$?
  assert_eq 2 "$CASE_RC" 'four-argument status' || return 1

  CASE_OUTPUT=$(PATH="$CASE_BIN:$ORIGINAL_PATH" "$DELEGATE" claude "$CASE_CARD" '' 2>&1)
  CASE_RC=$?
  assert_eq 2 "$CASE_RC" 'explicit empty workdir status' || return 1
  assert_not_launched
}

test_explicit_empty_new_variables_suppress_legacy() {
  prepare_case || return 1
  CCCC_MODE= DELEGATE_SANDBOX=edit run_delegate claude
  assert_eq 2 "$CASE_RC" 'empty CCCC_MODE status' || return 1
  case "$CASE_OUTPUT" in *DELEGATE_SANDBOX*deprecated*) return 1 ;; esac
  assert_not_launched || return 1

  prepare_case || return 1
  CCCC_TIMEOUT= DELEGATE_TIMEOUT=7 run_delegate claude
  assert_eq 2 "$CASE_RC" 'empty CCCC_TIMEOUT status' || return 1
  case "$CASE_OUTPUT" in *DELEGATE_TIMEOUT*deprecated*) return 1 ;; esac
  assert_not_launched || return 1

  prepare_case || return 1
  CCCC_MODEL= DELEGATE_MODEL=legacy run_delegate claude
  assert_success_outputs || return 1
  if normalize_argv "$CASE_ARGV" | grep -Fxq legacy; then return 1; fi
}

test_model_effort_mapping_and_argv_boundaries() {
  local hostile='model value;$(touch SHOULD-NOT-EXIST)'
  prepare_case || return 1
  CCCC_MODEL="$hostile" CCCC_EFFORT=max run_delegate claude
  assert_success_outputs || return 1
  assert_argv_equals "$(cat <<EOF
-p
<PROMPT>
--output-format
text
--permission-mode
auto
--model
$hostile
--effort
max
EOF
)" || return 1
  [ ! -e "$CASE_REPO/SHOULD-NOT-EXIST" ] || return 1

  prepare_case || return 1
  CCCC_MODEL="$hostile" CCCC_EFFORT=xhigh run_delegate codex
  assert_success_outputs || return 1
  assert_argv_equals "$(cat <<EOF
exec
--output-last-message
<RUN_REPORT>
--sandbox
workspace-write
--approve-for-me
-c
sandbox_workspace_write.network_access=true
--model
$hostile
-c
model_reasoning_effort=xhigh
<PROMPT>
EOF
)" || return 1
  [ ! -e "$CASE_REPO/SHOULD-NOT-EXIST" ]
}

test_target_specific_effort_validation() {
  prepare_case || return 1
  CCCC_EFFORT=minimal run_delegate claude
  assert_eq 2 "$CASE_RC" || return 1
  assert_not_launched || return 1

  prepare_case || return 1
  CCCC_EFFORT=max run_delegate codex
  assert_eq 2 "$CASE_RC" || return 1
  assert_not_launched
}

test_deprecated_fallbacks_and_new_precedence() {
  prepare_case || return 1
  DELEGATE_SANDBOX=edit DELEGATE_TIMEOUT=7 DELEGATE_MODEL=legacy-model run_delegate claude
  assert_success_outputs || return 1
  case "$CASE_OUTPUT" in
    *DELEGATE_SANDBOX*deprecated*DELEGATE_TIMEOUT*deprecated*DELEGATE_MODEL*deprecated*) ;;
    *) test_diag 'missing ordered migration warnings'; return 1 ;;
  esac
  grep -q '^timeout=7$' "$CASE_REPO/docs/tasks/T-test.log" || return 1
  normalize_argv "$CASE_ARGV" | grep -Fxq legacy-model || return 1

  prepare_case || return 1
  CCCC_MODE=auto CCCC_TIMEOUT=8 CCCC_MODEL=new-model \
    DELEGATE_SANDBOX=edit DELEGATE_TIMEOUT=7 DELEGATE_MODEL=legacy-model run_delegate claude
  assert_success_outputs || return 1
  case "$CASE_OUTPUT" in *deprecated*) test_diag 'unused legacy value warned'; return 1 ;; esac
  grep -q '^timeout=8$' "$CASE_REPO/docs/tasks/T-test.log" || return 1
  normalize_argv "$CASE_ARGV" | grep -Fxq new-model || return 1
  if normalize_argv "$CASE_ARGV" | grep -Fxq legacy-model; then return 1; fi
}

test_argument_card_and_policy_preflight() {
  prepare_case || return 1
  run_delegate auto
  assert_eq 2 "$CASE_RC" 'invalid target status' || return 1
  assert_not_launched || return 1

  prepare_case || return 1
  CASE_OUTPUT=$(PATH="$CASE_BIN:$ORIGINAL_PATH" "$DELEGATE" claude "$CASE_CARD" "$CASE_REPO" extra 2>&1)
  CASE_RC=$?
  assert_eq 2 "$CASE_RC" 'extra argument status' || return 1
  assert_not_launched || return 1

  prepare_case || return 1
  printf '# missing policy\n' >"$CASE_REPO/$CASE_CARD"
  CCCC_ALLOW_DIRTY=1 run_delegate claude
  assert_eq 2 "$CASE_RC" 'missing policy status' || return 1
  assert_not_launched || return 1

  prepare_case || return 1
  write_card "$CASE_REPO" "$CASE_CARD" '../escape' || return 1
  CCCC_ALLOW_DIRTY=1 run_delegate claude
  assert_eq 2 "$CASE_RC" 'invalid policy status' || return 1
  assert_not_launched
}

test_allowed_policy_cannot_cover_card_or_ancestor() {
  local policy
  for policy in docs/ docs/tasks/ docs/tasks/T-test.md; do
    prepare_case || return 1
    write_card "$CASE_REPO" "$CASE_CARD" "$policy" || return 1
    CCCC_ALLOW_DIRTY=1 run_delegate claude
    assert_eq 2 "$CASE_RC" "card-overlapping policy status for $policy" || return 1
    assert_not_launched || return 1
  done
}

test_dangerous_git_redirect_environment_is_rejected() {
  local variable
  for variable in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY; do
    prepare_case || return 1
    case "$variable" in
      GIT_DIR) GIT_DIR="$CASE_DIR/redirect" run_delegate claude ;;
      GIT_WORK_TREE) GIT_WORK_TREE="$CASE_DIR/redirect" run_delegate claude ;;
      GIT_INDEX_FILE) GIT_INDEX_FILE="$CASE_DIR/redirect" run_delegate claude ;;
      GIT_COMMON_DIR) GIT_COMMON_DIR="$CASE_DIR/redirect" run_delegate claude ;;
      GIT_OBJECT_DIRECTORY) GIT_OBJECT_DIRECTORY="$CASE_DIR/redirect" run_delegate claude ;;
    esac
    assert_eq 2 "$CASE_RC" "$variable redirect status" || return 1
    assert_not_launched || return 1
  done
}

test_python_is_isolated_and_windows_shim_environment_is_cleared() {
  local real_python python_log
  prepare_case || return 1
  real_python=$(command -v python3)
  python_log="$CASE_DIR/python-argv.bin"
  cat >"$CASE_BIN/python3" <<'PYTHON_SHIM'
#!/usr/bin/env bash
for argument in "$@"; do
  printf '%s\0' "$argument" >>"$CCCC_PYTHON_LOG"
done
printf '\0' >>"$CCCC_PYTHON_LOG"
exec "$CCCC_REAL_PYTHON" "$@"
PYTHON_SHIM
  chmod +x "$CASE_BIN/python3" || return 1
  MSYSTEM=MINGW64 BASH_ENV=/dev/null ENV=/dev/null \
    CCCC_PYTHON_LOG="$python_log" CCCC_REAL_PYTHON="$real_python" run_delegate codex
  assert_success_outputs || return 1
  grep -Fxq 'BASH_ENV=<unset>' "$CASE_ENV" || return 1
  grep -Fxq 'ENV=<unset>' "$CASE_ENV" || return 1
  python3 - "$python_log" <<'PY'
import sys

records = [record for record in open(sys.argv[1], "rb").read().split(b"\0\0") if record]
if not records:
    raise SystemExit("no Python invocations recorded")
for record in records:
    arguments = [item for item in record.split(b"\0") if item]
    if not arguments or arguments[0] != b"-I":
        raise SystemExit("non-isolated Python invocation: %r" % arguments)
PY
}

test_dirty_default_rejection_and_explicit_warning() {
  prepare_case || return 1
  printf 'dirty\n' >>"$CASE_REPO/src/allowed.txt"
  run_delegate claude
  assert_eq 4 "$CASE_RC" 'dirty default status' || return 1
  assert_not_launched || return 1

  prepare_case || return 1
  printf 'dirty\n' >>"$CASE_REPO/src/allowed.txt"
  CCCC_ALLOW_DIRTY=1 run_delegate claude
  assert_success_outputs || return 1
  case "$CASE_OUTPUT" in *WARNING*dirty*baseline*) ;; *)
    test_diag 'dirty escape warning missing'
    return 1
    ;;
  esac
  case "$CASE_OUTPUT" in *Git\ metadata*Git-ignored*) return 0 ;; esac
  test_diag 'audit-boundary warning missing'
  return 1
}

test_clean_run_warns_audit_boundary_and_logs_metadata() {
  prepare_case || return 1
  CCCC_FAKE_SCENARIO=write-allowed run_delegate claude
  assert_success_outputs || return 1
  case "$CASE_OUTPUT" in *Git\ metadata*Git-ignored*) ;; *) return 1 ;; esac
  grep -q '^head_before=' "$CASE_REPO/docs/tasks/T-test.log" || return 1
  grep -q '^head_after=' "$CASE_REPO/docs/tasks/T-test.log" || return 1
  grep -q '^status_before_sha256=' "$CASE_REPO/docs/tasks/T-test.log" || return 1
  grep -q '^status_after_sha256=' "$CASE_REPO/docs/tasks/T-test.log" || return 1
  grep -q '^changed_path_hex=7372632f6368616e6765642e747874$' "$CASE_REPO/docs/tasks/T-test.log" || return 1
  grep -q 'fake-agent stderr marker' "$CASE_REPO/docs/tasks/T-test.log"
}

test_out_of_policy_and_boundary_tricks_fail() {
  prepare_case || return 1
  CCCC_FAKE_SCENARIO=write-outside run_delegate claude
  assert_eq 4 "$CASE_RC" 'outside write status' || return 1
  [ ! -e "$CASE_REPO/docs/tasks/T-test-report.md" ] || return 1
  [ ! -e "$CASE_REPO/docs/tasks/T-test.log" ] || return 1

  prepare_case || return 1
  CCCC_FAKE_SCENARIO=write-prefix-trick run_delegate claude
  assert_eq 4 "$CASE_RC" 'directory prefix boundary status' || return 1

  prepare_case || return 1
  printf 'markdown\n' >"$CASE_REPO/src/allowed.md"
  write_card "$CASE_REPO" "$CASE_CARD" src/allowed.md || return 1
  git -C "$CASE_REPO" add src/allowed.md || return 1
  git -C "$CASE_REPO" add "$CASE_CARD" && git -C "$CASE_REPO" commit -q -m policy || return 1
  CCCC_FAKE_SCENARIO=write-md-suffix run_delegate claude
  assert_eq 4 "$CASE_RC" '.md exact-file boundary status'
}

test_rename_to_disallowed_fails() {
  require_posix_inode_capability || return 77
  prepare_case || return 1
  CCCC_FAKE_SCENARIO=rename-outside run_delegate claude
  assert_eq 4 "$CASE_RC" || return 1
  [ ! -e "$CASE_REPO/docs/tasks/T-test-report.md" ]
}

test_dirty_tracked_file_second_change_is_detected() {
  prepare_case || return 1
  printf 'first mutation\n' >>"$CASE_REPO/bad/dirty.txt"
  CCCC_ALLOW_DIRTY=1 CCCC_FAKE_SCENARIO=dirty-twice run_delegate claude
  assert_eq 4 "$CASE_RC" || return 1
  case "$CASE_OUTPUT" in *path_hex=6261642f64697274792e747874*) return 0 ;; esac
  test_diag 'second mutation path was not reported'
  return 1
}

test_unborn_repository_succeeds() {
  prepare_case || return 1
  git -C "$CASE_REPO" update-ref -d HEAD || return 1
  CCCC_ALLOW_DIRTY=1 run_delegate codex
  assert_success_outputs || return 1
  grep -q '^head_before=CCCC_UNBORN_HEAD$' "$CASE_REPO/docs/tasks/T-test.log"
}

test_head_change_is_policy_failure() {
  prepare_case || return 1
  CCCC_FAKE_REAL_GIT=$(command -v git) CCCC_FAKE_SCENARIO=commit run_delegate claude
  assert_eq 4 "$CASE_RC" || return 1
  [ ! -e "$CASE_REPO/docs/tasks/T-test-report.md" ] || return 1
  case "$CASE_OUTPUT" in *HEAD*changed*) return 0 ;; esac
  return 1
}

test_card_content_change_is_policy_failure() {
  prepare_case || return 1
  printf 'docs/tasks/T-test.md\n' >>"$CASE_REPO/.gitignore"
  git -C "$CASE_REPO" rm -q --cached docs/tasks/T-test.md || return 1
  git -C "$CASE_REPO" add .gitignore || return 1
  git -C "$CASE_REPO" commit -q -m ignore-card || return 1
  CCCC_FAKE_CARD="$CASE_CARD" CCCC_FAKE_SCENARIO=modify-card run_delegate claude
  assert_eq 4 "$CASE_RC" || return 1
  [ ! -e "$CASE_REPO/docs/tasks/T-test-report.md" ] || return 1
  [ ! -e "$CASE_REPO/docs/tasks/T-test.log" ]
}

test_card_parent_regular_inode_swap_is_policy_failure() {
  local external
  require_posix_inode_capability || return 77
  prepare_case || return 1
  external="$CASE_DIR/external-tasks"
  CCCC_FAKE_CARD="$CASE_CARD" CCCC_FAKE_EXTERNAL="$external" \
    CCCC_FAKE_SCENARIO=replace-card-parent run_delegate claude
  assert_eq 4 "$CASE_RC" || return 1
  [ ! -e "$external/original-tasks/T-test-report.md" ] || return 1
  [ ! -e "$external/original-tasks/T-test.log" ] || return 1
  assert_eq '' "$(git -C "$CASE_REPO" status --porcelain=v1)" 'regular parent replacement changed Git status'
}

test_card_docs_ancestor_regular_inode_swap_is_policy_failure() {
  local external
  require_posix_inode_capability || return 77
  prepare_case || return 1
  external="$CASE_DIR/external-docs"
  CCCC_FAKE_CARD="$CASE_CARD" CCCC_FAKE_EXTERNAL="$external" \
    CCCC_FAKE_SCENARIO=replace-docs-ancestor run_delegate claude
  assert_eq 4 "$CASE_RC" || return 1
  [ ! -e "$external/original-docs/tasks/T-test-report.md" ] || return 1
  [ ! -e "$external/original-docs/tasks/T-test.log" ] || return 1
  assert_eq '' "$(git -C "$CASE_REPO" status --porcelain=v1)" 'docs ancestor replacement changed Git status'
}

test_agent_nonzero_empty_timeout_and_natural_124() {
  prepare_case || return 1
  CCCC_FAKE_SCENARIO=nonzero CCCC_FAKE_RC=23 run_delegate claude
  assert_eq 70 "$CASE_RC" 'agent nonzero mapping' || return 1
  case "$CASE_OUTPUT" in *agent_rc=23*) ;; *) return 1 ;; esac
  [ ! -e "$CASE_REPO/docs/tasks/T-test-report.md" ] || return 1

  prepare_case || return 1
  CCCC_FAKE_SCENARIO=empty run_delegate codex
  assert_eq 5 "$CASE_RC" 'empty report mapping' || return 1
  [ ! -e "$CASE_REPO/docs/tasks/T-test-report.md" ] || return 1

  prepare_case || return 1
  CCCC_TIMEOUT=1 CCCC_FAKE_SCENARIO=timeout run_delegate claude
  assert_eq 124 "$CASE_RC" 'timeout mapping' || return 1
  case "$CASE_OUTPUT" in *'cccc-timeout: command exceeded 1 seconds'*) ;; *) return 1 ;; esac
  [ ! -e "$CASE_REPO/docs/tasks/T-test-report.md" ] || return 1

  prepare_case || return 1
  CCCC_FAKE_SCENARIO=natural-124 run_delegate claude
  assert_eq 70 "$CASE_RC" 'natural 124 mapping' || return 1
  case "$CASE_OUTPUT" in *agent_rc=124*) return 0 ;; esac
  return 1
}

test_trusted_runner_outcome_maps_natural_reserved_statuses() {
  local status
  for status in 2 124 125 127; do
    prepare_case || return 1
    CCCC_FAKE_NATURAL_RC="$status" CCCC_FAKE_SCENARIO=natural-status run_delegate claude
    assert_eq 70 "$CASE_RC" "natural child $status mapping" || return 1
    case "$CASE_OUTPUT" in *"agent_rc=$status"*) ;; *) return 1 ;; esac
  done
}

test_trusted_runner_launch_failure_maps_127() {
  prepare_case || return 1
  printf '%s\n' '#!/definitely/missing/cccc-interpreter' >"$CASE_BIN/claude"
  chmod +x "$CASE_BIN/claude" || return 1
  run_delegate claude
  assert_eq 127 "$CASE_RC" 'trusted runner launch status' || return 1
  assert_not_launched
}

test_policy_failure_precedes_agent_and_timeout_status() {
  prepare_case || return 1
  CCCC_FAKE_SCENARIO=nonzero-outside CCCC_FAKE_RC=29 run_delegate claude
  assert_eq 4 "$CASE_RC" 'policy beats agent nonzero' || return 1
  case "$CASE_OUTPUT" in *agent_rc=29*) ;; *) return 1 ;; esac

  prepare_case || return 1
  CCCC_TIMEOUT=2 CCCC_FAKE_SCENARIO=timeout-outside run_delegate claude
  assert_eq 4 "$CASE_RC" 'policy beats timeout' || {
    test_diag "timeout output: $CASE_OUTPUT"
    test_diag "timeout outside present: $([ -e "$CASE_REPO/bad/timeout-outside.txt" ] && printf yes || printf no)"
    return 1
  }
  case "$CASE_OUTPUT" in *agent_rc=124*) return 0 ;; esac
  return 1
}

test_cleanup_failure_precedes_policy_failure() {
  local real_python
  prepare_case || return 1
  real_python=$(command -v python3)
  cat >"$CASE_BIN/python3" <<'CLEANUP_SHIM'
#!/usr/bin/env bash
status_file=
intercept=0
previous=
for argument in "$@"; do
  case "$argument" in --status-file) intercept=1 ;; esac
  if [ "$previous" = --status-file ]; then status_file=$argument; fi
  previous=$argument
done
if [ "$intercept" -eq 1 ]; then
  mkdir -p "$CCCC_FAKE_REPO/bad"
  printf 'outside during cleanup failure\n' >"$CCCC_FAKE_REPO/bad/cleanup-outside.txt"
  if [ -n "$status_file" ]; then
    umask 077
    printf '%s\n' 'cccc-timeout-result-v1 kind=cleanup-failure value=none' >"$status_file"
    chmod 600 "$status_file"
  fi
  printf '%s\n' 'cccc-timeout: cleanup failed: injected wrapper test' >&2
  exit 125
fi
exec "$CCCC_REAL_PYTHON" "$@"
CLEANUP_SHIM
  chmod +x "$CASE_BIN/python3" || return 1
  CCCC_REAL_PYTHON="$real_python" CCCC_FAKE_REPO="$CASE_REPO" run_delegate claude
  assert_eq 125 "$CASE_RC" 'cleanup failure precedence' || return 1
  case "$CASE_OUTPUT" in *agent_rc=125*) return 0 ;; esac
  return 1
}

test_unsafe_or_inconsistent_runner_status_fails_closed() {
  local real_python mode status_pid attempts referent
  for mode in missing malformed symlink fifo unsafe-mode inconsistent; do
    prepare_case || return 1
    case "$mode" in
      symlink) require_symlink_capability "$CASE_DIR" || return 77 ;;
      fifo) require_fifo_capability "$CASE_DIR" || return 77 ;;
    esac
    real_python=$(command -v python3)
    cat >"$CASE_BIN/python3" <<'STATUS_SHIM'
#!/usr/bin/env bash
status_file=
intercept=0
previous=
for argument in "$@"; do
  case "$argument" in --status-file) intercept=1 ;; esac
  if [ "$previous" = --status-file ]; then status_file=$argument; fi
  previous=$argument
done
if [ "$intercept" -eq 1 ]; then
  case "$CCCC_STATUS_MODE" in
    missing) ;;
    malformed)
      umask 077
      printf '%s\n' 'forged status' >"$status_file"
      chmod 600 "$status_file"
      ;;
    symlink)
      umask 077
      printf '%s\n' 'cccc-timeout-result-v1 kind=child-exit value=0' >"$CCCC_STATUS_REFERENT"
      chmod 600 "$CCCC_STATUS_REFERENT"
      ln -s "$CCCC_STATUS_REFERENT" "$status_file"
      ;;
    fifo)
      mkfifo "$status_file"
      ;;
    unsafe-mode)
      printf '%s\n' 'cccc-timeout-result-v1 kind=child-exit value=0' >"$status_file"
      chmod 644 "$status_file"
      ;;
    inconsistent)
      umask 077
      printf '%s\n' 'cccc-timeout-result-v1 kind=child-exit value=0' >"$status_file"
      chmod 600 "$status_file"
      exit 23
      ;;
  esac
  exit 0
fi
exec "$CCCC_REAL_PYTHON" "$@"
STATUS_SHIM
    chmod +x "$CASE_BIN/python3" || return 1
    referent="$CASE_DIR/status-referent"
    CCCC_REAL_PYTHON="$real_python" CCCC_STATUS_MODE="$mode" \
      CCCC_STATUS_REFERENT="$referent" invoke_delegate_explicit \
        "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" "$CASE_ARGV" "$CASE_ENV" "$CASE_LAUNCH" \
        claude "$CASE_CARD" "$CASE_DIR/status-output" "$CASE_DIR/status-rc" &
    status_pid=$!
    attempts=500
    while [ ! -s "$CASE_DIR/status-rc" ] && [ "$attempts" -gt 0 ]; do
      sleep 0.02
      attempts=$((attempts - 1))
    done
    if [ ! -s "$CASE_DIR/status-rc" ]; then
      terminate_and_reap_pid "$status_pid" || true
      test_diag "$mode runner status invocation exceeded bounded wait"
      return 1
    fi
    wait_pid_bounded "$status_pid" 100 || terminate_and_reap_pid "$status_pid" || return 1
    CASE_RC=$(cat "$CASE_DIR/status-rc")
    assert_eq 125 "$CASE_RC" "$mode runner status mapping" || return 1
    [ ! -e "$CASE_REPO/docs/tasks/T-test-report.md" ] || return 1
    if [ "$mode" = symlink ]; then
      assert_eq 'cccc-timeout-result-v1 kind=child-exit value=0' "$(cat "$referent")" 'status symlink referent' || return 1
    fi
  done
}

test_signals_preserve_status_cleanup_child_and_release_lock() {
  local signal expected barrier wrapper_pid fake_pid attempts rc launcher_python
  case $(uname -s 2>/dev/null || true) in
    Darwin|Linux) ;;
    *) return 77 ;;
  esac
  for signal in HUP INT TERM; do
    case "$signal" in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
    prepare_case || return 1
    barrier="$CASE_DIR/barrier"
    mkdir -p "$barrier"
    launcher_python=$(command -v python3)
    (
      export PATH="$CASE_BIN:$ORIGINAL_PATH"
      export TMPDIR="$CASE_TMP"
      export CCCC_FAKE_ARGV_FILE="$CASE_ARGV"
      export CCCC_FAKE_ENV_FILE="$CASE_ENV"
      export CCCC_FAKE_LAUNCH_FILE="$CASE_LAUNCH"
      export CCCC_FAKE_BARRIER_DIR="$barrier"
      exec_delegate_with_signal_defaults "$launcher_python" claude "$CASE_CARD" "$CASE_REPO"
    ) >"$CASE_DIR/signal-output" 2>&1 &
    wrapper_pid=$!
    if ! wait_for_ready_count "$barrier" 1; then
      : >"$barrier/release"
      terminate_and_reap_pid "$wrapper_pid" || true
      return 1
    fi
    fake_pid=$(find "$barrier" -name 'ready.*' -type f | head -n 1)
    fake_pid=${fake_pid##*.}
    if ! kill -s "$signal" "$wrapper_pid"; then
      : >"$barrier/release"
      terminate_and_reap_pid "$wrapper_pid" || true
      return 1
    fi
    attempts=0
    while kill -0 "$wrapper_pid" 2>/dev/null && [ "$attempts" -lt 250 ]; do
      sleep 0.02
      attempts=$((attempts + 1))
    done
    if kill -0 "$wrapper_pid" 2>/dev/null; then
      : >"$barrier/release"
      terminate_and_reap_pid "$wrapper_pid" || true
      test_diag "wrapper did not exit after $signal"
      return 1
    fi
    wait "$wrapper_pid"
    rc=$?
    if kill -0 "$fake_pid" 2>/dev/null; then
      : >"$barrier/release"
      attempts=150
      while kill -0 "$fake_pid" 2>/dev/null && [ "$attempts" -gt 0 ]; do
        sleep 0.02
        attempts=$((attempts - 1))
      done
      if kill -0 "$fake_pid" 2>/dev/null; then
        terminate_external_pid "$fake_pid" || true
      fi
      test_diag "child survived wrapper $signal"
      return 1
    fi
    : >"$barrier/release"
    assert_eq "$expected" "$rc" "$signal wrapper status" || return 1
    run_delegate claude
    assert_success_outputs || return 1
  done
}

test_signal_runner_cleanup_failure_overrides_signal_with_125() {
  local real_python barrier wrapper_pid attempts rc signal
  require_posix_inode_capability || return 77
  for signal in HUP INT TERM; do
    prepare_case || return 1
    real_python=$(command -v python3)
    barrier="$CASE_DIR/runner-cleanup-barrier"
    mkdir -p "$barrier"
    cat >"$CASE_BIN/python3" <<'RUNNER_CLEANUP_SIGNAL_SHIM'
#!/usr/bin/env bash
status_file=
intercept=0
previous=
for argument in "$@"; do
  case "$argument" in --status-file) intercept=1 ;; esac
  if [ "$previous" = --status-file ]; then status_file=$argument; fi
  previous=$argument
done
if [ "$intercept" -eq 1 ]; then
  exec "$CCCC_REAL_PYTHON" - "$status_file" "$CCCC_RUNNER_SIGNAL_BARRIER" <<'PY'
import os
import signal
import sys
import time

status_file, barrier = sys.argv[1:]

def cleanup_failure(signum, frame):
    descriptor = os.open(status_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="ascii") as stream:
        stream.write("cccc-timeout-result-v1 kind=cleanup-failure value=none\n")
    os.chmod(status_file, 0o600)
    raise SystemExit(125)

for name in ("SIGHUP", "SIGINT", "SIGTERM"):
    if hasattr(signal, name):
        signal.signal(getattr(signal, name), cleanup_failure)
open(os.path.join(barrier, "ready.%d" % os.getpid()), "wb").close()
while not os.path.exists(os.path.join(barrier, "release")):
    time.sleep(0.02)
PY
fi
exec "$CCCC_REAL_PYTHON" "$@"
RUNNER_CLEANUP_SIGNAL_SHIM
    chmod +x "$CASE_BIN/python3" || return 1
    (
      export PATH="$CASE_BIN:$ORIGINAL_PATH" TMPDIR="$CASE_TMP"
      export CCCC_REAL_PYTHON="$real_python" CCCC_RUNNER_SIGNAL_BARRIER="$barrier"
      export CCCC_FAKE_ARGV_FILE="$CASE_ARGV" CCCC_FAKE_ENV_FILE="$CASE_ENV"
      export CCCC_FAKE_LAUNCH_FILE="$CASE_LAUNCH"
      exec_delegate_with_signal_defaults "$real_python" claude "$CASE_CARD" "$CASE_REPO"
    ) >"$CASE_DIR/runner-cleanup-output" 2>&1 & wrapper_pid=$!
    if ! wait_for_ready_count "$barrier" 1; then
      : >"$barrier/release"
      terminate_and_reap_pid "$wrapper_pid" || true
      return 1
    fi
    if ! kill -s "$signal" "$wrapper_pid"; then
      : >"$barrier/release"
      terminate_and_reap_pid "$wrapper_pid" || true
      return 1
    fi
    attempts=250
    while kill -0 "$wrapper_pid" 2>/dev/null && [ "$attempts" -gt 0 ]; do
      sleep 0.02
      attempts=$((attempts - 1))
    done
    if kill -0 "$wrapper_pid" 2>/dev/null; then
      : >"$barrier/release"
      terminate_and_reap_pid "$wrapper_pid" || true
      test_diag "wrapper did not resolve runner cleanup failure after $signal"
      return 1
    fi
    wait "$wrapper_pid"; rc=$?
    : >"$barrier/release"
    assert_eq 125 "$rc" "runner cleanup failure beats $signal" || return 1
    case $(cat "$CASE_DIR/runner-cleanup-output") in
      *'cccc: delegated report:'*) return 1 ;;
    esac
  done
}

test_natural_child_background_descendant_is_cleaned() {
  local sentinel
  case $(uname -s 2>/dev/null || true) in
    Darwin|Linux) ;;
    *) return 77 ;;
  esac
  prepare_case || return 1
  sentinel="$CASE_DIR/late-writer"
  CCCC_FAKE_SENTINEL="$sentinel" CCCC_FAKE_SCENARIO=background-writer run_delegate claude
  assert_success_outputs || return 1
  sleep 0.8
  [ ! -e "$sentinel" ] || {
    test_diag 'background descendant survived natural child exit'
    return 1
  }
}

test_codex_unsafe_report_sources_fail_boundedly() {
  local referent fifo_pid attempts
  prepare_case || return 1
  require_symlink_capability "$CASE_DIR" || return 77
  referent="$CASE_DIR/report-referent"
  CCCC_FAKE_REFERENT="$referent" CCCC_FAKE_SCENARIO=report-symlink run_delegate codex
  assert_eq 5 "$CASE_RC" 'symlink report source status' || return 1
  [ ! -e "$CASE_REPO/docs/tasks/T-test-report.md" ] || return 1

  prepare_case || return 1
  require_fifo_capability "$CASE_DIR" || return 77
  CCCC_FAKE_SCENARIO=report-fifo invoke_delegate_explicit \
    "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" "$CASE_ARGV" "$CASE_ENV" "$CASE_LAUNCH" \
    codex "$CASE_CARD" "$CASE_DIR/fifo-output" "$CASE_DIR/fifo-rc" &
  fifo_pid=$!
  attempts=500
  while [ ! -s "$CASE_DIR/fifo-rc" ] && [ "$attempts" -gt 0 ]; do
    sleep 0.02
    attempts=$((attempts - 1))
  done
  if [ ! -s "$CASE_DIR/fifo-rc" ]; then
    terminate_and_reap_pid "$fifo_pid" || true
    test_diag 'FIFO report source invocation exceeded bounded wait'
    return 1
  fi
  wait_pid_bounded "$fifo_pid" 100 || terminate_and_reap_pid "$fifo_pid" || return 1
  CASE_RC=$(cat "$CASE_DIR/fifo-rc")
  assert_eq 5 "$CASE_RC" 'FIFO report source status' || return 1
  [ ! -e "$CASE_REPO/docs/tasks/T-test-report.md" ]
}

test_dirty_untracked_and_index_only_second_changes_are_detected() {
  prepare_case || return 1
  printf 'first mutation\n' >"$CASE_REPO/bad/untracked.txt"
  CCCC_ALLOW_DIRTY=1 CCCC_FAKE_SCENARIO=untracked-dirty-twice run_delegate claude
  assert_eq 4 "$CASE_RC" 'dirty untracked second change status' || return 1

  prepare_case || return 1
  printf 'first mutation\n' >>"$CASE_REPO/bad/dirty.txt"
  CCCC_ALLOW_DIRTY=1 CCCC_FAKE_REAL_GIT="$(command -v git)" \
    CCCC_FAKE_SCENARIO=index-only run_delegate claude
  assert_eq 4 "$CASE_RC" 'index-only second change status'
}

test_unchanged_dirty_out_of_policy_baseline_is_not_attributed_to_child() {
  prepare_case || return 1
  printf 'tracked baseline dirty\n' >>"$CASE_REPO/bad/dirty.txt"
  CCCC_ALLOW_DIRTY=1 run_delegate claude
  assert_success_outputs || return 1

  prepare_case || return 1
  printf 'untracked baseline dirty\n' >"$CASE_REPO/bad/untracked-control.txt"
  CCCC_ALLOW_DIRTY=1 run_delegate claude
  assert_success_outputs || return 1

  prepare_case || return 1
  printf 'index baseline dirty\n' >>"$CASE_REPO/bad/dirty.txt"
  git -C "$CASE_REPO" add bad/dirty.txt || return 1
  CCCC_ALLOW_DIRTY=1 run_delegate claude
  assert_success_outputs
}

test_newline_out_of_policy_path_is_escaped() {
  local expected_hex
  require_posix_inode_capability || return 77
  prepare_case || return 1
  CCCC_FAKE_SCENARIO=newline-outside run_delegate claude
  assert_eq 4 "$CASE_RC" || return 1
  expected_hex=$(printf 'bad/line\nforged-agent_rc=0' | python3 -c 'import sys; print(sys.stdin.buffer.read().hex())')
  case "$CASE_OUTPUT" in *"path_hex=$expected_hex"*) ;; *)
    test_diag 'newline path was not rendered as one escaped diagnostic'
    return 1
    ;;
  esac
  case "$CASE_OUTPUT" in *$'\nforged-agent_rc=0'*) return 1 ;; esac
}

test_stale_and_existing_outputs_never_satisfy_run() {
  prepare_case || return 1
  printf 'stale report\n' >"$CASE_REPO/docs/tasks/T-test-report.md"
  run_delegate claude
  assert_eq 5 "$CASE_RC" || return 1
  assert_not_launched || return 1
  assert_eq 'stale report' "$(cat "$CASE_REPO/docs/tasks/T-test-report.md")" || return 1

  prepare_case || return 1
  printf 'stale log\n' >"$CASE_REPO/docs/tasks/T-test.log"
  run_delegate claude
  assert_eq 5 "$CASE_RC" || return 1
  assert_not_launched || return 1
  assert_eq 'stale log' "$(cat "$CASE_REPO/docs/tasks/T-test.log")"
}

test_symlink_and_fifo_outputs_are_never_clobbered() {
  local kind target referent output_pid attempts
  for kind in report log; do
    prepare_case || return 1
    require_symlink_capability "$CASE_DIR" || return 77
    case "$kind" in
      report) target="$CASE_REPO/docs/tasks/T-test-report.md" ;;
      log) target="$CASE_REPO/docs/tasks/T-test.log" ;;
    esac
    referent="$CASE_DIR/$kind-referent"
    printf 'unchanged\n' >"$referent"
    ln -s "$referent" "$target" || return 77
    run_delegate claude
    assert_eq 5 "$CASE_RC" "$kind symlink output status" || return 1
    assert_not_launched || return 1
    assert_eq unchanged "$(cat "$referent")" "$kind symlink referent" || return 1

    prepare_case || return 1
    require_fifo_capability "$CASE_DIR" || return 77
    case "$kind" in
      report) target="$CASE_REPO/docs/tasks/T-test-report.md" ;;
      log) target="$CASE_REPO/docs/tasks/T-test.log" ;;
    esac
    mkfifo "$target" || return 77
    invoke_delegate_explicit "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" "$CASE_ARGV" \
      "$CASE_ENV" "$CASE_LAUNCH" claude "$CASE_CARD" \
      "$CASE_DIR/$kind-fifo-output" "$CASE_DIR/$kind-fifo-rc" &
    output_pid=$!
    attempts=500
    while [ ! -s "$CASE_DIR/$kind-fifo-rc" ] && [ "$attempts" -gt 0 ]; do
      sleep 0.02
      attempts=$((attempts - 1))
    done
    if [ ! -s "$CASE_DIR/$kind-fifo-rc" ]; then
      terminate_and_reap_pid "$output_pid" || true
      test_diag "$kind FIFO output preflight exceeded bounded wait"
      return 1
    fi
    wait_pid_bounded "$output_pid" 100 || terminate_and_reap_pid "$output_pid" || return 1
    assert_eq 5 "$(cat "$CASE_DIR/$kind-fifo-rc")" "$kind FIFO output status" || return 1
    assert_not_launched || return 1
  done
}

test_post_preflight_output_injection_is_not_published() {
  local referent
  prepare_case || return 1
  require_symlink_capability "$CASE_DIR" || return 77
  referent="$CASE_DIR/referent"
  printf 'unchanged\n' >"$referent"
  printf 'docs/tasks/T-test-report.md\n' >>"$CASE_REPO/.git/info/exclude"
  CCCC_FAKE_SCENARIO=inject-symlink CCCC_FAKE_DEST="$CASE_REPO/docs/tasks/T-test-report.md" \
    CCCC_FAKE_REFERENT="$referent" run_delegate claude
  assert_eq 5 "$CASE_RC" 'snapshot-invisible publication collision status' || return 1
  assert_eq unchanged "$(cat "$referent")" || return 1
  [ -L "$CASE_REPO/docs/tasks/T-test-report.md" ]
}

test_report_publish_failure_leaves_diagnostic_orphan_log() {
  local real_python publish_count report referent log_before
  prepare_case || return 1
  require_symlink_capability "$CASE_DIR" || return 77
  real_python=$(command -v python3)
  publish_count="$CASE_DIR/publish-count"
  report="$CASE_REPO/docs/tasks/T-test-report.md"
  referent="$CASE_DIR/injected-report-referent"
  printf 'do not overwrite\n' >"$referent"
  printf '0\n' >"$publish_count"
  cat >"$CASE_BIN/python3" <<'PUBLISH_SHIM'
#!/usr/bin/env bash
is_publish=0
destination=
for argument in "$@"; do
  if [ "$argument" = --parent-identity ]; then is_publish=1; fi
  destination=$argument
done
if [ "$is_publish" -eq 1 ]; then
  count=$(cat "$CCCC_PUBLISH_COUNT")
  count=$((count + 1))
  printf '%s\n' "$count" >"$CCCC_PUBLISH_COUNT"
  case "$count:$destination" in
    2:*/docs/tasks/T-test-report.md)
      ln -s "$CCCC_INJECT_REFERENT" "$destination"
      printf '%s\n' 'cccc publish: injected report commit failure' >&2
      exit 5
      ;;
  esac
fi
exec "$CCCC_REAL_PYTHON" "$@"
PUBLISH_SHIM
  chmod +x "$CASE_BIN/python3" || return 1
  CCCC_REAL_PYTHON="$real_python" CCCC_PUBLISH_COUNT="$publish_count" \
    CCCC_INJECT_REFERENT="$referent" CCCC_INJECT_REPORT="$report" run_delegate claude
  assert_eq 5 "$CASE_RC" 'report publication failure status' || {
    test_diag "publish count: $(cat "$publish_count" 2>/dev/null || printf unreadable)"
    test_diag "publication output: $CASE_OUTPUT"
    return 1
  }
  [ -s "$CASE_REPO/docs/tasks/T-test.log" ] || {
    test_diag 'published diagnostic log was not preserved'
    return 1
  }
  [ -L "$report" ] || {
    test_diag 'report-race injection was not preserved for the no-clobber assertion'
    return 1
  }
  assert_eq 'do not overwrite' "$(cat "$referent")" 'injected report referent' || return 1
  case "$CASE_OUTPUT" in *'cccc: delegated report:'*)
    test_diag 'failed report publication printed a success marker'
    return 1
    ;;
  esac
  case "$CASE_OUTPUT" in *orphan*log*remove*'T-test.log'*) ;; *)
    test_diag 'missing explicit orphan-log recovery diagnostic'
    return 1
    ;;
  esac
  log_before=$(cksum "$CASE_REPO/docs/tasks/T-test.log") || return 1
  unlink "$report" || return 1
  : >"$CASE_LAUNCH"
  CCCC_REAL_PYTHON="$real_python" CCCC_PUBLISH_COUNT="$publish_count" \
    CCCC_INJECT_REFERENT="$referent" CCCC_INJECT_REPORT="$report" run_delegate claude
  assert_eq 5 "$CASE_RC" 'orphan-log retry status' || return 1
  assert_not_launched || return 1
  assert_eq "$log_before" "$(cksum "$CASE_REPO/docs/tasks/T-test.log")" 'orphan log changed on retry'
}

test_publish_parent_identity_rejects_last_moment_regular_swap() {
  local real_python external
  prepare_case || return 1
  require_posix_inode_capability || return 77
  real_python=$(command -v python3)
  external="$CASE_DIR/publish-parent-external"
  cat >"$CASE_BIN/python3" <<'PARENT_RACE_SHIM'
#!/usr/bin/env bash
is_publish=0
for argument in "$@"; do
  if [ "$argument" = --parent-identity ]; then is_publish=1; fi
done
if [ "$is_publish" -eq 1 ] && [ ! -e "$CCCC_PARENT_RACE_ONCE" ]; then
  : >"$CCCC_PARENT_RACE_ONCE"
  mkdir -p "$CCCC_PARENT_RACE_EXTERNAL"
  mv "$CCCC_PARENT_RACE_REPO/docs/tasks" "$CCCC_PARENT_RACE_EXTERNAL/original-tasks"
  mkdir "$CCCC_PARENT_RACE_REPO/docs/tasks"
  cp "$CCCC_PARENT_RACE_EXTERNAL/original-tasks/T-test.md" \
    "$CCCC_PARENT_RACE_REPO/docs/tasks/T-test.md"
fi
exec "$CCCC_REAL_PYTHON" "$@"
PARENT_RACE_SHIM
  chmod +x "$CASE_BIN/python3" || return 1
  CCCC_REAL_PYTHON="$real_python" CCCC_PARENT_RACE_ONCE="$CASE_DIR/parent-raced" \
    CCCC_PARENT_RACE_EXTERNAL="$external" CCCC_PARENT_RACE_REPO="$CASE_REPO" run_delegate claude
  assert_eq 5 "$CASE_RC" 'publish parent identity race status' || return 1
  [ ! -e "$CASE_REPO/docs/tasks/T-test.log" ] || return 1
  [ ! -e "$CASE_REPO/docs/tasks/T-test-report.md" ] || return 1
  [ ! -e "$external/original-tasks/T-test.log" ] || return 1
  [ ! -e "$external/original-tasks/T-test-report.md" ] || return 1
  assert_eq '' "$(git -C "$CASE_REPO" status --porcelain=v1)" 'publish parent race changed Git status'
}

wait_for_ready_count() {
  local directory=$1 wanted=$2 attempts=0 count
  while [ "$attempts" -lt 500 ]; do
    count=$(find "$directory" -name 'ready.*' -type f 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -ge "$wanted" ] && return 0
    sleep 0.02
    attempts=$((attempts + 1))
  done
  return 1
}

wait_pid_bounded() {
  local pid=$1 attempts=${2:-250}
  while kill -0 "$pid" 2>/dev/null && [ "$attempts" -gt 0 ]; do
    sleep 0.02
    attempts=$((attempts - 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  wait "$pid" 2>/dev/null || true
  return 0
}

terminate_and_reap_pid() {
  local pid=$1
  kill -TERM "$pid" 2>/dev/null || true
  if ! wait_pid_bounded "$pid" 150; then
    kill -KILL "$pid" 2>/dev/null || true
    wait_pid_bounded "$pid" 150 || return 1
  fi
  return 0
}

terminate_external_pid() {
  local pid=$1 attempts=150
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -TERM "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$attempts" -gt 0 ]; do
    sleep 0.02
    attempts=$((attempts - 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

assert_repo_lock_rejects_second() {
  local second_card=$1 barrier first_pid second_pid second_launch attempts
  prepare_case || return 1
  if [ "$second_card" != "$CASE_CARD" ]; then
    write_card "$CASE_REPO" "$second_card" src/ || return 1
    git -C "$CASE_REPO" add "$second_card" || return 1
    git -C "$CASE_REPO" commit -q -m second-card || return 1
  fi
  printf 'dirty before lock\n' >>"$CASE_REPO/src/allowed.txt"
  barrier="$CASE_DIR/barrier"
  second_launch="$CASE_DIR/second-launched.txt"
  mkdir -p "$barrier"
  CCCC_ALLOW_DIRTY=1 CCCC_FAKE_BARRIER_DIR="$barrier" \
    invoke_delegate_explicit "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" \
      "$CASE_DIR/first-argv" "$CASE_DIR/first-env" "$CASE_LAUNCH" \
      codex "$CASE_CARD" "$CASE_DIR/first-output" "$CASE_DIR/first-rc" &
  first_pid=$!
  if ! wait_for_ready_count "$barrier" 1; then
    : >"$barrier/release"
    wait_pid_bounded "$first_pid" 150 || terminate_and_reap_pid "$first_pid" || true
    return 1
  fi

  invoke_delegate_explicit "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" \
    "$CASE_DIR/second-argv" "$CASE_DIR/second-env" "$second_launch" \
    claude "$second_card" "$CASE_DIR/second-output" "$CASE_DIR/second-rc" &
  second_pid=$!
  attempts=250
  while [ ! -s "$CASE_DIR/second-rc" ] && [ "$attempts" -gt 0 ]; do
    sleep 0.02
    attempts=$((attempts - 1))
  done
  if [ ! -s "$CASE_DIR/second-rc" ]; then
    : >"$barrier/release"
    terminate_and_reap_pid "$second_pid" || true
    terminate_and_reap_pid "$first_pid" || true
    test_diag 'repo-lock loser waited instead of failing closed'
    return 1
  fi
  wait_pid_bounded "$second_pid" 100 || terminate_and_reap_pid "$second_pid" || return 1
  assert_eq 5 "$(cat "$CASE_DIR/second-rc")" 'repo-lock collision status' || {
    : >"$barrier/release"
    wait_pid_bounded "$first_pid" 150 || terminate_and_reap_pid "$first_pid" || true
    return 1
  }
  [ ! -s "$second_launch" ] || {
    : >"$barrier/release"
    wait_pid_bounded "$first_pid" 150 || terminate_and_reap_pid "$first_pid" || true
    test_diag 'second same-repository fake agent was launched'
    return 1
  }
  : >"$barrier/release"
  wait_pid_bounded "$first_pid" 300 || terminate_and_reap_pid "$first_pid" || return 1
  assert_eq 0 "$(cat "$CASE_DIR/first-rc")" 'lock owner status'
}

test_repo_lock_blocks_same_and_different_cards() {
  assert_repo_lock_rejects_second docs/tasks/T-test.md || return 1
  assert_repo_lock_rejects_second docs/tasks/T-other.md
}

test_repo_lock_is_acquired_before_git_status_baseline() {
  local real_git barrier first_pid second_pid status_count second_launch attempts
  prepare_case || return 1
  real_git=$(command -v git)
  barrier="$CASE_DIR/git-status-barrier"
  second_launch="$CASE_DIR/second-launched"
  mkdir -p "$barrier"
  cat >"$CASE_BIN/git" <<'STATUS_GIT_SHIM'
#!/usr/bin/env bash
is_status=0
for argument in "$@"; do
  if [ "$argument" = status ]; then is_status=1; fi
done
if [ "$is_status" -eq 1 ]; then
  printf 'status\n' >>"$CCCC_GIT_STATUS_LOG"
  if [ -n "${CCCC_GIT_STATUS_BARRIER-}" ]; then
    : >"$CCCC_GIT_STATUS_BARRIER/ready.$$"
    while [ ! -e "$CCCC_GIT_STATUS_BARRIER/release" ]; do sleep 0.02; done
  fi
fi
exec "$CCCC_FAKE_REAL_GIT" "$@"
STATUS_GIT_SHIM
  chmod +x "$CASE_BIN/git" || return 1
  CCCC_GIT_STATUS_LOG="$CASE_DIR/status.log" CCCC_GIT_STATUS_BARRIER="$barrier" \
    CCCC_FAKE_REAL_GIT="$real_git" invoke_delegate_explicit \
      "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" "$CASE_DIR/first-argv" "$CASE_DIR/first-env" \
      "$CASE_LAUNCH" claude "$CASE_CARD" "$CASE_DIR/first-output" "$CASE_DIR/first-rc" &
  first_pid=$!
  if ! wait_for_ready_count "$barrier" 1; then
    : >"$barrier/release"
    terminate_and_reap_pid "$first_pid" || true
    return 1
  fi
  CCCC_GIT_STATUS_LOG="$CASE_DIR/status.log" CCCC_FAKE_REAL_GIT="$real_git" \
    invoke_delegate_explicit "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" \
      "$CASE_DIR/second-argv" "$CASE_DIR/second-env" "$second_launch" \
      codex "$CASE_CARD" "$CASE_DIR/second-output" "$CASE_DIR/second-rc" &
  second_pid=$!
  attempts=250
  while [ ! -s "$CASE_DIR/second-rc" ] && [ "$attempts" -gt 0 ]; do
    sleep 0.02
    attempts=$((attempts - 1))
  done
  if [ ! -s "$CASE_DIR/second-rc" ]; then
    : >"$barrier/release"
    terminate_and_reap_pid "$second_pid" || true
    terminate_and_reap_pid "$first_pid" || true
    test_diag 'baseline lock loser waited instead of returning 5'
    return 1
  fi
  wait_pid_bounded "$second_pid" 100 || terminate_and_reap_pid "$second_pid" || return 1
  assert_eq 5 "$(cat "$CASE_DIR/second-rc")" 'baseline barrier lock collision' || {
    : >"$barrier/release"; terminate_and_reap_pid "$first_pid" || true; return 1;
  }
  status_count=$(wc -l <"$CASE_DIR/status.log" | tr -d ' ')
  assert_eq 1 "$status_count" 'second invocation reached Git status before repo lock' || {
    : >"$barrier/release"; terminate_and_reap_pid "$first_pid" || true; return 1;
  }
  [ ! -s "$second_launch" ] || {
    : >"$barrier/release"; terminate_and_reap_pid "$first_pid" || true; return 1;
  }
  : >"$barrier/release"
  wait_pid_bounded "$first_pid" 300 || terminate_and_reap_pid "$first_pid" || return 1
  assert_eq 0 "$(cat "$CASE_DIR/first-rc")" 'baseline barrier lock owner status'
}

test_repo_lock_is_shared_by_linked_worktrees() {
  local linked barrier first_pid second_pid second_launch attempts
  prepare_case || return 1
  linked="$CASE_DIR/linked-worktree"
  git -C "$CASE_REPO" worktree add -q -b linked-test "$linked" || return 1
  barrier="$CASE_DIR/linked-barrier"
  second_launch="$CASE_DIR/linked-second-launch"
  mkdir -p "$barrier"
  CCCC_FAKE_BARRIER_DIR="$barrier" invoke_delegate_explicit \
    "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" "$CASE_DIR/first-argv" "$CASE_DIR/first-env" \
    "$CASE_LAUNCH" claude "$CASE_CARD" "$CASE_DIR/first-output" "$CASE_DIR/first-rc" &
  first_pid=$!
  if ! wait_for_ready_count "$barrier" 1; then
    : >"$barrier/release"; terminate_and_reap_pid "$first_pid" || true; return 1
  fi
  invoke_delegate_explicit "$linked" "$CASE_BIN" "$CASE_TMP" "$CASE_DIR/second-argv" \
    "$CASE_DIR/second-env" "$second_launch" codex "$CASE_CARD" \
    "$CASE_DIR/second-output" "$CASE_DIR/second-rc" &
  second_pid=$!
  attempts=250
  while [ ! -s "$CASE_DIR/second-rc" ] && [ "$attempts" -gt 0 ]; do
    sleep 0.02
    attempts=$((attempts - 1))
  done
  if [ ! -s "$CASE_DIR/second-rc" ]; then
    : >"$barrier/release"
    terminate_and_reap_pid "$second_pid" || true
    terminate_and_reap_pid "$first_pid" || true
    test_diag 'linked-worktree lock loser waited instead of returning 5'
    return 1
  fi
  wait_pid_bounded "$second_pid" 100 || terminate_and_reap_pid "$second_pid" || return 1
  assert_eq 5 "$(cat "$CASE_DIR/second-rc")" 'linked-worktree repo lock status' || {
    : >"$barrier/release"; terminate_and_reap_pid "$first_pid" || true; return 1;
  }
  [ ! -s "$second_launch" ] || {
    : >"$barrier/release"; terminate_and_reap_pid "$first_pid" || true; return 1;
  }
  : >"$barrier/release"
  wait_pid_bounded "$first_pid" 300 || terminate_and_reap_pid "$first_pid" || return 1
  assert_eq 0 "$(cat "$CASE_DIR/first-rc")" 'linked-worktree lock owner status'
}

test_repo_lock_signal_window_cleans_before_retry() {
  local real_ln
  require_posix_inode_capability || return 77
  prepare_case || return 1
  real_ln=$(command -v ln)
  cat >"$CASE_BIN/ln" <<'LN_SIGNAL_SHIM'
#!/usr/bin/env bash
"$CCCC_REAL_LN" "$@"
rc=$?
case ${!#} in */cccc-v2.lock)
  if [ "$rc" -eq 0 ]; then kill -HUP "$PPID"; fi
  ;;
esac
exit "$rc"
LN_SIGNAL_SHIM
  chmod +x "$CASE_BIN/ln" || return 1
  CCCC_REAL_LN="$real_ln" run_delegate claude
  assert_eq 129 "$CASE_RC" 'lock acquisition signal status' || return 1
  assert_not_launched || return 1
  unlink "$CASE_BIN/ln" || return 1
  : >"$CASE_LAUNCH"
  run_delegate claude
  assert_success_outputs
}

test_old_owner_never_deletes_replacement_lock_inode() {
  local barrier wrapper_pid common lock rc fake_pid attempts
  require_posix_inode_capability || return 77
  prepare_case || return 1
  common=$(git -C "$CASE_REPO" rev-parse --git-common-dir) || return 1
  case "$common" in /*) ;; *) common="$CASE_REPO/$common" ;; esac
  common=$(CDPATH= cd -P -- "$common" && pwd) || return 1
  lock="$common/cccc-v2.lock"
  barrier="$CASE_DIR/owner-barrier"
  mkdir -p "$barrier"
  (
    export PATH="$CASE_BIN:$ORIGINAL_PATH" TMPDIR="$CASE_TMP"
    export CCCC_FAKE_ARGV_FILE="$CASE_ARGV" CCCC_FAKE_ENV_FILE="$CASE_ENV"
    export CCCC_FAKE_LAUNCH_FILE="$CASE_LAUNCH" CCCC_FAKE_BARRIER_DIR="$barrier"
    exec "$DELEGATE" claude "$CASE_CARD" "$CASE_REPO"
  ) >"$CASE_DIR/owner-output" 2>&1 &
  wrapper_pid=$!
  if ! wait_for_ready_count "$barrier" 1; then
    : >"$barrier/release"; terminate_and_reap_pid "$wrapper_pid" || true; return 1
  fi
  fake_pid=$(find "$barrier" -name 'ready.*' -type f | head -n 1); fake_pid=${fake_pid##*.}
  [ -f "$lock" ] && [ ! -L "$lock" ] || { : >"$barrier/release"; terminate_and_reap_pid "$wrapper_pid" || true; return 1; }
  unlink "$lock" || return 1
  printf 'winner inode\n' >"$lock"
  kill -TERM "$wrapper_pid" || return 1
  attempts=250
  while kill -0 "$wrapper_pid" 2>/dev/null && [ "$attempts" -gt 0 ]; do sleep 0.02; attempts=$((attempts - 1)); done
  if kill -0 "$wrapper_pid" 2>/dev/null; then
    : >"$barrier/release"; terminate_and_reap_pid "$wrapper_pid" || true; return 1
  fi
  wait "$wrapper_pid"; rc=$?
  : >"$barrier/release"
  if kill -0 "$fake_pid" 2>/dev/null; then terminate_external_pid "$fake_pid" || true; fi
  assert_eq 125 "$rc" 'replacement-lock ownership loss status' || return 1
  assert_eq 'winner inode' "$(cat "$lock")" 'old owner deleted replacement lock' || return 1
  unlink "$lock" || return 1
  : >"$CASE_LAUNCH"
  run_delegate claude
  assert_success_outputs
}

test_repo_lock_remains_held_during_publication() {
  local real_python barrier first_pid second_pid attempts second_launch
  prepare_case || return 1
  real_python=$(command -v python3)
  barrier="$CASE_DIR/publish-barrier"
  second_launch="$CASE_DIR/publish-second-launch"
  mkdir -p "$barrier"
  cat >"$CASE_BIN/python3" <<'PUBLISH_BARRIER_SHIM'
#!/usr/bin/env bash
is_publish=0
for argument in "$@"; do if [ "$argument" = --parent-identity ]; then is_publish=1; fi; done
if [ "$is_publish" -eq 1 ] && [ ! -e "$CCCC_PUBLISH_BARRIER/once" ]; then
  : >"$CCCC_PUBLISH_BARRIER/once"
  : >"$CCCC_PUBLISH_BARRIER/ready.$$"
  while [ ! -e "$CCCC_PUBLISH_BARRIER/release" ]; do sleep 0.02; done
fi
exec "$CCCC_REAL_PYTHON" "$@"
PUBLISH_BARRIER_SHIM
  chmod +x "$CASE_BIN/python3" || return 1
  CCCC_REAL_PYTHON="$real_python" CCCC_PUBLISH_BARRIER="$barrier" \
    invoke_delegate_explicit "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" "$CASE_DIR/first-argv" \
      "$CASE_DIR/first-env" "$CASE_LAUNCH" claude "$CASE_CARD" \
      "$CASE_DIR/first-output" "$CASE_DIR/first-rc" & first_pid=$!
  if ! wait_for_ready_count "$barrier" 1; then
    : >"$barrier/release"; terminate_and_reap_pid "$first_pid" || true; return 1
  fi
  CCCC_REAL_PYTHON="$real_python" CCCC_PUBLISH_BARRIER="$barrier" \
    invoke_delegate_explicit "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" "$CASE_DIR/second-argv" \
      "$CASE_DIR/second-env" "$second_launch" codex "$CASE_CARD" \
      "$CASE_DIR/second-output" "$CASE_DIR/second-rc" & second_pid=$!
  attempts=250
  while [ ! -s "$CASE_DIR/second-rc" ] && [ "$attempts" -gt 0 ]; do sleep 0.02; attempts=$((attempts - 1)); done
  if [ ! -s "$CASE_DIR/second-rc" ]; then
    : >"$barrier/release"; terminate_and_reap_pid "$second_pid" || true; terminate_and_reap_pid "$first_pid" || true; return 1
  fi
  wait_pid_bounded "$second_pid" 100 || terminate_and_reap_pid "$second_pid" || return 1
  assert_eq 5 "$(cat "$CASE_DIR/second-rc")" 'publication-phase lock collision' || {
    : >"$barrier/release"; terminate_and_reap_pid "$first_pid" || true; return 1;
  }
  [ ! -s "$second_launch" ] || { : >"$barrier/release"; terminate_and_reap_pid "$first_pid" || true; return 1; }
  : >"$barrier/release"
  wait_pid_bounded "$first_pid" 300 || terminate_and_reap_pid "$first_pid" || return 1
  assert_eq 0 "$(cat "$CASE_DIR/first-rc")" 'publication lock owner status'
}

install_lock_release_failure_python() {
  local real_python=$1
  cat >"$CASE_BIN/python3" <<'LOCK_RELEASE_SHIM'
#!/usr/bin/env bash
if [ "$#" -eq 5 ] && [ "$1" = -I ] && [ "$2" = - ]; then
  case "$3" in */cccc-v2.lock) exit 9 ;; esac
fi
exec "$CCCC_REAL_PYTHON" "$@"
LOCK_RELEASE_SHIM
  chmod +x "$CASE_BIN/python3" || return 1
  CCCC_LOCK_REAL_PYTHON=$real_python
}

cleanup_injected_lock_files() {
  local common=$1 path
  [ ! -e "$common/cccc-v2.lock" ] || unlink "$common/cccc-v2.lock" || return 1
  for path in "$common"/.cccc-delegate-owner.*; do
    [ -e "$path" ] || continue
    unlink "$path" || return 1
  done
}

test_lock_release_failure_overrides_success_with_125() {
  local real_python common
  prepare_case || return 1
  real_python=$(command -v python3)
  install_lock_release_failure_python "$real_python" || return 1
  common=$(git -C "$CASE_REPO" rev-parse --git-common-dir) || return 1
  case "$common" in /*) ;; *) common="$CASE_REPO/$common" ;; esac
  common=$(CDPATH= cd -P -- "$common" && pwd) || return 1
  CCCC_REAL_PYTHON="$real_python" run_delegate claude
  assert_eq 125 "$CASE_RC" 'lock release failure success-path precedence' || {
    cleanup_injected_lock_files "$common" || true; return 1;
  }
  case "$CASE_OUTPUT" in *'cccc: delegated report:'*) cleanup_injected_lock_files "$common" || true; return 1 ;; esac
  [ -e "$common/cccc-v2.lock" ] || return 1
  cleanup_injected_lock_files "$common"
}

test_signal_lock_release_failure_overrides_signal_with_125() {
  local real_python common barrier wrapper_pid attempts rc
  require_posix_inode_capability || return 77
  prepare_case || return 1
  real_python=$(command -v python3)
  install_lock_release_failure_python "$real_python" || return 1
  common=$(git -C "$CASE_REPO" rev-parse --git-common-dir) || return 1
  case "$common" in /*) ;; *) common="$CASE_REPO/$common" ;; esac
  common=$(CDPATH= cd -P -- "$common" && pwd) || return 1
  barrier="$CASE_DIR/release-failure-barrier"
  mkdir -p "$barrier"
  (
    export PATH="$CASE_BIN:$ORIGINAL_PATH" TMPDIR="$CASE_TMP" CCCC_REAL_PYTHON="$real_python"
    export CCCC_FAKE_ARGV_FILE="$CASE_ARGV" CCCC_FAKE_ENV_FILE="$CASE_ENV"
    export CCCC_FAKE_LAUNCH_FILE="$CASE_LAUNCH" CCCC_FAKE_BARRIER_DIR="$barrier"
    exec "$DELEGATE" claude "$CASE_CARD" "$CASE_REPO"
  ) >"$CASE_DIR/release-signal-output" 2>&1 & wrapper_pid=$!
  if ! wait_for_ready_count "$barrier" 1; then
    : >"$barrier/release"; terminate_and_reap_pid "$wrapper_pid" || true; cleanup_injected_lock_files "$common" || true; return 1
  fi
  kill -HUP "$wrapper_pid" || return 1
  attempts=250
  while kill -0 "$wrapper_pid" 2>/dev/null && [ "$attempts" -gt 0 ]; do sleep 0.02; attempts=$((attempts - 1)); done
  if kill -0 "$wrapper_pid" 2>/dev/null; then
    : >"$barrier/release"; terminate_and_reap_pid "$wrapper_pid" || true; cleanup_injected_lock_files "$common" || true; return 1
  fi
  wait "$wrapper_pid"; rc=$?
  : >"$barrier/release"
  assert_eq 125 "$rc" 'lock release cleanup beats HUP' || {
    cleanup_injected_lock_files "$common" || true; return 1;
  }
  case $(cat "$CASE_DIR/release-signal-output") in
    *'cccc: delegated report:'*) cleanup_injected_lock_files "$common" || true; return 1 ;;
  esac
  cleanup_injected_lock_files "$common"
}

test_different_repositories_can_run_concurrently() {
  local a_dir a_repo a_bin a_tmp a_card b_dir b_repo b_bin b_tmp b_card
  local barrier pid1 pid2
  prepare_case || return 1
  a_dir=$CASE_DIR; a_repo=$CASE_REPO; a_bin=$CASE_BIN; a_tmp=$CASE_TMP; a_card=$CASE_CARD
  prepare_case || return 1
  b_dir=$CASE_DIR; b_repo=$CASE_REPO; b_bin=$CASE_BIN; b_tmp=$CASE_TMP; b_card=$CASE_CARD
  barrier="$TEST_TMP_ROOT/cross-repo-barrier"
  mkdir -p "$barrier"
  CCCC_FAKE_BARRIER_DIR="$barrier" CCCC_FAKE_REPORT=repo-one \
    invoke_delegate_explicit "$a_repo" "$a_bin" "$a_tmp" "$a_dir/argv" "$a_dir/env" \
      "$a_dir/launch" claude "$a_card" "$a_dir/output" "$a_dir/rc" & pid1=$!
  CCCC_FAKE_BARRIER_DIR="$barrier" CCCC_FAKE_REPORT=repo-two \
    invoke_delegate_explicit "$b_repo" "$b_bin" "$b_tmp" "$b_dir/argv" "$b_dir/env" \
      "$b_dir/launch" codex "$b_card" "$b_dir/output" "$b_dir/rc" & pid2=$!
  if ! wait_for_ready_count "$barrier" 2; then
    : >"$barrier/release"
    wait_pid_bounded "$pid1" 150 || terminate_and_reap_pid "$pid1" || true
    wait_pid_bounded "$pid2" 150 || terminate_and_reap_pid "$pid2" || true
    return 1
  fi
  : >"$barrier/release"
  wait_pid_bounded "$pid1" 300 || terminate_and_reap_pid "$pid1" || return 1
  wait_pid_bounded "$pid2" 300 || terminate_and_reap_pid "$pid2" || return 1
  assert_eq 0 "$(cat "$a_dir/rc")" 'first repository status' || return 1
  assert_eq 0 "$(cat "$b_dir/rc")" 'second repository status' || return 1
  assert_eq repo-one "$(cat "$a_repo/docs/tasks/T-test-report.md")" || return 1
  assert_eq repo-two "$(cat "$b_repo/docs/tasks/T-test-report.md")"
}

test_run_dir_is_private_and_owned_cleanup_is_scoped() {
  prepare_case || return 1
  CCCC_FAKE_RUN_MODE_FILE="$CASE_DIR/mode" run_delegate codex
  assert_success_outputs || return 1
  assert_eq 700 "$(cat "$CASE_DIR/mode")" 'run directory mode' || return 1
  if find "$CASE_TMP" -mindepth 1 -maxdepth 1 -type d -name 'cccc.*' -print -quit | grep -q .; then
    test_diag "owned run directory was not cleaned: $(find "$CASE_TMP" -mindepth 1 -maxdepth 1 -type d -name 'cccc.*' -print | tr '\n' ' ')"
    return 1
  fi
  if find "$CASE_REPO/docs/tasks" -name '*.cccc-claim' -print -quit | grep -q .; then
    test_diag 'owned publication claim was not cleaned'
    return 1
  fi
}

test_wrapper_never_invokes_forbidden_git_operations() {
  local real_git git_log forbidden
  prepare_case || return 1
  real_git=$(command -v git)
  git_log="$CASE_DIR/git.log"
  cat >"$CASE_BIN/git" <<'GIT'
#!/usr/bin/env bash
printf '%s\0' "$@" >>"$CCCC_FAKE_GIT_LOG"
printf '\n' >>"$CCCC_FAKE_GIT_LOG"
exec "$CCCC_FAKE_REAL_GIT" "$@"
GIT
  chmod +x "$CASE_BIN/git" || return 1
  CCCC_FAKE_GIT_LOG="$git_log" CCCC_FAKE_REAL_GIT="$real_git" run_delegate claude
  assert_success_outputs || return 1
  for forbidden in commit stash reset checkout clean push; do
    if python3 - "$git_log" "$forbidden" <<'PY'
import sys
records = open(sys.argv[1], 'rb').read().split(b'\n')
needle = sys.argv[2].encode()
raise SystemExit(0 if any(needle in record.split(b'\0') for record in records) else 1)
PY
    then
      test_diag "wrapper invoked forbidden git operation: $forbidden"
      return 1
    fi
  done
}

run_test 'Claude edit argv is exact' test_exact_claude_edit_argv
run_test 'Claude auto argv is exact' test_exact_claude_auto_argv
run_test 'Claude full argv is exact' test_exact_claude_full_argv
run_test 'Codex edit argv is exact' test_exact_codex_edit_argv
run_test 'Codex auto argv is exact' test_exact_codex_auto_argv
run_test 'Codex full argv is exact' test_exact_codex_full_argv
run_test 'full mode requires explicit gate' test_full_requires_explicit_gate
run_test 'configuration defaults and validation are fixed' test_configuration_validation_and_defaults
run_test 'timeout zero and safe maximum are validated' test_timeout_zero_and_safe_maximum_validation
run_test 'depth is validated and set only for child' test_depth_validation_and_child_scope
run_test 'arity and explicit empty workdir are rejected exactly' test_exact_arity_and_empty_workdir
run_test 'explicit empty new variables suppress legacy fallbacks' test_explicit_empty_new_variables_suppress_legacy
run_test 'model and effort mappings preserve argv boundaries' test_model_effort_mapping_and_argv_boundaries
run_test 'effort validation is target specific' test_target_specific_effort_validation
run_test 'deprecated fallbacks warn and new variables win' test_deprecated_fallbacks_and_new_precedence
run_test 'arguments cards and policies fail before launch' test_argument_card_and_policy_preflight
run_test 'allowed policy cannot cover card or ancestors' test_allowed_policy_cannot_cover_card_or_ancestor
run_test 'dangerous Git redirect environment is rejected' test_dangerous_git_redirect_environment_is_rejected
run_test 'Python is isolated and shim environment is cleared' test_python_is_isolated_and_windows_shim_environment_is_cleared
run_test 'dirty baseline is rejected unless loudly admitted' test_dirty_default_rejection_and_explicit_warning
run_test 'clean runs warn audit boundary and log metadata' test_clean_run_warns_audit_boundary_and_logs_metadata
run_test 'out-of-policy writes and boundary tricks fail' test_out_of_policy_and_boundary_tricks_fail
run_test 'rename to a disallowed path fails' test_rename_to_disallowed_fails
run_test 'already-dirty tracked file second change is detected' test_dirty_tracked_file_second_change_is_detected
run_test 'unborn Git repository succeeds under dirty escape' test_unborn_repository_succeeds
run_test 'HEAD change is a policy failure' test_head_change_is_policy_failure
run_test 'card content change is a policy failure' test_card_content_change_is_policy_failure
run_test 'card parent regular inode swap is a policy failure' test_card_parent_regular_inode_swap_is_policy_failure
run_test 'card docs ancestor regular inode swap is a policy failure' test_card_docs_ancestor_regular_inode_swap_is_policy_failure
run_test 'agent failures empty output and timeout map exactly' test_agent_nonzero_empty_timeout_and_natural_124
run_test 'trusted runner maps natural reserved statuses to agent failure' test_trusted_runner_outcome_maps_natural_reserved_statuses
run_test 'trusted runner launch failure maps to 127' test_trusted_runner_launch_failure_maps_127
run_test 'policy failure precedes agent and timeout status' test_policy_failure_precedes_agent_and_timeout_status
run_test 'cleanup failure precedes policy failure' test_cleanup_failure_precedes_policy_failure
run_test 'unsafe or inconsistent runner status fails closed' test_unsafe_or_inconsistent_runner_status_fails_closed
run_test 'signals preserve status clean child and release lock' test_signals_preserve_status_cleanup_child_and_release_lock
run_test 'runner cleanup failure precedes wrapper signals' test_signal_runner_cleanup_failure_overrides_signal_with_125
run_test 'natural child background descendant is cleaned' test_natural_child_background_descendant_is_cleaned
run_test 'Codex unsafe report sources fail boundedly' test_codex_unsafe_report_sources_fail_boundedly
run_test 'dirty untracked and index-only changes are detected' test_dirty_untracked_and_index_only_second_changes_are_detected
run_test 'unchanged dirty policy-outside baseline is not attributed' test_unchanged_dirty_out_of_policy_baseline_is_not_attributed_to_child
run_test 'newline out-of-policy path is escaped' test_newline_out_of_policy_path_is_escaped
run_test 'stale report or log never satisfies a run' test_stale_and_existing_outputs_never_satisfy_run
run_test 'symlink and FIFO outputs are never clobbered' test_symlink_and_fifo_outputs_are_never_clobbered
run_test 'post-preflight output injection cannot publish' test_post_preflight_output_injection_is_not_published
run_test 'report publish failure leaves diagnostic orphan log' test_report_publish_failure_leaves_diagnostic_orphan_log
run_test 'publish parent identity rejects last moment regular swap' test_publish_parent_identity_rejects_last_moment_regular_swap
run_test 'repo lock blocks same and different cards before baseline' test_repo_lock_blocks_same_and_different_cards
run_test 'repo lock is acquired before Git status baseline' test_repo_lock_is_acquired_before_git_status_baseline
run_test 'repo lock is shared by linked worktrees' test_repo_lock_is_shared_by_linked_worktrees
run_test 'repo lock signal acquisition window is recoverable' test_repo_lock_signal_window_cleans_before_retry
run_test 'old lock owner cannot delete a replacement inode' test_old_owner_never_deletes_replacement_lock_inode
run_test 'repo lock remains held through publication' test_repo_lock_remains_held_during_publication
run_test 'lock release cleanup failure precedes success' test_lock_release_failure_overrides_success_with_125
run_test 'lock release cleanup failure precedes signals' test_signal_lock_release_failure_overrides_signal_with_125
run_test 'different repositories can run concurrently' test_different_repositories_can_run_concurrently
run_test 'run directory is private and owned cleanup is scoped' test_run_dir_is_private_and_owned_cleanup_is_scoped
run_test 'wrapper never invokes dangerous Git operations' test_wrapper_never_invokes_forbidden_git_operations

if ! python3 - "$0" <<'PY'
from collections import Counter
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
defined = re.findall(r"^(test_[A-Za-z0-9_]+)\(\) \{$", text, re.MULTILINE)
registered = re.findall(r"^run_test '[^']+' (test_[A-Za-z0-9_]+)$", text, re.MULTILINE)
counts = Counter(registered)
missing = sorted(set(defined) - set(registered))
undefined = sorted(set(registered) - set(defined))
duplicates = sorted(name for name, count in counts.items() if count != 1)
if len(defined) != len(set(defined)) or missing or undefined or duplicates:
    raise SystemExit(
        "delegate test registration audit failed: "
        "duplicate definitions=%r missing=%r undefined=%r duplicate registrations=%r"
        % (
            sorted(name for name, count in Counter(defined).items() if count != 1),
            missing,
            undefined,
            duplicates,
        )
    )
PY
then
  test_diag 'delegate test registration audit failed'
  exit 1
fi

finish_tests
