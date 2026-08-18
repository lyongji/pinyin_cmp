# 拼音补全 (Pinyin Completion)

> 在 Neovim 中输入拼音时自动补全中文（CJK）词汇，支持文本和代码两种场景。

---

## 项目概述

拼音补全是一个 Neovim 插件 + C++ CLI 的混合项目，通过在缓冲区中收集中文词汇（文本词 + LSP 代码标识符），使用 ib_pinyin 库进行拼音匹配，实现输入拼音时自动补全中文的功能。

### 核心技术栈

| 层 | 技术 | 作用 |
|----|------|------|
| 匹配引擎 | C++ (C++latest) + ib_pinyin C 库 | 拼音模式匹配（简拼/全拼/双拼等） |
| 构建系统 | xmake | C++ 编译 |
| CLI 工具 | C++ (xmake build cli) | 供 Lua 插件调用的命令行匹配程序 |
| Neovim 插件 | Lua | 候选词收集、上下文检测、调用 CLI |
| 补全框架 | blink.cmp (主) / omnifunc (同步回退) | 展示补全菜单 |
| LSP 集成 | `textDocument/documentSymbol` | 提取中文代码标识符 |
| 测试 | Python + Lua | CLI 逻辑测试 + Neovim 内插件测试 |

### 项目特点

- **全中文代码**：C++ 源码使用中文标识符（函数名、变量名、枚举等），遵循 `CODING_STANDARD.md`（中文代码命名规范）
- **上下文感知**：自动检测光标上下文（代码/注释/字符串），切换候选词来源
- **多拼音方案**：支持简拼、全拼、带声调全拼、Unicode、6 种双拼方案（共 10 种注音方式）
- **纯同步**：CLI 调用为同步操作（C++ 匹配 < 10ms），无异步复杂性

---

## 项目结构

```
拼音补全/
├── xmake.lua              # 构建配置 — 两个 target: pinyin (demo) + cli (插件用)
├── CODING_STANDARD.md     # 中文代码命名规范（V8.0）
├── AGENT.md               # 本文件 — 项目总览
│
├── src/
│   ├── main.cpp           # Demo 入口 — 展示 pinyin 库用法
│   ├── pinyin.cpp         # 核心：封装 ib_pinyin C API 为 C++ 接口
│   ├── cli.cpp            # CLI 入口 — 拼音匹配命令行工具
│   ├── shuangpin.cpp      # 双拼转换 — 加加/华宇双拼转全拼（补足 ib_pinyin 缺口）
│   └── shuangpin.hpp      # 双拼转换头文件
│
├── include/ib_pinyin/
│   ├── pinyin.hpp         # C++ 头文件 — 注音方式枚举、匹配结果结构体、API 声明
│   ├── ib_pinyin.h        # ib_pinyin C 库头文件（diplomat FFI 风格）
│   └── diplomat_runtime.h # diplomat 运行时头文件
│
├── lib/                   # ib_pinyin C 库预编译产物
│   ├── libib_pinyin_c.so  # Linux
│   ├── libib_pinyin_c.a   # Linux 静态库
│   ├── ib_pinyin_c.dll    # Windows
│   ├── ib_pinyin_c.lib    # Windows
│   └── ib_pinyin_c.dll.lib
│
├── lua/
│   ├── cmp_pinyin/
│   │   ├── init.lua       # 核心模块 — setup / LSP 标识符收集 / 文本词收集 / CLI 调用 / 上下文检测
│   │   ├── blink.lua      # blink.cmp provider — get_completions 入口
│   │   └── bin/           # CLI 编译产物（gitignore）
│   └── README.md          # 插件完整文档
│
├── test/
│   ├── example.py         # 含中文标识符的测试文件
│   └── test_plugin.lua    # Neovim 内插件测试脚本
│
└── test.py                # CLI 匹配逻辑的 Python 测试脚本
```

---

## 核心架构

### 数据流

```
用户输入拼音 (ASCII 字母)
  │
  ▼
get_cursor_context()                   ← 启发式检测上下文（commentstring + 引号计数）
  │
  ▼
collect_candidates(bufnr, opts)        ← 收集候选词
  ├─ mode='code' → LSP documentSymbol（中文函数/变量/类名等）
  ├─ mode='text' → 正则匹配文本词 [%w_]+ 或连续 CJK 主区字符（全角标点自动分隔）
  └─ mode='all'  → 合并两者
  │
  ▼
cli <query> <candidates...>            ← C++ CLI 进行拼音匹配
  │                                      输入：stdin 逐行候选词
  │                                      输出：tab 分隔的 word + score
  ▼
parse_cli_output()                     ← 按 score 排序
  │
  ▼
get_lsp_symbol_info()                  ← 查询 SymbolKind
  ├─ 可调用（Function/Method/Constructor）→ append "()"
  └─ 其他                             → 原样返回
  │
  ▼
blink.cmp 补全菜单
```

### C++ 层 (`pinyin.cpp` + `cli.cpp`)

**`pinyin::注音方式` 枚举** — 位掩码设计，支持多方案组合：

| 值 | 方案 | 说明 |
|----|------|------|
| `0x1` | 简拼 | 首字母（yh → 用户） |
| `0x2` | 全拼 | 全拼（yonghu → 用户） |
| `0x4` | 带声调全拼 | yong4hu4 → 用户 |
| `0x8` | unicode | Unicode 编码 |
| `0x10` | abc双拼 | ABC 双拼 |
| `0x20` | 加加双拼 | 加加双拼 |
| `0x40` | 微软双拼 | 微软双拼 |
| `0x80` | 华宇双拼 | 华宇双拼 |
| `0x100` | 小鹤双拼 | 小鹤双拼 |
| `0x200` | 自然码双拼 | 自然码双拼 |

