# README 中文化设计

## 目标

将仓库 README 改写为面向中文用户的产品说明，第一屏清楚表达：`cccc` 是一个让 Claude Code 与 Codex 协作的通用 skill，而不是只属于其中某一个宿主的扩展。

标题固定为：

`cccc — Claude Code Codex Collaboration`

## 核心信息顺序

README 开头按以下顺序建立认知：

1. `cccc` 同时安装到 Claude Code 与 Codex，共用同一份 skill。
2. skill 根据当前编排宿主选择另一端作为协作对象：Claude Code 调用 Codex，Codex 调用 Claude Code；底层脚本仍保留显式目标参数，便于审计和排障。
3. Claude Code 可把生图或图片编辑任务交给 Codex 的 `$imagegen` 能力。
4. Codex 可把顶层设计、架构推演和方案评审交给 Claude Code，并在当前版本、账号与供应商支持时请求 Fable 5。
5. 两条正式协作通道仍是 `delegate`（受限实现）与 `consult`（只读咨询）。

## 能力表述边界

- “自动识别”描述为 skill 的宿主感知路由规则，不声称底层脚本会猜测可执行文件身份。
- `$imagegen`、Fable 5、模型、effort、网络和供应商能力都必须在当前 CLI、账号、供应商与工作区中验证，README 不作无条件保证。
- `consult` 只提供建议，不授权实施；`delegate` 只允许任务卡白名单范围内的修改。
- 保留“不是操作系统沙箱”的边界：Git ignored 路径、Git 元数据、同用户可读文件、密钥及故意脱离的进程不属于完整隔离范围。
- 退出码 `0` 才是成功依据，不能仅凭产物文件存在判断成功。

## README 结构

1. 标题与一句话定位
2. “它能做什么”：双向能力示例与宿主感知路由
3. `delegate` / `consult` 对比
4. 安全与授权边界
5. 环境要求
6. macOS、Linux、Windows 安装
7. v1 迁移
8. 安全更新、回滚和卸载
9. 最小使用示例
10. 规范文档与许可证

安装、迁移、回滚命令保留现有已验证语义，只将说明文字中文化，不为了缩短篇幅删掉安全步骤。

## 验收标准

- 首行精确为 `# cccc — Claude Code Codex Collaboration`。
- 标题、正文、表格标题、章节标题与操作说明均为中文；命令、路径、变量名和产品名保持原样。
- 第一屏明确出现“Claude Code 与 Codex 协作”“通用 skill”“宿主感知/自动路由”三层信息。
- 明确给出 Claude Code → Codex `$imagegen` 与 Codex → Claude Code / Fable 5 两个示例，并带能力可用性条件。
- 现有安装、迁移、回滚、安全边界和退出码语义不丢失。
- 添加内容契约测试，锁定标题、中文定位、双向能力、条件性表述及关键安全边界。
- 通过 README 内容测试、skill validator、Markdown 链接检查和差异格式检查后，才提交并推送 `main`。

## 非目标

- 不修改 wrapper、路由逻辑、模型选择或权限策略。
- 不把 Fable 5 写成所有 Claude Code 环境的默认或必然可用模型。
- 不把 `$imagegen` 写成所有 Codex 环境的必备能力。
- 不删除为无损安装、迁移、回滚和卸载而保留的操作细节。
