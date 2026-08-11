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
  local output rc output_file rc_file test_pid attempts
  if [ -n "${CCCC_TEST_FILTER-}" ]; then
    case "$name $2" in *"$CCCC_TEST_FILTER"*) ;; *) return 0 ;; esac
  fi
  TEST_COUNT=$((TEST_COUNT + 1))
  output_file="$TEST_TMP_ROOT/delegate-case-$TEST_COUNT.output"
  rc_file="$TEST_TMP_ROOT/delegate-case-$TEST_COUNT.rc"
  (
    "$2"
    printf '%s\n' "$?" >"$rc_file"
  ) >"$output_file" 2>&1 &
  test_pid=$!
  attempts=${CCCC_TEST_WATCHDOG_TICKS:-6000}
  while kill -0 "$test_pid" 2>/dev/null && [ "$attempts" -gt 0 ]; do
    sleep 0.02
    attempts=$((attempts - 1))
  done
  if kill -0 "$test_pid" 2>/dev/null; then
    terminate_and_reap_pid "$test_pid" || true
    output=$(cat "$output_file" 2>/dev/null || true)
    output="${output}${output:+
}delegate case exceeded the bounded watchdog"
    rc=124
  else
    wait "$test_pid" 2>/dev/null || true
    output=$(cat "$output_file" 2>/dev/null || true)
    rc=$(cat "$rc_file" 2>/dev/null || printf 1)
  fi
  unlink "$output_file" 2>/dev/null || true
  unlink "$rc_file" 2>/dev/null || true
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
  local directory=$1 fake status_helper
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
json_mode=0
previous=
for argument in "$@"; do
  if [ "$previous" = --output-last-message ]; then
    output=$argument
  fi
  if [ "$argument" = --json ]; then json_mode=1; fi
  previous=$argument
done

emit_report() {
  local report=${CCCC_FAKE_REPORT:-fake report}
  if [ "$json_mode" -eq 1 ]; then
    printf '{"type":"item.completed","item":{"type":"agent_message","text":"%s"}}\n' "$report"
    printf '%s\n' '{"type":"turn.completed"}'
  elif [ -n "$output" ]; then
    printf '%s\n' "$report" >"$output"
  else
    printf '%s\n' "$report"
  fi
}

find_run_dir() {
  local candidate found=
  for candidate in "$TMPDIR"/cccc.*; do
    [ -d "$candidate" ] || continue
    [ -z "$found" ] || {
      printf 'multiple delegated run directories are visible\n' >&2
      return 1
    }
    found=$candidate
  done
  [ -n "$found" ] || {
    printf 'delegated run directory is unavailable\n' >&2
    return 1
  }
  printf '%s\n' "$found"
}

if [ -n "${CCCC_FAKE_RUN_MODE_FILE-}" ]; then
  directory=$(find_run_dir) || exit 97
  mode=$(stat -c '%a' "$directory" 2>/dev/null || stat -f '%Lp' "$directory" 2>/dev/null || true)
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
    run_dir=$(find_run_dir) || exit 97
    printf 'symlink report\n' >"$CCCC_FAKE_REFERENT"
    ln -s "$CCCC_FAKE_REFERENT" "$run_dir/report.md"
    ;;
  report-fifo)
    run_dir=$(find_run_dir) || exit 97
    mkfifo "$run_dir/report.md"
    ;;
  report-write-symlink)
    run_dir=$(find_run_dir) || exit 97
    printf 'do not overwrite\n' >"$CCCC_FAKE_REFERENT"
    ln -s "$CCCC_FAKE_REFERENT" "$run_dir/report.md"
    ;;
  replace-run-dir)
    run_dir=$(find_run_dir) || exit 97
    printf '%s\n' "$run_dir" >"$CCCC_FAKE_ATTACK_PATH_FILE"
    if ! mv "$run_dir" "$run_dir.original" ||
       ! mv "$CCCC_FAKE_VICTIM_DIR" "$run_dir"; then
      : >"$CCCC_FAKE_ATTACK_UNSUPPORTED_FILE"
      exit 88
    fi
    ;;
  poison-run-artifact)
    run_dir=$(find_run_dir) || exit 97
    case "$CCCC_FAKE_ARTIFACT_KIND" in
      symlink) ln -s "$CCCC_FAKE_REFERENT" "$run_dir/$CCCC_FAKE_ARTIFACT_NAME" ;;
      fifo) mkfifo "$run_dir/$CCCC_FAKE_ARTIFACT_NAME" ;;
      *) exit 97 ;;
    esac
    ;;
  forge-runner-timeout)
    run_dir=$(find_run_dir) || exit 97
    if ! unlink "$run_dir/runner.status" 2>/dev/null; then
      : >"$CCCC_FAKE_ATTACK_UNSUPPORTED_FILE"
      exit 124
    fi
    umask 077
    printf '%s\n' 'cccc-timeout-result-v1 kind=wrapper-timeout value=none' >"$run_dir/runner.status"
    chmod 600 "$run_dir/runner.status"
    : >"$CCCC_FAKE_ATTACK_APPLIED_FILE"
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
    emit_report
    exit "${CCCC_FAKE_RC:-19}"
    ;;
  natural-124)
    emit_report
    exit 124
    ;;
  forge-runner-timeout)
    emit_report
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
    emit_report
    exit "${CCCC_FAKE_RC:-19}"
    ;;
  *)
    emit_report
    ;;
esac
exit 0
FAKE
  chmod +x "$fake" || return 1
  cp "$fake" "$directory/claude" || return 1
  cp "$fake" "$directory/codex" || return 1
  chmod +x "$directory/claude" "$directory/codex" || return 1

  status_helper="$directory/write-auth-status.py"
  cat >"$status_helper" <<'PY'
#!/usr/bin/env python3
import hashlib
import hmac
import os
import stat
import sys

token_path, status_path = sys.argv[1:3]
token_before = os.lstat(token_path)
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
token_fd = os.open(token_path, flags)
try:
    token_opened = os.fstat(token_fd)
    if not stat.S_ISREG(token_opened.st_mode):
        raise SystemExit(125)
    if (token_before.st_dev, token_before.st_ino) != (token_opened.st_dev, token_opened.st_ino):
        raise SystemExit(125)
    token = os.read(token_fd, 33)
finally:
    os.close(token_fd)
if len(token) != 32:
    raise SystemExit(125)
os.unlink(token_path)
if status_path == "-":
    raise SystemExit(0)
kind, value = sys.argv[3:5]
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
status_fd = os.open(status_path, flags, 0o600)
try:
    if os.name == "posix":
        os.fchmod(status_fd, 0o600)
    identity = os.fstat(status_fd)
    canonical = (
        "cccc-timeout-result-v2 kind=%s value=%s status_dev=%d status_ino=%d"
        % (kind, value, identity.st_dev, identity.st_ino)
    ).encode("ascii")
    record = canonical + b" mac=" + hmac.new(token, canonical, hashlib.sha256).hexdigest().encode("ascii") + b"\n"
    os.write(status_fd, record)
    os.fsync(status_fd)
