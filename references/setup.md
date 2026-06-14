# 安装与一次性配置

## 1. 把 skill 装进两侧

同一份 SKILL.md 格式，Claude Code 和 Codex 都能读。把整个 `cccc/` 文件夹放进：

| Agent | 个人级（全局） | 项目级 |
|---|---|---|
| Claude Code | `~/.claude/skills/cccc/` | `<repo>/.claude/skills/cccc/` |
| Codex | `~/.codex/skills/cccc/` | `<repo>/.codex/skills/cccc/` |

推荐只保留一份真身、另一侧做链接，改一处两边生效（Codex 支持链接形式的 skill 目录）。

macOS / Linux（以 Claude Code 侧为真身）：

```bash
mkdir -p ~/.claude/skills ~/.codex/skills
cp -r cccc ~/.claude/skills/
ln -s ~/.claude/skills/cccc ~/.codex/skills/cccc
chmod +x ~/.claude/skills/cccc/scripts/delegate.sh
```

Windows（junction 不需要管理员权限，也不依赖开发者模式）：

```powershell
New-Item -ItemType Junction -Path "$env:USERPROFILE\.codex\skills\cccc" -Target "$env:USERPROFILE\.claude\skills\cccc"
```

注意：
- Codex 在启动时加载 skills 元数据，**新增或修改 skill 后要重启 Codex** 才生效。Codex 里可用 `$cccc` 显式触发，或靠 description 自动触发。
- Windows 下脚本经 Git Bash 运行（装了 git 就有）：`bash <skill目录>/scripts/delegate.sh ...`。Codex 编排方在 Windows 上若默认 shell 是 PowerShell，同样写 `bash ...` 即可。
- 改名/迁移本 skill 时，记得把**两侧**的目录/链接一起处理，并检查各项目级副本。

## 2. 放行编排方的网络

**Codex 侧必做**：Codex 默认沙箱（workspace-write）不允许网络访问，导致它 spawn 的 `claude` 子进程调不到 Anthropic API（或你的自建中转）。在 `~/.codex/config.toml` 加：

```toml
[sandbox_workspace_write]
network_access = true
```

或仅对单次会话放行：`codex -c 'sandbox_workspace_write.network_access=true'`。

**Claude Code 侧视平台而定**：Windows 上 Bash 工具没有 OS 级网络沙箱，spawn `codex` 直接可用（已实测）；macOS/Linux 若启用了沙箱模式（/sandbox），spawn 的 `codex` 可能断网，表现为卡住或 API 报错——对该次调用关闭沙箱，或在沙箱配置里放行对应 API 域名。

`codex exec` 子代理自身要联网（装依赖、调 image_gen 等）时，由 delegate.sh 的 `auto` 档自动追加 `-c sandbox_workspace_write.network_access=true`。

## 3. CLI 认证与算力前提

- `claude`：已登录订阅账号，或配置 `ANTHROPIC_API_KEY`（自建中转再加 `ANTHROPIC_BASE_URL`）。
- `codex`：已 `codex login`，或配置 `OPENAI_API_KEY` / config.toml 里的自定义 provider。
- 生图依赖 Codex 侧的 image_gen 工具或 OpenAI 图像 API 可用（自建中转需支持图像端点）。

**算力策略是硬编码的（效果优先）**，接收方需要满足：

- claude 账号/中转必须有 **opus** 权限（脚本强制 `--model opus --effort max`，低配模型会被拒绝降级）。
- codex 版本需支持 `model_reasoning_effort=xhigh`（0.13x 起）。
- codex 的「最新 GPT」由 `~/.codex/config.toml` 的 `model` 字段维护——升级新模型只改那里，cccc 自动跟随；脚本不锁死具体型号，避免过期。

子进程继承编排方 shell 的环境变量，所以编排方环境里配好即可。

## 4. 项目级路由策略（可选但推荐）

在项目根目录的 `AGENTS.md` / `CLAUDE.md` 里写一段分工，编排方会优先遵守，例如：

```markdown
## Delegation policy
- frontend/ 下的 UI、组件、样式任务 → 委派给 claude（用 cccc skill）
- 批量重构、数据迁移脚本、测试补全 → 委派给 codex
- 一切位图素材生成（icon/logo/插画/banner）→ 委派给 codex（image_gen）
- 接口契约以 docs/api.md 为准，双方只读不改
```

提示：若你的 Claude Code 版本不自动读 AGENTS.md，在 CLAUDE.md 里放一行 `@AGENTS.md` 导入即可共享同一份说明。

## 5. 快速自检

```bash
command -v claude codex              # 两个 CLI 都在 PATH 上
bash ~/.claude/skills/cccc/scripts/delegate.sh 2>&1 | head -1   # 应打印用法行（干活通道）
bash ~/.claude/skills/cccc/scripts/consult.sh  2>&1 | head -1   # 应打印用法行（商讨通道）
mkdir -p docs/tasks docs/discussions # 任务卡 / 议题卡目录
git rev-parse --is-inside-work-tree  # codex exec 要求在 git 仓库内
```
