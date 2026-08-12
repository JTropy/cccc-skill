# cccc — Claude Code Codex Collaboration

`cccc` 是一个让 Claude Code 与 Codex 协作的通用 skill。同一份 skill 同时安装在两个宿主中，会根据当前编排上下文自动识别当前宿主，并把任务路由给另一端：Claude Code 调用 Codex，Codex 调用 Claude Code。底层 wrapper 仍保留显式目标参数，便于审计和排障。

它让两端不只是“互相问一句”，而是按明确边界发挥各自能力：

- **Claude Code → Codex**：可把生图、图片编辑等视觉任务交给 Codex 的 `$imagegen` 能力。
- **Codex → Claude Code**：可把顶层设计、架构推演和方案评审交给 Claude Code，并在当前环境支持时请求 Fable 5。

`$imagegen`、Fable 5、具体模型、effort、网络和供应商能力都需要根据当前 CLI、账号、供应商与工作区实际验证；本 skill 不承诺它们在所有环境中可用。

## 它如何协作

当前宿主始终是编排者，另一端是受边界约束的协作伙伴。`cccc` 提供两条正式通道：

| 通道 | 用途 | 发布产物 |
|---|---|---|
| `delegate` | 在任务卡允许的路径内执行受限仓库实现 | 报告与审计日志 |
| `consult` | 在不授权实施的前提下进行独立分析、批评或方案评审 | 意见与审计日志 |

使用同一份 skill 的路由规则如下：

- 当前是 Claude Code：选择 Codex 作为 peer。
- 当前是 Codex：选择 Claude Code 作为 peer。
- 不把自己再次选为目标，也不根据某个可执行文件是否存在来猜测身份。

## 安全与授权边界

发现这个 skill 不等于获得启动另一个 CLI 的权限。只有用户明确提出 cccc/4C、本地 peer 协作或 wrapper 调用，或者编排者提出建议后得到确认，才可以启动另一端。

wrapper 提供无覆盖发布、进程超时、仓库级串行化，以及运行前后的 Git 可见变更审计。它不是操作系统沙箱：Git 元数据、Git ignored 路径、同一用户可读取的文件、密钥，以及故意脱离管理的进程，仍有部分处于该边界之外。不可信仓库应放进外部容器和隔离 worktree。

退出码 `0` 才是成功依据；仅看到报告、意见或日志文件存在，不代表任务成功。`consult` 的意见只是建议，不授权代码修改；所有结果都必须由当前编排者复核。

## 环境要求

- Git、Bash 3.2+ 与 Python 3
- `claude` 和 `codex` 均可从 `PATH` 调用
- 目标 peer CLI 已完成可用认证
- Git 仓库中存在任务卡或讨论卡
- Windows 使用 Git Bash

## 在 macOS 或 Linux 上安装

保留一份稳定 checkout，只把其中规范的 `skills/cccc` 目录链接到两个宿主：

```bash
install_root="${XDG_DATA_HOME:-$HOME/.local/share}/cccc-skill"
git clone https://github.com/JTropy/cccc-skill.git "$install_root"
mkdir -p "$HOME/.agents/skills" "$HOME/.claude/skills"
ln -s "$install_root/skills/cccc" "$HOME/.agents/skills/cccc"
ln -s "$install_root/skills/cccc" "$HOME/.claude/skills/cccc"
chmod +x "$install_root/skills/cccc/scripts/"*.sh
```

用户级规范路径：

- Codex：`~/.agents/skills/cccc`
- Claude Code：`~/.claude/skills/cccc`

项目级安装使用 `<repo>/.agents/skills/cccc` 与 `<repo>/.claude/skills/cccc`。

## 在 Windows 上安装

在 PowerShell 中先克隆真实目标，再创建两个父目录和两个 Junction：

```powershell
$InstallRoot = "$env:LOCALAPPDATA\cccc-skill"
git clone https://github.com/JTropy/cccc-skill.git $InstallRoot
New-Item -ItemType Directory -Force "$env:USERPROFILE\.agents\skills" | Out-Null
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\skills" | Out-Null
New-Item -ItemType Junction -Path "$env:USERPROFILE\.agents\skills\cccc" -Target "$InstallRoot\skills\cccc"
New-Item -ItemType Junction -Path "$env:USERPROFILE\.claude\skills\cccc" -Target "$InstallRoot\skills\cccc"
```

如果某个宿主版本无法跟随目录链接，只对该宿主使用复制兜底：

```powershell
Copy-Item -Recurse "$InstallRoot\skills\cccc" "$env:USERPROFILE\.claude\skills\cccc"
```

复制安装需要手动保持同步。不要在已有 `cccc` 目录内再叠加第二个 `cccc` 目录。

## 从 v1 迁移

v2 将可安装入口从仓库根目录移动到 `skills/cccc`，并把 Codex 的规范用户级位置迁移到 `.agents`。

1. 解析并记录当前链接或目录的真实目标。
2. 创建稳定的 v2 checkout，不改动当前安装。
3. 创建指向 `<checkout>/skills/cccc` 的临时链接或 Junction。
4. 通过临时路径运行 validator 与 wrapper 用法检查。
5. 把旧入口重命名为备份，再将验证通过的新入口切换到规范路径。

