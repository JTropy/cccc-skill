#!/usr/bin/env bash
set -u

TEST_DIR=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$TEST_DIR/test_helper.bash"
trap test_cleanup EXIT
trap 'test_signal_cleanup 1' HUP
trap 'test_signal_cleanup 2' INT
trap 'test_signal_cleanup 15' TERM

COMMON="$TEST_DIR/../skills/cccc/scripts/cccc-common.sh"
COMMON_TEST_WINDOWS=0
case ${MSYSTEM-} in
  MINGW*|MSYS*) COMMON_TEST_WINDOWS=1 ;;
esac
COMMON_LOADED=0
if [ -r "$COMMON" ]; then
  # shellcheck source=/dev/null
  if . "$COMMON"; then
    COMMON_LOADED=1
  fi
fi

test_harness_isolates_home_and_git_config() {
  case "$HOME/" in
    "$TEST_TMP_ROOT/"*) ;;
    *) test_diag "HOME is outside test root: $HOME"; return 1 ;;
  esac
  case "$XDG_CONFIG_HOME/" in
    "$TEST_TMP_ROOT/"*) ;;
    *) test_diag "XDG_CONFIG_HOME is outside test root: $XDG_CONFIG_HOME"; return 1 ;;
  esac
  [ -d "$HOME" ] && [ -d "$XDG_CONFIG_HOME" ] || return 1
  assert_eq 1 "${GIT_CONFIG_NOSYSTEM-}" "Git system config isolation" || return 1
  assert_eq "$HOME" "${USERPROFILE-}" "Windows home isolation" || return 1
  [ -z "${GIT_CONFIG_GLOBAL-}" ] || return 1
  bash -c '
    [ "$HOME" = "$1" ] &&
    [ "$XDG_CONFIG_HOME" = "$2" ] &&
    [ "$USERPROFILE" = "$1" ] &&
    [ "$GIT_CONFIG_NOSYSTEM" = 1 ] &&
    [ -z "${GIT_CONFIG_GLOBAL-}" ]
  ' _ "$HOME" "$XDG_CONFIG_HOME"
}

test_common_library_exists() {
  [ "$COMMON_LOADED" -eq 1 ] || {
    test_diag "missing $COMMON"
    return 1
  }
}

test_target_is_exact() {
  local tmp old_path discovered_claude discovered_codex
  tmp=$(new_test_dir) || return 1
  cp "$TEST_DIR/fixtures/fake-agent.sh" "$tmp/claude"
  cp "$TEST_DIR/fixtures/fake-agent.sh" "$tmp/codex"
  chmod +x "$tmp/claude" "$tmp/codex"
  old_path=$PATH
  PATH="$tmp:$PATH"
  discovered_claude=$(command -v claude) || return 1
  discovered_codex=$(command -v codex) || return 1
  cccc_resolve_target_argv claude || return 1
  if [ "$COMMON_TEST_WINDOWS" -eq 1 ]; then
    assert_eq 2 "${#CCCC_TARGET_ARGV[@]}" "claude argv length" || return 1
    assert_eq bash "${CCCC_TARGET_ARGV[0]}" "resolved Claude interpreter" || return 1
    assert_eq "$discovered_claude" "${CCCC_TARGET_ARGV[1]}" "resolved claude" || return 1
  else
    assert_eq 1 "${#CCCC_TARGET_ARGV[@]}" "claude argv length" || return 1
    assert_eq "$tmp/claude" "${CCCC_TARGET_ARGV[0]}" "resolved claude" || return 1
  fi
  cccc_resolve_target_argv codex || return 1
  if [ "$COMMON_TEST_WINDOWS" -eq 1 ]; then
    assert_eq 2 "${#CCCC_TARGET_ARGV[@]}" "codex argv length" || return 1
    assert_eq bash "${CCCC_TARGET_ARGV[0]}" "resolved Codex interpreter" || return 1
    assert_eq "$discovered_codex" "${CCCC_TARGET_ARGV[1]}" "resolved codex" || return 1
  else
    assert_eq "$tmp/codex" "${CCCC_TARGET_ARGV[0]}" "resolved codex" || return 1
  fi
  assert_fails cccc_resolve_target_argv Claude || return 1
  assert_fails cccc_resolve_target_argv codex-nightly || return 1
  assert_fails cccc_resolve_target_argv "$tmp/claude" || return 1
  PATH=$old_path
}

test_diagnostics_and_required_commands_return() {
  local output
  cccc_require_command git || return 1
  assert_fails cccc_require_command cccc-command-that-does-not-exist || return 1
  output=$(cccc_warn 'audit warning' 2>&1) || return 1
  printf '%s' "$output" | grep -q 'warning: audit warning' || return 1
  if output=$(cccc_die 'bad input' 2>&1); then
    test_diag "cccc_die unexpectedly succeeded"
    return 1
  fi
  printf '%s' "$output" | grep -q 'error: bad input' || return 1
}

test_depth_validation_is_not_arithmetic() {
  cccc_validate_depth "" || return 1
  cccc_validate_depth 0 || return 1
  assert_fails cccc_validate_depth 1 || return 1
  assert_fails cccc_validate_depth 00 || return 1
  assert_fails cccc_validate_depth abc || return 1
  assert_fails cccc_validate_depth '1+0' || return 1
  assert_fails cccc_validate_depth '$((0))' || return 1
}

test_timeout_validation_is_decimal() {
  cccc_validate_timeout 0 || return 1
  cccc_validate_timeout 1 || return 1
  cccc_validate_timeout 900 || return 1
  assert_fails cccc_validate_timeout "" || return 1
  assert_fails cccc_validate_timeout 00 || return 1
  assert_fails cccc_validate_timeout 01 || return 1
  assert_fails cccc_validate_timeout -1 || return 1
  assert_fails cccc_validate_timeout '1+1' || return 1
  assert_fails cccc_validate_timeout '$((2))' || return 1
}

test_python_discovery_checks_major_version() {
  local tmp old_path chmod_path
  tmp=$(new_test_dir) || return 1
  cat >"$tmp/python3" <<'EOF'
#!/bin/sh
exit 1
EOF
  cat >"$tmp/python" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$tmp/python3" "$tmp/python"
  chmod_path=$(command -v chmod) || return 1
  old_path=$PATH
  PATH=$tmp
  unset CCCC_PYTHON
  cccc_find_python3 || return 1
  assert_eq "$tmp/python" "$CCCC_PYTHON" "fallback Python 3" || return 1
  printf '%s\n' '#!/bin/sh' 'exit 1' >"$tmp/python"
  "$chmod_path" +x "$tmp/python"
  unset CCCC_PYTHON
  assert_fails cccc_find_python3 || return 1
  PATH=$old_path
}

