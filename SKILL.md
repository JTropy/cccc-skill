---
name: cccc
description: cccc（4 个 C，cross-codex-claude-code）跨 agent 协作：让本机的 Claude Code 和 Codex 互为 subagent。先识别自己是谁——你是 Codex 就找本机 claude，你是 Claude Code 就找本机 codex。两条通道：delegate 分包干活（写权限）；consult 只读商讨（重大顶层设计向对方顶配模型要第二意见，综合后交用户拍板）。触发场景：用户说「用 cccc/4C」「把这个交给/委派/外包给 claude/codex」「双 agent 协作」「和对方商讨/讨论/评审这个方案」「要第二意见」「拍板前问问对面」；任务明显更适合对方（UI/前端代码 → Claude Code；大批量机械改造 → Codex）；以及一切生图/图片素材需求——icon、logo、插画、banner、占位图、贴图的生成一律委派给 Codex（内置 gpt-image 的 image_gen 工具，Claude 无生图模型，绝不要用代码画位图代替真实生图）。Use whenever the user says "cccc"/"4C", wants to delegate work to the local peer agent (Claude Code ⇄ Codex), wants a max-compute read-only second opinion / design review (consult) from the peer before deciding, or needs raster image assets (Codex has gpt-image; Claude must delegate all image generation).
disable-model-invocation: true
---

# cccc — cross-codex-claude-code（跨 agent 分包）

核心思想：**你是编排方**，保有完整上下文和决策权；对方 agent 是 headless 子进程，干完一票有界任务就退出。子代理是冷启动，看不到你和用户的任何对话，所以**文件 + git 是你们之间唯一的总线**。两条通道：**delegate 干活**（子代理有写权限，任务卡进、回执+diff 出）；**consult 商讨**（对方机制级只读当顾问，议题卡进、观点文件出，最终用户拍板）。

## 第 0 步：我是谁，对方是谁

- 你是 **Codex** → 对方命令是 `claude`（Claude Code）
- 你是 **Claude Code** → 对方命令是 `codex`
- 不确定对方装没装：`command -v claude codex`。缺失就直接告诉用户并指向 `references/setup.md`，不要硬调。

把对方名字**显式**作为 delegate.sh 的第一个参数传入（你清楚自己的身份，显式永远比脚本猜测可靠）。调用脚本时用**本 skill 目录的绝对路径**（如 `bash ~/.claude/skills/cccc/scripts/delegate.sh`），不要假设它在项目 cwd 里。

## 何时分包，何时不分包

**硬规则（优先级最高）——生图一律给 Codex**：任何位图素材的生成（icon、logo、插画、banner、占位图、纹理、示意图……）都委派给 Codex，它有内置 image_gen 工具（gpt-image）；Claude 没有生图模型。即使你是 Claude Code 正在做 UI 任务，其中的位图素材子任务也必须拆出来给 codex，**不要用 canvas/PIL 代码画图来糊弄**。SVG 等纯代码矢量图不算生图，谁擅长谁做。

**常规路由**：UI / 前端代码 / 组件 / 样式 → Claude Code；大批量机械改造、跑量、成本敏感 → Codex。混合任务拆成多张卡：素材卡先行，产出的文件路径写进后续 UI 卡的「接口与约定」。**项目根目录的 AGENTS.md / CLAUDE.md 若写了分工策略，以项目文件为准**——动手前先看一眼。

**分包的前提**：用户点名要求；或任务能被清晰规格化且体量值得（≳15 分钟的独立工作，生图任务除外——生图再小也得委派）。

**不分包**：自己几分钟能干完的非生图小活（进程冷启动 + 写任务卡的开销不值）；需要和用户多轮来回的探索性任务；用户明确说「你自己做」。

## 分包流程（5 步）

1. **写任务卡** `docs/tasks/T-<编号>.md`（模板见下；编号 = 扫一眼 docs/tasks/ 取现有最大号 +1）。子代理只知道任务卡里的内容，所以背景、边界、接口约定、验收命令一个都不能省。
2. **git 工作区收干净**：`git status` 检查，未提交的先 commit 或 stash——**刚写的任务卡也一并 commit**（它本身就是审计记录）。这样事后 `git diff` 就是纯净的审查界面。
3. **调用** `bash <skill目录>/scripts/delegate.sh <claude|codex> docs/tasks/T-xxx.md`。长任务调大 `DELEGATE_TIMEOUT`。脚本会阻塞到完成并打印回执；**运行期间你不要改动工作区**（会污染 diff）。需要并行委派多个任务时，每个子代理各开一个 `git worktree`，不要共用工作区。
4. **验收**：① 看脚本输出有没有 HEAD 变化告警（子代理违规 commit 会让 diff 看似干净，脚本已自动比对）；② 读回执 `T-xxx-report.md`；③ `git diff --stat` 及关键文件 diff；④ **执行任务卡里写的验收命令**（build / lint / test）。机械可验证的标准优先于你的主观判断。**图片产物必须亲眼看**：用你的图像读取能力打开生成的图片检查内容与风格，再用 `file` 或脚本核对尺寸/格式——文件存在 ≠ 画对了。
5. **收尾**：合格 → 由你来 commit（message 注明经哪个 agent 完成）；不合格 → 写一张 fix-up 任务卡（开头注明「先读 T-xxx.md 与 T-xxx-report.md 再读本卡」，具体指出问题与复现方式），回到第 3 步。**同一任务连续 2 轮失败就停下来向用户汇报**，附上 diff 与日志，不要无限重试烧钱。

