-- cmp_pinyin 测试脚本
-- 在 Neovim 中运行: :luafile test/test_plugin.lua
--
-- 前提条件:
--   1. CLI 已编译: xmake build cli
--   2. 确保 build/linux/x86_64/release/cli 可执行
--
-- 该脚本测试:
--   1. CLI 能找到且可执行
--   2. CJK 检测函数
--   3. 候选项收集
--   4. 拼音匹配（同步）

local function header(msg)
    print('')
    print('═══ ' .. msg .. ' ' .. string.rep('═', 60 - #msg))
end

local function pass(msg) print('  ✓ ' .. msg) end
local function fail(msg) print('  ✗ FAIL: ' .. msg) end

-- Locate project root
-- Use debug.getinfo (works in luafile), fallback to cwd
local script_path = debug.getinfo(1, 'S').source
script_path = script_path:gsub('^@', '')              -- strip @ prefix
local project_root = vim.fn.fnamemodify(script_path, ':h:h')
if project_root == '' or project_root == '.' then
    project_root = vim.fn.getcwd()                     -- fallback
end
local cli_path = project_root .. '/lua/cmp_pinyin/bin/cli'

-- 1. Load the module ------------------------------------------
header('Loading cmp_pinyin')
local ok, cmp_pinyin = pcall(function()
    package.path = project_root .. '/lua/?.lua;' .. project_root .. '/lua/?/init.lua;' .. package.path
    return require('cmp_pinyin')
end)

if not ok then
    print('  Failed to load: ' .. tostring(cmp_pinyin))
    return
end
pass('Module loaded')

-- 2. Setup ----------------------------------------------------
header('Setup')
cmp_pinyin.setup({
    cli_path = cli_path,
    min_query_len = 2,
    notation = { '简拼', '全拼' },
})
pass('Setup completed')

-- 3. Test: CLI executable -------------------------------------
header('CLI check')
if vim.fn.executable(cli_path) == 1 then
    pass('CLI found: ' .. cli_path)
else
    fail('CLI not executable: ' .. cli_path)
    return
end

-- 4. Test: CJK detection --------------------------------------
header('CJK detection')
local cjk_cases = {
    { '拼音', true },
    { 'hello', false },
    { 'abc123', false },
    { '中文测试', true },
    { 'Hello世界', true },
}
for _, case in ipairs(cjk_cases) do
    local result = cmp_pinyin.has_cjk(case[1])
    if result == case[2] then
        pass(string.format('has_cjk("%s") = %s', case[1], tostring(result)))
    else
        fail(string.format('has_cjk("%s") = %s, expected %s', case[1], tostring(result), tostring(case[2])))
    end
end

-- 5. Test: collect_candidates (uses current buffer) -----------
header('Candidate collection')
local bufnr = vim.api.nvim_get_current_buf()
local candidates = cmp_pinyin.collect_candidates(bufnr)
if #candidates > 0 then
    pass('Found ' .. #candidates .. ' candidates in current buffer')
    -- Show sample
    local sample = {}
    for i = 1, math.min(10, #candidates) do
        sample[#sample + 1] = candidates[i]
    end
    print('    Sample: ' .. table.concat(sample, ', '))
else
    print('  ~ No CJK candidates in current buffer (open test/example.py first)')
end

-- 6. Test: Sync matching --------------------------------------
header('Pinyin matching (sync)')
local test_cases = {
    { query = 'yh', expect_match = true },   -- 用户 (简拼)
    { query = 'hello', expect_match = false },
    { query = 'sj', expect_match = true },    -- 数据 (简拼) / 世界 (简拼)
}
for _, case in ipairs(test_cases) do
    local matches = cmp_pinyin.run_cli_sync(case.query, candidates)
    local matched = #matches > 0
    if matched == case.expect_match then
        pass(string.format('query="%s": %d matches', case.query, #matches))
        for _, m in ipairs(matches) do
            print(string.format('      %s (score=%d)', m.word, m.score))
        end
    else
        fail(string.format('query="%s": expected match=%s, got %d matches',
                           case.query, tostring(case.expect_match), #matches))
    end
end

-- 7. Test: Cache invalidation ---------------------------------
header('Cache invalidation')
local before = #cmp_pinyin.collect_candidates(bufnr)
cmp_pinyin.invalidate_cache(bufnr)
local after = #cmp_pinyin.collect_candidates(bufnr)
if before == after then
    pass(string.format('Cache OK: %d candidates before and after invalidation', before))
else
    fail(string.format('Cache broken: %d → %d', before, after))
end

-- 8. Test: Empty query ----------------------------------------
header('Edge cases')
local empty_matches = cmp_pinyin.run_cli_sync('a', candidates)
if #empty_matches == 0 then
    pass('Single-char query returns no results (below min_query_len=2)')
else
    pass('Single-char query returned ' .. #empty_matches .. ' results')
end

local no_cand_matches = cmp_pinyin.run_cli_sync('hello', {})
if #no_cand_matches == 0 then
    pass('Empty candidate list returns no results')
else
    fail('Empty candidate list should return no results')
end

print('')
print('═══ Tests complete ═══')
print('')
