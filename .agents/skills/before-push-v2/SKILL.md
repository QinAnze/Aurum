---
name: before-push-v2
description: a skill which aims to enhance code quality before a commit
version: 1.0.0
---

# 软件工程 Loop 引擎

## 定位

本文件是**总调度器（Orchestrator）**，不承载技术细节。它定义：
- 何时启动（Trigger）
- 目标是什么（Goal）
- 如何闭环（Loop Specification）
- 何时停止（Stop Conditions）
- 何时交给人（Human Gates）

技术细节拆分至同目录下的 skill 子目录，每个子目录包含独立的 `SKILL.md`，按任务类型路由。

---

## 核心原则

| 原则 | 含义 |
|------|------|
| **Evidence over claims** | Agent 说"完成了"不算数，Evidence 定义 Done。每条 Done 条件必须有对应的验证命令或产物 |
| **Simplicity First** | 200 行能解决的事不用 500 行。不添加未请求的功能或抽象 |
| **Surgical Changes** | 只碰必须改的。每一行变更都能追溯到用户请求 |
| **Small Context** | 每轮只保留 Goal + State + Relevant Files + Latest Verification + Known Failures + Next Action |
| **Least Privilege** | 所有权限、访问、授予均遵循最小权限原则 |
| **Zero Trust** | 不信任任何内部/外部网络，始终验证 |
| **Task-Graph over Phase Pipeline** | 简单任务走默认线性路径；复杂多子任务走 DAG 图执行。每个 Task 自带验证策略 |
| **Ambiguity-Tolerant Execution** | Agent 不是因为不确定就停，而是因为"这个不确定可能导致不可逆后果"才停 |

---

## Task Graph 执行模型

### 何时使用 Task Graph

| 场景 | 执行模式 |
|------|---------|
| 单一目标、单类型任务（如"修一个 typo"） | **线性执行**：按 Phase 0→1→4→5 顺序走，无需建图 |
| 多子任务、有依赖关系（如"修内存泄漏 + 审计 unsafe"） | **Task Graph**：构建 DAG，按依赖拓扑执行 |

### Task 节点结构

Task 不是一个名字，而是一个包含执行策略的数据结构：

```yaml
task:
  id: "audit-unsafe"
  objective: "审计 src/ 下所有 unsafe 块的安全性"
  skill: "security/SKILL.md"

  # 依赖
  dependencies: ["fix-memory-leak"]

  # 验证配置（这个任务需要跑哪些门控）
  gates:
    - sast: required
    - sca: required
    - secret_scan: skip        # 和 secret 无关，跳过
    - container_scan: skip     # 非容器项目

  # 风险等级决定 Reviewer 策略
  risk: high                   # high → 启用独立 Reviewer
  change_size: medium

  # 假设追踪（Agent 不确定时记录，不阻塞 Loop）
  assumptions:
    - "项目使用 cargo 构建（从 Cargo.toml 推断）"

  # 状态
  status: pending              # pending | running | verifying | done | failed | escalated
  retry_count: 0
```

**关键点：** DoD 不是一张通用表格，而是每个 Task 根据自己的 gates 配置动态生成。一个 typo 修复任务的 gates 里可能只有 `build: required`，自然就不会跑 SAST。

### 执行规则

```
找出所有 dependencies 已满足的 Task → 并行执行
  ↓
每个 Task 加载对应的 Skill 文件，按 Skill 中的工具链执行
  ↓
验证：用 Task 自己的 gates 逐条检查
  ↓
  ├─ 全部通过 → 标记 done，触发下游 Task
  ├─ 部分通过 → 记录失败，按 Retry Policy 重试
  └─ 超过重试上限 → 标记 escalated，交还用户
```

### 与六阶段框架的关系

Task Graph 不是替代六阶段，而是**包裹**六阶段：

```
Task Graph（DAG 调度层）
  │
  ├─ Task A ──→ Phase 0 → Phase 1 → Phase 4 → Phase 5
  │             (Clean)
  │
  ├─ Task B ──→ Phase 0 → Phase 3 → Phase 4
  │             (Secure)   ↑
  │                        │ gates 动态决定需要哪些 Phase
  │
  └─ Task C ──→ Phase 0 → Phase 2 → Phase 4
               (Optimize)
```

