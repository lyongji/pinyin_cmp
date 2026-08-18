local cmp_pinyin = require('cmp_pinyin')

-- Debug flag: set to false to silence status messages
local function dbg(msg) end  -- set to vim.notify(...) to debug

--- 提取光标前的拼音查询词（仅 ASCII 字母）。
--- 使用 blink 传入的 ctx（含 line/cursor，多窗口场景更稳）。
local function get_query(ctx)
    local line = ctx and ctx.line or vim.api.nvim_get_current_line()
    -- cursor: {行(1基), 列(0基)}；无 ctx 时用 col('.')-1（0基列）
    local end_pos = (ctx and ctx.cursor and ctx.cursor[2]) or (vim.fn.col('.') - 1)

    local start = end_pos
    while start > 0 and line:sub(start, start):match('[%a]') do
        start = start - 1
    end
    if start < end_pos then
        return line:sub(start + 1, end_pos)
    end
    return ''
end

-- Resolve LSP CompletionItemKind, with fallback
local kind_text = 1
local kind_keyword = 14  -- fallback for identifiers
local ok, types = pcall(require, 'blink.cmp.types')
if ok and types.CompletionItemKind then
    kind_text = types.CompletionItemKind.Text
    kind_keyword = types.CompletionItemKind.Keyword or 14
end

-- Map LSP SymbolKind → blink CompletionItemKind
-- LSP: 5=Class 6=Method 9=Constructor 12=Function 13=Variable 14=Constant 22=EnumMember 23=Struct
local lsp_kind_to_cmp = {
    [5] = types and types.CompletionItemKind and types.CompletionItemKind.Class or 7,
    [6] = types and types.CompletionItemKind and types.CompletionItemKind.Method or 2,
    [9] = types and types.CompletionItemKind and types.CompletionItemKind.Constructor or 4,
    [12] = types and types.CompletionItemKind and types.CompletionItemKind.Function or 3,
    [13] = types and types.CompletionItemKind and types.CompletionItemKind.Variable or 6,
    [14] = types and types.CompletionItemKind and types.CompletionItemKind.Constant or 21,
    [22] = types and types.CompletionItemKind and types.CompletionItemKind.EnumMember or 20,
    [23] = types and types.CompletionItemKind and types.CompletionItemKind.Struct or 22,
}

-- LSP SymbolKind values that represent callable symbols
local callable_kinds = { [6] = true, [9] = true, [12] = true }  -- Method, Constructor, Function

local M = {}

--- blink.cmp calls new(opts) to create a provider instance (v1.x).
--- The instance inherits get_completions from M.
function M.new(opts)
    return setmetatable(opts or {}, { __index = M })
end

--- blink.cmp completion provider entry point.
function M:get_completions(ctx, callback)
    local query = get_query(ctx)

    if #query < (cmp_pinyin.config.min_query_len or 2) then
        return callback({
            items = {},
            is_incomplete_forward = true,   -- keep source alive so blink re-queries on further typing
            is_incomplete_backward = true,
        })
    end

    local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()

    -- Detect cursor context and choose candidate source
    -- （候选收集是内存/正则操作，同步很快；CLI 匹配走异步回调）
    local context = cmp_pinyin.get_cursor_context(ctx)
    local candidates
    if context == 'code' then
        candidates = cmp_pinyin.collect_candidates(bufnr, { mode = 'code' })
    elseif context == 'comment' or context == 'string' then
        candidates = cmp_pinyin.collect_candidates(bufnr, { mode = 'text' })
    else
        -- No LSP / unknown context; collect all CJK words
        candidates = cmp_pinyin.collect_candidates(bufnr, { mode = 'all' })
    end

    if #candidates == 0 then
        dbg('query="' .. query .. '" → no CJK candidates in buffer ' .. bufnr)
        return callback({
            items = {},
            is_incomplete_forward = true,
            is_incomplete_backward = true,
        })
    end

    -- 同步 CLI：每次按键同步完成查询+更新，避免异步空窗被 blink 的 fuzzy
    -- 过滤闪掉中文候选（CLI 设计目标 <10ms，不阻塞主线程）
    local matches = cmp_pinyin.run_cli_sync(query, candidates)
    if #matches == 0 then
        dbg('query="' .. query .. '" → no pinyin match in ' .. #candidates .. ' candidates')
        return callback({
            items = {},
            is_incomplete_forward = true,
            is_incomplete_backward = true,
        })
    end

    local items = {}
    for i, m in ipairs(matches) do
        local info = cmp_pinyin.get_lsp_symbol_info(m.word, bufnr)
        local lsp_kind = info and info.kind
        local is_callable = lsp_kind and callable_kinds[lsp_kind]

        -- 可调用符号用 LSP snippet：参数区作 ${0:...} 占位，接受后光标落在括号内
        -- （blink 内置引擎展开，配合 <Tab> 跳出参数继续输入）
        local insertText = m.word
        local insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText
        if is_callable then
            insertTextFormat = vim.lsp.protocol.InsertTextFormat.Snippet
            local signature = info and info.signature
            local open = signature and signature:find('(', 1, true) -- 完整签名含 '函数名(' 前缀
            if open then
                local args = signature:sub(open + 1)
                if args:sub(-1) == ')' then args = args:sub(1, -2) end
                if #args > 0 then
                    insertText = m.word .. '(${0:' .. args .. '})'
                else
                    insertText = m.word .. '(${0})'
                end
            else
                insertText = m.word .. '(${0})'
            end
        end

        items[i] = {
            label = m.word,
            insertText = insertText,
            insertTextFormat = insertTextFormat,
            filterText = query .. ' ' .. m.word,
            -- score 小 = 更相关；补零使字典序 == 数值序，
            -- 覆盖 blink 默认按 sort_text 排序时丢失 CLI 相关性排名的问题
            sortText = string.format('%010d', m.score),
            kind = lsp_kind and lsp_kind_to_cmp[lsp_kind]
                or (context == 'code' and kind_keyword or kind_text),
        }
    end

    dbg('query="' .. query .. '" → ' .. #items .. ' results (context=' .. context .. ')')
    callback({
        items = items,
        is_incomplete_forward = true,
        is_incomplete_backward = true,
    })
end

return M
