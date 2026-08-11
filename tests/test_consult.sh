#!/usr/bin/env bash
set -u

TEST_DIR=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
ROOT_DIR=$(CDPATH= cd -P -- "$TEST_DIR/.." && pwd) || exit 1
CONSULT="$ROOT_DIR/skills/cccc/scripts/consult.sh"
DELEGATE="$ROOT_DIR/skills/cccc/scripts/delegate.sh"
FAKE_AGENT="$TEST_DIR/fixtures/fake-consult-agent.sh"
AUTH_STATUS_HELPER="$TEST_DIR/fixtures/write-auth-runner-status.py"
ORIGINAL_PATH=$PATH
CONSULT_TEST_WINDOWS=0
case ${MSYSTEM-}:$(uname -s 2>/dev/null || true) in
  MINGW*:MINGW*|MSYS*:MSYS*|UCRT*:MINGW*) CONSULT_TEST_WINDOWS=1 ;;
esac
CODEX_STRICT_FEATURES='hooks
plugins
apps
browser_use
browser_use_external
browser_use_full_cdp_access
computer_use
in_app_browser
memories
multi_agent
multi_agent_v2
image_generation
workspace_dependencies
skill_search
skill_mcp_dependency_install
shell_snapshot
remote_plugin
plugin_sharing
auth_elicitation
tool_call_mcp_elicitation
tool_suggest
goals
code_mode_host
in_app_updates
enable_mcp_apps
recommended_plugins'
CODEX_STRICT_FEATURES="$CODEX_STRICT_FEATURES
chronicle
code_mode
deferred_executor
standalone_web_search
network_proxy
request_permissions_tool
external_agent_memory_import
artifact
code_mode_buffered_exec
code_mode_only
executor_capability_discovery
exec_permission_approvals
view_image
shell_zsh_fork
unified_exec_zsh_fork"
CODEX_STRICT_CONFIGS='model_provider="openai"
project_doc_max_bytes=0
skills.bundled.enabled=false
skills.include_instructions=false
model_reasoning_effort="xhigh"
web_search="disabled"
tools.web_search=false
allow_login_shell=false
check_for_update_on_startup=false
analytics.enabled=false
feedback.enabled=false
notify=[]
otel.exporter="none"
otel.metrics_exporter="none"
otel.trace_exporter="none"
history.persistence="none"
shell_environment_policy.inherit="none"
shell_environment_policy.ignore_default_excludes=false'

# shellcheck source=tests/test_helper.bash
. "$TEST_DIR/test_helper.bash"
trap test_cleanup EXIT
trap 'test_signal_cleanup 1' HUP
trap 'test_signal_cleanup 2' INT
trap 'test_signal_cleanup 15' TERM

run_test() {
  local name=$1 function_name=$2 output_file rc_file test_pid attempts output rc
  if [ -n "${CCCC_TEST_FILTER-}" ]; then
    case "$name" in *"$CCCC_TEST_FILTER"*) ;; *) return 0 ;; esac
  fi
  TEST_COUNT=$((TEST_COUNT + 1))
  output_file="$TEST_TMP_ROOT/consult-case-$TEST_COUNT.output"
  rc_file="$TEST_TMP_ROOT/consult-case-$TEST_COUNT.rc"
  (
    "$function_name"
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
}consult case exceeded the bounded watchdog"
    rc=124
  else
    wait "$test_pid" 2>/dev/null || true
    output=$(cat "$output_file" 2>/dev/null || true)
    rc=$(cat "$rc_file" 2>/dev/null || printf 1)
  fi
  unlink "$output_file" "$rc_file" 2>/dev/null || true
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

write_discussion_card() {
  local repo=$1 card=$2
  mkdir -p "$repo/$(dirname -- "$card")" || return 1
  {
    printf '# Consult test\n\n'
    printf 'Read the repository and return an opinion.\n'
  } >"$repo/$card"
}

install_fake_agents() {
  local directory=$1
  mkdir -p "$directory" || return 1
  cp "$FAKE_AGENT" "$directory/claude" || return 1
  cp "$FAKE_AGENT" "$directory/codex" || return 1
  chmod +x "$directory/claude" "$directory/codex" || return 1
}

prepare_case() {
  CASE_DIR=$(new_test_dir) || return 1
  CASE_REPO="$CASE_DIR/repo"
  CASE_BIN="$CASE_DIR/bin"
  CASE_TMP="$CASE_DIR/tmp"
  CASE_ARGV="$CASE_DIR/argv.bin"
  CASE_ENV="$CASE_DIR/env.txt"
  CASE_CWD="$CASE_DIR/cwd.txt"
  CASE_PRIVATE="$CASE_DIR/private.txt"
  CASE_CALLS="$CASE_DIR/calls.txt"
  CASE_LAUNCH="$CASE_DIR/launched.txt"
  CASE_CARD=${1:-docs/discussions/D-test.md}
  mkdir -p "$CASE_REPO/src" "$CASE_REPO/scratch" "$CASE_TMP" || return 1
  chmod 700 "$CASE_TMP" || return 1
  CASE_REPO_PHYSICAL=$(CDPATH= cd -P -- "$CASE_REPO" && pwd) || return 1
  CASE_TMP_PHYSICAL=$(CDPATH= cd -P -- "$CASE_TMP" && pwd) || return 1
  init_test_repo "$CASE_REPO" || return 1
  printf 'tracked baseline\n' >"$CASE_REPO/src/tracked.txt"
  write_discussion_card "$CASE_REPO" "$CASE_CARD" || return 1
  printf '*.log\n' >"$CASE_REPO/.gitignore"
  mkdir -p "$CASE_REPO/.claude" "$CASE_REPO/.codex/skills/poison" || return 1
  printf '{"hooks":{"SessionStart":[{"command":"touch %s"}]}}\n' "$CASE_DIR/project-hook-ran" >"$CASE_REPO/.claude/settings.json"
  printf '{"mcpServers":{"poison":{"command":"touch","args":["%s"]}}}\n' "$CASE_DIR/project-mcp-ran" >"$CASE_REPO/.mcp.json"
  printf 'model_provider = "poison"\n' >"$CASE_REPO/.codex/config.toml"
  printf '%s\n' '---' 'name: poison' 'description: poison' '---' >"$CASE_REPO/.codex/skills/poison/SKILL.md"
  git -C "$CASE_REPO" add . || return 1
  git -C "$CASE_REPO" commit -q -m baseline || return 1
  install_fake_agents "$CASE_BIN" || return 1
  mkdir -p "$TEST_FAKE_HOME/.claude" "$TEST_FAKE_HOME/.codex" || return 1
  printf '{"hooks":{"SessionStart":[{"command":"touch user-hook-ran"}]}}\n' >"$TEST_FAKE_HOME/.claude/settings.json"
  printf 'model_provider = "poison-user"\n' >"$TEST_FAKE_HOME/.codex/config.toml"
}

run_consult() {
  local target=${1:-claude} card=${2:-$CASE_CARD} workdir=${3:-$CASE_REPO} old_path=$PATH
  PATH="$CASE_BIN:$ORIGINAL_PATH"
  export PATH
  export TMPDIR="$CASE_TMP"
  export CCCC_FAKE_ARGV_FILE="$CASE_ARGV"
  export CCCC_FAKE_ENV_FILE="$CASE_ENV"
  export CCCC_FAKE_CWD_FILE="$CASE_CWD"
  export CCCC_FAKE_PRIVATE_FILE="$CASE_PRIVATE"
  export CCCC_FAKE_CALLS_FILE="$CASE_CALLS"
  export CCCC_FAKE_LAUNCH_FILE="$CASE_LAUNCH"
  export CCCC_FAKE_REPO="$CASE_REPO"
  export CCCC_FAKE_CARD="$card"
  export CCCC_AUTH_STATUS_HELPER="$AUTH_STATUS_HELPER"
  CASE_OUTPUT=$("$CONSULT" "$target" "$card" "$workdir" 2>&1)
  CASE_RC=$?
  PATH=$old_path
  export PATH
}

invoke_consult_explicit() {
  local repo=$1 bin=$2 tmp=$3 target=$4 card=$5 output=$6 rc_file=$7 launch=$8
  (
    export PATH="$bin:$ORIGINAL_PATH" TMPDIR="$tmp"
    export CCCC_FAKE_ARGV_FILE="$output.argv" CCCC_FAKE_ENV_FILE="$output.env"
    export CCCC_FAKE_CWD_FILE="$output.cwd" CCCC_FAKE_PRIVATE_FILE="$output.private"
    export CCCC_FAKE_CALLS_FILE="$output.calls" CCCC_FAKE_LAUNCH_FILE="$launch"
    export CCCC_FAKE_REPO="$repo" CCCC_FAKE_CARD="$card"
    export CCCC_AUTH_STATUS_HELPER="$AUTH_STATUS_HELPER"
    "$CONSULT" "$target" "$card" "$repo" >"$output" 2>&1
    printf '%s\n' "$?" >"$rc_file"
  )
}

require_consult() {
  if [ ! -f "$CONSULT" ]; then
    test_diag "canonical consult entrypoint is missing: $CONSULT"
    return 1
  fi
  if [ ! -x "$CONSULT" ]; then
    test_diag "canonical consult entrypoint is not executable: $CONSULT"
    return 1
  fi
}

assert_not_launched() {
  if [ -s "$CASE_LAUNCH" ]; then
    test_diag 'agent was launched unexpectedly'
    return 1
  fi
}

opinion_path() {
  printf '%s/%s-%s-opinion.md\n' "$CASE_REPO" "${2%.md}" "$1"
}

log_path() {
  printf '%s/%s-%s.log\n' "$CASE_REPO" "${2%.md}" "$1"
}

assert_success_outputs() {
  local target=${1:-claude} card=${2:-$CASE_CARD} opinion log
  opinion=$(opinion_path "$target" "$card")
  log=$(log_path "$target" "$card")
  assert_eq 0 "$CASE_RC" 'consult status' || return 1
  [ -s "$opinion" ] && [ -f "$opinion" ] && [ ! -L "$opinion" ] || {
    test_diag "opinion was not safely published: $opinion"
    return 1
  }
  [ -s "$log" ] && [ -f "$log" ] && [ ! -L "$log" ] || {
    test_diag "log was not safely published: $log"
    return 1
  }
}

normalize_argv() {
  python3 -I - "$1" "$CASE_REPO" <<'PY'
import os
import sys

raw = open(sys.argv[1], "rb").read()
arguments = raw.split(b"\0")
if arguments and arguments[-1] == b"":
    arguments.pop()
repo = sys.argv[2]
physical_repo = os.path.realpath(repo)

def path_key(value):
    return os.path.normcase(os.path.realpath(os.path.abspath(value))).replace("\\", "/")

repo_keys = {path_key(repo), path_key(physical_repo)}
for argument in arguments:
    text = os.fsdecode(argument)
    normalized_text = text.replace("\\", "/")
    is_absolute_path = os.path.isabs(text)
    if is_absolute_path and path_key(text) in repo_keys:
        text = "<REPO>"
    elif is_absolute_path and any(
        path_key(text).startswith(path_key(os.path.join(root, "docs", "discussions")) + "/")
        for root in (repo, physical_repo)
    ):
        text = "<CARD>"
    elif normalized_text.endswith("/empty-mcp.json") or normalized_text.endswith("/mcp.json"):
        text = "<PRIVATE_MCP>"
    elif "/cccc." in normalized_text and os.path.basename(normalized_text) in ("codex-cwd", "cwd"):
        text = "<PRIVATE_CWD>"
    elif text.startswith("You are") or "expert consult" in text.lower() or "专家顾问" in text:
        text = "<PROMPT>"
    sys.stdout.buffer.write(os.fsencode(text) + b"\n")
PY
}

argv_has_exact_argument() {
  python3 -I - "$CASE_ARGV" "$1" <<'PY'
import os
import sys
arguments = open(sys.argv[1], "rb").read().split(b"\0")
needle = os.fsencode(sys.argv[2])
raise SystemExit(0 if needle in arguments else 1)
PY
}

argv_prompt() {
  python3 -I - "$CASE_ARGV" <<'PY'
import os
import sys
arguments = open(sys.argv[1], "rb").read().split(b"\0")
for raw in reversed(arguments):
    if raw:
        sys.stdout.buffer.write(raw + b"\n")
        break
PY
}

expected_codex_strict_argv() {
  local value
  printf '%s\n' -a never exec --json --ephemeral --sandbox read-only --ignore-user-config \
    --strict-config --ignore-rules --skip-git-repo-check -C '<PRIVATE_CWD>'
  while IFS= read -r value; do
    [ -n "$value" ] || continue
    printf '%s\n' -c "$value"
  done <<EOF
$CODEX_STRICT_CONFIGS
EOF
  while IFS= read -r value; do
    [ -n "$value" ] || continue
    printf '%s\n' --disable "$value"
  done <<EOF
$CODEX_STRICT_FEATURES
EOF
  printf '%s\n' '<PROMPT>'
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

publication_ready_pid() {
  local directory=$1 ready pid
  for ready in "$directory"/ready.*; do
    [ -f "$ready" ] || continue
    pid=${ready##*.}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$pid"
    return 0
  done
  return 1
}

assert_publication_helper_gone() {
  local pid=$1 barrier=$2 label=$3
  if kill -0 "$pid" 2>/dev/null; then
    : >"$barrier/release"
    terminate_external_pid "$pid" || true
    test_diag "$label publisher shim survived wrapper signal cleanup"
    return 1
  fi
}

wait_pid_bounded() {
  local pid=$1 attempts=${2:-250}
  while kill -0 "$pid" 2>/dev/null && [ "$attempts" -gt 0 ]; do
    sleep 0.02
    attempts=$((attempts - 1))
  done
  if kill -0 "$pid" 2>/dev/null; then return 1; fi
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
}

terminate_external_pid() {
  local pid=$1 attempts=150
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -TERM "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$attempts" -gt 0 ]; do
    sleep 0.02
    attempts=$((attempts - 1))
  done
  if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
}

require_symlink_capability() {
  local directory=$1 target link
  target="$directory/cap-target"
  link="$directory/cap-link"
  printf 'target\n' >"$target" || return 77
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

exec_consult_with_signal_defaults() {
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
' "$CONSULT" "$@"
}

test_canonical_entrypoint_exists_and_is_not_legacy() {
  require_consult || return 1
  [ "$CONSULT" != "$ROOT_DIR/scripts/consult.sh" ] || return 1
  grep -q 'cccc-common.sh' "$CONSULT" || {
    test_diag 'canonical consult does not load hardened common primitives'
    return 1
  }
}

test_exact_arity_target_and_empty_workdir_validation() {
  local rc
  require_consult || return 1
  prepare_case || return 1
  for invocation in zero one four bad-target empty-workdir; do
    case "$invocation" in
      zero) "$CONSULT" >/dev/null 2>&1; rc=$? ;;
      one) "$CONSULT" claude >/dev/null 2>&1; rc=$? ;;
      four) "$CONSULT" claude "$CASE_CARD" "$CASE_REPO" extra >/dev/null 2>&1; rc=$? ;;
      bad-target) "$CONSULT" auto "$CASE_CARD" "$CASE_REPO" >/dev/null 2>&1; rc=$? ;;
      empty-workdir) "$CONSULT" claude "$CASE_CARD" '' >/dev/null 2>&1; rc=$? ;;
    esac
    assert_eq 2 "$rc" "$invocation status" || return 1
  done
  assert_not_launched
}

