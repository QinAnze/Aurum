---
name: security
description: 安全审计与加固。覆盖SAST/SCA/密钥扫描/STRIDE威胁建模/合规检查，按语言特定工具链识别漏洞并提供修复方案。Use when the user asks to check security, scan for vulnerabilities, audit code, or prepare for compliance.
version: 1.0.0
---

# 安全性检查

## 安全开发生命周期 (SDL) 检查清单

```
□ 安全需求：是否定义了安全需求和威胁模型？
□ 安全设计：是否遵循最小权限、纵深防御原则？
□ 安全编码：是否使用了安全的编码实践和工具？
□ 安全测试：是否进行了安全测试（SAST / DAST / IAST / SCA）？
□ 安全部署：是否遵循安全部署实践？
□ 安全运维：是否有监控、告警和应急响应机制？
```

---

## 通用安全检查项

### 密钥与凭据管理
- 硬编码密钥扫描：`git-secrets` / `trufflehog` / `gitleaks` / `detect-secrets`
- 凭据存储：禁止明文 → 推荐 Vault / KMS / 环境变量
- 密钥生命周期：定期轮换、离职撤销、环境隔离

### 供应链安全
- SBOM 生成：`syft` / `cyclonedx` / `trivy`
- 依赖签名验证：`sha256` / `GPG` / `Sigstore` / `Notary`
- 依赖漏洞扫描：`Snyk` / `Dependabot` / `Renovate`
- 私有仓库安全：镜像源可信度、访问权限、镜像签名

### 代码安全
- SAST：`Semgrep` / `SonarQube` / `CodeQL`
- 密钥泄露防护：`pre-commit` 钩子 + GitHub Secret Scanning
- 安全编码规范：OWASP / CERT

### 数据安全
- 数据分类：公开 / 内部 / 机密 / 绝密
- 传输加密：TLS 1.2+ / HSTS / 证书 pinning
- 存储加密：AES-256 / TDE / 字段级加密
- 数据脱敏：日志脱敏 / 测试环境脱敏 / API 响应脱敏

### 身份认证与授权
- 认证：MFA / 密码策略 / JWT 安全 / OAuth 2.0 / Session 安全
- 授权：最小权限 / 默认拒绝 / 越权检查 / mTLS
- 审计日志：可追溯 / 防篡改 / 保留期限

### API 安全
- OWASP API Security Top 10（BOLA / BOPLA / SSRF 等 10 项）
- API 网关：速率限制 / 请求体限制 / CORS / JSON Schema 验证
- GraphQL（如适用）：深度限制 / 复杂度限制 / 内省禁用

### 前端安全
- OWASP Top 10 (Web)（访问控制 / 密码学失败 / 注入 等 10 项）
- 输入验证与输出编码：服务端验证 / CSP / Trusted Types
- XSS / CSRF 防护：模板自动转义 / CSRF Token / SameSite Cookie
- 第三方脚本：SRI / 脚本审查

### 容器与云安全
- Docker：非 root / 最小镜像 / 多阶段构建 / 镜像扫描（`Trivy` / `Grype`）
- Kubernetes：Pod 安全标准 / NetworkPolicy / RBAC / OPA
- 云：IAM 最小权限 / 存储桶公开访问 / 日志启用 / 加密启用

### IaC 安全
- Terraform / CloudFormation：`tfsec` / `checkov` / `cfn-nag`
- CI/CD：管道权限最小化 / 密钥不暴露 / 签名构件

---

## 语言特定安全检查

### Python

**工具：** `bandit` / `pip-audit` / `semgrep`

```bash
bandit -r src/ -ll
pip-audit
semgrep --config=auto src/
```

关键检查项：
- 硬编码密钥 / 密码
- `eval()` / `exec()` / `pickle` 反序列化
- SQL 拼接（非参数化查询）
- 路径遍历（`open(user_input)`）
- `subprocess` shell=True
- `yaml.load()` 非安全加载（应使用 `yaml.safe_load()`）
- `verify=False`（SSL 证书验证跳过）
- SSRF（用户控制 URL 请求）
- 模板注入（Jinja2 未转义）
- `DEBUG=True`（生产环境）
- `random` → `secrets`（安全随机数）

