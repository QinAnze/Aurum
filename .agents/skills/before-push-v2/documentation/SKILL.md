---
name: documentation
description: 文档更新与维护。检查并更新README.md、CHANGELOG.md、SECURITY.md、部署文档和.gitignore模板。Use when the user asks to update documentation, sync changelog, or prepare release docs.
version: 1.0.0
---

# 文档更新

## README.md

检查并更新：项目介绍、功能列表、使用方法、安装步骤、架构说明、新增功能、编译方式。保持准确、简洁、易读。

### 结构模板

```markdown
# 项目名

一句话定位。

## 功能

- 核心功能 1
- 核心功能 2

## 安装

\`\`\`bash
# 依赖安装命令
\`\`\`

## 使用

\`\`\`bash
# 最小可运行示例
\`\`\`

## 架构

[核心模块关系图或描述]

## 开发

\`\`\`bash
# 构建命令
# 测试命令
\`\`\`

## 许可证

[许可证类型]
```

---

## 安全相关文档

### SECURITY.md

```markdown
# 安全政策

## 支持的版本

| 版本 | 支持状态 |
|------|---------|
| x.y.z  | ✅ 支持 |
| x.y-1.z | ⚠️ 安全修复 only |

## 报告漏洞

请发送邮件至 security@example.com，包含：
- 漏洞描述
- 复现步骤
- 影响范围
- 建议修复方案（如有）

我们会在 48 小时内确认收到，7 天内提供修复计划。

## 安全更新策略

- 高危漏洞：7 天内修复并发布
- 中危漏洞：30 天内修复并发布
- 低危漏洞：下次版本迭代修复
```

### CHANGELOG.md

```markdown
# 变更日志

## [Unreleased]

### Security Fix
- [CVE-2024-XXXX] 修复 XX 漏洞（高危）
- [SEC-001] 移除硬编码密钥

### Added
- 新增 XX 功能

### Fixed
- 修复 XX bug
```

### 部署文档

- 环境变量清单（敏感变量标记为 `[SENSITIVE]`）
- 安全配置基线
- 密钥轮换流程
- 回滚步骤

### 应急响应计划

- 安全事件分级：P0（Critical）/ P1（High）/ P2（Medium）/ P3（Low）
- 联系人清单（On-call 工程师、安全负责人）
- 回滚流程
- 取证与复盘

---

## .gitignore 模板

```
# Python
__pycache__/
*.py[cod]
*$py.class
*.egg-info/
dist/
build/
.eggs/
venv/
.env
.env.local
.env.*.local
.pytest_cache/
.mypy_cache/
.ruff_cache/
*.secret
.secrets-baseline

# C++
build/
cmake-build-*/
*.o
*.obj
*.so
*.a
*.dll
*.dylib
*.exe
CMakeCache.txt
CMakeFiles/
Makefile
*.user
*.suo
.vs/

# R
.Rhistory
.RData
.Rprofile
.Renviron
*.Rproj.user/
.Ruserdata
renv/
packrat/

# Rust
target/
*.rs.bk
Cargo.lock  # 仅库项目

# C#/
bin/
obj/
*.user
*.suo
*.userprefs
.vs/
packages/

# Golang
*.exe
*.test
*.out/
vendor/  # 按需

# Haskell
.stack-work/
dist/
dist-newstyle/
*.hi
*.o
*.dyn_hi
*.dyn_o
stack.yaml.lock  # 仅 Stack
cabal.project.freeze  # 仅 Cabal

# TypeScript/JavaScript
node_modules/
dist/
build/
.next/
.nuxt/
.output/
coverage/
*.log
npm-debug.log*
yarn-debug.log*
yarn-error.log*
.env
.env.local
.env.*.local
*.tsbuildinfo

# Java
target/
build/
*.class
*.jar
*.war
.idea/
*.iml
.classpath
.project
.settings/
dependency-reduced-pom.xml

# Swift
.build/
DerivedData/
xcuserdata/
Package.resolved
*.xcodeproj
*.xcworkspace

# Kotlin
build/
.gradle/
*.iml
.idea/
local.properties

# 通用密钥和敏感文件
*.pem
*.key
*.p12
*.pfx
*.jks
*.keystore
*.mobileprovision
*.provisionprofile
credentials.json
service-account.json
*secret*
*token*
*password*
.aws/
.azure/
.gcp/
```

---

## 安全维度

- [ ] 文档是否泄露内部架构细节（攻击面暴露）
- [ ] 示例代码是否包含真实密钥或内部地址
- [ ] .gitignore 是否防止敏感文件提交

## 验证标准

- [ ] README.md 完整准确
- [ ] CHANGELOG.md 更新（含安全修复标注）
- [ ] SECURITY.md 更新
- [ ] 部署文档更新
- [ ] .gitignore 配置正确