test_windows_target_resolution_preserves_argv() {
  local tmp old_path
  tmp=$(new_test_dir) || return 1
  tmp=$(CDPATH= cd -P -- "$tmp" && pwd) || return 1
  mkdir "$tmp/native" "$tmp/shim" "$tmp/batch"
  cp "$TEST_DIR/fixtures/fake-agent.sh" "$tmp/native/claude.exe"
  chmod +x "$tmp/native/claude.exe"
  old_path=$PATH
  PATH="$tmp/native:$old_path"
  MSYSTEM=MINGW64 cccc_resolve_target_argv claude || return 1
  assert_eq 1 "${#CCCC_TARGET_ARGV[@]}" "native argv length" || return 1
  assert_eq "$tmp/native/claude.exe" "${CCCC_TARGET_ARGV[0]}" "native executable" || return 1

  cat >"$tmp/shim/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$tmp/shim/codex"
  PATH="$tmp/shim:$old_path"
  MSYSTEM=MINGW64 cccc_resolve_target_argv codex || return 1
  assert_eq 2 "${#CCCC_TARGET_ARGV[@]}" "shim argv length" || return 1
  assert_eq bash "${CCCC_TARGET_ARGV[0]}" "shim interpreter" || return 1
  assert_eq "$tmp/shim/codex" "${CCCC_TARGET_ARGV[1]}" "shim path boundary" || return 1

  cat >"$tmp/batch/claude.cmd" <<'EOF'
@echo off
EOF
  chmod +x "$tmp/batch/claude.cmd"
  PATH="$tmp/batch:/usr/bin:/bin"
  assert_fails env MSYSTEM=MINGW64 PATH="$PATH" bash -c '. "$1"; cccc_resolve_target_argv claude' _ "$COMMON" || return 1
  PATH=$old_path
}

test_windows_target_resolution_rejects_unsafe_entries_and_preserves_hostile_args() {
  local tmp old_path output
  tmp=$(new_test_dir) || return 1
  mkdir "$tmp/mixed" "$tmp/bad-shim" "$tmp/native"
  printf '%s\n' '@echo off' >"$tmp/mixed/claude.CmD"
  printf '%s\n' '@echo off' >"$tmp/mixed/codex.BAT"
  chmod +x "$tmp/mixed/claude.CmD" "$tmp/mixed/codex.BAT"
  old_path=$PATH
  _cccc_is_batch_path "$tmp/mixed/claude.CmD" || return 1
  _cccc_is_batch_path "$tmp/mixed/codex.BAT" || return 1
  assert_fails _cccc_is_batch_path "$tmp/mixed/native.EXE" || return 1
  PATH="$tmp/mixed:/usr/bin:/bin"
  output=$(MSYSTEM=MINGW64 cccc_resolve_target_argv claude 2>&1) && return 1
  output=$(MSYSTEM=MINGW64 cccc_resolve_target_argv codex 2>&1) && return 1

  printf '%s\n' '#!/usr/bin/env python3' 'raise SystemExit(0)' >"$tmp/bad-shim/claude"
  chmod +x "$tmp/bad-shim/claude"
  PATH="$tmp/bad-shim:/usr/bin:/bin"
  assert_fails env MSYSTEM=MINGW64 PATH="$PATH" bash -c '. "$1"; cccc_resolve_target_argv claude' _ "$COMMON" || return 1

  cp "$TEST_DIR/fixtures/fake-agent.sh" "$tmp/native/codex.exe"
  chmod +x "$tmp/native/codex.exe"
  PATH="$tmp/native:$old_path"
  MSYSTEM=MINGW64 cccc_resolve_target_argv codex || return 1
  CCCC_FAKE_ARGV_FILE="$tmp/argv.z" "${CCCC_TARGET_ARGV[@]}" 'space arg' '$(touch should-not-exist)' '; echo injected' || return 1
  [ ! -e "$tmp/should-not-exist" ] || return 1
  python3 - "$tmp/argv.z" <<'PY'
import sys
args = [item.decode() for item in open(sys.argv[1], 'rb').read().split(b'\0') if item]
expected = ['space arg', '$(touch should-not-exist)', '; echo injected']
if args != expected:
    raise SystemExit(f'argv boundary lost: {args!r}')
PY
}

test_windows_target_resolution_honors_path_precedence() {
  local tmp early later bad batch com old_path
  tmp=$(new_test_dir) || return 1
  tmp=$(CDPATH= cd -P -- "$tmp" && pwd) || return 1
  early="$tmp/early shim"
  later="$tmp/later-native"
  bad="$tmp/early-invalid"
  batch="$tmp/early-batch"
  com="$tmp/early-com"
  mkdir "$early" "$later" "$bad" "$batch" "$com"
  cp "$TEST_DIR/fixtures/fake-agent.sh" "$early/codex"
  cp "$TEST_DIR/fixtures/fake-agent.sh" "$later/codex.exe"
  chmod +x "$early/codex" "$later/codex.exe"
  old_path=$PATH
  PATH="$early:$later:$old_path"
  MSYSTEM=MINGW64 cccc_resolve_target_argv codex || return 1
  assert_eq 2 "${#CCCC_TARGET_ARGV[@]}" "earlier shim argv length" || return 1
  assert_eq bash "${CCCC_TARGET_ARGV[0]}" "earlier shim interpreter" || return 1
  assert_eq "$early/codex" "${CCCC_TARGET_ARGV[1]}" "PATH precedence" || return 1
  CCCC_FAKE_ARGV_FILE="$tmp/precedence-argv.z" "${CCCC_TARGET_ARGV[@]}" 'one arg' ';not-shell' || return 1
  python3 - "$tmp/precedence-argv.z" <<'PY' || return 1
import sys
actual = [item.decode() for item in open(sys.argv[1], 'rb').read().split(b'\0') if item]
if actual != ['one arg', ';not-shell']:
    raise SystemExit(f'precedence argv mismatch: {actual!r}')
PY
  (
    cd "$tmp" || exit 1
    PATH="early shim:$later:$old_path"
    MSYSTEM=MINGW64 cccc_resolve_target_argv codex || exit 1
    [ "${CCCC_TARGET_ARGV[1]}" = "$early/codex" ]
  ) || return 1
  (
    cd "$early" || exit 1
    PATH=":$later:$old_path"
    MSYSTEM=MINGW64 cccc_resolve_target_argv codex || exit 1
    [ "${CCCC_TARGET_ARGV[1]}" = "$early/codex" ]
  ) || return 1

  printf '%s\n' '#!/usr/bin/env python3' 'raise SystemExit(0)' >"$bad/codex"
  chmod +x "$bad/codex"
  PATH="$bad:$later:$old_path"
  assert_fails env MSYSTEM=MINGW64 PATH="$PATH" bash -c '. "$1"; cccc_resolve_target_argv codex' _ "$COMMON" || return 1

  printf '%s\n' '@echo off' >"$batch/codex.cmd"
  chmod +x "$batch/codex.cmd"
  PATH="$batch:$later:$old_path"
  assert_fails env MSYSTEM=MINGW64 PATH="$PATH" bash -c '. "$1"; cccc_resolve_target_argv codex' _ "$COMMON" || return 1
  cp "$TEST_DIR/fixtures/fake-agent.sh" "$com/codex.com"
  chmod +x "$com/codex.com"
  PATH="$com:$later:$old_path"
  assert_fails env MSYSTEM=MINGW64 PATH="$PATH" bash -c '. "$1"; cccc_resolve_target_argv codex' _ "$COMMON" || return 1
  PATH=$old_path
}

