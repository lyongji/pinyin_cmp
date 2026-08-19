// ib_pinyin 库冒烟测试：覆盖各注音方式与查找匹配
// 编译运行（在仓库根目录）：
//   g++ -std=c++23 -Iinclude test/test_ib_pinyin.cpp src/pinyin.cpp -Llib -lib_pinyin_c -o test/test_ib_pinyin
//   LD_LIBRARY_PATH=lib test/test_ib_pinyin
#include <cassert>
#include <cstdio>
#include <string_view>

#include <ib_pinyin/pinyin.hpp>

using namespace pinyin;
using std::string_view;

static int 通过数 = 0;

static void 断言匹配(string_view 模式, string_view 文本, 注音方式 方式) {
    assert(是否匹配(模式, 文本, 方式));
    ++通过数;
}

static void 断言不匹配(string_view 模式, string_view 文本, 注音方式 方式) {
    assert(!是否匹配(模式, 文本, 方式));
    ++通过数;
}

static void 测试各注音方式() {
    // 简拼
    断言匹配("py", "拼音", 注音方式::简拼);
    断言匹配("pyss", "拼音搜索", 注音方式::简拼);  // 搜 sou/sou suo 皆 s
    断言不匹配("px", "拼音搜索", 注音方式::简拼);
    // 全拼
    断言匹配("pinyin", "拼音", 注音方式::全拼);
    断言不匹配("py", "拼音", 注音方式::全拼);
    // 带声调全拼
    断言匹配("pin1", "拼音", 注音方式::带声调全拼);
    断言不匹配("pin", "拼音", 注音方式::带声调全拼);
    // unicode（带声调字母）
    断言匹配("pīn", "拼音", 注音方式::unicode);
    断言不匹配("pin", "拼音", 注音方式::unicode);
    // 双拼方案（ib_pinyin 原生支持）
    断言匹配("go", "国家", 注音方式::加加双拼);    // g=gu, o=uo
    断言匹配("xbnm", "新年", 注音方式::小鹤双拼);  // 新 xin(in→b) + 年 nian(ian→m)
}

static void 测试查找匹配() {
    auto 结果 = 查找匹配("sousuo", "拼音搜索Everything", 注音方式::全拼 | 注音方式::简拼);
    assert(结果.has_value());
    assert(结果->开始 > 0 && 结果->结束 > 结果->开始);
    ++通过数;

    auto 无结果 = 查找匹配("xyz", "拼音搜索Everything", 注音方式::全拼);
    assert(!无结果.has_value());
    ++通过数;
}

static void 测试组合注音() {
    const auto 组合 = 注音方式::全拼 | 注音方式::简拼;
    断言匹配("py", "拼音搜索", 组合);
    断言匹配("pinyinsousuo", "拼音搜索", 组合);
}

int 加(int a,int b){
  return a+b;
}

int main() {
    测试各注音方式();
    测试查找匹配();
    测试组合注音();

    std::printf("全部通过 (%d 项断言)\n", 通过数);
    return 0;
}
