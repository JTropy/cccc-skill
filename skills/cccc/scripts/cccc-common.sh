#!/usr/bin/env bash
# Shared validation and publication primitives for cccc wrappers.
# This file is sourced; it deliberately installs no traps and calls no exit.

CCCC_COMMON_DIR=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || return 1
CCCC_TARGET_ARGV=()
CCCC_ALLOWED_PATHS=()
CCCC_ALLOWED_PATHS_COUNT=0

cccc_die() {
  printf 'cccc: error: %s\n' "$*" >&2
  return 1
}

cccc_warn() {
  printf 'cccc: warning: %s\n' "$*" >&2
  return 0
}

cccc_require_command() {
  local name=${1-}
  if [ -z "$name" ] || ! command -v "$name" >/dev/null 2>&1; then
    cccc_die "required command not found: ${name:-<empty>}"
    return 1
  fi
  return 0
}

cccc_validate_depth() {
  case ${1-} in
    ''|0) return 0 ;;
    *)
      cccc_die 'DELEGATE_DEPTH must be unset or exactly 0'
      return 1
      ;;
  esac
}

cccc_validate_timeout() {
  local value=${1-}
  case "$value" in
    0|[1-9]|[1-9][0-9]*)
      case "$value" in
        *[!0-9]*) ;;
        *) return 0 ;;
      esac
      ;;
  esac
  cccc_die 'timeout must be 0 or a positive decimal integer'
  return 1
}

cccc_find_python3() {
  local candidate path
  CCCC_PYTHON=
  for candidate in python3 python; do
    path=$(type -P "$candidate" 2>/dev/null || true)
    if [ -n "$path" ] && "$path" -I -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
      CCCC_PYTHON=$path
      return 0
    fi
  done
  cccc_die 'Python 3 is required (looked for python3, then python)'
  return 1
}

_cccc_is_windows_git_bash() {
  case ${MSYSTEM-} in
    MINGW*|MSYS*|UCRT*) return 0 ;;
  esac
  case ${OSTYPE-} in
    msys*|cygwin*|win32*) return 0 ;;
  esac
  return 1
}

_cccc_executable_path() {
  local path
  path=$(type -P "$1" 2>/dev/null || true)
  if [ -n "$path" ] && [ -f "$path" ] && [ -x "$path" ]; then
    printf '%s\n' "$path"
    return 0
  fi
  return 1
}

_cccc_is_posix_shim() {
  local path=$1 first_line
  [ -f "$path" ] && [ -x "$path" ] && [ ! -L "$path" ] || return 1
  IFS= read -r first_line <"$path" || [ -n "$first_line" ] || return 1
  first_line=${first_line%$'\r'}
  case "$first_line" in
    '#!/bin/sh'|'#!/bin/bash'|'#!/usr/bin/sh'|'#!/usr/bin/bash'|'#!/usr/bin/env sh'|'#!/usr/bin/env bash')
      return 0
      ;;
  esac
  return 1
}

_cccc_is_batch_path() {
  case ${1-} in
    *.[cC][mM][dD]|*.[bB][aA][tT]) return 0 ;;
  esac
  return 1
}

cccc_resolve_target_argv() {
  local target=${1-} resolved
  CCCC_TARGET_ARGV=()
  case "$target" in
    claude|codex) ;;
    *)
      cccc_die 'target must be exactly claude or codex'
      return 1
      ;;
  esac

  if _cccc_is_windows_git_bash; then
    _cccc_resolve_windows_target_argv "$target"
    return $?
  fi

  resolved=$(_cccc_executable_path "$target" || true)
  if [ -z "$resolved" ]; then
    cccc_die "target command not found: $target"
    return 1
  fi
  CCCC_TARGET_ARGV=("$resolved")
  return 0
}

