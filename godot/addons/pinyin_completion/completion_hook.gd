class_name CompletionHook
extends Node
## 拼音补全钩子
##
## 挂载到 CodeEdit 节点上，提供拼音补全功能。
## 自动检测用户输入的 ASCII 字母，匹配合适的中文候选项。
## 函数补全行为和 Godot 默认一致：有参数时光标在括号内。

## 引用的拼音补全核心模块
var pinyin_completion: PinyinCompletion = null

## 引用的文本收集器
var text_collector: TextCollector = null

## 最小查询长度
var min_query_len: int = 2

## 附加的候选词（可手动添加）
var extra_candidates: Array[String] = []

## 按键防抖时长：连续输入拼音时只触发一次 CLI 匹配
const DEBOUNCE_SECONDS := 0.18

# 内部状态
var _code_edit: CodeEdit = null
var _last_query: String = ""
var _connected: bool = false
var _debounce_timer: Timer = null
var _pending_query: String = ""

# ── 符号缓存 ──────────────────────────────────────────────────────────
var _func_cache: Dictionary = {}  # name → {params, param_str, param_count}
var _var_cache: Dictionary = {}  # name → true
var _func_scan_line_count: int = -1  # 上次扫描时的脚本行数

func _ready():
	_code_edit = get_parent() if get_parent() is CodeEdit else null
	if _code_edit == null:
		_code_edit = owner if owner is CodeEdit else null

func set_code_edit(ce: CodeEdit):
	_code_edit = ce
	if _code_edit:
		_setup_code_edit()

func _setup_code_edit():
	if _connected:
		return
	_code_edit.code_completion_requested.connect(_on_completion_requested)
	_code_edit.text_changed.connect(_on_text_changed)

	if _debounce_timer == null:
		_debounce_timer = Timer.new()
		_debounce_timer.one_shot = true
		_debounce_timer.wait_time = DEBOUNCE_SECONDS
		_debounce_timer.timeout.connect(_on_debounce_timeout)
		add_child(_debounce_timer)

	_connected = true

	if pinyin_completion == null:
		pinyin_completion = PinyinCompletion.new()
	if text_collector == null:
		text_collector = TextCollector.new()

# ── 信号处理 ──────────────────────────────────────────────────────────

func _on_text_changed():
	if _code_edit == null or _debounce_timer == null or not _debounce_timer.is_inside_tree():
		return

	var caret = _code_edit.get_caret_column()
	var line = _code_edit.get_line(_code_edit.get_caret_line())
	var query = _get_prefix_query(line, caret)

	if query.length() < min_query_len:
		_last_query = ""
		_pending_query = ""
		_debounce_timer.stop()
		return
	if query == _last_query:
		return
	_last_query = query
	_pending_query = query
	_debounce_timer.start()

func _on_debounce_timeout():
	var query := _pending_query
	_pending_query = ""
	if query.is_empty() or _code_edit == null:
		return
	# 确认用户光标处仍是同一前缀再触发
	var caret = _code_edit.get_caret_column()
	var line = _code_edit.get_line(_code_edit.get_caret_line())
	if _get_prefix_query(line, caret) == query:
		_trigger_completion(query)

func _on_completion_requested():
	if _code_edit == null or _debounce_timer == null:
		return
	var caret = _code_edit.get_caret_column()
	var line = _code_edit.get_line(_code_edit.get_caret_line())
	var query = _get_prefix_query(line, caret)
	if query.length() >= min_query_len:
		_last_query = query
		_pending_query = ""
		_debounce_timer.stop()
		_trigger_completion(query)

# ── 查询提取 ──────────────────────────────────────────────────────────

