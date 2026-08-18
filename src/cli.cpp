#include <ib_pinyin/pinyin.hpp>
#include "shuangpin.hpp"
#include <algorithm>
#include <fstream>
#include <iostream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

static void 打印用法(const char* 程序名) {
    std::cerr << "拼音代码补全 CLI\n\n";
    std::cerr << "用法:\n";
    std::cerr << "  " << 程序名 << " [--notation 名称]... <拼音查询> [候选词...]\n";
    std::cerr << "  " << 程序名 << " [--notation 名称]... -f <候选词文件> <拼音查询>\n";
    std::cerr << "  echo 候选词 | " << 程序名 << " [--notation 名称]... <拼音查询>\n\n";
    std::cerr << "注音方式: 简拼 全拼 带声调全拼 unicode abc双拼 加加双拼 微软双拼 华宇双拼 小鹤双拼 自然码双拼\n";
    std::cerr << "也可用十六进制: --notation 0x3 (=简拼|全拼)\n";
}

static const std::unordered_map<std::string, uint32_t> 名称到值 = {
    {"简拼",     0x1},
    {"全拼",     0x2},
    {"带声调全拼", 0x4},
    {"unicode",  0x8},
    {"abc双拼",   0x10},
    {"加加双拼",   0x20},
    {"微软双拼",   0x40},
    {"华宇双拼",   0x80},
    {"小鹤双拼",   0x100},
    {"自然码双拼",  0x200},
};

/// 输出前净化候选词，防止 \t 破坏 word\tscore 协议
static std::string 净化词(const std::string& 词) {
    std::string 结果 = 词;
    std::replace(结果.begin(), 结果.end(), '\t', ' ');
    std::replace(结果.begin(), 结果.end(), '\r', ' ');
    return 结果;
}

int main(int 参数个数, char* 参数[]) {
    const char* 程序名 = 参数个数 > 0 ? 参数[0] : "cli";
    if (参数个数 < 2) {
        打印用法(程序名);
        return 1;
    }

    uint32_t 注音标记 = 0;
    std::string 查询词;
    std::vector<std::string> 候选词列表;

    int i = 1;
    // 解析 --notation / -n
    for (; i < 参数个数; i++) {
        std::string_view 当前参数 = 参数[i];
        if (当前参数 == "-n" || 当前参数 == "--notation") {
            if (i + 1 >= 参数个数) { 打印用法(程序名); return 1; }
            std::string 名称 = 参数[++i];
            if (名称.size() > 2 && 名称[0] == '0' && (名称[1] == 'x' || 名称[1] == 'X')) {
                std::size_t 已解析 = 0;
                try {
                    auto 值 = std::stoul(名称, &已解析, 16);
                    // stoul 只解析合法前缀（如 0xGG 解析为 0），必须完整消费才有效
                    if (已解析 != 名称.size()) throw std::invalid_argument("部分解析");
                    注音标记 |= static_cast<uint32_t>(值);
                } catch (const std::exception&) {
                    std::cerr << "无效的注音方式: " << 名称 << '\n';
                    打印用法(程序名);
                    return 1;
                }
            } else {
                auto it = 名称到值.find(名称);
                if (it == 名称到值.end()) {
                    std::cerr << "未知注音方式: " << 名称 << '\n';
                    打印用法(程序名);
                    return 1;
                }
                注音标记 |= it->second;
            }
        } else {
            break;
        }
    }

    // 默认：简拼 + 全拼
    if (注音标记 == 0) 注音标记 = 0x1 | 0x2;

    // 解析剩余参数
    if (i >= 参数个数) { 打印用法(程序名); return 1; }

    std::string 参数x = 参数[i];
    if (参数x == "-f" || 参数x == "--file") {
        if (i + 2 >= 参数个数) { 打印用法(程序名); return 1; }
        std::ifstream 文件(参数[i + 1]);
        if (!文件) {
            std::cerr << "无法打开文件: " << 参数[i + 1] << '\n';
            return 1;
        }
        std::string 行;
        while (std::getline(文件, 行)) {
            if (!行.empty()) 候选词列表.push_back(std::move(行));
        }
        查询词 = 参数[i + 2];
    } else {
        查询词 = 参数x;
        i++;
        if (i < 参数个数) {
            for (; i < 参数个数; i++)
                候选词列表.push_back(参数[i]);
        } else {
            std::string 行;
            while (std::getline(std::cin, 行)) {
                if (!行.empty()) 候选词列表.push_back(std::move(行));
            }
        }
    }

    if (查询词.empty() || 候选词列表.empty()) return 0;

    constexpr uint32_t 加加双拼标记 = 0x20;
    constexpr uint32_t 华宇双拼标记 = 0x80;
    constexpr uint32_t 本库双拼掩码 = 加加双拼标记 | 华宇双拼标记;

    // 第一步：用所有选中的注音方式匹配（包括 ib_pinyin 原生支持的各类双拼）
    auto 方式 = static_cast<pinyin::注音方式>(注音标记);
    std::unordered_set<std::string> 已输出;  // 两阶段去重

    for (const auto& 候选词 : 候选词列表) {
        auto 匹配 = pinyin::查找匹配(查询词, 候选词, 方式);
        if (匹配) {
            std::string 输出词 = 净化词(候选词);
            已输出.insert(输出词);
            auto 得分 = (匹配->开始 << 32) |
                        ((匹配->结束 - 匹配->开始) << 16) |
                        候选词.size();
            std::cout << 输出词 << '\t' << 得分 << '\n';
        }
    }

    // 第二步：对 ib_pinyin 未原生支持的双拼方案（加加/华宇）进行转换匹配
    // 转换查询词为全拼后，仅用全拼方式匹配；跳过第一阶段已输出的词
    uint32_t 需转换双拼 = 注音标记 & 本库双拼掩码;
    auto 转换匹配 = [&](uint32_t 方案位) {
        std::string 全拼查询 = shuangpin::转换为全拼(查询词, 方案位);
        if (全拼查询.empty() || 全拼查询 == 查询词) return;

        auto 全拼方式 = static_cast<pinyin::注音方式>(0x2);  // 仅全拼
        for (const auto& 候选词 : 候选词列表) {
            auto 匹配 = pinyin::查找匹配(全拼查询, 候选词, 全拼方式);
            if (!匹配) continue;
            std::string 输出词 = 净化词(候选词);
            if (已输出.count(输出词)) continue;  // 第一阶段已命中，去重

            auto 基础得分 = (匹配->开始 << 32) |
                            ((匹配->结束 - 匹配->开始) << 16) |
                            候选词.size();
            // 双拼结果整体 +100 偏移，让简拼/全拼原生结果优先
            auto 得分 = 基础得分 + 100;
            std::cout << 输出词 << '\t' << 得分 << '\n';
        }
    };

    // 同时指定多个双拼方案时，只处理第一个（加加优先）
    if (需转换双拼 & 加加双拼标记) {
        转换匹配(加加双拼标记);
    } else if (需转换双拼 & 华宇双拼标记) {
        转换匹配(华宇双拼标记);
    }

    return 0;
}