finally:
    os.close(status_fd)
PY
  chmod +x "$status_helper" || return 1
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
  export CCCC_AUTH_STATUS_HELPER="$CASE_BIN/write-auth-status.py"
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
    export CCCC_AUTH_STATUS_HELPER="$bin/write-auth-status.py"
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
    sys.stdout.buffer.write(os.fsencode(text) + b"\n")
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

require_windows_git_bash() {
  case ${MSYSTEM-}:$(uname -s 2>/dev/null || true) in
    MINGW*:MINGW*|MSYS*:MSYS*|UCRT*:MINGW*) return 0 ;;
    *) return 77 ;;
  esac
}

run_delegate_with_outer_timeout() {
  local target=${1:-codex} real_python outer_runner
  local command_argv
  real_python=$(command -v python3) || return 1
  outer_runner="$ROOT_DIR/skills/cccc/scripts/run-with-timeout.py"
  command_argv=("$DELEGATE" "$target" "$CASE_CARD" "$CASE_REPO")
  if require_windows_git_bash; then
    command_argv=(bash "$DELEGATE" "$target" "$CASE_CARD" "$CASE_REPO")
  fi
  CASE_OUTPUT=$(env \
    PATH="$CASE_BIN:$ORIGINAL_PATH" TMPDIR="$CASE_TMP" \
    CCCC_FAKE_ARGV_FILE="$CASE_ARGV" CCCC_FAKE_ENV_FILE="$CASE_ENV" \
    CCCC_FAKE_LAUNCH_FILE="$CASE_LAUNCH" \
    CCCC_FAKE_SCENARIO="$CCCC_FAKE_SCENARIO" \
    CCCC_FAKE_ARTIFACT_KIND="${CCCC_FAKE_ARTIFACT_KIND-}" \
    CCCC_FAKE_ARTIFACT_NAME="${CCCC_FAKE_ARTIFACT_NAME-}" \
    CCCC_FAKE_REFERENT="${CCCC_FAKE_REFERENT-}" \
    "$real_python" -I "$outer_runner" 4 -- \
      "${command_argv[@]}" 2>&1)
  CASE_RC=$?
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
--json
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
--json
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
--json
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
--json
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
  for variable in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY; do
    prepare_case || return 1
    case "$variable" in
      GIT_DIR) GIT_DIR= run_delegate claude ;;
      GIT_WORK_TREE) GIT_WORK_TREE= run_delegate claude ;;
      GIT_INDEX_FILE) GIT_INDEX_FILE= run_delegate claude ;;
      GIT_COMMON_DIR) GIT_COMMON_DIR= run_delegate claude ;;
      GIT_OBJECT_DIRECTORY) GIT_OBJECT_DIRECTORY= run_delegate claude ;;
    esac
    assert_eq 2 "$CASE_RC" "$variable empty-but-present status" || return 1
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
token_file=
intercept=0
previous=
for argument in "$@"; do
  case "$argument" in --status-file) intercept=1 ;; esac
  if [ "$previous" = --status-file ]; then status_file=$argument; fi
  if [ "$previous" = --status-token-file ]; then token_file=$argument; fi
  previous=$argument
done
if [ "$intercept" -eq 1 ]; then
  mkdir -p "$CCCC_FAKE_REPO/bad"
  printf 'outside during cleanup failure\n' >"$CCCC_FAKE_REPO/bad/cleanup-outside.txt"
  if [ -n "$status_file" ] && [ -n "$token_file" ]; then
    "$CCCC_REAL_PYTHON" -I "$CCCC_AUTH_STATUS_HELPER" \
      "$token_file" "$status_file" cleanup-failure none || exit 125
  fi
  printf '%s\n' 'cccc-timeout: cleanup failed: injected wrapper test' >&2
  exit 125
fi
exec "$CCCC_REAL_PYTHON" "$@"
CLEANUP_SHIM
  chmod +x "$CASE_BIN/python3" || return 1
  CCCC_REAL_PYTHON="$real_python" CCCC_FAKE_REPO="$CASE_REPO" run_delegate claude
  assert_eq 125 "$CASE_RC" 'cleanup failure precedence' || return 1
  [ -e "$CASE_REPO/bad/cleanup-outside.txt" ] || {
    test_diag 'cleanup-failure shim did not create the policy violation'
    return 1
  }
  case "$CASE_OUTPUT" in *'runner outcome: kind=cleanup-failure'*) return 0 ;; esac
  test_diag "cleanup-failure outcome was not authenticated: $CASE_OUTPUT"
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
token_file=
intercept=0
previous=
for argument in "$@"; do
  case "$argument" in --status-file) intercept=1 ;; esac
  if [ "$previous" = --status-file ]; then status_file=$argument; fi
  if [ "$previous" = --status-token-file ]; then token_file=$argument; fi
  previous=$argument
done
if [ "$intercept" -eq 1 ]; then
  case "$CCCC_STATUS_MODE" in
    missing)
      "$CCCC_REAL_PYTHON" -I "$CCCC_AUTH_STATUS_HELPER" "$token_file" - || exit 125
      ;;
    malformed)
      "$CCCC_REAL_PYTHON" -I "$CCCC_AUTH_STATUS_HELPER" "$token_file" - || exit 125
      umask 077
      printf '%s\n' 'forged status' >"$status_file"
      chmod 600 "$status_file"
      ;;
    symlink)
      "$CCCC_REAL_PYTHON" -I "$CCCC_AUTH_STATUS_HELPER" \
        "$token_file" "$CCCC_STATUS_REFERENT" child-exit 0 || exit 125
      ln -s "$CCCC_STATUS_REFERENT" "$status_file"
      ;;
    fifo)
      "$CCCC_REAL_PYTHON" -I "$CCCC_AUTH_STATUS_HELPER" "$token_file" - || exit 125
      mkfifo "$status_file"
      ;;
    unsafe-mode)
      "$CCCC_REAL_PYTHON" -I "$CCCC_AUTH_STATUS_HELPER" \
        "$token_file" "$status_file" child-exit 0 || exit 125
      chmod 644 "$status_file"
      ;;
    inconsistent)
      "$CCCC_REAL_PYTHON" -I "$CCCC_AUTH_STATUS_HELPER" \
        "$token_file" "$status_file" child-exit 0 || exit 125
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
      grep -Eq '^cccc-timeout-result-v2 kind=child-exit value=0 status_dev=[0-9]+ status_ino=[0-9]+ mac=[0-9a-f]{64}$' \
        "$referent" || {
          test_diag 'status symlink referent was not otherwise-valid authenticated v2'
          return 1
        }
    fi
  done
}

