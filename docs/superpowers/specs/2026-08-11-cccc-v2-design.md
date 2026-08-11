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
│   │   ├── publish-no-clobber.py
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

每行表示一个仓库相对文件或目录前缀，不接受 glob、绝对路径与 `..`。任一层级的 `.git` 路径组件（大小写不敏感）及其后代永不允许，因为普通仓库的 Git metadata 目录、嵌套仓库 metadata 和 linked worktree 的 `.git` 指针都不在工作树内容快照内。为与 Git 的 NTFS 防护语义一致，尾随 ASCII 点/空格的 `.git`、`git~1` 短名及其变体同样拒绝；策略路径中的 `:` 一律拒绝，以封闭 alternate data stream 与不可移植路径别名。解析策略时拒绝任何已存在的 symlink 路径组件，并验证最深的已存在父目录仍位于物理仓库根内；尚不存在的新路径仍只能得到事后审计，不能形成操作系统级写入隔离。wrapper 用 Git 前后快照验证本轮 tracked 与非 ignored untracked 变化全部落在允许范围内；Git metadata 与 Git-ignored 路径始终不在该审计边界，wrapper 每次运行都明确警告。

为避免 dirty baseline 下出现不可见的二次变化，v2 遇到 submodule/gitlink 或 Git 视为单个目录项的嵌套仓库时 fail closed；在实现递归指纹前，不把这类目录描述为已审计。人类可读的“边界”章节仍保留，用来解释理由和禁止项。

运行前：

- 验证 CLI、Git 仓库、task card、正整数超时和 sandbox 档位；
- 在任何 clean/baseline 检查或 child 启动前，取得覆盖同一 Git common-dir 的 repo-wide execution lock，并持有到最终 report 发布完成；不同卡片也不并发修改同一仓库；
- 默认要求 clean worktree；`CCCC_ALLOW_DIRTY=1` 仅作为显式逃生口并打印强警告；
- 记录 HEAD 与工作树快照；
- 在目标目录中创建仅本轮可见的唯一临时产物，不复用旧 report/log/last-message。

repo lock 使用同文件系统的唯一 ownership inode 与 no-clobber hard link 建立；EXIT 清理前必须重新证明 lock 与本轮 ownership inode 相同，不能因 signal/竞争误删另一进程的 lock。`GIT_DIR`、`GIT_WORK_TREE`、`GIT_INDEX_FILE`、`GIT_COMMON_DIR` 与 `GIT_OBJECT_DIRECTORY` 等可重定向审计对象的环境覆盖在 preflight 阶段拒绝。Python helper 用 isolated mode，Windows POSIX shim 子进程不继承 `BASH_ENV`/`ENV`。

任务卡本身及其任何祖先目录都不能落入 allowed-path 范围。child 结束后重新验证 task card 的普通文件、物理路径和内容指纹；策略检查以 pre-run 解析结果为准。changed-path 消费保持 NUL-safe，诊断/日志用十六进制或等价转义，避免换行文件名伪造 metadata。

权限档位：

| 档位 | Claude Code | Codex | 网络 |
|---|---|---|---|
| `edit` | `--permission-mode acceptEdits` | `--sandbox workspace-write` | Codex 显式关闭 |
| `auto`（默认） | `--permission-mode auto` | `--sandbox workspace-write --approve-for-me` | Codex 显式开启 |
| `full` | `--dangerously-skip-permissions` | `--dangerously-bypass-approvals-and-sandbox` | 不限制；另需 `CCCC_ALLOW_FULL=1` |

模型沿用各 CLI 当前配置；`CCCC_MODEL` 与 `CCCC_EFFORT` 允许调用者显式覆盖。脚本不再声称能判断“更强模型”，也不强制升级用户模型或预算。

子代理最终回复直接作为结构化 report 捕获。wrapper 确认本轮新产物、重新验证 card/card-parent identity 与输出空缺后，通过硬链接执行 no-clobber 原子发布；POSIX 发布固定到已验证 parent dirfd，Windows 至少拒绝 reparse parent 并在每个提交点前后复核 identity。日志先发布，report/opinion 最后发布，但调用成功的权威信号始终是 wrapper 最终退出码 `0`；消费者不得仅凭 report/opinion 存在推断成功，因为发布后的 lock 或临时目录清理仍可能失败并把最终状态提升为 `125`。目标或 repo lock 已存在、或平台不支持安全发布时失败，不退化成覆盖式 `mv`。若日志已发布而 report 提交失败，保留孤儿日志作为失败诊断并明确提示人工删除后重试；若 report 已发布后清理失败，同样保留现场、返回 `125` 且不打印成功提示。wrapper 发现 HEAD 改变、card/祖先变化、缺少 report、策略外文件变化或 agent 非零退出时必须返回非零，不得把旧文件当成功回执。同一仓库的 cccc 执行被序列化。

失败优先级固定为：timeout/interruption cleanup failure `125` > HEAD/card/snapshot/path-policy violation `4` > 可信 runner timeout `124` > child nonzero `70`；`5` 仅用于 agent 启动前的输出/lock 冲突、空或不安全产物及发布阶段失败。所有组合仍在 stderr 记录原始 child outcome。

## consult 设计

`consult.sh <claude|codex> <discussion-card> [workdir]` 使用相同的路径、临时文件和运行新鲜度机制。

Claude 顾问采用 `--safe-mode`、`--tools Read,Glob,Grep`、`--permission-mode dontAsk`、`--disable-slash-commands`、`--no-session-persistence` 与 `--no-chrome`。再配合空 MCP 配置和 strict MCP 校验作纵深防御，使普通项目 CLAUDE.md、skills、plugins、hooks、MCP、commands 与 agents 不进入本轮；管理员强制设置、认证/API 请求和进程本身仍不属于 OS 级只读隔离。