test_repo_resolution_and_unborn_head() {
  local tmp repo physical head
  tmp=$(new_test_dir) || return 1
  repo="$tmp/repo"
  init_test_repo "$repo" || return 1
  mkdir -p "$repo/a/b"
  cccc_resolve_repo "$repo/a/b" || return 1
  physical=$(CDPATH= cd -P -- "$repo" && pwd)
  assert_eq "$physical" "$CCCC_REPO_ROOT" "physical repo root" || return 1
  head=$(cccc_git_head "$CCCC_REPO_ROOT") || return 1
  assert_eq "CCCC_UNBORN_HEAD" "$head" "unborn sentinel" || return 1
  printf 'tracked\n' >"$repo/file"
  git -C "$repo" add file || return 1
  git -C "$repo" commit -qm initial || return 1
  head=$(cccc_git_head "$CCCC_REPO_ROOT") || return 1
  [ -n "$head" ] && [ "$head" != CCCC_UNBORN_HEAD ] || return 1
  assert_fails cccc_resolve_repo "$tmp" || return 1
}

test_repo_resolution_follows_physical_worktree_path() {
  local tmp repo link physical
  tmp=$(new_test_dir) || return 1
  repo="$tmp/repo"
  init_test_repo "$repo" || return 1
  mkdir -p "$repo/a/b"
  link="$tmp/repo-link"
  if ! ln -s "$repo" "$link" 2>/dev/null; then
    return 77
  fi
  [ -L "$link" ] || return 77
  cccc_resolve_repo "$link/a/b" || return 1
  physical=$(CDPATH= cd -P -- "$repo" && pwd)
  assert_eq "$physical" "$CCCC_REPO_ROOT" "physical repo root"
}

make_card_repo() {
  local repo=$1
  init_test_repo "$repo" || return 1
  mkdir -p "$repo/docs/tasks/子 目录" "$repo/docs/discussions" "$repo/docs/tasks-evil"
  printf '# task\n' >"$repo/docs/tasks/子 目录/卡 片.md"
  printf '# discussion\n' >"$repo/docs/discussions/topic.md"
  printf '# evil\n' >"$repo/docs/tasks-evil/evil.md"
  printf '# text\n' >"$repo/docs/tasks/nope.txt"
}

test_card_validation_exact_root_and_unicode() {
  local tmp repo
  tmp=$(new_test_dir) || return 1
  repo="$tmp/repo"
  make_card_repo "$repo" || return 1
  cccc_resolve_repo "$repo" || return 1
  cccc_validate_card 'docs/tasks/子 目录/卡 片.md' docs/tasks || return 1
  assert_eq 'docs/tasks/子 目录/卡 片.md' "$CCCC_CARD_REL" "card relpath" || return 1
  assert_eq "$CCCC_REPO_ROOT/docs/tasks/子 目录/卡 片.md" "$CCCC_CARD_ABS" "card absolute path" || return 1
  cccc_validate_card docs/discussions/topic.md docs/discussions || return 1
  assert_fails cccc_validate_card docs/tasks-evil/evil.md docs/tasks || return 1
  assert_fails cccc_validate_card docs/tasks/nope.txt docs/tasks || return 1
  assert_fails cccc_validate_card "$repo/docs/tasks/子 目录/卡 片.md" docs/tasks || return 1
  assert_fails cccc_validate_card '../repo/docs/tasks/子 目录/卡 片.md' docs/tasks || return 1
  assert_fails cccc_validate_card 'docs/tasks/../tasks/子 目录/卡 片.md' docs/tasks || return 1
  assert_fails cccc_validate_card docs/discussions/topic.md docs/tasks || return 1
}

test_card_rejects_symlink() {
  local tmp repo
  tmp=$(new_test_dir) || return 1
  repo="$tmp/repo"
  make_card_repo "$repo" || return 1
  if ! ln -s '子 目录/卡 片.md' "$repo/docs/tasks/link.md" 2>/dev/null; then
    return 77
  fi
  [ -L "$repo/docs/tasks/link.md" ] || return 77
  cccc_resolve_repo "$repo" || return 1
  assert_fails cccc_validate_card docs/tasks/link.md docs/tasks
}

test_card_rejects_fifo_without_blocking() {
  local tmp repo
  tmp=$(new_test_dir) || return 1
  repo="$tmp/repo"
  make_card_repo "$repo" || return 1
  command -v mkfifo >/dev/null 2>&1 || return 77
  mkfifo "$repo/docs/tasks/pipe.md" 2>/dev/null || return 77
  cccc_resolve_repo "$repo" || return 1
  assert_fails cccc_validate_card docs/tasks/pipe.md docs/tasks
}

test_card_rejects_physical_root_escape() {
  local tmp repo
  tmp=$(new_test_dir) || return 1
  repo="$tmp/repo"
  make_card_repo "$repo" || return 1
  mkdir -p "$tmp/outside"
  printf '# outside\n' >"$tmp/outside/card.md"
  if ! ln -s "$tmp/outside" "$repo/docs/tasks/escape" 2>/dev/null; then
    return 77
  fi
  [ -L "$repo/docs/tasks/escape" ] || return 77
  cccc_resolve_repo "$repo" || return 1
  assert_fails cccc_validate_card docs/tasks/escape/card.md docs/tasks
}

test_card_rejects_every_intermediate_symlink() {
  local tmp repo root_link_repo
  tmp=$(new_test_dir) || return 1
  repo="$tmp/repo"
  make_card_repo "$repo" || return 1
  mkdir -p "$repo/docs/tasks/real/nested"
  printf '# card\n' >"$repo/docs/tasks/real/nested/card.md"
  if ! ln -s real "$repo/docs/tasks/alias" 2>/dev/null; then
    return 77
  fi
  [ -L "$repo/docs/tasks/alias" ] || return 77
  cccc_resolve_repo "$repo" || return 1
  assert_fails cccc_validate_card docs/tasks/alias/nested/card.md docs/tasks || return 1

  root_link_repo="$tmp/root-link-repo"
  init_test_repo "$root_link_repo" || return 1
  mkdir -p "$root_link_repo/docs/real-tasks"
  printf '# card\n' >"$root_link_repo/docs/real-tasks/card.md"
  if ! ln -s real-tasks "$root_link_repo/docs/tasks" 2>/dev/null ||
     [ ! -L "$root_link_repo/docs/tasks" ]; then
    return 77
  fi
  cccc_resolve_repo "$root_link_repo" || return 1
  assert_fails cccc_validate_card docs/tasks/card.md docs/tasks
}