test_card_path_is_strictly_repository_relative_markdown() {
  local card
  prepare_case || return 1
  for card in /tmp/D.md docs/discussions/../D-test.md docs/discussions/D-test.txt \
    docs/tasks/T-test.md docs/discussions/sub/../../D-test.md; do
    run_consult claude "$card"
    assert_eq 2 "$CASE_RC" "unsafe card status for $card" || return 1
  done
  assert_not_launched
}

test_unicode_and_space_card_is_safe_and_named_by_stem() {
  prepare_case 'docs/discussions/D-设计 讨论.md' || return 1
  run_consult claude
  assert_success_outputs claude "$CASE_CARD" || return 1
  assert_eq '# Fake consult opinion' "$(cat "$(opinion_path claude "$CASE_CARD")")"
}

test_card_and_ancestors_must_be_regular_without_symlinks() {
  local outside
  require_symlink_capability "$TEST_TMP_ROOT" || return 77
  prepare_case || return 1
  outside="$CASE_DIR/outside.md"
  printf '# outside\n' >"$outside"
  unlink "$CASE_REPO/$CASE_CARD" || return 1
  ln -s "$outside" "$CASE_REPO/$CASE_CARD" || return 1
  run_consult claude
  assert_eq 2 "$CASE_RC" 'symlink card status' || return 1
  assert_not_launched || return 1
  prepare_case || return 1
  mv "$CASE_REPO/docs/discussions" "$CASE_REPO/discussions-real" || return 1
  ln -s ../discussions-real "$CASE_REPO/docs/discussions" || return 1
  run_consult claude
  assert_eq 2 "$CASE_RC" 'symlink ancestor status' || return 1
  assert_not_launched
}

test_fifo_card_is_rejected_without_blocking() {
  require_fifo_capability "$TEST_TMP_ROOT" || return 77
  prepare_case || return 1
  unlink "$CASE_REPO/$CASE_CARD" || return 1
  mkfifo "$CASE_REPO/$CASE_CARD" || return 1
  run_consult claude
  assert_eq 2 "$CASE_RC" 'FIFO card status' || return 1
  assert_not_launched
}

test_depth_guard_is_exact_and_only_child_receives_one() {
  prepare_case || return 1
  DELEGATE_DEPTH=1 run_consult claude
  assert_eq 3 "$CASE_RC" 'nested consult status' || return 1
  DELEGATE_DEPTH='1+0' run_consult claude
  assert_eq 3 "$CASE_RC" 'malformed depth status' || return 1
  DELEGATE_DEPTH=0 run_consult claude
  assert_success_outputs || return 1
  grep -Fxq 'DELEGATE_DEPTH=1' "$CASE_ENV" || return 1
  assert_eq 0 "${DELEGATE_DEPTH:-0}" 'caller depth changed'
}

test_write_enabling_environment_is_rejected() {
  local variable
  for variable in CCCC_MODE CCCC_ALLOW_FULL DELEGATE_SANDBOX; do
    prepare_case || return 1
    case "$variable" in
      CCCC_MODE) CCCC_MODE=auto run_consult claude ;;
      CCCC_ALLOW_FULL) CCCC_ALLOW_FULL=1 run_consult claude ;;
      DELEGATE_SANDBOX) DELEGATE_SANDBOX=read-only run_consult claude ;;
    esac
    assert_eq 2 "$CASE_RC" "$variable rejection status" || return 1
    assert_not_launched || return 1
  done
  for variable in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY; do
    prepare_case || return 1
    case "$variable" in
      GIT_DIR) GIT_DIR="$CASE_DIR/redirect" run_consult claude ;;
      GIT_WORK_TREE) GIT_WORK_TREE="$CASE_DIR/redirect" run_consult claude ;;
      GIT_INDEX_FILE) GIT_INDEX_FILE="$CASE_DIR/redirect" run_consult claude ;;
      GIT_COMMON_DIR) GIT_COMMON_DIR="$CASE_DIR/redirect" run_consult claude ;;
      GIT_OBJECT_DIRECTORY) GIT_OBJECT_DIRECTORY="$CASE_DIR/redirect" run_consult claude ;;
    esac
    assert_eq 2 "$CASE_RC" "$variable redirect status" || return 1
    assert_not_launched || return 1
  done
  for variable in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY; do
    prepare_case || return 1
    case "$variable" in
      GIT_DIR) GIT_DIR= run_consult claude ;;
      GIT_WORK_TREE) GIT_WORK_TREE= run_consult claude ;;
      GIT_INDEX_FILE) GIT_INDEX_FILE= run_consult claude ;;
      GIT_COMMON_DIR) GIT_COMMON_DIR= run_consult claude ;;
      GIT_OBJECT_DIRECTORY) GIT_OBJECT_DIRECTORY= run_consult claude ;;
    esac
    assert_eq 2 "$CASE_RC" "$variable empty-but-present status" || return 1
    assert_not_launched || return 1
  done
}

test_timeout_defaults_to_1800_and_accepts_zero_and_maximum() {
  local value maximum
  prepare_case || return 1
  run_consult claude
  assert_success_outputs || return 1
  grep -Eq 'timeout(_seconds)?=1800|timeout: 1800|1800s' "$(log_path claude "$CASE_CARD")" || {
    test_diag 'default timeout 1800 is absent from authoritative log'
    return 1
  }
  prepare_case || return 1
  CCCC_TIMEOUT=0 run_consult codex
  assert_success_outputs codex || return 1
  maximum=$(python3 -I -c \
    'import runpy, sys; print(runpy.run_path(sys.argv[1])["MAX_TIMEOUT_SECONDS"])' \
    "$ROOT_DIR/skills/cccc/scripts/run-with-timeout.py") || return 1
  prepare_case || return 1
  CCCC_TIMEOUT="$maximum" run_consult claude
  assert_success_outputs
}

test_timeout_rejects_invalid_and_over_maximum_values() {
  local value maximum over
  maximum=$(python3 -I -c \
    'import runpy, sys; print(runpy.run_path(sys.argv[1])["MAX_TIMEOUT_SECONDS"])' \
    "$ROOT_DIR/skills/cccc/scripts/run-with-timeout.py") || return 1
  over=$(python3 -I -c 'import sys; print(int(sys.argv[1]) + 1)' "$maximum") || return 1
  for value in '' -1 01 1.5 1s "$over"; do
    prepare_case || return 1
    CCCC_TIMEOUT="$value" run_consult claude
    assert_eq 2 "$CASE_RC" "timeout [$value] status (maximum $maximum)" || return 1
    assert_not_launched || return 1
  done
}

test_model_and_effort_are_single_argv_boundaries() {
  prepare_case || return 1
  CCCC_MODEL='opus test boundary' CCCC_EFFORT=max run_consult claude
  assert_success_outputs || return 1
  argv_has_exact_argument 'opus test boundary' || return 1
  argv_has_exact_argument max || return 1
  prepare_case || return 1
  CCCC_MODEL='gpt test boundary' CCCC_EFFORT=xhigh run_consult codex
  assert_success_outputs codex || return 1
  argv_has_exact_argument 'gpt test boundary' || return 1
  argv_has_exact_argument 'model_reasoning_effort="xhigh"'
}

test_allow_dirty_is_literal_one_only() {
  local value
  for value in yes true 01 2; do
    prepare_case || return 1
    CCCC_ALLOW_DIRTY=$value run_consult claude
    assert_eq 2 "$CASE_RC" "CCCC_ALLOW_DIRTY=$value status" || return 1
    assert_not_launched || return 1
  done
}

test_codex_config_mode_defaults_strict_and_rejects_other_values() {
  local value
  prepare_case || return 1
  run_consult codex
  assert_success_outputs codex || return 1
  argv_has_exact_argument --ignore-user-config || return 1
  for value in '' Strict inherit-user permissive 0; do
    prepare_case || return 1
    CCCC_CODEX_CONFIG_MODE=$value run_consult codex
    assert_eq 2 "$CASE_RC" "CCCC_CODEX_CONFIG_MODE=[$value] status" || return 1
    assert_not_launched || return 1
  done
}

test_claude_argv_is_exact_and_read_only() {
  local actual expected
  prepare_case || return 1
  CCCC_MODEL=claude-test-model CCCC_EFFORT=max run_consult claude
  assert_success_outputs || return 1
  actual=$(normalize_argv "$CASE_ARGV") || return 1
  expected=$(cat <<'EOF'
--safe-mode
--tools
Read,Glob,Grep
--permission-mode
dontAsk
--disable-slash-commands
--no-session-persistence
--no-chrome
--add-dir
<REPO>
--mcp-config
<PRIVATE_MCP>
--strict-mcp-config
-p
<PROMPT>
--model
claude-test-model
--effort
max
EOF
)
  assert_eq "$expected" "$actual" 'exact Claude consult argv'
}

test_claude_mcp_config_is_private_regular_0600_and_empty() {
  local mcp_path
  prepare_case || return 1
  run_consult claude
  assert_success_outputs || return 1
  if [ "$CONSULT_TEST_WINDOWS" -eq 0 ]; then
    grep -Fxq 'mcp_mode=600' "$CASE_PRIVATE" || return 1
  fi
  grep -Fxq 'mcp_type=regular' "$CASE_PRIVATE" || return 1
  mcp_path=$(sed -n 's/^mcp_path=//p' "$CASE_PRIVATE")
  [ -n "$mcp_path" ] || return 1
  python3 -I - "$CASE_PRIVATE" <<'PY'
import json
import sys
text = open(sys.argv[1], encoding="utf-8").read()
payload = text.split("mcp_content_begin\n", 1)[1].split("\nmcp_content_end", 1)[0]
value = json.loads(payload)
if value != {"mcpServers": {}}:
    raise SystemExit("MCP config is not the current Claude empty schema")
PY
}

