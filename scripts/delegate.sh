#!/usr/bin/env bash
# cccc (cross-codex-claude-code) — 把任务卡交给本机另一个 coding agent headless 执行
#
# 用法:
#   delegate.sh <claude|codex|auto> <task-file.md> [workdir]
#   （Windows 下经 Git Bash 调用: bash <skill目录>/scripts/delegate.sh ...）
#
# 环境变量:
#   DELEGATE_MODEL    模型覆盖, 只许向上加码 (claude: 低于 opus 会被强制抬回; codex: mini/nano 会被忽略)
#   DELEGATE_TIMEOUT  超时秒数, 默认 3600
#   DELEGATE_SANDBOX  edit | auto(默认) | full   档位含义见 SKILL.md
#
# 算力策略 (硬性, 效果优先):
#   claude 子代理: 最低 opus + --effort max
#   codex  子代理: 跟随 ~/.codex/config.toml 的最新 GPT + model_reasoning_effort=xhigh
#
# 约定 (均相对 workdir):
#   任务卡    docs/tasks/T-xxx.md
#   回执      docs/tasks/T-xxx-report.md        (由子代理写)
#   日志      docs/tasks/T-xxx.log              (本脚本写, 含子代理全部输出)
#   兜底回执  docs/tasks/T-xxx-last-message.txt (codex -o 落盘的最后一条消息)
#
# 退出码: 子代理进程的退出码; 124=超时; 2=参数错误; 3=嵌套委派被拦截; 127=对方 CLI 未安装
set -uo pipefail

err() { echo "[delegate] $*" >&2; }

# ── 防套娃（机制层）: 子代理继承本环境变量, 任何嵌套调用直接被拒 ──
if (( ${DELEGATE_DEPTH:-0} >= 1 )); then
  err "检测到嵌套委派 (DELEGATE_DEPTH=${DELEGATE_DEPTH})。子代理禁止再委派, 已拦截。"
  exit 3
fi
export DELEGATE_DEPTH=1

TARGET="${1:-}"
TASK_FILE="${2:-}"
WORKDIR="${3:-$PWD}"

if [[ -z "$TARGET" || -z "$TASK_FILE" ]]; then
  err "用法: delegate.sh <claude|codex|auto> <task-file.md> [workdir]"
  exit 2
fi

cd "$WORKDIR" || { err "无法进入工作目录: $WORKDIR"; exit 2; }

# auto 仅作兜底: 优先显式传 claude/codex。
# CLAUDECODE 由 Claude Code 注入其 shell; CODEX_SANDBOX* 由 Codex 沙箱注入。
if [[ "$TARGET" == "auto" ]]; then
  if [[ -n "${CLAUDECODE:-}" ]]; then
    TARGET="codex"
  elif [[ -n "${CODEX_SANDBOX:-}${CODEX_SANDBOX_NETWORK_DISABLED:-}" ]]; then
    TARGET="claude"
  else
    err "无法自动识别当前环境, 请显式指定目标: claude 或 codex"
    exit 2
  fi
fi

case "$TARGET" in claude|codex) ;; *) err "目标只能是 claude 或 codex (或 auto)"; exit 2 ;; esac

command -v "$TARGET" >/dev/null 2>&1 || {
  err "找不到 $TARGET CLI。请先安装并完成登录 (见 references/setup.md)"
  exit 127
}

[[ -f "$TASK_FILE" ]] || { err "任务卡不存在: $WORKDIR/$TASK_FILE"; exit 2; }

# ── 算力策略归一化 (硬性, 效果优先): 在输出重定向前处理, 让告警上控制台 ──
MODEL="${DELEGATE_MODEL:-}"
if [[ "$TARGET" == "claude" ]]; then
  MODEL="${MODEL:-opus}"
  case "$MODEL" in
    *haiku*|*sonnet*) err "效果优先: 已忽略低配模型 $MODEL, 强制使用 opus"; MODEL="opus" ;;
  esac
elif [[ -n "$MODEL" ]]; then
  case "$MODEL" in
    *mini*|*nano*) err "效果优先: 已忽略低配模型 $MODEL, 使用 config.toml 默认 (最新 GPT)"; MODEL="" ;;
  esac
fi

REPORT_FILE="${TASK_FILE%.md}-report.md"
LOG_FILE="${TASK_FILE%.md}.log"
LASTMSG_FILE="${TASK_FILE%.md}-last-message.txt"
TIMEOUT="${DELEGATE_TIMEOUT:-3600}"
SANDBOX="${DELEGATE_SANDBOX:-auto}"

# git 工作区检查: 不干净只警告不阻断, 由编排方自行判断
HEAD_BEFORE="(no-git)"
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  HEAD_BEFORE="$(git rev-parse HEAD 2>/dev/null || echo '(no-commit)')"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    err "警告: git 工作区不干净。建议先 commit/stash, 否则 diff 验收会混入无关改动。"
  fi
