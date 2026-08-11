# cccc v2 设计

## 目标

把 cccc 从“仓库根目录即 skill 的本地脚本集合”升级为可验证、可迁移、默认安全的 Claude Code / Codex 双端协作 skill。

v2 必须做到：

- 符合 Agent Skills 的标准目录与 frontmatter 约束；
- 保留 `delegate`（可写执行）与 `consult`（只读第二意见）两条通道；
- 默认权限与文档承诺一致，不把 `auto` 偷换成完全绕过权限；
- 拒绝路径逃逸、symlink/FIFO 覆写、陈旧产物冒充和并发互相截断；
- 对 dirty worktree、违规 commit、缺失产物和超时给出确定的失败结果；
- 用自动化测试证明关键安全属性，而不再依赖“已实测”的静态描述；
- 给 v1 用户提供明确、可回退的安装迁移路径。

## 非目标

- 不把 cccc 做成常驻守护进程、MCP server 或远程队列。
- 不内置任何账号、token、模型名称或供应商密钥。
- 不替用户自动 commit、stash、reset、clean、push 或合并代码。
- 不承诺 Claude Code 与 Codex 一定具备某种模型、推理档位或生图能力；能力必须预检。
- 不保证同一 UID 下的恶意子进程无法绕过约束；v2 防止的是意外越权和错误配置，并准确说明信任边界。

## 仓库结构

```text
cccc-skill/
├── README.md
├── LICENSE
├── .gitattributes
├── .github/workflows/ci.yml
├── skills/cccc/
│   ├── SKILL.md
│   ├── agents/openai.yaml
│   ├── scripts/
│   │   ├── cccc-common.sh
│   │   ├── delegate.sh
│   │   ├── consult.sh
│   │   └── run-with-timeout.py
│   ├── references/
│   │   ├── delegate.md
│   │   ├── consult.md
│   │   ├── setup.md
│   │   └── troubleshooting.md
│   └── assets/
│       ├── task-card.md
│       └── discussion-card.md
└── tests/
    ├── validate_skill.py
    ├── test_delegate.sh
    ├── test_consult.sh
    └── fixtures/
```

`skills/cccc/` 是唯一可安装入口，目录名与 `name: cccc` 一致。README 只负责产品介绍、安装、迁移和最小示例；代理执行细节只在 `SKILL.md` 与按需 references 中维护。

## 调用与授权模型

canonical `SKILL.md` 只使用 Agent Skills 标准字段；`agents/openai.yaml` 不再关闭隐式发现。宿主可以发现 cccc，但正文第一道门必须区分：

1. 用户本轮明确写了 `cccc`、`4C`、`委派给本机 Claude/Codex` 或 `向本机对端咨询`：可在请求范围内继续。
2. 只是模型判断“对端可能更擅长”：只能建议使用 cccc，并在启动外部 CLI 前取得用户确认。
3. 用户要求自己完成、禁止委派，或项目规则禁止外部 agent：不得启动。

路由优先级固定为：用户指令 > 项目 `AGENTS.md` / `CLAUDE.md` > 已验证的本机能力 > 通用启发式。Codex 编排方不把任务“委派给自己”；Claude 只有确认对端具备可用 `$imagegen` 能力时，才把位图生成交给 Codex。

## delegate 设计

`delegate.sh <claude|codex> <task-card> [workdir]` 只接受工作区内 `docs/tasks/` 下的普通相对 Markdown 文件。绝对路径、`..`、symlink、FIFO 和越界路径直接返回参数错误。

任务卡必须包含一个机器可读的允许路径区块：

```markdown
<!-- cccc-allowed-paths
frontend/
tests/ui/
package.json
-->
```

每行表示一个仓库相对文件或目录前缀，不接受 glob、绝对路径与 `..`。wrapper 用 Git 前后快照验证本轮新增变化全部落在允许范围内；人类可读的“边界”章节仍保留，用来解释理由和禁止项。

运行前：

- 验证 CLI、Git 仓库、task card、正整数超时和 sandbox 档位；
- 默认要求 clean worktree；`CCCC_ALLOW_DIRTY=1` 仅作为显式逃生口并打印强警告；
- 记录 HEAD 与工作树快照；
- 在目标目录中创建仅本轮可见的唯一临时产物，不复用旧 report/log/last-message。

权限档位：

| 档位 | Claude Code | Codex | 网络 |
|---|---|---|---|
| `edit` | `--permission-mode acceptEdits` | `--sandbox workspace-write` | Codex 显式关闭 |
| `auto`（默认） | `--permission-mode auto` | `--sandbox workspace-write --approve-for-me` | Codex 显式开启 |
| `full` | `--dangerously-skip-permissions` | `--dangerously-bypass-approvals-and-sandbox` | 不限制；另需 `CCCC_ALLOW_FULL=1` |

