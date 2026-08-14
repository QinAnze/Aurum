---
name: dependencies
description: 依赖管理与供应链安全。检查构建产物、lockfile完整性、SBOM生成、依赖签名验证和漏洞扫描。Use when the user asks to manage dependencies, check for supply chain issues, generate SBOM, or verify build reproducibility.
version: 1.0.0
---

# 依赖管理

## 构建产物检查清单

确保构建产物正确且可复现：

### Python
- `requirements.txt` / `poetry.lock` / `pyproject.toml`
- `setup.py` / `__init__.py`
- `python -m build`

### C++
- `CMakeLists.txt`
- 编译器版本/标志
- Conan lockfile / `vcpkg.json`

### R
- `DESCRIPTION`
- `renv.lock` / `packrat.lock`
- `NAMESPACE`

### Rust
- `Cargo.toml`
- `Cargo.lock`（二进制提交/库忽略）
- features 默认值

### C#
- `*.csproj` PackageReference
- `nuget.config`
- 多目标框架

### Golang
- `go.mod` / `go.sum`
- 模块路径（v2+）
- `vendor/` 一致性

### Haskell
- `stack.yaml` resolver
- `cabal.project.freeze`
- GHC 版本

### TypeScript / JavaScript
- `package-lock.json` / `yarn.lock` / `pnpm-lock.yaml`
- `.npmrc`
- `dist/` 可复现

### Java
- `pom.xml` / `build.gradle`
- Gradle 锁定文件
- `mvn dependency:tree`

### Swift
- `Package.resolved`
- Xcode 项目文件冲突检查

### Kotlin
- `build.gradle.kts`
- Gradle 版本目录（`libs.versions.toml`）

---

## 多语言混合项目依赖关系图

- 语言间接口（FFI / C ABI / gRPC / REST）版本兼容性
- 序列化/反序列化协议（Protobuf / JSON / MessagePack）一致性
- 共享配置文件格式统一
- 跨语言日志格式统一
- 构建顺序依赖（Makefile / CMake / 脚本编排）
- 容器化构建（Dockerfile 多阶段构建）

---

## 供应链安全

### SBOM 生成
```bash
# 通用
syft packages dir:. -o spdx-json > sbom.spdx
trivy fs --format cyclonedx -o sbom.json .

# 各语言特定
cdxgen -o sbom.json
cargo cyclonedx
```

### 依赖签名验证
- `sha256` 校验和
- `GPG` 签名
- `Sigstore` / `Notary`

### 依赖漏洞扫描
```bash
# Python
pip-audit

# Node.js
npm audit --audit-level=high

# Rust
cargo audit

# Go
govulncheck ./...

# Java
mvn org.owasp:dependency-check-maven:check
```

---

## 验证标准

- [ ] Debug 构建成功
- [ ] Release 构建成功
- [ ] 构建可复现（相同 commit 产生相同产物）
- [ ] 构建产物大小合理
- [ ] SBOM 已生成
- [ ] 依赖无高危漏洞