_cccc_resolve_windows_target_argv() {
  local target=$1 remaining=${PATH-} segment more directory candidate
  while :; do
    case "$remaining" in
      *:*)
        segment=${remaining%%:*}
        remaining=${remaining#*:}
        more=1
        ;;
      *)
        segment=$remaining
        remaining=
        more=0
        ;;
    esac
    [ -n "$segment" ] || segment=.
    directory=$(CDPATH= cd -P -- "$segment" 2>/dev/null && pwd) || directory=
    if [ -n "$directory" ]; then
      candidate="$directory/${target}.exe"
      if [ -e "$candidate" ] || [ -L "$candidate" ]; then
        if [ -f "$candidate" ] && [ -x "$candidate" ]; then
          CCCC_TARGET_ARGV=("$candidate")
          return 0
        fi
        cccc_die "$target has an invalid native executable in the first matching PATH directory"
        return 1
      fi

      candidate="$directory/$target"
      if [ -e "$candidate" ] || [ -L "$candidate" ]; then
        if _cccc_is_posix_shim "$candidate"; then
          CCCC_TARGET_ARGV=(bash "$candidate")
          return 0
        fi
        cccc_die "$target has an invalid extensionless entry in the first matching PATH directory"
        return 1
      fi

      candidate="$directory/${target}.com"
      if [ -e "$candidate" ] || [ -L "$candidate" ]; then
        cccc_die "$target has an unsupported .com entry in the first matching PATH directory"
        return 1
      fi
      candidate="$directory/${target}.cmd"
      if [ -e "$candidate" ] || [ -L "$candidate" ]; then
        cccc_die "batch-only $target entry point is not supported"
        return 1
      fi
      candidate="$directory/${target}.bat"
      if [ -e "$candidate" ] || [ -L "$candidate" ]; then
        cccc_die "batch-only $target entry point is not supported"
        return 1
      fi
    fi
    [ "$more" -eq 1 ] || break
  done
  cccc_die "target command not found: $target"
  return 1
}

cccc_resolve_repo() {
  local workdir=${1:-.} physical inside top root
  CCCC_REPO_ROOT=
  if [ ! -d "$workdir" ]; then
    cccc_die "workdir is not a directory: $workdir"
    return 1
  fi
  physical=$(CDPATH= cd -P -- "$workdir" 2>/dev/null && pwd) || {
    cccc_die "cannot resolve workdir: $workdir"
    return 1
  }
  inside=$(git -C "$physical" rev-parse --is-inside-work-tree 2>/dev/null || true)
  if [ "$inside" != true ]; then
    cccc_die "workdir is not inside a Git worktree: $workdir"
    return 1
  fi
  top=$(git -C "$physical" rev-parse --show-toplevel 2>/dev/null) || {
    cccc_die "cannot resolve Git worktree root: $workdir"
    return 1
  }
  root=$(CDPATH= cd -P -- "$top" 2>/dev/null && pwd) || {
    cccc_die "cannot resolve physical Git worktree root: $top"
    return 1
  }
  CCCC_REPO_ROOT=$root
  return 0
}

_cccc_relative_path_is_safe() {
  local path=${1-}
  [ -n "$path" ] || return 1
  case "$path" in
    /*|\\*|[A-Za-z]:*|*\\*|*'//'*) return 1 ;;
  esac
  case "/$path/" in
    */./*|*/../*) return 1 ;;
  esac
  return 0
}

_cccc_path_has_symlink_component() {
  local root=$1 relative=$2 current=$1 component remainder=$2
  while :; do
    case "$remainder" in
      */*)
        component=${remainder%%/*}
        remainder=${remainder#*/}
        ;;
      *)
        component=$remainder
        remainder=
        ;;
    esac
    current="$current/$component"
    [ -L "$current" ] && return 0
    [ -n "$remainder" ] || break
  done
  return 1
}

