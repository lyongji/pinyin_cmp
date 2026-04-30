#include <ib_pinyin/pinyin.hpp>
#include <algorithm>
#include <fstream>
#include <iostream>
#include <string>
#include <unordered_map>
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

int main(int 参数个数, char* 参数[]) {
    if (参数个数 < 2) {
        打印用法(参数[0]);
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
            if (i + 1 >= 参数个数) { 打印用法(参数[0]); return 1; }
            std::string 名称 = 参数[++i];
            if (名称.size() > 2 && 名称[0] == '0' && 名称[1] == 'x') {
                注音标记 |= static_cast<uint32_t>(std::stoul(名称, nullptr, 16));
            } else {
                auto it = 名称到值.find(名称);
                if (it == 名称到值.end()) {
                    std::cerr << "未知注音方式: " << 名称 << '\n';
                    打印用法(参数[0]);
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
    if (i >= 参数个数) { 打印用法(参数[0]); return 1; }

    std::string 参数x = 参数[i];
    if (参数x == "-f" || 参数x == "--file") {
        if (i + 2 >= 参数个数) { 打印用法(参数[0]); return 1; }
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

    auto 方式 = static_cast<pinyin::注音方式>(注音标记);

    for (const auto& 候选词 : 候选词列表) {
        auto 匹配 = pinyin::查找匹配(查询词, 候选词, 方式);
        if (匹配) {
            auto 得分 = (匹配->开始 << 32) |
                        ((匹配->结束 - 匹配->开始) << 16) |
                        候选词.size();
            std::cout << 候选词 << '\t' << 得分 << '\n';
        }
    }

    return 0;
}