Codex 顾问默认使用 `strict` 配置模式：从本轮 `0700` 私有空目录启动，以绝对路径在 prompt 中指向仓库与 discussion card，并通过 `--add-dir` 只把仓库加入 read-only 会话；不得以仓库作为 cwd。调用保留 `--ephemeral --sandbox read-only --ignore-user-config --ignore-rules --skip-git-repo-check`，同时固定官方 `openai` provider，关闭 project docs、bundled skill instructions、hooks、plugins、apps、browser/computer-use、memories、multi-agent、image generation、workspace dependency/skill discovery、shell snapshot 等可扩展工具面。wrapper 必须预检当前 CLI 支持全部安全参数和 feature 名；缺一项即 fail closed，不静默降级。该模式隔离普通用户与项目配置，但管理员/managed policy 仍可生效，因此只称“受限工具面并经 Git 审计的只读第二意见”，不称 OS 级隔离。

依赖 custom provider 的用户可显式设置 `CCCC_CODEX_CONFIG_MODE=inherit`。inherit 仍从私有空 cwd 启动、使用 read-only sandbox 并关闭项目发现，但继承用户 provider/config；wrapper 必须明确警告第三方 MCP、connector、plugin、hook 或 provider 可能产生仓库外副作用，不能称 strict。空 `mcp_servers={}` 不是清空已合并 MCP 配置的安全机制，不作为隔离手段。

consult 与 delegate 复用同一 physical Git common-dir repo-wide ownership lock，在 baseline/CLI 前取得并持有到 opinion 最终发布；不同 target、不同 discussion card、两个 linked worktree 也不得并发。discussion card 及祖先、输出 parent identity、可信 timeout status、signal/descendant 清理、no-clobber 发布与半发布孤儿日志语义全部沿用 delegate 的安全原语，不再使用 per-topic mkdir claim。

consult 默认要求 clean worktree；显式使用 dirty 逃生口时，wrapper 对所有 Git tracked 与非 ignored untracked 路径做内容指纹快照，并警告 Git metadata 与 ignored 路径不在审计边界内。顾问运行前后 HEAD、card/ancestor identity 或该快照出现任何变化都视为只读策略失守。观点与日志都带 target 后缀，使同一议题可分别咨询两端；第一轮产物会使第二轮默认遇到 dirty worktree，调用者须先归档/提交，或显式使用 dirty escape 并接受警告。文档统一使用“只读第二意见”，不承诺双方一定形成共识。

## 超时与进程清理

用 Python 3 标准库实现 `run-with-timeout.py`：

- Unix 创建独立进程组，超时先发 TERM，宽限期后发 KILL；
- Windows 使用新进程组与 kill-on-close Job Object 清理整棵子进程树；
- wrapper 在成功完成超时清理后返回 124，同时保留原始 `agent_rc` 与 wrapper 失败原因；
- 124 只表示 deadline 已触发且子进程清理完成；若 signal/job/reap 清理失败则返回 125，避免把残留进程伪装成普通超时；
- `CCCC_TIMEOUT=0` 才表示调用者明确接受不限时。

helper 的可选私有 status file 由 runner 以 no-clobber 方式创建并写入 versioned outcome；它区分 child 自然 `2/124/125/127`、launch、timeout 与 cleanup，stderr marker 只作人类诊断，不再作为 wrapper 判定依据。POSIX direct child 自然退出后仍检查其原 process group，清理残留 descendants 后才返回；无法有界证明 group 消失则返回 125。

helper 在启动子进程前把 timeout 限制到所有支持平台都可安全表示的上界；超过上界的十进制输入按参数错误拒绝并显示上限。runner 被 SIGINT/SIGTERM/SIGHUP 中断时先清理子树，再恢复原信号语义。

Python 3 因此成为 v2 的明确依赖；wrapper 在不同平台依次查找 `python3` 与 `python` 并验证主版本，不再在 macOS 缺少 `timeout` 时悄悄退化成无限运行。

Windows 的 timeout helper 只执行已解析的 native executable，拒绝把 `.cmd`/`.bat` 交给隐式 shell。运行在 Git Bash 的 wrapper 负责把 `command -v` 找到的无扩展 POSIX shim 转成显式 `bash <shim> ...` argv；若只存在 batch shim 且无安全的 POSIX/native 入口则 fail closed，不拼接 `cmd.exe /c` 字符串。

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
- stale report/opinion、空产物、非零退出、同一卡片并发竞争与 no-clobber 原子发布；
- 任务卡允许路径区块缺失、非法或与实际 diff 不一致；
- clean/dirty/unborn Git、违规 commit 和策略外文件变化；
- 正常超时、TERM/KILL、自然返回 124；
- `DELEGATE_DEPTH` 的未设置、0、1、非数字和算术表达式输入；
- Claude consult 不加载 project hook/MCP/Skill，Codex consult 使用 read-only/ephemeral；
- Linux、macOS、Windows Git Bash 的 CI 矩阵；POSIX-only 的信号、FIFO 与 symlink 语义按平台显式 skip，Windows 覆盖 direct-child terminate 与安全发布冲突。

完成本地 mock 测试后，用全新子代理做至少三个 forward tests：delegate 路由、consult 决策、能力缺失/禁止委派。若本机认证可用，再在临时 Git 仓库做一次 Claude 与 Codex 的最小真实 smoke；所有真实测试不得触碰业务仓库。

## 发布

实现位于 `agent/cccc-v2-hardening`。通过全部本地验证、独立复审和 diff 审查后，提交并推送该分支，创建 draft PR；不自动合并，不删除用户的 v1 安装或本地主分支。