每个 Task 根据自己的 gates 配置决定需要经过哪些 Phase，而不是所有任务都走全流程。

---

## 歧义处理

Agent 在 Phase 0 几乎总会遇到不确定项。但不是所有不确定都应该阻塞 Loop：

```
遇到不确定项
  ↓
判断：这个不确定会不会影响可逆性？
  ├─ 会影响不可逆操作（删字段、改 schema、切方案）
  │   → 停止，输出 Escalation 报告，等用户决策
  ├─ 可逆但可能做错（"用 Markdown 还是 AsciiDoc？"）
  │   → 做合理假设，记录到 Task.assumptions，继续执行
  └─ 完全无关紧要（缩进用 2 还是 4 空格？）
      → 用项目现有风格，无需记录
```

**设计哲学：** Agent 不是因为不确定就停，而是因为"这个不确定可能导致不可逆后果"才停。State 里的 assumptions 字段让这些假设可见——如果后续验证失败，可以先回头检查假设是否正确。

---

## Loop Specification

### 1. Trigger（何时启动）

| 触发条件 | 匹配任务类型 |
|----------|-------------|
| 用户请求"审查代码" / "review" | Code Review |
| 用户请求"优化" / "提升性能" | Performance |
| 用户请求"检查安全" / "安全加固" | Security |
| 用户请求"修复 bug" | Bug Fix |
| 用户请求"发布准备" / "上线前检查" | Release |
| 用户请求"加功能" / "实现 XX" | Feature |
| CI/CD pipeline 触发 | Automated Gate |

### 2. Goal（目标）

每个任务必须定义可量化的目标：

```
❌ "优化性能"
✅ "将 /api/users 响应时间从 200ms → <100ms，通过 k6 负载测试（100并发，5分钟）"

❌ "检查安全"
✅ "SAST 零高危 + SCA 零 CVE-High + 密钥扫描通过 + 容器镜像无 Critical"
```

### 3. State（状态）

每轮维护以下状态，不依赖完整对话历史：

```yaml
goal: ""
current_phase: understand|clean|optimize|secure|verify|document
files_changed: []
tests_passed: 0
tests_failed: 0
known_issues: []
attempted_fixes: []
remaining_tasks: []
retry_count: 0
verification_status: pending|pass|fail|partial
last_error: ""
assumptions: []              # 新增：假设追踪（歧义处理产生的假设）
task_graph_status: null      # 新增：Task Graph 模式下的 DAG 状态
active_task_ids: []          # 新增：当前正在执行的 Task ID 列表
```

### 4. Action Policy（Agent 能做什么）

#### 自主执行（无需确认）
- 读取代码文件
- 运行 lint / formatter
- 运行单元测试
- 运行 SAST / SCA / 密钥扫描
- 生成分析报告

#### 自主 + 记录（执行后报告）
- 修改代码（非删除）
- 新增测试用例
- 更新依赖

#### 必须确认（Human Gate — 见 §6）
- 删除文件或大量代码
- 修改数据库 schema
- 修改 CI/CD 配置
- 修改 Secrets / 密钥
- Git force push / rebase
- Production deployment
- 数据迁移

### 5. Observation（收集什么）

每轮执行后收集：
- 测试结果（pass/fail 数、覆盖率变化）
- Lint 输出
- 安全扫描结果
- Build 状态
- Git diff 摘要

### 6. Verification（如何证明正确）

**Evidence-Gated 验证：** 每个 Done 条件必须有对应的自动化验证命令。

```
条件                          验证命令
─────────────────────────────  ──────────────────
代码无 lint 错误               ruff check . && eslint .
类型检查通过                   tsc --noEmit && mypy src/
单元测试通过                   pytest --cov=src tests/
集成测试通过                   docker-compose -f test.yml up --exit-code-from test
安全扫描通过                   semgrep --config=auto src/ && bandit -r src/
依赖无高危漏洞                 npm audit --audit-level=high
构建成功                       cargo build --release
文档已同步                     grep -q "new_feature" README.md
```

### 7. Retry Policy

