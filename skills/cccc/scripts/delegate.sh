#!/usr/bin/env bash
# Execute one cccc task card through Claude Code or Codex with Git-visible policy enforcement.
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 127
# shellcheck source=skills/cccc/scripts/cccc-common.sh
. "$SCRIPT_DIR/cccc-common.sh" || exit 127

OWNED_RUN_DIR=
OWNED_LOCK_PATH=
OWNED_LOCK_OWNER=
OWNED_LOCK_ID=
RUNNER_PID=
RUNNER_STATUS_PATH=

cccc_delegate_release_lock() {
  [ -n "$OWNED_LOCK_ID" ] || return 0
  [ -n "${CCCC_PYTHON-}" ] || return 1
  "$CCCC_PYTHON" -I - "$OWNED_LOCK_PATH" "$OWNED_LOCK_OWNER" "$OWNED_LOCK_ID" <<'PY' 2>/dev/null || return 1
import os
import stat
import sys

lock_path, owner_path, expected = sys.argv[1:]
try:
    expected_dev, expected_ino = (int(item) for item in expected.split(":", 1))
except (TypeError, ValueError):
    raise SystemExit(1)

def identity(path):
    try:
        value = os.lstat(path)
    except OSError:
        return None
    if stat.S_ISLNK(value.st_mode) or not stat.S_ISREG(value.st_mode):
        return None
    return value.st_dev, value.st_ino

failed = False
if lock_path:
    if identity(lock_path) != (expected_dev, expected_ino):
        failed = True
    else:
        try:
            os.unlink(lock_path)
        except OSError:
            failed = True
if identity(owner_path) != (expected_dev, expected_ino):
    failed = True
else:
    try:
        os.unlink(owner_path)
    except OSError:
        failed = True
raise SystemExit(1 if failed else 0)
PY
  OWNED_LOCK_PATH=
  OWNED_LOCK_OWNER=
  OWNED_LOCK_ID=
  return 0
}

cccc_delegate_remove_run_dir() {
  if [ -n "$OWNED_RUN_DIR" ] && [ -d "$OWNED_RUN_DIR" ]; then
    rm -rf -- "$OWNED_RUN_DIR" || return 1
  fi
  OWNED_RUN_DIR=
  return 0
}

cccc_delegate_cleanup() {
  local original_status=$1 cleanup_failed=0
  trap - EXIT
  cccc_delegate_release_lock || cleanup_failed=1
  cccc_delegate_remove_run_dir || cleanup_failed=1
  if [ "$cleanup_failed" -ne 0 ]; then
    cccc_die 'delegated execution cleanup failed'
    exit 125
  fi
  exit "$original_status"
}

cccc_delegate_on_signal() {
  local number=$1 name=$2 runner_rc=0 status_rc=125 had_runner=0
  trap - HUP INT TERM
  if [ -n "$RUNNER_PID" ] && kill -0 "$RUNNER_PID" 2>/dev/null; then
    had_runner=1
    kill -s "$name" "$RUNNER_PID" 2>/dev/null || true
    wait "$RUNNER_PID" 2>/dev/null || runner_rc=$?
    if [ -n "$RUNNER_STATUS_PATH" ]; then
      cccc_delegate_parse_runner_status "$RUNNER_STATUS_PATH" "$runner_rc" >/dev/null 2>&1
      status_rc=$?
    fi
  fi
  RUNNER_PID=
  if [ "$had_runner" -eq 1 ] && [ "$status_rc" -ne 0 ]; then
    exit 125
  fi
  if [ "$status_rc" -eq 0 ]; then
    case "$CCCC_RUNNER_KIND" in
      cleanup-failure|runner-internal) exit 125 ;;
    esac
  fi
  exit $((128 + number))
}

trap 'cccc_delegate_cleanup $?' EXIT
trap 'cccc_delegate_on_signal 1 HUP' HUP
trap 'cccc_delegate_on_signal 2 INT' INT
trap 'cccc_delegate_on_signal 15 TERM' TERM

