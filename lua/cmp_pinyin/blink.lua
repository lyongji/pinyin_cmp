local cmp_pinyin = require('cmp_pinyin')

-- Debug flag: set to false to silence status messages
local function dbg(msg) end  -- set to vim.notify(...) to debug

--- Extract the pinyin query before the cursor (ASCII letters only).
local function get_query()
    local line = vim.api.nvim_get_current_line()
    local col = vim.fn.col('.')            -- 1-indexed cursor column

    local end_pos = col - 1
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
local ok, types = pcall(require, 'blink.cmp.types')
if ok and types.CompletionItemKind then
    kind_text = types.CompletionItemKind.Text
end

local M = {}

--- blink.cmp calls new(opts) to create a provider instance (v1.x).
--- The instance inherits get_completions from M.
function M.new(opts)
    return setmetatable(opts or {}, { __index = M })
end

--- blink.cmp completion provider entry point.
function M:get_completions(ctx, callback)
    local query = get_query()

    if #query < (cmp_pinyin.config.min_query_len or 2) then
        return callback({
            items = {},
            is_incomplete_forward = true,   -- keep source alive so blink re-queries on further typing
            is_incomplete_backward = true,
        })
    end

    local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()
    local candidates = cmp_pinyin.collect_candidates(bufnr)

    if #candidates == 0 then
        dbg('query="' .. query .. '" → no CJK candidates in buffer ' .. bufnr)
        return callback({
            items = {},
            is_incomplete_forward = true,
            is_incomplete_backward = true,
        })
    end

    -- Use sync CLI for reliability; the C++ CLI is fast (<10ms for typical buffers)
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
        items[i] = {
            label = m.word,
            insertText = m.word,
            -- blink.cmp fuzzy-matches filterText against typed text.
            -- User types ASCII pinyin but word is Chinese — include
            -- query in filterText so the fuzzy matcher finds a match.
            filterText = query .. ' ' .. m.word,
            sortText = m.word,
            kind = kind_text,
        }
    end

    dbg('query="' .. query .. '" → ' .. #items .. ' results')
    callback({
        items = items,
        is_incomplete_forward = true,
        is_incomplete_backward = true,
    })
end

return M
