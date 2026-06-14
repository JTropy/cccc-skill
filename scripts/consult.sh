#!/usr/bin/env bash
# cccc (cross-codex-claude-code) — 重大设计商讨: 向对方 agent 要一份只读的顶配第二意见
#
# 与 delegate.sh 的区别: 对方是顾问不是工人——机制级只读(改不了任何文件), 观点由本脚本捕获落盘。
# 商讨产物永远不直接执行, 由编排方综合成决策简报交用户拍板。
#
# 用法:
#   consult.sh <claude|codex|auto> <discussion-file.md> [workdir]
#   （Windows 下经 Git Bash 调用: bash <skill目录>/scripts/consult.sh ...）
#
# 环境变量:
#   DELEGATE_MODEL    模型覆盖, 只许向上加码 (同 delegate.sh)
#   DELEGATE_TIMEOUT  超时秒数, 默认 1800
#
# 算力策略 (硬性, 顶配商讨):
#   claude 顾问: 最低 opus + --effort max + 只读 plan 权限模式
#   codex  顾问: config.toml 最新 GPT + model_reasoning_effort=xhigh + --sandbox read-only
#
# 约定 (均相对 workdir):
#   议题卡  docs/discussions/D-xxx.md      (编排方写; 多轮时另起 D-xxx-r2.md 并附上一轮观点)
#   观点    docs/discussions/D-xxx-<对方>-opinion.md  (本脚本捕获写入, 对方无写权限)
#   日志    docs/discussions/D-xxx-<对方>.log
#
# 退出码: 顾问进程的退出码; 124=超时; 2=参数错误; 3=嵌套被拦截; 127=对方 CLI 未安装
set -uo pipefail

err() { echo "[consult] $*" >&2; }

# ── 防套娃: 与 delegate.sh 共用 DELEGATE_DEPTH, 子代理/顾问都不许再发起任何委派或商讨 ──
if (( ${DELEGATE_DEPTH:-0} >= 1 )); then
  err "检测到嵌套商讨 (DELEGATE_DEPTH=${DELEGATE_DEPTH})。子代理/顾问禁止再发起, 已拦截。"
  exit 3
fi
export DELEGATE_DEPTH=1

TARGET="${1:-}"
TOPIC_FILE="${2:-}"
WORKDIR="${3:-$PWD}"

if [[ -z "$TARGET" || -z "$TOPIC_FILE" ]]; then
  err "用法: consult.sh <claude|codex|auto> <discussion-file.md> [workdir]"
  exit 2
fi

cd "$WORKDIR" || { err "无法进入工作目录: $WORKDIR"; exit 2; }

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

[[ -f "$TOPIC_FILE" ]] || { err "议题卡不存在: $WORKDIR/$TOPIC_FILE"; exit 2; }

# ── 算力策略归一化 (硬性, 顶配): 商讨必须用对方最强配置 ──
MODEL="${DELEGATE_MODEL:-}"
if [[ "$TARGET" == "claude" ]]; then
  MODEL="${MODEL:-opus}"
  case "$MODEL" in
    *haiku*|*sonnet*) err "顶配商讨: 已忽略低配模型 $MODEL, 强制使用 opus"; MODEL="opus" ;;
  esac
elif [[ -n "$MODEL" ]]; then
  case "$MODEL" in
    *mini*|*nano*) err "顶配商讨: 已忽略低配模型 $MODEL, 使用 config.toml 默认 (最新 GPT)"; MODEL="" ;;
  esac
fi

OPINION_FILE="${TOPIC_FILE%.md}-${TARGET}-opinion.md"
LOG_FILE="${TOPIC_FILE%.md}-${TARGET}.log"
TIMEOUT="${DELEGATE_TIMEOUT:-1800}"

# codex exec 仍要求在 git 仓库内; 商讨只读, 无需干净工作区
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  err "警告: 当前不在 git 仓库内, codex exec 会拒绝运行。"
fi

PROMPT="你是被请来商讨重大设计的对方专家顾问, 处于只读模式(任何写入都会被系统拒绝)。\
读取 ${TOPIC_FILE} 与其中列出的必读文件, 必要时自行检索仓库代码, 然后严格按议题卡的输出要求作答。规则: \
1) 不要尝试修改任何文件, 不要 git commit (写/执行类工具已被系统禁用, 尝试只会浪费回合); \
2) 不要调用 claude 或 codex CLI, 不要再咨询任何其他 agent; \
3) 你的最终回复会被原样存档为观点文件, 必须是一份自包含的结构化 Markdown(开头用一级标题注明议题编号), 不要寒暄不要复述题面; \
4) 观点要可执行可比较: 给结论、给理由、给风险代价、给与备选方案的对比, 立场要明确, 不要和稀泥。"

TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
run_with_timeout() {
  if [[ -n "$TIMEOUT_BIN" ]]; then "$TIMEOUT_BIN" -k 30 "$TIMEOUT" "$@"; else
    err "提示: 未找到 timeout 命令, 本次不限时运行"
    "$@"
  fi
}

err "商讨对象 $TARGET | 议题卡: $TOPIC_FILE | 模型: ${MODEL:-latest-gpt(config)}(顶配) | 只读 | 超时: ${TIMEOUT}s"
START=$(date +%s)
RC=0
case "$TARGET" in
  claude)
    # 机制级只读 = 禁用全部写/执行工具 (不用 plan 模式: headless 下 ExitPlanMode 收尾会吞掉最终文本)
    # text 格式 stdout 即完整观点, 直接落盘
    args=(-p "$PROMPT" --output-format text --model "$MODEL" --effort max
          --disallowedTools "Write,Edit,MultiEdit,NotebookEdit,Bash,KillShell,ExitPlanMode")
    run_with_timeout claude "${args[@]}" >"$OPINION_FILE" 2>"$LOG_FILE" || RC=$?
    ;;
  codex)
    # read-only 沙箱 = 机制级只读; 观点经 -o 由 CLI 落盘(不受沙箱限制)
    args=(exec --sandbox read-only -c model_reasoning_effort=xhigh --output-last-message "$OPINION_FILE")
    [[ -n "$MODEL" ]] && args+=(--model "$MODEL")
    run_with_timeout codex "${args[@]}" "$PROMPT" >"$LOG_FILE" 2>&1 || RC=$?
    ;;
esac
DUR=$(( $(date +%s) - START ))

[[ $RC -eq 124 ]] && err "顾问超时 (${TIMEOUT}s) 被终止, 可加大 DELEGATE_TIMEOUT 重试"

echo "=== consult 结果 ==="
echo "对象: $TARGET | 退出码: $RC | 耗时: ${DUR}s"
echo "日志: $LOG_FILE"
if [[ -s "$OPINION_FILE" ]]; then
  echo "观点: $OPINION_FILE"
  echo "--- 观点内容 ---"
  cat "$OPINION_FILE"
else
  echo "观点缺失或为空, 日志末尾如下:"
  tail -n 30 "$LOG_FILE" 2>/dev/null || true
fi
echo "下一步: 综合双方观点写决策简报, 交用户拍板; 重大分歧可发起第 2 轮(上限 2 轮)。拍板前不动手实现。"
# DONE 标记写进日志: 进程包装层(后台任务/超时收割)可能谎报完成, 以此标记为准
echo "[consult] DONE rc=$RC dur=${DUR}s $(date '+%F %T')" >>"$LOG_FILE"
exit "$RC"