| 次数 | 策略 |
|------|------|
| **第 1 次失败** | 分析错误，尝试修复 |
| **第 2 次失败** | 更换解决策略（换一种实现方式） |
| **第 3 次失败** | 更换策略 + 收缩修改范围 |
| **超过 3 次** | 停止自动修复，输出失败原因，请求人工介入 |

**硬性上限：**
```yaml
MAX_RETRIES: 3
MAX_TOOL_CALLS: 50
MAX_RUNTIME: 30m
MAX_CONTEXT_PERCENT: 70  # context window 使用不超过 70%
```

### 8. Stop Conditions

| 条件 | 行为 |
|------|------|
| **SUCCESS** | 所有 Definition of Done 条件满足 |
| **RETRY** | 验证失败 + 问题可修复 + 未超过 retry budget |
| **ESCALATE** | 需要用户决策 / 需求有歧义 / 涉及高风险操作 |
| **ABORT** | 检测到不可接受风险 / 工具环境损坏 / 超出权限范围 |
| **TIMEOUT** | 超过 MAX_RUNTIME |
| **BUDGET_EXCEEDED** | 超过 token / API / tool-call budget |

### 9. Escalation（升级策略）

```
检测到需要人工介入
    ↓
暂停当前 Loop
    ↓
输出：
  - 当前状态（State）
  - 阻塞原因
  - 已尝试的方案（attempted_fixes）
  - 建议的下一步（给用户 2-3 个选项）
    ↓
等待用户指令
    ↓
恢复 Loop（根据用户选择调整策略）
```

---

## 任务分类与路由

WORKFLOW 根据任务类型路由到对应的 reference 文件：

| 任务类型 | 路由 Reference | 阶段映射 |
|----------|---------------|---------|
| **Code Review** | `code-quality/SKILL.md` | Phase 0 → Phase 1 → Phase 4 |
| **Performance** | `performance/SKILL.md` | Phase 0 → Phase 2 → Phase 4 |
| **Security Audit** | `security/SKILL.md` | Phase 0 → Phase 3 → Phase 4 |
| **Bug Fix** | `code-quality/SKILL.md` | Phase 0 → Phase 1 → Phase 4 |
| **Feature** | `code-quality/SKILL.md` | Phase 0 → Phase 1 → Phase 3 → Phase 4 |
| **Release** | 全部 References | Phase 0 → Phase 1 → Phase 2 → Phase 3 → Phase 4 → Phase 5 |
| **Dependency** | `dependencies/SKILL.md` | Phase 0 → Phase 3 → Phase 4 |

---

## Definition of Done（证据驱动）

**Agent 不能定义 Done，Evidence 定义 Done。**

每条 Done 条件必须满足三个要素：
1. **条件**：描述性陈述
2. **验证命令**：可执行的命令或检查方式
3. **证据**：命令输出或文件存在的证明

### DoD 生成规则

DoD 不是一张通用表格，而是**根据每个 Task 的 gates 配置动态生成**：

```
Task.gates
  ├─ sast: required      → 追加 SAST 检查条目
  ├─ sast: skip          → 不生成 SAST 条目
  ├─ build: required     → 追加构建检查条目
  └─ test: required      → 追加测试检查条目
```

### 通用 DoD（基础，始终包含）

| # | 条件 | 验证命令 | 证据 |
|---|------|---------|------|
| 1 | 需求已实现 | 用户验收 / 测试通过 | Test result |
| 2 | Git diff 已审查 | `git diff --stat` | Reviewed |
| 3 | 无调试残留 | `grep -r "console.log\|pdb\|breakpoint" src/` | Empty |

### 按需追加（由 gates 驱动）

| # | 条件 | 验证命令 | 证据 | 触发 gate |
|---|------|---------|------|----------|
| 4 | 单元测试通过 | `pytest --cov=src tests/` | Exit 0 | `test` |
| 5 | Lint 零错误 | `ruff check . && eslint .` | Exit 0 | `lint` |
| 6 | 类型检查通过 | `tsc --noEmit && mypy src/` | Exit 0 | `typecheck` |
| 7 | 构建成功 | `cargo build --release` | Exit 0 | `build` |
| 8 | SAST 无高危 | `semgrep --config=auto src/` | 0 high | `sast` |
| 9 | SCA 零高危 CVE | `npm audit --audit-level=high` | 0 vulnerabilities | `sca` |
| 10 | 密钥扫描通过 | `gitleaks detect` | 0 findings | `secret_scan` |
| 11 | 文档已同步 | `grep -q "feature" README.md` | Found | `docs` |

