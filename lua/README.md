# cmp_pinyin — 拼音补全插件

在 Neovim 中输入拼音时自动补全中文（CJK）词汇。

支持 [blink.cmp](https://github.com/saghen/blink.cmp) 和

## 依赖项

| 依赖 | 说明 |
|------|------|
| Neovim ≥ 0.9 | — |
| blink.cmp  | 补全框架 |
| `libib_pinyin_c.so` | ib_pinyin C 库，运行时动态链接 |
| `cli` (C++ 可执行文件) | 拼音匹配 CLI，由本项目编译 |
| `xmake` | 仅编译时需要 |

## 编译 CLI

```bash
xmake build cli
```

编译产物：`lua/cmp_pinyin/bin/cli`（与其同目录须有
`libib_pinyin_c.so`，xmake 会自动拷贝）。

## 安装

### lazy.nvim

**blink.cmp** 用户：

```lua
{
    'your/cmp_pinyin',   -- 替换为你的路径
    build = 'xmake build cli',
    -- cli_path 自动检测，无需手动配置
}
```

并在 blink.cmp 配置中添加 `pinyin` 源：

```lua
require('blink.cmp').setup({
    sources = {
        -- … 其他源 …
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

### Neovim 0.12 原生包管理

然后在 `init.lua` 中配置：

```lua
-- 本地插件：拼音补全
vim.opt.rtp:prepend("E:/code/pinyin_cmp")
vim.schedule(function()
  local ok, mod = pcall(require, 'cmp_pinyin')
  if ok then
    mod.setup({ notation = { '0x1', '0x2' } })
  end
end)


-- cli_path 自动检测，直接配置补全源即可
-- 如需手动覆盖：require('cmp_pinyin').setup({ cli_path = '...' })
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

    -- 异步 CLI 超时（毫秒）
    cli_timeout_ms = 3000,       -- 默认 3000
})
```

### `notation` 可选值

| 值 | 方案 |
|----|------|
| `简拼` | 首字母（yonghu → 用户） |
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

CLI 会按数组顺序尝试每种方案，命中任意一种即返回结果。

## 使用

1. 打开含中文文本的缓冲区（`.py` `.lua` `.md` 等）
2. 在插入模式下输入拼音（ASCII 字母，如 `yh`、`yonghu`）
3. 等待自动补全弹出，或手动触发补全（`<C-Space>`）
4. 选择中文候选项完成输入

> 拼音查询会自动识别光标前连续的 ASCII 字母，无需前缀标记。

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
  init.lua    — 核心模块（setup / collect_candidates / CLI 调用）
  blink.lua   — blink.cmp provider (get_completions)
  cmp.lua     — nvim-cmp source (complete / resolve / execute)
  bin/        — 编译产物（xmake build 生成，gitignore）
```
