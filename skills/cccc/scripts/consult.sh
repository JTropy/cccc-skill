#!/usr/bin/env bash
# Obtain one read-only cccc discussion opinion through Claude Code or Codex with Git-visible policy enforcement.
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 127
# shellcheck source=skills/cccc/scripts/cccc-common.sh
. "$SCRIPT_DIR/cccc-common.sh" || exit 127

OWNED_RUN_DIR=
OWNED_RUN_DIR_ID=
OWNED_RUN_MANIFEST=()
OWNED_PRIVATE_CWD=
OWNED_PRIVATE_CWD_ID=
OWNED_LOCK_PATH=
OWNED_LOCK_OWNER=
OWNED_LOCK_ID=
RUNNER_PID=
RUNNER_STATUS_PATH=
RUNNER_TOKEN_PATH=
RUNNER_SECRET_HEX=
PENDING_SIGNAL_NUMBER=
PENDING_SIGNAL_NAME=
ACTIVE_HELPER_PID=
PUBLICATION_PHASE=
PUBLICATION_LOG_DESTINATION=
PUBLICATION_OPINION_DESTINATION=

CCCC_CONSULT_CODEX_FEATURES='hooks
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
recommended_plugins
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
unified_exec_zsh_fork'

CCCC_CONSULT_CODEX_SAFE_FEATURES='enable_request_compression
fast_mode
guardian_approval
mentions_v2
personality
remote_compaction_v2
shell_tool
unified_exec'

cccc_consult_directory_identity() {
  "$CCCC_PYTHON" -I -c '
import os, stat, sys
value = os.lstat(sys.argv[1])
if stat.S_ISLNK(value.st_mode) or not stat.S_ISDIR(value.st_mode):
    raise SystemExit(1)
if (getattr(value, "st_file_attributes", 0) & 0x400
        or getattr(value, "st_reparse_tag", 0)):
    raise SystemExit(1)
print("%d:%d" % (value.st_dev, value.st_ino))
' "$1"
}

cccc_consult_manifest_add() {
  local path=${1-} digest=0 allow_absent=0 expected_identity=
  local record name existing
  if [ "$#" -lt 1 ] || [ "$#" -gt 4 ] || [ -z "$path" ]; then
    return 1
  fi
  [ "$#" -lt 2 ] || digest=$2
  [ "$#" -lt 3 ] || allow_absent=$3
  if [ "$#" -eq 4 ]; then
    expected_identity=$4
    [ -n "$expected_identity" ] || return 1
  fi
  case "$digest" in 0|1) ;; *) return 1 ;; esac
  case "$allow_absent" in 0|1) ;; *) return 1 ;; esac
  name=${path##*/}
  [ -n "$name" ] || return 1
  if [ "${#OWNED_RUN_MANIFEST[@]}" -gt 0 ]; then
    for existing in "${OWNED_RUN_MANIFEST[@]}"; do
      case "$existing" in "$name|"*) return 1 ;; esac
    done
  fi
  record=$("$CCCC_PYTHON" -I -c '
import hashlib, os, re, stat, sys
run_dir, expected, path, with_digest, allow_absent, expected_identity = sys.argv[1:]

def is_reparse(value):
    return bool(
        getattr(value, "st_file_attributes", 0) & 0x400
        or getattr(value, "st_reparse_tag", 0)
    )

directory = os.lstat(run_dir)
if stat.S_ISLNK(directory.st_mode) or is_reparse(directory) or not stat.S_ISDIR(directory.st_mode):
    raise SystemExit(1)
if "%d:%d" % (directory.st_dev, directory.st_ino) != expected:
    raise SystemExit(1)
if os.path.dirname(os.path.abspath(path)) != os.path.abspath(run_dir):
    raise SystemExit(1)
name = os.path.basename(path)
if not name or "/" in name or "\\" in name or "|" in name:
    raise SystemExit(1)
value = os.lstat(path)
if stat.S_ISLNK(value.st_mode) or is_reparse(value) or not stat.S_ISREG(value.st_mode):
    raise SystemExit(1)
actual_identity = "%d:%d" % (value.st_dev, value.st_ino)
if expected_identity and actual_identity != expected_identity:
    raise SystemExit(1)
digest = "-"
if with_digest == "1":
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    try:
        opened = os.fstat(descriptor)
        if (is_reparse(opened)
                or (opened.st_dev, opened.st_ino) != (value.st_dev, value.st_ino)):
            raise SystemExit(1)
        hasher = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            hasher.update(chunk)
        digest = hasher.hexdigest()
    finally:
        os.close(descriptor)
print("%s|%d|%d|regular|%s|%s" % (
    name, value.st_dev, value.st_ino, digest, allow_absent
))
' "$OWNED_RUN_DIR" "$OWNED_RUN_DIR_ID" "$path" "$digest" "$allow_absent" "$expected_identity") || return 1
  OWNED_RUN_MANIFEST[${#OWNED_RUN_MANIFEST[@]}]=$record
  return 0
}

cccc_consult_manifest_binding() {
  local path=${1-} name record rest dev ino kind digest allow_absent
  CCCC_CONSULT_MANIFEST_ID=
  CCCC_CONSULT_MANIFEST_DIGEST=
  [ -n "$path" ] || return 1
  name=${path##*/}
  for record in "${OWNED_RUN_MANIFEST[@]}"; do
    case "$record" in
      "$name|"*)
        rest=${record#*|}
        dev=${rest%%|*}; rest=${rest#*|}
        ino=${rest%%|*}; rest=${rest#*|}
        kind=${rest%%|*}; rest=${rest#*|}
        digest=${rest%%|*}; allow_absent=${rest#*|}
        case "$dev" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
        case "$ino" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
        [ "$kind" = regular ] || return 1
        case "$allow_absent" in 0|1) ;; *) return 1 ;; esac
        case "$digest" in
          -) ;;
          *)
            [ "${#digest}" -eq 64 ] || return 1
            case "$digest" in *[!0-9a-f]*) return 1 ;; esac
            ;;
        esac
        CCCC_CONSULT_MANIFEST_ID="$dev:$ino"
        CCCC_CONSULT_MANIFEST_DIGEST=$digest
        return 0
        ;;
    esac
  done
  return 1
}

cccc_consult_publish_manifest_source() {
  local source=$1 destination=$2 parent_identity=$3 digest helper_rc=0
  local publish_argv=()
  cccc_consult_manifest_binding "$source" || {
    cccc_die 'publication source is not registered in the owned manifest'
    return 5
  }
  if [ "$CCCC_CONSULT_MANIFEST_DIGEST" = - ]; then
    digest=$("$CCCC_PYTHON" -I -c '
import hashlib, os, stat, sys
path, expected = sys.argv[1:]

def is_reparse(value):
    return bool(
        getattr(value, "st_file_attributes", 0) & 0x400
        or getattr(value, "st_reparse_tag", 0)
    )

before = os.lstat(path)
if (stat.S_ISLNK(before.st_mode) or is_reparse(before)
        or not stat.S_ISREG(before.st_mode)
        or "%d:%d" % (before.st_dev, before.st_ino) != expected):
    raise SystemExit(1)
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
descriptor = os.open(path, flags)
try:
    opened = os.fstat(descriptor)
    if (not stat.S_ISREG(opened.st_mode) or is_reparse(opened)
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)):
        raise SystemExit(1)
    hasher = hashlib.sha256()
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        hasher.update(chunk)
    after = os.fstat(descriptor)
    before_metadata = (opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns)
    after_metadata = (after.st_size, after.st_mtime_ns, after.st_ctime_ns)
    if (is_reparse(after) or (after.st_dev, after.st_ino) != (opened.st_dev, opened.st_ino)
            or before_metadata != after_metadata):
        raise SystemExit(1)
finally:
    os.close(descriptor)
current = os.lstat(path)
if (stat.S_ISLNK(current.st_mode) or is_reparse(current)
        or not stat.S_ISREG(current.st_mode)
        or (current.st_dev, current.st_ino) != (before.st_dev, before.st_ino)):
    raise SystemExit(1)
print(hasher.hexdigest())
' "$source" "$CCCC_CONSULT_MANIFEST_ID") || {
      cccc_die 'cannot seal publication source content against its manifest identity'
      return 5
    }
  else
    digest=$CCCC_CONSULT_MANIFEST_DIGEST
  fi
  case "$digest" in
    *[!0-9a-f]*|'') return 5 ;;
  esac
  [ "${#digest}" -eq 64 ] || return 5
  publish_argv=("$CCCC_PYTHON" -I "$SCRIPT_DIR/run-with-timeout.py" 0 --
    "$CCCC_PYTHON" -I "$CCCC_COMMON_DIR/publish-no-clobber.py"
    --parent-identity "$parent_identity"
    --source-identity "$CCCC_CONSULT_MANIFEST_ID"
    --source-sha256 "$digest" "$source" "$destination")
  PENDING_SIGNAL_NUMBER=
  PENDING_SIGNAL_NAME=
  trap 'cccc_consult_defer_signal 1 HUP' HUP
  trap 'cccc_consult_defer_signal 2 INT' INT
  trap 'cccc_consult_defer_signal 15 TERM' TERM
  (
    trap - HUP INT TERM
    unset BASH_ENV ENV
    exec "${publish_argv[@]}"
  ) &
  ACTIVE_HELPER_PID=$!
  trap 'cccc_consult_on_signal 1 HUP' HUP
  trap 'cccc_consult_on_signal 2 INT' INT
  trap 'cccc_consult_on_signal 15 TERM' TERM
  if [ -n "$PENDING_SIGNAL_NAME" ]; then
    cccc_consult_on_signal "$PENDING_SIGNAL_NUMBER" "$PENDING_SIGNAL_NAME"
  fi
  wait "$ACTIVE_HELPER_PID" || helper_rc=$?
  ACTIVE_HELPER_PID=
  return "$helper_rc"
}