test_run_dir_is_private() {
  local tmp mode
  tmp=$(new_test_dir) || return 1
  TMPDIR="$tmp/space tmp"
  mkdir "$TMPDIR"
  cccc_make_run_dir || return 1
  case "$CCCC_RUN_DIR" in
    "$TMPDIR"/cccc.*) ;;
    *) test_diag "run dir outside requested temp root: $CCCC_RUN_DIR"; return 1 ;;
  esac
  mode=$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$CCCC_RUN_DIR") || return 1
  [ "$COMMON_TEST_WINDOWS" -eq 0 ] || return 77
  assert_eq 700 "$mode" "run directory mode"
}

test_output_refusal_and_claim() {
  local tmp claim mode identity
  tmp=$(new_test_dir) || return 1
  cccc_refuse_output_target "$tmp/absent.md" || return 1
  printf 'keep\n' >"$tmp/existing.md"
  mkdir "$tmp/existing-dir"
  assert_fails cccc_refuse_output_target "$tmp/existing.md" || return 1
  assert_fails cccc_refuse_output_target "$tmp/existing-dir" || return 1
  claim="$tmp/card.claim"
  cccc_acquire_claim "$claim" || return 1
  assert_fails cccc_acquire_claim "$claim" || return 1
  mode=$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$claim") || return 1
  if [ "$COMMON_TEST_WINDOWS" -eq 0 ]; then
    assert_eq 700 "$mode" "claim mode" || return 1
  fi
  printf 'publish me\n' >"$tmp/source"
  cccc_capture_destination_parent_identity "$tmp/published.md" || return 1
  identity=$CCCC_DESTINATION_PARENT_IDENTITY
  case "$identity" in
    *:*) ;;
    *) test_diag "invalid destination parent identity: $identity"; return 1 ;;
  esac
  cccc_atomic_publish "$tmp/source" "$tmp/published.md" "$identity" || return 1
  assert_eq 'publish me' "$(cat "$tmp/published.md")" "published content"
}

test_atomic_publish_rejects_replaced_parent_identity() {
  local tmp parent original outside identity
  tmp=$(new_test_dir) || return 1
  parent="$tmp/output"
  original="$tmp/original-output"
  outside="$tmp/outside"
  mkdir "$parent" "$outside" || return 1
  printf 'payload\n' >"$tmp/source"
  printf 'keep\n' >"$outside/referent.md"
  cccc_capture_destination_parent_identity "$parent/result.md" || return 1
  identity=$CCCC_DESTINATION_PARENT_IDENTITY
  mv "$parent" "$original" || return 1
  if ! ln -s "$outside" "$parent" 2>/dev/null; then
    return 77
  fi
  [ -L "$parent" ] || return 77
  assert_fails cccc_atomic_publish "$tmp/source" "$parent/result.md" "$identity" || return 1
  [ ! -e "$outside/result.md" ] || return 1
  assert_eq keep "$(cat "$outside/referent.md")" "outside referent" || return 1
  [ ! -e "$original/result.md" ]
}

test_atomic_publish_binds_expected_source_identity_and_digest() {
  local tmp source original identity digest parent_identity
  tmp=$(new_test_dir) || return 1
  source="$tmp/source"
  original="$tmp/original-source"
  printf 'trusted\n' >"$source"
  identity=$(python3 - "$source" <<'PY'
import os
import sys
value = os.stat(sys.argv[1], follow_symlinks=False)
print("%d:%d" % (value.st_dev, value.st_ino))
PY
  ) || return 1
  digest=$(python3 - "$source" <<'PY'
import hashlib
import sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
  ) || return 1
  cccc_capture_destination_parent_identity "$tmp/normal.md" || return 1
  parent_identity=$CCCC_DESTINATION_PARENT_IDENTITY
  cccc_atomic_publish "$source" "$tmp/normal.md" "$parent_identity" "$identity" "$digest" || return 1
  assert_eq trusted "$(cat "$tmp/normal.md")" 'bound source publication' || return 1

  mv "$source" "$original" || return 1
  printf 'forged\n' >"$source"
  cccc_capture_destination_parent_identity "$tmp/replaced.md" || return 1
  parent_identity=$CCCC_DESTINATION_PARENT_IDENTITY
  assert_fails cccc_atomic_publish \
    "$source" "$tmp/replaced.md" "$parent_identity" "$identity" "$digest" || return 1
  [ ! -e "$tmp/replaced.md" ] || return 1
  assert_eq forged "$(cat "$source")" 'replacement source preserved' || return 1

  identity=$(python3 - "$source" <<'PY'
import os
import sys
value = os.stat(sys.argv[1], follow_symlinks=False)
print("%d:%d" % (value.st_dev, value.st_ino))
PY
  ) || return 1
  cccc_capture_destination_parent_identity "$tmp/mutated.md" || return 1
  parent_identity=$CCCC_DESTINATION_PARENT_IDENTITY
  assert_fails cccc_atomic_publish \
    "$source" "$tmp/mutated.md" "$parent_identity" "$identity" "$digest" || return 1
  [ ! -e "$tmp/mutated.md" ]
}

