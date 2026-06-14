# cccc — cross-codex-claude-code

> 让本机的 **Claude Code** 和 **Codex** 互为子代理（subagent）、并彼此求共识的**通用**协作 skill。
> A universal skill that lets your local **Claude Code** and **Codex** delegate work to — and reach consensus with — each other.

`cccc`（4 个 C）是一份**两端通用**的 skill：同一个 `cccc/` 目录直接丢进 Claude Code 或 Codex 任意一侧都能用，**无需任何特殊适配**——两边读同一份 `SKILL.md`，脚本是纯 bash 双端通跑，谁当编排方都对称工作。

它把同一台机器上的两个 coding agent 接成一对搭档：你保有完整上下文当**编排方**，对方作为 headless 子进程，干完一票有界任务就退出。**文件 + git 是你们之间唯一的总线**——子代理冷启动，看不到你和用户的任何对话，所有背景都通过任务卡传递。

## 两条通道

| 通道 | 对方角色 | 权限 | 产物 | 用途 |
|---|---|---|---|---|
| **delegate（分包）** | 工人 | 可写、可执行 | 任务卡进 → 回执 + diff 出 | 把一块能规格化的活外包出去 |
| **consult（共识）** | 顾问 | 机制级**只读** | 议题卡进 → 观点文件出 | 重大设计向对方顶配模型要第二意见，双方交叉论证形成共识后交你拍板 |

核心原则：**delegate 干活，consult 求共识；共识产物永不直接执行，由编排方综合成决策简报交用户拍板。**

## 为什么需要它

两个 agent 各有顶尖的一面。cccc 把「**各取对方所长**」机制化，让你不必手动在两个会话之间倒腾上下文。

### 能力互借（两个旗舰场景）

- **Claude Code 借用 Codex 的顶尖生图能力**：Claude 没有生图模型，凡是位图素材（icon、logo、插画、banner、占位图、纹理……）一律 `delegate` 给 Codex，由它内置的 `image_gen`（gpt-image）产出——绝不用 canvas/PIL 代码画位图糊弄。这是硬规则。
- **Codex 借用 Claude Code 的顶尖顶层设计能力**：面对架构选型、数据模型、对外 API 契约、安全模型这类高风险、改错成本大的决策，Codex 可以 `consult` Claude Code，调它**最强配置**（opus + `--effort max`）做只读的方案推演与设计评审。
- **方向对称，谁强谁上**：反过来，Claude 也能把大批量机械改造、跑量、成本敏感的活 `delegate` 给 Codex，或就某个设计 `consult` Codex。常规路由：UI / 前端代码 → Claude Code；批量改造 / 生图 → Codex。

### 共识机制（consult）

重大设计不靠单个 agent 拍脑袋：编排方写议题卡，对方顶配模型以**机制级只读**身份参与，给出独立结论、理由、风险与方案对比；有分歧最多再交换一轮（上限 2 轮），双方观点**交叉论证、收敛成共识**。所有观点落盘进 git，编排方再综合成决策简报（方案 A/B、双方立场、分歧点、推荐与理由）**交用户拍板**——共识产物在拍板前一行实现代码都不写，拍板后写入 ADR 风格的 `decision.md` 留档。

### 还有

- **可审计**：任务卡、回执、观点、决策全部落盘进 git，构成项目可追溯的设计史。
- **机制级安全**：防套娃、顾问真只读、提交权只在编排方手里（见下「安全设计」）。

## 工作方式

### 第 0 步：我是谁，对方是谁
- 你是 **Codex** → 对方命令是 `claude`
- 你是 **Claude Code** → 对方命令是 `codex`

把对方名字**显式**作为脚本第一个参数传入。

### delegate 流程（5 步）
1. 写任务卡 `docs/tasks/T-xxx.md`（背景、要做什么、边界、接口约定、验收命令一个都不能省）
2. 收干净 git 工作区（任务卡也一并 commit）
3. `bash <skill目录>/scripts/delegate.sh <claude|codex> docs/tasks/T-xxx.md`
4. 验收：HEAD 是否被违规 commit、读回执、`git diff`、跑验收命令；**图片产物必须亲眼看**
5. 收尾：合格由编排方 commit；不合格写 fix-up 卡。同一任务连续 2 轮失败就停下来汇报