cccc_consult_manifest_remove() {
  local name=$1 record
  local next=()
  for record in "${OWNED_RUN_MANIFEST[@]}"; do
    case "$record" in "$name|"*) continue ;; esac
    next[${#next[@]}]=$record
  done
  OWNED_RUN_MANIFEST=("${next[@]}")
}

cccc_consult_verify_post_child_namespace() {
  "$CCCC_PYTHON" -I -c '
import hashlib, os, re, stat, sys
run_dir, expected = sys.argv[1:3]
records = sys.argv[3:]

def unsafe(value, wanted):
    if (stat.S_ISLNK(value.st_mode)
            or getattr(value, "st_file_attributes", 0) & 0x400
            or getattr(value, "st_reparse_tag", 0)):
        return True
    return not wanted(value.st_mode)

directory = os.lstat(run_dir)
if unsafe(directory, stat.S_ISDIR) or "%d:%d" % (directory.st_dev, directory.st_ino) != expected:
    raise SystemExit(1)
manifest = {}
for raw in records:
    fields = raw.split("|")
    if len(fields) != 6 or fields[0] in manifest:
        raise SystemExit(1)
    name, dev, ino, kind, digest, allow_absent = fields
    if (not name or "/" in name or "\\" in name or "|" in name
            or kind != "regular"
            or re.fullmatch(r"0|[1-9][0-9]*", dev) is None
            or re.fullmatch(r"0|[1-9][0-9]*", ino) is None
            or (digest != "-" and re.fullmatch(r"[0-9a-f]{64}", digest) is None)
            or allow_absent not in ("0", "1")):
        raise SystemExit(1)
    manifest[name] = (int(dev), int(ino), digest, allow_absent == "1")
actual = set(os.listdir(run_dir))
if actual - set(manifest) - {"runner.status"}:
    raise SystemExit(1)
for name, (dev, ino, digest, allow_absent) in manifest.items():
    path = os.path.join(run_dir, name)
    try:
        value = os.lstat(path)
    except OSError:
        if allow_absent:
            continue
        raise SystemExit(1)
    if unsafe(value, stat.S_ISREG) or (value.st_dev, value.st_ino) != (dev, ino):
        raise SystemExit(1)
    if digest != "-":
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
        try:
            opened = os.fstat(descriptor)
            if (opened.st_dev, opened.st_ino) != (dev, ino):
                raise SystemExit(1)
            hasher = hashlib.sha256()
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                hasher.update(chunk)
            if hasher.hexdigest() != digest:
                raise SystemExit(1)
        finally:
            os.close(descriptor)
if "runner.status" in actual:
    value = os.lstat(os.path.join(run_dir, "runner.status"))
    if unsafe(value, stat.S_ISREG):
        raise SystemExit(1)
' "$OWNED_RUN_DIR" "$OWNED_RUN_DIR_ID" "${OWNED_RUN_MANIFEST[@]}"
}

cccc_consult_release_lock() {
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
    if (stat.S_ISLNK(value.st_mode)
            or getattr(value, "st_file_attributes", 0) & 0x400
            or getattr(value, "st_reparse_tag", 0)
            or not stat.S_ISREG(value.st_mode)):
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

cccc_consult_remove_run_dir() {
  [ -n "$OWNED_RUN_DIR" ] || return 0
  [ -n "$OWNED_RUN_DIR_ID" ] || return 1
  "$CCCC_PYTHON" -I -c '
import os, re, stat, sys
run_dir, expected = sys.argv[1:3]
records = sys.argv[3:]

def unsafe(value, wanted):
    if (stat.S_ISLNK(value.st_mode)
            or getattr(value, "st_file_attributes", 0) & 0x400
            or getattr(value, "st_reparse_tag", 0)):
        return True
    return not wanted(value.st_mode)

manifest = {}
for raw in records:
    fields = raw.split("|")
    if len(fields) != 6 or fields[0] in manifest:
        raise SystemExit(1)
    name, dev, ino, kind, digest, allow_absent = fields
    if (not name or "/" in name or "\\" in name or "|" in name
            or kind != "regular"
            or re.fullmatch(r"0|[1-9][0-9]*", dev) is None
            or re.fullmatch(r"0|[1-9][0-9]*", ino) is None
            or (digest != "-" and re.fullmatch(r"[0-9a-f]{64}", digest) is None)
            or allow_absent not in ("0", "1")):
        raise SystemExit(1)
    manifest[name] = (int(dev), int(ino), allow_absent == "1")

directory_fd = None
parent_fd = None
try:
    if os.name == "posix":
        parent = os.path.realpath(os.path.dirname(run_dir))
        basename = os.path.basename(run_dir)
        directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        parent_fd = os.open(parent, directory_flags)
        directory_fd = os.open(basename, directory_flags, dir_fd=parent_fd)
        directory = os.fstat(directory_fd)
    else:
        # The standard library has no Windows dir_fd/unlinkat equivalent.  Keep
        # the path branch fail-closed with identity checks immediately before
        # every unlink, and reject reparse points throughout.
        directory = os.lstat(run_dir)
    if unsafe(directory, stat.S_ISDIR) or "%d:%d" % (directory.st_dev, directory.st_ino) != expected:
        raise SystemExit(1)

    actual = set(os.listdir(directory_fd if directory_fd is not None else run_dir))
    if actual - set(manifest):
        raise SystemExit(1)

    def entry_stat(name):
        if directory_fd is not None:
            return os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        return os.lstat(os.path.join(run_dir, name))

    def directory_path_matches():
        if directory_fd is not None:
            opened = os.fstat(directory_fd)
            current = os.stat(basename, dir_fd=parent_fd, follow_symlinks=False)
            return (
                not unsafe(current, stat.S_ISDIR)
                and (opened.st_dev, opened.st_ino) == (directory.st_dev, directory.st_ino)
                and (current.st_dev, current.st_ino) == (directory.st_dev, directory.st_ino)
            )
        current = os.lstat(run_dir)
        return (
            not unsafe(current, stat.S_ISDIR)
            and "%d:%d" % (current.st_dev, current.st_ino) == expected
        )

    to_delete = []
    for name, (dev, ino, allow_absent) in manifest.items():
        try:
            value = entry_stat(name)
        except OSError:
            if allow_absent:
                continue
            raise SystemExit(1)
        if unsafe(value, stat.S_ISREG) or (value.st_dev, value.st_ino) != (dev, ino):
            raise SystemExit(1)
        to_delete.append((name, dev, ino))

    # cccc-cleanup-delete-pass
    for name, dev, ino in to_delete:
        if not directory_path_matches():
            raise SystemExit(1)
        value = entry_stat(name)
        if unsafe(value, stat.S_ISREG) or (value.st_dev, value.st_ino) != (dev, ino):
            raise SystemExit(1)
        if directory_fd is not None:
            os.unlink(name, dir_fd=directory_fd)
        else:
            os.unlink(os.path.join(run_dir, name))

    if directory_fd is not None:
        if not directory_path_matches():
            raise SystemExit(1)
        os.rmdir(basename, dir_fd=parent_fd)
    else:
        directory = os.lstat(run_dir)
        if unsafe(directory, stat.S_ISDIR) or "%d:%d" % (directory.st_dev, directory.st_ino) != expected:
            raise SystemExit(1)
        os.rmdir(run_dir)
finally:
    if directory_fd is not None:
        os.close(directory_fd)
    if parent_fd is not None:
        os.close(parent_fd)
' "$OWNED_RUN_DIR" "$OWNED_RUN_DIR_ID" "${OWNED_RUN_MANIFEST[@]}" || return 1
  OWNED_RUN_DIR=
  OWNED_RUN_DIR_ID=
  OWNED_RUN_MANIFEST=()
  return 0
}

cccc_consult_create_private_cwd() {
  local path=$1 identity
  if ! (umask 077 && mkdir -- "$path"); then
    cccc_die 'cannot create private agent cwd'
    return 1
  fi
  chmod 700 "$path" || return 1
  identity=$(cccc_consult_directory_identity "$path") || return 1
  OWNED_PRIVATE_CWD=$path
  OWNED_PRIVATE_CWD_ID=$identity
  return 0
}

cccc_consult_remove_private_cwd() {
  [ -n "$OWNED_PRIVATE_CWD" ] || return 0
  [ -n "$OWNED_PRIVATE_CWD_ID" ] && [ -n "$OWNED_RUN_DIR_ID" ] || return 1
  "$CCCC_PYTHON" -I - "$OWNED_PRIVATE_CWD" "$OWNED_PRIVATE_CWD_ID" \
    "$OWNED_RUN_DIR" "$OWNED_RUN_DIR_ID" <<'PY' 2>/dev/null || return 1
import os
import stat
import sys

path, expected_text, parent, parent_expected_text = sys.argv[1:]
expected = tuple(int(item) for item in expected_text.split(":", 1))
parent_expected = tuple(int(item) for item in parent_expected_text.split(":", 1))
name = os.path.basename(path)
if not name or os.path.dirname(os.path.abspath(path)) != os.path.abspath(parent):
    raise SystemExit(1)

def unsafe(value, wanted):
    return (
        stat.S_ISLNK(value.st_mode)
        or getattr(value, "st_file_attributes", 0) & 0x400
        or getattr(value, "st_reparse_tag", 0)
        or not wanted(value.st_mode)
    )

if os.name == "posix":
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    parent_fd = os.open(parent, flags)
    directory_fd = None
    try:
        parent_stat = os.fstat(parent_fd)
        if unsafe(parent_stat, stat.S_ISDIR) or (parent_stat.st_dev, parent_stat.st_ino) != parent_expected:
            raise SystemExit(1)
        directory_fd = os.open(name, flags, dir_fd=parent_fd)
        opened = os.fstat(directory_fd)
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if (unsafe(opened, stat.S_ISDIR) or unsafe(current, stat.S_ISDIR)
                or (opened.st_dev, opened.st_ino) != expected
                or (current.st_dev, current.st_ino) != expected
                or os.listdir(directory_fd)):
            raise SystemExit(1)
        os.rmdir(name, dir_fd=parent_fd)
    finally:
        if directory_fd is not None:
            os.close(directory_fd)
        os.close(parent_fd)
else:
    parent_stat = os.lstat(parent)
    before = os.lstat(path)
    if (unsafe(parent_stat, stat.S_ISDIR)
            or (parent_stat.st_dev, parent_stat.st_ino) != parent_expected
            or unsafe(before, stat.S_ISDIR)
            or (before.st_dev, before.st_ino) != expected
            or os.listdir(path)):
        raise SystemExit(1)
    current = os.lstat(path)
    if unsafe(current, stat.S_ISDIR) or (current.st_dev, current.st_ino) != expected:
        raise SystemExit(1)
    os.rmdir(path)
PY
  OWNED_PRIVATE_CWD=
  OWNED_PRIVATE_CWD_ID=
  return 0
}

cccc_consult_cleanup() {
  local original_status=$1 cleanup_failed=0
  trap - EXIT
  trap '' HUP INT TERM
  cccc_consult_remove_private_cwd || cleanup_failed=1
  cccc_consult_release_lock || cleanup_failed=1
  cccc_consult_remove_run_dir || cleanup_failed=1
  if [ "$cleanup_failed" -ne 0 ]; then
    cccc_die 'consult cleanup failed'
    exit 125
  fi
  exit "$original_status"
}

cccc_consult_publication_interrupt_diagnostic() {
  local log_exists=0 opinion_exists=0
  if [ -n "$PUBLICATION_LOG_DESTINATION" ] &&
    { [ -e "$PUBLICATION_LOG_DESTINATION" ] || [ -L "$PUBLICATION_LOG_DESTINATION" ]; }; then
    log_exists=1
  fi
  if [ -n "$PUBLICATION_OPINION_DESTINATION" ] &&
    { [ -e "$PUBLICATION_OPINION_DESTINATION" ] || [ -L "$PUBLICATION_OPINION_DESTINATION" ]; }; then
    opinion_exists=1
  fi
  if [ "$log_exists" -eq 1 ] && [ "$opinion_exists" -eq 0 ]; then
    cccc_die "publication interrupted after log commit; orphan log requires manual cleanup: remove $PUBLICATION_LOG_DESTINATION before retry"
  elif [ "$opinion_exists" -eq 1 ]; then
    cccc_die "publication interrupted after output commit; no success was recorded; manual cleanup or verification is required for $PUBLICATION_LOG_DESTINATION and $PUBLICATION_OPINION_DESTINATION"
  fi
}

cccc_consult_on_signal() {
  local number=$1 name=$2 runner_rc=0 status_rc=125 had_runner=0 namespace_ok=1
  local helper_rc=0
  trap '' HUP INT TERM
  if [ -n "$ACTIVE_HELPER_PID" ]; then
    if kill -0 "$ACTIVE_HELPER_PID" 2>/dev/null; then
      kill -s "$name" "$ACTIVE_HELPER_PID" 2>/dev/null || true
    fi
    wait "$ACTIVE_HELPER_PID" 2>/dev/null || helper_rc=$?
    ACTIVE_HELPER_PID=
    cccc_consult_publication_interrupt_diagnostic
    if [ "$helper_rc" -eq 125 ]; then
      exit 125
    fi
    exit $((128 + number))
  fi
  if [ -n "$RUNNER_PID" ]; then
    had_runner=1
    if kill -0 "$RUNNER_PID" 2>/dev/null; then
      kill -s "$name" "$RUNNER_PID" 2>/dev/null || true
    fi
    wait "$RUNNER_PID" 2>/dev/null || runner_rc=$?
    cccc_consult_remove_private_cwd >/dev/null 2>&1 || namespace_ok=0
    if [ -n "$RUNNER_TOKEN_PATH" ] && [ ! -e "$RUNNER_TOKEN_PATH" ] && [ ! -L "$RUNNER_TOKEN_PATH" ]; then
      cccc_consult_manifest_remove "${RUNNER_TOKEN_PATH##*/}"
    else
      namespace_ok=0
    fi
    if [ "$namespace_ok" -eq 1 ] && [ -n "$RUNNER_STATUS_PATH" ] &&
      cccc_consult_verify_post_child_namespace >/dev/null 2>&1; then
      cccc_consult_parse_runner_status "$RUNNER_STATUS_PATH" "$runner_rc" >/dev/null 2>&1
      status_rc=$?
      if [ "$status_rc" -eq 0 ]; then
        cccc_consult_manifest_add "$RUNNER_STATUS_PATH" 1 0 \
          "$CCCC_RUNNER_STATUS_ID" >/dev/null 2>&1 || status_rc=125
      fi
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
  cccc_consult_publication_interrupt_diagnostic
  exit $((128 + number))
}

cccc_consult_defer_signal() {
  if [ -z "$PENDING_SIGNAL_NAME" ]; then
    PENDING_SIGNAL_NUMBER=$1
    PENDING_SIGNAL_NAME=$2
  fi
}

trap 'cccc_consult_cleanup $?' EXIT
trap 'cccc_consult_on_signal 1 HUP' HUP
trap 'cccc_consult_on_signal 2 INT' INT
trap 'cccc_consult_on_signal 15 TERM' TERM

cccc_consult_usage() {
  cccc_die 'usage: consult.sh <claude|codex> <docs/discussions/card.md> [workdir]'
}

cccc_consult_environment() {
  if [ "${CCCC_MODE+x}" = x ] || [ "${CCCC_ALLOW_FULL+x}" = x ] ||
    [ "${DELEGATE_SANDBOX+x}" = x ]; then
    cccc_die 'consult forbids CCCC_MODE, CCCC_ALLOW_FULL, and DELEGATE_SANDBOX'
    return 2
  fi
  if [ "${CCCC_TIMEOUT+x}" = x ]; then
    CCCC_CONSULT_TIMEOUT=$CCCC_TIMEOUT
  else
    CCCC_CONSULT_TIMEOUT=1800
  fi
  if [ "${CCCC_MODEL+x}" = x ]; then
    CCCC_CONSULT_MODEL=$CCCC_MODEL
  else
    CCCC_CONSULT_MODEL=
  fi
  cccc_validate_timeout "$CCCC_CONSULT_TIMEOUT" || return 2
  if [ "${CCCC_ALLOW_DIRTY+x}" = x ] && [ "$CCCC_ALLOW_DIRTY" != 1 ]; then
    cccc_die 'CCCC_ALLOW_DIRTY must be unset or exactly 1'
    return 2
  fi
  if [ "${CCCC_CODEX_CONFIG_MODE+x}" = x ]; then
    CCCC_CONSULT_CODEX_CONFIG_MODE=$CCCC_CODEX_CONFIG_MODE
  else
    CCCC_CONSULT_CODEX_CONFIG_MODE=strict
  fi
  case "$CCCC_CONSULT_CODEX_CONFIG_MODE" in
    strict|inherit) ;;
    *) cccc_die 'CCCC_CODEX_CONFIG_MODE must be exactly strict or inherit'; return 2 ;;
  esac
  return 0
}