test_common_python_invocations_ignore_pythonpath() {
  local tmp attack marker repo before after changed identity
  tmp=$(new_test_dir) || return 1
  attack="$tmp/attack"
  marker="$tmp/pythonpath-loaded"
  repo="$tmp/repo"
  mkdir "$attack" || return 1
  cat >"$attack/sitecustomize.py" <<'PY'
import os
from pathlib import Path
Path(os.environ["CCCC_PYTHONPATH_SENTINEL"]).write_text("loaded")
PY
  PYTHONPATH="$attack" CCCC_PYTHONPATH_SENTINEL="$marker" cccc_find_python3 || return 1
  [ ! -e "$marker" ] || {
    test_diag 'Python discovery imported PYTHONPATH sitecustomize'
    return 1
  }

  printf 'payload\n' >"$tmp/source"
  PYTHONPATH="$attack" CCCC_PYTHONPATH_SENTINEL="$marker" \
    cccc_capture_destination_parent_identity "$tmp/result.md" || return 1
  identity=$CCCC_DESTINATION_PARENT_IDENTITY
  PYTHONPATH="$attack" CCCC_PYTHONPATH_SENTINEL="$marker" \
    cccc_atomic_publish "$tmp/source" "$tmp/result.md" "$identity" || return 1

  init_test_repo "$repo" || return 1
  printf '*.ignored\n' >"$repo/.gitignore"
  printf 'one\n' >"$repo/file"
  printf 'ignored\n' >"$repo/cache.ignored"
  git -C "$repo" add .gitignore file || return 1
  before="$tmp/before.snapshot"
  after="$tmp/after.snapshot"
  changed="$tmp/changed.z"
  PYTHONPATH="$attack" CCCC_PYTHONPATH_SENTINEL="$marker" \
    cccc_git_snapshot "$repo" "$before" || return 1
  printf 'two\n' >"$repo/file"
  PYTHONPATH="$attack" CCCC_PYTHONPATH_SENTINEL="$marker" \
    cccc_git_snapshot "$repo" "$after" || return 1
  PYTHONPATH="$attack" CCCC_PYTHONPATH_SENTINEL="$marker" \
    cccc_snapshot_changed_paths "$before" "$after" "$changed" || return 1
  PYTHONPATH="$attack" CCCC_PYTHONPATH_SENTINEL="$marker" \
    cccc_git_has_ignored_paths "$repo" || return 1
  [ ! -e "$marker" ] || {
    test_diag 'a common Python invocation imported PYTHONPATH sitecustomize'
    return 1
  }
}

test_claim_loser_never_owns_winner_claim() {
  local tmp claim marker
  tmp=$(new_test_dir) || return 1
  claim="$tmp/card.claim"
  marker="$tmp/loser-owned"
  cccc_acquire_claim "$claim" || return 1
  [ "$CCCC_CLAIM_DIR" = "$claim" ] || return 1
  if CCCC_LOSER_MARKER="$marker" bash -c '
    . "$1"
    unset CCCC_CLAIM_DIR
    if cccc_acquire_claim "$2"; then exit 9; fi
    [ -z "${CCCC_CLAIM_DIR-}" ] || printf owned >"$CCCC_LOSER_MARKER"
    exit 5
  ' _ "$COMMON" "$claim"; then
    return 1
  fi
  [ ! -e "$marker" ] || return 1
  [ -d "$claim" ] || return 1
  CCCC_CLAIM_DIR=stale-sentinel
  assert_fails cccc_acquire_claim "$claim" || return 1
  [ -z "${CCCC_CLAIM_DIR-}" ] || {
    test_diag "failed claim retained stale ownership: $CCCC_CLAIM_DIR"
    return 1
  }
}

test_output_refuses_symlink() {
  local tmp
  [ "$COMMON_LOADED" -eq 1 ] || return 1
  tmp=$(new_test_dir) || return 1
  printf 'keep\n' >"$tmp/referent"
  if ! ln -s referent "$tmp/output.md" 2>/dev/null; then
    return 77
  fi
  [ -L "$tmp/output.md" ] || return 77
  assert_fails cccc_refuse_output_target "$tmp/output.md" || return 1
  assert_eq keep "$(cat "$tmp/referent")" "symlink referent" || return 1
  if ! ln -s missing "$tmp/dangling.md" 2>/dev/null ||
     [ ! -L "$tmp/dangling.md" ]; then
    return 77
  fi
  assert_fails cccc_refuse_output_target "$tmp/dangling.md"
}

test_output_refuses_fifo() {
  local tmp
  [ "$COMMON_LOADED" -eq 1 ] || return 1
  tmp=$(new_test_dir) || return 1
  command -v mkfifo >/dev/null 2>&1 || return 77
  mkfifo "$tmp/output.md" 2>/dev/null || return 77
  assert_fails cccc_refuse_output_target "$tmp/output.md"
}

write_policy_card() {
  local path=$1
  shift
  {
    printf '# card\n<!-- cccc-allowed-paths\n'
    for rule in "$@"; do
      printf '%s\n' "$rule"
    done
    printf '%s\n' '-->'
  } >"$path"
}

test_allowed_paths_parse_and_match_exactly() {
  local tmp card repo
  tmp=$(new_test_dir) || return 1
  repo="$tmp/repo"
  init_test_repo "$repo" || return 1
  mkdir -p "$repo/frontend" "$repo/tests/界 面"
  printf '{}\n' >"$repo/package.json"
  cccc_resolve_repo "$repo" || return 1
  card="$tmp/card.md"
  write_policy_card "$card" 'frontend/' 'tests/界 面/' 'package.json'
  cccc_parse_allowed_paths "$card" || return 1
  assert_eq 3 "${#CCCC_ALLOWED_PATHS[@]}" "policy count" || return 1
  cccc_path_allowed frontend/main.ts || return 1
  cccc_path_allowed 'tests/界 面/a b.ts' || return 1
  cccc_path_allowed package.json || return 1
  assert_fails cccc_path_allowed frontend-evil/main.ts || return 1
  assert_fails cccc_path_allowed package.json/child || return 1
  assert_fails cccc_path_allowed docs/tasks/card.md || return 1
  assert_fails cccc_path_allowed 'frontend/../escape' || return 1
  assert_fails cccc_path_allowed 'frontend//escape' || return 1
  assert_fails cccc_path_allowed '/frontend/escape' || return 1
}

test_allowed_paths_reject_ambiguous_policy() {
  local tmp card value repo
  [ "$COMMON_LOADED" -eq 1 ] || return 1
  tmp=$(new_test_dir) || return 1
  repo="$tmp/repo"
  init_test_repo "$repo" || return 1
  cccc_resolve_repo "$repo" || return 1
  card="$tmp/card.md"
  write_policy_card "$card"
  assert_fails cccc_parse_allowed_paths "$card" || return 1
  for value in '' '/absolute' '//server/share' '\\server\share' 'C:/absolute' 'C:\absolute' '.' './file' '..' '../file' 'a/../b' 'a/./b' 'a//b' 'src/*' 'src/?' 'src/[ab]' ' leading' 'trailing ' $'tab\tinside'; do
    write_policy_card "$card" "$value"
    assert_fails cccc_parse_allowed_paths "$card" || {
      test_diag "accepted invalid policy [$value]"
      return 1
    }
  done
  {
    printf '%s\n' '<!-- cccc-allowed-paths' 'src/' '-->' '<!-- cccc-allowed-paths' 'tests/' '-->'
  } >"$card"
  assert_fails cccc_parse_allowed_paths "$card" || return 1
  printf '%s\r\n' '<!-- cccc-allowed-paths' 'src/' 'package.json' '-->' >"$card"
  cccc_parse_allowed_paths "$card" || return 1
  assert_eq 2 "$CCCC_ALLOWED_PATHS_COUNT" "CRLF policy count"
}

