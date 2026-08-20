@tool
extends EditorPlugin
## Pinyin Completion 编辑器插件
##
## 在 Godot 脚本编辑器中提供拼音补全功能。
## 输入中文词汇的拼音时自动弹出中文补全候选项。
## 支持简拼、全拼、双拼等 10 种方案。
## 选中双拼方案时，简拼和全拼自动启用，两种格式都支持。

const PLUGIN_NAME := "Pinyin Completion"

## 拼音补全核心模块实例
var pinyin: PinyinCompletion = null

## 文本收集器实例
var collector: TextCollector = null

## 补全钩子（当前脚本编辑器的）
var _current_hook: CompletionHook = null

## 设置按钮（工具栏）
var _settings_btn: Button = null

## 扫描完成信号
signal scan_completed(count: int)

# ── 插件生命周期 ──────────────────────────────────────────────────

func _enter_tree():
	pinyin = PinyinCompletion.new()
	collector = TextCollector.new()

	# 从 ProjectSettings 加载配置
	_load_settings()

	# 添加设置按钮到编辑器工具栏
	_add_settings_button()

	# 连接到脚本编辑器的信号
	var se = get_editor_interface().get_script_editor()
	if se:
		se.editor_script_changed.connect(_on_script_changed)
		_on_script_changed()

	var fs = get_editor_interface().get_resource_filesystem()
	if fs:
		fs.filesystem_changed.connect(_on_filesystem_changed)

	call_deferred("_delayed_scan")
	print("[PinyinCompletion] Plugin initialized (v1.1.0)")

func _exit_tree():
	_remove_current_hook()
	_remove_settings_button()

	var se = get_editor_interface().get_script_editor()
	if se and se.editor_script_changed.is_connected(_on_script_changed):
		se.editor_script_changed.disconnect(_on_script_changed)

	var fs = get_editor_interface().get_resource_filesystem()
	if fs and fs.filesystem_changed.is_connected(_on_filesystem_changed):
		fs.filesystem_changed.disconnect(_on_filesystem_changed)

	print("[PinyinCompletion] Plugin disabled")

# ── 配置加载/保存 ─────────────────────────────────────────────────

func _load_settings():
	# 首次运行：注册设置与默认值
	var defaults := [
		["pinyin_completion/notation", ["简拼", "全拼"], {
			"name": "pinyin_completion/notation",
			"type": TYPE_PACKED_STRING_ARRAY,
			"hint": PROPERTY_HINT_TYPE_STRING,
			"hint_string": "简拼,全拼,带声调全拼,unicode,小鹤双拼,自然码双拼,微软双拼,abc双拼,加加双拼,华宇双拼"
		}],
		["pinyin_completion/min_query_len", 2, {
			"name": "pinyin_completion/min_query_len",
			"type": TYPE_INT,
			"hint": PROPERTY_HINT_RANGE,
			"hint_string": "1,10,1"
		}],
		["pinyin_completion/max_candidates", 300, {
			"name": "pinyin_completion/max_candidates",
			"type": TYPE_INT,
			"hint": PROPERTY_HINT_RANGE,
			"hint_string": "10,1000,10"
		}],
	]
	for entry in defaults:
		var key: String = entry[0]
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, entry[1])
			ProjectSettings.set_initial_value(key, entry[1])
			ProjectSettings.add_property_info(entry[2])

	# 加载到 pinyin 模块
	if pinyin:
		var saved_notation = ProjectSettings.get_setting("pinyin_completion/notation", ["简拼", "全拼"])
		if saved_notation is Array or saved_notation is PackedStringArray:
			var tmp: Array[String] = []
			for s in saved_notation:
				tmp.append(s)
			pinyin.notation = tmp

		var saved_min = ProjectSettings.get_setting("pinyin_completion/min_query_len", 2)
		if saved_min is int:
			pinyin.min_query_len = saved_min

		var saved_max = ProjectSettings.get_setting("pinyin_completion/max_candidates", 300)
		if saved_max is int:
			pinyin.max_candidates = saved_max

# ── 设置按钮 ─────────────────────────────────────────────────────

func _add_settings_button():
	_settings_btn = Button.new()
	_settings_btn.text = "拼音"
	_settings_btn.flat = true
	_settings_btn.tooltip_text = "拼音补全设置"
	_settings_btn.pressed.connect(_open_settings)
	# 添加到编辑器工具栏
	add_control_to_container(EditorPlugin.CONTAINER_TOOLBAR, _settings_btn)

func _remove_settings_button():
	if _settings_btn:
		remove_control_from_container(EditorPlugin.CONTAINER_TOOLBAR, _settings_btn)
		_settings_btn.queue_free()
		_settings_btn = null

