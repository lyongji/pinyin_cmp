#pragma once
#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_map>

namespace shuangpin {

/// 双拼方案 ID（与 ib_pinyin 的注音方式枚举一致）
enum 方案 : uint32_t {
    加加双拼  = 0x20,
    华宇双拼  = 0x80,
};

/// 将双拼查询转换为全拼字符串
/// @param query  用户输入的双拼查询（如 "yshu"）
/// @param scheme 双拼方案（加加双拼/华宇双拼）
/// @return 全拼字符串（如 "yonghu"），转换失败返回空字符串
std::string 转换为全拼(std::string_view query, uint32_t scheme);

/// 将单个双拼音节 (initial_key, final_key) 转换为全拼
/// @param c1  声母键
/// @param c2  韵母键
/// @param scheme  双拼方案
/// @return 全拼音节（如 "yong"），无效返回空
std::string 音节转全拼(char c1, char c2, uint32_t scheme);

} // namespace shuangpin
