#!/usr/bin/env bash
set -u

record_nul_argv() {
  local destination=$1 argument
  : >"$destination"
  shift
  for argument in "$@"; do
    printf '%s\0' "$argument" >>"$destination"
  done
}

record_call() {
  local kind=$1
  if [ -n "${CCCC_FAKE_CALLS_FILE-}" ]; then
    printf '%s\t%s\n' "$kind" "$*" >>"$CCCC_FAKE_CALLS_FILE"
  fi
}

feature_list='hooks
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
shell_snapshot'
feature_list="$feature_list
remote_plugin
plugin_sharing
auth_elicitation
tool_call_mcp_elicitation
tool_suggest
goals
code_mode_host
in_app_updates
enable_mcp_apps
recommended_plugins"
feature_list="$feature_list
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

preflight_barrier() {
  local stage=$1 attempts
  [ "${CCCC_FAKE_PREFLIGHT_BARRIER_STAGE-}" = "$stage" ] || return 0
  [ -n "${CCCC_FAKE_PREFLIGHT_BARRIER_DIR-}" ] || return 98
  mkdir -p "$CCCC_FAKE_PREFLIGHT_BARRIER_DIR" || return 98
  : >"$CCCC_FAKE_PREFLIGHT_BARRIER_DIR/ready.$stage.$$"
  attempts=${CCCC_FAKE_BARRIER_TICKS:-3000}
  while [ ! -e "$CCCC_FAKE_PREFLIGHT_BARRIER_DIR/release" ] && [ "$attempts" -gt 0 ]; do
    sleep 0.02
    attempts=$((attempts - 1))
  done
  [ -e "$CCCC_FAKE_PREFLIGHT_BARRIER_DIR/release" ] || return 98
}

if [ "${1-}" = --help ]; then
  record_call root-help "$@"
  preflight_barrier root-help || exit $?
  if [ "${CCCC_FAKE_HELP_RC:-0}" -ne 0 ]; then
    exit "$CCCC_FAKE_HELP_RC"
  fi
  if [ "${CCCC_FAKE_MISSING_FLAG-}" = -a ]; then
    printf '  %s\n' '-a-extra  description mentions -a'
  else
    printf '  %s\n' '-a, --ask-for-approval <POLICY>'
  fi
  exit 0
fi

if [ "${1-}" = exec ] && [ "${2-}" = --help ]; then
  record_call exec-help "$@"
  preflight_barrier exec-help || exit $?
  if [ "${CCCC_FAKE_HELP_RC:-0}" -ne 0 ]; then
    exit "$CCCC_FAKE_HELP_RC"
  fi
  for flag in --json --ephemeral --sandbox --ignore-user-config --strict-config \
    --ignore-rules --skip-git-repo-check -C -c --disable; do
    if [ "$flag" = "${CCCC_FAKE_MISSING_FLAG-}" ]; then
      printf '  %s-extra  description mentions %s\n' "$flag" "$flag"
    else
      printf '  %s <VALUE>\n' "$flag"
    fi
  done
  exit 0
fi

if [ "${1-}" = features ] && [ "${2-}" = list ] && [ "$#" -eq 2 ]; then
  record_call features "$@"
  preflight_barrier features || exit $?
  if [ "${CCCC_FAKE_FEATURES_RC:-0}" -ne 0 ]; then
    exit "$CCCC_FAKE_FEATURES_RC"
  fi
  while IFS= read -r feature; do
    [ -n "$feature" ] || continue
    if [ "$feature" = "${CCCC_FAKE_MISSING_FEATURE-}" ]; then
      continue
    fi
    if [ "$feature" = hooks ] && [ "${CCCC_FAKE_FEATURES_SHAPE-}" = removed ]; then
      printf '%-38s %-22s %s\n' "$feature" removed false
    elif [ "$feature" = chronicle ]; then
      printf '%-38s %-22s %s\n' "$feature" 'under development' true
    elif [ "$feature" = code_mode ] || [ "$feature" = enable_mcp_apps ]; then
      printf '%-38s %-22s %s\n' "$feature" 'under development' false
    else
      printf '%-38s %-22s %s\n' "$feature" stable true
    fi
    if [ "$feature" = hooks ] && [ "${CCCC_FAKE_FEATURES_SHAPE-}" = duplicate ]; then
      printf '%-38s %-22s %s\n' "$feature" stable true
    fi
  done <<EOF