模型沿用各 CLI 当前配置；`CCCC_MODEL` 与 `CCCC_EFFORT` 允许调用者显式覆盖。脚本不再声称能判断“更强模型”，也不强制升级用户模型或预算。

子代理最终回复直接作为结构化 report 捕获，由 wrapper 在确认是本轮新产物后原子发布。wrapper 发现 HEAD 改变、缺少 report、策略外文件变化或 agent 非零退出时必须返回非零，不得把旧文件当成功回执。

## consult 设计

`consult.sh <claude|codex> <discussion-card> [workdir]` 使用相同的路径、临时文件和运行新鲜度机制。

Claude 顾问采用 `--safe-mode`、`--tools Read,Glob,Grep`、`--permission-mode dontAsk`、`--disable-slash-commands` 和 `--no-session-persistence`，避免加载项目 hooks、plugins、MCP 与写执行工具。

Codex 顾问默认采用 `--ephemeral --sandbox read-only --ignore-user-config --ignore-rules`，保留 CLI 认证但不加载用户规则、MCP 与自定义 provider，形成严格模式。依赖 custom provider 的用户可显式设置 `CCCC_CODEX_CONFIG_MODE=inherit`；此时仍有文件系统只读沙箱，但 wrapper 必须警告第三方 MCP/connector 可能具有外部副作用，不能再宣称完整只读。

wrapper 在顾问运行前后比较 HEAD 与工作树快照；除 wrapper 自己发布的 opinion/log 外出现任何变化都视为只读策略失守。文档统一使用“只读第二意见”，不承诺双方一定形成共识。

## 超时与进程清理

用 Python 3 标准库实现 `run-with-timeout.py`：

- Unix 创建独立进程组，超时先发 TERM，宽限期后发 KILL；
- Windows 使用新进程组并执行 terminate/kill；
- wrapper 超时统一返回 124，同时保留原始 `agent_rc` 与 wrapper 失败原因；
- `CCCC_TIMEOUT=0` 才表示调用者明确接受不限时。

Python 3 因此成为 v2 的明确依赖；wrapper 在不同平台依次查找 `python3` 与 `python` 并验证主版本，不再在 macOS 缺少 `timeout` 时悄悄退化成无限运行。

## 安装与迁移

新的安装目标是：

- Claude Code 用户级：`~/.claude/skills/cccc`
- Codex 用户级：`~/.agents/skills/cccc`
- 项目级：`.claude/skills/cccc` 与 `.agents/skills/cccc`

推荐 clone 仓库到稳定位置，再把两侧目录链接到仓库内的 `skills/cccc/`。Windows 用 junction；`.gitattributes` 强制所有 shell 文件保持 LF。

v1 用户必须把原来指向仓库根的链接迁移到 `skills/cccc/`。旧 `~/.codex/skills/cccc` 只作为迁移提示，不再作为 canonical Codex 路径。安装文档提供检查、切换和回退命令，但不自动删除旧目录。

## 测试与验收

先写失败测试，再改实现。测试至少覆盖：

- 标准目录、frontmatter、description 长度、引用存在性与 `openai.yaml`；
- 两个 CLI 三档权限的精确 argv；
- 非法 target、timeout、绝对路径、`..`、Unicode、空格、symlink、FIFO；
- stale report/opinion、空产物、非零退出、并发运行与原子发布；
- 任务卡允许路径区块缺失、非法或与实际 diff 不一致；
- clean/dirty/unborn Git、违规 commit 和策略外文件变化；
- 正常超时、TERM/KILL、自然返回 124；
- `DELEGATE_DEPTH` 的未设置、0、1、非数字和算术表达式输入；
- Claude consult 不加载 project hook/MCP/Skill，Codex consult 使用 read-only/ephemeral；
- Linux、macOS、Windows Git Bash 的 CI 矩阵。

完成本地 mock 测试后，用全新子代理做至少三个 forward tests：delegate 路由、consult 决策、能力缺失/禁止委派。若本机认证可用，再在临时 Git 仓库做一次 Claude 与 Codex 的最小真实 smoke；所有真实测试不得触碰业务仓库。

## 发布

实现位于 `agent/cccc-v2-hardening`。通过全部本地验证、独立复审和 diff 审查后，提交并推送该分支，创建 draft PR；不自动合并，不删除用户的 v1 安装或本地主分支。