test_allowed_paths_reject_symlinks_and_invalid_existing_shapes() {
  local tmp repo card output
  tmp=$(new_test_dir) || return 1
  repo="$tmp/repo"
  init_test_repo "$repo" || return 1
  mkdir "$repo/allowed-dir" "$tmp/outside"
  printf 'file\n' >"$repo/existing-file"
  if ! ln -s allowed-dir "$repo/link-inside" 2>/dev/null; then
    return 77
  fi
  [ -L "$repo/link-inside" ] || return 77
  if ! ln -s "$tmp/outside" "$repo/link-outside" 2>/dev/null ||
     [ ! -L "$repo/link-outside" ]; then
    return 77
  fi
  if ! ln -s missing-target "$repo/dangling" 2>/dev/null ||
     [ ! -L "$repo/dangling" ]; then
    return 77
  fi
  cccc_resolve_repo "$repo" || return 1
  card="$tmp/card.md"
  for rule in 'link-inside/' 'link-outside/' 'dangling/' 'allowed-dir' 'existing-file/' 'existing-file/child'; do
    write_policy_card "$card" "$rule"
    assert_fails cccc_parse_allowed_paths "$card" || {
      test_diag "accepted unsafe existing allowed path: $rule"
      return 1
    }
  done
  write_policy_card "$card" 'allowed-dir/' 'existing-file' 'new/path.md' 'new-directory/'
  output=$(cccc_parse_allowed_paths "$card" 2>&1) || return 1
  printf '%s' "$output" | grep -qi 'audit.*not.*OS' || {
    test_diag "missing audit-only warning: $output"
    return 1
  }
  printf '%s' "$output" | grep -qi 'metadata.*ignored.*outside' || {
    test_diag "missing metadata/ignored boundary warning: $output"
    return 1
  }
}

test_allowed_paths_reject_git_metadata_in_normal_repo() {
  local tmp repo card rule
  tmp=$(new_test_dir) || return 1
  repo="$tmp/repo"
  init_test_repo "$repo" || return 1
  mkdir -p "$repo/nested"
  printf 'allowed\n' >"$repo/.gitignore"
  cccc_resolve_repo "$repo" || return 1
  card="$tmp/card.md"
  for rule in '.git' '.git/' '.git/config' '.GIT/Config' 'nested/.GiT/config'; do
    write_policy_card "$card" "$rule"
    assert_fails cccc_parse_allowed_paths "$card" || {
      test_diag "accepted Git metadata allowed path: $rule"
      return 1
    }
  done
  write_policy_card "$card" '.gitignore' '.github/'
  cccc_parse_allowed_paths "$card" >/dev/null 2>&1 || return 1
}

test_allowed_paths_reject_ntfs_git_aliases_and_colons() {
  local tmp repo card rule
  tmp=$(new_test_dir) || return 1
  repo="$tmp/repo"
  init_test_repo "$repo" || return 1
  cccc_resolve_repo "$repo" || return 1
  card="$tmp/card.md"
  for rule in \
    '.git./config' \
    '.git . . ./hooks/pre-commit' \
    'git~1/config' \
    'GIT~1. /config' \
    '.git::$INDEX_ALLOCATION/config' \
    'nested/.GiT... /config' \
    'nested/deeper/GiT~1... /hooks/pre-commit' \
    'src/file:stream'; do
    write_policy_card "$card" "$rule"
    assert_fails cccc_parse_allowed_paths "$card" || {
      test_diag "accepted NTFS Git metadata alias or colon: $rule"
      return 1
    }
  done
  write_policy_card "$card" '.gitignore' '.github/' 'legit~1/'
  cccc_parse_allowed_paths "$card" >/dev/null 2>&1 || return 1
}

test_allowed_paths_reject_git_metadata_in_linked_worktree() {
  local tmp main linked card rule
  tmp=$(new_test_dir) || return 1
  main="$tmp/main"
  linked="$tmp/linked"
  init_test_repo "$main" || return 1
  printf 'initial\n' >"$main/file"
  git -C "$main" add file || return 1
  git -C "$main" commit -qm initial || return 1
  git -C "$main" worktree add -q -b cccc-linked-test "$linked" || return 1
  [ -f "$linked/.git" ] && [ ! -L "$linked/.git" ] || return 1
  cccc_resolve_repo "$linked" || return 1
  card="$tmp/card.md"
  for rule in '.git' '.git/' '.git/config' '.GIT/Config'; do
    write_policy_card "$card" "$rule"
    assert_fails cccc_parse_allowed_paths "$card" || {
      test_diag "linked worktree accepted Git metadata path: $rule"
      return 1
    }
  done
}

