extends CanvasLayer
## 开发者调试面板：只在 debug 构建里出现。
## F12 或左下角 DEV 按钮打开；可改鲸元券、推进模拟时间（测试旅行信/饥饿等）。
## 不改变正式玩法规则，正式发布构建直接 queue_free。

var _root: Control
var _overlay: Control
var _balance_label: Label
var _time_label: Label
var _status: Label
var _currency_input: LineEdit
var _hours_input: LineEdit


func _ready() -> void:
	if not OS.is_debug_build() or OS.has_feature("android") or OS.has_feature("fishroom_clean"):
		queue_free()
		return
	# 调试运行时确保有可见窗口：godot_run_project 的宿主可能以隐藏窗口启动。
	if DisplayServer.get_name() != "headless":
		get_window().show()
		get_window().move_to_foreground()
	_build()
	GameState.currency_changed.connect(_on_currency_changed)
	GameState.stats_changed.connect(_refresh_time)
	_refresh_all()
	set_process_input(true)


func _build() -> void:
	var theme: Theme = load("res://assets/ui/theme/game_theme.tres")
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = theme
	add_child(_root)

	var dev_button := Button.new()
	dev_button.text = "DEV"
	dev_button.position = Vector2(16, 66)
	dev_button.size = Vector2(48, 22)
	dev_button.focus_mode = Control.FOCUS_NONE
	dev_button.pressed.connect(toggle)
	_root.add_child(dev_button)

	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.visible = false
	_root.add_child(_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.05, 0.1, 0.52)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.add_child(dim)

	var panel := PanelContainer.new()
	panel.position = Vector2(52, 102)
	panel.size = Vector2(300, 470)
	var style := StyleBoxFlat.new()
	style.bg_color = Color("f3f8ff")
	style.set_corner_radius_all(16)
	style.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", style)
	_overlay.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	var title := Label.new()
	title.text = "开发者调试"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color("16273b"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close := Button.new()
	close.text = "×"
	close.custom_minimum_size = Vector2(32, 30)
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(toggle)
	header.add_child(close)

	_balance_label = _label("鲸元券：%d" % GameState.get_currency(), 14, Color("24425e"))
	box.add_child(_balance_label)

	var currency_row := HBoxContainer.new()
	currency_row.add_theme_constant_override("separation", 6)
	box.add_child(currency_row)
	_currency_input = LineEdit.new()
	_currency_input.placeholder_text = "输入余额"
	_currency_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_currency_input.custom_minimum_size = Vector2(0, 32)
	_currency_input.add_theme_font_size_override("font_size", 13)
	currency_row.add_child(_currency_input)
	var set_button := Button.new()
	set_button.text = "设为"
	set_button.custom_minimum_size = Vector2(54, 32)
	set_button.focus_mode = Control.FOCUS_NONE
	set_button.pressed.connect(_on_set_currency)
	currency_row.add_child(set_button)

	var quick := HBoxContainer.new()
	quick.add_theme_constant_override("separation", 6)
	box.add_child(quick)
	for amount in [100, 1000, -100]:
		var button := Button.new()
		button.text = "%+d" % amount
		button.custom_minimum_size = Vector2(84, 30)
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_on_add_currency.bind(amount))
		quick.add_child(button)

	var divider := HSeparator.new()
	box.add_child(divider)

	_time_label = _label("模拟时间：—", 12, Color("3d5a74"))
	box.add_child(_time_label)

	var time_row := HBoxContainer.new()
	time_row.add_theme_constant_override("separation", 4)
	box.add_child(time_row)
	for item in [[1, "+1时"], [2, "+2时"], [6, "+6时"], [24, "+1天"]]:
		var button := Button.new()
		button.text = item[1]
		button.custom_minimum_size = Vector2(64, 30)
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_on_advance_hours.bind(int(item[0])))
		time_row.add_child(button)

	var custom_row := HBoxContainer.new()
	custom_row.add_theme_constant_override("separation", 6)
	box.add_child(custom_row)
	_hours_input = LineEdit.new()
	_hours_input.placeholder_text = "自定义小时"
	_hours_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hours_input.custom_minimum_size = Vector2(0, 30)
	_hours_input.add_theme_font_size_override("font_size", 13)
	custom_row.add_child(_hours_input)
	var advance := Button.new()
	advance.text = "推进"
	advance.custom_minimum_size = Vector2(58, 30)
	advance.focus_mode = Control.FOCUS_NONE
	advance.pressed.connect(_on_custom_hours)
	custom_row.add_child(advance)

	var reset := Button.new()
	reset.text = "把模拟基线拉回现在（不回滚已结算）"
	reset.custom_minimum_size = Vector2(0, 28)
	reset.focus_mode = Control.FOCUS_NONE
	reset.add_theme_font_size_override("font_size", 11)
	reset.pressed.connect(_on_reset_time)
	box.add_child(reset)

	_status = _label("F12 或 DEV 关闭；调试改动会写入当前存档。", 11, Color("6b8094"))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)

	var note := _label("家具购买已实现，可买家具并即时摆放。\n旅行信：先买票出发，推进旅行时间测试来信。", 11, Color("718aa4"))
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(note)


func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F12:
		toggle()
		get_viewport().set_input_as_handled()


func toggle() -> void:
	_overlay.visible = not _overlay.visible
	if _overlay.visible:
		_refresh_all()


func _refresh_all() -> void:
	_refresh_balance()
	_refresh_time()


func _refresh_balance() -> void:
	if is_instance_valid(_balance_label):
		_balance_label.text = "鲸元券：%d" % GameState.get_currency()
		if is_instance_valid(_currency_input) and not _currency_input.has_focus():
			_currency_input.text = str(GameState.get_currency())


func _refresh_time() -> void:
	if not is_instance_valid(_time_label):
		return
	var sim := GameState.last_sim_time
	_time_label.text = "模拟时间：%s" % (sim if not sim.is_empty() else "未记录")


func _on_currency_changed(_value: int) -> void:
	_refresh_balance()


func _on_set_currency() -> void:
	var value := int(_currency_input.text.strip_edges()) if _currency_input.text.strip_edges().is_valid_int() else -1
	if value < 0:
		_status.text = "请输入非负整数余额。"
		return
	GameState.debug_set_currency(value)
	_status.text = "已设置鲸元券为 %d。" % GameState.get_currency()
	_refresh_all()


func _on_add_currency(amount: int) -> void:
	GameState.debug_set_currency(GameState.get_currency() + amount)
	_status.text = "鲸元券 %+d，当前 %d。" % [amount, GameState.get_currency()]
	_refresh_all()


func _on_advance_hours(hours: int) -> void:
	_advance(hours)


func _on_custom_hours() -> void:
	var text := _hours_input.text.strip_edges()
	if not text.is_valid_int() or int(text) <= 0:
		_status.text = "请输入正的小时数。"
		return
	_advance(int(text))


func _advance(hours: int) -> void:
	var before := GameState.last_sim_time
	var after := GameState.debug_advance_time(hours * 3600)
	if after == before and hours > 0:
		_status.text = "推进失败：模拟正忙或时间无效。"
	else:
		_status.text = "已推进 %d 小时；旅行信/饥饿按规则结算。" % hours
	_refresh_time()


func _on_reset_time() -> void:
	GameState.debug_reset_sim_to_now()
	_status.text = "模拟基线已拉回当前时间；已结算的旅行/事件不回滚。"
	_refresh_time()
