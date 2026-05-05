# cmp_pinyin — 拼音补全插件

在 Neovim 中输入拼音时自动补全中文（CJK）词汇，支持文本和代码两种场景。

## 功能

- **文本补全**：在注释、字符串等文本上下文中，输入拼音补全中文词汇
- **代码标识符补全**：在代码上下文中，输入拼音补全中文变量名、函数名等标识符（通过 LSP document symbols 提取）
- **上下文自动切换**：根据光标位置（代码 / 注释 / 字符串）自动切换候选词来源（基于 commentstring + 引号计数启发式）
- 支持 [blink.cmp](https://github.com/saghen/blink.cmp)（nvim-cmp 支持计划中）

## 依赖项

| 依赖 | 说明 |
|------|------|
| Neovim ≥ 0.9 | 运行环境 |
| blink.cmp | 补全框架 |
| LSP（可选） | 通过 document symbols 提取代码标识符（函数名、变量名、类名等），未安装时回退为全文本匹配 |
| `libib_pinyin_c.so` / `.dll` | ib_pinyin C 库，运行时动态链接 |
| `cli`（C++ 可执行文件） | 拼音匹配 CLI，由本项目编译 |
| `xmake` | 仅编译时需要 |

## 编译 CLI

```bash
xmake build cli
```

编译产物：`lua/cmp_pinyin/bin/cli`（同目录下须有 `libib_pinyin_c.so`，xmake 会自动拷贝）。

## 安装

### lazy.nvim

```lua
{
    'your/cmp_pinyin',   -- 替换为你的路径
    build = 'xmake build cli',
    -- cli_path 自动检测，无需手动配置
}
```

在 blink.cmp 配置中添加 `pinyin` 源：

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

拼音补全与 LSP 等源并行工作，补全菜单中同时显示 LSP 建议和拼音匹配项。

### Neovim 0.12 原生包管理

```lua
vim.opt.rtp:prepend("E:/code/pinyin_cmp")
vim.schedule(function()
  local ok, mod = pcall(require, 'cmp_pinyin')
  if ok then
    mod.setup({ notation = { '简拼', '全拼' } })
  end
end)
```

## 可配置项

```lua
require('cmp_pinyin').setup({

    -- CLI 可执行文件路径（自动检测，通常无需设置）
    cli_path = nil,              -- 默认自动定位到 lua/cmp_pinyin/bin/cli

    -- 最小查询长度：拼音字母数少于此值时不触发补全
    min_query_len = 2,           -- 默认 2

    -- 拼音标注方案（可多选，按顺序匹配）
    notation = { '简拼', '全拼' },  -- 默认值

    -- 缓冲区最多收集的 CJK 候选项数（超长词优先）
    max_candidates = 300,        -- 默认 300
})
```

### `collect_candidates()` 选项

`collect_candidates(bufnr, opts)` 支持以下选项，供高级集成使用：

| 选项 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `mode` | `'text'` / `'code'` / `'all'` | `'all'` | 候选词来源：文本词（正则） / LSP 代码标识符 / 两者合并 |
| `exclude_code` | `boolean` | `false` | 在 `mode='text'` 时生效：用 LSP symbols 作排除集，过滤掉代码标识符 |

`get_cursor_context()` 返回光标上下文：`'code'` / `'comment'` / `'string'` / `'unknown'`（无 LSP 时返回 `'unknown'`）。

### 各模式数据来源

| 模式 | 无 LSP | 有 LSP |
|------|--------|--------|
| `text` | 正则 `[%w_\128-\255]+` 匹配 | 正则匹配，可选 `exclude_code` 过滤 LSP 标识符 |
| `code` | `collect_lsp_identifiers()` 返回空 → 回退为 `text` | `textDocument/documentSymbol` 同步请求 → 提取中文符号名 |
| `all` | 正则匹配 | 正则 + LSP symbols 合并去重 |

### `notation` 可选值

| 值 | 方案 |
|----|------|
| `简拼` | 首字母（yh → 用户） |
| `全拼` | 全拼（yonghu → 用户） |
| `带声调全拼` | yong4hu4 → 用户 |
| `unicode` | Unicode 编码 |
| `abc双拼` | ABC 双拼 |
| `加加双拼` | 加加双拼 |
| `微软双拼` | 微软双拼 |
| `华宇双拼` | 华宇双拼 |
| `小鹤双拼` | 小鹤双拼 |
| `自然码双拼` | 自然码双拼 |

多选示例：

```lua
notation = { '简拼', '全拼', '小鹤双拼' },
```

CLI 按数组顺序尝试每种方案，命中任意一种即返回结果。

## LSP 集成

插件通过 LSP `textDocument/documentSymbol` 同步请求提取代码中的中文标识符，不依赖 treesitter。

### 补全行为

| LSP SymbolKind | insertText | blink 图标 | 签名提示 |
|----------------|-----------|-----------|---------|
| Function / Method / Constructor | `标识符名()` | 函数/方法/构造函数图标 | blink 的 `signatureHelp` 在 `()` 内自动触发 |
| Variable / Class / Struct / 其他 | `标识符名` | 对应图标 | — |

不再自行解析参数签名或构建 snippet，交给 blink 引擎处理。

### 工作流程

```
用户输入拼音
  → get_cursor_context() 启发式检测上下文
  → collect_candidates() 收集候选词
      ├─ mode='code' → LSP documentSymbol（中文函数/变量/类名等）
      ├─ mode='text' → 正则匹配文本词
      └─ mode='all'  → 合并两者
  → CLI 拼音匹配
  → get_lsp_symbol_info() 查询 SymbolKind
      ├─ 可调用 → append "()"
      └─ 其他   → 原样返回
  → blink.cmp 显示
```

### 上下文检测

基于启发式（不依赖 treesitter）：

1. 行首匹配 `commentstring` → `'comment'`
2. 未转义引号内 → `'string'`
3. 有 LSP client → `'code'`
4. 其他 → `'unknown'`

### LSP symbols 缓存

`documentSymbol` 结果按 `(bufnr, changedtick)` 缓存，`TextChanged` / `BufWritePost` 时失效。同步请求超时 300ms，失败时 `vim.notify` 告警并自动回退。

## 使用

### 文本补全

1. 打开含中文文本的缓冲区（`.py` `.lua` `.md` 等）
2. 在注释或字符串中输入拼音（ASCII 字母，如 `yh`、`yonghu`）
3. 等待自动补全弹出，选择中文候选项

### 代码标识符补全

1. 打开含中文标识符的代码文件（需 LSP server 已运行）
2. 在代码区域输入拼音
3. 插件通过 LSP document symbols 提取中文函数名、变量名、类名等作为候选词
4. 选择后，ASCII 拼音被替换为对应的中文标识符

> 拼音查询自动识别光标前连续的 ASCII 字母，无需前缀标记。上下文切换由 `get_cursor_context()` 自动完成（基于 commentstring + 引号计数启发式，有 LSP 时返回 'code'，无 LSP 时退化为全文本模式）。

## 测试

**CLI 测试（Python）**：

```bash
python test.py                        # 内置测试集，自动使用 lua/cmp_pinyin/bin/cli
python test.py lua/cmp_pinyin/bin/cli # 指定 CLI
```

**插件测试（Neovim）**：

```vim
:luafile test/test_plugin.lua
```

> 需要先编译 CLI（`xmake build cli`），确保 `lua/cmp_pinyin/bin/cli` 存在。

## 文件结构

```
lua/cmp_pinyin/
  init.lua    — 核心模块（setup / LSP 标识符收集 / 文本词收集 / CLI 调用 / 上下文启发式检测）
  blink.lua   — blink.cmp provider（get_completions / 上下文感知补全）
  bin/        — 编译产物（xmake build 生成，gitignore）
```