cccc_consult_validate_depth() {
  local depth=${DELEGATE_DEPTH-}
  case "$depth" in
    ''|0) return 0 ;;
    *)
      cccc_die "nested consultation is forbidden (DELEGATE_DEPTH=$depth)"
      return 3
      ;;
  esac
}

cccc_consult_validate_effort() {
  local target=$1 effort=${CCCC_EFFORT-}
  [ -n "$effort" ] || return 0
  case "$target:$effort" in
    claude:low|claude:medium|claude:high|claude:xhigh|claude:max) return 0 ;;
    codex:minimal|codex:low|codex:medium|codex:high|codex:xhigh) return 0 ;;
  esac
  cccc_die "invalid CCCC_EFFORT for $target: $effort"
  return 2
}

cccc_consult_reject_git_redirects() {
  if [ "${GIT_DIR+x}" = x ] || [ "${GIT_WORK_TREE+x}" = x ] ||
    [ "${GIT_INDEX_FILE+x}" = x ] || [ "${GIT_COMMON_DIR+x}" = x ] ||
    [ "${GIT_OBJECT_DIRECTORY+x}" = x ]; then
    cccc_die 'Git redirect environment variables are forbidden for consultation'
    return 2
  fi
  return 0
}

cccc_consult_validate_timeout_max() {
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
  if [ "${#CCCC_CONSULT_TIMEOUT}" -gt "${#maximum}" ] || {
    [ "${#CCCC_CONSULT_TIMEOUT}" -eq "${#maximum}" ] &&
      [ "$CCCC_CONSULT_TIMEOUT" \> "$maximum" ]
  }; then
    cccc_die "timeout must be no greater than $maximum"
    return 2
  fi
  return 0
}

