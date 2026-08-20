# Pinyin Completion — Godot 拼音补全插件

在 Godot 编辑器中输入拼音时自动补全中文（CJK）词汇。

## 功能

- **拼音补全**：在脚本编辑器中输入拼音（简拼/全拼/双拼），自动匹配当前项目中的中文词汇
- **项目扫描**：自动扫描项目 `.gd`、`.tscn`、`.res` 等文件中的中文文本作为候选词
- **编辑器集成**：作为 EditorPlugin 无缝集成到 Godot 脚本编辑器
- **C++ CLI 驱动**：使用 ib_pinyin 库进行高精度匹配，支持 10 种拼音方案
- **多拼音方案**：简拼（首字母）、全拼、双拼（abc/加加/微软/华宇/小鹤/自然码）、带声调全拼、unicode

## 安装

### 方法一：手动安装

1. 将 `addons/pinyin_completion` 目录复制到你的 Godot 项目的 `addons/` 下
2. 在 Godot 中打开 **项目设置 → 插件**，启用 `Pinyin Completion`
3. （可选）注册 `PinyinCompletion` 为自动加载（Autoload），方便在运行时使用：

   **项目设置 → 自动加载**，添加 `addons/pinyin_completion/pinyin_completion.gd` → 命名为 `Pinyin`

## 使用

### 脚本编辑器补全

1. 在脚本编辑器中输入中文词汇的拼音（ASCII 字母）
2. 自动触发补全，或按 `Ctrl + Space` 手动触发
3. 选择中文候选项，拼音被替换为对应的中文

### 示例

| 输入 | 补全结果 |
|------|---------|
| `yh` | 用户、用户管理、用户列表 |
| `yonghu` | 用户、用户管理 |
| `yshu`（双拼） | 用户 |

### 配置

点击编辑器工具栏的 **拼音** 按钮打开设置弹窗，可配置：

- 拼音方案（多选，支持 10 种方案）
- 最小查询长度
- 最大候选词数

## 架构

```
用户输入拼音
    │
    ▼
文本收集器 (text_collector.gd)    ← 扫描项目文件中的 CJK 词汇
    │
    ▼
拼音补全核心 (pinyin_completion.gd)  ← 通过 C++ CLI 调用 ib_pinyin 匹配
    │
    ▼
补全钩子 (completion_hook.gd)      ← 注入 Godot CodeEdit 补全系统
    │
    ▼
Godot 编辑器补全菜单
```

## 依赖项

| 依赖 | 说明 |
|------|------|
| Godot 4.x | 编辑器环境 |
| `libib_pinyin_c.so` | ib_pinyin C 库（Linux，bundled） |
| `cli` | C++ 拼音匹配 CLI（Linux，bundled） |

> **Windows/macOS**：如需在 Windows 或 macOS 上运行，需要编译对应的 CLI 二进制文件并放置在 `addons/pinyin_completion/bin/` 目录下。