test_claude_runs_from_private_cwd_with_absolute_repo_access() {
  local cwd prompt
  prepare_case || return 1
  run_consult claude
  assert_success_outputs || return 1
  cwd=$(cat "$CASE_CWD")
  [ "$cwd" != "$CASE_REPO_PHYSICAL" ] || { test_diag 'Claude cwd is the repository'; return 1; }
  case "$cwd" in "$CASE_TMP_PHYSICAL"/*) ;; *) test_diag "Claude cwd is not private: $cwd"; return 1 ;; esac
  argv_has_exact_argument "$CASE_REPO_PHYSICAL" || return 1
  prompt=$(argv_prompt)
  case "$prompt" in *"$CASE_REPO_PHYSICAL"*"$CASE_REPO_PHYSICAL/$CASE_CARD"*) ;; *) test_diag 'prompt lacks absolute repo/card'; return 1 ;; esac
}

test_claude_project_poison_cannot_start() {
  local poison poisons
  prepare_case || return 1
  poisons="$CASE_DIR/project-hook-ran
$CASE_DIR/project-mcp-ran
$CASE_DIR/project-skill-ran
$CASE_DIR/user-hook-ran
$CASE_DIR/user-mcp-ran
$CASE_DIR/user-plugin-ran"
  CCCC_FAKE_POISON_SENTINELS="$poisons" run_consult claude
  assert_success_outputs || return 1
  while IFS= read -r poison; do [ -z "$poison" ] || [ ! -e "$poison" ] || return 1; done <<EOF
$poisons
EOF
  case "$(cat "$CASE_CWD")" in "$CASE_REPO"|"$CASE_REPO"/*) return 1 ;; esac
  argv_has_exact_argument --strict-mcp-config
}

test_codex_strict_argv_is_exact_and_root_approval_precedes_exec() {
  local actual expected shape opinion
  prepare_case || return 1
  run_consult codex
  assert_success_outputs codex || return 1
  actual=$(normalize_argv "$CASE_ARGV") || return 1
  expected=$(expected_codex_strict_argv)
  assert_eq "$expected" "$actual" 'exact Codex strict consult argv' || return 1
  if argv_has_exact_argument --add-dir; then
    test_diag 'Codex strict must never receive --add-dir'
    return 1
  fi
  if argv_has_exact_argument shell_tool || argv_has_exact_argument unified_exec; then
    test_diag 'necessary read-only execution features must not be disabled'
    return 1
  fi
  prepare_case || return 1
  CCCC_FAKE_JSON_SHAPE=multi run_consult codex
  assert_success_outputs codex || return 1
  opinion=$(opinion_path codex "$CASE_CARD")
  assert_eq 'last opinion' "$(cat "$opinion")" 'Codex last agent_message selection' || return 1
  for shape in malformed missing-turn empty-message trailing plain; do
    prepare_case || return 1
    CCCC_FAKE_JSON_SHAPE=$shape run_consult codex
    assert_eq 5 "$CASE_RC" "Codex JSONL $shape status" || return 1
    [ ! -e "$(opinion_path codex "$CASE_CARD")" ] || return 1
  done
}

test_codex_strict_denies_every_locked_feature() {
  local feature
  prepare_case || return 1
  run_consult codex
  assert_success_outputs codex || return 1
  for feature in $CODEX_STRICT_FEATURES; do
    python3 -I - "$CASE_ARGV" "$feature" <<'PY' || return 1
import os
import sys
args = open(sys.argv[1], "rb").read().split(b"\0")
needle = os.fsencode(sys.argv[2])
if not any(args[index] == b"--disable" and args[index + 1] == needle for index in range(len(args) - 1)):
    raise SystemExit("missing --disable " + sys.argv[2])
PY
  done
}

test_codex_preflight_really_runs_help_and_features_before_launch() {
  local sequence
  prepare_case || return 1
  run_consult codex
  assert_success_outputs codex || return 1
  sequence=$(cut -f1 "$CASE_CALLS" | tr '\n' ' ')
  assert_eq 'root-help exec-help features launch ' "$sequence" 'Codex preflight call order'
}

test_codex_missing_required_flag_fails_closed_before_launch() {
  local flag
  require_consult || return 1
  for flag in -a --json --ephemeral --sandbox --ignore-user-config --strict-config \
    --ignore-rules --skip-git-repo-check -C -c --disable; do
    prepare_case || return 1
    CCCC_FAKE_MISSING_FLAG=$flag run_consult codex
    [ "$CASE_RC" -ne 0 ] || return 1
    assert_not_launched || return 1
  done
}

test_codex_missing_required_feature_fails_closed_before_launch() {
  local shape
  require_consult || return 1
  prepare_case || return 1
  CCCC_FAKE_MISSING_FEATURE=remote_plugin run_consult codex
  [ "$CASE_RC" -ne 0 ] || return 1
  assert_not_launched || return 1
  for shape in duplicate malformed removed unknown-enabled; do
    prepare_case || return 1
    CCCC_FAKE_FEATURES_SHAPE=$shape run_consult codex
    [ "$CASE_RC" -ne 0 ] || { test_diag "feature shape $shape was accepted"; return 1; }
    assert_not_launched || return 1
  done
}

test_codex_preflight_command_failures_do_not_launch_agent() {
  require_consult || return 1
  prepare_case || return 1
  CCCC_FAKE_HELP_RC=9 run_consult codex
  [ "$CASE_RC" -ne 0 ] || return 1
  assert_not_launched || return 1
  prepare_case || return 1
  CCCC_FAKE_FEATURES_RC=9 run_consult codex
  [ "$CASE_RC" -ne 0 ] || return 1
  assert_not_launched
}

test_codex_strict_private_cwd_is_0700_and_not_repo() {
  local cwd
  prepare_case || return 1
  run_consult codex
  assert_success_outputs codex || return 1
  if [ "$CONSULT_TEST_WINDOWS" -eq 0 ]; then
    grep -Fxq 'codex_cwd_mode=700' "$CASE_PRIVATE" || return 1
  fi
  cwd=$(sed -n 's/^codex_cwd=//p' "$CASE_PRIVATE")
  [ -n "$cwd" ] || return 1
  python3 -I - "$cwd" "$CASE_REPO_PHYSICAL" "$CASE_TMP" "$CASE_TMP_PHYSICAL" <<'PY' || return 1
import os
import sys

def key(value):
    return os.path.normcase(os.path.realpath(os.path.abspath(value)))

cwd, repo, *temporary_roots = map(key, sys.argv[1:])
if cwd == repo:
    raise SystemExit("Codex private cwd is the repository")
for root in temporary_roots:
    try:
        if os.path.commonpath((cwd, root)) == root and cwd != root:
            break
    except ValueError:
        pass
else:
    raise SystemExit("Codex private cwd is outside the test temporary root")
PY
  if sed -n '/codex_cwd_entries_begin/,/codex_cwd_entries_end/p' "$CASE_PRIVATE" | sed '1d;$d' | grep -q .; then
    test_diag 'Codex private cwd was not empty at launch'
    return 1
  fi
}

test_codex_strict_does_not_inherit_poison_configuration() {
  local poison poisons
  prepare_case || return 1
  poisons="$CASE_DIR/project-hook-ran
$CASE_DIR/project-mcp-ran
$CASE_DIR/project-skill-ran
$CASE_DIR/user-hook-ran
$CASE_DIR/user-mcp-ran
$CASE_DIR/user-plugin-ran"
  CCCC_FAKE_POISON_SENTINELS="$poisons" run_consult codex
  assert_success_outputs codex || return 1
  argv_has_exact_argument --ignore-user-config || return 1
  argv_has_exact_argument --strict-config || return 1
  argv_has_exact_argument 'model_provider="openai"' || return 1
  case "$(cat "$CASE_CWD")" in "$CASE_REPO"|"$CASE_REPO"/*) return 1 ;; esac
  while IFS= read -r poison; do [ -z "$poison" ] || [ ! -e "$poison" ] || return 1; done <<EOF
$poisons
EOF
}

test_codex_inherit_keeps_runtime_isolation_but_warns_side_effects() {
  prepare_case || return 1
  CCCC_CODEX_CONFIG_MODE=inherit run_consult codex
  assert_success_outputs codex || return 1
  for forbidden in --ignore-user-config 'model_provider="openai"'; do
    if argv_has_exact_argument "$forbidden"; then
      test_diag "inherit unexpectedly overrode user config: $forbidden"
      return 1
    fi
  done
  for required in -a never exec --ephemeral read-only --strict-config --ignore-rules \
    --skip-git-repo-check -C project_doc_max_bytes=0 skills.bundled.enabled=false \
    skills.include_instructions=false 'web_search="disabled"' tools.web_search=false \
    allow_login_shell=false check_for_update_on_startup=false analytics.enabled=false \
    feedback.enabled=false 'notify=[]' 'otel.exporter="none"' \
    'otel.metrics_exporter="none"' 'otel.trace_exporter="none"' \
    'history.persistence="none"' 'shell_environment_policy.inherit="none"' \
    shell_environment_policy.ignore_default_excludes=false; do
    argv_has_exact_argument "$required" || return 1
  done
  if argv_has_exact_argument --add-dir; then return 1; fi
  case "$CASE_OUTPUT" in
    *MCP*connector*plugin*hook*provider*|*MCP*连接器*插件*hook*provider*) ;;
    *) test_diag 'inherit warning does not enumerate external side-effect classes'; return 1 ;;
  esac
}

test_prompt_states_security_prohibitions_and_wrapper_boundary() {
  local prompt lower needle forbidden
  prepare_case || return 1
  run_consult claude
  assert_success_outputs || return 1
  prompt=$(argv_prompt)
  lower=$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]')
  for needle in 'not an os sandbox' background detached setsid 'same-uid detached' \
    'tracked and nonignored' ignored '.git' secret 'managed policy' auth api \
    'external container' 'isolated worktree'; do
    case "$lower" in *"$needle"*) ;;
      *) test_diag "prompt lacks security boundary: $needle"; return 1 ;;
    esac
  done
  for forbidden in 'only repo readable' 'writes impossible' 'physical isolation' 'guaranteed consensus'; do
    case "$lower" in *"$forbidden"*) test_diag "prompt makes forbidden claim: $forbidden"; return 1 ;; esac
  done
}

test_codex_strict_fixed_side_effect_controls_and_shell_policy() {
  local config
  prepare_case || return 1
  run_consult codex
  assert_success_outputs codex || return 1
  for config in $CODEX_STRICT_CONFIGS; do
    argv_has_exact_argument "$config" || { test_diag "missing strict config: $config"; return 1; }
  done
}

test_update_notify_and_login_shell_behavior_probes_stay_quiet() {
  local update notify profile
  prepare_case || return 1
  update="$CASE_DIR/update-ran"
  notify="$CASE_DIR/notify-ran"
  profile="$CASE_DIR/profile-ran"
  CCCC_FAKE_UPDATE_SENTINEL="$update" CCCC_FAKE_NOTIFY_SENTINEL="$notify" \
    CCCC_FAKE_PROFILE_SENTINEL="$profile" run_consult codex
  assert_success_outputs codex || return 1
  [ ! -e "$update" ] || { test_diag 'update behavior probe fired'; return 1; }
  [ ! -e "$notify" ] || { test_diag 'notify behavior probe fired'; return 1; }
  [ ! -e "$profile" ] || { test_diag 'login-shell profile behavior probe fired'; return 1; }
}

test_child_environment_is_scoped_and_python_is_isolated() {
  local real_python python_log poison_dir poison_sentinel
  prepare_case || return 1
  real_python=$(command -v python3) || return 1
  python_log="$CASE_DIR/python-argv.log"
  poison_dir="$CASE_DIR/python-poison"
  poison_sentinel="$CASE_DIR/python-sitecustomize-ran"
  if [ "$CONSULT_TEST_WINDOWS" -eq 0 ]; then
    cat >"$CASE_BIN/python3" <<'PYTHON_SHIM'
#!/usr/bin/env bash
printf '%s\n' "${1-}" >>"$CCCC_FAKE_PYTHON_LOG" || exit 98
exec "$CCCC_REAL_PYTHON" "$@"
PYTHON_SHIM
    chmod +x "$CASE_BIN/python3" || return 1
  else
    mkdir -p "$poison_dir" || return 1
    cat >"$poison_dir/sitecustomize.py" <<'PYTHON_POISON'
import os
with open(os.environ["CCCC_PYTHON_POISON_SENTINEL"], "w", encoding="utf-8") as stream:
    stream.write("loaded\n")
PYTHON_POISON
  fi
  BASH_ENV="$CASE_DIR/poison-bash-env" ENV="$CASE_DIR/poison-env" \
    PYTHONPATH="$poison_dir" CCCC_PYTHON_POISON_SENTINEL="$poison_sentinel" \
    CCCC_REAL_PYTHON="$real_python" CCCC_FAKE_PYTHON_LOG="$python_log" run_consult claude
  assert_success_outputs || return 1
  grep -Fxq 'DELEGATE_DEPTH=1' "$CASE_ENV" || return 1
  grep -Fxq 'BASH_ENV=<unset>' "$CASE_ENV" || return 1
  grep -Fxq 'ENV=<unset>' "$CASE_ENV" || return 1
  grep -Fxq 'DISABLE_AUTOUPDATER=1' "$CASE_ENV" || return 1
  grep -Fxq 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1' "$CASE_ENV" || return 1
  if [ "$CONSULT_TEST_WINDOWS" -eq 0 ]; then
    [ -s "$python_log" ] || return 1
    if grep -Fvxq -- '-I' "$python_log"; then
      test_diag 'wrapper made a non-isolated Python call'
      return 1
    fi
  elif [ -e "$poison_sentinel" ]; then
    test_diag 'a Windows wrapper Python call loaded PYTHONPATH sitecustomize'
    return 1
  fi
}

test_clean_run_logs_git_metadata_and_audit_boundary() {
  local log
  prepare_case || return 1
  run_consult claude
  assert_success_outputs || return 1
  log=$(log_path claude "$CASE_CARD")
  grep -Eq 'head(_before)?=|HEAD' "$log" || return 1
  grep -Eq 'dirty|baseline' "$log" || return 1
  case "$CASE_OUTPUT$(cat "$log")" in
    *ignored*Git*metadata*|*Git*metadata*ignored*) ;;
    *) test_diag 'audit-boundary warning is absent'; return 1 ;;
  esac
}

test_dirty_default_rejects_and_escape_warns_boundary() {
  prepare_case || return 1
  printf 'dirty baseline\n' >>"$CASE_REPO/src/tracked.txt"
  run_consult claude
  assert_eq 4 "$CASE_RC" 'dirty default status' || return 1
  assert_not_launched || return 1
  CCCC_ALLOW_DIRTY=1 run_consult claude
  assert_success_outputs || return 1
  case "$CASE_OUTPUT" in
    *WARNING*dirty*Git*metadata*ignored*|*warning*dirty*Git*metadata*ignored*) ;;
    *) test_diag 'dirty escape warning lacks Git metadata and ignored boundary'; return 1 ;;
  esac
}

test_tracked_second_change_is_policy_failure() {
  prepare_case || return 1
  printf 'dirty baseline\n' >>"$CASE_REPO/src/tracked.txt"
  CCCC_ALLOW_DIRTY=1 CCCC_FAKE_SCENARIO=tracked-change run_consult claude
  assert_eq 4 "$CASE_RC" 'tracked second-change status'
}

test_untracked_second_change_is_policy_failure() {
  prepare_case || return 1
  printf 'dirty baseline\n' >"$CASE_REPO/scratch/untracked.txt"
  CCCC_ALLOW_DIRTY=1 CCCC_FAKE_SCENARIO=untracked-change run_consult claude
  assert_eq 4 "$CASE_RC" 'untracked second-change status'
}

test_index_only_second_change_is_policy_failure() {
  prepare_case || return 1
  printf 'dirty baseline\n' >>"$CASE_REPO/src/tracked.txt"
  CCCC_ALLOW_DIRTY=1 CCCC_FAKE_REAL_GIT="$(command -v git)" \
    CCCC_FAKE_SCENARIO=index-only run_consult claude
  assert_eq 4 "$CASE_RC" 'index-only second-change status'
}

test_unchanged_dirty_tracked_untracked_and_index_baselines_succeed() {
  prepare_case || return 1
  printf 'dirty tracked\n' >>"$CASE_REPO/src/tracked.txt"
  CCCC_ALLOW_DIRTY=1 run_consult claude
  assert_success_outputs || return 1
  prepare_case || return 1
  printf 'dirty untracked\n' >"$CASE_REPO/scratch/untracked.txt"
  CCCC_ALLOW_DIRTY=1 run_consult claude
  assert_success_outputs || return 1
  prepare_case || return 1
  printf 'dirty index\n' >>"$CASE_REPO/src/tracked.txt"
  git -C "$CASE_REPO" add src/tracked.txt || return 1
  CCCC_ALLOW_DIRTY=1 run_consult claude
  assert_success_outputs
}

test_head_and_card_changes_are_policy_failures() {
  prepare_case || return 1
  CCCC_FAKE_REAL_GIT="$(command -v git)" CCCC_FAKE_SCENARIO=head-change run_consult claude
  assert_eq 4 "$CASE_RC" 'HEAD change status' || return 1
  prepare_case || return 1
  CCCC_FAKE_SCENARIO=modify-card run_consult claude
  assert_eq 4 "$CASE_RC" 'card content change status' || return 1
  prepare_case || return 1
  CCCC_FAKE_SCENARIO=replace-card-same-content run_consult claude
  assert_eq 4 "$CASE_RC" 'same-content card inode replacement status'
}

test_card_parent_and_docs_ancestor_identity_swaps_fail() {
  prepare_case || return 1
  CCCC_FAKE_EXTERNAL="$CASE_DIR/external" CCCC_FAKE_SCENARIO=replace-card-parent run_consult claude
  assert_eq 4 "$CASE_RC" 'discussion parent identity-swap status' || return 1
  prepare_case || return 1
  CCCC_FAKE_EXTERNAL="$CASE_DIR/external" CCCC_FAKE_SCENARIO=replace-docs-ancestor run_consult claude
  assert_eq 4 "$CASE_RC" 'docs ancestor identity-swap status'
}

test_nested_repository_and_submodule_are_refused() {
  local nested source
  require_consult || return 1
  prepare_case || return 1
  nested="$CASE_REPO/vendor/nested"
  mkdir -p "$nested" || return 1
  git init -q "$nested" || return 1
  CCCC_ALLOW_DIRTY=1 run_consult claude
  [ "$CASE_RC" -ne 0 ] || return 1
  assert_not_launched || return 1
  prepare_case || return 1
  source="$CASE_DIR/submodule-source"
  init_test_repo "$source" || return 1
  printf 'submodule\n' >"$source/file.txt"
  git -C "$source" add file.txt && git -C "$source" commit -q -m initial || return 1
  git -C "$CASE_REPO" -c protocol.file.allow=always submodule add -q "$source" vendor/sub || return 1
  git -C "$CASE_REPO" commit -q -am submodule || return 1
  run_consult claude
  [ "$CASE_RC" -ne 0 ] || return 1
  assert_not_launched
}

test_unborn_repository_requires_dirty_escape() {
  prepare_case || return 1
  git -C "$CASE_REPO" update-ref -d HEAD || return 1
  run_consult codex
  assert_eq 4 "$CASE_RC" 'unborn default status' || return 1
  CCCC_ALLOW_DIRTY=1 run_consult codex
  assert_success_outputs codex
}

test_newline_paths_are_diagnostic_safe() {
  local newline_path
  prepare_case || return 1
  newline_path=$(printf 'scratch/line\nforged-success=1')
  printf 'dirty\n' >"$CASE_REPO/$newline_path"
  run_consult claude
  assert_eq 4 "$CASE_RC" 'newline dirty status' || return 1
  case "$CASE_OUTPUT" in *'forged-success=1'*)
    case "$CASE_OUTPUT" in *'\nforged-success=1'*|*'\\012forged-success=1'*) ;;
      *) test_diag 'newline path was rendered as a forged diagnostic line'; return 1 ;;
    esac
  esac
}

test_natural_reserved_child_statuses_map_to_agent_failure() {
  local scenario artifact forged_marker mutation_marker
  for scenario in natural-124 natural-125 natural-127; do
    prepare_case || return 1
    forged_marker="$CASE_DIR/forged-timeout-stderr"
    CCCC_FAKE_SCENARIO=$scenario CCCC_FAKE_FORGED_TIMEOUT_MARKER="$forged_marker" run_consult claude
    assert_eq 70 "$CASE_RC" "$scenario mapping" || return 1
    if [ "$scenario" = natural-124 ]; then
      [ -s "$forged_marker" ] || { test_diag 'forged timeout stderr scenario did not fire'; return 1; }
    fi
  done
  prepare_case || return 1
  CCCC_FAKE_SCENARIO=nonzero CCCC_FAKE_RC=2 run_consult claude
  assert_eq 70 "$CASE_RC" 'natural child 2 mapping' || return 1
  [ ! -e "$(opinion_path claude "$CASE_CARD")" ] || return 1
  [ ! -e "$(log_path claude "$CASE_CARD")" ] || return 1
  prepare_case || return 1
  CCCC_FAKE_SCENARIO=empty run_consult claude
  assert_eq 5 "$CASE_RC" 'empty opinion status' || return 1
  prepare_case || return 1
  CCCC_FAKE_SCENARIO=nonzero CCCC_FAKE_RC=19 CCCC_FAKE_MUTATE_TRACKED=1 run_consult claude
  assert_eq 4 "$CASE_RC" 'policy failure precedes child failure' || return 1
  prepare_case || return 1
  mutation_marker="$CASE_DIR/timeout-mutation"
  CCCC_TIMEOUT=3 CCCC_FAKE_SCENARIO=timeout CCCC_FAKE_MUTATE_TRACKED=1 \
    CCCC_FAKE_MUTATION_MARKER="$mutation_marker" run_consult claude
  [ -s "$mutation_marker" ] || {
    test_diag 'timeout precedence fixture did not mutate before blocking'
    return 1
  }
  git -C "$CASE_REPO" status --short -- src/tracked.txt | grep -q 'src/tracked.txt' || {
    test_diag 'timeout precedence fixture left no Git-visible change'
    return 1
  }
  assert_eq 4 "$CASE_RC" 'policy failure precedes timeout' || return 1
  prepare_case || return 1
  artifact="$CASE_DIR/referent"; printf 'referent\n' >"$artifact"
  CCCC_FAKE_SCENARIO=poison-run-artifact CCCC_FAKE_ARTIFACT_KIND=symlink \
    CCCC_FAKE_ARTIFACT_NAME=unowned.attack CCCC_FAKE_REFERENT="$artifact" \
    CCCC_FAKE_MUTATE_TRACKED=1 run_consult claude
  assert_eq 125 "$CASE_RC" 'cleanup failure precedes policy failure'
}

test_real_timeout_and_launch_failure_map_exactly() {
  prepare_case || return 1
  CCCC_TIMEOUT=1 CCCC_FAKE_SCENARIO=timeout run_consult claude
  assert_eq 124 "$CASE_RC" 'real timeout status' || return 1
  prepare_case || return 1
  printf '%s\n' '#!/definitely/missing/cccc-interpreter' >"$CASE_BIN/claude"
  chmod +x "$CASE_BIN/claude" || return 1
  run_consult claude
  assert_eq 127 "$CASE_RC" 'launch failure status' || return 1
  assert_not_launched
}

install_runner_status_shim() {
  local real_python=$1 mode=$2
  cat >"$CASE_BIN/python3" <<'RUNNER_SHIM'
#!/usr/bin/env bash
is_runner=0
has_status_file=0
has_status_token_file=0
for argument in "$@"; do
  case "$argument" in
    --status-file) has_status_file=1 ;;
    --status-token-file) has_status_token_file=1 ;;
  esac
done
if [ "$has_status_file" -eq 1 ] && [ "$has_status_token_file" -eq 1 ]; then
  is_runner=1
fi
if [ "$is_runner" -eq 0 ]; then exec "$CCCC_REAL_PYTHON" "$@"; fi
status=
token=
previous=
for argument in "$@"; do
  [ "$previous" = --status-file ] && status=$argument
  [ "$previous" = --status-token-file ] && token=$argument
  previous=$argument
done
case "$CCCC_STATUS_SHIM_MODE" in
  missing) unlink "$token"; exit 0 ;;
  malformed) unlink "$token"; printf 'malformed\n' >"$status"; chmod 600 "$status"; exit 0 ;;
  symlink)
    "$CCCC_REAL_PYTHON" -I "$CCCC_AUTH_STATUS_HELPER" "$token" "$CCCC_STATUS_REFERENT" child-exit 0 || exit 125
    ln -s "$CCCC_STATUS_REFERENT" "$status"
    printf 'fired\n' >"$CCCC_STATUS_ATTACK_MARKER"
    exit 0
    ;;
  fifo) unlink "$token"; mkfifo "$status"; exit 0 ;;
  wrong-mode)
    "$CCCC_REAL_PYTHON" -I "$CCCC_AUTH_STATUS_HELPER" "$token" "$status" child-exit 0 || exit 125
    chmod 644 "$status"
    exit 0
    ;;
  inconsistent)
    "$CCCC_REAL_PYTHON" -I "$CCCC_AUTH_STATUS_HELPER" "$token" "$status" child-exit 19 || exit 125
    exit 0
    ;;
  wrong-mac)
    "$CCCC_REAL_PYTHON" -I "$CCCC_AUTH_STATUS_HELPER" "$token" "$status" child-exit 0 || exit 125
    printf 'x' >>"$status"
    exit 0
    ;;
  signal-window)
    kill -HUP "$PPID"
    sleep 1
    exec "$CCCC_REAL_PYTHON" "$@"
    ;;
  *) exit 98 ;;
esac
RUNNER_SHIM
  chmod +x "$CASE_BIN/python3" || return 1
  CCCC_REAL_PYTHON=$real_python
  CCCC_STATUS_SHIM_MODE=$mode
}

test_runner_status_hmac_namespace_and_rc_mismatches_fail_closed() {
  local mode real_python marker
  real_python=$(command -v python3) || return 1
  for mode in missing malformed symlink fifo wrong-mode wrong-mac inconsistent; do
    if [ "$CONSULT_TEST_WINDOWS" -eq 1 ] && [ "$mode" = wrong-mode ]; then
      continue
    fi
    prepare_case || return 1
    install_runner_status_shim "$real_python" "$mode" || return 1
    marker="$CASE_DIR/status-attack-marker"
    [ "$mode" = symlink ] || printf 'referent\n' >"$CASE_DIR/referent"
    CCCC_REAL_PYTHON="$real_python" CCCC_STATUS_SHIM_MODE="$mode" \
      CCCC_STATUS_REFERENT="$CASE_DIR/referent" CCCC_STATUS_ATTACK_MARKER="$marker" run_consult claude
    assert_eq 125 "$CASE_RC" "$mode runner-status status" || return 1
    if [ "$mode" = symlink ]; then [ -s "$marker" ] || { test_diag 'status symlink injection did not fire'; return 1; }; fi
    case "$CASE_OUTPUT" in *'consult opinion:'*|*'观点:'*) return 1 ;; esac
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
            printf 'fired\n' >"$CCCC_STATUS_MANIFEST_RACE_ONCE"
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
}

assert_status_manifest_race_victim_preserved() {
  local attacked target=${1:-claude}
  [ -s "$CASE_DIR/status-manifest-raced" ] || {
    test_diag 'runner status parse-to-manifest race injection did not fire'
    return 1
  }
  attacked=$(cat "$CASE_DIR/status-manifest-race-path") || return 1
  assert_eq 'replacement victim must survive' \
    "$(cat "$attacked" 2>/dev/null || true)" \
    'replacement runner.status victim was cleaned' || return 1
  assert_eq 125 "$CASE_RC" 'runner status identity-race status' || return 1
  [ ! -e "$(opinion_path "$target" "$CASE_CARD")" ] || return 1
  [ ! -e "$(log_path "$target" "$CASE_CARD")" ]
}

test_authenticated_runner_status_main_and_signal_paths_are_manifest_bound() {
  local real_python barrier pid attempts
  require_posix_inode_capability || return 77
  require_consult || return 1
  prepare_case || return 1
  real_python=$(command -v python3) || return 1
  printf 'replacement victim must survive\n' >"$CASE_DIR/status-manifest-victim"
  install_status_manifest_race_python "$real_python" || return 1
  CCCC_REAL_PYTHON="$real_python" \
    CCCC_STATUS_MANIFEST_RACE_ONCE="$CASE_DIR/status-manifest-raced" \
    CCCC_STATUS_MANIFEST_RACE_PATH="$CASE_DIR/status-manifest-race-path" \
    CCCC_STATUS_MANIFEST_RACE_ORIGINAL="$CASE_DIR/original-runner-status" \
    CCCC_STATUS_MANIFEST_RACE_VICTIM="$CASE_DIR/status-manifest-victim" \
    run_consult codex
  assert_status_manifest_race_victim_preserved codex || return 1

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
    export CCCC_FAKE_CWD_FILE="$CASE_CWD" CCCC_FAKE_PRIVATE_FILE="$CASE_PRIVATE"
    export CCCC_FAKE_CALLS_FILE="$CASE_CALLS" CCCC_FAKE_LAUNCH_FILE="$CASE_LAUNCH"
    export CCCC_FAKE_BARRIER_DIR="$barrier" CCCC_FAKE_REPO="$CASE_REPO"
    export CCCC_FAKE_CARD="$CASE_CARD"
    export CCCC_AUTH_STATUS_HELPER="$AUTH_STATUS_HELPER"
    exec_consult_with_signal_defaults "$real_python" claude "$CASE_CARD" "$CASE_REPO"
  ) >"$CASE_DIR/status-signal-output" 2>&1 & pid=$!
  if ! wait_for_ready_count "$barrier" 1; then
    : >"$barrier/release"; terminate_and_reap_pid "$pid" || true; return 1
  fi
  kill -HUP "$pid" || { : >"$barrier/release"; terminate_and_reap_pid "$pid" || true; return 1; }
  attempts=500
  while [ ! -s "$CASE_DIR/status-manifest-race-path" ] && [ "$attempts" -gt 0 ]; do
    sleep 0.02
    attempts=$((attempts - 1))
  done
  : >"$barrier/release"
  attempts=250
  while kill -0 "$pid" 2>/dev/null && [ "$attempts" -gt 0 ]; do
    sleep 0.02
    attempts=$((attempts - 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    terminate_and_reap_pid "$pid" || true
    test_diag 'signal runner-status identity-race invocation exceeded bounded wait'
    return 1
  fi
  wait "$pid"
  CASE_RC=$?
  assert_status_manifest_race_victim_preserved claude
}

test_runner_pid_registration_signal_window_is_retryable() {
  local barrier wrapper_pid attempts rc fake_pid injected script_dir real_python
  require_posix_inode_capability || return 77
  require_consult || return 1
  prepare_case || return 1
  barrier="$CASE_DIR/pid-window-barrier"
  injected="$CASE_DIR/consult-pid-window.sh"
  script_dir=$(dirname -- "$CONSULT")
  real_python=$(command -v python3) || return 1
  mkdir -p "$barrier" || return 1
  python3 -I - "$CONSULT" "$injected" "$script_dir" <<'PY'
import shlex
import sys

source_path, output_path, script_dir = sys.argv[1:]
source = open(source_path, encoding="utf-8").read()
script_line = 'SCRIPT_DIR=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 127'
if script_line not in source:
    raise SystemExit("consult SCRIPT_DIR line changed")
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
    raise SystemExit("consult runner PID assignment changed")
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
  CONSULT="$injected" CCCC_PID_WINDOW_MARKER="$CASE_DIR/pid-window-injected" \
    CCCC_REAL_PYTHON="$real_python" CCCC_PID_WINDOW_BARRIER="$barrier" \
    CCCC_PID_WINDOW_EARLY_RELEASE="$CASE_DIR/lock-released-while-child-alive" \
    CCCC_FAKE_BARRIER_DIR="$barrier" invoke_consult_explicit \
      "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" claude "$CASE_CARD" \
      "$CASE_DIR/pid-window-output" "$CASE_DIR/pid-window-rc" "$CASE_LAUNCH" &
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
    *'consult opinion:'*|*'观点:'*) return 1 ;;
  esac
  unlink "$CASE_BIN/python3" || return 1
  install_fake_agents "$CASE_BIN" || return 1
  : >"$CASE_LAUNCH"
  run_consult claude
  assert_success_outputs
}

test_signals_cleanup_descendants_outputs_lock_and_allow_retry() {
  local signal expected barrier pid child_pid attempts rc common lock launcher_python
  require_posix_inode_capability || return 77
  require_consult || return 1
  for signal in HUP INT TERM; do
    case "$signal" in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
    prepare_case || return 1
    launcher_python=$(command -v python3) || return 1
    barrier="$CASE_DIR/signal-barrier"
    mkdir -p "$barrier" || return 1
    (
      export PATH="$CASE_BIN:$ORIGINAL_PATH" TMPDIR="$CASE_TMP"
      export CCCC_FAKE_SCENARIO=background-descendant CCCC_FAKE_BARRIER_DIR="$barrier"
      export CCCC_FAKE_DESCENDANT_PID_FILE="$CASE_DIR/descendant.pid"
      export CCCC_FAKE_LAUNCH_FILE="$CASE_LAUNCH" CCCC_FAKE_REPO="$CASE_REPO"
      export CCCC_FAKE_CARD="$CASE_CARD" CCCC_AUTH_STATUS_HELPER="$AUTH_STATUS_HELPER"
      exec_consult_with_signal_defaults "$launcher_python" claude "$CASE_CARD" "$CASE_REPO"
    ) >"$CASE_DIR/signal-output" 2>&1 & pid=$!
    if ! wait_for_ready_count "$barrier" 1; then
      : >"$barrier/release"; terminate_and_reap_pid "$pid" || true; return 1
    fi
    attempts=250
    while [ ! -s "$CASE_DIR/descendant.pid" ] && [ "$attempts" -gt 0 ]; do sleep 0.02; attempts=$((attempts - 1)); done
    [ -s "$CASE_DIR/descendant.pid" ] || { : >"$barrier/release"; terminate_and_reap_pid "$pid" || true; return 1; }
    child_pid=$(cat "$CASE_DIR/descendant.pid")
    case "$child_pid" in ''|*[!0-9]*) : >"$barrier/release"; terminate_and_reap_pid "$pid" || true; return 1 ;; esac
    kill -0 "$child_pid" 2>/dev/null || { : >"$barrier/release"; terminate_and_reap_pid "$pid" || true; return 1; }
    kill -s "$signal" "$pid" || return 1
    attempts=400
    while kill -0 "$pid" 2>/dev/null && [ "$attempts" -gt 0 ]; do sleep 0.02; attempts=$((attempts - 1)); done
    if kill -0 "$pid" 2>/dev/null; then
      : >"$barrier/release"; terminate_and_reap_pid "$pid" || true; return 1
    fi
    if wait "$pid"; then rc=0; else rc=$?; fi
    : >"$barrier/release"
    assert_eq "$expected" "$rc" "$signal wrapper status" || return 1
    if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
      kill -KILL "$child_pid" 2>/dev/null || true
      test_diag "$signal left a descendant alive"
      return 1
    fi
    [ ! -e "$(opinion_path claude "$CASE_CARD")" ] || return 1
    [ ! -e "$(log_path claude "$CASE_CARD")" ] || return 1
    common=$(git -C "$CASE_REPO" rev-parse --path-format=absolute --git-common-dir) || return 1
    lock="$common/cccc-v2.lock"
    [ ! -e "$lock" ] || return 1
    : >"$CASE_LAUNCH"
    run_consult claude
    assert_success_outputs || return 1
  done
}

start_consult_barrier() {
  local barrier=$1 output=$2 rc_file=$3 launch=$4 target=$5 card=$6
  CCCC_FAKE_BARRIER_DIR="$barrier" invoke_consult_explicit "$CASE_REPO" "$CASE_BIN" \
    "$CASE_TMP" "$target" "$card" "$output" "$rc_file" "$launch" &
  STARTED_PID=$!
}

wait_for_rc_file() {
  local file=$1 pid=$2 context=$3 attempts=250
  while [ ! -s "$file" ] && [ "$attempts" -gt 0 ]; do
    sleep 0.02
    attempts=$((attempts - 1))
  done
  if [ ! -s "$file" ]; then
    terminate_and_reap_pid "$pid" || true
    test_diag "$context exceeded bounded wait"
    return 1
  fi
  wait_pid_bounded "$pid" 100 || terminate_and_reap_pid "$pid" || return 1
}

assert_lock_precedes_codex_preflight_stage() {
  local stage=$1 barrier owner_pid loser_pid loser_launch
  prepare_case || return 1
  barrier="$CASE_DIR/preflight-$stage-barrier"
  loser_launch="$CASE_DIR/preflight-$stage-loser-launch"
  mkdir -p "$barrier" || return 1
  CCCC_FAKE_PREFLIGHT_BARRIER_STAGE="$stage" CCCC_FAKE_PREFLIGHT_BARRIER_DIR="$barrier" \
    invoke_consult_explicit "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" codex "$CASE_CARD" \
      "$CASE_DIR/preflight-owner-output" "$CASE_DIR/preflight-owner-rc" "$CASE_LAUNCH" & owner_pid=$!
  if ! wait_for_ready_count "$barrier" 1; then
    : >"$barrier/release"; terminate_and_reap_pid "$owner_pid" || true; return 1
  fi
  invoke_consult_explicit "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" codex "$CASE_CARD" \
    "$CASE_DIR/preflight-loser-output" "$CASE_DIR/preflight-loser-rc" "$loser_launch" & loser_pid=$!
  if ! wait_for_rc_file "$CASE_DIR/preflight-loser-rc" "$loser_pid" "$stage preflight lock loser"; then
    : >"$barrier/release"; terminate_and_reap_pid "$owner_pid" || true; return 1
  fi
  assert_eq 5 "$(cat "$CASE_DIR/preflight-loser-rc")" "$stage preflight lock status" || {
    : >"$barrier/release"; terminate_and_reap_pid "$owner_pid" || true; return 1;
  }
  [ ! -s "$loser_launch" ] || { : >"$barrier/release"; terminate_and_reap_pid "$owner_pid" || true; return 1; }
  [ ! -s "$CASE_DIR/preflight-loser-output.calls" ] || {
    : >"$barrier/release"; terminate_and_reap_pid "$owner_pid" || true
    test_diag "$stage loser reached a Codex preflight call before lock rejection"
    return 1
  }
  : >"$barrier/release"
  wait_for_rc_file "$CASE_DIR/preflight-owner-rc" "$owner_pid" "$stage preflight lock owner" || return 1
  assert_eq 0 "$(cat "$CASE_DIR/preflight-owner-rc")" "$stage preflight owner status"
}

assert_lock_precedes_git_baseline() {
  local real_git barrier owner_pid loser_pid count
  prepare_case || return 1
  real_git=$(command -v git) || return 1
  barrier="$CASE_DIR/git-status-barrier"
  mkdir -p "$barrier" || return 1
  cat >"$CASE_BIN/git" <<'STATUS_GIT_SHIM'
#!/usr/bin/env bash
is_status=0
for argument in "$@"; do [ "$argument" = status ] && is_status=1; done
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
    CCCC_FAKE_REAL_GIT="$real_git" invoke_consult_explicit \
      "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" claude "$CASE_CARD" \
      "$CASE_DIR/baseline-owner-output" "$CASE_DIR/baseline-owner-rc" "$CASE_LAUNCH" & owner_pid=$!
  if ! wait_for_ready_count "$barrier" 1; then
    : >"$barrier/release"; terminate_and_reap_pid "$owner_pid" || true; return 1
  fi
  CCCC_GIT_STATUS_LOG="$CASE_DIR/status.log" CCCC_FAKE_REAL_GIT="$real_git" \
    invoke_consult_explicit "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" codex "$CASE_CARD" \
      "$CASE_DIR/baseline-loser-output" "$CASE_DIR/baseline-loser-rc" \
      "$CASE_DIR/baseline-loser-launch" & loser_pid=$!
  if ! wait_for_rc_file "$CASE_DIR/baseline-loser-rc" "$loser_pid" 'baseline lock loser'; then
    : >"$barrier/release"; terminate_and_reap_pid "$owner_pid" || true; return 1
  fi
  assert_eq 5 "$(cat "$CASE_DIR/baseline-loser-rc")" 'baseline lock collision status' || {
    : >"$barrier/release"; terminate_and_reap_pid "$owner_pid" || true; return 1;
  }
  count=$(wc -l <"$CASE_DIR/status.log" | tr -d ' ')
  assert_eq 1 "$count" 'lock loser reached Git baseline' || {
    : >"$barrier/release"; terminate_and_reap_pid "$owner_pid" || true; return 1;
  }
  [ ! -s "$CASE_DIR/baseline-loser-launch" ] || { : >"$barrier/release"; terminate_and_reap_pid "$owner_pid" || true; return 1; }
  : >"$barrier/release"
  wait_for_rc_file "$CASE_DIR/baseline-owner-rc" "$owner_pid" 'baseline lock owner' || return 1
  assert_eq 0 "$(cat "$CASE_DIR/baseline-owner-rc")" 'baseline lock owner status'
}

assert_lock_acquisition_signal_window() {
  local real_ln
  require_posix_inode_capability || return 77
  prepare_case || return 1
  real_ln=$(command -v ln) || return 1
  cat >"$CASE_BIN/ln" <<'LOCK_SIGNAL_SHIM'
#!/usr/bin/env bash
"$CCCC_REAL_LN" "$@"
rc=$?
case ${!#} in */cccc-v2.lock) [ "$rc" -ne 0 ] || kill -HUP "$PPID" ;; esac
exit "$rc"
LOCK_SIGNAL_SHIM
  chmod +x "$CASE_BIN/ln" || return 1
  CCCC_REAL_LN="$real_ln" run_consult claude
  assert_eq 129 "$CASE_RC" 'lock acquisition signal-window status' || return 1
  assert_not_launched || return 1
  unlink "$CASE_BIN/ln" || return 1
  : >"$CASE_LAUNCH"
  run_consult claude
  assert_success_outputs
}