$feature_list
EOF
  for feature in enable_request_compression fast_mode guardian_approval mentions_v2 \
    personality remote_compaction_v2 shell_tool unified_exec; do
    printf '%-38s %-22s %s\n' "$feature" stable true
  done
  printf '%-38s %-22s %s\n' collaboration_modes removed true
  printf '%-38s %-22s %s\n' item_ids removed true
  case ${CCCC_FAKE_FEATURES_SHAPE-} in
    malformed) printf '%s\n' 'not a valid feature record' ;;
    unknown-enabled) printf '%-38s %-22s %s\n' unknown_surprise_feature 'under development' true ;;
  esac
  exit 0
fi

repo=${CCCC_FAKE_REPO-}
card=${CCCC_FAKE_CARD-docs/discussions/D-test.md}
scenario=${CCCC_FAKE_SCENARIO-success}

if [ "${CCCC_FAKE_MUTATE_TRACKED-}" = 1 ]; then
  printf 'generic tracked mutation\n' >>"$repo/src/tracked.txt"
  if [ -n "${CCCC_FAKE_MUTATION_MARKER-}" ]; then
    printf 'mutated\n' >"$CCCC_FAKE_MUTATION_MARKER"
  fi
fi
if [ "${CCCC_FAKE_MUTATE_IGNORED-}" = 1 ]; then
  printf 'ignored mutation\n' >"$repo/agent-ignored.log"
  printf 'git metadata mutation\n' >"$repo/.git/cccc-consult-ignored"
fi

if [ -n "${CCCC_FAKE_ARGV_FILE-}" ]; then
  record_nul_argv "$CCCC_FAKE_ARGV_FILE" "$@"
fi
if [ -n "${CCCC_FAKE_LAUNCH_FILE-}" ]; then
  printf 'launched\n' >>"$CCCC_FAKE_LAUNCH_FILE"
fi
record_call launch "$@"

if [ -n "${CCCC_FAKE_ENV_FILE-}" ]; then
  {
    printf 'DELEGATE_DEPTH=%s\n' "${DELEGATE_DEPTH-<unset>}"
    printf 'BASH_ENV=%s\n' "${BASH_ENV-<unset>}"
    printf 'ENV=%s\n' "${ENV-<unset>}"
    printf 'DISABLE_AUTOUPDATER=%s\n' "${DISABLE_AUTOUPDATER-<unset>}"
    printf 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=%s\n' "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC-<unset>}"
    printf 'HOME=%s\n' "${HOME-<unset>}"
    printf 'XDG_CONFIG_HOME=%s\n' "${XDG_CONFIG_HOME-<unset>}"
  } >"$CCCC_FAKE_ENV_FILE"
fi
if [ -n "${CCCC_FAKE_CWD_FILE-}" ]; then
  pwd -P >"$CCCC_FAKE_CWD_FILE"
fi

previous=
mcp_config=
codex_cwd=
for argument in "$@"; do
  if [ "$previous" = --mcp-config ]; then mcp_config=$argument; fi
  if [ "$previous" = -C ]; then codex_cwd=$argument; fi
  previous=$argument
done

has_exact_argument() {
  local wanted=$1 value
  shift
  for value in "$@"; do
    [ "$value" = "$wanted" ] && return 0
  done
  return 1
}
if [ -n "${CCCC_FAKE_UPDATE_SENTINEL-}" ] && \
  ! has_exact_argument 'check_for_update_on_startup=false' "$@"; then
  : >"$CCCC_FAKE_UPDATE_SENTINEL"
fi
if [ -n "${CCCC_FAKE_NOTIFY_SENTINEL-}" ] && ! has_exact_argument 'notify=[]' "$@"; then
  : >"$CCCC_FAKE_NOTIFY_SENTINEL"
