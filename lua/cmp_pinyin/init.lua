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
local cache = {}  -- [bufnr] = { tick, words_all / words_code / words_text_nocode }

-- LSP symbols cache (code identifiers) -----------------------------------
-- [bufnr] = { tick, ts = 请求时间戳(ns), ids, kinds, sigs }
local lsp_cache = {}
local lsp_notified = {}  -- [bufnr] = true，LSP 错误已提示过（避免每次按键刷屏）

-- LSP documentSymbol 节流：打字期间 tick 频繁变化，
-- 但符号集几乎不变，短时间内复用旧缓存避免同步阻塞
local LSP_THROTTLE_MS = 500

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
    -- 宽模式：ASCII 词 + 非 ASCII 连续段（含 CJK、假名等）
    return '[%w_\128-\255]+'
end

-- 全角标点字节段：U+3000-303F（E3 80 80-BF）与 U+FF00-FFEF（EF BC-BF 80-BF）
-- 先替换为空格断词，避免 “用户。” “系统、管理” 之类脏候选
-- （Lua pattern 无 “|” 交替，两个字节段用两次 gsub 分别替换）

--- 按标点断词后逐词回调
--- @param line string 单行文本
--- @param handle fun(word: string) 每个候选词回调（未过滤长度/CJK）
local function 提取行词(line, handle)
    line = line:gsub('\227\128[\128-\191]', ' ')      -- U+3000-303F 全角符号
    line = line:gsub('\239[\188-\191][\128-\191]', ' ')  -- U+FF00-FFEF 全角标点
    for word in line:gmatch(get_word_pattern()) do
        handle(word)
    end
end