assert_lock_held_during_publication() {
  local real_python barrier owner_pid loser_pid
  prepare_case || return 1
  real_python=$(command -v python3) || return 1
  barrier="$CASE_DIR/publication-lock-barrier"
  mkdir -p "$barrier" || return 1
  cat >"$CASE_BIN/python3" <<'PUBLICATION_LOCK_SHIM'
#!/usr/bin/env bash
is_publish=0
for argument in "$@"; do [ "$argument" = --parent-identity ] && is_publish=1; done
if [ "$is_publish" -eq 1 ] && [ ! -e "$CCCC_PUBLISH_BARRIER/once" ]; then
  : >"$CCCC_PUBLISH_BARRIER/once"
  : >"$CCCC_PUBLISH_BARRIER/ready.$$"
  attempts=3000
  while [ ! -e "$CCCC_PUBLISH_BARRIER/release" ] && [ "$attempts" -gt 0 ]; do
    sleep 0.02; attempts=$((attempts - 1))
  done
  [ -e "$CCCC_PUBLISH_BARRIER/release" ] || exit 98
fi
exec "$CCCC_REAL_PYTHON" "$@"
PUBLICATION_LOCK_SHIM
  chmod +x "$CASE_BIN/python3" || return 1
  CCCC_REAL_PYTHON="$real_python" CCCC_PUBLISH_BARRIER="$barrier" \
    invoke_consult_explicit "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" claude "$CASE_CARD" \
      "$CASE_DIR/publication-owner-output" "$CASE_DIR/publication-owner-rc" "$CASE_LAUNCH" & owner_pid=$!
  if ! wait_for_ready_count "$barrier" 1; then
    : >"$barrier/release"; terminate_and_reap_pid "$owner_pid" || true; return 1
  fi
  CCCC_REAL_PYTHON="$real_python" CCCC_PUBLISH_BARRIER="$barrier" \
    invoke_consult_explicit "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" codex "$CASE_CARD" \
      "$CASE_DIR/publication-loser-output" "$CASE_DIR/publication-loser-rc" \
      "$CASE_DIR/publication-loser-launch" & loser_pid=$!
  if ! wait_for_rc_file "$CASE_DIR/publication-loser-rc" "$loser_pid" 'publication lock loser'; then
    : >"$barrier/release"; terminate_and_reap_pid "$owner_pid" || true; return 1
  fi
  assert_eq 5 "$(cat "$CASE_DIR/publication-loser-rc")" 'publication-phase lock status' || {
    : >"$barrier/release"; terminate_and_reap_pid "$owner_pid" || true; return 1;
  }
  [ ! -s "$CASE_DIR/publication-loser-launch" ] || { : >"$barrier/release"; terminate_and_reap_pid "$owner_pid" || true; return 1; }
  : >"$barrier/release"
  wait_for_rc_file "$CASE_DIR/publication-owner-rc" "$owner_pid" 'publication lock owner' || return 1
  assert_eq 0 "$(cat "$CASE_DIR/publication-owner-rc")" 'publication lock owner status'
}

