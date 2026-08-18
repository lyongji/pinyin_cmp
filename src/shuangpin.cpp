#include "shuangpin.hpp"
#include <algorithm>
#include <array>
#include <string>
#include <string_view>
#include <unordered_map>

namespace shuangpin {

// ── 加加双拼 转换表 ─────────────────────────────────────────────────
// 声母键 → 实际声母（zh/ch/sh 特殊映射）
// 加加双拼：v→zh, i→ch, u→sh
static const std::unordered_map<char, std::string_view> 加加_声母 = {
    {'b', "b"}, {'p', "p"}, {'m', "m"}, {'f', "f"},
    {'d', "d"}, {'t', "t"}, {'n', "n"}, {'l', "l"},
    {'g', "g"}, {'k', "k"}, {'h', "h"},
    {'j', "j"}, {'q', "q"}, {'x', "x"},
    {'r', "r"}, {'z', "z"}, {'c', "c"}, {'s', "s"},
    {'y', "y"}, {'w', "w"},
    {'v', "zh"},  // v → zh
    {'i', "ch"},  // i → ch
    {'u', "sh"},  // u → sh
};

// 韵母键 → 实际韵母
// 加加双拼 keyboard layout
static const std::unordered_map<char, std::string_view> 加加_韵母 = {
    {'q', "iu"}, {'w', "ia"}, {'e', "e"}, {'r', "uan"},
    {'t', "ue"}, {'y', "uai"}, {'u', "u"}, {'i', "i"},
    {'o', "o"}, {'p', "ou"},
    {'a', "a"}, {'s', "ong"}, {'d', "iang"}, {'f', "en"},
    {'g', "eng"}, {'h', "ang"}, {'j', "an"}, {'k', "ao"},
    {'l', "ai"}, {'z', "ei"}, {'x', "ie"}, {'c', "iao"},
    {'v', "ui"}, {'b', "in"}, {'n', "un"}, {'m', "ian"},
    // 特殊：w 也可以表示 ua
    // 特殊：o 也可以表示 uo
};

// 部分韵母键有多个候选韵母，需要根据声母选择
// 加加双拼中: w = ia/ua, o = o/uo
struct 韵母候选 { char 键; std::string_view 韵母1; std::string_view 韵母2; std::string_view 声母集1; };
// 声母集1:用 韵母1 的声母键集合;其余声母用 韵母2
// 加加双拼: w = ia/ua(ia 只跟 j/q/x/l 相拼), o = o/uo(o 只跟 b/p/m/f 相拼)
static const std::array<韵母候选, 2> 加加_多候选 = {{
    {'w', "ia", "ua", "jqxl"},
    {'o', "o", "uo", "bpmf"},
}};

// ── 华宇双拼 转换表 ─────────────────────────────────────────────────
// 华宇双拼：v→zh, i→ch, u→sh
static const std::unordered_map<char, std::string_view> 华宇_声母 = 加加_声母;  // 相同

// 华宇双拼 keyboard layout
static const std::unordered_map<char, std::string_view> 华宇_韵母 = {
    {'q', "iu"}, {'w', "ua"}, {'e', "e"}, {'r', "uan"},
    {'t', "ue"}, {'y', "un"}, {'u', "u"}, {'i', "i"},
    {'o', "o"}, {'p', "ou"},
    {'a', "a"}, {'s', "ong"}, {'d', "uang"}, {'f', "en"},
    {'g', "eng"}, {'h', "ang"}, {'j', "an"}, {'k', "ao"},
    {'l', "ai"}, {'z', "ei"}, {'x', "ie"}, {'c', "iao"},
    {'v', "ui"}, {'b', "in"}, {'n', "un"}, {'m', "ian"},
    // 特殊：s = ong/iong, d = uang/iang, n = un/iao(?) 
    // 华宇双拼中: s = ong/iong, d = uang/iang
};

static const std::array<韵母候选, 2> 华宇_多候选 = {{
    {'s', "iong", "ong", "jqx"},
    {'d', "iang", "uang", "jqxnl"},
}};

// ── 核心转换逻辑 ───────────────────────────────────────────────────

/// 在 声母+韵母 表中查询某个键的韵母
/// 多候选键（如 w = ia/ua）按声母键二选一；其余键直接查表
static std::string 查韵母(char 声母键, char 韵母键, const std::unordered_map<char, std::string_view>& map,
                        const std::array<韵母候选, 2>& extras) {
    for (const auto& e : extras) {
        if (e.键 == 韵母键) {
            bool 用韵母1 = e.声母集1.find(声母键) != std::string_view::npos;
            return std::string(用韵母1 ? e.韵母1 : e.韵母2);
        }
    }
    auto it = map.find(韵母键);
    if (it != map.end()) return std::string(it->second);
    return "";
}

/// 将一个双拼音节 (c1, c2) 转换为全拼
/// 加加双拼/华宇双拼 共用此逻辑（声母表相同）
std::string 音节转全拼(char c1, char c2, uint32_t scheme) {
    const auto& 声母表 = 加加_声母;  // 两个方案声母表相同
    const auto& 韵母表 = (scheme == 华宇双拼) ? 华宇_韵母 : 加加_韵母;
    const auto& 多候选 = (scheme == 华宇双拼) ? 华宇_多候选 : 加加_多候选;

    // 查声母
    auto sm_it = 声母表.find(c1);
    if (sm_it == 声母表.end()) return "";  // 无效声母键
    std::string sm(sm_it->second);

    // 查韵母（多候选键按声母键选择）
    std::string ym = 查韵母(c1, c2, 韵母表, 多候选);
    if (ym.empty()) return "";  // 无效韵母键

    // 处理特殊组合：当韵母以 i/u 开头且声母为空时
    // 如 yi, wu, yu 等
    if (sm == "y" && ym[0] == 'i') {
        return sm + ym;  // yi, yin, ying, etc.
    }
    if (sm == "y" && ym == "u") {
        return "yu";
    }
    if (sm == "w" && ym == "u") {
        return "wu";
    }
    if (sm == "y" && ym[0] == 'u' && ym != "u") {
        return "y" + ym.substr(1);  // yue, yuan, yun
    }
    if (sm == "w" && ym[0] == 'u') {
        return "w" + ym.substr(1);  // wa, wo, wai, wan, etc.
    }

    // zh/ch/sh 全拼
    if (sm == "zh" || sm == "ch" || sm == "sh") {
        // zh + i = zhi, zh + u = zhu, etc.
        // 特殊：zh + (i 类韵母) = zhi (不加 i)
        // 通用：zh + 韵母 = zh + 韵母
        return sm + ym;
    }

    // 常规情况：声母 + 韵母
    return sm + ym;
}

/// 将双拼查询串转换为全拼
/// 如 "yshu" → "yonghu"
std::string 转换为全拼(std::string_view query, uint32_t scheme) {
    if (query.empty() || query.length() < 2) return "";
    if (scheme != 加加双拼 && scheme != 华宇双拼) return "";

    std::string result;
    size_t i = 0;

    while (i + 1 < query.length()) {
        char c1 = query[i];
        char c2 = query[i + 1];
        std::string syl = 音节转全拼(c1, c2, scheme);
        if (syl.empty()) {
            // 无效音节：尝试单字符处理
            result += c1;
            result += c2;
        } else {
            result += syl;
        }
        i += 2;
    }

    // 处理最后一个奇数位置的字符（部分输入）
    if (i < query.length()) {
        // 最后一个字符是单个声母键，暂时附加
        // 由 ib_pinyin 的简拼匹配处理
        auto it = 加加_声母.find(query[i]);
        if (it != 加加_声母.end()) {
            result += it->second;  // 附加声母本身
        } else {
            result += query[i];
        }
    }

    return result;
}

} // namespace shuangpin