cccc_validate_card() {
  local card=${1-} expected_root=${2-} expected_dir expected_physical
  local card_path card_dir card_dir_physical card_name
  CCCC_CARD_REL=
  CCCC_CARD_ABS=
  case "$expected_root" in
    docs/tasks|docs/discussions) ;;
    *)
      cccc_die 'expected card root must be docs/tasks or docs/discussions'
      return 1
      ;;
  esac
  if [ -z "${CCCC_REPO_ROOT-}" ] || [ ! -d "$CCCC_REPO_ROOT" ]; then
    cccc_die 'repository root has not been resolved'
    return 1
  fi
  if ! _cccc_relative_path_is_safe "$card"; then
    cccc_die "card path must be a safe repository-relative path: $card"
    return 1
  fi
  case "$card" in
    "$expected_root"/*.md) ;;
    *)
      cccc_die "card must be a Markdown file under $expected_root/"
      return 1
      ;;
  esac

  if _cccc_path_has_symlink_component "$CCCC_REPO_ROOT" "$card"; then
    cccc_die "card path must not contain symlink components: $card"
    return 1
  fi

  expected_dir="$CCCC_REPO_ROOT/$expected_root"
  if [ ! -d "$expected_dir" ] || [ -L "$expected_dir" ]; then
    cccc_die "card root is missing or is a symlink: $expected_root"
    return 1
  fi
  expected_physical=$(CDPATH= cd -P -- "$expected_dir" 2>/dev/null && pwd) || return 1
  if [ "$expected_physical" != "$expected_dir" ]; then
    cccc_die "card root does not resolve to its physical repository location: $expected_root"
    return 1
  fi

  card_path="$CCCC_REPO_ROOT/$card"
  if [ -L "$card_path" ] || [ ! -f "$card_path" ]; then
    cccc_die "card must be a regular, non-symlink file: $card"
    return 1
  fi
  card_dir=$(dirname -- "$card_path")
  card_dir_physical=$(CDPATH= cd -P -- "$card_dir" 2>/dev/null && pwd) || {
    cccc_die "cannot resolve card directory: $card"
    return 1
  }
  case "$card_dir_physical/" in
    "$expected_physical/"*) ;;
    *)
      cccc_die "card resolves outside $expected_root/: $card"
      return 1
      ;;
  esac
  card_name=$(basename -- "$card_path")
  CCCC_CARD_REL=$card
  CCCC_CARD_ABS="$card_dir_physical/$card_name"
  return 0
}

cccc_make_run_dir() {
  local temp_root=${TMPDIR:-/tmp} run_dir
  CCCC_RUN_DIR=
  if [ ! -d "$temp_root" ]; then
    cccc_die "temporary directory root does not exist: $temp_root"
    return 1
  fi
  run_dir=$(umask 077 && mktemp -d "$temp_root/cccc.XXXXXXXX") || {
    cccc_die "cannot create private run directory under $temp_root"
    return 1
  }
  if ! chmod 700 "$run_dir"; then
    rmdir -- "$run_dir" 2>/dev/null || true
    cccc_die 'cannot enforce mode 700 on private run directory'
    return 1
  fi
  CCCC_RUN_DIR=$run_dir
  return 0
}

cccc_refuse_output_target() {
  local destination=${1-}
  if [ -z "$destination" ]; then
    cccc_die 'output destination is empty'
    return 1
  fi
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    cccc_die "output destination already exists: $destination"
    return 1
  fi
  return 0
}

cccc_acquire_claim() {
  local claim=${1-}
  CCCC_CLAIM_DIR=
  if [ -z "$claim" ]; then
    cccc_die 'claim path is empty'
    return 1
  fi
  if ! (umask 077 && mkdir -- "$claim") 2>/dev/null; then
    cccc_die "publication claim is already held or unavailable: $claim"
    return 5
  fi
  if ! chmod 700 "$claim"; then
    rmdir -- "$claim" 2>/dev/null || true
    cccc_die "cannot enforce mode 700 on publication claim: $claim"
    return 5
  fi
  CCCC_CLAIM_DIR=$claim
  return 0
}

cccc_atomic_publish() {
  local source=${1-} destination=${2-} parent_identity=${3-}
  local source_identity=${4-} source_digest=${5-}
  if [ -z "$source" ] || [ -z "$destination" ] || [ "$#" -lt 2 ] || [ "$#" -gt 5 ]; then
    cccc_die 'atomic publish requires source and destination'
    return 1
  fi
  cccc_find_python3 || return 1
  if [ "$#" -ge 3 ]; then
    [ -n "$parent_identity" ] || {
      cccc_die 'destination parent identity must not be empty'
      return 1
    }
  fi
  if [ "$#" -ge 4 ]; then
    [ -n "$source_identity" ] || {
      cccc_die 'source identity must not be empty'
      return 1
    }
  fi
  if [ "$#" -eq 5 ]; then
    [ -n "$source_digest" ] || {
      cccc_die 'source digest must not be empty'
      return 1
    }
  fi
  case "$#" in
    2)
      "$CCCC_PYTHON" -I "$CCCC_COMMON_DIR/publish-no-clobber.py" "$source" "$destination"
      ;;
    3)
      "$CCCC_PYTHON" -I "$CCCC_COMMON_DIR/publish-no-clobber.py" \
        --parent-identity "$parent_identity" "$source" "$destination"
      ;;
    4)
      "$CCCC_PYTHON" -I "$CCCC_COMMON_DIR/publish-no-clobber.py" \
        --parent-identity "$parent_identity" --source-identity "$source_identity" \
        "$source" "$destination"
      ;;
    5)
      "$CCCC_PYTHON" -I "$CCCC_COMMON_DIR/publish-no-clobber.py" \
        --parent-identity "$parent_identity" --source-identity "$source_identity" \
        --source-sha256 "$source_digest" "$source" "$destination"
      ;;
  esac
}

cccc_capture_destination_parent_identity() {
  local destination=${1-} identity
  CCCC_DESTINATION_PARENT_IDENTITY=
  if [ -z "$destination" ] || [ "$#" -ne 1 ]; then
    cccc_die 'destination parent identity capture requires one destination'
    return 1
  fi
  cccc_find_python3 || return 1
  identity=$("$CCCC_PYTHON" -I "$CCCC_COMMON_DIR/publish-no-clobber.py" \
    --print-parent-identity "$destination") || return $?
  case "$identity" in
    *:*) ;;
    *)
      cccc_die 'publisher returned an invalid destination parent identity'
      return 5
      ;;
  esac
  CCCC_DESTINATION_PARENT_IDENTITY=$identity
  return 0
}

cccc_git_head() {
  local repo=${1:-${CCCC_REPO_ROOT-}} head
  if [ -z "$repo" ] || [ "$(git -C "$repo" rev-parse --is-inside-work-tree 2>/dev/null || true)" != true ]; then
    cccc_die 'cannot read HEAD outside a Git worktree'
    return 1
  fi
  head=$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null || true)
  if [ -n "$head" ]; then
    printf '%s\n' "$head"
  else
    printf '%s\n' 'CCCC_UNBORN_HEAD'
  fi
}

cccc_git_snapshot() {
  local repo=${1-} output=${2-}
  [ -n "$repo" ] && [ -n "$output" ] || {
    cccc_die 'git snapshot requires repository and output file'
    return 1
  }
  cccc_find_python3 || return 1
  "$CCCC_PYTHON" -I - "$repo" "$output" <<'PY'
import hashlib
import os
import stat
import subprocess
import sys
import tempfile

root, output = sys.argv[1:]
try:
    os.unlink(output)
except FileNotFoundError:
    pass
except OSError as error:
    print("cccc snapshot: cannot clear previous output: %s" % error, file=sys.stderr)
    raise SystemExit(5)

result = subprocess.run(
    ["git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=False,
)
if result.returncode:
    sys.stderr.buffer.write(result.stderr)
    raise SystemExit(result.returncode)

index_result = subprocess.run(
    ["git", "-C", root, "ls-files", "-z", "--stage"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=False,
)
if index_result.returncode:
    sys.stderr.buffer.write(index_result.stderr)
    raise SystemExit(index_result.returncode)
index_records = {}
for record in (item for item in index_result.stdout.split(b"\0") if item):
    if b"\t" not in record:
        raise SystemExit("invalid NUL-safe Git index record")
    metadata, relative = record.split(b"\t", 1)
    if metadata.split(b" ", 1)[0] == b"160000":
        print(
            "cccc snapshot: submodule/gitlink paths are unsupported: %r"
            % os.fsdecode(relative),
            file=sys.stderr,
        )
        raise SystemExit(5)
    index_records.setdefault(relative, []).append(metadata)

root_bytes = os.fsencode(root)

def fingerprint(relative):
    full = os.path.join(root_bytes, relative)
    try:
        before = os.lstat(full)
    except FileNotFoundError:
        return b"missing", hashlib.sha256(b"").hexdigest().encode("ascii")

    mode = before.st_mode
    permissions = (mode & 0o7777)
    if stat.S_ISREG(mode):
        flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(full, flags)
        try:
            opened = os.fstat(descriptor)
            if not stat.S_ISREG(opened.st_mode):
                raise RuntimeError("Git-visible path changed type during snapshot")
            if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
                raise RuntimeError("Git-visible path changed during snapshot")
            digest = hashlib.sha256()
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
            after = os.fstat(descriptor)
            stable_before = (opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns)
            stable_after = (after.st_size, after.st_mtime_ns, after.st_ctime_ns)
            if stable_before != stable_after:
                raise RuntimeError("Git-visible file changed while being fingerprinted")
            return ("regular:%04o" % permissions).encode("ascii"), digest.hexdigest().encode("ascii")
        finally:
            os.close(descriptor)
    if stat.S_ISLNK(mode):
        target = os.readlink(full)
        if not isinstance(target, bytes):
            target = os.fsencode(target)
        return b"symlink", hashlib.sha256(target).hexdigest().encode("ascii")
    if stat.S_ISFIFO(mode):
        kind = b"fifo"
    elif stat.S_ISDIR(mode):
        print(
            "cccc snapshot: nested repositories or enumerated directories are unsupported: %r"
            % os.fsdecode(relative),
            file=sys.stderr,
        )
        raise SystemExit(5)
    elif stat.S_ISSOCK(mode):
        kind = b"socket"
    elif stat.S_ISCHR(mode):
        kind = b"character"
    elif stat.S_ISBLK(mode):
        kind = b"block"
    else:
        kind = b"other"
    return kind + (b":%04o" % permissions), hashlib.sha256(b"").hexdigest().encode("ascii")

paths = sorted(set(path for path in result.stdout.split(b"\0") if path))
snapshot_records = []
for relative in paths:
    kind, digest = fingerprint(relative)
    index_state = b"|".join(sorted(index_records.get(relative, [b"untracked"])))
    snapshot_records.append(
        relative.hex().encode("ascii")
        + b"\t" + kind
        + b"\t" + digest
        + b"\t" + index_state.hex().encode("ascii")
        + b"\n"
    )

output_directory = os.path.dirname(os.path.abspath(output))
temporary_fd = None
temporary_path = None
try:
    temporary_fd, temporary_path = tempfile.mkstemp(
        prefix=".cccc-snapshot-", dir=output_directory
    )
    with os.fdopen(temporary_fd, "wb", closefd=True) as stream:
        temporary_fd = None
        for record in snapshot_records:
            stream.write(record)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary_path, output)
    temporary_path = None
finally:
    if temporary_fd is not None:
        os.close(temporary_fd)
    if temporary_path is not None:
        try:
            os.unlink(temporary_path)
        except FileNotFoundError:
            pass
PY
}

cccc_snapshot_equal() {
  local before=${1-} after=${2-}
  [ -f "$before" ] && [ -f "$after" ] || return 1
  cmp -s -- "$before" "$after"
}

cccc_snapshot_changed_paths() {
  local before=${1-} after=${2-} output=${3-}
  [ -f "$before" ] && [ -f "$after" ] && [ -n "$output" ] || {
    cccc_die 'changed-path comparison requires two snapshots and an output file'
    return 1
  }
  cccc_find_python3 || return 1
  "$CCCC_PYTHON" -I - "$before" "$after" "$output" <<'PY'
import os
import sys

before_path, after_path, output_path = sys.argv[1:]

def read_snapshot(path):
    records = {}
    with open(path, "rb") as stream:
        for number, raw_line in enumerate(stream, 1):
            fields = raw_line.rstrip(b"\n").split(b"\t")
            if len(fields) != 4:
                raise SystemExit("invalid snapshot record at line %d" % number)
            try:
                relative = bytes.fromhex(fields[0].decode("ascii"))
            except (UnicodeDecodeError, ValueError):
                raise SystemExit("invalid snapshot path at line %d" % number)
            if not relative or b"\0" in relative or relative in records:
                raise SystemExit("invalid or duplicate snapshot path at line %d" % number)
            records[relative] = (fields[1], fields[2], fields[3])
    return records

before = read_snapshot(before_path)
after = read_snapshot(after_path)
changed = sorted(path for path in set(before) | set(after) if before.get(path) != after.get(path))
with open(output_path, "wb") as stream:
    for path in changed:
        stream.write(path + b"\0")
    stream.flush()
    os.fsync(stream.fileno())
PY
}

cccc_git_status_z() {
  local repo=${1-} output=${2-}
  [ -n "$repo" ] && [ -n "$output" ] || {
    cccc_die 'git status requires repository and output file'
    return 1
  }
  git -C "$repo" status --porcelain=v1 -z --untracked-files=all --ignored=no >"$output"
}

cccc_git_has_ignored_paths() {
  local repo=${1:-${CCCC_REPO_ROOT-}}
  [ -n "$repo" ] || return 1
  cccc_find_python3 || return 1
  "$CCCC_PYTHON" -I - "$repo" <<'PY'
import subprocess
import sys

result = subprocess.run(
    ["git", "-C", sys.argv[1], "ls-files", "-z", "--others", "--ignored", "--exclude-standard"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=False,
)
if result.returncode:
    sys.stderr.buffer.write(result.stderr)
    raise SystemExit(result.returncode)
raise SystemExit(0 if result.stdout else 1)
PY
}

cccc_warn_ignored_audit_boundary() {
  cccc_warn 'Git metadata and Git-ignored paths are outside the cccc Git-visible audit boundary'
}

_cccc_validate_policy_path() {
  local path=${1-}
  _cccc_relative_path_is_safe "$path" || return 1
  case "$path" in
    ' '*|*' '|*$'\t'*|*:*|*'*'*|*'?'*|*'['*|*']'*) return 1 ;;
  esac
  return 0
}

_cccc_is_git_metadata_path() {
  local path=${1-} component remainder
  remainder=$path
  while :; do
    case "$remainder" in
      */*)
        component=${remainder%%/*}
        remainder=${remainder#*/}
        ;;
      *)
        component=$remainder
        remainder=
        ;;
    esac
    while :; do
      case "$component" in
        *' '|*.) component=${component%?} ;;
        *) break ;;
      esac
    done
    case "$component" in
      .[gG][iI][tT]|[gG][iI][tT]'~1') return 0 ;;
    esac
    [ -n "$remainder" ] || break
  done
  return 1
}

