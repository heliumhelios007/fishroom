extends PanelContainer
## Local memory service only. This view never creates a diary itself.
var client: Node
var content: VBoxContainer
var status_label: Label
var _view_version := 0

func _ready() -> void:
	name = "DiaryPanel"
	position = Vector2(20, 74)
	size = Vector2(365, 572)
	theme = preload("res://assets/ui/theme/game_theme.tres")
	add_theme_stylebox_override("panel", _panel_style())
	var margin := MarginContainer.new()
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 16)
	add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)
	var heading := HBoxContainer.new()
	box.add_child(heading)
	var title := Label.new()
	title.text = "每日日记"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", Color("2c4b63"))
	title.add_theme_font_size_override("font_size", 20)
	heading.add_child(title)
	var close := Button.new()
	close.text = "×"
	_style_button(close)
	close.pressed.connect(func(): queue_free())
	heading.add_child(close)
	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_color_override("font_color", Color("718aa4"))
	box.add_child(status_label)
	var connect_button := Button.new()
	connect_button.text = "DSH 连接设置"
	_style_button(connect_button)
	connect_button.pressed.connect(_connection_form)
	box.add_child(connect_button)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)
	content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	scroll.add_child(content)
	show_list()

func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("f9fcff")
	style.border_color = Color("cfe3f0")
	style.set_border_width_all(1)
	style.corner_radius_top_left = 20
	style.corner_radius_top_right = 20
	style.corner_radius_bottom_left = 20
	style.corner_radius_bottom_right = 20
	style.shadow_color = Color(0, 0, 0, 0.18)
	style.shadow_size = 12
	return style


func _button_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	style.corner_radius_bottom_left = 10
	style.corner_radius_bottom_right = 10
	return style


func _style_button(button: Button) -> void:
	button.add_theme_stylebox_override("normal", _button_style(Color("eaf4fb")))
	button.add_theme_stylebox_override("hover", _button_style(Color("dbeeff")))
	button.add_theme_stylebox_override("pressed", _button_style(Color("c9e4ff")))
	button.add_theme_stylebox_override("disabled", _button_style(Color("edf3f7")))
	button.add_theme_color_override("font_color", Color("2c4b63"))
	button.add_theme_color_override("font_hover_color", Color("1f3b52"))
	button.add_theme_color_override("font_pressed_color", Color("1f3b52"))


func _clear() -> void:
	_view_version += 1
	for child in content.get_children():
		content.remove_child(child)
		child.queue_free()

func _text(value: String) -> void:
	var label := Label.new()
	label.text = value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", Color("2c4b63"))
	content.add_child(label)

func _button(text: String, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 36
	_style_button(button)
	button.pressed.connect(action)
	content.add_child(button)

func show_list() -> void:
	_clear()
	var version := _view_version
	status_label.text = "正在读取日记…"
	var data: Dictionary = await client.get_local("/diary/list", true)
	if not is_inside_tree() or version != _view_version:
		return
	if not data.has("entries"):
		status_label.text = "日记服务未连接"
		_button("重试", show_list)
		return
	status_label.text = "每天 22:00 · Asia/Shanghai · 仅存本机"
	if data["entries"].is_empty():
		_text("暂无日记。有当天事件后，将在 22:00 等待已接入的 DSH 写下日记。")
	for entry in data["entries"]:
		var state := _state_text(entry)
		_button("%s  %s  %s" % [entry["date"], entry.get("title", ""), state], _detail.bind(str(entry["date"])))
	_button("重要回忆包", _inheritance)
	_button("刷新", show_list)

func _state_text(entry: Dictionary) -> String:
	if entry.get("status") == "generated":
		return ""
	var error := str(entry.get("last_error", ""))
	if error.begins_with("DSH_"):
		return "未接入 DSH / 暂时不可用"
	if error.begins_with("DIARY_UNSUPPORTED_") or error == "DIARY_DIGEST_UNSUPPORTED":
		return "等待可用日摘要 · 证据不足"
	if not error.is_empty():
		return "格式 / 长度校验失败 · 将重试"
	return "等待可用日摘要"

func _detail(date: String) -> void:
	_clear()
	var version := _view_version
	var entry: Dictionary = await client.get_local("/diary/" + date, true)
	if not is_inside_tree() or version != _view_version:
		return
	if entry.is_empty():
		_text("日记服务未连接")
	else:
		_text(date + "  " + str(entry.get("title", "")))
		_text(_state_text(entry))
		if entry.get("status") == "generated":
			_text(str(entry.get("body", "")))
			for memory in entry.get("memories", []):
				_text("回忆 · " + str(memory.get("summary", "")))
			var legacy: Dictionary = entry.get("continuity") if entry.get("continuity") is Dictionary else {}
			for item in entry.get("unresolved", legacy.get("unresolved", [])):
				_text("未解决 · " + str(item))
	_button("返回日期列表", show_list)

func _inheritance() -> void:
	_clear()
	var version := _view_version
	status_label.text = "回忆包 · 仅存本机"
	var data: Dictionary = await client.get_local("/diary/inheritance", true)
	if not is_inside_tree() or version != _view_version:
		return
	_text(str(data.get("text", "回忆服务未连接")))
	_button("返回日期列表", show_list)

func _field(caption: String, value: String) -> LineEdit:
	_text(caption)
	var field := LineEdit.new()
	field.text = value
	content.add_child(field)
	return field

func _connection_form() -> void:
	_clear()
	var version := _view_version
	var config: Dictionary = await client.get_local("/connection/config")
	if not is_inside_tree() or version != _view_version:
		return
	status_label.text = "选择你自己的 DSH 人格；可手填 preset ID"
	var url := _field("DSH 本机 URL", str(config.get("base_url", "http://127.0.0.1:51936")))
	var game := _field("游戏 / 旅行信件 preset ID（无工具）", str(config.get("game_preset", "")))
	var qq := _field("QQ preset ID（发送 / 表情工具）", str(config.get("qq_preset", "")))
	var diary := _field("日记 preset ID（无工具 / 无 runtime context）", str(config.get("diary_preset", "")))
	if config.has("warnings"):
		status_label.text = "旧单 preset：请逐通道确认并重新测试保存"
	var display := _field("显示名（可选）", str(config.get("display_name", "")))
	_button("读取可用 preset", func():
		var result: Dictionary = await client.post("/connection/presets", {"base_url":url.text})
		if not is_instance_valid(game):
			return
		var choices: Array = result.get("data", {}).get("presets", [])
		if choices.is_empty():
			status_label.text = "无法列出 preset，请手填 ID 后连接测试"
		for item in choices:
			for field in [["游戏", game], ["QQ", qq], ["日记", diary]]:
				var target: LineEdit = field[1]
				_button(str(field[0]) + " ← " + str(item.get("name", item["id"])), func(): target.text = str(item["id"]))
	)
	_button("连接测试并保存", func():
		var result: Dictionary = await client.post("/connection", {"base_url":url.text,"game_preset":game.text,"qq_preset":qq.text,"diary_preset":diary.text,"display_name":display.text})
		if is_inside_tree():
			status_label.text = "三通道人格及工具校验通过" if result.get("ok", false) else "未接入 DSH · 连接测试失败"
		await client.refresh_connection()
	)
	_button("断开 DSH", func():
		await client.post("/connection", {"enabled":false})
		await client.refresh_connection()
		if is_inside_tree():
			status_label.text = "未接入 DSH"
	)
	_button("返回日记", show_list)