**核心 API（C++ 封装）**：
- `是否匹配(模式, 文本, 方式)` → `bool`
- `查找匹配(模式, 文本, 方式)` → `std::optional<匹配结果{开始, 结束}>`

**CLI 用法**：
```
cli [--notation 名称]... <拼音查询> [候选词...]
cli [--notation 名称]... -f <候选词文件> <拼音查询>
echo 候选词 | cli [--notation 名称]... <拼音查询>
```

CLI 输出格式：`候选词\t得分`（得分低者优先，编码了匹配起始位置、匹配长度、词长信息）

**计分算法**（在 `cli.cpp` 中）：
```
得分 = (匹配开始 << 32) | ((匹配长度) << 16) | 候选词长度
```
_score 越低匹配越好；优先匹配位置靠前 → 匹配长度短 → 词短。_

### Lua 层 (`init.lua`)

**配置项** (`M.config`)：

| 配置 | 默认值 | 说明 |
|------|--------|------|
| `cli_path` | 自动检测 | CLI 可执行文件路径 |
| `min_query_len` | 2 | 最小拼音查询长度 |
| `notation` | `{'简拼', '全拼'}` | 拼音标注方案 |
| `max_candidates` | 300 | 缓冲区最多收集的 CJK 候选项 |

**核心函数**：

| 函数 | 用途 |
|------|------|
| `has_cjk(s)` | 快速字节级 CJK 检测（E3-E9 UTF-8 lead bytes） |
| `collect_candidates(bufnr, opts)` | 收集缓冲区候选项（文本词 + LSP 标识符） |
| `get_cursor_context()` | 检测光标上下文（code/comment/string/unknown） |
| `get_lsp_symbol_info(name, bufnr)` | 查询 LSP SymbolKind |
| `run_cli_sync(query, candidates)` | 调用 CLI 进行拼音匹配 |
| `complete(findstart, base)` | omnifunc 入口 |
| `setup(opts)` | 初始化配置 + 注册 autocmd 失效缓存 |

**缓存机制**：
- 候选词缓存：`cache[bufnr]` 按 `changedtick` 失效
- LSP 标识符缓存：`lsp_cache[bufnr]` 按 `changedtick` 失效
- 失效事件：`TextChanged` / `TextChangedI` / `BufWritePost`

**上下文检测（启发式，不依赖 treesitter）**：
1. 行首匹配 `commentstring` → `'comment'`
2. 未转义引号内 → `'string'`
3. 有 LSP client → `'code'`
4. 其他 → `'unknown'`

### blink.cmp Provider (`blink.lua`)

- `new(opts)` — 创建 provider 实例（blink.cmp v1.x 接口）
- `get_completions(ctx, callback)` — 补全入口：
  1. 提取光标前连续 ASCII 字母作为查询
  2. 检测上下文 → 选择候选词模式（code/text/all）
  3. 调用 `run_cli_sync` 进行拼音匹配
  4. 查询 LSP SymbolKind → 设置补全项属性
  5. 可调用符号（Function/Method/Constructor）自动追加 `()`
  6. 返回 `is_incomplete_forward = true` 保持持续查询

---

## 构建与运行

### 编译 CLI

```bash
xmake build cli
```

产物：`lua/cmp_pinyin/bin/cli`（xmake 自动拷贝 `libib_pinyin_c.so` 到同目录）

### 测试

```bash
python test.py                          # CLI 匹配逻辑测试
nvim test/example.py                    # 打开后 :luafile test/test_plugin.lua
```

### Neovim 配置 (blink.cmp)

```lua
require('blink.cmp').setup({
    sources = {
        providers = {
            pinyin = {
                name = 'pinyin',
                module = 'cmp_pinyin.blink',
            },
        },
        completion = {
            enabled_providers = { 'lsp', 'path', 'buffer', 'pinyin' },
        },
    },
})
```

---

## 关键技术决策

| 决策 | 选择 | 考量 |
|------|------|------|
| 匹配引擎 | C++ CLI 同步调用 | 匹配 <10ms，同步调用简化架构 |
| 拼音库 | ib_pinyin (Chaoses-Ib) | 支持多种拼音方案，diplomat FFI |
| 代码标识符提取 | LSP documentSymbol | 不依赖 treesitter，通用性强 |
| 上下文检测 | 启发式（commentstring + 引号计数） | 比 treesitter 轻量，兼容性好 |
| 中文命名 | 全中文标识符 | 遵循 CODING_STANDARD.md |
| 补全框架 | blink.cmp (主) | 异步 provider 接口，兼容 omnifunc 回退 |
| 构建系统 | xmake | 跨平台 C++ 构建，依赖管理 |

---

## 相关资源

- **ib_pinyin 匹配库**：[Chaoses-Ib/ib-matcher](https://github.com/Chaoses-Ib/ib-matcher.git)
- **blink.cmp 补全框架**：[saghen/blink.cmp](https://github.com/saghen/blink.cmp)
- **diplomat FFI**：[diplomat](https://github.com/rust-diplomat/diplomat)
- **中文代码命名规范**：`CODING_STANDARD.md`