test_return_globals_are_cleared_before_failure() {
  local tmp repo old_path target_count
  tmp=$(new_test_dir) || return 1
  mkdir "$tmp/empty-path"
  CCCC_TARGET_ARGV=(stale)
  assert_fails cccc_resolve_target_argv invalid || return 1
  set +u
  target_count=${#CCCC_TARGET_ARGV[@]}
  set -u
  assert_eq 0 "$target_count" "stale target argv" || return 1

  CCCC_REPO_ROOT=stale
  assert_fails cccc_resolve_repo "$tmp/missing" || return 1
  [ -z "${CCCC_REPO_ROOT-}" ] || return 1

  repo="$tmp/repo"
  make_card_repo "$repo" || return 1
  cccc_resolve_repo "$repo" || return 1
  CCCC_CARD_REL=stale
  CCCC_CARD_ABS=stale
  assert_fails cccc_validate_card /absolute.md docs/tasks || return 1
  [ -z "${CCCC_CARD_REL-}" ] && [ -z "${CCCC_CARD_ABS-}" ] || return 1

  CCCC_RUN_DIR=stale
  TMPDIR="$tmp/missing-tmp" assert_fails cccc_make_run_dir || return 1
  [ -z "${CCCC_RUN_DIR-}" ] || return 1

  old_path=$PATH
  CCCC_PYTHON=stale
  PATH="$tmp/empty-path"
  assert_fails cccc_find_python3 || return 1
  [ -z "${CCCC_PYTHON-}" ] || return 1
  PATH=$old_path
}

test_snapshot_fingerprints_visible_content_and_ignores_ignored() {
  local tmp repo before after ignored changed status
  tmp=$(new_test_dir) || return 1
  repo="$tmp/repo"
  init_test_repo "$repo" || return 1
  printf '*.ignored\n' >"$repo/.gitignore"
  printf 'one\n' >"$repo/tracked.txt"
  printf 'untracked\n' >"$repo/新 文件.txt"
  printf 'ignored one\n' >"$repo/cache.ignored"
  git -C "$repo" add .gitignore tracked.txt || return 1
  before="$tmp/before.snapshot"
  after="$tmp/after.snapshot"
  ignored="$tmp/ignored.snapshot"
  changed="$tmp/changed.z"
  status="$tmp/status.z"
  cccc_git_snapshot "$repo" "$before" || return 1
  printf 'two\n' >"$repo/tracked.txt"
  printf 'untracked two\n' >"$repo/新 文件.txt"
  cccc_git_snapshot "$repo" "$after" || return 1
  assert_fails cccc_snapshot_equal "$before" "$after" || return 1
  cccc_snapshot_changed_paths "$before" "$after" "$changed" || return 1
  python3 - "$changed" <<'PY' || return 1
import sys
paths = open(sys.argv[1], 'rb').read().split(b'\0')
paths = [p for p in paths if p]
expected = {b'tracked.txt', '新 文件.txt'.encode()}
if set(paths) != expected:
    raise SystemExit(f"changed paths mismatch: {paths!r}")
PY
  printf 'ignored two\n' >"$repo/cache.ignored"
  cccc_git_snapshot "$repo" "$ignored" || return 1
  cccc_snapshot_equal "$after" "$ignored" || return 1
  cccc_git_has_ignored_paths "$repo" || return 1
  cccc_warn_ignored_audit_boundary 2>&1 | grep -qi 'metadata.*ignored.*outside' || return 1
  cccc_git_status_z "$repo" "$status" || return 1
  python3 - "$status" <<'PY' || return 1
import sys
data = open(sys.argv[1], 'rb').read()
if not data.endswith(b'\0'):
    raise SystemExit('status is not NUL terminated')
if b'tracked.txt\0' not in data or '新 文件.txt'.encode() + b'\0' not in data:
    raise SystemExit(f'missing visible paths: {data!r}')
if b'cache.ignored' in data:
    raise SystemExit('ignored path leaked into visible status')
PY
}

test_snapshot_handles_newline_path() {
  local tmp repo before after changed
  tmp=$(new_test_dir) || return 1
  repo="$tmp/repo"
  init_test_repo "$repo" || return 1
  if ! printf 'regular\n' >"$repo/line
break.txt" 2>/dev/null; then
    return 77
  fi
  git -C "$repo" add "line
break.txt" 2>/dev/null || return 77
  before="$tmp/before.snapshot"
  after="$tmp/after.snapshot"
  changed="$tmp/changed.z"
  cccc_git_snapshot "$repo" "$before" || return 1
  printf 'changed\n' >"$repo/line
break.txt" || return 1
  cccc_git_snapshot "$repo" "$after" || return 1
  assert_fails cccc_snapshot_equal "$before" "$after" || return 1
  cccc_snapshot_changed_paths "$before" "$after" "$changed" || return 1
  python3 - "$changed" <<'PY'
import sys
paths = [p for p in open(sys.argv[1], 'rb').read().split(b'\0') if p]
if paths != [b'line\nbreak.txt']:
    raise SystemExit(f"newline path mismatch: {paths!r}")
PY
}

test_snapshot_detects_index_only_transition() {
  local tmp repo before after
  tmp=$(new_test_dir) || return 1
  repo="$tmp/repo"
  init_test_repo "$repo" || return 1
  printf 'one\n' >"$repo/tracked.txt"
  git -C "$repo" add tracked.txt || return 1
  git -C "$repo" commit -qm initial || return 1
  printf 'pre-dirty\n' >"$repo/tracked.txt"
  before="$tmp/before.snapshot"
  after="$tmp/after.snapshot"
  cccc_git_snapshot "$repo" "$before" || return 1
  git -C "$repo" add tracked.txt || return 1
  cccc_git_snapshot "$repo" "$after" || return 1
  assert_fails cccc_snapshot_equal "$before" "$after"
}

test_snapshot_tracked_fifo_is_nonblocking() {
  local tmp repo before after runner
  command -v mkfifo >/dev/null 2>&1 || return 77
  tmp=$(new_test_dir) || return 1
  repo="$tmp/repo"
  init_test_repo "$repo" || return 1
  printf 'regular\n' >"$repo/tracked.md"
  git -C "$repo" add tracked.md || return 1
  before="$tmp/before.snapshot"
  after="$tmp/after.snapshot"
  cccc_git_snapshot "$repo" "$before" || return 1
  rm "$repo/tracked.md"
  mkfifo "$repo/tracked.md" 2>/dev/null || return 77
  runner="$TEST_DIR/../skills/cccc/scripts/run-with-timeout.py"
  python3 "$runner" 3 -- bash -c '. "$1"; cccc_git_snapshot "$2" "$3"' _ "$COMMON" "$repo" "$after" || return 1
  assert_fails cccc_snapshot_equal "$before" "$after"
}

test_snapshot_detects_delete_and_rename_paths() {
  local tmp repo before after changed
  tmp=$(new_test_dir) || return 1
  repo="$tmp/repo"
  init_test_repo "$repo" || return 1
  printf 'delete\n' >"$repo/delete-me"
  printf 'rename\n' >"$repo/old-name"
  git -C "$repo" add delete-me old-name || return 1
  git -C "$repo" commit -qm initial || return 1
  before="$tmp/before.snapshot"
  after="$tmp/after.snapshot"
  changed="$tmp/changed.z"
  cccc_git_snapshot "$repo" "$before" || return 1
  rm "$repo/delete-me"
  mv "$repo/old-name" "$repo/new-name"
  cccc_git_snapshot "$repo" "$after" || return 1
  cccc_snapshot_changed_paths "$before" "$after" "$changed" || return 1
  python3 - "$changed" <<'PY'
import sys
paths = set(item for item in open(sys.argv[1], 'rb').read().split(b'\0') if item)
expected = {b'delete-me', b'old-name', b'new-name'}
if paths != expected:
    raise SystemExit(f'delete/rename paths mismatch: {paths!r}')
PY
}

test_snapshot_detects_executable_mode() {
  local tmp repo before after before_mode after_mode
  tmp=$(new_test_dir) || return 1
  repo="$tmp/repo"
  init_test_repo "$repo" || return 1
  printf '#!/bin/sh\n' >"$repo/tool"
  chmod 600 "$repo/tool"
  git -C "$repo" add tool || return 1
  before="$tmp/before.snapshot"
  after="$tmp/after.snapshot"
  cccc_git_snapshot "$repo" "$before" || return 1
  before_mode=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mode & 0o111)' "$repo/tool") || return 1
  chmod +x "$repo/tool" || return 77
  after_mode=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mode & 0o111)' "$repo/tool") || return 1
  [ "$before_mode" != "$after_mode" ] || return 77
  cccc_git_snapshot "$repo" "$after" || return 1
  assert_fails cccc_snapshot_equal "$before" "$after"
}