install_status_manifest_race_python() {
  local real_python=$1
  cat >"$CASE_BIN/python3" <<'STATUS_MANIFEST_RACE_SHIM'
#!/usr/bin/env bash
if [ "${1-}" = -I ] && [ "${2-}" = -c ]; then
  case ${3-} in
    *'print("%s|%d|%d|regular|%s|%s"'*)
      path=${6-}
      case "$path" in
        */runner.status)
          if [ ! -e "$CCCC_STATUS_MANIFEST_RACE_ONCE" ]; then
            : >"$CCCC_STATUS_MANIFEST_RACE_ONCE"
            printf '%s\n' "$path" >"$CCCC_STATUS_MANIFEST_RACE_PATH"
            mv "$path" "$CCCC_STATUS_MANIFEST_RACE_ORIGINAL" || exit 97
            mv "$CCCC_STATUS_MANIFEST_RACE_VICTIM" "$path" || exit 97
          fi
          ;;
      esac
      ;;
  esac
fi
exec "$CCCC_REAL_PYTHON" "$@"
STATUS_MANIFEST_RACE_SHIM
  chmod +x "$CASE_BIN/python3" || return 1
  CCCC_REAL_PYTHON=$real_python
  export CCCC_REAL_PYTHON
}

assert_status_manifest_race_victim_preserved() {
  local attacked
  [ -e "$CASE_DIR/status-manifest-raced" ] || {
    test_diag 'runner status parse-to-manifest race injection did not fire'
    return 1
  }
  attacked=$(cat "$CASE_DIR/status-manifest-race-path") || return 1
  assert_eq 'replacement victim must survive' \
    "$(cat "$attacked" 2>/dev/null || true)" \
    'replacement runner.status victim was cleaned' || return 1
  assert_eq 125 "$CASE_RC" 'runner status identity-race status' || return 1
  [ ! -e "$CASE_REPO/docs/tasks/T-test-report.md" ]
}

test_runner_status_identity_is_bound_through_manifest_registration() {
  local real_python
  require_posix_inode_capability || return 77
  prepare_case || return 1
  real_python=$(command -v python3) || return 1
  printf 'replacement victim must survive\n' >"$CASE_DIR/status-manifest-victim"
  install_status_manifest_race_python "$real_python" || return 1
  CCCC_STATUS_MANIFEST_RACE_ONCE="$CASE_DIR/status-manifest-raced" \
    CCCC_STATUS_MANIFEST_RACE_PATH="$CASE_DIR/status-manifest-race-path" \
    CCCC_STATUS_MANIFEST_RACE_ORIGINAL="$CASE_DIR/original-runner-status" \
    CCCC_STATUS_MANIFEST_RACE_VICTIM="$CASE_DIR/status-manifest-victim" \
    run_delegate codex
  assert_status_manifest_race_victim_preserved
}

test_signal_runner_status_identity_is_bound_through_manifest_registration() {
  local real_python barrier wrapper_pid attempts
  require_posix_inode_capability || return 77
  prepare_case || return 1
  real_python=$(command -v python3) || return 1
  barrier="$CASE_DIR/status-signal-barrier"
  mkdir -p "$barrier" || return 1
  printf 'replacement victim must survive\n' >"$CASE_DIR/status-manifest-victim"
  install_status_manifest_race_python "$real_python" || return 1
  (
    export PATH="$CASE_BIN:$ORIGINAL_PATH" TMPDIR="$CASE_TMP"
    export CCCC_REAL_PYTHON="$real_python"
    export CCCC_STATUS_MANIFEST_RACE_ONCE="$CASE_DIR/status-manifest-raced"
    export CCCC_STATUS_MANIFEST_RACE_PATH="$CASE_DIR/status-manifest-race-path"
    export CCCC_STATUS_MANIFEST_RACE_ORIGINAL="$CASE_DIR/original-runner-status"
    export CCCC_STATUS_MANIFEST_RACE_VICTIM="$CASE_DIR/status-manifest-victim"
    export CCCC_FAKE_ARGV_FILE="$CASE_ARGV" CCCC_FAKE_ENV_FILE="$CASE_ENV"
    export CCCC_FAKE_LAUNCH_FILE="$CASE_LAUNCH" CCCC_FAKE_BARRIER_DIR="$barrier"
    exec_delegate_with_signal_defaults "$real_python" claude "$CASE_CARD" "$CASE_REPO"
  ) >"$CASE_DIR/status-signal-output" 2>&1 & wrapper_pid=$!
  if ! wait_for_ready_count "$barrier" 1; then
    : >"$barrier/release"
    terminate_and_reap_pid "$wrapper_pid" || true
    return 1
  fi
  kill -HUP "$wrapper_pid" || {
    : >"$barrier/release"
    terminate_and_reap_pid "$wrapper_pid" || true
    return 1
  }
  attempts=500
  while [ ! -s "$CASE_DIR/status-manifest-race-path" ] && [ "$attempts" -gt 0 ]; do
    sleep 0.02
    attempts=$((attempts - 1))
  done
  : >"$barrier/release"
  attempts=250
  while kill -0 "$wrapper_pid" 2>/dev/null && [ "$attempts" -gt 0 ]; do
    sleep 0.02
    attempts=$((attempts - 1))
  done
  if kill -0 "$wrapper_pid" 2>/dev/null; then
    terminate_and_reap_pid "$wrapper_pid" || true
    test_diag 'signal runner-status identity-race invocation exceeded bounded wait'
    return 1
  fi
  wait "$wrapper_pid"
  CASE_RC=$?
  assert_status_manifest_race_victim_preserved
}

