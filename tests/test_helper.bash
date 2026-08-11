#!/usr/bin/env bash

TEST_COUNT=0
TEST_FAILED=0
TEST_TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cccc-shell-tests.XXXXXXXX") || exit 1
TEST_CLEANUP_DIRS=("$TEST_TMP_ROOT")
TEST_FAKE_HOME="$TEST_TMP_ROOT/home"
TEST_FAKE_XDG_CONFIG_HOME="$TEST_TMP_ROOT/xdg-config"
if ! mkdir -p "$TEST_FAKE_HOME" "$TEST_FAKE_XDG_CONFIG_HOME"; then
  rm -rf -- "$TEST_TMP_ROOT"
  exit 1
fi
chmod 700 "$TEST_FAKE_HOME" "$TEST_FAKE_XDG_CONFIG_HOME" || exit 1

HOME=$TEST_FAKE_HOME
USERPROFILE=$TEST_FAKE_HOME
XDG_CONFIG_HOME=$TEST_FAKE_XDG_CONFIG_HOME
GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
export HOME USERPROFILE XDG_CONFIG_HOME GIT_CONFIG_NOSYSTEM

test_diag() {
  printf '# %s\n' "$*"
}

test_register_tmp() {
  TEST_CLEANUP_DIRS+=("$1")
}

test_cleanup() {
  local path
  for path in "${TEST_CLEANUP_DIRS[@]}"; do
    if [ -n "$path" ] && [ -d "$path" ]; then
      rm -rf -- "$path"
    fi
  done
}

test_signal_cleanup() {
  local signal_number=$1
  trap - EXIT HUP INT TERM
  test_cleanup
  exit $((128 + signal_number))
}

run_test() {
  local name=$1
  local output
  local rc
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
      while IFS= read -r line; do
        printf '# %s\n' "$line"
      done <<EOF
$output
EOF
    fi
    TEST_FAILED=$((TEST_FAILED + 1))
  fi
}

new_test_dir() {
  local path
  path=$(mktemp -d "$TEST_TMP_ROOT/case.XXXXXXXX") || return 1
  printf '%s\n' "$path"
}

init_test_repo() {
  local path=$1
  git init -q "$path" || return 1
  git -C "$path" config user.name cccc-test || return 1
  git -C "$path" config user.email cccc-test@example.invalid || return 1
}

assert_eq() {
  local expected=$1
  local actual=$2
  local label=${3:-values differ}
  if [ "$expected" != "$actual" ]; then
    test_diag "$label: expected [$expected], got [$actual]"
    return 1
  fi
}

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    test_diag "expected failure: $*"
    return 1
  fi
}

finish_tests() {
  printf '1..%d\n' "$TEST_COUNT"
  test_cleanup
  [ "$TEST_FAILED" -eq 0 ]
}