### 任务类型自动追加

| 任务类型 | 自动追加项 | 来源 |
|---------|-----------|------|
| Feature | 集成测试覆盖新增代码路径 + API 文档同步 | `code-quality` |
| Security | 容器镜像无 Critical + DAST（如适用）+ SBOM 已生成 | `security` |
| Release | 版本号 SemVer + CHANGELOG.md + 回滚方案 | `documentation` |

### 场景示例

| 场景 | gates 配置 | 生成的 DoD |
|------|-----------|-----------|
| 修复 typo | `build: required` | 基础(3) + 构建(7) = **4 项** |
| 清理代码 | `lint, typecheck, test, build: required` | 基础(3) + 测试(4) + Lint(5) + 类型(6) + 构建(7) = **8 项** |
| 安全加固 | `sast, sca, secret_scan, container: required` | 基础(3) + SAST(8) + SCA(9) + 密钥(10) + 容器 = **7 项** |
| 发布准备 | 全量 gates | 基础(3) + 全部按需(8) + 发布追加(3) = **14 项** |

---

## Execution Loop（六阶段作为 Loop Phase）

```
┌──────────────────────────────────────────────────┐
│              Goal / Issue                        │
└──────────────────────┬───────────────────────────┘
                       ↓
              ┌─── Discover ───┐
              │  Phase 0:      │
              │  理解项目       │
              │  前置声明       │
              └────────┬───────┘
                       ↓
              ┌─── Plan ───────┐
              │  任务分类       │
              │  路由 Reference │
              └────────┬───────┘
                       ↓
         ┌─────────────┴─────────────┐
         ↓                           ↓
   ┌─────▼─────┐              ┌──────▼──────┐
   │   Act     │              │   Act       │
   │ Phase 1-3 │              │ Phase 1-3   │
   │ (按计划    │              │ (按计划     │
   │  执行)    │              │  执行)      │
   └─────┬─────┘              └──────┬──────┘
         ↓                           ↓
   ┌─────▼─────┐              ┌──────▼──────┐
   │ Observe   │              │ Observe     │
   │ 收集结果   │              │ 收集结果     │
   └─────┬─────┘              └──────┬──────┘
         ↓                           ↓
   ┌─────▼─────┐              ┌──────▼──────┐
   │ Verify    │              │ Verify      │
   │ 证据比对   │              │ 证据比对     │
   └─────┬─────┘              └──────┬──────┘
         ↓                           ↓
   ┌─────┴─────┐              ┌──────┴──────┐
   │           │              │             │
   ▼           ▼              ▼             ▼
PASS        FAIL           PASS          FAIL
   │           │              │             │
   │           └──────┬───────┘             │
   │                  ↓                     │
   │          ┌───────▼───────┐             │
   │          │ Retry Policy  │             │
   │          │ 分析→修复→验证 │             │
   │          └───────┬───────┘             │
   │                  ↓                     │
   │            ┌─────┴─────┐               │
   │           PASS       FAIL              │
   │            │           │               │
   │            │     Escalate              │
   │            │     (Human Gate)          │
   │            │           │               │
   └────────────┴───────────┴───────────────┘
                       ↓
              ┌─── Review ───┐
              │ Phase 4:     │
              │ 最终验证     │
              │ 安全门       │
              └────────┬──────┘
                       ↓
              ┌─── Document ──┐
              │ Phase 5:      │
              │ 文档同步      │
              └────────┬───────┘
                       ↓
              ┌─── Done ─────┐
              │ 交付报告      │
              │ Git commit   │
              └──────────────┘
```

### Phase 详解

#### Phase 0：理解项目（Discover）

**输入：** 用户请求 + 项目路径
**输出：** 前置声明（见 §Stage 0 Template）

**必做：**
- 读取项目结构（目录、核心文件）
- 识别技术栈（语言、框架、构建工具）
- 输出假设与不确定项
- 等待用户确认不确定项

**DoD：**
- [ ] 项目类型已确认
- [ ] 核心语言已确认
- [ ] 不确定项已得到用户回复
- [ ] 安全基线扫描已完成