cccc_consult_create_private_json() {
  local path=$1
  "$CCCC_PYTHON" -I -c '
import os, sys
path = sys.argv[1]
data = b"{}\n"
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
for name in ("O_NOFOLLOW", "O_CLOEXEC", "O_BINARY"):
    flags |= getattr(os, name, 0)
descriptor = os.open(path, flags, 0o600)
try:
    if os.name == "posix":
        os.fchmod(descriptor, 0o600)
    if os.write(descriptor, data) != len(data):
        raise OSError("short private-config write")
    os.fsync(descriptor)
finally:
    os.close(descriptor)
' "$path" || return 1
  cccc_consult_manifest_add "$path" 1 0
}

cccc_consult_reject_allowed_block() {
  local path=$1
  "$CCCC_PYTHON" -I -c '
import os, stat, sys
path = sys.argv[1]
before = os.lstat(path)
if (stat.S_ISLNK(before.st_mode)
        or getattr(before, "st_file_attributes", 0) & 0x400
        or getattr(before, "st_reparse_tag", 0)
        or not stat.S_ISREG(before.st_mode)):
    raise SystemExit(1)
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
descriptor = os.open(path, flags)
try:
    opened = os.fstat(descriptor)
    if (not stat.S_ISREG(opened.st_mode)
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)):
        raise SystemExit(1)
    chunks = []
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        chunks.append(chunk)
    after = os.fstat(descriptor)
    if ((after.st_dev, after.st_ino) != (opened.st_dev, opened.st_ino)
            or (after.st_size, after.st_mtime_ns, after.st_ctime_ns)
            != (opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns)):
        raise SystemExit(1)
finally:
    os.close(descriptor)
current = os.lstat(path)
if (current.st_dev, current.st_ino) != (before.st_dev, before.st_ino):
    raise SystemExit(1)
raise SystemExit(2 if b"<!-- cccc-allowed-paths" in b"".join(chunks) else 0)
' "$path"
  case $? in
    0) return 0 ;;
    2) cccc_die 'discussion cards must not contain a cccc-allowed-paths block'; return 2 ;;
    *) cccc_die 'cannot safely inspect discussion card policy markers'; return 2 ;;
  esac
}

cccc_consult_help_has_options() {
  local path=$1
  shift
  "$CCCC_PYTHON" -I -c '
import re, sys
path = sys.argv[1]
required = set(sys.argv[2:])
found = set()
with open(path, encoding="utf-8", errors="strict") as stream:
    for line in stream:
        fields = line.lstrip().split()
        if not fields or not fields[0].startswith("-"):
            continue
        for raw in fields:
            token = raw.rstrip(",").split("=", 1)[0]
            if re.fullmatch(r"-[A-Za-z]|--[A-Za-z0-9][A-Za-z0-9-]*", token) is None:
                break
            found.add(token)
missing = sorted(required - found)
if missing:
    print("missing required CLI option tokens: " + ", ".join(missing), file=sys.stderr)
    raise SystemExit(1)
' "$path" "$@"
}

cccc_consult_validate_codex_features() {
  local path=$1
  printf '%s\n--safe--\n%s\n' "$CCCC_CONSULT_CODEX_FEATURES" \
    "$CCCC_CONSULT_CODEX_SAFE_FEATURES" | "$CCCC_PYTHON" -I -c '
import re, sys
path = sys.argv[1]
raw_required, raw_safe = sys.stdin.read().split("\n--safe--\n", 1)
required = {item for item in raw_required.splitlines() if item}
safe = {item for item in raw_safe.splitlines() if item}
records = {}
allowed_lifecycles = {"stable", "experimental", "under development", "deprecated", "removed"}
with open(path, encoding="utf-8", errors="strict") as stream:
    for number, line in enumerate(stream, 1):
        fields = line.split()
        if len(fields) < 3 or re.fullmatch(r"[a-z][a-z0-9_]*", fields[0]) is None:
            raise SystemExit("malformed feature record at line %d" % number)
        name, enabled = fields[0], fields[-1]
        lifecycle = " ".join(fields[1:-1])
        if enabled not in ("true", "false") or lifecycle not in allowed_lifecycles or name in records:
            raise SystemExit("invalid or duplicate feature record at line %d" % number)
        records[name] = (lifecycle, enabled == "true")
for name in required:
    if name not in records or records[name][0] in ("removed", "deprecated"):
        raise SystemExit("required deny feature missing or removed: " + name)
for name, (lifecycle, enabled) in records.items():
    if name in required or name in safe or lifecycle in ("removed", "deprecated"):
        continue
    if enabled:
        raise SystemExit("unknown enabled feature: " + name)
' "$path"
}

cccc_consult_preflight_codex() {
  local helper=$1 root_help=$2 exec_help=$3 features=$4
  cccc_consult_create_empty_file "$root_help" || return 127
  cccc_consult_create_empty_file "$exec_help" || return 127
  cccc_consult_create_empty_file "$features" || return 127
  (
    cd "$OWNED_PRIVATE_CWD" || exit 127
    unset BASH_ENV ENV
    DELEGATE_DEPTH=1 exec "$CCCC_PYTHON" -I "$helper" 30 -- \
      "${CCCC_TARGET_ARGV[@]}" --help
  ) >"$root_help" 2>/dev/null || {
      cccc_die 'Codex root help preflight failed'
      return 127
    }
  cccc_consult_help_has_options "$root_help" -a || {
    cccc_die 'Codex root help lacks required safety options'
    return 127
  }
  (
    cd "$OWNED_PRIVATE_CWD" || exit 127
    unset BASH_ENV ENV
    DELEGATE_DEPTH=1 exec "$CCCC_PYTHON" -I "$helper" 30 -- \
      "${CCCC_TARGET_ARGV[@]}" exec --help
  ) >"$exec_help" 2>/dev/null || {
      cccc_die 'Codex exec help preflight failed'
      return 127
    }
  cccc_consult_help_has_options "$exec_help" --json --ephemeral --sandbox \
    --ignore-user-config --strict-config --ignore-rules --skip-git-repo-check \
    -C -c --disable || {
      cccc_die 'Codex exec help lacks required safety options'
      return 127
    }
  (
    cd "$OWNED_PRIVATE_CWD" || exit 127
    unset BASH_ENV ENV
    DELEGATE_DEPTH=1 exec "$CCCC_PYTHON" -I "$helper" 30 -- \
      "${CCCC_TARGET_ARGV[@]}" features list
  ) >"$features" 2>/dev/null || {
      cccc_die 'Codex feature-list preflight failed'
      return 127
    }
  cccc_consult_validate_codex_features "$features" || {
    cccc_die 'Codex feature-list preflight failed closed'
    return 127
  }
  return 0
}

cccc_consult_resolve_common_dir() {
  local raw physical
  CCCC_CONSULT_COMMON_DIR=
  raw=$(git -C "$CCCC_REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
    cccc_die 'cannot resolve Git common-dir'
    return 4
  }
  physical=$(CDPATH= cd -P -- "$raw" 2>/dev/null && pwd) || {
    cccc_die 'cannot resolve physical Git common-dir'
    return 4
  }
  CCCC_CONSULT_COMMON_DIR=$physical
  return 0
}