test_manifest_registration_rejects_duplicate_and_noncanonical_flags() {
  local injected script_dir
  prepare_case || return 1
  injected="$CASE_DIR/delegate-manifest-contract.sh"
  script_dir=$(dirname -- "$DELEGATE")
  python3 - "$DELEGATE" "$injected" "$script_dir" "$CASE_TMP" <<'PY'
import shlex
import sys

source_path, output_path, script_dir, temp_root = sys.argv[1:]
source = open(source_path, encoding="utf-8").read()
script_line = 'SCRIPT_DIR=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 127'
if script_line not in source:
    raise SystemExit("delegate SCRIPT_DIR line changed")
source = source.replace(script_line, "SCRIPT_DIR=" + shlex.quote(script_dir), 1)
needle = 'cccc_delegate_main "$@"\nexit $?'
replacement = r'''
CCCC_PYTHON=$(command -v python3) || exit 97
OWNED_RUN_DIR=$(mktemp -d "''' + temp_root.replace('"', '\\"') + r'''/manifest.XXXXXXXX") || exit 97
OWNED_RUN_DIR_ID=$(cccc_delegate_directory_identity "$OWNED_RUN_DIR") || exit 97
printf 'one\n' >"$OWNED_RUN_DIR/one"
printf 'two\n' >"$OWNED_RUN_DIR/two"
printf 'three\n' >"$OWNED_RUN_DIR/three"
printf 'four\n' >"$OWNED_RUN_DIR/four"
printf 'five\n' >"$OWNED_RUN_DIR/five"
cccc_delegate_manifest_add "$OWNED_RUN_DIR/one" 1 0 || exit 97
if cccc_delegate_manifest_add "$OWNED_RUN_DIR/one" 1 0; then exit 91; fi
if cccc_delegate_manifest_add "$OWNED_RUN_DIR/two" 01 0; then exit 92; fi
if cccc_delegate_manifest_add "$OWNED_RUN_DIR/three" 1 00; then exit 93; fi
if cccc_delegate_manifest_add "$OWNED_RUN_DIR/four" '' 0; then exit 94; fi
if cccc_delegate_manifest_add "$OWNED_RUN_DIR/five" 0 ''; then exit 95; fi
cccc_delegate_manifest_add "$OWNED_RUN_DIR/two" 1 0 || exit 97
cccc_delegate_manifest_add "$OWNED_RUN_DIR/three" 1 0 || exit 97
cccc_delegate_manifest_add "$OWNED_RUN_DIR/four" 1 0 || exit 97
cccc_delegate_manifest_add "$OWNED_RUN_DIR/five" 1 0 || exit 97
cccc_delegate_remove_run_dir || exit 97
exit 0
'''
if needle not in source:
    raise SystemExit("delegate main call changed")
with open(output_path, "x", encoding="utf-8") as stream:
    stream.write(source.replace(needle, replacement, 1))
PY
  chmod +x "$injected" || return 1
  "$injected"
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

test_runner_pid_registration_signal_window_is_safe() {
  local barrier wrapper_pid attempts rc fake_pid injected script_dir real_python
  require_posix_inode_capability || return 77
  prepare_case || return 1
  barrier="$CASE_DIR/pid-window-barrier"
  injected="$CASE_DIR/delegate-pid-window.sh"
  script_dir=$(dirname -- "$DELEGATE")
  real_python=$(command -v python3)
  mkdir -p "$barrier" || return 1
  python3 - "$DELEGATE" "$injected" "$script_dir" <<'PY'
import shlex
import sys

source_path, output_path, script_dir = sys.argv[1:]
source = open(source_path, encoding="utf-8").read()
script_line = 'SCRIPT_DIR=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 127'
if script_line not in source:
    raise SystemExit("delegate SCRIPT_DIR line changed")
source = source.replace(script_line, "SCRIPT_DIR=" + shlex.quote(script_dir), 1)
needle = '  ) >"$agent_stdout" 2>"$agent_stderr" &\n  RUNNER_PID=$!'
injection = (
    '  ) >"$agent_stdout" 2>"$agent_stderr" &\n'
    '  : >"$CCCC_PID_WINDOW_MARKER"\n'
    '  attempts=250\n'
    '  while ! find "$CCCC_FAKE_BARRIER_DIR" -name "ready.*" -type f -print -quit | grep -q .; do\n'
    '    [ "$attempts" -gt 0 ] || exit 97\n'
    '    sleep 0.02\n'
    '    attempts=$((attempts - 1))\n'
    '  done\n'
    '  kill -HUP "$$"\n'
    '  sleep 0.2\n'
    '  RUNNER_PID=$!'
)
if needle not in source:
    raise SystemExit("delegate runner PID assignment changed")
with open(output_path, "x", encoding="utf-8") as stream:
    stream.write(source.replace(needle, injection, 1))
PY
  chmod +x "$injected" || return 1
  cat >"$CASE_BIN/python3" <<'EARLY_RELEASE_SHIM'
#!/usr/bin/env bash
if [ "${1-}" = -I ] && [ "${2-}" = - ]; then
  case ${3-} in
    */cccc-v2.lock)
      for ready in "$CCCC_PID_WINDOW_BARRIER"/ready.*; do
        [ -f "$ready" ] || continue
        pid=${ready##*.}
        if kill -0 "$pid" 2>/dev/null; then
          : >"$CCCC_PID_WINDOW_EARLY_RELEASE"
        fi
      done
      ;;
  esac
fi
exec "$CCCC_REAL_PYTHON" "$@"
EARLY_RELEASE_SHIM
  chmod +x "$CASE_BIN/python3" || return 1
  DELEGATE="$injected" CCCC_PID_WINDOW_MARKER="$CASE_DIR/pid-window-injected" \
    CCCC_REAL_PYTHON="$real_python" CCCC_PID_WINDOW_BARRIER="$barrier" \
    CCCC_PID_WINDOW_EARLY_RELEASE="$CASE_DIR/lock-released-while-child-alive" \
    CCCC_FAKE_BARRIER_DIR="$barrier" invoke_delegate_explicit \
      "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" "$CASE_ARGV" "$CASE_ENV" "$CASE_LAUNCH" \
      claude "$CASE_CARD" "$CASE_DIR/pid-window-output" "$CASE_DIR/pid-window-rc" &
  wrapper_pid=$!
  attempts=400
  while [ ! -s "$CASE_DIR/pid-window-rc" ] && [ "$attempts" -gt 0 ]; do
    sleep 0.02
    attempts=$((attempts - 1))
  done
  if [ ! -s "$CASE_DIR/pid-window-rc" ]; then
    : >"$barrier/release"
    terminate_and_reap_pid "$wrapper_pid" || true
    test_diag 'PID-registration signal-window invocation exceeded bounded wait'
    return 1
  fi
  wait_pid_bounded "$wrapper_pid" 100 || terminate_and_reap_pid "$wrapper_pid" || return 1
  rc=$(cat "$CASE_DIR/pid-window-rc") || return 1
  [ -e "$CASE_DIR/pid-window-injected" ] || {
    test_diag 'white-box PID-registration signal injection did not fire'
    return 1
  }
  [ ! -e "$CASE_DIR/lock-released-while-child-alive" ] || {
    : >"$barrier/release"
    test_diag 'repo lock was released while the unregistered runner child was alive'
    return 1
  }
  if find "$barrier" -name 'ready.*' -type f -print -quit | grep -q .; then
    fake_pid=$(find "$barrier" -name 'ready.*' -type f -print -quit)
    fake_pid=${fake_pid##*.}
    : >"$barrier/release"
    if kill -0 "$fake_pid" 2>/dev/null; then
      terminate_external_pid "$fake_pid" || true
      test_diag 'runner child survived the PID-registration signal window'
      return 1
    fi
  else
    : >"$barrier/release"
  fi
  assert_eq 129 "$rc" 'PID-registration HUP status' || return 1
  case "$(cat "$CASE_DIR/pid-window-output" 2>/dev/null || true)" in
    *'cccc: delegated report:'*) return 1 ;;
  esac
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
token_file=
intercept=0
previous=
for argument in "$@"; do
  case "$argument" in --status-file) intercept=1 ;; esac
  if [ "$previous" = --status-file ]; then status_file=$argument; fi
  if [ "$previous" = --status-token-file ]; then token_file=$argument; fi
  previous=$argument
done
if [ "$intercept" -eq 1 ]; then
  exec "$CCCC_REAL_PYTHON" - "$status_file" "$token_file" "$CCCC_RUNNER_SIGNAL_BARRIER" <<'PY'
import hashlib
import hmac
import os
import signal
import sys
import time

status_file, token_file, barrier = sys.argv[1:]
token_fd = os.open(token_file, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    token = os.read(token_fd, 33)
finally:
    os.close(token_fd)
if len(token) != 32:
    raise SystemExit(125)
os.unlink(token_file)

def cleanup_failure(signum, frame):
    descriptor = os.open(status_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        identity = os.fstat(descriptor)
        canonical = (
            "cccc-timeout-result-v2 kind=cleanup-failure value=none "
            "status_dev=%d status_ino=%d" % (identity.st_dev, identity.st_ino)
        ).encode("ascii")
        record = canonical + b" mac=" + hmac.new(token, canonical, hashlib.sha256).hexdigest().encode("ascii") + b"\n"
        os.write(descriptor, record)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
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
  assert_eq 125 "$CASE_RC" 'symlink report source status' || return 1
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
  assert_eq 125 "$CASE_RC" 'FIFO report source status' || return 1
  [ ! -e "$CASE_REPO/docs/tasks/T-test-report.md" ]
}

test_run_dir_replacement_never_deletes_replacement_victim() {
  local victim attacked_path unsupported
  prepare_case || return 1
  victim="$CASE_TMP/victim-directory"
  unsupported="$CASE_DIR/run-dir-replacement-unsupported"
  mkdir "$victim" || return 1
  printf 'preexisting important data\n' >"$victim/preexisting-important.txt"
  CCCC_FAKE_SCENARIO=replace-run-dir CCCC_FAKE_VICTIM_DIR="$victim" \
    CCCC_FAKE_ATTACK_UNSUPPORTED_FILE="$unsupported" \
    CCCC_FAKE_ATTACK_PATH_FILE="$CASE_DIR/attacked-run-path" run_delegate codex
  [ ! -e "$unsupported" ] || return 77
  assert_eq 125 "$CASE_RC" 'run-dir identity-loss status' || return 1
  attacked_path=$(cat "$CASE_DIR/attacked-run-path") || return 1
  assert_eq 'preexisting important data' \
    "$(cat "$attacked_path/preexisting-important.txt" 2>/dev/null || true)" \
    'replacement victim content was deleted' || return 1
  [ -d "$attacked_path.original" ] || {
    test_diag 'owned run-dir inode was not preserved after pathname replacement'
    return 1
  }
  case "$CASE_OUTPUT" in *'cccc: delegated report:'*) return 1 ;; esac
}

test_run_dir_cleanup_rechecks_identity_at_unlink() {
  local real_python victim current owned
  prepare_case || return 1
  real_python=$(command -v python3)
  victim="$CASE_TMP/cleanup-race-victim"
  mkdir "$victim" || return 1
  printf 'preexisting important data\n' >"$victim/agent.stdout"
  cat >"$CASE_BIN/python3" <<'CLEANUP_RACE_SHIM'
#!/usr/bin/env bash
if [ "${1-}" = -I ] && [ "${2-}" = -c ]; then
  case ${3-} in
    *'# cccc-cleanup-delete-pass'*'os.rmdir'*)
      source=$3
      source=$("$CCCC_REAL_PYTHON" -I -c '
import sys
source = sys.argv[1]
needle = "# cccc-cleanup-delete-pass"
attack = """# cccc-cleanup-delete-pass
    os.rename(run_dir, run_dir + ".owned")
    os.rename(os.environ["CCCC_CLEANUP_RACE_VICTIM"], run_dir)
    with open(os.environ["CCCC_CLEANUP_RACE_DEBUG"], "a", encoding="ascii") as debug:
        opened = os.fstat(directory_fd) if directory_fd is not None else None
        current = os.lstat(run_dir)
        debug.write("run=%s:%s current=%s:%s dirfd=%r victim=%r\\n" % (
            directory.st_dev, directory.st_ino, current.st_dev, current.st_ino,
            directory_fd, open(os.path.join(run_dir, "agent.stdout"), "rb").read(),
        ))
"""
if needle not in source:
    raise SystemExit(97)
print(source.replace(needle, attack, 1))
' "$source") || exit $?
      shift 3
      exec "$CCCC_REAL_PYTHON" -I -c "$source" "$@"
      ;;
  esac
fi
exec "$CCCC_REAL_PYTHON" "$@"
CLEANUP_RACE_SHIM
  chmod +x "$CASE_BIN/python3" || return 1
  CCCC_REAL_PYTHON="$real_python" CCCC_CLEANUP_RACE_VICTIM="$victim" \
    CCCC_CLEANUP_RACE_DEBUG="$CASE_DIR/cleanup-race-debug" run_delegate codex
  assert_eq 125 "$CASE_RC" 'cleanup identity-race status' || return 1
  current=$(find "$CASE_TMP" -maxdepth 1 -type d -name 'cccc.*' ! -name '*.owned' -print) || return 1
  owned=$(find "$CASE_TMP" -maxdepth 1 -type d -name 'cccc.*.owned' -print) || return 1
  [ -n "$current" ] && [ -n "$owned" ] || {
    test_diag 'cleanup race did not leave both current victim and original owned directory'
    return 1
  }
  assert_eq 'preexisting important data' \
    "$(cat "$current/agent.stdout" 2>/dev/null || true)" \
    'cleanup deleted a replacement-victim entry' || {
      test_diag "cleanup race identities: $(cat "$CASE_DIR/cleanup-race-debug" 2>/dev/null || true)"
      test_diag "remaining entries: $(find "$CASE_TMP" -maxdepth 2 -print 2>/dev/null | tr '\n' ' ')"
      return 1
    }
  [ -s "$owned/agent.stdout" ] || {
    test_diag 'original owned run directory contents were not preserved after pathname race'
    return 1
  }
  case "$CASE_OUTPUT" in *'cccc: delegated report:'*) return 1 ;; esac
}