#### Phase 1：代码清理与质量优化（Act — Clean）

**Reference：** `code-quality/SKILL.md`

**执行范围：** 按项目实际语言选择对应工具链

**DoD：**
- [ ] 静态分析工具零错误
- [ ] 格式化检查通过
- [ ] 未使用依赖已移除
- [ ] 调试残留已清除
- [ ] 原有功能未被破坏

#### Phase 2：性能优化（Act — Optimize）

**Reference：** `performance/SKILL.md`

**DoD：**
- [ ] 关键路径性能无退化
- [ ] 内存泄漏已识别并修复
- [ ] 基准测试结果可复现

#### Phase 3：安全性检查（Act — Secure）

**Reference：** `security/SKILL.md`

**DoD：**
- [ ] SAST 扫描通过
- [ ] SCA 扫描通过
- [ ] 密钥扫描通过
- [ ] 容器镜像扫描通过（如适用）
- [ ] 依赖无高危漏洞
- [ ] SBOM 已生成（如适用）

#### Phase 4：最终验证（Review）

**所有 Evidence Gates 汇总检查。**

**安全门（Security Gate）：**
```
                    Implementation
                          ↓
                     Unit Tests
                          ↓
                    Build / Lint
                          ↓
                    Security Gate
                          ↓
                 ┌────────┴────────┐
              PASS               FAIL
                 │                 │
                 ↓                 ↓
             Review             Diagnose
                 │                 │
                 ↓                 ↓
               Done              Fix
                                   │
                                   └──→ Verification
```

**DoD：** 通用 DoD + 任务特定 DoD 全部满足

#### Phase 5：文档同步（Document）

**Reference：** `documentation/SKILL.md`

**DoD：**
- [ ] README.md 完整准确
- [ ] CHANGELOG.md 更新（含安全修复标注）
- [ ] .gitignore 配置正确
- [ ] SECURITY.md 更新（如适用）

### 停止时输出什么

不是"我完成了/我没完成"，而是：

```
每个 Task 的最终状态：done / failed / escalated
每个 Task 的 evidence 汇总
如果失败：为什么失败 + 已尝试了什么 + 建议的下一步
如果部分完成：哪些 Task 完成了，哪些没有
留给用户的可选操作
```

---

## Human Gates（人机协同）

### 风险分级

| 风险等级 | 操作 | 策略 |
|---------|------|------|
| **LOW** | 读取文件、运行检查、生成报告 | Autonomous — 自动执行 |
| **MEDIUM** | 修改代码、新增测试、更新依赖 | Autonomous + Review — 执行后报告 |
| **HIGH** | 删除文件、修改 CI/CD、修改密钥 | Human Approval — 必须确认 |
| **IRREVERSIBLE** | 生产部署、数据迁移、force push | Human Mandatory Gate — 必须人工执行 |

### HIGH RISK 操作清单

Agent **必须暂停并询问**：
- 删除文件或大量代码行
- 修改数据库 schema
- 修改 CI/CD pipeline 配置
- 修改 Secrets / 密钥 / 环境变量
- Git force push / rebase public branch
- Production deployment
- 数据迁移脚本
- 高风险安全修复（可能破坏功能）
- 超出原始请求范围的变更

### Escalation 输出格式

当 Agent 遇到 HIGH/IRREVERSIBLE 操作时，输出：

```
⚠️ 需要人工确认

当前操作：[描述要做什么]
风险等级：HIGH / IRREVERSIBLE
影响范围：[受影响的文件/系统]
回滚方案：[如何撤销]

已尝试的替代方案：
1. [方案 A] — [为什么不可行]
2. [方案 B] — [为什么不可行]

建议选项：
1. [选项 1] — [描述]
2. [选项 2] — [描述]
3. [选项 3] — [描述]

请选择（输入编号），或提供自定义指令：
```

---

## Git 操作的安全边界

### Commit 策略

Agent 不自动 commit。代码修改和 Git 提交是两件事。用户让 Agent 改代码 ≠ 授权 Agent 管 Git history。除非用户明确说"commit 一下"。

### 回滚安全

当修改引入新问题时，Agent 的第一反应不是跑 `git stash/checkout`，而是：