test_repo_lock_blocks_same_and_different_consult_cards_and_targets() {
  local barrier first_pid second_pid card second_launch attempts
  require_consult || return 1
  for card in docs/discussions/D-test.md docs/discussions/D-other.md; do
    prepare_case || return 1
    if [ "$card" != "$CASE_CARD" ]; then
      write_discussion_card "$CASE_REPO" "$card" || return 1
      git -C "$CASE_REPO" add "$card" && git -C "$CASE_REPO" commit -q -m other-card || return 1
    fi
    barrier="$CASE_DIR/lock-barrier"; mkdir -p "$barrier" || return 1
    start_consult_barrier "$barrier" "$CASE_DIR/first-output" "$CASE_DIR/first-rc" "$CASE_LAUNCH" claude "$CASE_CARD"
    first_pid=$STARTED_PID
    wait_for_ready_count "$barrier" 1 || { : >"$barrier/release"; terminate_and_reap_pid "$first_pid" || true; return 1; }
    second_launch="$CASE_DIR/second-launch"
    invoke_consult_explicit "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" codex "$card" \
      "$CASE_DIR/second-output" "$CASE_DIR/second-rc" "$second_launch" & second_pid=$!
    wait_pid_bounded "$second_pid" 250 || { : >"$barrier/release"; terminate_and_reap_pid "$second_pid" || true; terminate_and_reap_pid "$first_pid" || true; return 1; }
    assert_eq 5 "$(cat "$CASE_DIR/second-rc")" 'same-repo lock loser status' || return 1
    [ ! -s "$second_launch" ] || return 1
    : >"$barrier/release"
    wait_pid_bounded "$first_pid" 300 || return 1
    assert_eq 0 "$(cat "$CASE_DIR/first-rc")" 'same-repo lock owner status' || return 1
  done
  assert_lock_precedes_git_baseline || return 1
  for card in root-help exec-help features; do
    assert_lock_precedes_codex_preflight_stage "$card" || return 1
  done
  if require_posix_inode_capability; then
    assert_lock_acquisition_signal_window || return 1
  fi
  if [ "$CONSULT_TEST_WINDOWS" -eq 0 ]; then
    assert_lock_held_during_publication
  fi
}