### C++

**工具：** `cppcheck` / `clang-tidy`

```bash
cppcheck --enable=all --suppress=missingIncludeSystem src/
clang-tidy src/*.cpp -- -Iinclude -std=c++17
```

关键检查项：
- 缓冲区溢出（`strcpy` → `strncpy`、`snprintf`）
- 格式化字符串漏洞（`printf(user_input)`）
- 整数溢出（`int` 运算前检查范围）
- 悬垂指针（use-after-free、double-free）
- `memcpy` 重叠（使用 `memmove`）
- 临时文件竞争（`tmpnam` → `mkstemp`）
- ASLR/NX/Stack Canary 编译标志
- 不安全函数（`gets`、`sprintf`、`strcat`）
- 竞态条件（TOCTOU）

### R

**工具：** 人工审查

关键检查项：
- 硬编码凭据
- `eval(parse(text=user_input))` 注入
- `system()` 命令注入
- 不安全临时文件（`tempfile()` 竞争）
- `setwd()` 硬编码路径
- RData 反序列化
- Shiny 安全（输入验证、SQL 注入）

### Rust

**工具：** `cargo audit` / `cargo deny` / `cargo geiger`

```bash
cargo audit
cargo deny check
cargo geiger
```

关键检查项：
- `unsafe` 块边界检查
- `unwrap()` DoS（panic 导致服务中断）
- 密钥零化（`zeroize` crate）
- 恒定时间比较（`subtle` crate）
- `serde` 深度限制（反序列化炸弹）
- FFI 边界检查
- 整数溢出（`checked_add`、`overflowing_add`）

### C#

**工具：** `dotnet security-scan`

关键检查项：
- 硬编码连接字符串
- SQL 拼接
- `BinaryFormatter`（不安全反序列化）
- XXE（`XmlReader` 配置）
- `ViewState` MAC 验证
- `unsafe` 块
- P/Invoke 安全

### Golang

**工具：** `govulncheck` / `gosec` / `semgrep`

```bash
govulncheck ./...
gosec ./...
semgrep --config=auto .
```

关键检查项：
- 硬编码密钥
- SQL 拼接（`fmt.Sprintf` 拼接 SQL）
- `exec.Command` 注入
- `crypto/rand`（非 `math/rand`）
- 弱算法（MD5、SHA1、DES）
- `http.ListenAndServe` 超时配置
- 路径遍历
- `-race` 竞态检测

### Haskell

**工具：** `hlint` + 人工审查

关键检查项：
- 硬编码凭据
- `unsafePerformIO`
- 模板 Haskell 注入
- 资源泄漏（文件句柄、数据库连接）
- 日志敏感信息

### TypeScript / JavaScript

**工具：** `npm audit` / `snyk` / `eslint`

```bash
npm audit --audit-level=high
snyk test
npx eslint src/ --ext .ts,.tsx,.js,.jsx
```

关键检查项：
- XSS（`innerHTML`、`document.write`、`dangerouslySetInnerHTML`）
- CSRF（SameSite Cookie、CSRF Token）
- CSP 头
- 依赖混淆（typosquatting）
- 供应链攻击（恶意 npm 包）
- `eval()` / `Function()` 动态执行
- 原型链污染（`__proto__`、`constructor`）
- ReDoS（正则表达式拒绝服务）
- 环境变量泄露（`process.env` 暴露给前端）

### Java

**工具：** `dependency-check` / `spotbugs`

```bash
mvn org.owasp:dependency-check-maven:check
mvn spotbugs:check
# 或 Gradle
./gradlew dependencyCheckAnalyze spotbugsMain
```

关键检查项：
- SQL 注入（MyBatis `${}` 拼接）
- XXE（`SAXParser`、`DocumentBuilderFactory`）
- 不安全反序列化（`ObjectInputStream`）
- Log4Shell（Log4j 版本）
- Spring Boot Actuator 端点暴露
- SpEL / OGNL 表达式注入