cccc_delegate_usage() {
  cccc_die 'usage: delegate.sh <claude|codex> <docs/tasks/card.md> [workdir]'
}

cccc_delegate_environment() {
  if [ "${CCCC_MODE+x}" = x ]; then
    CCCC_DELEGATE_MODE=$CCCC_MODE
  elif [ "${DELEGATE_SANDBOX+x}" = x ]; then
    cccc_warn 'DELEGATE_SANDBOX is deprecated; use CCCC_MODE'
    CCCC_DELEGATE_MODE=$DELEGATE_SANDBOX
  else
    CCCC_DELEGATE_MODE=auto
  fi

  if [ "${CCCC_TIMEOUT+x}" = x ]; then
    CCCC_DELEGATE_TIMEOUT=$CCCC_TIMEOUT
  elif [ "${DELEGATE_TIMEOUT+x}" = x ]; then
    cccc_warn 'DELEGATE_TIMEOUT is deprecated; use CCCC_TIMEOUT'
    CCCC_DELEGATE_TIMEOUT=$DELEGATE_TIMEOUT
  else
    CCCC_DELEGATE_TIMEOUT=3600
  fi

  if [ "${CCCC_MODEL+x}" = x ]; then
    CCCC_DELEGATE_MODEL=$CCCC_MODEL
  elif [ "${DELEGATE_MODEL+x}" = x ]; then
    cccc_warn 'DELEGATE_MODEL is deprecated; use CCCC_MODEL'
    CCCC_DELEGATE_MODEL=$DELEGATE_MODEL
  else
    CCCC_DELEGATE_MODEL=
  fi

  case "$CCCC_DELEGATE_MODE" in
    edit|auto|full) ;;
    *) cccc_die 'CCCC_MODE must be exactly edit, auto, or full'; return 2 ;;
  esac
  cccc_validate_timeout "$CCCC_DELEGATE_TIMEOUT" || return 2
  case ${CCCC_ALLOW_FULL-} in
    ''|1) ;;
    *) cccc_die 'CCCC_ALLOW_FULL must be unset, empty, or exactly 1'; return 2 ;;
  esac
  case ${CCCC_ALLOW_DIRTY-} in
    ''|1) ;;
    *) cccc_die 'CCCC_ALLOW_DIRTY must be unset, empty, or exactly 1'; return 2 ;;
  esac
  if [ "$CCCC_DELEGATE_MODE" = full ] && [ "${CCCC_ALLOW_FULL-}" != 1 ]; then
    cccc_die 'full mode requires explicit CCCC_ALLOW_FULL=1'
    return 2
  fi
  return 0
}

cccc_delegate_validate_depth() {
  local depth=${DELEGATE_DEPTH-}
  case "$depth" in
    ''|0) return 0 ;;
    *[!0-9]*|00*)
      cccc_die 'DELEGATE_DEPTH must be an unset or canonical decimal integer'
      return 2
      ;;
    *)
      cccc_die "nested delegation is forbidden (DELEGATE_DEPTH=$depth)"
      return 3
      ;;
  esac
}

cccc_delegate_validate_effort() {
  local target=$1 effort=${CCCC_EFFORT-}
  [ -n "$effort" ] || return 0
  case "$target:$effort" in
    claude:low|claude:medium|claude:high|claude:xhigh|claude:max) return 0 ;;
    codex:minimal|codex:low|codex:medium|codex:high|codex:xhigh) return 0 ;;
  esac
  cccc_die "invalid CCCC_EFFORT for $target: $effort"
  return 2
}

cccc_delegate_reject_git_redirects() {
  if [ -n "${GIT_DIR-}" ] || [ -n "${GIT_WORK_TREE-}" ] ||
    [ -n "${GIT_INDEX_FILE-}" ] || [ -n "${GIT_COMMON_DIR-}" ] ||
    [ -n "${GIT_OBJECT_DIRECTORY-}" ]; then
    cccc_die 'Git redirect environment variables are forbidden for delegated execution'
    return 2
  fi
  return 0
}