write_delegate_card() {
  mkdir -p "$CASE_REPO/docs/tasks" || return 1
  {
    printf '# Delegate lock test\n\n'
    printf '<!-- cccc-allowed-paths\n'
    printf 'src/\n'
    printf '%s\n' '-->'
  } >"$CASE_REPO/docs/tasks/T-lock.md"
  git -C "$CASE_REPO" add docs/tasks/T-lock.md || return 1
  git -C "$CASE_REPO" commit -q -m delegate-card || return 1
}

invoke_delegate_for_lock() {
  local output=$1 rc_file=$2 launch=$3
  (
    export PATH="$CASE_BIN:$ORIGINAL_PATH" TMPDIR="$CASE_TMP"
    export CCCC_FAKE_LAUNCH_FILE="$launch" CCCC_FAKE_REPO="$CASE_REPO"
    export CCCC_FAKE_CARD=docs/tasks/T-lock.md CCCC_AUTH_STATUS_HELPER="$AUTH_STATUS_HELPER"
    "$DELEGATE" claude docs/tasks/T-lock.md "$CASE_REPO" >"$output" 2>&1
    printf '%s\n' "$?" >"$rc_file"
  )
}

test_delegate_and_consult_share_the_lock_in_both_directions() {
  local barrier owner loser owner_pid loser_pid
  require_consult || return 1
  prepare_case || return 1
  write_delegate_card || return 1
  barrier="$CASE_DIR/delegate-owner-barrier"; mkdir -p "$barrier" || return 1
  CCCC_FAKE_BARRIER_DIR="$barrier" invoke_delegate_for_lock "$CASE_DIR/delegate-owner-output" \
    "$CASE_DIR/delegate-owner-rc" "$CASE_DIR/delegate-owner-launch" & owner_pid=$!
  wait_for_ready_count "$barrier" 1 || { : >"$barrier/release"; terminate_and_reap_pid "$owner_pid" || true; return 1; }
  invoke_consult_explicit "$CASE_REPO" "$CASE_BIN" "$CASE_TMP" codex "$CASE_CARD" \
    "$CASE_DIR/consult-loser-output" "$CASE_DIR/consult-loser-rc" "$CASE_DIR/consult-loser-launch" & loser_pid=$!
  wait_pid_bounded "$loser_pid" 250 || { : >"$barrier/release"; terminate_and_reap_pid "$loser_pid" || true; terminate_and_reap_pid "$owner_pid" || true; return 1; }
  assert_eq 5 "$(cat "$CASE_DIR/consult-loser-rc")" 'delegate to consult lock status' || return 1
  [ ! -s "$CASE_DIR/consult-loser-launch" ] || return 1
  : >"$barrier/release"; wait_pid_bounded "$owner_pid" 300 || return 1
  assert_eq 0 "$(cat "$CASE_DIR/delegate-owner-rc")" 'delegate lock owner status' || return 1

  prepare_case || return 1
  write_delegate_card || return 1
  barrier="$CASE_DIR/consult-owner-barrier"; mkdir -p "$barrier" || return 1
  start_consult_barrier "$barrier" "$CASE_DIR/consult-owner-output" "$CASE_DIR/consult-owner-rc" \
    "$CASE_DIR/consult-owner-launch" claude "$CASE_CARD"; owner_pid=$STARTED_PID
  wait_for_ready_count "$barrier" 1 || { : >"$barrier/release"; terminate_and_reap_pid "$owner_pid" || true; return 1; }
  invoke_delegate_for_lock "$CASE_DIR/delegate-loser-output" "$CASE_DIR/delegate-loser-rc" \
    "$CASE_DIR/delegate-loser-launch" & loser_pid=$!
  wait_pid_bounded "$loser_pid" 250 || { : >"$barrier/release"; terminate_and_reap_pid "$loser_pid" || true; terminate_and_reap_pid "$owner_pid" || true; return 1; }
  assert_eq 5 "$(cat "$CASE_DIR/delegate-loser-rc")" 'consult to delegate lock status' || return 1
  [ ! -s "$CASE_DIR/delegate-loser-launch" ] || return 1
  : >"$barrier/release"; wait_pid_bounded "$owner_pid" 300 || return 1
  assert_eq 0 "$(cat "$CASE_DIR/consult-owner-rc")" 'consult lock owner status'
}

test_linked_worktrees_share_the_physical_common_dir_lock() {
  local linked barrier owner_pid loser_pid
  require_consult || return 1
  prepare_case || return 1
  linked="$CASE_DIR/linked"
  git -C "$CASE_REPO" worktree add -q -b consult-linked "$linked" || return 1
  barrier="$CASE_DIR/linked-barrier"; mkdir -p "$barrier" || return 1
  start_consult_barrier "$barrier" "$CASE_DIR/owner-output" "$CASE_DIR/owner-rc" \
    "$CASE_DIR/owner-launch" claude "$CASE_CARD"; owner_pid=$STARTED_PID
  wait_for_ready_count "$barrier" 1 || { : >"$barrier/release"; terminate_and_reap_pid "$owner_pid" || true; return 1; }
  invoke_consult_explicit "$linked" "$CASE_BIN" "$CASE_TMP" codex "$CASE_CARD" \
    "$CASE_DIR/loser-output" "$CASE_DIR/loser-rc" "$CASE_DIR/loser-launch" & loser_pid=$!
  wait_pid_bounded "$loser_pid" 250 || { : >"$barrier/release"; terminate_and_reap_pid "$loser_pid" || true; terminate_and_reap_pid "$owner_pid" || true; return 1; }
  assert_eq 5 "$(cat "$CASE_DIR/loser-rc")" 'linked-worktree lock status' || return 1
  [ ! -s "$CASE_DIR/loser-launch" ] || return 1
  : >"$barrier/release"; wait_pid_bounded "$owner_pid" 300 || return 1
  assert_eq 0 "$(cat "$CASE_DIR/owner-rc")" 'linked-worktree lock owner status'
}

test_different_repositories_can_consult_concurrently() {
  local a_dir a_repo a_bin a_tmp a_card b_dir b_repo b_bin b_tmp b_card barrier p1 p2
  require_consult || return 1
  prepare_case || return 1
  a_dir=$CASE_DIR; a_repo=$CASE_REPO; a_bin=$CASE_BIN; a_tmp=$CASE_TMP; a_card=$CASE_CARD
  prepare_case || return 1
  b_dir=$CASE_DIR; b_repo=$CASE_REPO; b_bin=$CASE_BIN; b_tmp=$CASE_TMP; b_card=$CASE_CARD
  barrier="$TEST_TMP_ROOT/cross-repo-barrier"; mkdir -p "$barrier" || return 1
  CCCC_FAKE_BARRIER_DIR="$barrier" invoke_consult_explicit "$a_repo" "$a_bin" "$a_tmp" \
    claude "$a_card" "$a_dir/output" "$a_dir/rc" "$a_dir/launch" & p1=$!
  CCCC_FAKE_BARRIER_DIR="$barrier" invoke_consult_explicit "$b_repo" "$b_bin" "$b_tmp" \
    codex "$b_card" "$b_dir/output" "$b_dir/rc" "$b_dir/launch" & p2=$!
  wait_for_ready_count "$barrier" 2 || { : >"$barrier/release"; terminate_and_reap_pid "$p1" || true; terminate_and_reap_pid "$p2" || true; return 1; }
  : >"$barrier/release"
  wait_pid_bounded "$p1" 300 || return 1
  wait_pid_bounded "$p2" 300 || return 1
  assert_eq 0 "$(cat "$a_dir/rc")" 'first repo status' || return 1
  assert_eq 0 "$(cat "$b_dir/rc")" 'second repo status'
}

test_stale_symlink_fifo_outputs_are_bounded_and_never_clobbered() {
  local opinion log referent
  require_consult || return 1
  require_symlink_capability "$TEST_TMP_ROOT" || return 77
  require_fifo_capability "$TEST_TMP_ROOT" || return 77
  prepare_case || return 1
  opinion=$(opinion_path claude "$CASE_CARD"); log=$(log_path claude "$CASE_CARD")
  printf 'stale opinion\n' >"$opinion"; printf 'stale log\n' >"$log"
  CCCC_ALLOW_DIRTY=1 run_consult claude
  [ "$CASE_RC" -ne 0 ] || return 1
  assert_eq 'stale opinion' "$(cat "$opinion")" || return 1
  assert_eq 'stale log' "$(cat "$log")" || return 1
  prepare_case || return 1
  opinion=$(opinion_path claude "$CASE_CARD"); referent="$CASE_DIR/referent"
  printf 'referent\n' >"$referent"; ln -s "$referent" "$opinion" || return 1
  CCCC_ALLOW_DIRTY=1 run_consult claude
  [ "$CASE_RC" -ne 0 ] || return 1
  assert_eq referent "$(cat "$referent")" || return 1
  prepare_case || return 1
  log=$(log_path claude "$CASE_CARD"); mkfifo "$log" || return 1
  CCCC_ALLOW_DIRTY=1 run_consult claude
  [ "$CASE_RC" -ne 0 ] || return 1
}

test_target_outputs_do_not_conflict_and_second_run_obeys_dirty_gate() {
  local first opinion content identity
  prepare_case || return 1
  CCCC_FAKE_OPINION='claude first' run_consult claude
  assert_success_outputs claude || return 1
  opinion=$(opinion_path claude "$CASE_CARD"); content=$(cat "$opinion")
  identity=$(stat -c '%d:%i' "$opinion" 2>/dev/null || stat -f '%d:%i' "$opinion") || return 1
  : >"$CASE_LAUNCH"
  CCCC_FAKE_OPINION='codex second' run_consult codex
  assert_eq 4 "$CASE_RC" 'second target dirty-default status' || return 1
  [ ! -s "$CASE_LAUNCH" ] || return 1
  CCCC_ALLOW_DIRTY=1 CCCC_FAKE_OPINION='codex second' run_consult codex
  assert_success_outputs codex || return 1
  assert_eq "$content" "$(cat "$opinion")" 'first opinion content changed' || return 1
  assert_eq "$identity" "$(stat -c '%d:%i' "$opinion" 2>/dev/null || stat -f '%d:%i' "$opinion")" 'first opinion inode changed'
}

install_publication_attack_python() {
  local real_python=$1
  cat >"$CASE_BIN/python3" <<'PUBLISH_SHIM'
#!/usr/bin/env bash
is_publish=0
is_parent_identity=0
source=
destination=
previous=
second_last=
last=
case ${2-} in */publish-no-clobber.py) is_publish=1 ;; esac
for argument in "$@"; do
  case "$argument" in --print-parent-identity) is_parent_identity=1 ;; esac
  second_last=$last
  last=$argument
done
if [ "$is_parent_identity" -eq 1 ]; then
  exec "$CCCC_REAL_PYTHON" "$@"
fi
if [ "$is_publish" -eq 1 ]; then
  source=$second_last
  destination=$last
  has_parent=0; has_identity=0; has_sha=0; previous=
  for argument in "$@"; do
    [ "$argument" = --parent-identity ] && has_parent=1
    [ "$argument" = --source-identity ] && has_identity=1
    [ "$argument" = --source-sha256 ] && has_sha=1
    if [ "$previous" = --source-identity ]; then
      case "$argument" in *:*) ;; *) exit 92 ;; esac
    fi
    if [ "$previous" = --source-sha256 ]; then
      [ "${#argument}" -eq 64 ] || exit 93
      case "$argument" in *[!0-9a-f]*) exit 93 ;; esac
    fi
    previous=$argument
  done
  [ "$has_parent" -eq 1 ] && [ "$has_identity" -eq 1 ] && [ "$has_sha" -eq 1 ] || exit 91
  case "$CCCC_PUBLISH_ATTACK_MODE:$source:$destination" in
    fail-opinion:*-opinion.md) exit 9 ;;
    path-replace:*/consult.log:*|path-replace:*/opinion.md:*)
      case "$source:$CCCC_PUBLISH_SOURCE_KIND" in
        */consult.log:consult.log|*/opinion.md:opinion.md)
          if [ ! -e "$CCCC_PUBLISH_ATTACK_MARKER" ]; then
            printf 'fired\n' >"$CCCC_PUBLISH_ATTACK_MARKER"
            printf '%s\n' "$source" >"$CCCC_PUBLISH_ATTACK_PATH"
            mv "$source" "$CCCC_PUBLISH_ATTACK_ORIGINAL" || exit 97
            mv "$CCCC_PUBLISH_ATTACK_VICTIM" "$source" || exit 97
          fi
          ;;
      esac
      ;;
    same-inode:*/consult.log:*|same-inode:*/opinion.md:*)
      case "$source:$CCCC_PUBLISH_SOURCE_KIND" in
        */consult.log:consult.log|*/opinion.md:opinion.md)
          if [ ! -e "$CCCC_PUBLISH_ATTACK_MARKER" ]; then
            printf '%s\n' "$CCCC_PUBLISH_SOURCE_KIND" >"$CCCC_PUBLISH_ATTACK_MARKER"
            printf 'forged same-inode %s\n' "$CCCC_PUBLISH_SOURCE_KIND" >"$source" || exit 97
          fi
          ;;
      esac
      ;;
    swap-parent:*/opinion.md:*)
      printf 'fired\n' >"$CCCC_PUBLISH_ATTACK_MARKER"
      mv "$CCCC_FAKE_REPO/docs/discussions" "$CCCC_FAKE_REPO/docs/discussions.old"
      mkdir "$CCCC_FAKE_REPO/docs/discussions"
      printf 'replacement victim\n' >"$CCCC_FAKE_REPO/docs/discussions/victim"
      ;;
  esac