_cccc_validate_allowed_path_physical() {
  local rule=$1 relative=$1 directory_rule=0 current remainder component candidate
  local candidate_physical more
  if [ -z "${CCCC_REPO_ROOT-}" ] || [ ! -d "$CCCC_REPO_ROOT" ]; then
    cccc_die 'repository root must be resolved before parsing allowed paths'
    return 1
  fi
  case "$relative" in
    */)
      directory_rule=1
      relative=${relative%/}
      ;;
  esac
  [ -n "$relative" ] || return 1
  current=$CCCC_REPO_ROOT
  remainder=$relative
  while :; do
    case "$remainder" in
      */*)
        component=${remainder%%/*}
        remainder=${remainder#*/}
        more=1
        ;;
      *)
        component=$remainder
        remainder=
        more=0
        ;;
    esac
    candidate="$current/$component"
    if [ -L "$candidate" ]; then
      cccc_die "allowed path contains a symlink component: $rule"
      return 1
    fi
    if [ -e "$candidate" ]; then
      if [ -d "$candidate" ]; then
        candidate_physical=$(CDPATH= cd -P -- "$candidate" 2>/dev/null && pwd) || return 1
        case "$candidate_physical/" in
          "$CCCC_REPO_ROOT/"*) ;;
          *)
            cccc_die "allowed path resolves outside the repository: $rule"
            return 1
            ;;
        esac
        if [ "$more" -eq 0 ] && [ "$directory_rule" -eq 0 ]; then
          cccc_die "existing allowed directory requires a trailing slash: $rule"
          return 1
        fi
        current=$candidate_physical
      elif [ -f "$candidate" ]; then
        if [ "$more" -eq 1 ] || [ "$directory_rule" -eq 1 ]; then
          cccc_die "allowed file cannot be used as a directory prefix: $rule"
          return 1
        fi
      else
        cccc_die "allowed path has an unsupported existing file type: $rule"
        return 1
      fi
    else
      return 0
    fi
    [ "$more" -eq 1 ] || return 0
  done
}