## 任务卡模板

```markdown
# T-001: <一句话目标>

## 背景
<为什么做这件事。子代理看不到对话历史，相关上下文全靠这里。>

## 要做什么
1. <具体改动，逐条列出>
<生图任务必须给足规格：尺寸、格式、透明背景与否、风格、数量、输出路径与命名。
 例：生成 3 张 512x512 PNG 透明背景的扁平风格齿轮 icon，存为 assets/icons/gear-{1,2,3}.png。
 注意写明「最终文件落到项目内目标路径」——codex 的 image_gen 默认先存到
 ~/.codex/generated_images/，需要它自己复制/缩放过来（已实测可行）>

## 边界（必填）
- 只允许改动: <目录/文件，如 frontend/ 或 assets/>
- 禁止: git commit / git push、改动边界外的文件、再委派给任何其他 agent

## 接口与约定
<API 契约、设计 token、命名规范；或直接指向 docs/api.md 等共享文件>

## 验收命令
- `npm run build`（生图任务可写：`file assets/icons/gear-1.png` 应为 512x512 PNG）

## 完成后
按此骨架写 docs/tasks/T-001-report.md：改了什么（文件清单）/ 怎么验证的（实际跑过的命令与结果）/ 已知问题 / 对任务卡的疑问
```

## 重大设计商讨（consult，只读第二意见）

**何时商讨**：架构选型、数据模型、对外 API 契约、安全模型、大重构策略——影响面广、改错成本高、存在多个可行方案的决策；或用户点名「商讨/评审/第二意见」。小决策直接做，别商讨（顶配商讨很贵，价值在不可逆决策上）。

**机制**：对方以**机制级只读**身份参与——claude 被禁用全部写/执行工具（--disallowedTools），codex 走 read-only 沙箱，物理上改不了你的仓库；观点由脚本捕获存档，算力硬性顶配（同 delegate 策略）。商讨只读，**可以并行**，也不要求工作区干净。

**流程（4 步）**：
1. **写议题卡** `docs/discussions/D-<编号>.md`（模板见下），模式二选一：**独立提案**（不亮你的倾向，防锚定——全新设计用）／**方案批判**（附你的草案让对方攻击——已有倾向用）。
2. **调用** `bash <skill目录>/scripts/consult.sh <claude|codex> docs/discussions/D-001.md`，读观点文件 `D-001-<对方>-opinion.md`。
3. 有重大分歧或对方提出新信息 → 最多再发一轮（`D-001-r2.md`，**附双方观点全文** + 聚焦分歧点——对方是冷启动，上下文要带全）。**上限 2 轮**，别 ping-pong。
4. **综合成决策简报交用户拍板（硬规则）**：方案 A/B/…、双方立场、分歧点、你的推荐与理由，用清晰选项呈现（Claude Code 用 AskUserQuestion；Codex 用编号提问）。**拍板前不许动手实现**；拍板后把选定方案、理由、被否方案写入 `D-001-decision.md`（ADR 风格）并 commit，后续任务卡直接引用它。

### 议题卡模板

```markdown
# D-001: <一句话议题>

## 模式
独立提案（请勿揣测我的倾向，先给你的独立设计）｜方案批判（下附我的草案，请攻击）

## 背景与目标
<要解决什么问题、成功标准、硬约束（性能/兼容/技术栈/期限）>

## 必读文件
- <必须是仓库内路径！claude 顾问读不了仓库外文件（headless 越界读被拒）；
  仓库外材料先复制进 docs/discussions/refs/ 或直接贴进本卡>

## 议题（逐条编号）
1. <决策点；已知候选方案一并列出>

## 我的草案（仅批判模式填）
<当前设计与理由>

## 输出要求
直接输出结构化 Markdown：每个决策点的结论一句话 / 方案与理由 / 风险与代价 / 与候选方案的对比 / 开放问题。立场要明确，不要和稀泥。
```

## 调用方式

首选脚本（统一处理超时、日志落盘、回执路径、安全档位、防套娃）：

```bash
bash ~/.claude/skills/cccc/scripts/delegate.sh codex  docs/tasks/T-001.md        # 我是 Claude Code，喊 Codex 干活
bash ~/.codex/skills/cccc/scripts/delegate.sh  claude docs/tasks/T-001.md        # 我是 Codex，喊 Claude Code 干活
bash ~/.claude/skills/cccc/scripts/consult.sh  codex  docs/discussions/D-001.md  # 只读商讨（方向同理互换）

# 常用环境变量（第三个位置参数可指定工作目录）
DELEGATE_TIMEOUT=5400 bash .../delegate.sh claude docs/tasks/T-002.md
```