cccc_delegate_validate_timeout_max() {
  local helper=$1 maximum
  maximum=$("$CCCC_PYTHON" -I -c \
    'import runpy, sys; print(runpy.run_path(sys.argv[1])["MAX_TIMEOUT_SECONDS"])' \
    "$helper" 2>/dev/null) || {
      cccc_die 'cannot read the timeout helper safe maximum'
      return 127
    }
  case "$maximum" in
    [1-9]|[1-9][0-9]*) ;;
    *) cccc_die 'timeout helper returned an invalid safe maximum'; return 127 ;;
  esac
  if [ "${#CCCC_DELEGATE_TIMEOUT}" -gt "${#maximum}" ] || {
    [ "${#CCCC_DELEGATE_TIMEOUT}" -eq "${#maximum}" ] &&
      [ "$CCCC_DELEGATE_TIMEOUT" \> "$maximum" ]
  }; then
    cccc_die "timeout must be no greater than $maximum"
    return 2
  fi
  return 0
}

cccc_delegate_resolve_common_dir() {
  local raw candidate physical
  CCCC_DELEGATE_COMMON_DIR=
  raw=$(git -C "$CCCC_REPO_ROOT" rev-parse --git-common-dir 2>/dev/null) || {
    cccc_die 'cannot resolve Git common-dir'
    return 4
  }
  case "$raw" in
    /*) candidate=$raw ;;
    *) candidate="$CCCC_REPO_ROOT/$raw" ;;
  esac
  physical=$(CDPATH= cd -P -- "$candidate" 2>/dev/null && pwd) || {
    cccc_die 'cannot resolve physical Git common-dir'
    return 4
  }
  CCCC_DELEGATE_COMMON_DIR=$physical
  return 0
}

cccc_delegate_file_identity() {
  "$CCCC_PYTHON" -I - "$1" <<'PY'
import os
import stat
import sys

value = os.lstat(sys.argv[1])
if stat.S_ISLNK(value.st_mode) or not stat.S_ISREG(value.st_mode):
    raise SystemExit(5)
print("%d:%d" % (value.st_dev, value.st_ino))
PY
}

cccc_delegate_acquire_repo_lock() {
  local common=$1 owner lock owner_id lock_id
  owner=$(umask 077 && mktemp "$common/.cccc-delegate-owner.XXXXXXXX") || {
    cccc_die 'cannot create repo-lock ownership file'
    return 5
  }
  chmod 600 "$owner" || { unlink "$owner" 2>/dev/null || true; return 5; }
  owner_id=$(cccc_delegate_file_identity "$owner") || {
    unlink "$owner" 2>/dev/null || true
    cccc_die 'cannot verify repo-lock ownership file'
    return 5
  }
  lock="$common/cccc-v2.lock"
  OWNED_LOCK_OWNER=$owner
  OWNED_LOCK_ID=$owner_id
  OWNED_LOCK_PATH=$lock
  if ! ln -- "$owner" "$lock" 2>/dev/null; then
    OWNED_LOCK_PATH=
    cccc_die 'repository already has an active cccc execution lock'
    cccc_delegate_release_lock
    return 5
  fi
  lock_id=$(cccc_delegate_file_identity "$lock") || {
    cccc_die 'cannot verify acquired cccc execution lock'
    cccc_delegate_release_lock
    return 5
  }
  if [ "$lock_id" != "$owner_id" ]; then
    cccc_die 'cccc execution lock ownership proof failed'
    cccc_delegate_release_lock
    return 5
  fi
  return 0
}

cccc_delegate_policy_excludes_card() {
  if cccc_path_allowed "$CCCC_CARD_REL"; then
    cccc_die 'allowed paths must not cover the task card or any card ancestor'
    return 2
  fi
  return 0
}

cccc_delegate_capture_card_identity() {
  local repo=$1 relative=$2 output=$3
  "$CCCC_PYTHON" -I - "$repo" "$relative" "$output" <<'PY'
import hashlib
import os
import stat
import sys

root, relative, output = sys.argv[1:]
parts = relative.split("/")
if not parts or any(not part or part in (".", "..") for part in parts):
    raise SystemExit(5)
records = []
root_stat = os.lstat(root)
if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
    raise SystemExit(5)
records.append((b"", root_stat))
current = root
for index, part in enumerate(parts):
    current = os.path.join(current, part)
    value = os.lstat(current)
    if stat.S_ISLNK(value.st_mode):
        raise SystemExit(5)
    if index == len(parts) - 1:
        if not stat.S_ISREG(value.st_mode):
            raise SystemExit(5)
    elif not stat.S_ISDIR(value.st_mode):
        raise SystemExit(5)
    records.append((os.fsencode("/".join(parts[: index + 1])), value))

flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
descriptor = os.open(current, flags)
try:
    opened = os.fstat(descriptor)
    final = records[-1][1]
    if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (final.st_dev, final.st_ino):
        raise SystemExit(5)
    digest = hashlib.sha256()
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
finally:
    os.close(descriptor)

with open(output, "xb") as stream:
    for path, value in records:
        stream.write(path.hex().encode("ascii"))
        stream.write(("\t%d\t%d\t%d\n" % (value.st_dev, value.st_ino, value.st_mode)).encode("ascii"))
    stream.write(b"sha256\t" + digest.hexdigest().encode("ascii") + b"\n")
PY
}

cccc_delegate_path_hex() {
  "$CCCC_PYTHON" -I -c 'import os,sys; print(os.fsencode(sys.argv[1]).hex())' "$1"
}

cccc_delegate_hash_file() {
  "$CCCC_PYTHON" -I -c \
    'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' \
    "$1"
}

cccc_delegate_parse_runner_status() {
  local status=$1 runner_rc=$2 parsed value
  CCCC_RUNNER_KIND=
  CCCC_RUNNER_VALUE=
  parsed=$("$CCCC_PYTHON" -I - "$status" "$runner_rc" <<'PY'
import os
import stat
import sys

path, runner_text = sys.argv[1:]
try:
    runner_rc = int(runner_text)
except ValueError:
    raise SystemExit(1)
try:
    before = os.lstat(path)
except OSError:
    raise SystemExit(1)
if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
    raise SystemExit(1)
if stat.S_IMODE(before.st_mode) != 0o600:
    raise SystemExit(1)
if hasattr(os, "geteuid") and before.st_uid != os.geteuid():
    raise SystemExit(1)
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
descriptor = None
try:
    descriptor = os.open(path, flags)
    opened = os.fstat(descriptor)
    if not stat.S_ISREG(opened.st_mode):
        raise OSError("not regular")
    if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
        raise OSError("identity changed")
    data = os.read(descriptor, 4097)
    if os.read(descriptor, 1):
        raise OSError("status too large")
except OSError:
    raise SystemExit(1)
finally:
    if descriptor is not None:
        os.close(descriptor)
if not data.endswith(b"\n") or data.count(b"\n") != 1:
    raise SystemExit(1)
try:
    line = data[:-1].decode("ascii")
except UnicodeDecodeError:
    raise SystemExit(1)
prefix = "cccc-timeout-result-v1 kind="
if not line.startswith(prefix) or " value=" not in line:
    raise SystemExit(1)
kind, value = line[len(prefix):].split(" value=", 1)
numeric = {"child-exit", "child-signal", "runner-signal"}
none_kinds = {
    "launch-failure", "wrapper-timeout", "cleanup-failure",
    "runner-internal", "argument-validation",
}
if kind in numeric:
    if not value.isascii() or not value.isdecimal() or str(int(value)) != value:
        raise SystemExit(1)
    number = int(value)
    if kind == "child-exit":
        if number > 255 or runner_rc != number:
            raise SystemExit(1)
    elif not 1 <= number <= 127 or runner_rc != 128 + number:
        raise SystemExit(1)
elif kind in none_kinds:
    if value != "none":
        raise SystemExit(1)
    expected = {
        "launch-failure": 127,
        "wrapper-timeout": 124,
        "cleanup-failure": 125,
        "runner-internal": 125,
        "argument-validation": 2,
    }[kind]
    if runner_rc != expected:
        raise SystemExit(1)
else:
    raise SystemExit(1)
print(kind + "\t" + value)
PY
  ) || {
    cccc_die 'trusted runner status is missing, unsafe, malformed, or inconsistent'
    return 125
  }
  CCCC_RUNNER_KIND=${parsed%%$'\t'*}
  value=${parsed#*$'\t'}
  CCCC_RUNNER_VALUE=$value
  return 0
}

cccc_delegate_write_log() {
  local destination=$1 target=$2 mode=$3 timeout=$4 agent_rc=$5
  local head_before=$6 head_after=$7 status_before=$8 status_after=$9
  local changed_file=${10} agent_stdout=${11} agent_stderr=${12}
  local path hex
  {
    printf '%s\n' 'cccc delegate v2'
    printf 'target=%s\n' "$target"
    printf 'mode=%s\n' "$mode"
    printf 'timeout=%s\n' "$timeout"
    printf 'agent_rc=%s\n' "$agent_rc"
    printf 'runner_kind=%s\n' "$CCCC_RUNNER_KIND"
    printf 'head_before=%s\n' "$head_before"
    printf 'head_after=%s\n' "$head_after"
    printf 'status_before_sha256=%s\n' "$(cccc_delegate_hash_file "$status_before")"
    printf 'status_after_sha256=%s\n' "$(cccc_delegate_hash_file "$status_after")"
    while IFS= read -r -d '' path; do
      hex=$(cccc_delegate_path_hex "$path") || return 1
      printf 'changed_path_hex=%s\n' "$hex"
    done <"$changed_file"
    printf '%s\n' '=== agent stdout ==='
    cat -- "$agent_stdout"
    printf '%s\n' '=== agent stderr ==='
    cat -- "$agent_stderr"
  } >"$destination"
}

cccc_delegate_main() {
  local target card workdir depth_rc environment_rc timeout_rc
  local card_rel card_abs report_destination log_destination
  local report_parent_identity log_parent_identity timeout_helper
  local dirty_status head_before head_after
  local snapshot_before snapshot_after status_before status_after changed_file
  local card_identity_before card_identity_after
  local report_source log_source agent_stdout agent_stderr runner_status
  local prompt runner_rc status_rc agent_rc policy_failed path path_hex
  local publication_rc
  local agent_argv=()
  local command_argv=()

  if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    cccc_delegate_usage
    return 2
  fi
  target=$1
  card=$2
  if [ "$#" -eq 3 ]; then
    [ -n "$3" ] || { cccc_die 'workdir must not be empty'; return 2; }
    workdir=$3
  else
    workdir=.
  fi

  cccc_delegate_validate_depth
  depth_rc=$?
  [ "$depth_rc" -eq 0 ] || return "$depth_rc"
  cccc_delegate_environment
  environment_rc=$?
  [ "$environment_rc" -eq 0 ] || return "$environment_rc"
  case "$target" in claude|codex) ;; *) cccc_die 'target must be exactly claude or codex'; return 2 ;; esac
  cccc_delegate_validate_effort "$target" || return 2
  cccc_delegate_reject_git_redirects || return 2

  cccc_require_command git || return 127
  cccc_find_python3 || return 127
  timeout_helper="$SCRIPT_DIR/run-with-timeout.py"
  if [ ! -f "$timeout_helper" ] || [ -L "$timeout_helper" ]; then
    cccc_die 'portable timeout helper is missing or unsafe'
    return 127
  fi
  cccc_delegate_validate_timeout_max "$timeout_helper"
  timeout_rc=$?
  [ "$timeout_rc" -eq 0 ] || return "$timeout_rc"

  cccc_resolve_repo "$workdir" || return 4
  cccc_validate_card "$card" docs/tasks || return 2
  cccc_parse_allowed_paths "$CCCC_CARD_ABS" || return 2
  cccc_delegate_policy_excludes_card || return 2
  card_rel=$CCCC_CARD_REL
  card_abs=$CCCC_CARD_ABS
  report_destination=${card_abs%.md}-report.md
  log_destination=${card_abs%.md}.log
  cccc_refuse_output_target "$report_destination" || return 5
  cccc_refuse_output_target "$log_destination" || return 5

  cccc_make_run_dir || return 5
  OWNED_RUN_DIR=$CCCC_RUN_DIR
  cccc_delegate_resolve_common_dir || return 4
  cccc_delegate_acquire_repo_lock "$CCCC_DELEGATE_COMMON_DIR" || return 5

  cccc_resolve_target_argv "$target" || return 127
  cccc_capture_destination_parent_identity "$report_destination" || return 5
  report_parent_identity=$CCCC_DESTINATION_PARENT_IDENTITY
  cccc_capture_destination_parent_identity "$log_destination" || return 5
  log_parent_identity=$CCCC_DESTINATION_PARENT_IDENTITY

  snapshot_before="$OWNED_RUN_DIR/snapshot.before"
  snapshot_after="$OWNED_RUN_DIR/snapshot.after"
  status_before="$OWNED_RUN_DIR/status.before"
  status_after="$OWNED_RUN_DIR/status.after"
  changed_file="$OWNED_RUN_DIR/changed.z"
  card_identity_before="$OWNED_RUN_DIR/card.before"
  card_identity_after="$OWNED_RUN_DIR/card.after"
  report_source="$OWNED_RUN_DIR/report.md"
  log_source="$OWNED_RUN_DIR/delegate.log"
  agent_stdout="$OWNED_RUN_DIR/agent.stdout"
  agent_stderr="$OWNED_RUN_DIR/agent.stderr"
  runner_status="$OWNED_RUN_DIR/runner.status"
  RUNNER_STATUS_PATH=$runner_status
  : >"$agent_stdout"
  : >"$agent_stderr"

  dirty_status=$(git -C "$CCCC_REPO_ROOT" status --porcelain=v1 --untracked-files=all --ignored=no) || {
    cccc_die 'cannot inspect Git worktree status'
    return 4
  }
  if [ -n "$dirty_status" ]; then
    if [ "${CCCC_ALLOW_DIRTY-}" != 1 ]; then
      cccc_die 'Git worktree is dirty; set CCCC_ALLOW_DIRTY=1 only as an explicit escape hatch'
      return 4
    fi
    cccc_warn 'WARNING: dirty baseline admitted by CCCC_ALLOW_DIRTY=1; already-dirty paths will be fingerprinted for second changes'
  fi

  head_before=$(cccc_git_head "$CCCC_REPO_ROOT") || return 4
  cccc_git_snapshot "$CCCC_REPO_ROOT" "$snapshot_before" || return 4
  cccc_git_status_z "$CCCC_REPO_ROOT" "$status_before" || return 4
  cccc_delegate_capture_card_identity "$CCCC_REPO_ROOT" "$card_rel" "$card_identity_before" || return 4

  prompt="You are the cccc delegated agent. Read $card_rel and execute it exactly. Modify only the machine-readable cccc-allowed-paths boundary. Do not invoke another Claude or Codex agent. Do not commit, stash, reset, checkout, clean, or push Git state. Your final response must be a self-contained Markdown report with the change summary, verification evidence, and known issues."
  if [ "$target" = claude ]; then
    agent_argv=(-p "$prompt" --output-format text)
    case "$CCCC_DELEGATE_MODE" in
      edit) agent_argv+=(--permission-mode acceptEdits) ;;
      auto) agent_argv+=(--permission-mode auto) ;;
      full) agent_argv+=(--dangerously-skip-permissions) ;;
    esac
    [ -z "$CCCC_DELEGATE_MODEL" ] || agent_argv+=(--model "$CCCC_DELEGATE_MODEL")
    [ -z "${CCCC_EFFORT-}" ] || agent_argv+=(--effort "$CCCC_EFFORT")
  else
    agent_argv=(exec --output-last-message "$report_source")
    case "$CCCC_DELEGATE_MODE" in
      edit) agent_argv+=(--sandbox workspace-write -c sandbox_workspace_write.network_access=false) ;;
      auto) agent_argv+=(--sandbox workspace-write --approve-for-me -c sandbox_workspace_write.network_access=true) ;;
      full) agent_argv+=(--dangerously-bypass-approvals-and-sandbox) ;;
    esac
    [ -z "$CCCC_DELEGATE_MODEL" ] || agent_argv+=(--model "$CCCC_DELEGATE_MODEL")
    [ -z "${CCCC_EFFORT-}" ] || agent_argv+=(-c "model_reasoning_effort=$CCCC_EFFORT")
    agent_argv+=("$prompt")
  fi
  command_argv=("$CCCC_PYTHON" -I "$timeout_helper" --status-file "$runner_status" "$CCCC_DELEGATE_TIMEOUT" --)
  command_argv+=("${CCCC_TARGET_ARGV[@]}")
  command_argv+=("${agent_argv[@]}")

  runner_rc=0
  if [ "$target" = claude ]; then
    (
      cd "$CCCC_REPO_ROOT" || exit 127
      unset BASH_ENV ENV
      DELEGATE_DEPTH=1 exec "${command_argv[@]}"
    ) >"$report_source" 2>"$agent_stderr" &
  else
    (
      cd "$CCCC_REPO_ROOT" || exit 127
      unset BASH_ENV ENV
      DELEGATE_DEPTH=1 exec "${command_argv[@]}"
    ) >"$agent_stdout" 2>"$agent_stderr" &
  fi
  RUNNER_PID=$!
  wait "$RUNNER_PID" || runner_rc=$?
  RUNNER_PID=

  cccc_delegate_parse_runner_status "$runner_status" "$runner_rc"
  status_rc=$?
  if [ "$status_rc" -ne 0 ]; then
    CCCC_RUNNER_KIND=invalid
    CCCC_RUNNER_VALUE=none
  fi
  case "$CCCC_RUNNER_KIND" in
    child-exit) agent_rc=$CCCC_RUNNER_VALUE ;;
    child-signal) agent_rc="signal-$CCCC_RUNNER_VALUE" ;;
    *) agent_rc=$runner_rc ;;
  esac

  policy_failed=0
  if ! cccc_validate_card "$card_rel" docs/tasks; then
    cccc_die 'task card or one of its ancestors changed physical identity'
    policy_failed=1
  elif ! cccc_delegate_capture_card_identity "$CCCC_REPO_ROOT" "$card_rel" "$card_identity_after"; then
    cccc_die 'cannot revalidate task card identity'
    policy_failed=1
  elif ! cmp -s -- "$card_identity_before" "$card_identity_after"; then
    cccc_die 'task card content or ancestor identity changed during execution'
    policy_failed=1
  fi

  head_after=$(cccc_git_head "$CCCC_REPO_ROOT" 2>/dev/null || true)
  if [ -z "$head_after" ] || [ "$head_after" != "$head_before" ]; then
    cccc_die "HEAD changed during delegated execution: $head_before -> ${head_after:-<unreadable>}"
    policy_failed=1
  fi
  if ! cccc_git_snapshot "$CCCC_REPO_ROOT" "$snapshot_after"; then
    cccc_die 'cannot capture post-run Git snapshot'
    policy_failed=1
  fi
  if ! cccc_git_status_z "$CCCC_REPO_ROOT" "$status_after"; then
    cccc_die 'cannot capture post-run Git status'
    policy_failed=1
  fi
  if [ -f "$snapshot_after" ] && ! cccc_snapshot_changed_paths "$snapshot_before" "$snapshot_after" "$changed_file"; then
    cccc_die 'cannot compare pre-run and post-run Git snapshots'
    policy_failed=1
  fi
  [ -f "$changed_file" ] || : >"$changed_file"
  while IFS= read -r -d '' path; do
    if ! cccc_path_allowed "$path"; then
      path_hex=$(cccc_delegate_path_hex "$path" 2>/dev/null || printf '<unavailable>')
      cccc_die "Git-visible path changed outside allowed policy: path_hex=$path_hex"
      policy_failed=1
    fi
  done <"$changed_file"

  if [ "$status_rc" -ne 0 ]; then
    cat -- "$agent_stderr" >&2
    cccc_die "trusted runner outcome failed closed: agent_rc=$runner_rc"
    return 125
  fi
  cccc_warn "runner outcome: kind=$CCCC_RUNNER_KIND agent_rc=$agent_rc"
  case "$CCCC_RUNNER_KIND" in
    cleanup-failure|runner-internal)
      cat -- "$agent_stderr" >&2
      return 125
      ;;
  esac
  if [ "$policy_failed" -ne 0 ]; then
    cat -- "$agent_stderr" >&2
    return 4
  fi
  case "$CCCC_RUNNER_KIND" in
    wrapper-timeout)
      cat -- "$agent_stderr" >&2
      return 124
      ;;
    launch-failure)
      cat -- "$agent_stderr" >&2
      return 127
      ;;
    argument-validation)
      cat -- "$agent_stderr" >&2
      return 2
      ;;
    runner-signal)
      cat -- "$agent_stderr" >&2
      return 70
      ;;
    child-signal)
      cat -- "$agent_stderr" >&2
      return 70
      ;;
    child-exit)
      if [ "$CCCC_RUNNER_VALUE" != 0 ]; then
        cat -- "$agent_stderr" >&2
        return 70
      fi
      ;;
    *)
      cat -- "$agent_stderr" >&2
      return 125
      ;;
  esac

  if [ ! -f "$report_source" ] || [ -L "$report_source" ] || [ ! -s "$report_source" ]; then
    cccc_die 'delegated agent returned no fresh non-empty regular report'
    return 5
  fi
  cccc_delegate_write_log "$log_source" "$target" "$CCCC_DELEGATE_MODE" \
    "$CCCC_DELEGATE_TIMEOUT" "$agent_rc" "$head_before" "$head_after" \
    "$status_before" "$status_after" "$changed_file" "$agent_stdout" "$agent_stderr" || {
      cccc_die 'cannot construct delegate log'
      return 5
    }

  if ! cccc_validate_card "$card_rel" docs/tasks ||
    ! cccc_delegate_capture_card_identity "$CCCC_REPO_ROOT" "$card_rel" "$OWNED_RUN_DIR/card.publish" ||
    ! cmp -s -- "$card_identity_before" "$OWNED_RUN_DIR/card.publish"; then
    cccc_die 'task card or ancestor changed before publication'
    return 4
  fi
  cccc_refuse_output_target "$report_destination" || return 5
  cccc_refuse_output_target "$log_destination" || return 5
  cccc_atomic_publish "$log_source" "$log_destination" "$log_parent_identity" || return 5
  cccc_atomic_publish "$report_source" "$report_destination" "$report_parent_identity"
  publication_rc=$?
  if [ "$publication_rc" -ne 0 ]; then
    cccc_die "report publication failed after log commit; orphan log requires manual recovery: remove $log_destination before retry"
    return 5
  fi

  cccc_delegate_release_lock || {
    cccc_die 'repository lock cleanup failed after publication'
    return 125
  }
  cccc_delegate_remove_run_dir || {
    cccc_die 'owned run directory cleanup failed after publication'
    return 125
  }

  printf 'cccc: delegated report: %s\n' "$report_destination"
  printf 'cccc: delegated log: %s\n' "$log_destination"
  return 0
}

cccc_delegate_main "$@"
exit $?