cccc_parse_allowed_paths() {
  local card=${1-} line in_block=0 blocks=0 count=0
  local parsed_paths=()
  CCCC_ALLOWED_PATHS=()
  CCCC_ALLOWED_PATHS_COUNT=0
  if [ ! -f "$card" ] || [ -L "$card" ]; then
    cccc_die 'allowed-path policy source must be a regular, non-symlink card'
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    if [ "$line" = '<!-- cccc-allowed-paths' ]; then
      if [ "$in_block" -ne 0 ] || [ "$blocks" -ne 0 ]; then
        cccc_die 'task card must contain exactly one allowed-paths block'
        return 1
      fi
      in_block=1
      blocks=1
      continue
    fi
    if [ "$line" = '-->' ] && [ "$in_block" -eq 1 ]; then
      in_block=0
      continue
    fi
    if [ "$in_block" -eq 1 ]; then
      if ! _cccc_validate_policy_path "$line"; then
        cccc_die "invalid allowed path: $line"
        return 1
      fi
      if _cccc_is_git_metadata_path "$line"; then
        cccc_die "Git metadata cannot be an allowed path: $line"
        return 1
      fi
      if ! _cccc_validate_allowed_path_physical "$line"; then
        return 1
      fi
      parsed_paths[$count]=$line
      count=$((count + 1))
    fi
  done <"$card"

  if [ "$blocks" -ne 1 ] || [ "$in_block" -ne 0 ] || [ "$count" -eq 0 ]; then
    cccc_die 'task card requires one non-empty, closed allowed-paths block'
    return 1
  fi
  CCCC_ALLOWED_PATHS=("${parsed_paths[@]}")
  CCCC_ALLOWED_PATHS_COUNT=$count
  cccc_warn 'allowed paths are a post-run Git audit boundary, not OS-level write isolation; Git metadata and Git-ignored paths are outside this audit boundary'
  return 0
}

cccc_path_allowed() {
  local path=${1-} index=0 rule prefix
  _cccc_relative_path_is_safe "$path" || return 1
  while [ "$index" -lt "${CCCC_ALLOWED_PATHS_COUNT:-0}" ]; do
    rule=${CCCC_ALLOWED_PATHS[$index]}
    case "$rule" in
      */)
        prefix=${rule%/}
        case "$path" in
          "$prefix"/*) return 0 ;;
        esac
        ;;
      *)
        [ "$path" = "$rule" ] && return 0
        ;;
    esac
    index=$((index + 1))
  done
  return 1
}