func _open_settings():
	# 创建设置弹窗
	var popup = AcceptDialog.new()
	popup.title = "Pinyin Completion 设置"
	popup.min_size = Vector2(420, 420)

	var vbox := VBoxContainer.new()
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0

	# 标题
	var title := Label.new()
	title.text = "拼音方案（可多选，按顺序尝试）"
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color(0.8, 0.8, 1.0))
	vbox.add_child(title)

	# 全部 10 种拼音方案
	var all_schemes := [
		"简拼", "全拼", "带声调全拼", "unicode",
		"小鹤双拼", "自然码双拼", "微软双拼",
		"abc双拼", "加加双拼", "华宇双拼",
	]

	var checkboxes: Dictionary = {}
	for nname in all_schemes:
		var hbox := HBoxContainer.new()
		var cb := CheckBox.new()
		cb.text = nname
		cb.tooltip_text = PinyinCompletion.NOTATION_DESC.get(nname, "")
		cb.button_pressed = nname in pinyin.notation
		checkboxes[nname] = cb
		hbox.add_child(cb)

		var desc := Label.new()
		desc.text = PinyinCompletion.NOTATION_DESC.get(nname, "")
		desc.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		hbox.add_child(desc)
		vbox.add_child(hbox)

	# 提示
	var tip := Label.new()
	tip.text = "提示：选中双拼方案后，简拼+全拼自动补充，\n三种格式（简拼/全拼/双拼）同时支持。"
	tip.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0))
	tip.add_theme_font_size_override("font_size", 11)
	vbox.add_child(tip)

	# 分隔
	vbox.add_child(HSeparator.new())

	# 最小查询长度
	var min_hbox := HBoxContainer.new()
	var min_label := Label.new()
	min_label.text = "最小查询长度: "
	min_hbox.add_child(min_label)
	var min_spin := SpinBox.new()
	min_spin.min_value = 1
	min_spin.max_value = 10
	min_spin.value = pinyin.min_query_len
	min_hbox.add_child(min_spin)
	vbox.add_child(min_hbox)

	# 最大候选词数
	var max_hbox := HBoxContainer.new()
	var max_label := Label.new()
	max_label.text = "最大候选词数: "
	max_hbox.add_child(max_label)
	var max_spin := SpinBox.new()
	max_spin.min_value = 10
	max_spin.max_value = 1000
	max_spin.step = 10
	max_spin.value = pinyin.max_candidates
	max_hbox.add_child(max_spin)
	vbox.add_child(max_hbox)

	# 按钮行
	var btn_hbox := HBoxContainer.new()
	btn_hbox.add_spacer(true)

	var save_btn := Button.new()
	save_btn.text = "保存"
	save_btn.pressed.connect(func():
		# 收集选中的方案
		var selected: Array[String] = []
		for nname in checkboxes:
			if checkboxes[nname].button_pressed:
				selected.append(nname)
		if selected.is_empty():
			selected = ["简拼", "全拼"]

		# 保存到 ProjectSettings
		ProjectSettings.set_setting("pinyin_completion/notation", selected)
		ProjectSettings.set_setting("pinyin_completion/min_query_len", int(min_spin.value))
		ProjectSettings.set_setting("pinyin_completion/max_candidates", int(max_spin.value))
		ProjectSettings.save()

		# 应用到当前实例
		pinyin.notation = selected
		pinyin.min_query_len = int(min_spin.value)
		pinyin.max_candidates = int(max_spin.value)
		pinyin.invalidate_candidates()
		if _current_hook:
			_current_hook.min_query_len = int(min_spin.value)
			_current_hook.pinyin_completion = pinyin

		popup.queue_free()
		print("[PinyinCompletion] Settings saved: notation=", selected, " min_len=", int(min_spin.value))
	)
	btn_hbox.add_child(save_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "取消"
	cancel_btn.pressed.connect(func():
		popup.queue_free()
	)
	btn_hbox.add_child(cancel_btn)

	vbox.add_child(HSeparator.new())
	vbox.add_child(btn_hbox)

	popup.add_child(vbox)
	popup.get_ok_button().hide()  # 自定义保存/取消按钮，隐藏内置 OK
	popup.close_requested.connect(popup.queue_free)
	popup.canceled.connect(popup.queue_free)
	get_editor_interface().get_base_control().add_child(popup)
	popup.popup_centered()

# ── 脚本编辑切换 ─────────────────────────────────────────────────

func _on_script_changed(_script = null):
	_remove_current_hook()

	var se = get_editor_interface().get_script_editor()
	var current_script = se.get_current_script()
	if current_script == null:
		return

	var current_editor = se.get_current_editor()
	var code_edit: CodeEdit = null

	if current_editor:
		code_edit = _find_code_edit(current_editor)
	if code_edit == null:
		code_edit = _find_code_edit(se)
	if code_edit == null:
		return

	_current_hook = CompletionHook.new()
	_current_hook.pinyin_completion = pinyin
	_current_hook.text_collector = collector
	_current_hook.min_query_len = pinyin.min_query_len

	code_edit.add_child(_current_hook)
	_current_hook.set_code_edit(code_edit)

func _remove_current_hook():
	if _current_hook and _current_hook.get_parent():
		_current_hook.get_parent().remove_child(_current_hook)
		_current_hook.queue_free()
	_current_hook = null

func _find_code_edit(node: Node) -> CodeEdit:
	if node is CodeEdit:
		return node
	for child in node.get_children():
		var result = _find_code_edit(child)
		if result:
			return result
	return null

func _on_filesystem_changed():
	if collector:
		collector.invalidate_cache()
	if pinyin:
		pinyin.invalidate_candidates()

func _delayed_scan():
	if collector:
		collector.collect_from_directory_async(func(count: int):
			print("[PinyinCompletion] Prescan: ", count, " CJK words")
		)

func scan_project() -> int:
	if collector == null:
		return 0
	var words = collector.collect_from_directory()
	if pinyin:
		pinyin.invalidate_candidates()
	print("[PinyinCompletion] Scanned project: found ", words.size(), " CJK words")
	scan_completed.emit(words.size())
	return words.size()

func get_stats() -> Dictionary:
	var desc: Array[String] = []
	if pinyin:
		for n in pinyin.notation:
			desc.append(PinyinCompletion.NOTATION_DESC.get(n, n))
	return {
		"cached_words": collector.get_cached_words().size() if collector else 0,
		"cli_available": pinyin._cli_available if pinyin else false,
		"notation": pinyin.notation.duplicate() if pinyin else [],
		"min_query_len": pinyin.min_query_len if pinyin else 2,
		"notation_desc": desc,
	}