assert_child_artifact_symlink_is_safe() {
  local artifact=$1 victim
  prepare_case || return 1
  require_symlink_capability "$CASE_DIR" || return 77
  victim="$CASE_DIR/$artifact-victim"
  printf 'do not overwrite\n' >"$victim"
  CCCC_FAKE_SCENARIO=poison-run-artifact CCCC_FAKE_ARTIFACT_KIND=symlink \
    CCCC_FAKE_ARTIFACT_NAME="$artifact" CCCC_FAKE_REFERENT="$victim" run_delegate codex
  assert_eq 'do not overwrite' "$(cat "$victim")" "$artifact symlink referent" || return 1
  assert_eq 125 "$CASE_RC" "$artifact tamper status" || return 1
  case "$CASE_OUTPUT" in *'cccc: delegated report:'*) return 1 ;; esac
}

test_child_symlink_cannot_redirect_delegate_log() {
  assert_child_artifact_symlink_is_safe delegate.log
}

test_child_symlink_cannot_redirect_post_status() {
  assert_child_artifact_symlink_is_safe status.after
}

test_child_symlink_cannot_redirect_changed_paths() {
  assert_child_artifact_symlink_is_safe changed.z
}

assert_child_artifact_fifo_is_bounded() {
  local artifact=$1
  prepare_case || return 1
  require_fifo_capability "$CASE_DIR" || return 77
  CCCC_FAKE_SCENARIO=poison-run-artifact CCCC_FAKE_ARTIFACT_KIND=fifo \
    CCCC_FAKE_ARTIFACT_NAME="$artifact" run_delegate_with_outer_timeout codex
  if [ "$CASE_RC" -eq 124 ]; then
    test_diag "$artifact FIFO caused a post-child write to block"
    return 1
  fi
  assert_eq 125 "$CASE_RC" "$artifact FIFO tamper status" || return 1
  case "$CASE_OUTPUT" in *'cccc: delegated report:'*) return 1 ;; esac
}