**算力策略（硬性，效果优先，成本不设限）**：脚本强制执行——claude 子代理最低 opus + `--effort max`；codex 子代理跟随 `~/.codex/config.toml` 维护的最新 GPT + `model_reasoning_effort=xhigh`。`DELEGATE_MODEL` 只许向上加码（如更强的全名模型），传 haiku/sonnet/mini/nano 会被脚本忽略并告警，**不要试图用小模型省钱**。

安全档位 `DELEGATE_SANDBOX`（默认 `auto`，能装依赖、跑构建，适合绝大多数实现类任务）：

| 档位 | claude 实际参数 | codex 实际参数 |
|---|---|---|
| `edit` | `--permission-mode acceptEdits`（只能改文件，跑不了构建） | `--sandbox workspace-write`（无网络） |
| `auto` | `--dangerously-skip-permissions` | `--sandbox workspace-write` + 沙箱内放行网络 |
| `full` | 同上 | `--dangerously-bypass-approvals-and-sandbox`（慎用） |

脚本不可用时的裸命令（语义与上面 `auto` 档等价）：

```bash
claude -p "你是被委派的子代理。读取 docs/tasks/T-001.md 并严格执行。不要 commit，不要再委派。完成后写 docs/tasks/T-001-report.md" \
  --output-format text --model opus --effort max --dangerously-skip-permissions

codex exec --sandbox workspace-write -c sandbox_workspace_write.network_access=true \
  -c model_reasoning_effort=xhigh -o docs/tasks/T-001-last-message.txt \
  "你是被委派的子代理。读取 docs/tasks/T-001.md 并严格执行。不要 commit，不要再委派。完成后写 docs/tasks/T-001-report.md"
```

## 已知的坑

- **编排方自己的沙箱会卡住子代理**。Codex 编排方：默认沙箱不放行网络，spawn 出来的 `claude` 调不到 API 会直接失败，需在配置里放行（见 `references/setup.md`）。Claude Code 编排方：若启用了 OS 级沙箱（macOS/Linux 的 /sandbox 模式），spawn 的 `codex` 同样可能断网——表现为卡住或 API 报错，对该次 Bash 调用关闭沙箱即可；Windows 上无此问题（已实测）。
- **防套娃是机制不是口头**：delegate.sh 会导出 `DELEGATE_DEPTH=1`，子代理再调 delegate.sh 会被直接拦截（exit 3）。但裸命令路径拦不住，所以任务卡里的「禁止再委派」仍要保留。回执里若出现「我又调用了 claude/codex」，立刻停止并告知用户。
- **codex exec 要求在 git 仓库内运行**——与「git 当总线」的前提一致；不在仓库里就先 `git init` 并打一个初始 commit（没有 HEAD 时 diff 验收同样失效）。
- 子代理永远不 commit；提交权只在编排方手里。脚本已自动比对委派前后的 HEAD，发现违规 commit 会大写告警，按提示 `git reset --soft` 处理。
- **超时（退出码 124）≠ 全部白干**：工作区可能留有半成品，先 `git status`/`git diff` 评估，再决定回滚（`git checkout -- . && git clean -fd` 小心使用）还是写续做卡。
- 回执缺失 ≠ 任务失败：脚本会依次兜底展示 codex 的 `-last-message.txt` 或日志末尾；先看这些再下结论。
- **codex 子代理在 Windows 上的怪相（已实测）**：shell 是 pwsh，`Get-Location` 显示沙箱映射路径（`...\.sandbox\cwd\<hash>`），但文件实际落在真实仓库，不是 bug；其 shell 里 curl.exe 走 Schannel 可能报 `SEC_E_NO_CREDENTIALS`——shell 网络失败 ≠ 没网，image_gen / web search 等工具级网络不受影响。
- 验收命令由编排方 shell 执行；若任务卡要求子代理自跑验收，注意 codex@Windows 是 pwsh，`test -f` 之类 bash 语法跑不了——写跨平台命令或注明 shell。
- 验收命令失败时，先区分「环境问题」（编排方沙箱断网装不了依赖等）和「代码问题」，别冤枉子代理。
- **商讨观点 ≠ 决策**：consult 产物只能进决策简报，用户拍板前一行实现代码都不许写；观点文件与 decision 文件都要 commit 留档，这是项目的设计史。
- **顾问能力不对称**：claude 顾问被禁了 Bash 且**读不了仓库外路径**（已实测被拒）——必读材料必须在仓库内或贴卡；codex 顾问（read-only 沙箱）可跑只读命令、可读仓库外。要实跑验证的事放进拍板后的任务卡。另外别给 claude 顾问用 plan 权限模式：headless 下它会以 ExitPlanMode 收尾，吞掉最终文本（已实测踩坑）。
- **xhigh 长推理流可能被网络/中转掐断**（已实测）：症状是日志末尾连环 `Reconnecting...`、观点文件缺失。这是瞬时故障不是配置错误——直接重跑一次；议题特别大就拆小。给 consult 留足 `DELEGATE_TIMEOUT`（建议 ≥1500s）。

## 安装与一次性配置

见 `references/setup.md`：两侧 skills 目录与 symlink/junction 共用、Windows 注意事项、Codex 网络放行、CLI 认证前提。