### consult 流程（求共识，4 步）
1. 写议题卡 `docs/discussions/D-xxx.md`（独立提案 / 方案批判二选一）
2. `bash <skill目录>/scripts/consult.sh <claude|codex> docs/discussions/D-xxx.md`，读观点文件
3. 有重大分歧最多再发一轮（上限 2 轮）
4. 综合成决策简报交用户拍板 → 写 `D-xxx-decision.md`（ADR）并 commit

## 安装

> **通用、免适配**：同一个 `cccc/` 目录在 Claude Code 和 Codex 上都能直接安装运行，不需要为某一端做任何改造或改写——两端读同一份 `SKILL.md`，脚本两端通跑。

把整个目录放进两侧 skills 目录，推荐**只留一份真身、另一侧做链接**，改一处两边生效。

| Agent | 个人级（全局） | 项目级 |
|---|---|---|
| Claude Code | `~/.claude/skills/cccc/` | `<repo>/.claude/skills/cccc/` |
| Codex | `~/.codex/skills/cccc/` | `<repo>/.codex/skills/cccc/` |

**macOS / Linux**（以 Claude Code 侧为真身）：
```bash
git clone https://github.com/JTropy/cccc-skill.git
mkdir -p ~/.claude/skills ~/.codex/skills
cp -r cccc-skill ~/.claude/skills/cccc
ln -s ~/.claude/skills/cccc ~/.codex/skills/cccc
chmod +x ~/.claude/skills/cccc/scripts/*.sh
```

**Windows**（junction，不需管理员权限）：
```powershell
New-Item -ItemType Junction -Path "$env:USERPROFILE\.codex\skills\cccc" -Target "$env:USERPROFILE\.claude\skills\cccc"
```

> Codex 启动时加载 skills 元数据，**新增或修改后要重启 Codex** 才生效。

完整的一次性配置（网络放行、CLI 认证、算力前提、项目级路由策略、自检命令）见 **[`references/setup.md`](references/setup.md)**。

## 前提条件

- 本机同时装有 `claude`（Claude Code）和 `codex`（Codex）两个 CLI，且都已登录 / 配好 API。
- **算力策略是硬编码的（效果优先，成本不设限）**：claude 子代理强制 `--model opus --effort max`；codex 子代理跟随 `~/.codex/config.toml` 的最新 GPT + `model_reasoning_effort=xhigh`。接收方账号需具备对应权限。
- **Codex 侧必做**：默认沙箱不放行网络，需在 `~/.codex/config.toml` 加 `[sandbox_workspace_write] network_access = true`，否则它 spawn 的 `claude` 调不到 API。

## 安全设计

- **机制级防套娃**：脚本导出 `DELEGATE_DEPTH=1`，子代理再调脚本直接被拦截（exit 3）。
- **顾问真只读**：consult 时 claude 被 `--disallowedTools` 禁用全部写/执行工具，codex 走 `--sandbox read-only`，物理上改不了你的仓库。
- **提交权只在编排方手里**：子代理永不 commit；脚本自动比对委派前后 HEAD，发现违规 commit 会大写告警。
- 脚本本身**不含任何密钥**，全部凭证由各 CLI 自身的认证体系提供。

## 目录结构

```
cccc/
├── SKILL.md              # skill 主文件（编排方读取的完整协议 + 任务卡/议题卡模板 + 已知的坑）
├── references/setup.md   # 一次性安装与配置
├── agents/openai.yaml    # Codex 侧配置（禁用隐式调用，仅显式触发）
└── scripts/
    ├── delegate.sh       # 分包通道：统一处理超时、日志、回执、安全档位、防套娃
    └── consult.sh        # 商讨通道：机制级只读，观点落盘
```

完整的协议细节、任务卡 / 议题卡模板、以及踩过的坑，请直接读 **[`SKILL.md`](SKILL.md)**。

## License

[MIT](LICENSE)
