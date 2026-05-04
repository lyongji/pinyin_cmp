add_rules("mode.debug", "mode.release")
set_encodings("utf-8")
-- set_languages("cxx23")
set_languages("cxxlatest")

-- if is_plat("windows") then
--     add_cxxflags("/utf-8")
-- end

add_requires("spdlog")

target("pinyin")
    set_kind("binary")
    add_packages("spdlog")
    add_includedirs("include")
    add_linkdirs("lib")
    add_links("ib_pinyin_c")
    if is_plat("linux") then
        add_rpathdirs("$ORIGIN")
    elseif is_plat("windows") then
        add_links("ntdll")
    end
    add_files("src/main.cpp", "src/pinyin.cpp")
    after_build(function (target)
        if is_plat("linux") then
            os.cp("lib/libib_pinyin_c.so", target:targetdir())
        elseif is_plat("windows") then
            os.cp("lib/ib_pinyin_c.dll", target:targetdir())
        end
    end)

--https://github.com/Chaoses-Ib/ib-matcher.git
target("cli")
    set_kind("binary")
    set_targetdir("lua/cmp_pinyin/bin")
    add_includedirs("include")
    add_linkdirs("lib")
    add_links("ib_pinyin_c")
    if is_plat("linux") then
        add_rpathdirs("$ORIGIN")
    elseif is_plat("windows") then
        add_links("ntdll")
    end
    add_files("src/cli.cpp", "src/pinyin.cpp")
    after_build(function (target)
        if is_plat("linux") then
            os.cp("lib/libib_pinyin_c.so", target:targetdir())
        elseif is_plat("windows") then
            os.cp("lib/ib_pinyin_c.dll", target:targetdir())
        end
    end)