fi
exec "$CCCC_REAL_PYTHON" "$@"
PUBLISH_SHIM
  chmod +x "$CASE_BIN/python3" || return 1
  CCCC_REAL_PYTHON=$real_python
}

install_publication_signal_python() {
  local real_python=$1
  cat >"$CASE_BIN/python3" <<'PUBLISH_SIGNAL_SHIM'
#!/usr/bin/env bash
is_publish=0
is_parent_identity=0
second_last=
last=
case ${2-} in */publish-no-clobber.py) is_publish=1 ;; esac
for argument in "$@"; do
  case "$argument" in --print-parent-identity) is_parent_identity=1 ;; esac
  second_last=$last
  last=$argument
done
if [ "$is_publish" -eq 1 ] && [ "$is_parent_identity" -eq 0 ] &&
  [ -n "${CCCC_PUBLISH_SIGNAL_BARRIER-}" ]; then
  publication_signal_barrier() {
    mkdir -p "$CCCC_PUBLISH_SIGNAL_BARRIER" || exit 97
    printf 'ready\n' >"$CCCC_PUBLISH_SIGNAL_BARRIER/ready.$$" || exit 97
    attempts=${CCCC_PUBLISH_SIGNAL_TICKS:-1500}
    while [ ! -e "$CCCC_PUBLISH_SIGNAL_BARRIER/release" ] && [ "$attempts" -gt 0 ]; do
      sleep 0.02
      attempts=$((attempts - 1))
    done
    [ -e "$CCCC_PUBLISH_SIGNAL_BARRIER/release" ] || exit 98
  }
  case "${CCCC_PUBLISH_SIGNAL_PHASE-before-log}:${second_last##*/}" in
    before-log:consult.log)
      publication_signal_barrier
      ;;
    after-log:consult.log|after-opinion:opinion.md)
      "$CCCC_REAL_PYTHON" "$@"
      rc=$?
      [ "$rc" -eq 0 ] || exit "$rc"
      publication_signal_barrier
      exit 0
      ;;
  esac
fi
exec "$CCCC_REAL_PYTHON" "$@"
PUBLISH_SIGNAL_SHIM
  chmod +x "$CASE_BIN/python3" || return 1
}

test_signal_before_log_publication_commits_no_output() {
  local real_python barrier wrapper_pid publisher_pid attempts rc common lock launcher_python signal expected
  require_posix_inode_capability || return 77
  require_consult || return 1
  real_python=$(command -v python3) || return 1
  launcher_python=$real_python
  for signal in HUP INT TERM; do
    case "$signal" in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
    prepare_case || return 1
    install_publication_signal_python "$real_python" || return 1
    barrier="$CASE_DIR/publication-signal-barrier"
    mkdir -p "$barrier" || return 1
    (
      export PATH="$CASE_BIN:$ORIGINAL_PATH" TMPDIR="$CASE_TMP"
      export CCCC_REAL_PYTHON="$real_python" CCCC_PUBLISH_SIGNAL_BARRIER="$barrier"
      export CCCC_PUBLISH_SIGNAL_PHASE=before-log
      export CCCC_FAKE_ARGV_FILE="$CASE_ARGV" CCCC_FAKE_ENV_FILE="$CASE_ENV"
      export CCCC_FAKE_CWD_FILE="$CASE_CWD" CCCC_FAKE_PRIVATE_FILE="$CASE_PRIVATE"
      export CCCC_FAKE_CALLS_FILE="$CASE_CALLS" CCCC_FAKE_LAUNCH_FILE="$CASE_LAUNCH"
      export CCCC_FAKE_REPO="$CASE_REPO" CCCC_FAKE_CARD="$CASE_CARD"
      export CCCC_AUTH_STATUS_HELPER="$AUTH_STATUS_HELPER"
      exec_consult_with_signal_defaults "$launcher_python" claude "$CASE_CARD" "$CASE_REPO"
    ) >"$CASE_DIR/publication-signal-output" 2>&1 & wrapper_pid=$!
    if ! wait_for_ready_count "$barrier" 1; then
      : >"$barrier/release"
      terminate_and_reap_pid "$wrapper_pid" || true
      test_diag 'log publisher never reached the pre-commit barrier'
      return 1
    fi
    publisher_pid=$(publication_ready_pid "$barrier") || {
      : >"$barrier/release"
      terminate_and_reap_pid "$wrapper_pid" || true
      test_diag 'cannot identify the pre-commit publisher shim PID'
      return 1
    }
    kill -s "$signal" "$wrapper_pid" || {
      : >"$barrier/release"
      terminate_and_reap_pid "$wrapper_pid" || true
      return 1
    }
    attempts=250
    while kill -0 "$wrapper_pid" 2>/dev/null && [ "$attempts" -gt 0 ]; do
      sleep 0.02
      attempts=$((attempts - 1))
    done
    if kill -0 "$wrapper_pid" 2>/dev/null; then
      : >"$barrier/release"
      terminate_and_reap_pid "$wrapper_pid" || true
      test_diag "pre-commit publication $signal did not terminate the publisher tree"
      return 1
    fi
    if wait "$wrapper_pid"; then rc=0; else rc=$?; fi
    assert_publication_helper_gone "$publisher_pid" "$barrier" "pre-commit publication $signal" || return 1
    assert_eq "$expected" "$rc" "pre-commit publication $signal status" || return 1
    [ ! -e "$(log_path claude "$CASE_CARD")" ] || return 1
    [ ! -e "$(opinion_path claude "$CASE_CARD")" ] || return 1
    common=$(git -C "$CASE_REPO" rev-parse --path-format=absolute --git-common-dir) || return 1
    lock="$common/cccc-v2.lock"
    [ ! -e "$lock" ] || return 1
    CCCC_REAL_PYTHON="$real_python" run_consult claude
    assert_success_outputs claude || return 1
  done
}

test_signal_after_publication_commit_reports_partial_outputs() {
  local real_python launcher_python phase barrier wrapper_pid publisher_pid attempts rc output log log_physical opinion common lock
  require_posix_inode_capability || return 77
  require_consult || return 1
  real_python=$(command -v python3) || return 1
  launcher_python=$real_python
  for phase in after-log after-opinion; do
    prepare_case || return 1
    install_publication_signal_python "$real_python" || return 1
    barrier="$CASE_DIR/publication-signal-barrier"
    mkdir -p "$barrier" || return 1
    output="$CASE_DIR/publication-signal-output"
    log=$(log_path claude "$CASE_CARD")
    log_physical=$(CDPATH= cd -P -- "$(dirname -- "$log")" && printf '%s/%s\n' "$PWD" "${log##*/}") || return 1
    opinion=$(opinion_path claude "$CASE_CARD")
    (
      export PATH="$CASE_BIN:$ORIGINAL_PATH" TMPDIR="$CASE_TMP"
      export CCCC_REAL_PYTHON="$real_python" CCCC_PUBLISH_SIGNAL_BARRIER="$barrier"
      export CCCC_PUBLISH_SIGNAL_PHASE="$phase"
      export CCCC_FAKE_ARGV_FILE="$CASE_ARGV" CCCC_FAKE_ENV_FILE="$CASE_ENV"
      export CCCC_FAKE_CWD_FILE="$CASE_CWD" CCCC_FAKE_PRIVATE_FILE="$CASE_PRIVATE"
      export CCCC_FAKE_CALLS_FILE="$CASE_CALLS" CCCC_FAKE_LAUNCH_FILE="$CASE_LAUNCH"
      export CCCC_FAKE_REPO="$CASE_REPO" CCCC_FAKE_CARD="$CASE_CARD"
      export CCCC_AUTH_STATUS_HELPER="$AUTH_STATUS_HELPER"
      exec_consult_with_signal_defaults "$launcher_python" claude "$CASE_CARD" "$CASE_REPO"
    ) >"$output" 2>&1 & wrapper_pid=$!
    if ! wait_for_ready_count "$barrier" 1; then
      : >"$barrier/release"
      terminate_and_reap_pid "$wrapper_pid" || true
      test_diag "$phase publisher never reached its post-commit barrier"
      return 1
    fi
    publisher_pid=$(publication_ready_pid "$barrier") || {
      : >"$barrier/release"
      terminate_and_reap_pid "$wrapper_pid" || true
      test_diag "cannot identify the $phase publisher shim PID"
      return 1
    }
    [ -s "$log" ] || {
      : >"$barrier/release"
      terminate_and_reap_pid "$wrapper_pid" || true
      test_diag "$phase did not commit the log before its barrier"
      return 1
    }
    if [ "$phase" = after-log ]; then
      [ ! -e "$opinion" ] || {
        : >"$barrier/release"
        terminate_and_reap_pid "$wrapper_pid" || true
        return 1
      }
    else
      [ -s "$opinion" ] || {
        : >"$barrier/release"
        terminate_and_reap_pid "$wrapper_pid" || true
        test_diag 'opinion was not committed before the after-opinion barrier'
        return 1
      }
    fi
    kill -HUP "$wrapper_pid" || {
      : >"$barrier/release"
      terminate_and_reap_pid "$wrapper_pid" || true
      return 1
    }
    attempts=250
    while kill -0 "$wrapper_pid" 2>/dev/null && [ "$attempts" -gt 0 ]; do
      sleep 0.02
      attempts=$((attempts - 1))
    done
    if kill -0 "$wrapper_pid" 2>/dev/null; then
      : >"$barrier/release"
      terminate_and_reap_pid "$wrapper_pid" || true
      test_diag "$phase publication signal exceeded bounded wait"
      return 1
    fi
    if wait "$wrapper_pid"; then rc=0; else rc=$?; fi
    assert_publication_helper_gone "$publisher_pid" "$barrier" "$phase publication" || return 1
    assert_eq 129 "$rc" "$phase publication HUP status" || return 1
    case "$(cat "$output")" in
      *"$log_physical"*manual*cleanup*|*manual*cleanup*"$log_physical"*) ;;
      *) test_diag "$phase lacks an exact manual-cleanup diagnostic: $(cat "$output")"; return 1 ;;
    esac
    case "$(cat "$output")" in *'cccc: consult opinion:'*|*'cccc: consult log:'*) return 1 ;; esac
    [ -s "$log" ] || return 1
    if [ "$phase" = after-log ]; then [ ! -e "$opinion" ] || return 1; else [ -s "$opinion" ] || return 1; fi
    common=$(git -C "$CASE_REPO" rev-parse --path-format=absolute --git-common-dir) || return 1
    lock="$common/cccc-v2.lock"
    [ ! -e "$lock" ] || return 1
  done
}

test_signal_before_success_reporting_has_no_partial_success_lines() {
  local injected script_dir real_python launcher_python wrapper_pid attempts rc output log opinion common lock
  require_posix_inode_capability || return 77
  require_consult || return 1
  prepare_case || return 1
  injected="$CASE_DIR/consult-success-window.sh"
  script_dir=$(dirname -- "$CONSULT")
  real_python=$(command -v python3) || return 1
  launcher_python=$real_python
  python3 -I - "$CONSULT" "$injected" "$script_dir" <<'PY'
import shlex
import sys

source_path, output_path, script_dir = sys.argv[1:]
source = open(source_path, encoding="utf-8").read()
script_line = 'SCRIPT_DIR=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 127'
if script_line not in source:
    raise SystemExit("consult SCRIPT_DIR line changed")
source = source.replace(script_line, "SCRIPT_DIR=" + shlex.quote(script_dir), 1)
needle = """  trap '' HUP INT TERM
  printf 'cccc: consult opinion: %s\\ncccc: consult log: %s\\n' \\
    \"$opinion_destination\" \"$log_destination\"
"""
if needle not in source:
    raise SystemExit("consult success reporting is not one signal-atomic printf")
injection = """  printf 'fired\\n' >\"$CCCC_SUCCESS_WINDOW_MARKER\"
  kill -HUP \"$$\"
  sleep 0.2
"""
with open(output_path, "x", encoding="utf-8") as stream:
    stream.write(source.replace(needle, injection + needle, 1))
PY
  [ "$?" -eq 0 ] || return 1
  chmod +x "$injected" || return 1
  output="$CASE_DIR/success-window-output"
  log=$(log_path claude "$CASE_CARD")
  opinion=$(opinion_path claude "$CASE_CARD")
  (
    export PATH="$CASE_BIN:$ORIGINAL_PATH" TMPDIR="$CASE_TMP"
    export CCCC_SUCCESS_WINDOW_MARKER="$CASE_DIR/success-window-fired"
    export CCCC_FAKE_ARGV_FILE="$CASE_ARGV" CCCC_FAKE_ENV_FILE="$CASE_ENV"
    export CCCC_FAKE_CWD_FILE="$CASE_CWD" CCCC_FAKE_PRIVATE_FILE="$CASE_PRIVATE"
    export CCCC_FAKE_CALLS_FILE="$CASE_CALLS" CCCC_FAKE_LAUNCH_FILE="$CASE_LAUNCH"
    export CCCC_FAKE_REPO="$CASE_REPO" CCCC_FAKE_CARD="$CASE_CARD"
    export CCCC_AUTH_STATUS_HELPER="$AUTH_STATUS_HELPER"
    CONSULT="$injected" exec_consult_with_signal_defaults \
      "$launcher_python" claude "$CASE_CARD" "$CASE_REPO"
  ) >"$output" 2>&1 & wrapper_pid=$!
  attempts=500
  while kill -0 "$wrapper_pid" 2>/dev/null && [ "$attempts" -gt 0 ]; do
    sleep 0.02
    attempts=$((attempts - 1))
  done
  if kill -0 "$wrapper_pid" 2>/dev/null; then
    terminate_and_reap_pid "$wrapper_pid" || true
    test_diag 'pre-success signal invocation exceeded bounded wait'
    return 1
  fi
  if wait "$wrapper_pid"; then rc=0; else rc=$?; fi
  [ -s "$CASE_DIR/success-window-fired" ] || return 1
  assert_eq 129 "$rc" 'pre-success reporting HUP status' || return 1
  [ -s "$log" ] && [ -s "$opinion" ] || return 1
  case "$(cat "$output")" in *'cccc: consult opinion:'*|*'cccc: consult log:'*)
    test_diag 'pre-success signal emitted a partial success line'
    return 1
  esac
  case "$(cat "$output")" in *manual*cleanup*|*manual*cleanup*verification*) ;;
    *) test_diag 'pre-success signal lacks committed-output recovery guidance'; return 1 ;;
  esac
  common=$(git -C "$CASE_REPO" rev-parse --path-format=absolute --git-common-dir) || return 1
  lock="$common/cccc-v2.lock"
  [ ! -e "$lock" ]
}