test_child_fifo_cannot_block_delegate_log() {
  assert_child_artifact_fifo_is_bounded delegate.log
}

test_child_fifo_cannot_block_post_status() {
  assert_child_artifact_fifo_is_bounded status.after
}

test_child_fifo_cannot_block_changed_paths() {
  assert_child_artifact_fifo_is_bounded changed.z
}

test_child_cannot_forge_authenticated_runner_outcome() {
  local unsupported forged
  prepare_case || return 1
  unsupported="$CASE_DIR/status-forgery-unsupported"
  forged="$CASE_DIR/status-forgery-applied"
  CCCC_FAKE_SCENARIO=forge-runner-timeout \
    CCCC_FAKE_ATTACK_UNSUPPORTED_FILE="$unsupported" \
    CCCC_FAKE_ATTACK_APPLIED_FILE="$forged" run_delegate codex
  if [ -e "$unsupported" ]; then
    assert_eq 70 "$CASE_RC" 'OS-blocked forgery preserves natural child status' || return 1
  else
    [ -e "$forged" ] || { test_diag 'status forgery produced no capability marker'; return 1; }
    assert_eq 125 "$CASE_RC" 'forged runner outcome status' || return 1
  fi
  case "$CASE_OUTPUT" in
    *'runner outcome: kind=wrapper-timeout'*)
      test_diag 'child-forged status was trusted as a wrapper timeout'
      return 1
      ;;
    *'cccc: delegated report:'*) return 1 ;;
  esac
}

test_codex_report_path_cannot_redirect_cli_write() {
  local victim
  prepare_case || return 1
  require_symlink_capability "$CASE_DIR" || return 77
  victim="$CASE_DIR/codex-report-write-victim"
  printf 'do not overwrite\n' >"$victim"
  CCCC_FAKE_SCENARIO=report-write-symlink CCCC_FAKE_REFERENT="$victim" run_delegate codex
  assert_eq 'do not overwrite' "$(cat "$victim")" 'Codex report-path referent' || return 1
  [ "$CASE_RC" -ne 0 ] || return 1
  case "$CASE_OUTPUT" in *'cccc: delegated report:'*) return 1 ;; esac
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

test_publication_binds_manifest_source_identity_and_digest() {
  local real_python kind attacked destination
  require_posix_inode_capability || return 77
  for kind in delegate.log report.md; do
    prepare_case || return 1
    real_python=$(command -v python3) || return 1
    printf 'forged publication payload\n' >"$CASE_DIR/publication-source-victim"
    cat >"$CASE_BIN/python3" <<'PUBLICATION_SOURCE_RACE_SHIM'
#!/usr/bin/env bash
is_publish=0
last=
second_last=
for argument in "$@"; do
  case "$argument" in */publish-no-clobber.py) is_publish=1 ;; esac
  second_last=$last
  last=$argument
done
if [ "$is_publish" -eq 1 ]; then
  source=$second_last
  case "$source:$CCCC_PUBLICATION_SOURCE_KIND" in
    */delegate.log:delegate.log|*/report.md:report.md)
      if [ ! -e "$CCCC_PUBLICATION_SOURCE_RACE_ONCE" ]; then
        : >"$CCCC_PUBLICATION_SOURCE_RACE_ONCE"
        printf '%s\n' "$source" >"$CCCC_PUBLICATION_SOURCE_RACE_PATH"
        mv "$source" "$CCCC_PUBLICATION_SOURCE_ORIGINAL" || exit 97
        mv "$CCCC_PUBLICATION_SOURCE_VICTIM" "$source" || exit 97
      fi
      ;;
  esac
fi
exec "$CCCC_REAL_PYTHON" "$@"
PUBLICATION_SOURCE_RACE_SHIM
    chmod +x "$CASE_BIN/python3" || return 1
    CCCC_REAL_PYTHON="$real_python" CCCC_PUBLICATION_SOURCE_KIND="$kind" \
      CCCC_PUBLICATION_SOURCE_RACE_ONCE="$CASE_DIR/publication-source-raced" \
      CCCC_PUBLICATION_SOURCE_RACE_PATH="$CASE_DIR/publication-source-race-path" \
      CCCC_PUBLICATION_SOURCE_ORIGINAL="$CASE_DIR/original-$kind" \
      CCCC_PUBLICATION_SOURCE_VICTIM="$CASE_DIR/publication-source-victim" \
      run_delegate codex
    case "$CASE_RC" in 5|125) ;; *)
      test_diag "$kind publication source race returned $CASE_RC instead of 5 or 125"
      return 1
      ;;
    esac
    [ -e "$CASE_DIR/publication-source-raced" ] || {
      test_diag "$kind publication source race injection did not fire"
      return 1
    }
    attacked=$(cat "$CASE_DIR/publication-source-race-path") || return 1
    assert_eq 'forged publication payload' \
      "$(cat "$attacked" 2>/dev/null || true)" \
      "$kind replacement victim was cleaned" || return 1
    case "$kind" in
      delegate.log) destination="$CASE_REPO/docs/tasks/T-test.log" ;;
      report.md) destination="$CASE_REPO/docs/tasks/T-test-report.md" ;;
    esac
    [ ! -e "$destination" ] || {
      test_diag "$kind forged replacement was published"
      return 1
    }
  done
}

