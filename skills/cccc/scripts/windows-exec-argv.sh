#!/usr/bin/env bash
# Restore argv from private environment keys without Windows command-line reparsing.

set -u

if [ "$#" -ne 4 ]; then
  printf '%s\n' 'cccc-timeout: invalid Windows argv bootstrap invocation' >&2
  exit 125
fi

cccc_prefix=$1
cccc_expected_count=$2
cccc_expected_digest=$3
cccc_result_path=$4
case "$cccc_prefix" in
  CCCC_WINDOWS_ARGV_[0123456789abcdef][0123456789abcdef]*) ;;
  *)
    printf '%s\n' 'cccc-timeout: invalid Windows argv bootstrap prefix' >&2
    exit 125
    ;;
esac
case "$cccc_expected_count" in
  ''|*[!0-9]*)
    printf '%s\n' 'cccc-timeout: invalid Windows argv bootstrap count' >&2
    exit 125
    ;;
esac
case "$cccc_expected_digest" in
  *[!0123456789abcdef]*|'')
    printf '%s\n' 'cccc-timeout: invalid Windows argv bootstrap digest' >&2
    exit 125
    ;;
esac

cccc_argv=()
cccc_index=0
while [ "$cccc_index" -lt "$cccc_expected_count" ]; do
  cccc_name="${cccc_prefix}_${cccc_index}"
  cccc_argv[${#cccc_argv[@]}]=${!cccc_name}
  unset "$cccc_name"
  cccc_index=$((cccc_index + 1))
done
unset "${cccc_prefix}_COUNT" "${cccc_prefix}_DIGEST"

"$BASH" "${cccc_argv[@]}"
cccc_target_status=$?

umask 077
set -C
if ! printf '%s %s\n' 'cccc-windows-shell-result-v1' "$cccc_target_status" >"$cccc_result_path"; then
  printf '%s\n' 'cccc-timeout: could not publish Windows shell result' >&2
  exit 125
fi
exit 0
