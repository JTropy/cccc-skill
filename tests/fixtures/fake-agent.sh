#!/usr/bin/env bash
set -u

if [ -n "${CCCC_FAKE_ARGV_FILE-}" ]; then
  : >"$CCCC_FAKE_ARGV_FILE"
  for arg in "$@"; do
    printf '%s\0' "$arg" >>"$CCCC_FAKE_ARGV_FILE"
  done
fi

if [ -n "${CCCC_FAKE_OUTPUT-}" ]; then
  printf '%s\n' "$CCCC_FAKE_OUTPUT"
fi

exit "${CCCC_FAKE_RC:-0}"
