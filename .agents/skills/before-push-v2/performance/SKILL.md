---
name: performance
description: 性能分析与优化。按语言特定工具链（pprof/perf/cProfile等）识别瓶颈、内存泄漏、低效算法，并提供可复现的基准测试验证。Use when the user asks to optimize performance, reduce latency, fix memory leaks, or improve throughput.
version: 1.0.0
---

# 性能优化

## 通用原则

**优先解决真实性能问题，避免过度优化。**

检查前：
1. 是否有明确的性能指标（响应时间、吞吐量、内存占用）？
2. 是否有可复现的 benchmark 场景？
3. 是否已识别出热点路径？

---

## 代码层面

- 算法复杂度（O(n²) → O(n log n) 是否有必要）
- 内存分配（不必要的拷贝、大对象生命周期）
- 数据结构选择（Map vs Object、Set vs Array）
- 重复计算（循环内重复调用、无缓存的递归）
- 文件/网络 I/O（同步阻塞、无缓冲读写）
- 异步/并发（Promise 并行化、goroutine 泄漏、线程池饱和）

## 应用层面

- 启动速度（懒加载、预加载策略）
- 内存占用（内存泄漏、大对象未释放）
- 缓存策略（命中率、失效机制、缓存穿透）
- 资源加载（图片/字体/脚本的懒加载、CDN 策略）

---

## 语言特定性能检查

### Python

**工具：** `cProfile` / `memory_profiler`

```bash
python -m cProfile -s tottime script.py
python -m memory_profiler script.py
```

关键检查点：
- 循环内重复计算提取
- 生成器替代列表（`yield` 替代返回大列表）
- `''.join(list)` 替代字符串 `+` 拼接
- I/O 批量化（batch read/write）
- N+1 查询（ORM 预加载、join 查询）
- `functools.lru_cache` / `functools.cache`
- GIL 瓶颈（CPU 密集用 `multiprocessing`，非 `threading`）

### C++

**工具：** `perf` / `valgrind` / `heaptrack`

```bash
perf stat ./program
valgrind --tool=callgrind ./program
heaptrack ./program
```

关键检查点：
- 大对象拷贝（引用/移动语义、RVO/NRVO）
- 虚函数热路径（devirtualization、final 类）
- 内存对齐（cache line、padding）
- 缓存友好性（数据布局、分支预测）
- 动态内存分配频率（对象池、arena allocator）
- 编译器优化级别（`-O2`/`-O3`/`-flto`）
- 向量化（SIMD、auto-vectorization）

### R

**工具：** `Rprof` / `summaryRprof`

```r
Rprof("profile.out")
# ... 代码 ...
Rprof(NULL)
summaryRprof("profile.out")
```

关键检查点：
- 循环替代（`apply`/`purrr`/`data.table` 替代 `for`）
- 内存预分配（避免动态扩展向量）
- `data.table` > `dplyr` > `base`
- `parallel::mclapply` / `future` / `furrr`
- `Rcpp` 加速关键循环

### Rust

**工具：** `cargo bench` / `flamegraph` / `instruments`

```bash
cargo bench
cargo flamegraph
```

关键检查点：
- 不必要 `clone()`（借用、Cow、引用）
- `String` / `&str` 合理性
- 迭代器链内联（`fold` 替代 `collect` + 二次遍历）
- 锁竞争（`parking_lot`、无锁结构）
- 内存分配频率（`SmallVec`、`bumpalo`）
- async 开销（是否值得异步化）
- 泛型单态化膨胀（`Box<dyn Trait>` 动态分发）

### C#

**工具：** dotTrace / BenchmarkDotNet

```bash
dotnet run -c Release --project Benchmarks
```

关键检查点：
- 装箱/拆箱（泛型集合替代 `ArrayList`）
- `StringBuilder`（字符串拼接）
- LINQ 热路径（`foreach` 替代 `.Where().Select()`）
- `ValueTask`（热路径异步）
- 集合初始容量（`new List<T>(capacity)`）
- GC 触发（大对象堆 LOH、避免频繁分配）
- 反射 Emit（缓存 `Delegate`）

### Golang

**工具：** `pprof` / `benchmem`

```bash
go test -bench=. -benchmem -cpuprofile=cpu.prof
go tool pprof cpu.prof
```

关键检查点：
- 内存逃逸分析（`go build -gcflags="-m"`）
- 切片/Map 预分配（`make([]T, 0, cap)`）
- `strings.Builder`（字符串拼接）
- 锁竞争（`sync.RWMutex`、`atomic`）
- GC 调优（`GOGC`、 ballast）
- goroutine 泄漏（`context.WithTimeout`、WaitGroup）

### Haskell

**工具：** `+RTS -p -hc -s`

```bash
./program +RTS -p -hc -s
```

关键检查点：
- 惰性求值内存泄漏（`foldl'` 替代 `foldl`）
- 严格性标注（`!`、`BangPatterns`）
- 列表 vs `Vector`（随机访问）
- 空间泄漏（thunk 堆积、`$!`、`deepseq`）
- GHC 优化级别（`-O2`）

### TypeScript / JavaScript

**工具：** `--prof` / `clinic` / `0x`

```bash
node --prof script.js
clinic doctor -- node script.js
```

关键检查点：
- 内存泄漏（闭包、事件监听器、定时器）
- 虚拟滚动（大列表）
- 防抖/节流（resize、scroll、input）
- 代码分割（dynamic import、lazy loading）
- Tree Shaking（`sideEffects: false`、避免副作用）
- 事件循环阻塞（`setImmediate`、Worker Threads）

### Java

**工具：** JFR / async-profiler

```bash
java -XX:StartFlightRecording=duration=60s,filename=recording.jfr -jar app.jar
async-profiler -d 60 -f flamegraph.html <pid>
```

关键检查点：
- JVM 堆配置（`-Xms`、`-Xmx`、`-XX:+UseZGC`）
- GC 算法（G1/ZGC/Shenandoah）
- `StringBuilder`（字符串拼接）
- 集合初始容量
- N+1 查询（JPA `EntityGraph`、`JOIN FETCH`）
- 线程池配置（`ThreadPoolExecutor` 参数）
- 类加载泄漏（`ClassLoader`、static 集合）

### Swift

**工具：** Instruments / `xcrun simctl`

关键检查点：
- ARC 优化（weak/unowned 打破循环）
- 值类型 vs 引用类型（`struct` vs `class`）
- `lazy` 属性（延迟初始化）
- GCD 队列优化（`DispatchQueue`、`async/await`）
- 内存泄漏检测（Instruments → Leaks）

### Kotlin

**工具：** `kotlinx-benchmark` / Android Studio Profiler

关键检查点：
- 协程调度优化（`Dispatchers.IO` vs `Default`）
- `inline` 函数（高阶函数）
- 集合操作链（`Sequence` vs `List`）
- JVM 调优（同 Java）
- 避免装箱（`Int` 替代 `Integer`）

---

## 安全维度

- [ ] 缓存是否存储敏感数据（明文缓存风险）
- [ ] 异步处理是否引入竞态条件（TOCTOU 漏洞）
- [ ] 性能优化是否绕过安全检查（缓存命中跳过鉴权）

## 验证标准

- [ ] 关键路径性能无退化
- [ ] 内存泄漏已识别并修复
- [ ] 基准测试结果可复现
