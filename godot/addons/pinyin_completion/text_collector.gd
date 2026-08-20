class_name TextCollector
extends RefCounted
## 文本收集器
##
## 从 Godot 项目文件中提取中文（CJK）词汇，供拼音匹配使用。

## 默认扫描的文件扩展名
const DEFAULT_EXTENSIONS: Array[String] = [
	".gd", ".tscn", ".tres", ".res", ".json", ".csv", ".md",
	".txt", ".cfg", ".yaml", ".yml", ".xml", ".html"
]

## 缓存词汇
var _cached_words: Array[String] = []
var _cache_dirty: bool = true

# ── 后台扫描状态 ──────────────────────────────────────────────────────
var _scan_thread: Thread = null
var _scanning: bool = false
var _cache_generation: int = 0

## 标记缓存为过期
func invalidate_cache():
	_cache_generation += 1
	_cache_dirty = true

## 缓存是否已过期（过期时 get_cached_words 返回空）
func is_dirty() -> bool:
	return _cache_dirty

## 从文本字符串中提取 CJK 词汇
## 支持中文 + 数字/字母/下划线组合，如 "红色2" 作为一个词
static func extract_cjk_words(text: String) -> Array[String]:
	var words: Array[String] = []
	var current: String = ""

	for c in text:
		var code = c.unicode_at(0)
		var is_cjk = (code >= 0x4E00 and code <= 0x9FFF) or \
					 (code >= 0x3400 and code <= 0x4DBF) or \
					 (code >= 0x2E80 and code <= 0x2EFF)  # CJK Radicals
		# 码点范围：0-9, A-Z, a-z, _
		var is_word = (code >= 0x30 and code <= 0x39) or \
					 (code >= 0x41 and code <= 0x5A) or \
					 (code >= 0x61 and code <= 0x7A) or \
					 code == 0x5F

		if is_cjk:
			current += c
		elif is_word and current.length() > 0:
			# 数字/字母/下划线跟在 CJK 后一起收录
			current += c
		else:
			if current.length() >= 2:
				words.append(current)
			current = ""

	if current.length() >= 2:
		words.append(current)

	return words

## 从目录中递归收集所有 CJK 词汇
func collect_from_directory(
	path: String = "res://",
	extensions: Array[String] = DEFAULT_EXTENSIONS
) -> Array[String]:
	_cache_generation += 1  # 使进行中的后台扫描结果失效
	var words: Array[String] = []
	var seen: Dictionary = {}

	_collect_dir(path, extensions, words, seen)

	_cached_words = words
	_cache_dirty = false
	return words

## 在后台线程扫描项目（避免大项目同步扫描冻结编辑器 UI）
## 扫描完成后在主线程应用缓存并调用 callback(count)。若期间缓存又被置脏则丢弃结果。
func collect_from_directory_async(
	callback: Callable = Callable(),
	path: String = "res://",
	extensions: Array[String] = DEFAULT_EXTENSIONS
) -> void:
	if _scanning:
		return
	_scanning = true
	var gen := _cache_generation
	_scan_thread = Thread.new()
	_scan_thread.start(_scan_worker.bind(path, extensions, callback, gen))

func _scan_worker(path: String, extensions: Array[String], callback: Callable, gen: int) -> void:
	var words: Array[String] = []
	var seen: Dictionary = {}
	_collect_dir(path, extensions, words, seen)
	call_deferred("_on_scan_done", words, callback, gen)

func _on_scan_done(words: Array[String], callback: Callable, gen: int) -> void:
	if _scan_thread:
		_scan_thread.wait_to_finish()
		_scan_thread = null
	_scanning = false
	if gen != _cache_generation:
		return  # 扫描期间缓存又被置脏，结果已过时，丢弃
	_cached_words = words
	_cache_dirty = false
	if callback.is_valid():
		callback.call(words.size())

func _collect_dir(path: String, extensions: Array[String], words: Array, seen: Dictionary):
	var dir = DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var file_name = dir.get_next()

	while file_name != "":
		if file_name.begins_with(".") or file_name == "import":
			file_name = dir.get_next()
			continue

		var full_path = path.path_join(file_name)

		if dir.current_is_dir():
			# 跳过本插件自身目录，避免插件注释里的中文污染候选词
			if file_name == "pinyin_completion":
				file_name = dir.get_next()
				continue
			_collect_dir(full_path + "/", extensions, words, seen)
		else:
			var should_scan := false
			for ext in extensions:
				if file_name.to_lower().ends_with(ext):
					should_scan = true
					break
			if not should_scan:
				file_name = dir.get_next()
				continue

			var file = FileAccess.open(full_path, FileAccess.READ)
			if file == null:
				file_name = dir.get_next()
				continue

			# 只读取前 500KB 避免大文件问题
			var max_len = 500 * 1024
			var text_len = file.get_length()
			var text: String
			if text_len > max_len:
				text = file.get_as_text()
				text = text.substr(0, max_len)
			else:
				text = file.get_as_text()

			var line_words = extract_cjk_words(text)
			for w in line_words:
				if not seen.has(w) and w.length() >= 2:
					seen[w] = true
					words.append(w)

		file_name = dir.get_next()

	dir.list_dir_end()

## 获取缓存的词汇
func get_cached_words() -> Array[String]:
	if _cache_dirty:
		return []
	return _cached_words


