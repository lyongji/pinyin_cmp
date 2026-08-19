add_rules("mode.debug", "mode.release")
set_encodings("utf-8")
set_languages("cxxlatest")

add_requires("spdlog")  -- 仅 demo target (pinyin) 使用

-- ============ ib_pinyin 预编译库：首次构建自动拉取源码并用 cargo 编译 ============
-- 来源: https://github.com/Chaoses-Ib/ib-matcher (ib-pinyin/bindings/c/README.md)
-- 注意: xmake.lua 文件作用域内的 os 是裁剪版（无 run/exec/cd/cp），
--       因此完整 os 需由 before_build 回调（完整环境）传入。
local IB_PINYIN_URL = "https://github.com/Chaoses-Ib/ib-matcher.git"
local IB_PINYIN_SRC = path.join(os.projectdir(), ".xmake", "ib-matcher")
local IB_PINYIN_BINDING = path.join(IB_PINYIN_SRC, "ib-pinyin", "bindings", "c")
local ib_pinyin_ready = false  -- 两个 target 共享，只拉取/编译一次

-- 判断预编译库是否已就绪（已就绪则跳过拉取）
local function ib_pinyin_exists()
    local lib_dir = path.join(os.projectdir(), "lib")
    if is_plat("windows") then
        return os.isfile(path.join(lib_dir, "ib_pinyin_c.lib"))
    end
    return os.isfile(path.join(lib_dir, "libib_pinyin_c.so"))
end

-- 首次构建：拉取 ib-matcher 源码，编译 C 绑定库，拷贝产物到 lib/ 与 include/
-- os_ 为 before_build 回调中的完整 os（含 run/cp）
local function ensure_ib_pinyin(os_)
    if ib_pinyin_exists() then
        return
    end
    print("ib_pinyin 预编译库不存在，首次构建：拉取源码并编译（需 git 与 cargo）...")
    if not os.isdir(IB_PINYIN_SRC) then
        os_.run("git clone --depth 1 %s %s", IB_PINYIN_URL, IB_PINYIN_SRC)
    end
    -- 构建命令与 bindings/c/README.md 一致（用 --manifest-path 免去 cd）
    os_.run("cargo build -r --manifest-path %s", path.join(IB_PINYIN_BINDING, "Cargo.toml"))
    -- workspace 仓库，cargo 产物统一在仓库根 target/release/
    local release = path.join(IB_PINYIN_SRC, "target", "release")
    local lib_dir = path.join(os.projectdir(), "lib")
    -- 目标目录可能不存在，需先创建（os.cp 对不存在的目标目录会当文件处理）
    os_.mkdir(lib_dir)
    os_.mkdir(path.join(os.projectdir(), "include", "ib_pinyin"))
    if is_plat("windows") then
        os_.cp(path.join(release, "ib_pinyin_c.lib"), lib_dir)
        os_.cp(path.join(release, "ib_pinyin_c.dll"), lib_dir)
        os_.cp(path.join(release, "ib_pinyin_c.dll.lib"), lib_dir)
    else
        os_.cp(path.join(release, "libib_pinyin_c.so"), lib_dir)
        os_.cp(path.join(release, "libib_pinyin_c.a"), lib_dir)
    end
    -- 头文件（pinyin.hpp 为本地手写，保留）
    os_.cp(path.join(IB_PINYIN_BINDING, "include", "ib_pinyin", "*.h"), path.join(os.projectdir(), "include", "ib_pinyin"))
end

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
    before_build(function (target)
        if not ib_pinyin_ready then
            ib_pinyin_ready = true
            ensure_ib_pinyin(os)
        end
    end)
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
