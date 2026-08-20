class_name PinyinCompletion
extends Node
## 拼音补全核心模块
##
## 收集中文候选项，提供拼音匹配接口（仅通过 C++ CLI 实现）。
## 可作为 Autoload 注册，或附加到任意 CodeEdit/TextEdit 节点。
##
## 使用示例：
##   var pinyin = PinyinCompletion.new()
##   var candidates = ["用户", "用户列表", "拼音", "拼音补全"]
##   var results = pinyin.match("yh", candidates)
##   # → [{word:"用户", score:...}, {word:"拼音", score:...}, ...]

## 最小拼音查询长度
var min_query_len: int = 2:
	set(v):
		min_query_len = max(1, v)

## 拼音方案列表
## setter 自动补充 简拼+全拼（双拼方案需要它们作为回退）
var notation: Array[String] = ["简拼", "全拼"]:
	set(v):
		var filtered: Array[String] = []
		for n in v:
			if NOTATION_MAP.has(n):
				filtered.append(n)
		# 选了双拼但没选简拼/全拼时自动补充
		var has_shuangpin = false
		var has_jianpin = false
		var has_quanpin = false
		for n in filtered:
			if n.find("双拼") >= 0:
				has_shuangpin = true
			elif n == "简拼":
				has_jianpin = true
			elif n == "全拼":
				has_quanpin = true
		if has_shuangpin and not has_jianpin:
			filtered.push_front("简拼")
		if has_shuangpin and not has_quanpin:
			filtered.push_back("全拼")
		if filtered.is_empty():
			filtered = ["简拼", "全拼"]
		notation = filtered

## 所有支持的拼音方案及其 CLI 十六进制值
const NOTATION_MAP: Dictionary = {
	"简拼": "0x1",
	"全拼": "0x2",
	"带声调全拼": "0x4",
	"unicode": "0x8",
	"abc双拼": "0x10",
	"加加双拼": "0x20",
	"微软双拼": "0x40",
	"华宇双拼": "0x80",
	"小鹤双拼": "0x100",
	"自然码双拼": "0x200",
}

## 拼音方案的中文说明
const NOTATION_DESC: Dictionary = {
	"简拼": "首字母（yh → 用户）",
	"全拼": "完整拼音（yonghu → 用户）",
	"带声调全拼": "带声调（yong2hu4 → 用户）",
	"unicode": "Unicode 编码",
	"abc双拼": "ABC 双拼（yshu → 用户）",
	"加加双拼": "加加双拼（yshu → 用户）",
	"微软双拼": "微软双拼（yshu → 用户）",
	"华宇双拼": "紫光华宇双拼（yshu → 用户）",
	"小鹤双拼": "小鹤双拼（yshu → 用户）",
	"自然码双拼": "自然码双拼（yshu → 用户）",
}

## 发送给 CLI 的最大候选词数
var max_candidates: int = 300

## 调试输出（每次匹配打印 CLI 调用详情，默认关闭）
var debug_mode: bool = false

## CLI 路径（自动检测）
var _cli_path: String = ""
var _cli_available: bool = false
var _cli_notified: bool = false
var _cli_checked: bool = false

# ── 匹配结果缓存 ──────────────────────────────────────────────────────
# 相同 query 的连续按键会反复 spawn CLI，这里按 (候选词版本, 方案, query) 缓存结果。
var _match_cache: Dictionary = {}
var _candidates_version: int = 0
const MATCH_CACHE_MAX := 32  # ponytail: 简单容量上限，超限全清；若命中率不足再换 LRU

## 候选词集合变化时调用，使匹配缓存失效
func invalidate_candidates() -> void:
	_candidates_version += 1
	_match_cache.clear()

# ── CLI 桥接 ──────────────────────────────────────────────────────────

## 检测 CLI 是否可用
func _detect_cli() -> bool:
	var search_names = ["cli", "cli.exe"]
	var base_dir = "res://addons/pinyin_completion/bin/"

	for name in search_names:
		var full_path = base_dir + name

		if FileAccess.file_exists(full_path):
			_cli_path = full_path
			_cli_available = true
			print("[PinyinCompletion] CLI found: ", full_path)
			return true

		var dir = DirAccess.open(base_dir)
		if dir and dir.file_exists(name):
			_cli_path = full_path
			_cli_available = true
			print("[PinyinCompletion] CLI found (DirAccess): ", full_path)
			return true

		var abs_path = ProjectSettings.globalize_path(full_path)
		if abs_path.length() > 0:
			var f = FileAccess.open(abs_path, FileAccess.READ)
			if f:
				f.close()
				_cli_path = full_path
				_cli_available = true
				print("[PinyinCompletion] CLI found (abs path): ", abs_path)
				return true

	if not _cli_notified:
		print("[PinyinCompletion] CLI not found after 3 methods")
		_cli_notified = true
	_cli_available = false
	return false

## 通过 CLI 进行拼音匹配
func _match_via_cli(query: String, candidates: Array[String]) -> Array[Dictionary]:
	if not _cli_available:
		return []

	var cli_args := PackedStringArray()
	for n in notation:
		cli_args.append("--notation")
		cli_args.append(NOTATION_MAP.get(n, n))

	cli_args.append(query)
	for c in candidates:
		cli_args.append(c)

	var output: Array[Dictionary] = []
	var abs_path = ProjectSettings.globalize_path(_cli_path)
	if debug_mode:
		print("[PinyinCompletion] CLI: ", abs_path, " | args: ", cli_args.size(), " | query: ", query)

	if OS.has_feature("editor"):
		var result: Array = []
		var exit_code = OS.execute(abs_path, cli_args, result, true, false)
		if exit_code == 0 and result.size() > 0:
			var stdout = result[0].strip_edges()
			if stdout.is_empty():
				return []
			for line in stdout.split("\n"):
				line = line.strip_edges()
				if line.is_empty():
					continue
				var parts = line.split("\t")
				if parts.size() >= 2:
					output.append({"word": parts[0], "score": int(parts[1])})
		else:
			print("[PinyinCompletion] CLI failed exit_code=", exit_code, " result=", result)

	output.sort_custom(func(a, b): return a.score < b.score)
	if debug_mode:
		print("[PinyinCompletion] CLI found ", output.size(), " matches")
	return output

# ── 公开 API ──────────────────────────────────────────────────────────

## 初始化
func _ready():
	_detect_cli()

## 对候选词执行拼音匹配
## 返回按匹配度排序的 [{word, score}, ...] 数组
func match(query: String, candidates: Array[String]) -> Array[Dictionary]:
	if query.length() < min_query_len or candidates.is_empty():
		return []

	if not _cli_checked:
		_detect_cli()
		_cli_checked = true

	# 缓存命中直接返回，避免连续按键重复 spawn CLI
	var cache_key := "%d|%s|%s" % [_candidates_version, ",".join(notation), query]
	if _match_cache.has(cache_key):
		return _match_cache[cache_key]

	var results := _match_via_cli(query, candidates)
	if _match_cache.size() >= MATCH_CACHE_MAX:
		_match_cache.clear()
	_match_cache[cache_key] = results
	return results