cccc_consult_file_identity() {
  "$CCCC_PYTHON" -I - "$1" <<'PY'
import os
import stat
import sys

value = os.lstat(sys.argv[1])
if (stat.S_ISLNK(value.st_mode)
        or getattr(value, "st_file_attributes", 0) & 0x400
        or getattr(value, "st_reparse_tag", 0)
        or not stat.S_ISREG(value.st_mode)):
    raise SystemExit(5)
print("%d:%d" % (value.st_dev, value.st_ino))
PY
}

cccc_consult_acquire_repo_lock() {
  local common=$1 owner lock owner_id lock_id
  owner=$(umask 077 && mktemp "$common/.cccc-delegate-owner.XXXXXXXX") || {
    cccc_die 'cannot create repo-lock ownership file'
    return 5
  }
  OWNED_LOCK_OWNER=$owner
  owner_id=$(cccc_consult_file_identity "$owner") || {
    unlink "$owner" 2>/dev/null || true
    cccc_die 'cannot verify repo-lock ownership file'
    return 5
  }
  OWNED_LOCK_ID=$owner_id
  chmod 600 "$owner" || { cccc_consult_release_lock || true; return 5; }
  lock="$common/cccc-v2.lock"
  OWNED_LOCK_PATH=$lock
  if ! ln -- "$owner" "$lock" 2>/dev/null; then
    OWNED_LOCK_PATH=
    cccc_die 'repository already has an active cccc execution lock'
    cccc_consult_release_lock
    return 5
  fi
  lock_id=$(cccc_consult_file_identity "$lock") || {
    cccc_die 'cannot verify acquired cccc execution lock'
    cccc_consult_release_lock
    return 5
  }
  if [ "$lock_id" != "$owner_id" ]; then
    cccc_die 'cccc execution lock ownership proof failed'
    cccc_consult_release_lock
    return 5
  fi
  return 0
}

cccc_consult_policy_excludes_card() {
  if cccc_path_allowed "$CCCC_CARD_REL"; then
    cccc_die 'allowed paths must not cover the task card or any card ancestor'
    return 2
  fi
  return 0
}

cccc_consult_capture_card_identity() {
  local repo=$1 relative=$2 output=$3
  "$CCCC_PYTHON" -I - "$repo" "$relative" "$output" <<'PY'
import hashlib
import os
import stat
import sys

root, relative, output = sys.argv[1:]

def is_reparse(value):
    return bool(
        getattr(value, "st_file_attributes", 0) & 0x400
        or getattr(value, "st_reparse_tag", 0)
    )

parts = relative.split("/")
if not parts or any(not part or part in (".", "..") for part in parts):
    raise SystemExit(5)
records = []
root_stat = os.lstat(root)
if stat.S_ISLNK(root_stat.st_mode) or is_reparse(root_stat) or not stat.S_ISDIR(root_stat.st_mode):
    raise SystemExit(5)
records.append((b"", root_stat))
current = root
for index, part in enumerate(parts):
    current = os.path.join(current, part)
    value = os.lstat(current)
    if stat.S_ISLNK(value.st_mode) or is_reparse(value):
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
    if (not stat.S_ISREG(opened.st_mode) or is_reparse(opened)
            or (opened.st_dev, opened.st_ino) != (final.st_dev, final.st_ino)):
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

cccc_consult_create_empty_file() {
  local path=$1
  "$CCCC_PYTHON" -I -c '
import os, sys
path = sys.argv[1]
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
for name in ("O_NOFOLLOW", "O_CLOEXEC", "O_BINARY"):
    flags |= getattr(os, name, 0)
descriptor = os.open(path, flags, 0o600)
try:
    if os.name == "posix":
        os.fchmod(descriptor, 0o600)
    os.fsync(descriptor)
finally:
    os.close(descriptor)
' "$path" || return 1
  cccc_consult_manifest_add "$path" 0 0
}

cccc_consult_create_runner_token() {
  local path=$1 secret
  secret=$("$CCCC_PYTHON" -I -c '
import os, sys
path = sys.argv[1]
secret = os.urandom(32)
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
for name in ("O_NOFOLLOW", "O_CLOEXEC", "O_BINARY"):
    flags |= getattr(os, name, 0)
descriptor = os.open(path, flags, 0o600)
try:
    if os.name == "posix":
        os.fchmod(descriptor, 0o600)
    offset = 0
    while offset < len(secret):
        written = os.write(descriptor, secret[offset:])
        if written <= 0:
            raise OSError("token write made no progress")
        offset += written
    os.fsync(descriptor)
finally:
    os.close(descriptor)
print(secret.hex())
' "$path") || return 1
  case "$secret" in
    [0-9a-f][0-9a-f]*) ;;
    *) return 1 ;;
  esac
  [ "${#secret}" -eq 64 ] || return 1
  RUNNER_SECRET_HEX=$secret
  cccc_consult_manifest_add "$path" 1 1
}

