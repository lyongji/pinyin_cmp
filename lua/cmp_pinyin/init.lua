local M = {}

-- Default configuration ------------------------------------------------
M.config = {
    cli_path = nil,                     -- path to pinyin-cli binary (REQUIRED)
    min_query_len = 2,                  -- minimum pinyin query length
    notation = { '简拼', '全拼' },        -- pinyin notation(s): 简拼 全拼 带声调全拼 unicode abc双拼 加加双拼 微软双拼 华宇双拼 小鹤双拼 自然码双拼
    max_candidates = 300,               -- max buffer candidates sent to CLI
    cli_timeout_ms = 3000,              -- async CLI timeout
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

function M.invalidate_cache(bufnr)
    if bufnr then
        cache[bufnr] = nil
    else
        cache = {}
    end
end

local function get_word_pattern()
    -- Match runs of ASCII word chars + non-ASCII bytes
    return '[%w_\128-\255]+'
end

function M.collect_candidates(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)

    if cache[bufnr] and cache[bufnr].tick == tick then
        return cache[bufnr].words
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local seen = {}
    local words = {}
    local pat = get_word_pattern()

    for _, line in ipairs(lines) do
        for word in line:gmatch(pat) do
            if #word >= 2 and not seen[word] and M.has_cjk(word) then
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

    cache[bufnr] = { tick = tick, words = words }
    return words
end

-- CLI helpers -----------------------------------------------------------
local function build_cli_cmd(query)
    local cmd = { M.config.cli_path }
    for _, name in ipairs(M.config.notation) do
        cmd[#cmd + 1] = '--notation'
        cmd[#cmd + 1] = name
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

-- Async CLI (for nvim-cmp / blink.cmp) ----------------------------------
local active_job_id = nil
local active_timer_id = nil

local function cancel_active()
    if active_job_id then
        pcall(vim.fn.jobstop, active_job_id)
        active_job_id = nil
    end
    if active_timer_id then
        pcall(vim.fn.timer_stop, active_timer_id)
        active_timer_id = nil
    end
end

--- Run CLI asynchronously.  `callback(results)` is called in a vim.schedule
--- context, where `results` is a list of `{ word, score }` sorted by score asc.
function M.run_cli_async(query, candidates, callback)
    if #query < M.config.min_query_len or #candidates == 0 then
        callback({})
        return
    end

    cancel_active()

    local cmd = build_cli_cmd(query)
    local input = table.concat(candidates, '\n')
    local stdout_lines = {}
    local completed = false

    active_job_id = vim.fn.jobstart(cmd, {
        stdout_buffered = true,
        on_stdout = function(_, data)
            if data then
                for _, line in ipairs(data) do
                    if line ~= '' then
                        stdout_lines[#stdout_lines + 1] = line
                    end
                end
            end
        end,
        on_exit = function(_, code)
            if completed then return end
            completed = true
            active_job_id = nil

            if active_timer_id then
                pcall(vim.fn.timer_stop, active_timer_id)
                active_timer_id = nil
            end

            if code ~= 0 then
                vim.schedule(function() callback({}) end)
                return
            end
            local results = parse_cli_output(stdout_lines)
            vim.schedule(function() callback(results) end)
        end,
    })

    if active_job_id > 0 then
        vim.fn.chansend(active_job_id, input)
        vim.fn.chanclose(active_job_id, 'stdin')
        active_timer_id = vim.fn.timer_start(
            M.config.cli_timeout_ms,
            function()
                if not completed then
                    completed = true
                    cancel_active()
                    vim.schedule(function() callback({}) end)
                end
            end
        )
    else
        active_job_id = nil
        callback({})
    end
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

    -- Invalidate candidate cache when any buffer changes
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufWritePost' }, {
        group = vim.api.nvim_create_augroup('CmpPinyinCache', { clear = true }),
        callback = function(args)
            cache[args.buf] = nil
        end,
    })
end

return M