test_publication_binds_source_digest_parent_identity_and_orders_log_first() {
  local real_python kind attacked destination marker target victim
  require_posix_inode_capability || return 77
  real_python=$(command -v python3) || return 1

  prepare_case || return 1
  install_publication_attack_python "$real_python" || return 1
  marker="$CASE_DIR/publish-marker"
  CCCC_REAL_PYTHON="$real_python" CCCC_PUBLISH_ATTACK_MARKER="$marker" \
    CCCC_PUBLISH_ATTACK_MODE=fail-opinion run_consult claude
  assert_eq 5 "$CASE_RC" 'partial opinion publication status' || return 1
  [ -s "$(log_path claude "$CASE_CARD")" ] || { test_diag 'orphan diagnostic log was not published first'; return 1; }
  [ ! -e "$(opinion_path claude "$CASE_CARD")" ] || return 1
  case "$CASE_OUTPUT" in *manual*cleanup*|*人工*清理*) ;; *) test_diag 'partial publication lacks manual cleanup diagnostic'; return 1 ;; esac

  for kind in consult.log opinion.md; do
    prepare_case || return 1
    install_publication_attack_python "$real_python" || return 1
    marker="$CASE_DIR/publish-marker"
    printf 'forged publication payload\n' >"$CASE_DIR/publication-source-victim"
    CCCC_REAL_PYTHON="$real_python" CCCC_PUBLISH_ATTACK_MODE=path-replace \
      CCCC_PUBLISH_SOURCE_KIND="$kind" CCCC_PUBLISH_ATTACK_MARKER="$marker" \
      CCCC_PUBLISH_ATTACK_PATH="$CASE_DIR/publication-source-path" \
      CCCC_PUBLISH_ATTACK_ORIGINAL="$CASE_DIR/original-$kind" \
      CCCC_PUBLISH_ATTACK_VICTIM="$CASE_DIR/publication-source-victim" run_consult codex
    case "$CASE_RC" in 5|125) ;; *) test_diag "$kind source race returned $CASE_RC"; return 1 ;; esac
    [ -s "$marker" ] || { test_diag "$kind source replacement did not fire"; return 1; }
    attacked=$(cat "$CASE_DIR/publication-source-path") || return 1
    assert_eq 'forged publication payload' "$(cat "$attacked" 2>/dev/null || true)" \
      "$kind replacement victim was cleaned" || return 1
    case "$kind" in
      consult.log) destination=$(log_path codex "$CASE_CARD") ;;
      opinion.md) destination=$(opinion_path codex "$CASE_CARD") ;;
    esac
    [ ! -e "$destination" ] || { test_diag "$kind forged replacement was published"; return 1; }
  done

  for target in claude codex; do
    for kind in consult.log opinion.md; do
      prepare_case || return 1
      install_publication_attack_python "$real_python" || return 1
      marker="$CASE_DIR/publish-marker"
      CCCC_REAL_PYTHON="$real_python" CCCC_PUBLISH_ATTACK_MODE=same-inode \
        CCCC_PUBLISH_SOURCE_KIND="$kind" CCCC_PUBLISH_ATTACK_MARKER="$marker" \
        run_consult "$target"
      [ -s "$marker" ] || {
        test_diag "$target $kind same-inode tamper did not fire"
        return 1
      }
      assert_eq "$kind" "$(cat "$marker")" "$target same-inode source kind" || return 1
      case "$CASE_RC" in
        5|125) ;;
        *) test_diag "$target $kind same-inode source race returned $CASE_RC"; return 1 ;;
      esac
      case "$kind" in
        consult.log) destination=$(log_path "$target" "$CASE_CARD") ;;
        opinion.md) destination=$(opinion_path "$target" "$CASE_CARD") ;;
      esac
      [ ! -e "$destination" ] || {
        test_diag "$target $kind same-inode tamper reached its destination"
        return 1
      }
    done
  done

  prepare_case || return 1
  install_publication_attack_python "$real_python" || return 1
  marker="$CASE_DIR/publish-marker"
  CCCC_REAL_PYTHON="$real_python" CCCC_PUBLISH_ATTACK_MARKER="$marker" \
    CCCC_PUBLISH_ATTACK_MODE=swap-parent run_consult claude
  [ -s "$marker" ] || { test_diag 'parent-swap injection did not fire'; return 1; }
  [ "$CASE_RC" -ne 0 ] || return 1
  victim="$CASE_REPO/docs/discussions/victim"
  assert_eq 'replacement victim' "$(cat "$victim")" 'replacement parent victim changed'
}

test_run_directories_are_private_and_git_operations_are_non_destructive() {
  local real_git git_log forbidden
  prepare_case || return 1
  real_git=$(command -v git) || return 1
  git_log="$CASE_DIR/git.log"
  cat >"$CASE_BIN/git" <<'GIT_SHIM'
#!/usr/bin/env bash
printf '%s\0' "$@" >>"$CCCC_FAKE_GIT_LOG"
printf '\n' >>"$CCCC_FAKE_GIT_LOG"
exec "$CCCC_FAKE_REAL_GIT" "$@"
GIT_SHIM
  chmod +x "$CASE_BIN/git" || return 1
  CCCC_FAKE_GIT_LOG="$git_log" CCCC_FAKE_REAL_GIT="$real_git" run_consult codex
  assert_success_outputs codex || return 1
  if [ "$CONSULT_TEST_WINDOWS" -eq 0 ]; then
    grep -Fxq 'codex_cwd_mode=700' "$CASE_PRIVATE" || return 1
  fi
  for forbidden in commit stash reset checkout clean push; do
    if python3 -I - "$git_log" "$forbidden" <<'PY'
import sys
records = open(sys.argv[1], "rb").read().split(b"\n")
needle = sys.argv[2].encode()
raise SystemExit(0 if any(needle in record.split(b"\0") for record in records) else 1)
PY
    then test_diag "consult invoked forbidden git operation: $forbidden"; return 1; fi
  done
  if find "$CASE_TMP" -mindepth 1 -maxdepth 1 -type d -name 'cccc.*' -print -quit | grep -q .; then
    test_diag 'owned run directory remains after success'
    return 1
  fi
}

test_windows_native_execution_or_explicit_platform_skip() {
  case ${MSYSTEM-}:$(uname -s 2>/dev/null || true) in
    MINGW*:MINGW*|MSYS*:MSYS*|UCRT*:MINGW*) ;;
    *)
      [ "${CCCC_REQUIRE_WINDOWS_NATIVE-}" = 1 ] && {
        test_diag 'Windows native consult coverage was required but Git Bash was not detected'
        return 1
      }
      return 77
      ;;
  esac
  prepare_case || return 1
  run_consult codex
  assert_success_outputs codex
}

REGISTRATION_COUNTS=$(python3 -I - "$0" <<'PY'
import collections
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
definitions = re.findall(r"^(test_[A-Za-z0-9_]+)\(\) \{$", text, re.MULTILINE)
registrations = re.findall(
    r"^run_test '[^']*' (test_[A-Za-z0-9_]+)$", text, re.MULTILINE
)
definition_counts = collections.Counter(definitions)
registration_counts = collections.Counter(registrations)
bad = sorted(
    name
    for name in set(definition_counts) | set(registration_counts)
    if definition_counts[name] != 1 or registration_counts[name] != 1
)
if bad or len(definitions) != len(registrations):
    for name in bad:
        print(
            "registration audit mismatch %s definitions=%d registrations=%d"
            % (name, definition_counts[name], registration_counts[name]),
            file=sys.stderr,
        )
    raise SystemExit(99)
print("%d %d" % (len(definitions), len(registrations)))
PY
) || exit $?
set -- $REGISTRATION_COUNTS
REGISTERED_DEFINITIONS=$1
REGISTERED_INVOCATIONS=$2
printf '# registration audit: definitions=%s registrations=%s\n' \
  "$REGISTERED_DEFINITIONS" "$REGISTERED_INVOCATIONS"

run_test 'canonical entrypoint exists and is hardened' test_canonical_entrypoint_exists_and_is_not_legacy
run_test 'exact arity target and empty workdir validation' test_exact_arity_target_and_empty_workdir_validation
run_test 'card path is strict repo-relative Markdown' test_card_path_is_strictly_repository_relative_markdown
run_test 'Unicode and space card is safely named' test_unicode_and_space_card_is_safe_and_named_by_stem
run_test 'card and ancestors reject symlinks' test_card_and_ancestors_must_be_regular_without_symlinks
run_test 'FIFO card is bounded and rejected' test_fifo_card_is_rejected_without_blocking
run_test 'depth guard is exact and child-scoped' test_depth_guard_is_exact_and_only_child_receives_one
run_test 'write-enabling environment is rejected' test_write_enabling_environment_is_rejected
run_test 'timeout defaults zero and maximum are exact' test_timeout_defaults_to_1800_and_accepts_zero_and_maximum
run_test 'invalid and over-maximum timeouts fail' test_timeout_rejects_invalid_and_over_maximum_values
run_test 'model and effort preserve argv boundaries' test_model_and_effort_are_single_argv_boundaries
run_test 'dirty escape is literal one' test_allow_dirty_is_literal_one_only
run_test 'Codex config mode defaults strict' test_codex_config_mode_defaults_strict_and_rejects_other_values
run_test 'Claude argv is exact and read-only' test_claude_argv_is_exact_and_read_only
run_test 'Claude MCP config is private empty 0600' test_claude_mcp_config_is_private_regular_0600_and_empty
run_test 'Claude cwd is private with absolute repo access' test_claude_runs_from_private_cwd_with_absolute_repo_access
run_test 'Claude project poison cannot start' test_claude_project_poison_cannot_start
run_test 'Codex strict argv and root approval are exact' test_codex_strict_argv_is_exact_and_root_approval_precedes_exec
run_test 'Codex denies every locked feature' test_codex_strict_denies_every_locked_feature
run_test 'Codex preflight order is real' test_codex_preflight_really_runs_help_and_features_before_launch
run_test 'missing Codex flag fails before launch' test_codex_missing_required_flag_fails_closed_before_launch
run_test 'feature-list adversarial matrix fails closed' test_codex_missing_required_feature_fails_closed_before_launch
run_test 'preflight command errors do not launch' test_codex_preflight_command_failures_do_not_launch_agent
run_test 'Codex strict cwd is empty private 0700' test_codex_strict_private_cwd_is_0700_and_not_repo
run_test 'Codex strict excludes poison config' test_codex_strict_does_not_inherit_poison_configuration
run_test 'Codex inherit keeps isolation and warns' test_codex_inherit_keeps_runtime_isolation_but_warns_side_effects
run_test 'prompt states prohibitions and security boundary' test_prompt_states_security_prohibitions_and_wrapper_boundary
run_test 'Codex side-effect and shell configs are fixed' test_codex_strict_fixed_side_effect_controls_and_shell_policy
run_test 'update notify and login-shell probes stay quiet' test_update_notify_and_login_shell_behavior_probes_stay_quiet
run_test 'child env and Python isolation are scoped' test_child_environment_is_scoped_and_python_is_isolated
run_test 'clean run logs Git audit metadata' test_clean_run_logs_git_metadata_and_audit_boundary
run_test 'dirty default rejects and escape warns' test_dirty_default_rejects_and_escape_warns_boundary
run_test 'tracked second change fails policy' test_tracked_second_change_is_policy_failure
run_test 'untracked second change fails policy' test_untracked_second_change_is_policy_failure
run_test 'index-only second change fails policy' test_index_only_second_change_is_policy_failure
run_test 'unchanged dirty baselines are controls' test_unchanged_dirty_tracked_untracked_and_index_baselines_succeed
run_test 'HEAD and card changes fail policy' test_head_and_card_changes_are_policy_failures
run_test 'card ancestor identity swaps fail' test_card_parent_and_docs_ancestor_identity_swaps_fail
run_test 'nested repos and submodules are refused' test_nested_repository_and_submodule_are_refused
run_test 'unborn repo requires dirty escape' test_unborn_repository_requires_dirty_escape
run_test 'newline path diagnostics are safe' test_newline_paths_are_diagnostic_safe
run_test 'natural reserved child statuses map to 70' test_natural_reserved_child_statuses_map_to_agent_failure
run_test 'real timeout and launch failure map exactly' test_real_timeout_and_launch_failure_map_exactly
run_test 'runner status HMAC namespace matrix fails closed' test_runner_status_hmac_namespace_and_rc_mismatches_fail_closed
run_test 'authenticated status main and signal are bound' test_authenticated_runner_status_main_and_signal_paths_are_manifest_bound
run_test 'runner PID registration signal window retries' test_runner_pid_registration_signal_window_is_retryable
run_test 'signals clean descendants outputs and lock' test_signals_cleanup_descendants_outputs_lock_and_allow_retry
run_test 'same-repo consult locks all cards and targets' test_repo_lock_blocks_same_and_different_consult_cards_and_targets
run_test 'delegate and consult share lock both ways' test_delegate_and_consult_share_the_lock_in_both_directions
run_test 'linked worktrees share physical lock' test_linked_worktrees_share_the_physical_common_dir_lock
run_test 'different repositories run concurrently' test_different_repositories_can_consult_concurrently
run_test 'stale symlink FIFO outputs never clobber' test_stale_symlink_fifo_outputs_are_bounded_and_never_clobbered
run_test 'target outputs and dirty gate preserve first' test_target_outputs_do_not_conflict_and_second_run_obeys_dirty_gate
run_test 'publication binds source parent and order' test_publication_binds_source_digest_parent_identity_and_orders_log_first
run_test 'pre-commit publication signal leaves no output' test_signal_before_log_publication_commits_no_output
run_test 'post-commit publication signal reports partial outputs' test_signal_after_publication_commit_reports_partial_outputs
run_test 'pre-success signal emits no partial success' test_signal_before_success_reporting_has_no_partial_success_lines
run_test 'run dirs private and Git non-destructive' test_run_directories_are_private_and_git_operations_are_non_destructive
run_test 'Windows native execution or explicit skip' test_windows_native_execution_or_explicit_platform_skip

finish_tests
