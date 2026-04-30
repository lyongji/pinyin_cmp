#include <ib_pinyin/pinyin.hpp>
#include <ib_pinyin/ib_pinyin.h>

namespace pinyin {

bool 是否匹配(std::string_view 模式, std::string_view 文本, 注音方式 方式) {
    return capi::ib_pinyin_is_match_u8(
        模式.data(), 模式.size(),
        文本.data(), 文本.size(),
        原始值(方式));
}

std::optional<匹配结果> 查找匹配(std::string_view 模式, std::string_view 文本, 注音方式 方式) {
    auto r = capi::ib_pinyin_find_match_u8(
        模式.data(), 模式.size(),
        文本.data(), 文本.size(),
        原始值(方式));
    // 未找到时：r==0 或高位为全F（哨兵值）
    if (r == 0 || static_cast<uint32_t>(r >> 32) == UINT32_MAX) return std::nullopt;
    return 匹配结果{static_cast<size_t>(r & 0xFFFFFFFFULL), static_cast<size_t>(r >> 32)};
}

}  // namespace pinyin