else
  err "警告: 当前不在 git 仓库内。codex exec 会拒绝运行, 且无法用 diff 验收。"
fi

PROMPT="你是被委派的子代理。读取 ${TASK_FILE} 并严格按其执行。规则: \
1) 只改动任务卡允许的文件范围; \
2) 不要 git commit / git push; \
3) 不要再委派给任何其他 agent, 不要调用 claude 或 codex CLI; \
4) 完成后把变更摘要、运行与验证方式、已知问题写入 ${REPORT_FILE}。"

# macOS 原生无 timeout, 退化为不限时 (coreutils 的 gtimeout 可补)
# -k 30: TERM 后 30s 仍不退出则 KILL, 避免残留进程
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
run_with_timeout() {
  if [[ -n "$TIMEOUT_BIN" ]]; then "$TIMEOUT_BIN" -k 30 "$TIMEOUT" "$@"; else
    err "提示: 未找到 timeout 命令, 本次不限时运行"
    "$@"
  fi
}

run_claude() {
  # 模型已在上方归一化 (最低 opus); text 格式: 日志即最终回复, 排障可读性优先
  local args=(-p "$PROMPT" --output-format text --model "$MODEL" --effort max)
  case "$SANDBOX" in
    edit)      args+=(--permission-mode acceptEdits) ;;
    auto|full) args+=(--dangerously-skip-permissions) ;;
    *) err "未知 DELEGATE_SANDBOX=$SANDBOX (可选 edit|auto|full)"; exit 2 ;;
  esac
  run_with_timeout claude "${args[@]}"
}

run_codex() {
  # 模型已在上方归一化 (mini/nano 被剔除, 空 = config.toml 的最新 GPT); 推理强度硬性 xhigh
  # --sandbox 是 0.13x 文档化参数 (--full-auto 已退化为隐藏遗留别名, 不再依赖)
  local args=(exec --output-last-message "$LASTMSG_FILE" -c model_reasoning_effort=xhigh)
  case "$SANDBOX" in
    edit) args+=(--sandbox workspace-write) ;;
    auto) args+=(--sandbox workspace-write -c sandbox_workspace_write.network_access=true) ;;
    full) args+=(--dangerously-bypass-approvals-and-sandbox) ;;
    *) err "未知 DELEGATE_SANDBOX=$SANDBOX (可选 edit|auto|full)"; exit 2 ;;
  esac
  [[ -n "$MODEL" ]] && args+=(--model "$MODEL")
  run_with_timeout codex "${args[@]}" "$PROMPT"
}

err "委派给 $TARGET | 任务卡: $TASK_FILE | 模型: ${MODEL:-latest-gpt(config)} | 档位: $SANDBOX | 超时: ${TIMEOUT}s | 日志: $LOG_FILE"
START=$(date +%s)
case "$TARGET" in
  claude) run_claude >"$LOG_FILE" 2>&1 ;;
  codex)  run_codex  >"$LOG_FILE" 2>&1 ;;
esac
RC=$?
DUR=$(( $(date +%s) - START ))

[[ $RC -eq 124 ]] && err "子代理超时 (${TIMEOUT}s) 被终止。工作区可能留有半成品, 先 git status/diff 再决定回滚或续做。"

echo "=== delegate 结果 ==="
echo "目标: $TARGET | 退出码: $RC | 耗时: ${DUR}s"
echo "日志: $LOG_FILE"

# HEAD 校验: 子代理违规 commit 会让 git diff 看似干净, 必须显式抓出来
if [[ "$HEAD_BEFORE" != "(no-git)" ]]; then
  HEAD_AFTER="$(git rev-parse HEAD 2>/dev/null || echo '(no-commit)')"
  if [[ "$HEAD_AFTER" != "$HEAD_BEFORE" ]]; then
    echo "!!! 警告: HEAD 发生变化 ($HEAD_BEFORE -> $HEAD_AFTER)"
    echo "!!! 子代理违规执行了 commit。审查: git log $HEAD_BEFORE..HEAD; 必要时 git reset --soft $HEAD_BEFORE"
  fi
fi

if [[ -f "$REPORT_FILE" ]]; then
  echo "回执: $REPORT_FILE"
  echo "--- 回执内容 ---"
  cat "$REPORT_FILE"
elif [[ -s "$LASTMSG_FILE" ]]; then
  echo "回执缺失, 以下为子代理最后一条消息 ($LASTMSG_FILE):"
  cat "$LASTMSG_FILE"
else
  echo "回执缺失: 子代理没有写 $REPORT_FILE, 日志末尾如下:"
  tail -n 30 "$LOG_FILE" 2>/dev/null || true
fi
echo "下一步: git diff --stat 审查改动, 并执行任务卡中的验收命令。"
# DONE 标记写进日志: 进程包装层(后台任务/超时收割)可能谎报完成, 以此标记为准
echo "[delegate] DONE rc=$RC dur=${DUR}s $(date '+%F %T')" >>"$LOG_FILE"
exit "$RC"