cccc_consult_safe_git_status_z() {
  local repo=$1 output=$2
  "$CCCC_PYTHON" -I -c '
import os, subprocess, sys
repo, output = sys.argv[1:]
result = subprocess.run(
    ["git", "-C", repo, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=no"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
)
if result.returncode:
    sys.stderr.buffer.write(result.stderr)
    raise SystemExit(result.returncode)
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
for name in ("O_NOFOLLOW", "O_CLOEXEC", "O_BINARY"):
    flags |= getattr(os, name, 0)
descriptor = os.open(output, flags, 0o600)
try:
    if os.name == "posix":
        os.fchmod(descriptor, 0o600)
    offset = 0
    while offset < len(result.stdout):
        written = os.write(descriptor, result.stdout[offset:])
        if written <= 0:
            raise OSError("status write made no progress")
        offset += written
    os.fsync(descriptor)
finally:
    os.close(descriptor)
' "$repo" "$output" || return 1
  cccc_consult_manifest_add "$output" 1 0
}

cccc_consult_safe_changed_paths() {
  local before=$1 after=$2 output=$3
  "$CCCC_PYTHON" -I -c '
import os, sys
before_path, after_path, output_path = sys.argv[1:]
def read_snapshot(path):
    records = {}
    with open(path, "rb") as stream:
        for number, raw_line in enumerate(stream, 1):
            fields = raw_line.rstrip(b"\n").split(b"\t")
            if len(fields) != 4:
                raise SystemExit(1)
            relative = bytes.fromhex(fields[0].decode("ascii"))
            if not relative or b"\0" in relative or relative in records:
                raise SystemExit(1)
            records[relative] = tuple(fields[1:])
    return records
before = read_snapshot(before_path)
after = read_snapshot(after_path)
changed = sorted(path for path in set(before) | set(after) if before.get(path) != after.get(path))
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
for name in ("O_NOFOLLOW", "O_CLOEXEC", "O_BINARY"):
    flags |= getattr(os, name, 0)
descriptor = os.open(output_path, flags, 0o600)
try:
    if os.name == "posix":
        os.fchmod(descriptor, 0o600)
    for path in changed:
        data = path + b"\0"
        offset = 0
        while offset < len(data):
            written = os.write(descriptor, data[offset:])
            if written <= 0:
                raise OSError("changed-path write made no progress")
            offset += written
    os.fsync(descriptor)
finally:
    os.close(descriptor)
' "$before" "$after" "$output" || return 1
  cccc_consult_manifest_add "$output" 1 0
}

cccc_consult_parse_codex_json() {
  local source=$1 destination=$2
  "$CCCC_PYTHON" -I -c '
import json, os, stat, sys
source, destination = sys.argv[1:]

def is_reparse(value):
    return bool(
        getattr(value, "st_file_attributes", 0) & 0x400
        or getattr(value, "st_reparse_tag", 0)
    )

value = os.lstat(source)
if stat.S_ISLNK(value.st_mode) or is_reparse(value) or not stat.S_ISREG(value.st_mode):
    raise SystemExit(1)
messages = []
events = []
source_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
source_descriptor = os.open(source, source_flags)
try:
    opened = os.fstat(source_descriptor)
    if (not stat.S_ISREG(opened.st_mode) or is_reparse(opened)
            or (opened.st_dev, opened.st_ino) != (value.st_dev, value.st_ino)):
        raise SystemExit(1)
    with os.fdopen(source_descriptor, "rb", closefd=False) as stream:
        for raw in stream:
            if not raw.strip():
                continue
            try:
                event = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                raise SystemExit(1)
            if not isinstance(event, dict) or not isinstance(event.get("type"), str):
                raise SystemExit(1)
            events.append(event)
            if event["type"] == "item.completed":
                item = event.get("item")
                if isinstance(item, dict) and item.get("type") == "agent_message":
                    text = item.get("text")
                    if not isinstance(text, str) or not text:
                        raise SystemExit(1)
                    messages.append(text)
finally:
    os.close(source_descriptor)
if not messages or not events or events[-1].get("type") != "turn.completed":
    raise SystemExit(1)
data = messages[-1].encode("utf-8")
if not data.strip():
    raise SystemExit(1)
if not data.endswith(b"\n"):
    data += b"\n"
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
for name in ("O_NOFOLLOW", "O_CLOEXEC", "O_BINARY"):
    flags |= getattr(os, name, 0)
descriptor = os.open(destination, flags, 0o600)
try:
    if os.name == "posix":
        os.fchmod(descriptor, 0o600)
    offset = 0
    while offset < len(data):
        written = os.write(descriptor, data[offset:])
        if written <= 0:
            raise OSError("report write made no progress")
        offset += written
    os.fsync(descriptor)
finally:
    os.close(descriptor)
' "$source" "$destination" || return 1
  cccc_consult_manifest_add "$destination" 1 0
}

cccc_consult_path_hex() {
  "$CCCC_PYTHON" -I -c 'import os,sys; print(os.fsencode(sys.argv[1]).hex())' "$1"
}

cccc_consult_hash_file() {
  "$CCCC_PYTHON" -I -c \
    'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' \
    "$1"
}

cccc_consult_parse_runner_status() {
  local status=$1 runner_rc=$2 secret=${3:-$RUNNER_SECRET_HEX} parsed value
  CCCC_RUNNER_KIND=
  CCCC_RUNNER_VALUE=
  CCCC_RUNNER_STATUS_ID=
  parsed=$(printf '%s\n' "$secret" | "$CCCC_PYTHON" -I -c '
import hashlib
import hmac
import os
import re
import stat
import sys

path, runner_text = sys.argv[1:]

def is_reparse(value):
    return bool(
        getattr(value, "st_file_attributes", 0) & 0x400
        or getattr(value, "st_reparse_tag", 0)
    )

try:
    runner_rc = int(runner_text)
except ValueError:
    raise SystemExit(1)
secret_text = sys.stdin.readline().rstrip("\n")
if not re.fullmatch(r"[0-9a-f]{64}", secret_text):
    raise SystemExit(1)
secret = bytes.fromhex(secret_text)
try:
    before = os.lstat(path)
except OSError:
    raise SystemExit(1)
if stat.S_ISLNK(before.st_mode) or is_reparse(before) or not stat.S_ISREG(before.st_mode):
    raise SystemExit(1)
if os.name == "posix":
    if stat.S_IMODE(before.st_mode) != 0o600 or before.st_uid != os.geteuid():
        raise SystemExit(1)
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
descriptor = None
try:
    descriptor = os.open(path, flags)
    opened = os.fstat(descriptor)
    if not stat.S_ISREG(opened.st_mode) or is_reparse(opened):
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
match = re.fullmatch(
    r"cccc-timeout-result-v2 kind=([a-z-]+) value=(none|0|[1-9][0-9]*) "
    r"status_dev=(0|[1-9][0-9]*) status_ino=(0|[1-9][0-9]*) mac=([0-9a-f]{64})",
    line,
)
if match is None:
    raise SystemExit(1)
kind, value, status_dev, status_ino, supplied_mac = match.groups()
if (int(status_dev), int(status_ino)) != (before.st_dev, before.st_ino):
    raise SystemExit(1)
canonical = (
    "cccc-timeout-result-v2 kind=%s value=%s status_dev=%s status_ino=%s"
    % (kind, value, status_dev, status_ino)
).encode("ascii")
expected_mac = hmac.new(secret, canonical, hashlib.sha256).hexdigest()
if not hmac.compare_digest(supplied_mac, expected_mac):
    raise SystemExit(1)
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
        expected_rc = number
        if os.name == "nt":
            if number > 4294967295:
                raise SystemExit(1)
            if number > 255:
                expected_rc = 70
        if os.name != "nt" and number > 255:
            raise SystemExit(1)
        if runner_rc != expected_rc:
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
print(kind + "\t" + value + "\t" + status_dev + ":" + status_ino)
' "$status" "$runner_rc"
  ) || {
    cccc_die 'trusted runner status is missing, unsafe, malformed, or inconsistent'
    return 125
  }
  CCCC_RUNNER_KIND=${parsed%%$'\t'*}
  parsed=${parsed#*$'\t'}
  value=${parsed%%$'\t'*}
  CCCC_RUNNER_STATUS_ID=${parsed#*$'\t'}
  CCCC_RUNNER_VALUE=$value
  return 0
}

cccc_consult_copy_opinion() {
  local source=$1 destination=$2 expected
  cccc_consult_manifest_binding "$source" || return 1
  expected=$CCCC_CONSULT_MANIFEST_ID
  "$CCCC_PYTHON" -I -c '
import os, stat, sys
source, destination, expected = sys.argv[1:]
expected_identity = tuple(int(item) for item in expected.split(":", 1))
before = os.lstat(source)
if (stat.S_ISLNK(before.st_mode)
        or getattr(before, "st_file_attributes", 0) & 0x400
        or getattr(before, "st_reparse_tag", 0)
        or not stat.S_ISREG(before.st_mode)
        or (before.st_dev, before.st_ino) != expected_identity):
    raise SystemExit(1)
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
descriptor = os.open(source, flags)
try:
    opened = os.fstat(descriptor)
    if (opened.st_dev, opened.st_ino) != expected_identity:
        raise SystemExit(1)
    chunks = []
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        chunks.append(chunk)
    after = os.fstat(descriptor)
    if ((after.st_dev, after.st_ino) != expected_identity
            or (opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns)
            != (after.st_size, after.st_mtime_ns, after.st_ctime_ns)):
        raise SystemExit(1)
finally:
    os.close(descriptor)
data = b"".join(chunks)
if not data.strip():
    raise SystemExit(1)
out_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
for name in ("O_NOFOLLOW", "O_CLOEXEC", "O_BINARY"):
    out_flags |= getattr(os, name, 0)
output = os.open(destination, out_flags, 0o600)
try:
    if os.name == "posix":
        os.fchmod(output, 0o600)
    offset = 0
    while offset < len(data):
        written = os.write(output, data[offset:])
        if written <= 0:
            raise OSError("opinion write made no progress")
        offset += written
    os.fsync(output)
finally:
    os.close(output)
' "$source" "$destination" "$expected" || return 1
  cccc_consult_manifest_add "$destination" 1 0
}

cccc_consult_write_log() {
  local destination=$1 target=$2 mode=$3 timeout=$4 agent_rc=$5
  local head_before=$6 head_after=$7 status_before=$8 status_after=$9
  local changed_file=${10} agent_stdout=${11} agent_stderr=${12}
  "$CCCC_PYTHON" -I -c '
import hashlib, os, stat, sys
(
    destination, target, mode, timeout, agent_rc, runner_kind,
    head_before, head_after, status_before, status_after,
    changed_file, agent_stdout, agent_stderr,
) = sys.argv[1:]

def is_reparse(value):
    return bool(
        getattr(value, "st_file_attributes", 0) & 0x400
        or getattr(value, "st_reparse_tag", 0)
    )

def open_regular(path):
    before = os.lstat(path)
    if stat.S_ISLNK(before.st_mode) or is_reparse(before) or not stat.S_ISREG(before.st_mode):
        raise SystemExit(1)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    opened = os.fstat(descriptor)
    if (is_reparse(opened)
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)):
        os.close(descriptor)
        raise SystemExit(1)
    return descriptor

def read_regular(path):
    descriptor = open_regular(path)
    try:
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                return b"".join(chunks)
            chunks.append(chunk)
    finally:
        os.close(descriptor)

status_before_data = read_regular(status_before)
status_after_data = read_regular(status_after)
changed_data = read_regular(changed_file)
if changed_data and not changed_data.endswith(b"\0"):
    raise SystemExit(1)
changed = [item for item in changed_data.split(b"\0") if item]
stdout_data = read_regular(agent_stdout)
stderr_data = read_regular(agent_stderr)
header = [
    "cccc consult v2",
    "target=" + target,
    "mode=" + mode,
    "timeout=" + timeout,
    "agent_rc=" + agent_rc,
    "runner_kind=" + runner_kind,
    "baseline_policy=clean-or-fingerprinted-dirty",
    "audit_boundary=tracked and nonignored paths; ignored paths and Git metadata excluded",
    "head_before=" + head_before,
    "head_after=" + head_after,
    "status_before_sha256=" + hashlib.sha256(status_before_data).hexdigest(),
    "status_after_sha256=" + hashlib.sha256(status_after_data).hexdigest(),
]
header.extend("changed_path_hex=" + item.hex() for item in changed)
data = ("\n".join(header) + "\n=== agent stdout ===\n").encode("utf-8")
data += stdout_data + b"\n=== agent stderr ===\n" + stderr_data
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
for name in ("O_NOFOLLOW", "O_CLOEXEC", "O_BINARY"):
    flags |= getattr(os, name, 0)
descriptor = os.open(destination, flags, 0o600)
try:
    if os.name == "posix":
        os.fchmod(descriptor, 0o600)
    offset = 0
    while offset < len(data):
        written = os.write(descriptor, data[offset:])
        if written <= 0:
            raise OSError("log write made no progress")
        offset += written
    os.fsync(descriptor)
finally:
    os.close(descriptor)
' "$destination" "$target" "$mode" "$timeout" "$agent_rc" "$CCCC_RUNNER_KIND" \
    "$head_before" "$head_after" "$status_before" "$status_after" \
    "$changed_file" "$agent_stdout" "$agent_stderr" || return 1
  cccc_consult_manifest_add "$destination" 1 0
}

cccc_consult_main() {
  local target card workdir depth_rc environment_rc timeout_rc
  local card_rel card_abs opinion_destination log_destination
  local opinion_parent_identity log_parent_identity timeout_helper
  local dirty_status baseline_dirty head_before head_after
  local snapshot_before snapshot_after status_before status_after changed_file
  local card_identity_before card_identity_after
  local opinion_source log_source agent_stdout agent_stderr runner_status runner_token
  local private_mcp root_help exec_help features_file codex_effort feature
  local prompt runner_rc status_rc agent_rc policy_failed path path_hex
  local publication_rc
  local agent_argv=()
  local command_argv=()

  if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    cccc_consult_usage
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

  cccc_consult_validate_depth
  depth_rc=$?
  [ "$depth_rc" -eq 0 ] || return "$depth_rc"
  cccc_consult_environment
  environment_rc=$?
  [ "$environment_rc" -eq 0 ] || return "$environment_rc"
  case "$target" in claude|codex) ;; *) cccc_die 'target must be exactly claude or codex'; return 2 ;; esac
  cccc_consult_validate_effort "$target" || return 2
  cccc_consult_reject_git_redirects || return 2

  cccc_require_command git || return 127
  cccc_find_python3 || return 127
  timeout_helper="$SCRIPT_DIR/run-with-timeout.py"
  if [ ! -f "$timeout_helper" ] || [ -L "$timeout_helper" ]; then
    cccc_die 'portable timeout helper is missing or unsafe'
    return 127
  fi
  cccc_consult_validate_timeout_max "$timeout_helper"
  timeout_rc=$?
  [ "$timeout_rc" -eq 0 ] || return "$timeout_rc"

  cccc_resolve_repo "$workdir" || return 4
  cccc_validate_card "$card" docs/discussions || return 2
  cccc_consult_reject_allowed_block "$CCCC_CARD_ABS" || return $?
  card_rel=$CCCC_CARD_REL
  card_abs=$CCCC_CARD_ABS
  opinion_destination=${card_abs%.md}-$target-opinion.md
  log_destination=${card_abs%.md}-$target.log
  cccc_refuse_output_target "$opinion_destination" || return 5
  cccc_refuse_output_target "$log_destination" || return 5

  cccc_make_run_dir || return 5
  OWNED_RUN_DIR=$CCCC_RUN_DIR
  OWNED_RUN_DIR_ID=$(cccc_consult_directory_identity "$OWNED_RUN_DIR") || return 5
  cccc_consult_resolve_common_dir || return 4
  cccc_consult_acquire_repo_lock "$CCCC_CONSULT_COMMON_DIR" || return 5

  cccc_resolve_target_argv "$target" || return 127
  cccc_consult_create_private_cwd "$OWNED_RUN_DIR/cwd" || return 5

  snapshot_before="$OWNED_RUN_DIR/snapshot.before"
  snapshot_after="$OWNED_RUN_DIR/snapshot.after"
  status_before="$OWNED_RUN_DIR/status.before"
  status_after="$OWNED_RUN_DIR/status.after"
  changed_file="$OWNED_RUN_DIR/changed.z"
  card_identity_before="$OWNED_RUN_DIR/card.before"
  card_identity_after="$OWNED_RUN_DIR/card.after"
  opinion_source="$OWNED_RUN_DIR/opinion.md"
  log_source="$OWNED_RUN_DIR/consult.log"
  agent_stdout="$OWNED_RUN_DIR/agent.stdout"
  agent_stderr="$OWNED_RUN_DIR/agent.stderr"
  runner_status="$OWNED_RUN_DIR/runner.status"
  runner_token="$OWNED_RUN_DIR/runner.token"
  private_mcp="$OWNED_RUN_DIR/empty-mcp.json"
  root_help="$OWNED_RUN_DIR/codex-root.help"
  exec_help="$OWNED_RUN_DIR/codex-exec.help"
  features_file="$OWNED_RUN_DIR/codex-features.list"
  RUNNER_STATUS_PATH=$runner_status
  RUNNER_TOKEN_PATH=$runner_token
  cccc_consult_create_empty_file "$agent_stdout" || return 5
  cccc_consult_create_empty_file "$agent_stderr" || return 5

  if [ "$target" = claude ]; then
    cccc_consult_create_private_json "$private_mcp" || return 5
  else
    cccc_consult_preflight_codex "$timeout_helper" "$root_help" "$exec_help" \
      "$features_file" || return $?
  fi
  cccc_capture_destination_parent_identity "$opinion_destination" || return 5
  opinion_parent_identity=$CCCC_DESTINATION_PARENT_IDENTITY
  cccc_capture_destination_parent_identity "$log_destination" || return 5
  log_parent_identity=$CCCC_DESTINATION_PARENT_IDENTITY

  dirty_status=$(git -C "$CCCC_REPO_ROOT" status --porcelain=v1 --untracked-files=all --ignored=no) || {
    cccc_die 'cannot inspect Git worktree status'
    return 4
  }
  baseline_dirty=no
  if [ -n "$dirty_status" ]; then
    baseline_dirty=yes
    if [ "${CCCC_ALLOW_DIRTY-}" != 1 ]; then
      cccc_die 'Git worktree is dirty; set CCCC_ALLOW_DIRTY=1 only as an explicit escape hatch'
      return 4
    fi
    cccc_warn 'WARNING: dirty baseline admitted by CCCC_ALLOW_DIRTY=1; Git metadata and ignored paths remain outside the audit boundary'
  fi
  cccc_warn_ignored_audit_boundary

  head_before=$(cccc_git_head "$CCCC_REPO_ROOT") || return 4
  cccc_git_snapshot "$CCCC_REPO_ROOT" "$snapshot_before" || return 4
  cccc_consult_manifest_add "$snapshot_before" 1 0 || return 125
  cccc_consult_safe_git_status_z "$CCCC_REPO_ROOT" "$status_before" || return 4
  cccc_consult_capture_card_identity "$CCCC_REPO_ROOT" "$card_rel" "$card_identity_before" || return 4
  cccc_consult_manifest_add "$card_identity_before" 1 0 || return 125
  cccc_consult_create_runner_token "$runner_token" || return 125

  prompt="You are the cccc expert consult agent. Read the repository at $CCCC_REPO_ROOT and the discussion card at $card_abs, then return a self-contained Markdown opinion. The wrapper gives a restricted tool surface and audits tracked and nonignored Git-visible paths; it is not an OS sandbox. Do not write the repository or cause external side effects. Do not start background or detached processes, and do not use setsid; same-UID detached processes are not guaranteed to be contained. Ignored paths, .git metadata, same-UID-readable files, secrets, managed policy, auth material, and API credentials are not isolated. Do not invoke Claude, Codex, another agent, MCP connector, plugin, hook, browser, or network service. For an untrusted repository, use an external container and an isolated worktree. Give a clear conclusion, rationale, risks, and alternatives; do not promise consensus."
  if [ "$target" = claude ]; then
    agent_argv=(--safe-mode --tools Read,Glob,Grep --permission-mode dontAsk \
      --disable-slash-commands --no-session-persistence --no-chrome \
      --add-dir "$CCCC_REPO_ROOT" --mcp-config "$private_mcp" --strict-mcp-config \
      -p "$prompt")
    [ -z "$CCCC_CONSULT_MODEL" ] || agent_argv+=(--model "$CCCC_CONSULT_MODEL")
    [ -z "${CCCC_EFFORT-}" ] || agent_argv+=(--effort "$CCCC_EFFORT")
  else
    codex_effort=${CCCC_EFFORT:-xhigh}
    agent_argv=(-a never exec --json --ephemeral --sandbox read-only)
    if [ "$CCCC_CONSULT_CODEX_CONFIG_MODE" = strict ]; then
      agent_argv+=(--ignore-user-config)
    else
      cccc_warn 'Codex inherit mode may activate external MCP connector plugin hook provider side effects'
    fi
    agent_argv+=(--strict-config --ignore-rules --skip-git-repo-check -C "$OWNED_PRIVATE_CWD")
    if [ "$CCCC_CONSULT_CODEX_CONFIG_MODE" = strict ]; then
      agent_argv+=(-c 'model_provider="openai"')
    fi
    agent_argv+=(
      -c 'project_doc_max_bytes=0'
      -c 'skills.bundled.enabled=false'
      -c 'skills.include_instructions=false'
      -c "model_reasoning_effort=\"$codex_effort\""
      -c 'web_search="disabled"'
      -c 'tools.web_search=false'
      -c 'allow_login_shell=false'
      -c 'check_for_update_on_startup=false'
      -c 'analytics.enabled=false'
      -c 'feedback.enabled=false'
      -c 'notify=[]'
      -c 'otel.exporter="none"'
      -c 'otel.metrics_exporter="none"'
      -c 'otel.trace_exporter="none"'
      -c 'history.persistence="none"'
      -c 'shell_environment_policy.inherit="none"'
      -c 'shell_environment_policy.ignore_default_excludes=false'
    )
    [ -z "$CCCC_CONSULT_MODEL" ] || agent_argv+=(--model "$CCCC_CONSULT_MODEL")
    while IFS= read -r feature; do
      [ -n "$feature" ] || continue
      agent_argv+=(--disable "$feature")
    done <<EOF
$CCCC_CONSULT_CODEX_FEATURES
EOF
    agent_argv+=("$prompt")
  fi
  command_argv=("$CCCC_PYTHON" -I "$timeout_helper" --status-file "$runner_status" \
    --status-token-file "$runner_token" "$CCCC_CONSULT_TIMEOUT" --)
  command_argv+=("${CCCC_TARGET_ARGV[@]}")
  command_argv+=("${agent_argv[@]}")

  runner_rc=0
  PENDING_SIGNAL_NUMBER=
  PENDING_SIGNAL_NAME=
  trap 'cccc_consult_defer_signal 1 HUP' HUP
  trap 'cccc_consult_defer_signal 2 INT' INT
  trap 'cccc_consult_defer_signal 15 TERM' TERM
  (
    trap - HUP INT TERM
    cd "$OWNED_PRIVATE_CWD" || exit 127
    unset BASH_ENV ENV
    if [ "$target" = claude ]; then
      DELEGATE_DEPTH=1 DISABLE_AUTOUPDATER=1 \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 exec "${command_argv[@]}"
    else
      DELEGATE_DEPTH=1 exec "${command_argv[@]}"
    fi
  ) >"$agent_stdout" 2>"$agent_stderr" &
  RUNNER_PID=$!
  trap 'cccc_consult_on_signal 1 HUP' HUP
  trap 'cccc_consult_on_signal 2 INT' INT
  trap 'cccc_consult_on_signal 15 TERM' TERM
  if [ -n "$PENDING_SIGNAL_NAME" ]; then
    cccc_consult_on_signal "$PENDING_SIGNAL_NUMBER" "$PENDING_SIGNAL_NAME"
  fi
  wait "$RUNNER_PID" || runner_rc=$?
  RUNNER_PID=

  cccc_consult_remove_private_cwd || {
    cccc_die 'private agent cwd cleanup failed'
    return 125
  }
  if [ -e "$runner_token" ] || [ -L "$runner_token" ]; then
    cccc_die 'trusted runner token was not safely consumed before child launch'
    return 125
  fi
  cccc_consult_manifest_remove "${runner_token##*/}"
  if ! cccc_consult_verify_post_child_namespace; then
    cccc_die 'owned run directory identity, baseline, or namespace changed during execution'
    return 125
  fi
  cccc_consult_parse_runner_status "$runner_status" "$runner_rc"
  status_rc=$?
  if [ "$status_rc" -ne 0 ]; then
    CCCC_RUNNER_KIND=invalid
    CCCC_RUNNER_VALUE=none
  elif ! cccc_consult_manifest_add "$runner_status" 1 0 "$CCCC_RUNNER_STATUS_ID"; then
    cccc_die 'cannot register trusted runner status identity'
    return 125
  fi
  case "$CCCC_RUNNER_KIND" in
    child-exit) agent_rc=$CCCC_RUNNER_VALUE ;;
    child-signal) agent_rc="signal-$CCCC_RUNNER_VALUE" ;;
    *) agent_rc=$runner_rc ;;
  esac

  policy_failed=0
  if ! cccc_validate_card "$card_rel" docs/discussions; then
    cccc_die 'discussion card or one of its ancestors changed physical identity'
    policy_failed=1
  elif ! cccc_consult_capture_card_identity "$CCCC_REPO_ROOT" "$card_rel" "$card_identity_after"; then
    cccc_die 'cannot revalidate discussion card identity'
    policy_failed=1
  elif ! cccc_consult_manifest_add "$card_identity_after" 1 0; then
    cccc_die 'cannot register post-run card identity artifact'
    return 125
  elif ! cmp -s -- "$card_identity_before" "$card_identity_after"; then
    cccc_die 'discussion card content or ancestor identity changed during consultation'
    policy_failed=1
  fi

  head_after=$(cccc_git_head "$CCCC_REPO_ROOT" 2>/dev/null || true)
  if [ -z "$head_after" ] || [ "$head_after" != "$head_before" ]; then
    cccc_die "HEAD changed during consultation: $head_before -> ${head_after:-<unreadable>}"
    policy_failed=1
  fi
  if ! cccc_git_snapshot "$CCCC_REPO_ROOT" "$snapshot_after"; then
    cccc_die 'cannot capture post-run Git snapshot'
    policy_failed=1
  elif ! cccc_consult_manifest_add "$snapshot_after" 1 0; then
    cccc_die 'cannot register post-run Git snapshot artifact'
    return 125
  fi
  if ! cccc_consult_safe_git_status_z "$CCCC_REPO_ROOT" "$status_after"; then
    cccc_die 'cannot capture post-run Git status'
    policy_failed=1
  fi
  if [ -f "$snapshot_after" ] && ! cccc_consult_safe_changed_paths "$snapshot_before" "$snapshot_after" "$changed_file"; then
    cccc_die 'cannot compare pre-run and post-run Git snapshots'
    policy_failed=1
  fi
  if [ ! -f "$changed_file" ]; then
    cccc_die 'post-run changed-path artifact is unavailable'
    return 125
  fi
  while IFS= read -r -d '' path; do
    path_hex=$(cccc_consult_path_hex "$path" 2>/dev/null || printf '<unavailable>')
    cccc_die "Git-visible path changed during read-only consultation: path_hex=$path_hex"
    policy_failed=1
  done <"$changed_file"

  if [ "$status_rc" -ne 0 ]; then
    cat -- "$agent_stderr" >&2
    cccc_die "trusted runner outcome failed closed: raw agent_rc=$runner_rc"
    return 125
  fi
  cccc_warn "runner outcome: kind=$CCCC_RUNNER_KIND raw agent_rc=$agent_rc"
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

  if [ "$target" = codex ]; then
    if ! cccc_consult_parse_codex_json "$agent_stdout" "$opinion_source"; then
      cccc_die 'Codex JSON stream lacks a safe final agent message and turn completion'
      return 5
    fi
  elif ! cccc_consult_copy_opinion "$agent_stdout" "$opinion_source"; then
    cccc_die 'Claude returned no safe non-empty opinion'
    return 5
  fi
  if [ ! -f "$opinion_source" ] || [ -L "$opinion_source" ] || [ ! -s "$opinion_source" ]; then
    cccc_die 'consult agent returned no fresh non-empty regular opinion'
    return 5
  fi
  cccc_consult_write_log "$log_source" "$target" read-only \
    "$CCCC_CONSULT_TIMEOUT" "$agent_rc" "$head_before" "$head_after" \
    "$status_before" "$status_after" "$changed_file" "$agent_stdout" "$agent_stderr" || {
      cccc_die 'cannot construct consult log'
      return 5
    }

  if ! cccc_validate_card "$card_rel" docs/discussions ||
    ! cccc_consult_capture_card_identity "$CCCC_REPO_ROOT" "$card_rel" "$OWNED_RUN_DIR/card.publish" ||
    ! cccc_consult_manifest_add "$OWNED_RUN_DIR/card.publish" 1 0 ||
    ! cmp -s -- "$card_identity_before" "$OWNED_RUN_DIR/card.publish"; then
    cccc_die 'discussion card or ancestor changed before publication'
    return 4
  fi
  cccc_refuse_output_target "$opinion_destination" || return 5
  cccc_refuse_output_target "$log_destination" || return 5
  PUBLICATION_LOG_DESTINATION=$log_destination
  PUBLICATION_OPINION_DESTINATION=$opinion_destination
  PUBLICATION_PHASE=log
  cccc_consult_publish_manifest_source \
    "$log_source" "$log_destination" "$log_parent_identity" || return 5
  PUBLICATION_PHASE=opinion
  cccc_consult_publish_manifest_source \
    "$opinion_source" "$opinion_destination" "$opinion_parent_identity"
  publication_rc=$?
  if [ "$publication_rc" -ne 0 ]; then
    cccc_die "opinion publication failed after log commit; orphan log requires manual cleanup: remove $log_destination before retry"
    return 5
  fi

  cccc_consult_release_lock || {
    cccc_die 'repository lock cleanup failed after publication'
    return 125
  }
  cccc_consult_remove_run_dir || {
    cccc_die 'owned run directory cleanup failed after publication'
    return 125
  }

  trap '' HUP INT TERM
  printf 'cccc: consult opinion: %s\ncccc: consult log: %s\n' \
    "$opinion_destination" "$log_destination"
  PUBLICATION_PHASE=
  PUBLICATION_LOG_DESTINATION=
  PUBLICATION_OPINION_DESTINATION=
  return 0
}

cccc_consult_main "$@"
exit $?