test_claude_publication_binds_same_inode_report_digest() {
  local real_python report
  prepare_case || return 1
  real_python=$(command -v python3) || return 1
  report="$CASE_REPO/docs/tasks/T-test-report.md"
  cat >"$CASE_BIN/python3" <<'CLAUDE_REPORT_DIGEST_RACE_SHIM'
#!/usr/bin/env bash
is_publish=0
last=
second_last=
for argument in "$@"; do
  case "$argument" in */publish-no-clobber.py) is_publish=1 ;; esac
  second_last=$last
  last=$argument
done
if [ "$is_publish" -eq 1 ]; then
  source=$second_last
  case "$source" in
    */agent.stdout)
      if [ ! -e "$CCCC_CLAUDE_REPORT_DIGEST_RACE_ONCE" ]; then
        : >"$CCCC_CLAUDE_REPORT_DIGEST_RACE_ONCE"
        printf 'forged same-inode report\n' >"$source" || exit 97
      fi
      ;;
  esac
fi
exec "$CCCC_REAL_PYTHON" "$@"
CLAUDE_REPORT_DIGEST_RACE_SHIM
  chmod +x "$CASE_BIN/python3" || return 1
  CCCC_REAL_PYTHON="$real_python" \
    CCCC_CLAUDE_REPORT_DIGEST_RACE_ONCE="$CASE_DIR/claude-report-digest-raced" \
    run_delegate claude
  [ -e "$CASE_DIR/claude-report-digest-raced" ] || {
    test_diag 'Claude report same-inode race injection did not fire'
    return 1
  }
  case "$CASE_RC" in 5|125) ;; *)
    test_diag "Claude same-inode report race returned $CASE_RC instead of 5 or 125"
    return 1
    ;;
  esac
  [ ! -e "$report" ] || {
    test_diag 'forged same-inode Claude report was published'
    return 1
  }
}

test_windows_identity_helpers_and_child_exit_range_are_explicit() {
  python3 - "$DELEGATE" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
names = [
    "cccc_delegate_directory_identity",
    "cccc_delegate_manifest_add",
    "cccc_delegate_verify_post_child_namespace",
    "cccc_delegate_remove_run_dir",
    "cccc_delegate_release_lock",
    "cccc_delegate_file_identity",
    "cccc_delegate_capture_card_identity",
    "cccc_delegate_parse_codex_json",
    "cccc_delegate_parse_runner_status",
    "cccc_delegate_write_log",
]
for index, name in enumerate(names):
    marker = name + "() {"
    start = text.find(marker)
    if start < 0:
        raise SystemExit("missing identity helper: " + name)
    candidates = [text.find(other + "() {", start + len(marker)) for other in names]
    candidates = [candidate for candidate in candidates if candidate >= 0]
    end = min(candidates) if candidates else len(text)
    section = text[start:end]
    if "st_file_attributes" not in section or "st_reparse_tag" not in section:
        raise SystemExit("identity helper lacks both Windows reparse indicators: " + name)

runner_start = text.index("cccc_delegate_parse_runner_status() {")
runner_end = text.index("cccc_delegate_write_log() {", runner_start)
runner = text[runner_start:runner_end]
if "4294967295" not in runner:
    raise SystemExit("Windows child-exit UINT32 maximum is not explicit")
PY
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

test_windows_linked_worktree_uses_absolute_git_common_dir() {
  local linked real_git git_log
  prepare_case || return 1
  linked="$CASE_DIR/windows-linked-worktree"
  git -C "$CASE_REPO" worktree add -q -b windows-linked-test "$linked" || return 1
  real_git=$(command -v git)
  git_log="$CASE_DIR/windows-git-argv.log"
  cat >"$CASE_BIN/git" <<'WINDOWS_COMMON_GIT_SHIM'
#!/usr/bin/env bash
has_common=0
has_absolute=0
for argument in "$@"; do
  printf '%s\n' "$argument" >>"$CCCC_WINDOWS_GIT_LOG"
  case "$argument" in
    --git-common-dir) has_common=1 ;;
    --path-format=absolute) has_absolute=1 ;;
  esac
done
printf '%s\n' '--' >>"$CCCC_WINDOWS_GIT_LOG"
if [ "$has_common" -eq 1 ] && [ "$has_absolute" -eq 0 ]; then
  printf '%s\n' 'C:/simulated/shared/common-dir'
  exit 0
fi
exec "$CCCC_FAKE_REAL_GIT" "$@"
WINDOWS_COMMON_GIT_SHIM
  chmod +x "$CASE_BIN/git" || return 1
  MSYSTEM=MINGW64 CCCC_FAKE_REAL_GIT="$real_git" CCCC_WINDOWS_GIT_LOG="$git_log" \
    run_delegate codex "$CASE_CARD" "$linked"
  assert_eq 0 "$CASE_RC" 'Windows linked-worktree common-dir status' || return 1
  [ -s "$linked/docs/tasks/T-test-report.md" ] || return 1
  [ -s "$linked/docs/tasks/T-test.log" ] || return 1
  grep -Fxq -- '--path-format=absolute' "$git_log" || {
    test_diag 'Git common-dir was not requested in absolute path format'
    return 1
  }
}

test_windows_native_status_mode_allows_normal_execution() {
  if ! require_windows_git_bash; then
    [ "${CCCC_REQUIRE_WINDOWS_NATIVE-}" = 1 ] && {
      test_diag 'Windows native delegate coverage was required but Git Bash was not detected'
      return 1
    }
    return 77
  fi
  prepare_case || return 1
  run_delegate codex
  assert_success_outputs
}