test_snapshot_detects_symlink_target() {
  local tmp repo before after
  tmp=$(new_test_dir) || return 1
  repo="$tmp/repo"
  init_test_repo "$repo" || return 1
  if ! ln -s target-one "$repo/link" 2>/dev/null; then
    return 77
  fi
  [ -L "$repo/link" ] || return 77
  git -C "$repo" add link || return 1
  before="$tmp/before.snapshot"
  after="$tmp/after.snapshot"
  cccc_git_snapshot "$repo" "$before" || return 1
  rm "$repo/link"
  if ! ln -s target-two "$repo/link" 2>/dev/null || [ ! -L "$repo/link" ]; then
    return 77
  fi
  cccc_git_snapshot "$repo" "$after" || return 1
  assert_fails cccc_snapshot_equal "$before" "$after"
}

test_snapshot_rejects_real_submodule_gitlink() {
  local tmp source repo output
  tmp=$(new_test_dir) || return 1
  source="$tmp/source-repo"
  repo="$tmp/parent-repo"
  init_test_repo "$source" || return 1
  printf 'source\n' >"$source/file"
  git -C "$source" add file || return 1
  git -C "$source" commit -qm initial || return 1
  init_test_repo "$repo" || return 1
  printf 'parent\n' >"$repo/README"
  git -C "$repo" add README || return 1
  git -C "$repo" commit -qm initial || return 1
  git -C "$repo" -c protocol.file.allow=always submodule add -q "$source" modules/sub || return 1
  output="$tmp/submodule.snapshot"
  printf 'stale-success\n' >"$output"
  assert_fails cccc_git_snapshot "$repo" "$output" || return 1
  [ ! -e "$output" ] || {
    test_diag 'failed submodule snapshot left a reusable output'
    return 1
  }
}

test_snapshot_rejects_untracked_nested_repository() {
  local tmp repo nested output
  tmp=$(new_test_dir) || return 1
  repo="$tmp/parent-repo"
  nested="$repo/nested"
  init_test_repo "$repo" || return 1
  init_test_repo "$nested" || return 1
  printf 'nested\n' >"$nested/file"
  git -C "$nested" add file || return 1
  git -C "$nested" commit -qm initial || return 1
  output="$tmp/nested.snapshot"
  printf 'stale-success\n' >"$output"
  assert_fails cccc_git_snapshot "$repo" "$output" || return 1
  [ ! -e "$output" ] || {
    test_diag 'failed nested-repo snapshot left a reusable output'
    return 1
  }
}

test_common_uses_bash_3_2_safe_constructs() {
  if grep -En '(^|[^[:alnum:]_])(eval|mapfile|readarray|declare[[:space:]]+-A|local[[:space:]]+-A)|\$\{[^}]*,,|nameref|declare[[:space:]]+-n' "$COMMON" >/dev/null; then
    test_diag 'common library contains a forbidden post-Bash-3.2 or string-eval construct'
    return 1
  fi
}

run_test "shell harness isolates HOME and Git configuration" test_harness_isolates_home_and_git_config
run_test "common safety library exists and is sourceable" test_common_library_exists
run_test "target is exactly claude or codex" test_target_is_exact
run_test "diagnostics and required commands return to caller" test_diagnostics_and_required_commands_return
run_test "depth input is never arithmetic" test_depth_validation_is_not_arithmetic
run_test "timeout is canonical decimal" test_timeout_validation_is_decimal
run_test "Python discovery verifies major version" test_python_discovery_checks_major_version
run_test "Windows target resolution preserves argv boundaries" test_windows_target_resolution_preserves_argv
run_test "Windows resolver rejects unsafe entries and preserves hostile argv" test_windows_target_resolution_rejects_unsafe_entries_and_preserves_hostile_args
run_test "Windows resolver honors PATH precedence" test_windows_target_resolution_honors_path_precedence
run_test "repository resolves physically and unborn HEAD is stable" test_repo_resolution_and_unborn_head
run_test "symlinked workdir resolves to physical repository root" test_repo_resolution_follows_physical_worktree_path
run_test "card path uses exact root and supports Unicode spaces" test_card_validation_exact_root_and_unicode
run_test "card symlink is rejected" test_card_rejects_symlink
run_test "card FIFO is rejected without opening it" test_card_rejects_fifo_without_blocking
run_test "card physical root escape is rejected" test_card_rejects_physical_root_escape
run_test "card rejects every intermediate symlink" test_card_rejects_every_intermediate_symlink
run_test "private run directory is mode 700" test_run_dir_is_private
run_test "existing outputs are refused and claims are atomic" test_output_refusal_and_claim
run_test "atomic publish pins the captured parent identity" test_atomic_publish_rejects_replaced_parent_identity
run_test "atomic publish binds expected source identity and digest" test_atomic_publish_binds_expected_source_identity_and_digest
run_test "common Python invocations ignore PYTHONPATH" test_common_python_invocations_ignore_pythonpath
run_test "claim loser never owns the winner claim" test_claim_loser_never_owns_winner_claim
run_test "output symlink is refused" test_output_refuses_symlink
run_test "output FIFO is refused" test_output_refuses_fifo
run_test "allowed paths parse and match exact boundaries" test_allowed_paths_parse_and_match_exactly
run_test "ambiguous allowed-path policy is rejected" test_allowed_paths_reject_ambiguous_policy
run_test "allowed paths reject symlinks and invalid existing shapes" test_allowed_paths_reject_symlinks_and_invalid_existing_shapes
run_test "allowed paths reject Git metadata in a normal repo" test_allowed_paths_reject_git_metadata_in_normal_repo
run_test "allowed paths reject NTFS Git aliases and colons" test_allowed_paths_reject_ntfs_git_aliases_and_colons
run_test "allowed paths reject Git metadata in a linked worktree" test_allowed_paths_reject_git_metadata_in_linked_worktree
run_test "return globals clear stale values before failures" test_return_globals_are_cleared_before_failure
run_test "snapshot fingerprints Git-visible content only" test_snapshot_fingerprints_visible_content_and_ignores_ignored
run_test "snapshot is NUL-safe for newline paths" test_snapshot_handles_newline_path
run_test "snapshot detects index-only transition" test_snapshot_detects_index_only_transition
run_test "tracked FIFO snapshot is nonblocking" test_snapshot_tracked_fifo_is_nonblocking
run_test "snapshot reports delete and rename paths" test_snapshot_detects_delete_and_rename_paths
run_test "snapshot detects executable mode" test_snapshot_detects_executable_mode
run_test "snapshot detects symlink target" test_snapshot_detects_symlink_target
run_test "snapshot rejects a real submodule gitlink" test_snapshot_rejects_real_submodule_gitlink
run_test "snapshot rejects an untracked nested repository" test_snapshot_rejects_untracked_nested_repository
run_test "common library stays within Bash 3.2 syntax" test_common_uses_bash_3_2_safe_constructs
finish_tests
