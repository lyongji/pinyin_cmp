local M = {}

-- Auto-detect CLI path relative to this module -------------------------
local function default_cli_path()
    local source = debug.getinfo(1, 'S').source:gsub('^@', '')
    -- source: .../lua/cmp_pinyin/init.lua
    local ext = vim.fn.has('win32') == 1 and '.exe' or ''
    return vim.fn.fnamemodify(source, ':h') .. '/bin/cli' .. ext
end

-- Default configuration ------------------------------------------------
M.config = {
    cli_path = default_cli_path(),          -- auto-detected; override in setup() if needed
    min_query_len = 2,                  -- minimum pinyin query length
    notation = { '简拼', '全拼' },        -- pinyin notation(s): 简拼 全拼 带声调全拼 unicode abc双拼 加加双拼 微软双拼 华宇双拼 小鹤双拼 自然码双拼
    max_candidates = 300,               -- max buffer candidates sent to CLI
}

-- CJK detection ---------------------------------------------------------
-- Fast byte-level check: matches UTF-8 lead bytes for common CJK ranges
-- E3-E9 covers U+3000..U+9FFF (CJK Unified + Extension A + adjacent blocks)
local CJK_BYTE_PATTERN = '[\227-\233][\128-\191]'

function M.has_cjk(s)
    return s:find(CJK_BYTE_PATTERN) ~= nil
end

-- Candidate cache (per-buffer) ------------------------------------------
local cache = {}  -- [bufnr] = { tick = changedtick, words = {...} }

-- LSP symbols cache (code identifiers) -----------------------------------
local lsp_cache = {}  -- [bufnr] = { tick = changedtick, ids = {...} }

local function lsp_cache_invalidate(bufnr)
    if bufnr then
        lsp_cache[bufnr] = nil
    else
        lsp_cache = {}
    end
end

function M.invalidate_cache(bufnr)
    if bufnr then
        cache[bufnr] = nil
    else
        cache = {}
    end
    lsp_cache_invalidate(bufnr)
end

local function get_word_pattern()
    -- Match runs of ASCII word chars + non-ASCII bytes
    return '[%w_\128-\255]+'
end