--- Walk LSP DocumentSymbol[] / SymbolInformation[] and extract CJK names + kinds.
local function extract_lsp_symbols(symbols, seen, kinds, sigs)
    local ids = {}
    for _, sym in ipairs(symbols) do
        local name = sym.name
        if name and #name >= 2 and M.has_cjk(name) and not seen[name] then
            seen[name] = true
            ids[#ids + 1] = name
            kinds[name] = sym.kind
            -- 记录符号位置：用于从 buffer 提取函数签名（可调用符号带参数）
            local sel = sym.selectionRange or {} -- selectionRange 一般存在；DocumentSymbol 必带
            if sel.start then
                sigs[name] = sel.start   -- { line（0基）, character }
            elseif sym.range and sym.range.start then
                sigs[name] = sym.range.start
            end
        end
        if sym.children then
            local child_ids = extract_lsp_symbols(sym.children, seen, kinds, sigs)
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

    local 通知一次 = function(消息)
        if not lsp_notified[bufnr] then
            lsp_notified[bufnr] = true
            vim.notify(消息, vim.log.levels.WARN)
        end
    end

    if lsp_cache[bufnr] then
        local entry = lsp_cache[bufnr]
        if entry.tick == tick then
            return entry.ids
        end
        -- 节流期内复用旧缓存：打字时符号集几乎不变，避免每次按键同步请求
        local now = vim.uv.hrtime()
        if now - entry.ts < LSP_THROTTLE_MS * 1e6 then
            return entry.ids
        end
    end

    local clients = (vim.lsp.get_clients or vim.lsp.get_active_clients)({ bufnr = bufnr })
    if not clients or #clients == 0 then
        return {}
    end

    local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
    local ok, results = pcall(vim.lsp.buf_request_sync, bufnr,
        'textDocument/documentSymbol', params, 300)
    if not ok then
        通知一次('[cmp_pinyin] LSP documentSymbol error: ' .. tostring(results))
        return {}
    end
    if not results then
        return {}
    end

    local ids = {}
    local seen = {}
    local kinds = {}
    local sigs = {}
    for _, resp in pairs(results) do
        if resp.error then
            通知一次('[cmp_pinyin] LSP ' .. (resp.error.message or 'unknown error'))
        elseif resp.result and type(resp.result) == 'table' then
            local ok2, sym_ids = pcall(extract_lsp_symbols, resp.result, seen, kinds, sigs)
            if ok2 then
                for _, id in ipairs(sym_ids) do
                    ids[#ids + 1] = id
                end
            end
        end
    end

    lsp_cache[bufnr] = { tick = tick, ts = vim.uv.hrtime(), ids = ids, kinds = kinds, sigs = sigs }
    return ids
end

--- Look up LSP SymbolKind + signature for a given identifier name.
--- Returns { kind = SymbolKind, signature = '函数名(参数...)' } or nil.
--- signature 从定义行提取（如 `断言匹配(string_view 模式, ...)` 的括号段），
--- 供 blink 条目插入完整调用而不是裸的函数名()。
--- Common kinds: 5=Class, 6=Method, 9=Constructor, 12=Function, 13=Variable, 14=Constant, 22=EnumMember, 23=Struct.
function M.get_lsp_symbol_info(name, bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local entry = lsp_cache[bufnr]
    if not entry or not entry.kinds then
        return nil
    end
    local info = { kind = entry.kinds[name] }
    local pos = entry.sigs and entry.sigs[name]
    if pos and vim.api.nvim_buf_is_valid(bufnr) then
        local line = vim.api.nvim_buf_get_lines(bufnr, pos.line, pos.line + 1, false)[1]
        if line then
            -- 从名字开始截取到行尾，再取到第一个 '{' 或 ';' 之前，作为签名文本
            local rest = line:sub(pos.character + 1)
            rest = rest:gsub('[{;].*$', ''):gsub('%s+$', '')
            if #rest > #name then
                info.signature = rest
            end
        end
    end
    return info
end

--- Detect cursor context without treesitter (LSP candidate-set based fallback).
--- Uses buffer commentstring and simple quote counting.
-- 文本型文件类型：正文不应走代码分支（即使挂了 LSP 如 ltex）
local 文本型文件类型 = {
    markdown = true, text = true, tex = true, rst = true,
    pandoc = true, org = true, mail = true, gitcommit = true,
}
local function get_cursor_context_heuristic(bufnr, row, col)
    if 文本型文件类型[vim.bo[bufnr].filetype] then
        return 'unknown'
    end

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
    -- 含 HTML 注释（commentstring `<!-- %s -->` 去占位后无法精确匹配，直接查 <!--）
    if stripped:match('^%*%s') or stripped:match('^//') or stripped:match('^/#')
        or stripped:match('^<!%-%-') then
        return 'comment'
    end

    -- 引号计数 + 行内注释检测（同步扫描，仅统计引号外的标记）
    local in_single, in_double, in_backtick = false, false, false
    local i = 1
    while i <= #before do
        local ch = before:sub(i, i)
        local next_ch = i < #before and before:sub(i + 1, i + 1) or ''
        if ch == '\\' then
            i = i + 1  -- 跳过转义字符
        elseif ch == "'" and not in_double and not in_backtick then
            in_single = not in_single
        elseif ch == '"' and not in_single and not in_backtick then
            in_double = not in_double
        elseif ch == '`' and not in_single and not in_double then
            in_backtick = not in_backtick
        elseif not in_single and not in_double and not in_backtick then
            -- 引号外的行注释标记：光标在标记后，必在注释内
            if (ch == '-' and next_ch == '-') or (ch == '/' and next_ch == '/')
                or ch == '#' then
                return 'comment'
            end
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
--- Detect cursor context.
--- 优先使用 blink.cmp 传入的 ctx（含 bufnr/cursor，避免依赖当前窗口）；
--- 无 ctx 时回退到当前窗口（稍 omnifunc 等同步场景使用）。
function M.get_cursor_context(ctx)
    local bufnr, row, col
    if ctx and ctx.bufnr then
        bufnr = ctx.bufnr
        local cursor = ctx.cursor or vim.api.nvim_win_get_cursor(0)
        row, col = cursor[1] - 1, cursor[2]  -- cursor: {行(1基), 列(0基)}
    else
        bufnr = vim.api.nvim_get_current_buf()
        local cursor = vim.api.nvim_win_get_cursor(0)
        row, col = cursor[1] - 1, cursor[2]
    end
    return get_cursor_context_heuristic(bufnr, row, col)
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
    local freq = {}  -- 词频统计，用于截断时保留高频短词
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    -- Collect text words (mode 'text' or 'all')
    if mode == 'text' or mode == 'all' then
        for _, line in ipairs(lines) do
            提取行词(line, function(word)
                if #word >= 2 and M.has_cjk(word) then
                    if not seen[word] then
                        seen[word] = true
                        words[#words + 1] = word
                    end
                    freq[word] = (freq[word] or 0) + 1
                end
            end)
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
            for _, line in ipairs(lines) do
                提取行词(line, function(word)
                    if #word >= 2 and not seen[word] and M.has_cjk(word) then
                        seen[word] = true
                        words[#words + 1] = word
                        freq[word] = (freq[word] or 0) + 1
                    end
                end)
            end
        end
        for _, word in ipairs(code_ids) do
            if not seen[word] then
                seen[word] = true
                words[#words + 1] = word
            end
            freq[word] = (freq[word] or 0) + 1
        end
    end

    -- Cap for performance: keep high-frequency words first, then shorter ones
    -- （词频优先，常用短词不被长词挤掉）
    if #words > M.config.max_candidates then
        table.sort(words, function(a, b)
            if freq[a] ~= freq[b] then return freq[a] > freq[b] end
            return #a < #b
        end)
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

-- Async CLI (for blink.cmp provider，不阻塞主事件循环)
function M.run_cli_async(query, candidates, callback)
    if #query < M.config.min_query_len or #candidates == 0 then
        callback({})
        return
    end
    local cmd = build_cli_cmd(query)
    local input = table.concat(candidates, '\n')
    vim.system(cmd, { text = true, stdin = input, timeout = 1000 }, function(result)
        if result.code ~= 0 then
            vim.notify('[cmp_pinyin] CLI error (exit ' .. tostring(result.code) .. ')',
                       vim.log.levels.WARN)
            callback({})
            return
        end
        callback(parse_cli_output(vim.split(result.stdout, '\n')))
    end)
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
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufWritePost', 'BufDelete' }, {
        group = vim.api.nvim_create_augroup('CmpPinyinCache', { clear = true }),
        callback = function(args)
            cache[args.buf] = nil
            lsp_cache[args.buf] = nil
            lsp_notified[args.buf] = nil
        end,
    })
end

return M