```
修改引入新问题
  ↓
1. 停止当前修改
2. git diff → 精确识别哪些行需要撤回
3. 精确反向编辑（改回原来的代码）
   ├─ 可行 → 直接修复
   └─ 不可行（后续代码已经依赖了错误修改）
       ├─ 检查是否有用户未提交修改
       ├─ 有 → 必须询问用户
       └─ 没有 → 谨慎使用 git restore，报告给用户
```

### Reviewer 触发条件

不是所有 Task 都需要独立 Reviewer。用两个维度判断：

| 风险等级 | 修改规模 | 策略 |
|---------|---------|------|
| Low | 小 | 自检即可 |
| Low | 大 | 可选 Review |
| Medium | 任意 | 启用 Reviewer |
| High | 任意 | 启用 Reviewer |
| 涉及不可逆操作 | 任意 | 直接走 Human Gate |

**Reviewer 是同一个 Orchestrator 的另一次独立运行**，不是简单的"再检查一遍"。它拿到 Task 的 artifact（代码变更 + 测试 + evidence），独立评估安全、逻辑、风格。

---

## Context Budget（上下文管理）

### 每轮只保留

```
Goal
+ Current State（含 assumptions / task_graph_status / active_task_ids）
+ Relevant Files（当前关注的文件，不超过 5 个）
+ Latest Verification Result（最新一轮验证结果）
+ Known Failures（已知问题列表）
+ Next Action（下一步计划）
```

### 不重复读取

- 已验证无关的文件
- 已解决的问题
- 旧日志（非当前轮次）
- 过期测试结果
- 失败但已经被修复的尝试

### 优先读取

- 当前失败日志
- 当前 diff
- 相关源码
- 最新测试结果

### Token 预算

```yaml
CONTEXT_BUDGET:
  target: 60-70%     # 舒适区间
  hard_limit: 80%    # 超过必须截断
  preserve:          # 截断时保住的字段
    - goal
    - state
    - task_graph_status
    - latest_evidence
    - active_task_ids
    - assumptions
    - unresolved_failures
  overflow_action: truncate_history
```

每轮结束后做一次评估：当前 context 使用率？是否需要截断？截断后保留什么？

---

## Failure Recovery

### 重试不是无脑循环

每次重试前必须回答：**上次为什么失败？这次换什么策略？**

```
第 1 次失败：分析错误类型，直接修复问题
第 2 次失败：更换解决策略（换一种实现方式，不是改参数）
第 3 次失败：收缩修改范围（只改最核心的部分，其他先还原）
超过 3 次：停止，输出诊断报告，请求人工介入
```

**硬性上限：**
```yaml
MAX_RETRIES_PER_TASK: 3
MAX_TOOL_CALLS_PER_LOOP: 50
MAX_TOTAL_RUNTIME: 30m
```

### 失败分类处理

```
验证失败
    ↓
分析错误类型
    ↓
┌──────────────┬──────────────┬──────────────┐
│  工具错误     │  逻辑错误     │  环境问题     │
│  (lint/build │  (测试失败)   │  (依赖缺失)   │
│   配置问题)   │              │              │
└──────┬───────┴──────┬───────┴──────┬───────┘
       ↓              ↓              ↓
  修复配置        修复逻辑        修复环境
       ↓              ↓              ↓
  重新验证        重新验证        重新验证
       ↓              ↓              ↓
  ┌────┴────┐  ┌─────┴─────┐  ┌────┴────┐
  PASS     FAIL  PASS       FAIL  PASS     FAIL
   │         │    │           │    │         │
   ↓         ↓    ↓           ↓    ↓         ↓
  Done    Retry  Done      Retry Done     Retry
              ↓              ↓              ↓
         超过 3 次 → ESCALATE
```

### Rollback 策略

当修改引入新问题时：

```
修改引入新问题
  ↓
1. 停止当前修改
2. git diff → 精确识别哪些行需要撤回
3. 精确反向编辑（改回原来的代码）
   ├─ 可行 → 直接修复
   └─ 不可行（后续代码已经依赖了错误修改）
       ├─ 检查是否有用户未提交修改
       ├─ 有 → 必须询问用户
       └─ 没有 → 谨慎使用 git restore，报告给用户
```

