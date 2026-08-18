add_rules("mode.debug", "mode.release")
set_encodings("utf-8")
set_languages("cxxlatest")

add_requires("spdlog")  -- 仅 demo target (pinyin) 使用

-- 两个 target 共用的 ib_pinyin 预编译库配置
local function setup_ib_pinyin()
    add_includedirs("include")
    add_linkdirs("lib")
    add_links("ib_pinyin_c")
    if is_plat("linux") then
        add_rpathdirs("$ORIGIN")
    elseif is_plat("windows") then
        add_links("ntdll")
    end
    after_build(function (target)
        if is_plat("linux") then
            os.cp("lib/libib_pinyin_c.so", target:targetdir())
        elseif is_plat("windows") then
            os.cp("lib/ib_pinyin_c.dll", target:targetdir())
        end
    end)
end

-- 来源: https://github.com/Chaoses-Ib/ib-matcher.git
target("pinyin")
    set_kind("binary")
    add_packages("spdlog")
    setup_ib_pinyin()
    add_files("src/main.cpp", "src/pinyin.cpp")

target("cli")
    set_kind("binary")
    set_targetdir("lua/cmp_pinyin/bin")
    setup_ib_pinyin()
    add_files("src/cli.cpp", "src/pinyin.cpp", "src/shuangpin.cpp")
