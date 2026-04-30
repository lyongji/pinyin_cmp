#pragma once

#include <cstdint>
#include <optional>
#include <string_view>

namespace pinyin {

enum class 注音方式 : uint32_t {
    简拼   = 0x1,   // e.g. "p", "y"
    全拼   = 0x2,   // e.g. "pin", "yin"
    带声调全拼 = 0x4,   // e.g. "pin1", "yin1"
    unicode = 0x8,   // e.g. "pīn", "yīn"
    abc双拼  = 0x10,
    加加双拼  = 0x20,
    微软双拼  = 0x40,
    华宇双拼  = 0x80,
    小鹤双拼  = 0x100,
    自然码双拼 = 0x200,
};

constexpr 注音方式 operator|(注音方式 a, 注音方式 b) noexcept {
    return static_cast<注音方式>(static_cast<uint32_t>(a) | static_cast<uint32_t>(b));
}

constexpr uint32_t 原始值(注音方式 n) noexcept { return static_cast<uint32_t>(n); }

struct 匹配结果 {
    size_t 开始;
    size_t 结束;  // 左闭右开
};

bool 是否匹配(std::string_view 模式, std::string_view 文本, 注音方式 方式);

std::optional<匹配结果> 查找匹配(std::string_view 模式, std::string_view 文本, 注音方式 方式);

}  // namespace pinyin