**重要：** Agent 的第一反应不是跑 `git stash/checkout`，而是精确反向编辑。Git 回滚是最后手段。

### 什么时候真正停止

| 情况 | 行为 |
|------|------|
| 所有 Task done | 输出 Loop 报告 |
| Task 超过重试上限 | 标记 escalated，等用户 |
| 发现不可接受风险 | 立即 abort，报告风险性质 |
| 超出预算（时间/token/tool calls） | 暂停，报告当前进度 |

---

## Agent → Reviewer → Agent 闭环

当风险等级或修改规模触发 Reviewer 时，引入独立 Reviewer：

```
Implementer Agent
       ↓
    Artifact（代码变更 + 测试 + evidence）
       ↓
Reviewer Agent（独立上下文）
       ↓
  ┌────┴────┐
  │         │
PASS       FAIL
  │         │
  ↓         ↓
 Done     Review Comments
             ↓
          Implementer
             ↓
            Fix
             ↓
          Reviewer
```

**Reviewer 检查项：**
- 安全：注入漏洞、认证绕过、敏感信息泄露
- 逻辑：边界条件、错误处理、并发安全
- 风格：与项目现有代码风格一致

**适用范围：** 仅在风险等级 ≥ MEDIUM、或 涉及不可逆操作、或 change_size=large 时启用，避免不必要的 token 消耗。

**假设可见性：** Reviewer 也需要检查 Implementer 的 assumptions 列表，确认假设是否仍然成立。

---

## 输出格式

Loop 完成后，输出最终报告：

```markdown
# 软件工程 Loop 报告

## 任务摘要
- 类型：[Feature/Bug/Security/Release/...]
- 目标：[一句话目标]
- 执行模式：线性 / Task Graph（N 个 Task）
- 总迭代次数：[N]
- 总 Tool 调用：[N]
- 总耗时：[Nm]

## 变更清单
- [文件路径]：[变更描述]

## Evidence 汇总
| 检查项 | 状态 | 证据 |
|--------|------|------|
| Lint  | ✅/❌ | [输出摘要] |
| Test  | ✅/❌ | [通过/失败数] |
| SAST  | ✅/❌ | [高危/中危/低危] |
| Build | ✅/❌ | [状态] |

## 假设清单（如有）
- [假设内容] → [是否被后续验证推翻]

## 遗留问题
- [问题描述] + [建议处理方式]

## 人工确认项
- [需要用户决定的事项]
```

---

## Skill 索引

| 文件 | 内容 | 路由条件 |
|------|------|---------|
| `code-quality/SKILL.md` | 语言特定清理、Lint 工具、调试残留 | Phase 1 |
| `performance/SKILL.md` | 语言特定性能工具、检查点 | Phase 2 |
| `security/SKILL.md` | SAST/SCA/密钥扫描、STRIDE、合规 | Phase 3 |
| `dependencies/SKILL.md` | 构建产物、lockfile、SBOM | Phase 3 + Phase 4 |
| `documentation/SKILL.md` | README/CHANGELOG/.gitignore 模板 | Phase 5 |
| `ai-prompt-skill/SKILL.md` | Prompt 优化、Skill 结构、Token 预算 | 辅助优化 |

---

## 技术栈覆盖（11 种语言）

| 语言 | 构建系统 / 包管理 | 编译器 / 运行时 |
|------|------------------|----------------|
| **Python** | pip / Poetry / pyproject.toml | CPython 3.9+ |
| **C++** | CMake / Make / Bazel / Conan / vcpkg | GCC / Clang / MSVC |
| **R** | renv / packrat / DESCRIPTION | R 4.0+ |
| **Rust** | Cargo | rustc + LLVM |
| **C#** | MSBuild / dotnet CLI + NuGet | .NET 6+ |
| **Golang** | go mod | Go 1.21+ |
| **Haskell** | Stack / Cabal | GHC 9.x |
| **TypeScript/JavaScript** | npm / pnpm / yarn / vite / webpack | Node.js 20+ |
| **Java** | Maven / Gradle | JDK 17+ |
| **Swift** | Swift PM / CocoaPods | Swift 5.9+ |
| **Kotlin** | Gradle / Maven | Kotlin 1.9+ |

详细工具链命令见对应 Reference 文件。