test_windows_uint_child_exit_maps_to_agent_failure() {
  local real_python
  if ! require_windows_git_bash; then
    [ "${CCCC_REQUIRE_WINDOWS_NATIVE-}" = 1 ] && {
      test_diag 'Windows native DWORD coverage was required but Git Bash was not detected'
      return 1
    }
    return 77
  fi
  prepare_case || return 1
  real_python=$(command -v python3)
  cat >"$CASE_BIN/python3" <<'WINDOWS_LARGE_STATUS_SHIM'
#!/usr/bin/env bash
status_file=
token_file=
previous=
for argument in "$@"; do
  if [ "$previous" = --status-file ]; then status_file=$argument; fi
  if [ "$previous" = --status-token-file ]; then token_file=$argument; fi
  previous=$argument
done
if [ -n "$status_file" ]; then
  if [ -n "$token_file" ]; then
    "$CCCC_REAL_PYTHON" -I "$CCCC_AUTH_STATUS_HELPER" \
      "$token_file" "$status_file" child-exit 4294967295 || exit 125
  else
    printf '%s\n' \
      'cccc-timeout-result-v1 kind=child-exit value=4294967295' >"$status_file"
  fi
  exit 70
fi
exec "$CCCC_REAL_PYTHON" "$@"
WINDOWS_LARGE_STATUS_SHIM
  chmod +x "$CASE_BIN/python3" || return 1
  CCCC_REAL_PYTHON="$real_python" run_delegate codex
  assert_eq 70 "$CASE_RC" 'Windows UINT child-exit mapping'
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

test_repo_lock_owner_registration_signal_window_leaves_no_owner_file() {
  local real_chmod common leftovers
  require_posix_inode_capability || return 77
  prepare_case || return 1
  real_chmod=$(command -v chmod)
  common=$(git -C "$CASE_REPO" rev-parse --git-common-dir) || return 1
  case "$common" in /*) ;; *) common="$CASE_REPO/$common" ;; esac
  common=$(CDPATH= cd -P -- "$common" && pwd) || return 1
  cat >"$CASE_BIN/chmod" <<'OWNER_CHMOD_SIGNAL_SHIM'
#!/usr/bin/env bash
last=
for argument in "$@"; do last=$argument; done
"$CCCC_REAL_CHMOD" "$@"
rc=$?
case "$last" in
  */.cccc-delegate-owner.*)
    if [ "$rc" -eq 0 ]; then kill -HUP "$PPID"; fi
    ;;
esac
exit "$rc"
OWNER_CHMOD_SIGNAL_SHIM
  chmod +x "$CASE_BIN/chmod" || return 1
  CCCC_REAL_CHMOD="$real_chmod" run_delegate claude
  assert_eq 129 "$CASE_RC" 'owner-registration signal status' || return 1
  assert_not_launched || return 1
  leftovers=$(find "$common" -maxdepth 1 -name '.cccc-delegate-owner.*' -type f -print)
  assert_eq '' "$leftovers" 'owner-registration signal left a stale ownership file'
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
  [ -s "$CASE_REPO/docs/tasks/T-test-report.md" ] || {
    test_diag 'post-publish cleanup failure did not preserve its diagnostic report'
    cleanup_injected_lock_files "$common" || true
    return 1
  }
  [ -s "$CASE_REPO/docs/tasks/T-test.log" ] || {
    test_diag 'post-publish cleanup failure did not preserve its diagnostic log'
    cleanup_injected_lock_files "$common" || true
    return 1
  }
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
  if ! require_windows_git_bash; then
    assert_eq 700 "$(cat "$CASE_DIR/mode")" 'run directory mode' || return 1
  fi
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
run_test 'runner status identity stays bound through manifest registration' test_runner_status_identity_is_bound_through_manifest_registration
run_test 'signal runner status identity stays bound through manifest registration' test_signal_runner_status_identity_is_bound_through_manifest_registration
run_test 'manifest rejects duplicate names and noncanonical flags' test_manifest_registration_rejects_duplicate_and_noncanonical_flags
run_test 'signals preserve status clean child and release lock' test_signals_preserve_status_cleanup_child_and_release_lock
run_test 'runner PID registration signal window is safe' test_runner_pid_registration_signal_window_is_safe
run_test 'runner cleanup failure precedes wrapper signals' test_signal_runner_cleanup_failure_overrides_signal_with_125
run_test 'natural child background descendant is cleaned' test_natural_child_background_descendant_is_cleaned
run_test 'Codex unsafe report sources fail boundedly' test_codex_unsafe_report_sources_fail_boundedly
run_test 'run-dir replacement never deletes victim data' test_run_dir_replacement_never_deletes_replacement_victim
run_test 'run-dir cleanup rechecks identity at unlink' test_run_dir_cleanup_rechecks_identity_at_unlink
run_test 'child symlink cannot redirect delegate log' test_child_symlink_cannot_redirect_delegate_log
run_test 'child symlink cannot redirect post status' test_child_symlink_cannot_redirect_post_status
run_test 'child symlink cannot redirect changed paths' test_child_symlink_cannot_redirect_changed_paths
run_test 'child FIFO cannot block delegate log' test_child_fifo_cannot_block_delegate_log
run_test 'child FIFO cannot block post status' test_child_fifo_cannot_block_post_status
run_test 'child FIFO cannot block changed paths' test_child_fifo_cannot_block_changed_paths
run_test 'child cannot forge authenticated runner outcome' test_child_cannot_forge_authenticated_runner_outcome
run_test 'Codex report path cannot redirect CLI write' test_codex_report_path_cannot_redirect_cli_write
run_test 'dirty untracked and index-only changes are detected' test_dirty_untracked_and_index_only_second_changes_are_detected
run_test 'unchanged dirty policy-outside baseline is not attributed' test_unchanged_dirty_out_of_policy_baseline_is_not_attributed_to_child
run_test 'newline out-of-policy path is escaped' test_newline_out_of_policy_path_is_escaped
run_test 'stale report or log never satisfies a run' test_stale_and_existing_outputs_never_satisfy_run
run_test 'symlink and FIFO outputs are never clobbered' test_symlink_and_fifo_outputs_are_never_clobbered
run_test 'post-preflight output injection cannot publish' test_post_preflight_output_injection_is_not_published
run_test 'report publish failure leaves diagnostic orphan log' test_report_publish_failure_leaves_diagnostic_orphan_log
run_test 'publish parent identity rejects last moment regular swap' test_publish_parent_identity_rejects_last_moment_regular_swap
run_test 'publication binds manifest source identity and digest' test_publication_binds_manifest_source_identity_and_digest
run_test 'Claude publication binds same-inode report digest' test_claude_publication_binds_same_inode_report_digest
run_test 'Windows identity helpers and child exit range are explicit' test_windows_identity_helpers_and_child_exit_range_are_explicit
run_test 'repo lock blocks same and different cards before baseline' test_repo_lock_blocks_same_and_different_cards
run_test 'repo lock is acquired before Git status baseline' test_repo_lock_is_acquired_before_git_status_baseline
run_test 'repo lock is shared by linked worktrees' test_repo_lock_is_shared_by_linked_worktrees
run_test 'Windows linked worktree uses absolute Git common-dir' test_windows_linked_worktree_uses_absolute_git_common_dir
run_test 'Windows native status mode allows normal execution' test_windows_native_status_mode_allows_normal_execution
run_test 'Windows UINT child exit maps to agent failure' test_windows_uint_child_exit_maps_to_agent_failure
run_test 'repo lock signal acquisition window is recoverable' test_repo_lock_signal_window_cleans_before_retry
run_test 'repo lock owner registration signal window is clean' test_repo_lock_owner_registration_signal_window_leaves_no_owner_file
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
