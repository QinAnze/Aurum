---
name: code-quality
description: 代码质量优化与清理。按语言特定工具链清理死代码、未使用依赖、调试残留，并通过 Lint + Formatter 提升代码整洁度。Use when the user asks to clean up code, remove dead code, run lint, fix formatting, or optimize code quality.
version: 1.0.0
---

# 代码质量与清理

## 通用清理项

删除：死代码、无用函数、未使用变量、重复实现、调试代码、临时测试文件、编译生成残留、缓存文件、无用资源文件、废弃依赖。

**外科手术约束：**
- 不确定是否使用的代码不要删除
- 保留项目原有功能
- 避免为了代码美观进行无意义重构
- 保持项目原有代码风格

---

## 语言特定清理

### Python

```bash
pip install ruff pylint mypy black isort pyflakes vulture bandit
ruff check --select F401,F841 .
pyflakes src/
vulture src/ --min-confidence 80
mypy src/ --ignore-missing-imports
bandit -r src/ -ll
black --check src/
isort --check src/
```

清理重点：`__pycache__/`、`*.pyc`、`*.egg-info/`、`dist/`、`build/`、`venv/`、`print()`/`pdb.set_trace()`/`breakpoint()` 调试残留、未使用的 `import`、`TODO`/`FIXME`/`HACK` 注释堆积。

### C++

```bash
cppcheck --enable=all --suppress=missingIncludeSystem src/
clang-tidy src/*.cpp -- -Iinclude -std=c++17
clang-format --dry-run --Werror src/*.cpp include/*.h
include-what-you-use src/*.cpp
```

清理重点：`build/`、`cmake-build-*/`、`*.o`/`*.so`/`*.a`/`*.exe`、`.vs/`、`*.user`、未使用的头文件、`#ifdef DEBUG`/`#if 0` 残留、`using namespace std;` 头文件滥用、裸 `new`/`delete` 未用智能指针。

### R

```r
install.packages(c("lintr", "styler", "pkgload", "cleanrmd"))
lintr::lint_dir("R/")
styler::style_dir("R/", dry = "on")
pkgload::load_all(".")
```

清理重点：`.Rhistory`/`.RData`/`.Rprofile`/`.Renviron`、`*.Rproj.user/`、`renv/`/`packrat/`、`print()`/`cat()`/`browser()` 调试残留、散落的 `library()`/`require()`、硬编码路径 `setwd()`。

### Rust

```bash
cargo fmt -- --check
cargo clippy --all-targets --all-features -- -D warnings
cargo audit
cargo udeps
```

清理重点：`target/`、`Cargo.lock`（二进制提交/库忽略）、`*.rs.bk`、未使用的 `use`、`dbg!()`/`println!()`/`eprintln!()` 调试残留、`unwrap()` 滥用、`todo!()`/`unimplemented!()`/`unreachable!()` 宏残留、`#[allow(...)]` 过度使用。

### C#

```bash
dotnet format --verify-no-changes
dotnet build -c Release
dotnet build /p:TreatWarningsAsErrors=true
```

清理重点：`bin/`/`obj/`、`.vs/`、`*.user`、`packages/`、`*.dll`/`*.exe`、未使用的 `using`、`Debugger.Launch()`/`Console.WriteLine()` 调试残留、`#region` 过度嵌套、`async void` 方法、`IDisposable` 未正确实现 `using`。

### Golang

```bash
go fmt ./...
go vet ./...
golangci-lint run ./...
govulncheck ./...
gosec ./...
gofmt -l ./...
go mod tidy
```

清理重点：`vendor/`、`*.exe`/`*.test`、`go.sum` 校验和、未使用的导入（编译器报错）、`fmt.Println()`/`log.Println()` 调试残留、`panic()` 滥用、`go:embed` 路径失效、`context.Context` 未传递、`goroutine` 泄漏。

### Haskell

```bash
stack build
cabal build
hlint src/
ormolu --mode check src/
stack update
cabal update
```

清理重点：`.stack-work/`/`dist/`/`dist-newstyle/`、`*.hi`/`*.o`、`stack.yaml.lock`（Stack 提交）、`cabal.project.freeze`（Cabal 提交）、未使用的导入、`error "TODO"`/`undefined` 占位符、`PartialFunctions` 警告（`head`/`tail`/`fromJust`）。

### TypeScript / JavaScript

```bash
npm install --save-dev eslint prettier typescript @typescript-eslint/parser @typescript-eslint/plugin
npm audit
npx depcheck
npx eslint src/ --ext .ts,.tsx,.js,.jsx
npx prettier --check "src/**/*.{ts,tsx,js,jsx,json,md}"
npx tsc --noEmit
```

清理重点：`node_modules/`、`dist/`/`build/`/`.next/`/`.nuxt/`、`*.log`、`.env`/`.env.local`、`coverage/`、`*.tsbuildinfo`、未使用的 npm 包、`console.log()`/`debugger` 调试残留、`any` 类型滥用、`// @ts-ignore`/`// @ts-expect-error` 过度使用。

### Java

```bash
mvn spotbugs:check
mvn pmd:check
mvn dependency:analyze
mvn org.owasp:dependency-check-maven:check
# 或 Gradle
./gradlew spotbugsMain pmdMain dependencyCheckAnalyze
```

清理重点：`target/`(Maven)/`build/`(Gradle)、`.idea/`/`*.iml`、`*.class`/`*.jar`、`dependency-reduced-pom.xml`、未使用的 import、`System.out.println()` 调试残留、`e.printStackTrace()` → 日志框架、`@SuppressWarnings` 过度使用。

### Swift

```bash
swiftformat --lint .
swiftlint lint
xcodebuild -project App.xcodeproj -scheme App build
```

清理重点：`.build/`/`DerivedData/`/`xcuserdata/`、`Package.resolved`、强制解包 `!` 滥用、`print()` 调试残留、`fatalError()`/`precondition()` 生产代码风险。

### Kotlin

```bash
./gradlew detekt ktlintCheck dependencyCheckAnalyze
```

清理重点：`build/`/`.gradle/`、`*.iml`、`local.properties`、`!!` 强制解包滥用、`println()` 调试残留、协程异常处理（`CoroutineExceptionHandler`）。

---

## 安全维度

- [ ] 删除的代码是否包含安全检查逻辑（误删防护）
- [ ] 清理是否暴露敏感信息（如注释中的密码、内部地址）
- [ ] 依赖移除是否影响安全扫描工具（如 Snyk、Dependabot）

## 验证标准

- [ ] 静态分析工具零错误
- [ ] 格式化检查通过
- [ ] 未使用依赖已移除
- [ ] 调试残留已清除
- [ ] 原有功能未被破坏