func _get_prefix_query(line: String, caret_col: int) -> String:
	var end_pos = min(caret_col, line.length())
	var start = end_pos
	while start > 0:
		var ch = line[start - 1]
		if (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z'):
			start -= 1
		else:
			break
	return line.substr(start, end_pos - start).to_lower()

# ── 补全触发 ──────────────────────────────────────────────────────────

func _trigger_completion(query: String):
	if _code_edit == null:
		return

	var candidates = _collect_candidates()
	if candidates.is_empty():
		return

	var results = pinyin_completion.match(query, candidates)
	if results.is_empty():
		return

	# 函数/变量缓存：脚本行数变化时才重扫（新增/删除函数必然改变行数）
	# ponytail: 行数不变时原地改签名的场景不重扫；编辑时用户可直接 Ctrl+Space 手动刷新
	var line_count = _code_edit.get_line_count()
	if line_count != _func_scan_line_count:
		_collect_function_details()
		_func_scan_line_count = line_count

	if _code_edit.has_method("clear_code_completion_options"):
		_code_edit.clear_code_completion_options()

	for r in results:
		var info = _func_cache.get(r.word)
		var is_func = info != null
		var insert_text: String
		var display_sig: String

		if is_func and info.param_count > 0:
			insert_text = r.word + "("
			display_sig = r.word + "(" + info.param_str + ")"
		elif is_func:
			insert_text = r.word + "()"
			display_sig = r.word + "()"
		else:
			insert_text = r.word
			display_sig = r.word

		var kind = CodeEdit.KIND_FUNCTION if is_func else (CodeEdit.KIND_VARIABLE if _var_cache.has(r.word) else CodeEdit.KIND_MEMBER)
		var display = display_sig + " (" + query + ")"
		# Godot 4.6: 第4参数是颜色（字体色），不是图标
		var color = Color(0.3, 0.6, 1.0) if is_func else (Color(0.4, 0.9, 0.5) if _var_cache.has(r.word) else Color(0.9, 0.6, 0.3))
		_code_edit.add_code_completion_option(kind, display, insert_text, color)

	if _code_edit.has_method("update_code_completion"):
		_code_edit.update_code_completion(true)

# ── 函数签名解析 ──────────────────────────────────────────────────────

## 扫描当前脚本的所有函数签名和变量名
## 返回 { 函数名: {params, param_str, param_count} }
func _collect_function_details() -> Dictionary:
	_var_cache = {}
	_func_cache = {}
	var result: Dictionary = _func_cache
	if _code_edit == null:
		return result

	var line_count = _code_edit.get_line_count()
	for i in range(line_count):
		var raw = _code_edit.get_line(i)
		var line = raw.strip_edges()

		# 扫描 var 声明
		if line.begins_with("var "):
			var rest = line.substr(4).strip_edges()
			var vname = ""
			for ch in rest:
				if ch == ' ' or ch == ':' or ch == '=' or ch == '(':
					break
				vname += ch
			if vname.length() >= 2:
				_var_cache[vname] = true

		# 扫描 func 声明
		var func_pos = line.find("func ")
		if func_pos < 0:
			continue

		var rest = line.substr(func_pos + 5).strip_edges()
		var paren_open = rest.find("(")
		if paren_open < 0:
			continue

		var fname = rest.substr(0, paren_open).strip_edges()
		if fname.is_empty():
			continue

		var paren_close = _find_matching_paren(rest, paren_open)
		var params_str = ""
		if paren_close > paren_open + 1:
			params_str = rest.substr(paren_open + 1, paren_close - paren_open - 1).strip_edges()

		var params: Array[Dictionary] = []
		if not params_str.is_empty():
			for p in _split_params(params_str):
				p = p.strip_edges()
				if p.is_empty():
					continue
				var parts = p.split(":")
				var pname = parts[0].strip_edges()
				var has_type = parts.size() > 1 and not parts[1].strip_edges().is_empty()
				params.append({"name": pname, "has_type": has_type})

		var param_str_builder := ""
		for pi in range(params.size()):
			if pi > 0:
				param_str_builder += ", "
			var p = params[pi]
			if p.has_type:
				param_str_builder += p.name + ": " + _extract_type(params_str, p.name)
			else:
				param_str_builder += p.name

		result[fname] = {
			"params": params,
			"param_str": param_str_builder,
			"param_count": params.size()
		}

	return result

func _find_matching_paren(s: String, open_pos: int) -> int:
	var depth = 1
	var i = open_pos + 1
	while i < s.length() and depth > 0:
		if s[i] == "(":
			depth += 1
		elif s[i] == ")":
			depth -= 1
		i += 1
	return i - 1 if depth == 0 else -1

func _split_params(s: String) -> Array[String]:
	var parts: Array[String] = []
	var depth = 0
	var current = ""
	for i in range(s.length()):
		var c = s[i]
		if c == "(" or c == "<":
			depth += 1
			current += c
		elif c == ")" or c == ">":
			depth -= 1
			current += c
		elif c == "," and depth == 0:
			parts.append(current)
			current = ""
		else:
			current += c
	if not current.strip_edges().is_empty():
		parts.append(current)
	return parts

func _extract_type(params_str: String, pname: String) -> String:
	var idx = params_str.find(pname + ":")
	if idx < 0:
		return ""
	var after = params_str.substr(idx + pname.length() + 1).strip_edges()
	var end = after.find(",")
	if end < 0:
		return after.strip_edges()
	return after.substr(0, end).strip_edges()

# ── 候选词收集 ───────────────────────────────────────────────────────

func _collect_candidates() -> Array[String]:
	var words: Array[String] = []

	if text_collector:
		if text_collector.is_dirty():
			# 缓存过期：后台重建，本次不返回候选（下次按键即有结果）
			text_collector.collect_from_directory_async()
		else:
			words.append_array(text_collector.get_cached_words())

	for w in extra_candidates:
		if not words.has(w):
			words.append(w)

	if words.size() > pinyin_completion.max_candidates:
		words.resize(pinyin_completion.max_candidates)

	return words