fi
if [ -n "${CCCC_FAKE_PROFILE_SENTINEL-}" ] && \
  ! has_exact_argument 'allow_login_shell=false' "$@"; then
  : >"$CCCC_FAKE_PROFILE_SENTINEL"
fi
if [ -n "${CCCC_FAKE_POISON_SENTINELS-}" ]; then
  isolation_ok=1
  if [ "${0##*/}" = claude ]; then
    for required in --safe-mode --strict-mcp-config --no-chrome --no-session-persistence; do
      has_exact_argument "$required" "$@" || isolation_ok=0
    done
  else
    for required in --ignore-user-config --strict-config --ignore-rules; do
      has_exact_argument "$required" "$@" || isolation_ok=0
    done
  fi
  if [ "$isolation_ok" -ne 1 ]; then
    while IFS= read -r poison; do [ -z "$poison" ] || : >"$poison"; done <<EOF
$CCCC_FAKE_POISON_SENTINELS
EOF
  fi
fi

if [ -n "${CCCC_FAKE_PRIVATE_FILE-}" ]; then
  {
    if [ -n "$mcp_config" ]; then
      printf 'mcp_path=%s\n' "$mcp_config"
      mode=$(stat -c '%a' "$mcp_config" 2>/dev/null || stat -f '%Lp' "$mcp_config" 2>/dev/null || true)
      printf 'mcp_mode=%s\n' "$mode"
      printf 'mcp_type=%s\n' "$(if [ -f "$mcp_config" ] && [ ! -L "$mcp_config" ]; then printf regular; else printf unsafe; fi)"
      printf 'mcp_content_begin\n'
      cat "$mcp_config" 2>/dev/null || true
      printf 'mcp_content_end\n'
    fi
    if [ -n "$codex_cwd" ]; then
      printf 'codex_cwd=%s\n' "$codex_cwd"
      mode=$(stat -c '%a' "$codex_cwd" 2>/dev/null || stat -f '%Lp' "$codex_cwd" 2>/dev/null || true)
      printf 'codex_cwd_mode=%s\n' "$mode"
      printf 'codex_cwd_entries_begin\n'
      find "$codex_cwd" -mindepth 1 -maxdepth 1 -print 2>/dev/null || true
      printf 'codex_cwd_entries_end\n'
    fi
  } >"$CCCC_FAKE_PRIVATE_FILE"
fi

case "$scenario" in
  success) ;;
  empty) ;;
  nonzero) ;;
  natural-124) ;;
  natural-125) ;;
  natural-127) ;;
  timeout)
    sleep 30
    ;;
  tracked-change)
    printf 'second change\n' >>"$repo/src/tracked.txt"
    ;;
  untracked-change)
    printf 'second change\n' >>"$repo/scratch/untracked.txt"
    ;;
  index-only)
    printf 'index only\n' >>"$repo/src/tracked.txt"
    "${CCCC_FAKE_REAL_GIT:-git}" -C "$repo" add src/tracked.txt
    "${CCCC_FAKE_REAL_GIT:-git}" -C "$repo" checkout -- src/tracked.txt
    ;;
  modify-card)
    printf '\nchanged card\n' >>"$repo/$card"
    ;;
  replace-card-same-content)
    cp "$repo/$card" "$repo/$card.replacement"
    mv "$repo/$card.replacement" "$repo/$card"
    ;;
  head-change)
    printf 'head change\n' >>"$repo/src/tracked.txt"
    "${CCCC_FAKE_REAL_GIT:-git}" -C "$repo" add src/tracked.txt
    "${CCCC_FAKE_REAL_GIT:-git}" -C "$repo" commit -q -m fake-consult-head-change
    ;;
  replace-card-parent)
    mkdir -p "$CCCC_FAKE_EXTERNAL"
    mv "$repo/docs/discussions" "$CCCC_FAKE_EXTERNAL/original-discussions"
    mkdir "$repo/docs/discussions"
    cp "$CCCC_FAKE_EXTERNAL/original-discussions/${card##*/}" "$repo/$card"
    ;;
  replace-docs-ancestor)
    mkdir -p "$CCCC_FAKE_EXTERNAL"
    mv "$repo/docs" "$CCCC_FAKE_EXTERNAL/original-docs"
    mkdir -p "$repo/docs/discussions"
    cp "$CCCC_FAKE_EXTERNAL/original-docs/discussions/${card##*/}" "$repo/$card"
    ;;
  background-descendant)
    (
      trap '' HUP INT TERM
      while :; do sleep 1; done
    ) &
    descendant_pid=$!
    kill -0 "$descendant_pid" 2>/dev/null || exit 98
    if [ -n "${CCCC_FAKE_DESCENDANT_PID_FILE-}" ]; then
      printf '%s\n' "$descendant_pid" >"$CCCC_FAKE_DESCENDANT_PID_FILE"
    fi
    ;;
  poison-run-artifact)
    run_dir=
    for candidate in "${TMPDIR:-/tmp}"/cccc.*; do
      [ -d "$candidate" ] || continue
      run_dir=$candidate
    done
    [ -n "$run_dir" ] || exit 98
    case "${CCCC_FAKE_ARTIFACT_KIND-}" in
      symlink) ln -s "$CCCC_FAKE_REFERENT" "$run_dir/$CCCC_FAKE_ARTIFACT_NAME" ;;
      fifo) mkfifo "$run_dir/$CCCC_FAKE_ARTIFACT_NAME" ;;
      *) exit 98 ;;
    esac
    ;;
  *)
    printf 'unknown fake consult scenario: %s\n' "$scenario" >&2
    exit 98
    ;;
