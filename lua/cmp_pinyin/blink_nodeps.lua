-- cmp_pinyin 无依赖入口：不需要 blink.cmp 也能用拼音补全。
--
-- 回退优先级（自动检测）：
--   1. 已安装 blink.cmp        → 注册 pinyin provider，走 blink 全功能路径
--   2. 未安装 blink，有 LSP     → omnifunc 路径，候选词来自 LSP documentSymbol
--   3. 两者都没有               → omnifunc 路径，纯文本候选词
--
-- 用法：
--   有 blink.cmp：blink 配置里 module 填 'cmp_pinyin.blink_nodeps'（行为与 blink.lua 完全一致），
--                 或直接 require('cmp_pinyin.blink_nodeps').setup() 自动注册。
--   无 blink.cmp：require('cmp_pinyin.blink_nodeps').setup() 后按 <C-x><C-o> 触发补全。
local blink = require('cmp_pinyin.blink')
local cmp_pinyin = require('cmp_pinyin')

local M = {}

-- blink.cmp provider 接口：直接复用 blink.lua（两者行为一致，可互换）
M.new = blink.new
M.get_completions = blink.get_completions

-- 用 blink.cmp 官方 API add_source_provider 注册 pinyin 源。
-- 该 API 在 blink setup 前后均可调用（只改 config 表，下次触发补全即生效），
-- 且不依赖重复调用 setup()（blink 的 setup 是幂等的，二次调用无效）。
local function 注册blink源()
    local config = require('blink.cmp.config')
    -- 用户已自行定义 pinyin 源时，尊重用户配置，不覆盖
    if config.sources.providers['pinyin'] then return end

    require('blink.cmp').add_source_provider('pinyin', {
        name = 'pinyin',
        module = 'cmp_pinyin.blink_nodeps',
    })

    -- 追加到默认启用列表；用户把 default 设成函数时无法安全追加，仅注册（此时需自行启用）
    local defaults = config.sources.default
    if type(defaults) == 'table' then
        local 已有 = false
        for _, name in ipairs(defaults) do
            if name == 'pinyin' then 已有 = true break end
        end
        if not 已有 then
            defaults[#defaults + 1] = 'pinyin'
            config.sources.default = defaults
        end
    end
end

--- 无 blink 时的 omnifunc 回退。
--- 内部已按 LSP 可用性自动切换候选来源：有 LSP 用 documentSymbol 标识符，否则纯文本词。
local function 启用omnifunc回退()
    vim.bo.omnifunc = "v:lua.require'cmp_pinyin'.complete"
end

--- 统一入口：优先 blink，其次 LSP（omnifunc 内部自动），最后纯文本。
--- @param opts? table 与 cmp_pinyin.setup() 相同的配置项（cli_path / min_query_len / notation 等）
function M.setup(opts)
    cmp_pinyin.setup(opts)

    local ok = pcall(require, 'blink.cmp')
    if ok then
        注册blink源()
        vim.notify('[cmp_pinyin] 检测到 blink.cmp，已注册 pinyin 源', vim.log.levels.INFO)
    else
        启用omnifunc回退()
        vim.notify('[cmp_pinyin] 未检测到 blink.cmp，已启用 omnifunc 回退（<C-x><C-o> 触发）',
                   vim.log.levels.INFO)
    end
end

return M
