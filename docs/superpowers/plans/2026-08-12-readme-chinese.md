# Chinese README Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 README 完整改写为中文，并突出 Claude Code 与 Codex 的双向协作、宿主感知路由、Codex `$imagegen` 与 Claude Code / Fable 5 的条件性能力。

**Architecture:** 只修改 README 与其内容契约测试，不改 wrapper 或 skill 路由实现。先用 Python `unittest` 锁定中文产品定位和已有安全操作契约，再改写 README；安装、迁移、更新脚本保持可执行语义不变。

**Tech Stack:** Markdown、Python 3 `unittest`、Git。

---

## File map

- `README.md`: 中文产品说明、安装迁移与安全操作文档。
- `tests/test_validate_skill.py`: README 标题、双向协作能力、条件性表述、安装迁移与更新脚本的内容契约。

### Task 1: 用测试锁定中文产品定位

**Files:**

- Modify: `tests/test_validate_skill.py`
- Test: `tests/test_validate_skill.py`

- [ ] **Step 1: 添加失败的中文 README 契约测试**

在 `ValidateSkillTests` 中加入：

```python
def test_readme_presents_chinese_bidirectional_collaboration(self) -> None:
    readme = (REPOSITORY_ROOT / "README.md").read_text(encoding="utf-8")
    self.assertTrue(readme.startswith("# cccc — Claude Code Codex Collaboration\n"))
    for required in (
        "Claude Code 与 Codex 协作",
        "通用 skill",
        "自动识别当前宿主",
        "Claude Code",
        "Codex",
        "$imagegen",
        "Fable 5",
        "当前 CLI、账号、供应商与工作区",
    ):
        self.assertIn(required, readme)
    self.assertRegex(readme, r"Claude Code[\s\S]{0,220}\$imagegen")
    self.assertRegex(readme, r"Codex[\s\S]{0,220}Fable 5")
    self.assertIn("不是操作系统沙箱", readme)
    self.assertIn("退出码 `0`", readme)
```

同时将现有 `test_readme_uses_canonical_install_and_safe_migration` 与 `test_readme_update_recovers_signal_after_completed_link_move` 的章节切分和关键说明断言改为中文标题/文案，命令与路径断言保持不变：

```python
update = readme.split("## 更新、回滚与卸载", 1)[1]
self.assertRegex(readme, r"~/.codex/skills/cccc[\s\S]{0,160}旧版")
self.assertRegex(readme, r"重启[\s\S]{0,160}兜底|兜底[\s\S]{0,160}重启")
self.assertRegex(readme, r"卸载[\s\S]{0,600}(?:保留|不要删除)")
```

- [ ] **Step 2: 运行定向测试并确认 RED**

Run:

```bash
python3 -m unittest -v \
  tests.test_validate_skill.ValidateSkillTests.test_readme_presents_chinese_bidirectional_collaboration \
  tests.test_validate_skill.ValidateSkillTests.test_readme_uses_canonical_install_and_safe_migration \
  tests.test_validate_skill.ValidateSkillTests.test_readme_update_recovers_signal_after_completed_link_move
```

Expected: FAIL，原因是当前 README 仍为英文标题和英文章节。

- [ ] **Step 3: 检查测试差异**

Run:

```bash
git diff --check
git diff -- tests/test_validate_skill.py
```

Expected: 无格式错误；差异只包含 README 内容契约调整。

### Task 2: 改写中文 README

**Files:**

- Modify: `README.md`
- Test: `tests/test_validate_skill.py`

- [ ] **Step 1: 替换标题与第一屏定位**

README 必须以以下内容开头：

```markdown
# cccc — Claude Code Codex Collaboration

`cccc` 是一个让 Claude Code 与 Codex 协作的通用 skill。同一份 skill 同时安装在两个宿主中，会根据当前编排者自动选择另一端作为协作对象：Claude Code 调用 Codex，Codex 调用 Claude Code。
```

紧接着加入两个条件性能力示例：Claude Code 可将生图/图片编辑交给 Codex `$imagegen`；Codex 可将顶层设计、架构推演和方案评审交给 Claude Code，并在能力可用时请求 Fable 5。明确能力必须按当前 CLI、账号、供应商与工作区验证。

- [ ] **Step 2: 中文化全部说明结构**

使用这些章节标题并翻译全部说明文字：

```markdown
## 它如何协作
## 安全与授权边界
## 环境要求
## 在 macOS 或 Linux 上安装
## 在 Windows 上安装
## 从 v1 迁移
## 更新、回滚与卸载
## 最小用法
## 规范文档
## 许可证
```

保留现有 Bash/PowerShell 命令的变量名、路径、执行顺序和 fail-fast/trap 语义。将 `delegate` 与 `consult` 表格列名和说明翻译为中文，但保留 channel 名称。

- [ ] **Step 3: 运行 README 定向测试并确认 GREEN**

Run:

```bash
python3 -m unittest -v \
  tests.test_validate_skill.ValidateSkillTests.test_readme_presents_chinese_bidirectional_collaboration \
  tests.test_validate_skill.ValidateSkillTests.test_readme_uses_canonical_install_and_safe_migration \
  tests.test_validate_skill.ValidateSkillTests.test_readme_update_recovers_signal_after_completed_link_move
```

Expected: 3 tests PASS。

- [ ] **Step 4: 运行完整文档与 skill 验证**

Run:

```bash
python3 -m unittest -v tests.test_validate_skill
python3 tests/validate_skill.py skills/cccc
git diff --check
```

Expected: 全部测试通过；validator 输出 `skills/cccc: valid`；无格式错误。

- [ ] **Step 5: 审核最终差异并提交**

Run:

```bash
git status --short
git diff -- README.md tests/test_validate_skill.py
git add README.md tests/test_validate_skill.py
git diff --cached --check
git commit -m "docs: rewrite README in Chinese"
```

Expected: 提交只包含 README 与其内容契约测试。

### Task 3: 推送并验证 main

**Files:**

- No file changes.

- [ ] **Step 1: 确认本地主分支与远端同步关系**

Run:

```bash
git status --short
git branch --show-current
git fetch origin main
git merge-base --is-ancestor origin/main HEAD
```

Expected: 工作树干净、分支为 `main`、远端 `main` 是当前 HEAD 的祖先。

- [ ] **Step 2: 推送主分支**

Run:

```bash
git push origin main
```

Expected: 推送成功且远端 `main` 指向本次 README 提交。

- [ ] **Step 3: 核对远端状态**

Run:

```bash
git ls-remote --heads origin main
git log -2 --oneline
```

Expected: 远端哈希与本地 `HEAD` 相同，最近两条提交分别为 README 实现和已确认设计规格。