### Swift

**工具：** 人工审查

关键检查项：
- 强制解包 `!` DoS（nil 时 crash）
- UserDefaults 明文存储
- Keychain 访问控制
- ATS 配置（`NSAllowsArbitraryLoads`）
- 证书 pinning

### Kotlin

**工具：** `detekt` / `ktlint`

```bash
./gradlew detekt ktlintCheck
```

关键检查项：
- `!!` 强制解包（null 时 NPE）
- `lateinit` 未初始化访问
- 协程异常处理（`CoroutineExceptionHandler`）
- Intent 安全（隐式 Intent、PendingIntent）
- SharedPreferences 明文存储
- WebView 安全（`setJavaScriptEnabled`、`addJavascriptInterface`）

---

## 安全工具矩阵

| 类别 | 工具 | 用途 |
|------|------|------|
| **SAST** | Semgrep / SonarQube / CodeQL / Bandit / GoSec / Clang Static Analyzer | 语义分析、代码质量 + 安全 |
| **SCA** | Snyk / Dependabot / Renovate / OWASP DC / pip-audit / cargo-audit / npm audit / govulncheck | 依赖漏洞 + 自动更新 |
| **密钥扫描** | git-secrets / trufflehog / gitleaks / detect-secrets | Git 仓库密钥扫描 |
| **容器安全** | Trivy / Grype / Snyk Container | 容器镜像漏洞扫描 |
| **IaC 安全** | tfsec / checkov / cfn-nag | IaC 安全扫描 |
| **DAST** | OWASP ZAP / Burp Suite / Nikto | 动态 Web 安全测试 |
| **模糊测试** | AFL++ / cargo-fuzz / go-fuzz | 模糊测试 |
| **SBOM** | Syft / CycloneDX | SBOM 生成 / 标准 |
| **签名** | Sigstore / cosign | 构件签名验证 |

---

## 威胁建模（STRIDE）

| 威胁类型 | 描述 | 典型攻击 | 缓解措施 |
|----------|------|---------|---------|
| **S**poofing | 冒充他人身份 | 会话劫持 / IP 欺骗 | 强认证 / MFA |
| **T**ampering | 修改数据或代码 | 中间人攻击 / 参数篡改 | 数字签名 / 完整性校验 |
| **R**epudiation | 否认执行操作 | 删除日志 | 审计日志 / 数字签名 |
| **I**nformation Disclosure | 敏感信息暴露 | 目录遍历 / 错误信息泄露 | 加密 / 错误处理 |
| **D**enial of Service | 服务不可用 | DDoS / 资源耗尽 | 速率限制 / 弹性伸缩 |
| **E**levation of Privilege | 获取更高权限 | 垂直越权 / 注入 | 最小权限 / 输入验证 |

---

## 安全测试

- 单元测试：边界值、注入、认证/授权
- 集成测试：API 认证失败、速率限制、会话超时
- DAST：OWASP ZAP / Burp Suite
- 渗透测试：第三方专业测试 / Bug Bounty
- 模糊测试：关键输入接口、协议解析
- 安全回归测试：已知漏洞回归、补丁验证

---

## 合规性检查（如适用）

- **GDPR**：用户数据访问权/删除权、DPIA、72 小时泄露通知
- **中国网络安全法/数据安全法/个人信息保护法**：数据分类分级、告知同意、数据出境评估、等保 2.0
- **SOC 2**：安全性/可用性/处理完整性/机密性/隐私性
- **PCI DSS**：持卡人数据保护、加密传输存储
- **HIPAA**：PHI 安全、访问控制、审计控制

---

## 验证标准

- [ ] SAST 扫描通过
- [ ] SCA 扫描通过
- [ ] 密钥扫描通过
- [ ] 容器镜像扫描通过（如适用）
- [ ] DAST 扫描通过（如适用）
- [ ] 依赖无高危漏洞
- [ ] 所有已知 CVE 已修复或有缓解措施
- [ ] SBOM 已生成
