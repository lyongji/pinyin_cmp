local cmp_pinyin = require('cmp_pinyin')

local source = {}

function source.new()
    return setmetatable({}, { __index = source })
end

--- Check whether the source is usable.
function source:is_available()
    return cmp_pinyin.config.cli_path ~= nil
        and vim.fn.executable(cmp_pinyin.config.cli_path) == 1
end

--- Keyword pattern that triggers completion.
--- Matches ASCII letter sequences — the pinyin the user is typing.
function source:get_keyword_pattern()
    return [[[a-zA-Z]\+]]
end

--- Return the number of characters that must be typed before completion triggers.
--- This lets us use min_query_len instead of cmp's generic keyword_length.
function source:get_keyword_length()
    return cmp_pinyin.config.min_query_len
end

--- Extract the pinyin query before cursor (1-indexed, self-contained).
local function get_query()
    local line = vim.api.nvim_get_current_line()
    local col = vim.fn.col('.')            -- 1-indexed
    local end_pos = col - 1
    local start = end_pos
    while start > 0 and line:sub(start, start):match('[%a]') do
        start = start - 1
    end
    if start < end_pos then
        return start + 1, line:sub(start + 1, end_pos)
    end
    return col, ''
end

--- Perform completion.
function source:complete(params, callback)
    local offset, query = get_query()
    offset = offset - 1                          -- 1-indexed → 0-indexed

    if #query < cmp_pinyin.config.min_query_len then
        return callback({ items = {}, isIncomplete = false })
    end

    local bufnr = params.context.bufnr or vim.api.nvim_get_current_buf()
    local candidates = cmp_pinyin.collect_candidates(bufnr)
    if #candidates == 0 then
        return callback({ items = {}, isIncomplete = false })
    end

    cmp_pinyin.run_cli_async(query, candidates, function(matches)
        if #matches == 0 then
            return callback({ items = {}, isIncomplete = false })
        end

        local items = {}
        for i, m in ipairs(matches) do
            items[i] = {
                label = m.word,
                filterText = m.word,
                insertText = m.word,
                -- Higher = higher priority.  nvim-cmp sorts descending.
                score = #matches - i + 1,
                dup = 1,
            }
        end

        callback({
            items = items,
            isIncomplete = true,   -- pinyin can refine further
        })
    end)
end

--- Resolve additional info for the completion item (called on selection).
function source:resolve(item, callback)
    item.documentation = {
        kind = 'markdown',
        value = table.concat({
            '# 拼音补全',
            '',
            '**候选词:** `' .. item.label .. '`',
            '',
            '---',
            '*由 ib_pinyin 引擎提供匹配*',
        }, '\n'),
    }
    callback(item)
end

--- Execute on confirm (default behavior is fine — just pass through).
function source:execute(item, callback)
    callback(item)
end

return source