--- Walk LSP DocumentSymbol[] / SymbolInformation[] and extract CJK names + kinds.
local function extract_lsp_symbols(symbols, seen, kinds)
    local ids = {}
    for _, sym in ipairs(symbols) do
        local name = sym.name
        if name and #name >= 2 and M.has_cjk(name) and not seen[name] then
            seen[name] = true
            ids[#ids + 1] = name
            kinds[name] = sym.kind
        end
        if sym.children then
            local child_ids = extract_lsp_symbols(sym.children, seen, kinds)
            for _, cid in ipairs(child_ids) do
                ids[#ids + 1] = cid
            end
        end
    end
    return ids
end

--- Collect Chinese identifiers via LSP document symbols.
--- Returns a list of unique CJK identifier names found in the buffer.
--- Side effect: caches LSP SymbolKind per name for get_lsp_symbol_kind().
local function collect_lsp_identifiers(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)

    if lsp_cache[bufnr] and lsp_cache[bufnr].tick == tick then
        return lsp_cache[bufnr].ids
    end

    local clients = (vim.lsp.get_clients or vim.lsp.get_active_clients)({ bufnr = bufnr })
    if not clients or #clients == 0 then
        return {}
    end

    local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
    local ok, results = pcall(vim.lsp.buf_request_sync, bufnr,
        'textDocument/documentSymbol', params, 300)
    if not ok then
        vim.notify('[cmp_pinyin] LSP documentSymbol error: ' .. tostring(results),
                   vim.log.levels.WARN)
        return {}
    end
    if not results then
        return {}
    end

    local ids = {}
    local seen = {}
    local kinds = {}
    for _, resp in pairs(results) do
        if resp.error then
            vim.notify('[cmp_pinyin] LSP ' .. (resp.error.message or 'unknown error'),
                       vim.log.levels.WARN)
        elseif resp.result and type(resp.result) == 'table' then
            local ok2, sym_ids = pcall(extract_lsp_symbols, resp.result, seen, kinds)
            if ok2 then
                for _, id in ipairs(sym_ids) do
                    ids[#ids + 1] = id
                end
            end
        end
    end

    lsp_cache[bufnr] = { tick = tick, ids = ids, kinds = kinds }
    return ids
end

--- Look up LSP SymbolKind for a given identifier name.
--- Returns SymbolKind number or nil.
--- Common kinds: 5=Class, 6=Method, 9=Constructor, 12=Function, 13=Variable, 14=Constant, 22=EnumMember, 23=Struct.
function M.get_lsp_symbol_info(name, bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local entry = lsp_cache[bufnr]
    if entry and entry.kinds then
        return { kind = entry.kinds[name] }
    end
    return nil
end

--- Detect cursor context without treesitter (LSP candidate-set based fallback).
--- Uses buffer commentstring and simple quote counting.
local function get_cursor_context_heuristic()
    local bufnr = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor[1] - 1
    local col = cursor[2]

    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
    local before = line:sub(1, col)
    local stripped = vim.trim(line)

    -- Check line-comment prefix from buffer commentstring
    local cs = vim.bo[bufnr].commentstring or ''
    local prefix = vim.trim(cs:gsub('%%s', ''))
    if #prefix > 0 and vim.startswith(stripped, prefix) then
        return 'comment'
    end

    -- Common block-comment / doc-comment patterns
    if stripped:match('^%*%s') or stripped:match('^//') or stripped:match('^/#') then
        return 'comment'
    end

    -- Simple string detection: count unescaped quotes before cursor
    local in_single, in_double, in_backtick = false, false, false
    local i = 1
    while i <= #before do
        local ch = before:sub(i, i)
        local prev = i > 1 and before:sub(i - 1, i - 1) or ''
        if ch == '\\' then
            i = i + 1
        elseif ch == "'" and not in_double and not in_backtick then
            in_single = not in_single
        elseif ch == '"' and not in_single and not in_backtick then
            in_double = not in_double
        elseif ch == '`' and not in_single and not in_double then
            in_backtick = not in_backtick
        end
        i = i + 1
    end
    if in_single or in_double or in_backtick then
        return 'string'
    end

    -- No LSP client → can't distinguish code from text reliably
    local clients = (vim.lsp.get_clients or vim.lsp.get_active_clients)({ bufnr = bufnr })
    if not clients or #clients == 0 then
        return 'unknown'
    end

    return 'code'
end

--- Detect cursor context.
--- Uses LSP-based heuristic (commentstring + quote counting) instead of treesitter.
function M.get_cursor_context()
    return get_cursor_context_heuristic()
end

function M.collect_candidates(bufnr, opts)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    opts = opts or {}
    local mode = opts.mode or 'all'
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    local parts = { 'words', mode }
    if opts.exclude_code then parts[#parts + 1] = 'nocode' end
    local cache_key = table.concat(parts, '_')

    if cache[bufnr] and cache[bufnr].tick == tick and cache[bufnr][cache_key] then
        return cache[bufnr][cache_key]
    end

    if not cache[bufnr] then cache[bufnr] = {} end
    cache[bufnr].tick = tick

    local words = {}
    local seen = {}
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    -- Collect text words (mode 'text' or 'all')
    if mode == 'text' or mode == 'all' then
        local pat = get_word_pattern()
        for _, line in ipairs(lines) do
            for word in line:gmatch(pat) do
                if #word >= 2 and not seen[word] and M.has_cjk(word) then
                    seen[word] = true
                    words[#words + 1] = word
                end
            end
        end

        -- When exclude_code is true, filter out LSP symbols (code identifiers)
        if opts.exclude_code then
            local lsp_ids = collect_lsp_identifiers(bufnr)
            local lsp_set = {}
            for _, id in ipairs(lsp_ids) do
                lsp_set[id] = true
            end
            local filtered = {}
            for _, word in ipairs(words) do
                if not lsp_set[word] then
                    filtered[#filtered + 1] = word
                end
            end
            words = filtered
        end
    end

    -- Collect code identifiers via LSP (mode 'code' or 'all')
    if mode == 'code' or mode == 'all' then
        local code_ids = collect_lsp_identifiers(bufnr)
        if #code_ids == 0 and mode == 'code' then
            -- LSP returned nothing; fall back to all text words
            local pat = get_word_pattern()
            for _, line in ipairs(lines) do
                for word in line:gmatch(pat) do
                    if #word >= 2 and not seen[word] and M.has_cjk(word) then
                        seen[word] = true
                        words[#words + 1] = word
                    end
                end
            end
        end
        for _, word in ipairs(code_ids) do
            if not seen[word] then
                seen[word] = true
                words[#words + 1] = word
            end
        end
    end

    -- Cap for performance: keep longest words first (more meaningful)
    if #words > M.config.max_candidates then
        table.sort(words, function(a, b) return #a > #b end)
        local capped = {}
        for i = 1, M.config.max_candidates do
            capped[i] = words[i]
        end
        words = capped
    end

    cache[bufnr][cache_key] = words
    return words
end

-- CLI helpers -----------------------------------------------------------

-- Map Chinese notation names to hex bitmask values for CLI compatibility.
-- Using hex values avoids encoding issues when passing Chinese arguments
-- via the Windows ANSI codepage (e.g. GBK misinterpretation of UTF-8).
local notation_name_to_hex = {
    ['简拼'] = '0x1',
    ['全拼'] = '0x2',
    ['带声调全拼'] = '0x4',
    ['unicode'] = '0x8',
    ['abc双拼'] = '0x10',
    ['加加双拼'] = '0x20',
    ['微软双拼'] = '0x40',
    ['华宇双拼'] = '0x80',
    ['小鹤双拼'] = '0x100',
    ['自然码双拼'] = '0x200',
}

local function build_cli_cmd(query)
    local cmd = { M.config.cli_path }
    for _, name in ipairs(M.config.notation) do
        cmd[#cmd + 1] = '--notation'
        -- Use hex value when available; fall back to raw name for
        -- unrecognised strings that the CLI itself may understand.
        cmd[#cmd + 1] = notation_name_to_hex[name] or name
    end
    cmd[#cmd + 1] = query
    return cmd
end

local function parse_cli_output(lines)
    local results = {}
    for _, line in ipairs(lines) do
        if line ~= '' then
            local word, score_str = line:match('^(.-)\t(.+)$')
            if word then
                results[#results + 1] = {
                    word = word,
                    score = tonumber(score_str) or 0,
                }
            end
        end
    end
    -- Lower score = better match (earlier start, shorter match, shorter word)
    table.sort(results, function(a, b) return a.score < b.score end)
    return results
end

-- Synchronous CLI (for omnifunc, which is synchronous)
function M.run_cli_sync(query, candidates)
    if #query < M.config.min_query_len or #candidates == 0 then
        return {}
    end
    local cmd = build_cli_cmd(query)
    local input = table.concat(candidates, '\n')
    local output = vim.fn.system(cmd, input)

    if vim.v.shell_error ~= 0 then
        vim.notify('[cmp_pinyin] CLI error (exit ' .. vim.v.shell_error .. ')',
                   vim.log.levels.WARN)
        return {}
    end
    return parse_cli_output(vim.split(output, '\n'))
end

-- Omnifunc --------------------------------------------------------------
function M.complete(findstart, base)
    if findstart == 1 then
        local line = vim.api.nvim_get_current_line()
        local col = vim.fn.col('.') - 1
        local start = col
        while start > 0 and line:sub(start, start):match('[%w_]') do
            start = start - 1
        end
        return start
    end

    if #base < M.config.min_query_len then
        return {}
    end

    local candidates = M.collect_candidates()
    if #candidates == 0 then
        return {}
    end

    local matches = M.run_cli_sync(base, candidates)
    local items = {}
    for _, m in ipairs(matches) do
        items[#items + 1] = {
            word = m.word,
            abbr = m.word,
            menu = '[拼音]',
            dup = 1,
        }
    end
    return items
end

-- Setup -----------------------------------------------------------------
function M.setup(opts)
    M.config = vim.tbl_deep_extend('force', M.config, opts or {})

    if not M.config.cli_path or vim.fn.executable(M.config.cli_path) == 0 then
        vim.notify(
            '[cmp_pinyin] cli_path not found or not executable: '
                .. tostring(M.config.cli_path),
            vim.log.levels.WARN
        )
    end

    if type(M.config.notation) == 'string' then
        M.config.notation = { M.config.notation }
    end

    -- Invalidate caches when any buffer changes
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufWritePost' }, {
        group = vim.api.nvim_create_augroup('CmpPinyinCache', { clear = true }),
        callback = function(args)
            cache[args.buf] = nil
            lsp_cache[args.buf] = nil
        end,
    })
end

return M