esac

if [ -n "${CCCC_FAKE_BARRIER_DIR-}" ]; then
  mkdir -p "$CCCC_FAKE_BARRIER_DIR"
  : >"$CCCC_FAKE_BARRIER_DIR/ready.$$"
  attempts=${CCCC_FAKE_BARRIER_TICKS:-3000}
  while [ ! -e "$CCCC_FAKE_BARRIER_DIR/release" ] && [ "$attempts" -gt 0 ]; do
    sleep 0.02
    attempts=$((attempts - 1))
  done
  [ -e "$CCCC_FAKE_BARRIER_DIR/release" ] || exit 98
fi

case "$scenario" in
  empty) exit 0 ;;
  nonzero)
    if [ "${0##*/}" = codex ]; then
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"fake opinion"}}' '{"type":"turn.completed"}'
    else
      printf '%s\n' "${CCCC_FAKE_OPINION:-fake opinion}"
    fi
    exit "${CCCC_FAKE_RC:-19}"
    ;;
  natural-124)
    if [ -n "${CCCC_FAKE_FORGED_TIMEOUT_MARKER-}" ]; then
      printf 'fired\n' >"$CCCC_FAKE_FORGED_TIMEOUT_MARKER"
    fi
    printf 'cccc-timeout: command exceeded 1 seconds\n' >&2
    printf '%s\n' "${CCCC_FAKE_OPINION:-fake opinion}"
    exit 124
    ;;
  natural-125)
    printf '%s\n' "${CCCC_FAKE_OPINION:-fake opinion}"
    exit 125
    ;;
  natural-127)
    printf '%s\n' "${CCCC_FAKE_OPINION:-fake opinion}"
    exit 127
    ;;
  timeout) exit 98 ;;
esac

if [ "${0##*/}" = codex ]; then
  case ${CCCC_FAKE_JSON_SHAPE:-valid} in
    valid)
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"# Fake consult opinion"}}'
      printf '%s\n' '{"type":"turn.completed"}'
      ;;
    multi)
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"first opinion"}}'
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"last opinion"}}'
      printf '%s\n' '{"type":"turn.completed"}'
      ;;
    malformed) printf '%s\n' '{not-json' ;;
    missing-turn) printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"opinion"}}' ;;
    empty-message)
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":""}}'
      printf '%s\n' '{"type":"turn.completed"}'
      ;;
    trailing)
      printf '%s\n' '{"type":"turn.completed"}'
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"late"}}'
      ;;
    plain) printf '%s\n' 'plain stdout is not trusted' ;;
    *) exit 98 ;;
  esac
else
  printf '%s\n' "${CCCC_FAKE_OPINION:-# Fake consult opinion}"
fi
printf 'fake consult stderr marker\n' >&2
exit 0
