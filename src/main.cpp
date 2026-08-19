#include <cstdio>
#include <ib_pinyin/pinyin.hpp>

int main() {
    using namespace pinyin;
    const auto 方式 = 注音方式::全拼 | 注音方式::简拼;

    std::printf("是否匹配: %d\n", 是否匹配("pysousuoeve", "拼音搜索Everything", 方式));
    std::printf("是否匹配: %d\n", 是否匹配("py", "拼音", 注音方式::简拼));
    std::printf("是否匹配: %d\n", 是否匹配("xyz", "拼音搜索", 方式));

    if (auto 结果 = 查找匹配("sousuo", "拼音搜索Everything", 方式)) {
        std::printf("查找匹配: [%d, %d)\n", 结果->开始, 结果->结束);
    }
    if (auto 结果 = 查找匹配("pysousuo", "拼音搜索Everything", 方式)) {
        std::printf("查找匹配: [%d, %d)\n", 结果->开始, 结果->结束);
    }
}