`~/.codex/skills/cccc` 只属于旧版路径。先保留它，等 `~/.agents/skills/cccc` 验证通过后，再只删除这一条明确的旧链接或副本。不要递归删除宽泛的 skills 目录，也不要删除尚未解析真实目标的链接。

skill 变更通常会被自动发现。如果规范文件验证通过但 `$cccc` 仍未出现，可以重启对应宿主；重启仅作为兜底，不是每次更新的必需步骤。

## 更新、回滚与卸载

不要原地更新正在使用的 checkout。先创建独立、带版本号的 candidate，完成验证后再切换；当前链接与 checkout 始终作为回滚基础：

```bash
set -eu
base="${XDG_DATA_HOME:-$HOME/.local/share}"
release_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
candidate="$base/cccc-skill.candidate.$release_id"
codex_live="$HOME/.agents/skills/cccc"
claude_live="$HOME/.claude/skills/cccc"
codex_next="$codex_live.next.$release_id"
claude_next="$claude_live.next.$release_id"
codex_backup="$codex_live.rollback.$release_id"
claude_backup="$claude_live.rollback.$release_id"
codex_failed="$codex_live.failed.$release_id"
claude_failed="$claude_live.failed.$release_id"

[ -L "$codex_live" ] && [ -L "$claude_live" ]
readlink "$codex_live"
readlink "$claude_live"
recover_switch() {
  rc=$1
  trap - EXIT HUP INT TERM
  if [ -L "$claude_backup" ]; then
    [ ! -L "$claude_live" ] || mv "$claude_live" "$claude_failed" || true
    if [ ! -e "$claude_live" ] && [ ! -L "$claude_live" ]; then
      mv "$claude_backup" "$claude_live" || true
    fi
  fi
  if [ -L "$codex_backup" ]; then
    [ ! -L "$codex_live" ] || mv "$codex_live" "$codex_failed" || true
    if [ ! -e "$codex_live" ] && [ ! -L "$codex_live" ]; then
      mv "$codex_backup" "$codex_live" || true
    fi
  fi
  [ ! -L "$codex_next" ] || unlink "$codex_next"
  [ ! -L "$claude_next" ] || unlink "$claude_next"
  printf 'cccc update failed; inspect preserved candidate and versioned links\n' >&2
  exit "$rc"
}
trap 'recover_switch $?' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

git clone https://github.com/JTropy/cccc-skill.git "$candidate"
python3 "$candidate/tests/validate_skill.py" "$candidate/skills/cccc"
ln -s "$candidate/skills/cccc" "$codex_next"
ln -s "$candidate/skills/cccc" "$claude_next"

mv "$codex_live" "$codex_backup"
mv "$codex_next" "$codex_live"
mv "$claude_live" "$claude_backup"
mv "$claude_next" "$claude_live"
trap - EXIT HUP INT TERM
```

带版本号的名称让后续更新不依赖上一轮 candidate 或备份。如果验证失败，fail-fast 会让 live 链接保持不变，并保留 candidate。如果克隆、暂存链接或切换失败，流程会保留或恢复 live 链接，只移除本轮创建的暂存链接，并保留 candidate 与可能存在的 `.failed` 链接供排查。

切换后需要回滚时，把每个 live 链接重命名为 `.failed`，再将对应的 `.rollback` 链接移回规范名称。旧 checkout 与失败的 candidate 都应保留以供检查。Windows 采用相同的 candidate-first 顺序，通过两个暂存 Junction 与 `Rename-Item` 完成切换；验证前不要修改 live Junction 背后的目标。

不要删除任务卡、讨论卡、报告、意见、日志或任何项目仓库。

卸载前，先解析每个路径并确认它确实是 cccc 的链接、Junction 或复制目录。只移除 `~/.agents/skills/cccc` 与 `~/.claude/skills/cccc`，必要时再移除已经确认的旧版路径。默认保留或归档中立 checkout，并保留所有项目数据；不要删除更上层的 skills 目录。

## 最小用法

从 [`task-card.md`](skills/cccc/assets/task-card.md) 创建任务卡，然后把受限实现交给另一端 CLI：

```bash
bash /absolute/path/to/skills/cccc/scripts/delegate.sh \
  <claude|codex> docs/tasks/T-001.md
```

从 [`discussion-card.md`](skills/cccc/assets/discussion-card.md) 创建讨论卡，然后向另一端请求独立意见：

```bash
bash /absolute/path/to/skills/cccc/scripts/consult.sh \
  <claude|codex> docs/discussions/D-001.md
```

这里的 `<claude|codex>` 是供审计和排障使用的显式底层目标：上层 skill 已根据当前宿主选择另一端，wrapper 调用时把该 peer 明确传入。

## 规范文档

- [Skill 路由与授权](skills/cccc/SKILL.md)
- [`delegate` 工作流](skills/cccc/references/delegate.md)
- [`consult` 工作流](skills/cccc/references/consult.md)
- [安装与认证](skills/cccc/references/setup.md)
- [故障排查](skills/cccc/references/troubleshooting.md)

## 许可证

[MIT](LICENSE)
