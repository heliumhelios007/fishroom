extends CanvasLayer
## fishroom — 常驻 UI / 日历 / 商店背包 / 旅行相簿 / 用户发起的 DS 聊天
##
## 尺寸全部按设计分辨率 405×720 写死（窗口 540×960 由项目 stretch 放大 4/3），
## 所以这里用固定 px 而不是按屏宽换算：135px 的条正好是屏宽的 1/3。
## 打卡/商店/背包/聊天/旅行/相簿/设置接真实页面；日记保留占位提示。
##
## 结构（scenes/ui/game_ui.tscn）：
##   Root           全屏 Control，mouse_filter=IGNORE，保证房间拖动不被 UI 吃掉
##   ├─ TopLeft     左上：饥饿/口渴 两条 135×6 的圆角条（监听真实状态）
##   ├─ MenuButton  右上：32×32 圆角按钮（三条线占位图标）
##   ├─ MenuPanel   下拉面板 180×360：钱包头（鲸元券图标 + 余额）+ 8 项 + ×
##   └─ Toast       底部占位提示，自动淡出
##
## 钱包图标缩放：assets/ui/currency/whale_bill_icon.png 原图 64×34，
## 场景里用 22×12 的 TextureRect + expand_mode=IGNORE_SIZE + stretch_mode=KEEP_ASPECT_CENTERED，
## 实际绘制约 22×11.7，保持 64:34 比例不拉扁；换更清晰的币种图时只改这两个值。

## 菜单顺序是 docs/UI_AND_SYSTEMS.md 定的：
## 打卡 / 商店 / 旅行 / 聊天 / 日记 / 背包 / 相簿 / 设置。
## 不要改成字母序或按功能分组；后续阶段按这个顺序逐项接真页面。
## 单字只是图标占位（打/商/旅/聊/日/包/相/设），正式图标以后替换。
const MENU_ITEMS := [
	{"icon": "打", "label": "打卡"},
	{"icon": "商", "label": "商店"},
	{"icon": "旅", "label": "旅行"},
	{"icon": "聊", "label": "聊天"},
	{"icon": "日", "label": "日记"},
	{"icon": "包", "label": "背包"},
	{"icon": "相", "label": "相簿"},
	{"icon": "设", "label": "设置"},
]

## 每项 38px（规范要求 38–44）：8 项 304px，加上钱包头/分隔线仍塞得进 360px 面板。
const ITEM_HEIGHT := 38
const TOAST_HOLD_SECONDS := 1.6
const TOAST_FADE_SECONDS := 0.35
const MENU_FADE_SECONDS := 0.12
## 面板打开时从右上角"向下弹出"：只动 alpha + 纵向缩放，不改锚点/position，
## 避免和固定的 405×720 布局打架（pivot 在 tscn 里设成右上角 (180,0)）。
const MENU_POP_SECONDS := 0.18

# 浅色面板 + 深蓝字，和房间的蓝紫色调一致。
const COLOR_BALANCE := Color(0.086, 0.145, 0.227)
const COLOR_ITEM_TEXT := Color(0.133, 0.204, 0.294)
const COLOR_ICON_TEXT := Color(0.184, 0.424, 0.62)
const COLOR_CHIP_BG := Color(0.894, 0.937, 0.988)
const COLOR_ROW_HOVER := Color(0.898, 0.937, 0.988)
const COLOR_ROW_PRESSED := Color(0.851, 0.902, 0.973)
const COLOR_TRANSPARENT := Color(0, 0, 0, 0)
const CheckinDates := preload("res://scripts/game_state.gd")
const COLOR_CHECKED := Color("d84b5f")
const COLOR_TODAY := Color("3986c9")

@onready var _hunger_bar: ProgressBar = $Root/TopLeft/HungerRow/HungerBar
@onready var _thirst_bar: ProgressBar = $Root/TopLeft/ThirstRow/ThirstBar
@onready var _menu_button: Button = $Root/MenuButton
@onready var _menu_panel: PanelContainer = $Root/MenuPanel
@onready var _balance_label: Label = $Root/MenuPanel/VBox/Header/BalanceLabel
@onready var _close_button: Button = $Root/MenuPanel/VBox/Header/CloseButton
@onready var _items_box: VBoxContainer = $Root/MenuPanel/VBox/Items
@onready var _toast: PanelContainer = $Root/Toast
@onready var _toast_label: Label = $Root/Toast/ToastLabel
@onready var _calendar: Control = $Root/CalendarOverlay
@onready var _month_label: Label = $Root/CalendarOverlay/CalendarPanel/MonthLabel
@onready var _month_count: Label = $Root/CalendarOverlay/CalendarPanel/MonthCount
@onready var _date_grid: GridContainer = $Root/CalendarOverlay/CalendarPanel/DateGrid
@onready var _streak_label: Label = $Root/CalendarOverlay/CalendarPanel/StreakLabel
@onready var _checkin_button: Button = $Root/CalendarOverlay/CalendarPanel/CheckinButton
@onready var _checkin_text: Label = $Root/CalendarOverlay/CalendarPanel/CheckinButton/Content/Caption
@onready var _feedback: Label = $Root/CalendarOverlay/CalendarPanel/Feedback/Message
@onready var _shop: Control = $Root/ShopOverlay
@onready var _backpack: Control = $Root/BackpackOverlay
@onready var _chat: Control = $Root/ChatOverlay
@onready var _settings: Control = $Root/SettingsOverlay
var _settings_feedback: Label
var _export_dialog: FileDialog
var _import_dialog: FileDialog
var _import_confirmation: Control
var _pending_import_text := ""
var _content_dialog: FileDialog
var _runtime_dialog: AcceptDialog

const BILL_ICON := preload("res://assets/ui/currency/whale_bill_icon.png")
var _shop_balance: Label
var _backpack_balance: Label
var _shop_content: VBoxContainer
var _backpack_content: VBoxContainer
var _shop_feedback: Label
var _tabs: Array[Button] = []
var _active_tab := "家具"
var _confirmation: Control
var _confirm_button: Button
var _confirm_balance: Label
var _confirm_feedback: Label
var _pending_location := ""
var _pending_seat := ""
var _food_counts: Dictionary = {}
var _food_icons: Dictionary = {}
var _food_confirmation: Control
var _pending_food := ""
var _food_quantity := 1
var _food_quantity_label: Label
var _food_total: Label
var _food_balance: Label
var _food_feedback: Label
var _food_minus: Button
var _food_plus: Button
var _food_confirm: Button
var _furniture_buttons: Dictionary = {}
var _seat_buttons: Dictionary = {}
var _use_buttons: Dictionary = {}
var _chat_content: VBoxContainer
var _read_button: Button
var _chat_badge: Label
var _entry_badge: Label
var _seen_message_ids: Dictionary = {}
@onready var _travel_overlay: Control = $Root/TravelOverlay
@onready var _album_overlay: Control = $Root/AlbumOverlay
@onready var _letter_overlay: Control = $Root/LetterOverlay
var _travel_content: VBoxContainer
var _album_content: VBoxContainer
var _letter_content: VBoxContainer
var _travel_clock: Label
var _travel_confirm := ""
var _detail_source := "chat"
@onready var _companion: Node = $CompanionClient
var _chat_input: LineEdit
var _send_button: Button
var _chat_status: Label
var _retry_button: Button
var _chat_pending := false
var _failed_message: Dictionary = {}
var _chat_session := "game-local"

var _menu_tween: Tween
var _toast_tween: Tween
var _calendar_date := ""
var _action_panel: PanelContainer


func _ready() -> void:
	# 菜单/toast 默认收起；面板初始 alpha=0，第一次打开时再淡入。
	_menu_panel.visible = false
	_menu_panel.modulate.a = 0.0
	_toast.visible = false
	_build_menu_items()
	_build_action_panel()
	_refresh_bars()
	_refresh_wallet()
	_menu_button.pressed.connect(toggle_menu)
	_close_button.pressed.connect(close_menu)
	GameState.currency_changed.connect(_on_currency_changed)
	GameState.checkin_changed.connect(_on_checkin_changed)
	$Root/CalendarOverlay/CalendarPanel/CloseButton.pressed.connect(close_calendar)
	_checkin_button.pressed.connect(_on_checkin_pressed)
	_calendar.visible = false
	_build_shop_and_backpack()
	_build_chat()
	GameState.ticket_purchased.connect(_companion.prepare_ticket)
	_build_travel_album()
	_build_settings()
	GameState.content_changed.connect(_on_content_changed)
	_refresh_dsh_status()
	GameState.travel_changed.connect(_on_travel_changed)
	GameState.travel_completed.connect(_on_travel_completed)
	GameState.album_changed.connect(_on_album_changed)
	GameState.inventory_changed.connect(_on_inventory_changed)
	GameState.furniture_changed.connect(_refresh_shop_inventory)
	GameState.stats_changed.connect(_on_stats_changed)
	GameState.messages_changed.connect(_on_messages_changed)
	for message in GameState.get_chat_messages():
		if not GameState.session_new_message_ids.has(message["id"]):
			_seen_message_ids[message["id"]] = true
	call_deferred("_on_messages_changed")
	# 提示始终高于各面板和购买确认，避免被遮罩盖住。
	_toast.z_index = 30
	# 只在日期变化且日历可见时重建，跨过本地午夜或切后台回来也不会留旧月红圈。
	var date_timer := Timer.new()
	date_timer.wait_time = 1.0
	date_timer.timeout.connect(_on_calendar_tick)
	add_child(date_timer)
	date_timer.start()


# —————————————————— 对外小 API（验收/后续页面用）——————————————————

func toggle_menu() -> void:
	set_menu_open(not _menu_panel.visible)


func close_menu() -> void:
	set_menu_open(false)


## 打开/关闭总 UI 菜单。Stage 1 没有遮罩：菜单开着时房间仍然可见、可拖动（面板区域除外）。
func set_menu_open(open: bool) -> void:
	if open and (_calendar.visible or _shop.visible or _backpack.visible or _chat.visible or _travel_overlay.visible or _album_overlay.visible or _letter_overlay.visible or _settings.visible):
		return
	if _menu_tween and _menu_tween.is_valid():
		_menu_tween.kill()
	if not open:
		_menu_panel.visible = false
		return
	_menu_panel.visible = true
	_menu_panel.scale = Vector2(1.0, 0.94)
	_menu_panel.modulate.a = 0.0
	_menu_tween = create_tween().set_parallel(true)
	_menu_tween.tween_property(_menu_panel, "modulate:a", 1.0, MENU_FADE_SECONDS)
	_menu_tween.tween_property(_menu_panel, "scale:y", 1.0, MENU_POP_SECONDS) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func is_menu_open() -> bool:
	return _menu_panel.visible


## 返回 8 项的显示文案，顺序就是 MENU_ITEMS（验收用）。
func get_menu_items() -> Array[String]:
	var labels: Array[String] = []
	for item in MENU_ITEMS:
		labels.append(String(item["label"]))
	return labels


## 底部占位提示。Stage 1 里所有菜单项都只弹这个，不做跳转/扣费。
func show_toast(text: String) -> void:
	_toast_label.text = text
	_toast.visible = true
	_toast.modulate.a = 1.0
	if _toast_tween and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(TOAST_HOLD_SECONDS)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, TOAST_FADE_SECONDS)
	_toast_tween.tween_callback(_hide_toast)


# —————————————————— 数据刷新 ——————————————————

func _refresh_bars() -> void:
	# 仅接收状态信号；时间推进由 GameState 的五秒计时器负责。
	_hunger_bar.max_value = 100.0
	_thirst_bar.max_value = 100.0
	_hunger_bar.value = clampf(GameState.get_hunger(), 0.0, 100.0)
	_thirst_bar.value = clampf(GameState.get_thirst(), 0.0, 100.0)


func _refresh_wallet() -> void:
	_balance_label.text = str(GameState.get_currency())


func _on_stats_changed() -> void:
	_refresh_bars()
	_refresh_use_buttons()


func _on_currency_changed(_value: int) -> void:
	_refresh_wallet()
	_refresh_shop_inventory()


# —————————————————— 菜单内部 ——————————————————

func _build_menu_items() -> void:
	for child in _items_box.get_children():
		child.queue_free()
	for item in MENU_ITEMS:
		_items_box.add_child(_make_item_row(String(item["icon"]), String(item["label"])))
	_chat_badge = _make_badge(_items_box.get_node("Item_聊天"), Rect2(142, 10, 20, 18))
	_entry_badge = _make_badge(_menu_button, Rect2(23, -5, 20, 18))


## 一行菜单：左侧 20×20 圆角单字图标 + 中文标签，整行是可点的 Button。
## 行内所有装饰节点都设 mouse_filter=IGNORE，保证点击一定落到 Button 上。
func _make_item_row(icon_text: String, label_text: String) -> Button:
	var row := Button.new()
	row.name = "Item_%s" % label_text
	row.custom_minimum_size = Vector2(0, ITEM_HEIGHT)
	row.focus_mode = Control.FOCUS_NONE
	row.add_theme_stylebox_override("normal", _make_flat_style(COLOR_TRANSPARENT, 8))
	row.add_theme_stylebox_override("hover", _make_flat_style(COLOR_ROW_HOVER, 8))
	row.add_theme_stylebox_override("pressed", _make_flat_style(COLOR_ROW_PRESSED, 8))
	row.pressed.connect(_on_item_pressed.bind(label_text))

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 8)
	row.add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var box := HBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 9)
	margin.add_child(box)

	var chip := PanelContainer.new()
	chip.custom_minimum_size = Vector2(20, 20)
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_theme_stylebox_override("panel", _make_flat_style(COLOR_CHIP_BG, 6))
	box.add_child(chip)

	var chip_label := Label.new()
	chip_label.text = icon_text
	chip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	chip_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	chip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip_label.add_theme_font_size_override("font_size", 11)
	chip_label.add_theme_color_override("font_color", COLOR_ICON_TEXT)
	chip.add_child(chip_label)

	var text_label := Label.new()
	text_label.text = label_text
	text_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	text_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_label.add_theme_font_size_override("font_size", 14)
	text_label.add_theme_color_override("font_color", COLOR_ITEM_TEXT)
	box.add_child(text_label)

	return row


func _on_item_pressed(label_text: String) -> void:
	if label_text == "打卡":
		close_menu()
		open_calendar()
		return
	if label_text == "商店":
		open_shop()
		return
	if label_text == "背包":
		open_backpack()
		return
	if label_text == "聊天":
		open_chat()
		return
	if label_text == "旅行":
		open_travel()
		return
	if label_text == "相簿":
		open_album()
		return
	if label_text == "设置":
		open_settings()
		return
	if label_text == "日记":
		open_diary()
		return
	# 未识别菜单项。
	show_toast("%s：下一阶段" % label_text)


func open_calendar() -> void:
	close_settings()
	_close_stage5()
	close_menu()
	close_chat()
	close_shop()
	close_backpack()
	_hide_toast()
	_calendar.visible = true
	_feedback.text = ""
	_feedback.get_parent().visible = false
	_refresh_calendar()


func close_calendar() -> void:
	_calendar.visible = false


func _on_calendar_tick() -> void:
	_refresh_travel_clock()
	if _calendar.visible and _calendar_date != CheckinDates.local_date_string():
		_feedback.text = ""
		_feedback.get_parent().visible = false
		_refresh_calendar()


func _on_checkin_changed() -> void:
	if _calendar.visible:
		_refresh_calendar()


func _on_checkin_pressed() -> void:
	var result := GameState.check_in_today()
	_feedback.text = String(result["message"])
	_feedback.get_parent().visible = true
	_refresh_calendar()


func _refresh_calendar() -> void:
	_calendar_date = CheckinDates.local_date_string()
	var year := int(_calendar_date.left(4))
	var month := int(_calendar_date.substr(5, 2))
	var today := int(_calendar_date.right(2))
	var state := GameState.get_checkin_state()
	var days: Array = state["days"]
	var locked := CheckinDates.date_string_to_ordinal(state["last_date"]) >= CheckinDates.date_string_to_ordinal(_calendar_date)
	_month_label.text = "%d年%d月" % [year, month]
	_month_count.text = "本月已打卡 %d 天" % days.size()
	_streak_label.text = "连续打卡 %d 天 · 满 7 天额外 +100" % int(state["streak"])
	_checkin_button.disabled = locked
	_checkin_text.text = "今日已打卡" if locked else "打卡 +40"
	_checkin_text.add_theme_color_override("font_color", Color("6e87a3") if locked else Color.WHITE)
	_checkin_button.tooltip_text = _checkin_text.text + " · 鲸元券"
	# 先从容器移除再排队释放，保证同帧刷新不会把旧日号算进新布局。
	for child in _date_grid.get_children():
		_date_grid.remove_child(child)
		child.queue_free()
	var first_weekday := CheckinDates.ordinal_to_weekday(CheckinDates.date_to_ordinal(year, month, 1))
	var count := CheckinDates.days_in_month(year, month)
	for index in range(42):
		var day := index - first_weekday + 1
		_date_grid.add_child(_make_date_cell(day if day >= 1 and day <= count else 0, days.has(day), day == today))


func _make_date_cell(day: int, checked: bool, today: bool) -> Control:
	var cell := PanelContainer.new()
	cell.custom_minimum_size = Vector2(40, 40)
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := _make_flat_style(COLOR_TRANSPARENT, 20)
	var color := COLOR_ITEM_TEXT
	if day > 0 and (checked or today):
		color = COLOR_CHECKED if checked else COLOR_TODAY
		style.set_border_width_all(2)
		style.border_color = color
		style.bg_color = Color(color, 0.055)
	cell.add_theme_stylebox_override("panel", style)
	var number := Label.new()
	number.text = str(day) if day > 0 else ""
	number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	number.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	number.mouse_filter = Control.MOUSE_FILTER_IGNORE
	number.add_theme_color_override("font_color", color)
	number.add_theme_font_size_override("font_size", 14)
	cell.add_child(number)
	return cell


func _hide_toast() -> void:
	_toast.visible = false


## 生成一个圆角纯色 StyleBoxFlat。每行/每个按钮都要独立实例，不能共享同一个对象。
func _make_flat_style(color: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	return style


# —————————————————— Stage 10 设置 / 本机 JSON 文件 ——————————————————

func _settings_text(parent: Control, text: String, rectangle: Rect2, font_size: int = 13) -> Label:
	var label := _label(text, font_size)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_place(label, parent, rectangle)
	return label


func _build_settings() -> void:
	var panel: Control = $Root/SettingsOverlay/SettingsPanel
	_place(_label("设置", 19), panel, Rect2(16, 12, 260, 32))
	var close := _button("×")
	close.name = "CloseButton"
	close.pressed.connect(close_settings)
	_place(close, panel, Rect2(321, 12, 30, 30))
	_place(_label("存档", 17), panel, Rect2(16, 65, 333, 28))
	_settings_text(panel, "当前存档路径（只读）", Rect2(16, 102, 333, 23), 12)
	var path := TextEdit.new()
	path.name = "SavePath"
	path.text = GameState.get_save_file_path()
	path.editable = false
	path.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	path.add_theme_font_size_override("font_size", 12)
	_place(path, panel, Rect2(16, 130, 333, 78))
	_settings_text(panel, "导出为本机 JSON 文件。导入将覆盖当前存档，确认前不会更改数据。", Rect2(16, 222, 333, 45))
	var export_button := _button("导出存档", true)
	export_button.name = "ExportButton"
	export_button.pressed.connect(open_export_dialog)
	_place(export_button, panel, Rect2(16, 282, 160, 40))
	var import_button := _button("导入存档")
	import_button.name = "ImportButton"
	import_button.pressed.connect(open_import_dialog)
	_place(import_button, panel, Rect2(189, 282, 160, 40))
	_settings_feedback = _settings_text(panel, "", Rect2(16, 334, 333, 80), 12)
	_settings_feedback.name = "Feedback"
	_settings_feedback.max_lines_visible = 4
	_settings_feedback.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var separator := HSeparator.new()
	_place(separator, panel, Rect2(16, 420, 333, 2))
	var content_button := _button("导入本地内容包 ZIP")
	content_button.pressed.connect(func(): _content_dialog.popup_centered(Vector2i(360, 520)))
	_place(content_button, panel, Rect2(16, 434, 333, 36))
	var runtime_button := _button("DSH / companion / memory 设置")
	runtime_button.pressed.connect(_open_runtime_settings)
	_place(runtime_button, panel, Rect2(16, 478, 333, 36))
	var game_version: String = ProjectSettings.get_setting("application/config/version", "开发版（Stage 10）")
	_settings_text(panel, "fishroom · %s · 存档版本 1\n内容：%s · 数据仅保存在本机" % [game_version, GameState.content_version], Rect2(16, 528, 333, 48), 12)
	_export_dialog = _make_save_dialog("ExportSaveDialog", "导出存档", FileDialog.FILE_MODE_SAVE_FILE)
	_import_dialog = _make_save_dialog("ImportSaveDialog", "导入存档", FileDialog.FILE_MODE_OPEN_FILE)
	_export_dialog.file_selected.connect(_on_export_file_selected)
	_import_dialog.file_selected.connect(_on_import_file_selected)
	_export_dialog.canceled.connect(func(): _set_settings_feedback("已取消导出"))
	_import_dialog.canceled.connect(func(): _set_settings_feedback("已取消选择存档"))
	_content_dialog = _make_save_dialog("ContentPackDialog", "导入内容包（保留存档）", FileDialog.FILE_MODE_OPEN_FILE)
	_content_dialog.filters = PackedStringArray(["*.zip ; fishroom 内容包"])
	_content_dialog.file_selected.connect(_import_content)
	_settings.visible = false


func _make_save_dialog(node_name: String, title: String, mode: FileDialog.FileMode) -> FileDialog:
	var dialog := FileDialog.new()
	dialog.name = node_name
	dialog.title = title
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = mode
	dialog.filters = PackedStringArray(["*.json ; fishroom 存档"])
	dialog.use_native_dialog = OS.has_feature("android")
	dialog.transient = true
	dialog.exclusive = true
	dialog.theme = $Root.theme
	dialog.min_size = Vector2i(350, 420)
	_settings.add_child(dialog)
	return dialog


func open_settings() -> void:
	close_menu()
	close_calendar()
	close_shop()
	close_backpack()
	close_chat()
	_close_stage5()
	_hide_toast()
	_settings.visible = true
	_set_settings_feedback("")


func close_settings() -> void:
	_settings.visible = false
	if is_instance_valid(_export_dialog):
		_export_dialog.hide()
	if is_instance_valid(_import_dialog):
		_import_dialog.hide()
	if is_instance_valid(_content_dialog):
		_content_dialog.hide()
	_cancel_import()


func _set_settings_feedback(text: String, error: bool = false) -> void:
	_settings_feedback.text = text
	_settings_feedback.add_theme_color_override("font_color", Color("b33e50") if error else Color("3976a6"))


func _desktop_file_dialog_supported() -> bool:
	if OS.has_feature("android"):
		return true
	if OS.get_name() in ["Windows", "macOS", "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"] and DisplayServer.get_name() != "headless":
		return true
	_set_settings_feedback("当前平台请手动复制 user://save.json")
	return false


func _import_content(path: String) -> void:
	if GameState.import_content_pack(path):
		_set_settings_feedback("已切换内容 %s，存档与备份已保留" % GameState.content_version)
	else:
		_set_settings_feedback(GameState.last_content_error, true)


func _on_content_changed() -> void:
	close_food_purchase()
	close_purchase()
	close_letter()
	_food_icons.clear()
	if _shop.visible:
		select_shop_tab(_active_tab)
	if _backpack.visible:
		_refresh_backpack()
	if _travel_overlay.visible:
		_refresh_travel()
	if _album_overlay.visible:
		_refresh_album()


func _open_runtime_settings() -> void:
	if is_instance_valid(_runtime_dialog):
		_runtime_dialog.queue_free()
	_runtime_dialog = AcceptDialog.new()
	_runtime_dialog.title = "外部服务（可选）"
	_runtime_dialog.dialog_text = ""
	_runtime_dialog.theme = $Root.theme
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(320, 300)
	_runtime_dialog.add_child(box)
	box.add_child(_wrapped("手机填写电脑的 LAN / Tailscale 地址。未启用时可游玩空房子。", 12))
	var use_services := CheckBox.new()
	use_services.text = "启用外部服务"
	use_services.button_pressed = _companion.enabled
	box.add_child(use_services)
	box.add_child(_label("companion 地址", 13))
	var companion := LineEdit.new()
	companion.text = _companion.base_url
	box.add_child(companion)
	box.add_child(_label("memory 地址", 13))
	var memory := LineEdit.new()
	memory.text = _companion.memory_url
	box.add_child(memory)
	box.add_child(_wrapped("DSH 地址及三个 preset：保存地址后，进入日记 → DSH 连接设置。DSH URL 从电脑端 runtime 解析。", 12))
	_runtime_dialog.confirmed.connect(func():
		if _companion.configure_endpoints(companion.text, memory.text, use_services.button_pressed):
			_set_settings_feedback("服务地址已保存；DSH 及 preset 可在日记连接设置中填写")
			_refresh_dsh_status()
		else:
			_set_settings_feedback("地址无效、服务忙碌或保存失败，请使用私网 HTTP 或 HTTPS 地址", true)
	)
	_settings.add_child(_runtime_dialog)
	_runtime_dialog.popup_centered(Vector2i(350, 380))


func open_export_dialog() -> void:
	if not _desktop_file_dialog_supported():
		return
	_set_settings_feedback("")
	var stamp := Time.get_datetime_string_from_system().replace("-", "").replace(":", "").replace("T", "-")
	_export_dialog.current_file = "fishroom_save_%s.json" % stamp
	_export_dialog.popup_centered(Vector2i(365, 510))


func open_import_dialog() -> void:
	if not _desktop_file_dialog_supported():
		return
	_set_settings_feedback("")
	_import_dialog.popup_centered(Vector2i(365, 510))


func _on_export_file_selected(path: String) -> void:
	# 不允许把导出目标指向正式档、导入备份或其临时文件。
	var target := ProjectSettings.globalize_path(path).simplify_path()
	for reserved in [GameState.get_save_path(), GameState.get_save_path() + ".tmp", GameState.IMPORT_BACKUP_PATH, GameState.IMPORT_BACKUP_PATH + ".tmp"]:
		var reserved_path := ProjectSettings.globalize_path(reserved).simplify_path()
		if target.nocasecmp_to(reserved_path) == 0:
			_set_settings_feedback("请选择其它导出位置，不能覆盖游戏存档或导入备份", true)
			return
	var text: String = GameState.export_save_text()
	var temporary := path + ".fishroom-export-%d.tmp" % Time.get_ticks_usec()
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		_set_settings_feedback("导出失败：无法写入所选位置（错误 %d）" % FileAccess.get_open_error(), true)
		return
	file.store_string(text)
	file.flush()
	var error := file.get_error()
	file.close()
	if error == OK:
		error = DirAccess.rename_absolute(temporary, path)
	if error != OK:
		DirAccess.remove_absolute(temporary)
		_set_settings_feedback("导出失败：文件写入或替换失败（错误 %d）" % error, true)
		return
	_set_settings_feedback("导出成功：\n" + path)


func _on_import_file_selected(path: String) -> void:
	_cancel_import()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_set_settings_feedback("读取失败：无法打开所选文件（错误 %d）" % FileAccess.get_open_error(), true)
		return
	if file.get_length() > GameState.MAX_IMPORT_BYTES:
		file.close()
		_set_settings_feedback("存档超过 8 MiB，无法导入", true)
		return
	var text := file.get_as_text()
	var error := file.get_error()
	file.close()
	if error not in [OK, ERR_FILE_EOF]:
		_set_settings_feedback("读取存档失败（错误 %d）" % error, true)
		return
	var validation: Dictionary = GameState.validate_save_text(text)
	if not validation["ok"]:
		_set_settings_feedback(validation["error"], true)
		return
	# 确认后导入这份已验证的文本，不重读可能已被外部更改的文件。
	_pending_import_text = text
	_import_confirmation = Control.new()
	_import_confirmation.name = "ImportConfirmation"
	_place(_import_confirmation, _settings, Rect2(0, 0, 405, 720))
	_import_confirmation.mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.4)
	_place(shade, _import_confirmation, Rect2(0, 0, 405, 720))
	var panel := Panel.new()
	panel.name = "Panel"
	panel.add_theme_stylebox_override("panel", $Root/SettingsOverlay/SettingsPanel.get_theme_stylebox("panel"))
	_place(panel, _import_confirmation, Rect2(36, 248, 333, 224))
	_place(_label("导入存档", 18), panel, Rect2(16, 16, 301, 28))
	_settings_text(panel, "导入会覆盖当前存档，是否继续？", Rect2(16, 58, 301, 44), 15)
	_settings_text(panel, "继续前会在本机备份当前存档。", Rect2(16, 112, 301, 32), 12)
	var cancel := _button("取消")
	cancel.name = "CancelButton"
	cancel.pressed.connect(_cancel_import)
	_place(cancel, panel, Rect2(16, 166, 142, 40))
	var confirm := _button("确认导入", true)
	confirm.name = "ConfirmButton"
	confirm.pressed.connect(_confirm_import)
	_place(confirm, panel, Rect2(175, 166, 142, 40))


func _cancel_import() -> void:
	_pending_import_text = ""
	if is_instance_valid(_import_confirmation):
		_import_confirmation.get_parent().remove_child(_import_confirmation)
		_import_confirmation.queue_free()
	_import_confirmation = null


func _confirm_import() -> void:
	if _pending_import_text.is_empty():
		return
	var text := _pending_import_text
	_cancel_import()
	if not GameState.import_save_text(text):
		_set_settings_feedback(GameState.last_import_error, true)
		return
	var error := get_tree().reload_current_scene()
	if error != OK:
		_set_settings_feedback("存档已导入，但场景刷新失败（错误 %d），请重新启动游戏" % error, true)


# —————————————————— Stage 3 面板与组件 ——————————————————

func _place(node: Control, parent: Node, rectangle: Rect2) -> void:
	parent.add_child(node)
	node.position = rectangle.position
	node.size = rectangle.size


func _label(text: String, font_size: int = 14, color: Color = COLOR_ITEM_TEXT) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _button(text: String, active: bool = false) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 13)
	_style_button(button, active)
	return button


func _style_button(button: Button, active: bool) -> void:
	for state in ["normal", "hover", "pressed", "disabled"]:
		var color := Color("3986c9") if active else Color("eef6ff")
		if state == "hover" or state == "pressed":
			color = Color("2c70af") if active else Color("daeafb")
		if state == "disabled":
			color = Color("e5edf4")
		var style := _make_flat_style(color, 12)
		style.set_border_width_all(1)
		style.border_color = Color("bdd8ef")
		button.add_theme_stylebox_override(state, style)
	for state in ["font_color", "font_hover_color", "font_pressed_color"]:
		button.add_theme_color_override(state, Color.WHITE if active else COLOR_ITEM_TEXT)
	button.add_theme_color_override("font_disabled_color", Color("6b8197"))


func _money(parent: Node, value: int, prefix: String = "", font_size: int = 14) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 5)
	parent.add_child(row)
	if prefix != "":
		row.add_child(_label(prefix, font_size, Color("718aa4")))
	var icon := TextureRect.new()
	icon.texture = BILL_ICON
	icon.custom_minimum_size = Vector2(24, 14)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)
	var amount := _label(str(value), font_size)
	amount.name = "Amount"
	row.add_child(amount)
	return row


func _build_header(panel: Control, title: String, close_action: Callable) -> Label:
	_place(_label(title, 19), panel, Rect2(16, 12, 120, 32))
	var wallet := _money(panel, GameState.get_currency())
	wallet.position = Vector2(235, 19)
	var close := _button("×")
	close.name = "CloseButton"
	close.pressed.connect(close_action)
	_place(close, panel, Rect2(321, 12, 30, 30))
	return wallet.get_node("Amount") as Label


func _scroll_content(panel: Control, rectangle: Rect2) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_place(scroll, panel, rectangle)
	var content := VBoxContainer.new()
	content.name = "Content"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 6)
	scroll.add_child(content)
	return content


func _build_shop_and_backpack() -> void:
	var panel: Control = $Root/ShopOverlay/ShopPanel
	_shop_balance = _build_header(panel, "商店", close_shop)
	var tabs := HBoxContainer.new()
	tabs.name = "Tabs"
	tabs.add_theme_constant_override("separation", 8)
	_place(tabs, panel, Rect2(16, 56, 333, 32))
	for title in ["家具", "食物", "车票", "衣服"]:
		var tab := _button(title)
		tab.name = "Tab_" + title
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab.pressed.connect(select_shop_tab.bind(title))
		tabs.add_child(tab)
		_tabs.append(tab)
	_shop_content = _scroll_content(panel, Rect2(16, 100, 333, 428))
	_shop_feedback = _label("", 12, Color("3976a6"))
	_shop_feedback.name = "Feedback"
	_place(_shop_feedback, panel, Rect2(16, 538, 333, 24))
	var backpack_panel: Control = $Root/BackpackOverlay/BackpackPanel
	_backpack_balance = _build_header(backpack_panel, "背包", close_backpack)
	_place(_label("收藏的食物与车票", 12, Color("718aa4")), backpack_panel, Rect2(16, 53, 333, 24))
	_backpack_content = _scroll_content(backpack_panel, Rect2(16, 92, 333, 460))
	_shop.visible = false
	_backpack.visible = false
	select_shop_tab(_active_tab)


func open_shop() -> void:
	close_settings()
	_close_stage5()
	close_menu()
	close_chat()
	close_calendar()
	close_backpack()
	_hide_toast()
	_shop.visible = true
	_shop_feedback.text = ""
	select_shop_tab(_active_tab)
	_refresh_shop_inventory()


func close_shop() -> void:
	_shop.visible = false
	close_food_purchase()
	close_purchase()


func open_backpack() -> void:
	close_settings()
	_close_stage5()
	close_menu()
	close_chat()
	close_calendar()
	close_shop()
	_hide_toast()
	_backpack.visible = true
	_refresh_backpack()


func close_backpack() -> void:
	_backpack.visible = false


func _clear_content(content: Control) -> void:
	for child in content.get_children():
		content.remove_child(child)
		child.queue_free()


func select_shop_tab(title: String) -> void:
	_active_tab = title
	close_food_purchase()
	close_purchase()
	_clear_content(_shop_content)
	_food_counts.clear()
	_furniture_buttons.clear()
	_seat_buttons.clear()
	_shop_feedback.text = ""
	for tab in _tabs:
		_style_button(tab, tab.text == title)
	match title:
		"家具":
			_build_furniture()
		"衣服":
			_empty_message(_shop_content, "暂无商品上架")
		"食物":
			_build_food()
		"车票":
			_build_tickets()
	_refresh_shop_inventory()
	(_shop_content.get_parent() as ScrollContainer).scroll_vertical = 0


func _empty_message(content: Control, text: String) -> void:
	var message := _label(text, 15, Color("718aa4"))
	message.custom_minimum_size.y = 120
	message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	content.add_child(message)


func _build_furniture() -> void:
	var catalog := GameState.get_furniture_catalog()
	for category in ["挂画", "电视", "地毯"]:
		_shop_content.add_child(_label(category, 12))
		var grid := GridContainer.new()
		grid.name = "FurnitureGrid_" + category
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 8)
		grid.add_theme_constant_override("v_separation", 8)
		_shop_content.add_child(grid)
		for item in catalog:
			if item["category"] != category:
				continue
			var card := _button("")
			card.name = "Furniture_" + String(item["id"])
			card.custom_minimum_size = Vector2(160, 150)
			card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			card.tooltip_text = "购买 " + String(item["name"])
			card.pressed.connect(_buy_furniture.bind(String(item["id"])))
			grid.add_child(card)
			var art := TextureRect.new()
			art.texture = GameState.ContentManager.texture(String(item["icon"]))
			art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			art.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_place(art, card, Rect2(10, 8, 140, 62))
			_place(_label(item["name"], 12), card, Rect2(10, 72, 140, 20))
			_place(_label(item["description"], 10, Color("718aa4")), card, Rect2(10, 94, 140, 18))
			var price := _money(card, int(item["price"]), "", 12)
			price.position = Vector2(10, 118)
			var status := _label("", 10, Color("3976a6"))
			status.name = "Status"
			_place(status, card, Rect2(78, 118, 74, 18))
			_furniture_buttons[item["id"]] = card


func _buy_furniture(item_id: String) -> void:
	var result := GameState.buy_furniture(item_id)
	var message := "已购买 · 已摆进房间" if result["ok"] else ("已拥有该家具" if result["reason"] == "already_owned" else _purchase_reason(result["reason"]))
	_shop_feedback.text = message
	show_toast(message)
	_refresh_shop_inventory()


func _load_food_icon(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if _food_icons.has(path):
		return _food_icons[path] as Texture2D
	var texture: Texture2D
	if ResourceLoader.exists(path):
		texture = load(path) as Texture2D
	if texture == null and FileAccess.file_exists(path):
		var image := Image.load_from_file(ProjectSettings.globalize_path(path))
		if image != null and not image.is_empty():
			texture = ImageTexture.create_from_image(image)
	if texture == null:
		push_warning("[Food] 图片缺失或损坏：" + path)
	elif absf(float(texture.get_width()) / maxf(texture.get_height(), 1) - 0.8) > 0.08:
		push_warning("[Food] 图片比例不是 4:5，将保持比例显示：" + path)
	_food_icons[path] = texture
	return texture


func _build_food() -> void:
	var catalog := GameState.get_food_catalog()
	var colors := [Color("f3dfb5"), Color("e87568"), Color("d9ba86"), Color("74c5e5"), Color("e98bba"), Color("f4cf53"), Color("88ceb2")]
	var categories: Array[String] = []
	for item in catalog:
		var category := String(item["category"])
		if not categories.has(category):
			categories.append(category)
	for category in categories:
		_shop_content.add_child(_label(category, 12))
		var grid := GridContainer.new()
		grid.name = "FoodGrid_" + category
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 8)
		grid.add_theme_constant_override("v_separation", 6)
		_shop_content.add_child(grid)
		for index in range(catalog.size()):
			var item: Dictionary = catalog[index]
			if item["category"] != category:
				continue
			var card := _button("")
			card.name = "Food_" + String(item["id"])
			card.custom_minimum_size = Vector2(160, 80)
			card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			card.tooltip_text = "购买 " + String(item["name"])
			card.pressed.connect(_buy_food.bind(String(item["id"])))
			grid.add_child(card)
			var icon_value: Variant = item.get("icon")
			var icon_path := ""
			if icon_value is String:
				icon_path = icon_value
			var icon_texture := _load_food_icon(icon_path)
			if icon_texture != null:
				var icon := TextureRect.new()
				icon.texture = icon_texture
				icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
				_place(icon, card, Rect2(2, 5, 40, 50))
			else:
				if not icon_path.is_empty():
					push_warning("[GameUI] 食物图标加载失败：" + icon_path)
				var art := Panel.new()
				art.mouse_filter = Control.MOUSE_FILTER_IGNORE
				art.add_theme_stylebox_override("panel", _make_flat_style(colors[index % colors.size()], 9))
				_place(art, card, Rect2(2, 5, 40, 50))
			_place(_label(item["name"], 12), card, Rect2(43, 7, 111, 20))
			var price := _money(card, int(item.get("price", 0)), "", 11)
			price.position = Vector2(43, 28)
			var effects: Array[String] = []
			for effect in [["hunger", "饥饿"], ["thirst", "口渴"]]:
				if int(item.get(effect[0], 0)) > 0:
					effects.append("+%d %s" % [int(item.get(effect[0], 0)), effect[1]])
			_place(_label(" / ".join(effects), 10, Color("718aa4")), card, Rect2(43, 48, 111, 15))
			var count := _label("", 10, Color("3976a6"))
			_place(count, card, Rect2(8, 63, 144, 14))
			_food_counts[item["id"]] = count


func _buy_food(item_id: String) -> void:
	var item := GameState.get_food_item(item_id)
	if item.is_empty():
		return
	close_food_purchase()
	_pending_food = item_id
	_food_quantity = 1
	_shop_feedback.text = ""
	_hide_toast()
	_food_confirmation = Control.new()
	_food_confirmation.name = "FoodPurchaseConfirmation"
	_shop.add_child(_food_confirmation)
	_food_confirmation.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_food_confirmation.z_index = 20
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.35)
	_food_confirmation.add_child(backdrop)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := Panel.new()
	panel.name = "Panel"
	panel.add_theme_stylebox_override("panel", _make_flat_style(Color("f9fcff"), 20))
	_place(panel, _food_confirmation, Rect2(37.5, 100, 330, 520))
	var art := TextureRect.new()
	art.name = "FoodArt"
	var icon_value: Variant = item.get("icon")
	art.texture = _load_food_icon(icon_value if icon_value is String else "")
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place(art, panel, Rect2(85, 14, 160, 200))
	_place(_label(item["name"], 18), panel, Rect2(20, 220, 290, 28))
	_place(_label(item.get("category", ""), 12, Color("718aa4")), panel, Rect2(20, 250, 290, 20))
	var price := _money(panel, int(item.get("price", 0)), "单价", 14)
	price.position = Vector2(20, 279)
	_food_minus = _button("−")
	_food_minus.name = "Minus"
	_food_minus.pressed.connect(_change_food_quantity.bind(-1))
	_place(_food_minus, panel, Rect2(70, 314, 46, 36))
	_food_quantity_label = _label("1", 18)
	_food_quantity_label.name = "Quantity"
	_food_quantity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_place(_food_quantity_label, panel, Rect2(124, 314, 82, 36))
	_food_plus = _button("+")
	_food_plus.name = "Plus"
	_food_plus.pressed.connect(_change_food_quantity.bind(1))
	_place(_food_plus, panel, Rect2(214, 314, 46, 36))
	var total := _money(panel, 0, "总价", 16)
	total.position = Vector2(20, 365)
	_food_total = total.get_node("Amount") as Label
	var balance := _money(panel, GameState.get_currency(), "当前余额", 14)
	balance.position = Vector2(20, 399)
	_food_balance = balance.get_node("Amount") as Label
	_food_feedback = _label("", 12, Color("b05257"))
	_food_feedback.name = "Feedback"
	_place(_food_feedback, panel, Rect2(20, 434, 290, 24))
	var cancel := _button("取消/关闭")
	cancel.pressed.connect(close_food_purchase)
	_place(cancel, panel, Rect2(20, 470, 128, 36))
	_food_confirm = _button("确认购买", true)
	_food_confirm.name = "ConfirmButton"
	_food_confirm.pressed.connect(_confirm_food_purchase)
	_place(_food_confirm, panel, Rect2(160, 470, 150, 36))
	_refresh_food_purchase()


func _food_quantity_limit(price: int) -> int:
	if price <= 0:
		return 99
	@warning_ignore("integer_division")
	var affordable := GameState.get_currency() / price
	return clampi(affordable, 0, 99)


func _change_food_quantity(delta: int) -> void:
	var item := GameState.get_food_item(_pending_food)
	_food_quantity = clampi(_food_quantity + delta, 1, maxi(1, _food_quantity_limit(int(item.get("price", 0)))))
	_refresh_food_purchase()


func _refresh_food_purchase() -> void:
	if not is_instance_valid(_food_confirmation):
		return
	var item := GameState.get_food_item(_pending_food)
	var price := int(item.get("price", 0))
	var limit := _food_quantity_limit(price)
	_food_quantity = clampi(_food_quantity, 1, maxi(1, limit))
	var total := price * _food_quantity
	var insufficient := GameState.get_currency() < total
	_food_quantity_label.text = str(_food_quantity)
	_food_total.text = str(total)
	_food_total.modulate = Color("c74450") if insufficient else Color.WHITE
	_food_balance.text = str(GameState.get_currency())
	_food_minus.disabled = _food_quantity <= 1
	_food_plus.disabled = _food_quantity >= limit
	_food_confirm.disabled = insufficient or item.is_empty() or price < 0
	_food_feedback.text = "鲸元券不足" if insufficient else ""


func _confirm_food_purchase() -> void:
	var item := GameState.get_food_item(_pending_food)
	var result := GameState.buy_food(_pending_food, _food_quantity)
	_refresh_shop_inventory()
	if result["ok"]:
		var message := "已购买 %d 份 %s" % [result["quantity"], item.get("name", "")]
		close_food_purchase()
		_shop_feedback.text = message
		show_toast(message)
		_refresh_backpack()
	else:
		_refresh_food_purchase()
		_food_feedback.text = {"invalid_quantity": "数量无效（1–99）", "invalid_price": "商品价格无效", "insufficient": "鲸元券不足"}.get(result["reason"], _purchase_reason(result["reason"]))


func close_food_purchase() -> void:
	if is_instance_valid(_food_confirmation):
		_food_confirmation.get_parent().remove_child(_food_confirmation)
		_food_confirmation.queue_free()
	_food_confirmation = null
	_pending_food = ""


func _build_tickets() -> void:
	for location in GameState.get_location_catalog():
		var art := TextureRect.new()
		art.texture = GameState.ContentManager.texture(location["ticket_art_crop"])
		art.custom_minimum_size = Vector2(0, 114)
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_shop_content.add_child(art)
		var seats := HBoxContainer.new()
		seats.add_theme_constant_override("separation", 8)
		_shop_content.add_child(seats)
		for seat in location["seats"]:
			var button := _button("")
			button.name = "Seat_" + seat["id"]
			button.custom_minimum_size = Vector2(101, 64)
			button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			button.pressed.connect(open_purchase.bind(location["id"], seat["id"]))
			seats.add_child(button)
			_place(_label(seat["name"], 13), button, Rect2(10, 5, 85, 20))
			var price := _money(button, int(seat["price"]), "", 12)
			price.position = Vector2(10, 27)
			var status := _label("", 10, Color("718aa4"))
			status.name = "Status"
			_place(status, button, Rect2(10, 47, 85, 15))
			_seat_buttons[location["id"] + "/" + seat["id"]] = button
	_shop_content.add_child(_label("不同座位：旅行时长 / 照片数量 / 信件时间不同", 10, Color("718aa4")))
	_empty_message(_shop_content, "更多目的地 · 敬请期待")
	_shop_content.add_child(_label("每个座位限购一次；其它座位仍可购买", 11, Color("718aa4")))
	_shop_content.add_child(_label("购票后收藏于背包", 11, Color("718aa4")))


func _purchase_reason(reason: String) -> String:
	match reason:
		"insufficient": return "鲸元券余额不足"
		"already_owned": return "已拥有该座位的车票"
		"save_failed": return "保存失败，请重试"
		"busy": return "正在购买，请稍候"
	return "商品无效"


func _ticket_status(location: String, seat: String) -> String:
	for ticket in GameState.get_tickets():
		if ticket["location"] == location and ticket["seat"] == seat:
			return _ticket_status_text(ticket["status"])
	return ""


func _ticket_status_text(status: String) -> String:
	return {"owned": "已拥有", "traveling": "旅行中", "visited": "已旅行"}.get(status, "已拥有")


func _refresh_shop_inventory() -> void:
	if not is_instance_valid(_shop_balance):
		return
	_shop_balance.text = str(GameState.get_currency())
	_backpack_balance.text = str(GameState.get_currency())
	for item_id in _furniture_buttons:
		var card: Button = _furniture_buttons[item_id]
		card.disabled = GameState.has_furniture(item_id)
		card.get_node("Status").text = "已拥有" if card.disabled else "点击购买"
	for item_id in _food_counts:
		_food_counts[item_id].text = "背包 %d 份 · 点击购买" % GameState.get_food_count(item_id)
	for key in _seat_buttons:
		var ids := String(key).split("/")
		var button: Button = _seat_buttons[key]
		var status := _ticket_status(ids[0], ids[1])
		button.disabled = status != ""
		button.get_node("Status").text = status if status != "" else "查看详情"
	_refresh_purchase_state()
	_refresh_food_purchase()


func _on_inventory_changed() -> void:
	_refresh_shop_inventory()
	if _backpack.visible:
		_refresh_backpack()


func open_purchase(location_id: String, seat_id: String) -> void:
	# 新一笔确认只显示本次反馈，避免上次成功提示透过弹窗残留。
	_shop_feedback.text = ""
	_hide_toast()
	var location := GameState.get_location(location_id)
	var seat := GameState.get_seat(location_id, seat_id)
	if seat.is_empty():
		return
	close_purchase()
	_pending_location = location_id
	_pending_seat = seat_id
	_confirmation = Control.new()
	_confirmation.name = "PurchaseConfirmation"
	_shop.add_child(_confirmation)
	_confirmation.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_confirmation.z_index = 10
	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.color = Color(0, 0, 0, 0.3)
	_confirmation.add_child(backdrop)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := Panel.new()
	panel.name = "Panel"
	panel.add_theme_stylebox_override("panel", _make_flat_style(Color("f9fcff"), 20))
	_place(panel, _confirmation, Rect2(47.5, 174, 310, 372))
	_place(_label("确认购买", 16), panel, Rect2(18, 14, 240, 26))
	var close := _button("×")
	close.pressed.connect(close_purchase)
	_place(close, panel, Rect2(264, 12, 28, 28))
	_place(_label("%s · %s" % [location["name"], seat["name"]], 20), panel, Rect2(18, 56, 274, 32))
	var price := _money(panel, int(seat["price"]), "", 32)
	price.position = Vector2(18, 94)
	_place(_label("旅行时长                  %d 小时" % int(seat["duration_hours"]), 13, Color("718aa4")), panel, Rect2(18, 151, 274, 24))
	_place(_label("旅行照片                  %d 张" % int(seat["photo_count"]), 13, Color("718aa4")), panel, Rect2(18, 181, 274, 24))
	var hours: Array[String] = []
	for letter in seat["letters"]:
		hours.append(str(letter["photo_ids"].size()))
	_place(_label("旅行途中将陆续收到来信", 12, Color("718aa4")), panel, Rect2(18, 211, 274, 24))
	var balance := _money(panel, GameState.get_currency(), "余额", 13)
	balance.position = Vector2(18, 244)
	_confirm_balance = balance.get_node("Amount") as Label
	_confirm_feedback = _label("", 12, Color("b05257"))
	_place(_confirm_feedback, panel, Rect2(18, 275, 274, 24))
	var cancel := _button("取消")
	cancel.pressed.connect(close_purchase)
	_place(cancel, panel, Rect2(18, 317, 124, 38))
	_confirm_button = _button("确认购买", true)
	_confirm_button.name = "ConfirmButton"
	_confirm_button.pressed.connect(_confirm_purchase)
	_place(_confirm_button, panel, Rect2(152, 317, 140, 38))
	_refresh_purchase_state()


func _refresh_purchase_state() -> void:
	if not is_instance_valid(_confirmation):
		return
	_confirm_balance.text = str(GameState.get_currency())
	var status := _ticket_status(_pending_location, _pending_seat)
	var seat := GameState.get_seat(_pending_location, _pending_seat)
	var insufficient := GameState.get_currency() < int(seat.get("price", 0))
	_confirm_button.disabled = status != "" or insufficient
	_confirm_button.text = status if status != "" else ("余额不足" if insufficient else "确认购买")
	_confirm_feedback.text = "该座位不可重复购买" if status != "" else ("鲸元券余额不足" if insufficient else "购票后放入背包")


func _confirm_purchase() -> void:
	var result := GameState.buy_ticket(_pending_location, _pending_seat)
	_refresh_shop_inventory()
	if result["ok"]:
		close_purchase()
		_shop_feedback.text = "购买成功 · 车票已放入背包"
	else:
		_shop_feedback.text = ""
		_hide_toast()
		_refresh_purchase_state()
		_confirm_feedback.text = _purchase_reason(result["reason"])


func close_purchase() -> void:
	if is_instance_valid(_confirmation):
		_confirmation.get_parent().remove_child(_confirmation)
		_confirmation.queue_free()
	_confirmation = null


func _refresh_backpack() -> void:
	_backpack_balance.text = str(GameState.get_currency())
	_clear_content(_backpack_content)
	_use_buttons.clear()
	_backpack_content.add_child(_label("食物", 16))
	var inventory := GameState.get_food_inventory()
	if inventory.is_empty():
		_empty_message(_backpack_content, "背包里还没有食物")
	else:
		for item_id in inventory:
			var item := GameState.get_owned_food_item(item_id)
			if item.is_empty():
				_backpack_row("已归档食物 · %s × %d" % [item_id, inventory[item_id]], "原库存保留，当前内容不可使用")
				continue
			var effects: Array[String] = []
			for effect in [["hunger", "饥饿"], ["thirst", "口渴"]]:
				if int(item.get(effect[0], 0)) > 0:
					effects.append("+%d %s" % [int(item[effect[0]]), effect[1]])
			_backpack_row("%s  × %d" % [item.get("name", item_id), inventory[item_id]], "%s · %s" % [item.get("category", "食物"), " / ".join(effects)], item_id)
	_backpack_content.add_child(_label("车票", 16))
	var tickets := GameState.get_tickets()
	if tickets.is_empty():
		_empty_message(_backpack_content, "还没有车票")
	else:
		for ticket in tickets:
			var location := GameState.get_location(ticket["location"])
			var seat := GameState.get_seat(ticket["location"], ticket["seat"])
			_backpack_row("%s · %s" % [location.get("name", ticket["location"]), seat.get("name", ticket["seat"])], "状态：" + _ticket_status_text(ticket["status"]))
	_refresh_use_buttons()
	_backpack_content.add_child(_label("已拥有家具", 16))
	for item_id in GameState.get_owned_furniture():
		var found := false
		for item in GameState.get_furniture_catalog():
			if item["id"] == GameState.content.resolve("furniture", item_id):
				_backpack_row(str(item["name"]), "已拥有 · " + item_id)
				found = true
		if not found:
			_backpack_row("已归档家具 · " + item_id, "保留拥有记录")


func _backpack_row(title: String, detail: String, item_id: String = "") -> void:
	var card := PanelContainer.new()
	var style := _make_flat_style(Color("eef6ff"), 12)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	card.add_theme_stylebox_override("panel", style)
	_backpack_content.add_child(card)
	var row := HBoxContainer.new()
	card.add_child(row)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(content)
	content.add_child(_label(title, 14))
	content.add_child(_label(detail, 11, Color("718aa4")))
	if item_id != "":
		var use := _button("使用")
		use.name = "Use_" + item_id
		use.custom_minimum_size = Vector2(76, 32)
		use.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		use.pressed.connect(_use_food.bind(item_id))
		row.add_child(use)
		_use_buttons[item_id] = use


func _use_reason_text(reason: String) -> String:
	return {"full": "已经饱了", "not_thirsty": "不渴了", "empty": "没有库存", "save_failed": "保存失败，请重试", "busy": "请稍候", "invalid_id": "食物无效"}.get(reason, "使用")


func _refresh_use_buttons() -> void:
	for item_id in _use_buttons:
		var button: Button = _use_buttons[item_id]
		var reason := GameState.food_use_reason(item_id)
		button.disabled = reason != ""
		button.text = _use_reason_text(reason)
		button.tooltip_text = button.text


func _use_food(item_id: String) -> void:
	var result := GameState.use_food(item_id)
	show_toast("使用了%s · 剩余 %d 份" % [result["item"].get("name", item_id), result["count"]] if result["ok"] else _use_reason_text(result["reason"]))


# —————————————————— Stage 4 只读 DS 收件箱 ——————————————————

func _close_stage5() -> void:
	_travel_overlay.visible = false
	_album_overlay.visible = false
	_letter_overlay.visible = false
	_travel_confirm = ""


func _build_travel_album() -> void:
	for item in [[_travel_overlay, "TravelPanel", "旅行", close_travel], [_album_overlay, "AlbumPanel", "相簿", close_album], [_letter_overlay, "LetterPanel", "旅行来信", close_letter]]:
		var panel: Control = item[0].get_node(item[1])
		var heading := _label(item[2], 19)
		heading.name = "Title"
		_place(heading, panel, Rect2(16, 12, 280, 32))
		var close := _button("×")
		close.name = "CloseButton"
		close.pressed.connect(item[3])
		_place(close, panel, Rect2(321, 12, 30, 30))
	_travel_content = _scroll_content($Root/TravelOverlay/TravelPanel, Rect2(16, 60, 333, 496))
	_album_content = _scroll_content($Root/AlbumOverlay/AlbumPanel, Rect2(16, 60, 333, 496))
	_letter_content = _scroll_content($Root/LetterOverlay/LetterPanel, Rect2(16, 60, 333, 496))
	if GameState.session_completed_location != "":
		call_deferred("_on_travel_completed", GameState.session_completed_location)


func _open_stage5(overlay: Control) -> void:
	close_settings()
	close_menu()
	close_calendar()
	close_shop()
	close_backpack()
	close_chat()
	_close_stage5()
	_hide_toast()
	overlay.visible = true


func open_travel() -> void:
	_open_stage5(_travel_overlay)
	_refresh_travel()


func close_travel() -> void:
	_travel_overlay.visible = false
	_travel_confirm = ""


func _wrapped(text: String, size: int = 14, color: Color = COLOR_ITEM_TEXT) -> Label:
	var label := _label(text, size, color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _seat_summary(location: String, seat_id: String) -> String:
	var seat := GameState.get_seat(location, seat_id)
	var hours: Array[String] = []
	for plan in seat.get("letters", []):
		hours.append("%d张照片" % plan["photo_ids"].size())
	return "%d 小时旅程 · %d 张照片\n来信：%s" % [int(seat.get("duration_hours", 0)), int(seat.get("photo_count", 0)), " / ".join(hours)]


func _refresh_travel() -> void:
	_clear_content(_travel_content)
	_travel_clock = null
	var travel := GameState.get_active_travel()
	var pending_count := GameState.pending_letter_count(String(travel.get("id", "")))
	_travel_content.add_child(_wrapped("待补 %d 封 · 可用时自动补投" % pending_count, 13, Color("718aa4")))
	if not travel.is_empty():
		_travel_content.add_child(_label("旅行中", 13, Color("3986c9")))
		_travel_content.add_child(_label(_place_seat(travel), 22))
		_travel_content.add_child(_wrapped(_seat_summary(travel["location"], travel["seat"]), 13))
		_travel_clock = _label("", 17)
		_travel_clock.custom_minimum_size.y = 90
		_travel_content.add_child(_travel_clock)
		var received := 0
		for letter in travel["letters"]:
			if letter["status"] == "delivered":
				received += 1
		_travel_content.add_child(_label("已收到 %d / %d 封信" % [received, travel["letters"].size()], 16))
		_travel_content.add_child(_wrapped("来信会送到聊天收件箱，打开信件即可收藏照片。", 13, Color("718aa4")))
		_refresh_travel_clock()
		return
	var tickets := GameState.get_tickets()
	var owned := tickets.filter(func(ticket: Dictionary): return ticket["status"] == "owned")
	if owned.is_empty():
		_travel_content.add_child(_wrapped("背包里还没有车票，先去商店购买", 16))
	else:
		_travel_content.add_child(_label("选择一张车票出发", 14, Color("718aa4")))
	for ticket in tickets:
		var button := _button("")
		button.name = "TravelTicket_" + ticket["seat"]
		button.custom_minimum_size.y = 122
		button.disabled = ticket["status"] != "owned"
		button.pressed.connect(_show_departure.bind(ticket["id"]))
		_travel_content.add_child(button)
		_place(_label(_place_seat(ticket), 18), button, Rect2(14, 10, 300, 28))
		_place(_label(_seat_summary(ticket["location"], ticket["seat"]), 11, Color("718aa4")), button, Rect2(14, 43, 300, 43))
		_place(_label("选择出发" if ticket["status"] == "owned" else _ticket_status_text(ticket["status"]), 12, Color("3976a6")), button, Rect2(14, 94, 300, 20))


func _place_seat(item: Dictionary) -> String:
	return "%s · %s" % [GameState.get_location(item["location"]).get("name", item["location"]), GameState.get_seat(item["location"], item["seat"]).get("name", item["seat"])]


func _show_departure(ticket_id: String) -> void:
	if not GameState.get_active_travel().is_empty():
		_refresh_travel()
		return
	for ticket in GameState.get_tickets():
		if ticket["id"] != ticket_id or ticket["status"] != "owned":
			continue
		_travel_confirm = ticket_id
		_clear_content(_travel_content)
		_travel_content.add_child(_label("出发确认", 18, Color("3986c9")))
		_travel_content.add_child(_label(_place_seat(ticket), 22))
		var art := TextureRect.new()
		art.texture = GameState.ContentManager.texture(str(GameState.get_location(ticket["location"]).get("ticket_art_crop", "")))
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		art.custom_minimum_size.y = 120
		_travel_content.add_child(art)
		_travel_content.add_child(_wrapped(_seat_summary(ticket["location"], ticket["seat"]), 14))
		_travel_content.add_child(_wrapped("确认后开始计时，途中无法取消或改签。关闭后也会继续旅行。", 13, Color("718aa4")))
		var confirm := _button("确认出发", true)
		confirm.name = "ConfirmDeparture"
		confirm.custom_minimum_size.y = 42
		confirm.pressed.connect(_confirm_departure)
		_travel_content.add_child(confirm)
		var cancel := _button("返回选票")
		cancel.custom_minimum_size.y = 36
		cancel.pressed.connect(_refresh_travel)
		_travel_content.add_child(cancel)


func _confirm_departure() -> void:
	var result := GameState.start_travel(_travel_confirm)
	if result["ok"]:
		close_travel()
		show_toast("出发了")
	else:
		show_toast({"active": "已有一段旅行正在进行", "save_failed": "保存失败，请重试", "busy": "请稍候"}.get(result["reason"], "车票不可用"))
		_refresh_travel()


func _duration(seconds: int) -> String:
	var safe := maxi(0, seconds)
	@warning_ignore("integer_division")
	return "%02d:%02d:%02d" % [safe / 3600, safe % 3600 / 60, safe % 60]


func _refresh_travel_clock() -> void:
	if not _travel_overlay.visible or not is_instance_valid(_travel_clock):
		return
	var travel := GameState.get_active_travel()
	if travel.is_empty():
		return
	var now := int(GameState.simulation_now()["epoch"])
	var start := int(GameState._decode_sim_time(travel["started_at"])["epoch"])
	var end := int(GameState._decode_sim_time(travel["ends_at"])["epoch"])
	_travel_clock.text = "已过  %s\n剩余  %s" % [_duration(clampi(now - start, 0, end - start)), _duration(end - now)]


func _on_travel_changed() -> void:
	if GameState.is_traveling() and is_instance_valid(_action_panel):
		_action_panel.hide()
	if _travel_overlay.visible:
		_refresh_travel()


func _on_travel_completed(location_name: String) -> void:
	var pending := GameState.pending_letter_count()
	show_toast(("已回房 · 等待生成/待补信件 %d 封" % pending) if pending > 0 else ("到达%s · 旅行结束" % location_name))
	GameState.session_completed_location = ""


func _add_envelope(message: Dictionary) -> void:
	var envelope := _button("")
	envelope.name = message["id"]
	envelope.custom_minimum_size.y = 102
	envelope.pressed.connect(open_letter.bind(message["id"]))
	_chat_content.add_child(envelope)
	var icon := Panel.new()
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := _make_flat_style(Color("dceefa"), 3)
	style.set_border_width_all(1)
	style.border_color = Color("73b3dc")
	icon.add_theme_stylebox_override("panel", style)
	_place(icon, envelope, Rect2(14, 12, 28, 18))
	var fold := Line2D.new()
	fold.points = PackedVector2Array([Vector2(1, 1), Vector2(14, 11), Vector2(27, 1)])
	fold.width = 1
	fold.default_color = Color("73b3dc")
	fold.antialiased = true
	icon.add_child(fold)
	_place(_label("旅行来信", 11, Color("3986c9")), envelope, Rect2(54, 10, 210, 20))
	_place(_label(GameState.letter_provider.display_title(message), 16), envelope, Rect2(14, 33, 305, 28))
	_place(_label("%s · %s · 点击打开信封" % [String(message["created_at"]).left(16).replace("T", " "), "已读" if message["read"] else "未读"], 11, Color("718aa4")), envelope, Rect2(14, 68, 305, 22))
	var seal := _label("已读" if message["read"] else "未读", 11, Color("718aa4") if message["read"] else Color("d84b5f"))
	_place(seal, envelope, Rect2(275, 10, 44, 20))


func open_letter(message_id: String) -> void:
	_refresh_dsh_status()
	var result := GameState.open_travel_letter(message_id)
	if not result["ok"]:
		show_toast("打开失败，请重试")
		return
	var message: Dictionary = result["message"]
	_open_stage5(_letter_overlay)
	_detail_source = "chat"
	$Root/LetterOverlay/LetterPanel/Title.text = GameState.letter_provider.display_title(message)
	_clear_content(_letter_content)
	_letter_content.add_child(_label(GameState.letter_provider.display_title(message), 19))
	var sender := _label(_dsh_name() + " · " + String(message["created_at"]).left(16).replace("T", " "), 11, Color("718aa4"))
	sender.name = "DshSender"
	sender.set_meta("date", String(message["created_at"]).left(16).replace("T", " "))
	_letter_content.add_child(sender)
	_letter_content.add_child(_wrapped(message["body"], 14))
	_letter_content.add_child(_label("照片已存入相簿", 12, Color("397c70")))
	for photo_id in message["photo_ids"]:
		var photo := GameState.get_photo(message["location"], photo_id)
		_add_photo(_letter_content, photo_id, photo.get("caption", "旧版旅行照片"), 320, photo)
	(_letter_content.get_parent() as ScrollContainer).scroll_vertical = 0


func close_letter() -> void:
	_letter_overlay.visible = false
	if _detail_source == "album":
		open_album()
	else:
		open_chat()


func _add_photo(parent: Control, photo_id: String, caption: String, width: float, photo: Dictionary = {}) -> void:
	# 仅加载正式导入资源；旧 ID 不映射到新图，缺图保留安全占位。
	var art := Panel.new()
	art.name = "Photo_" + photo_id
	art.custom_minimum_size = Vector2(width, width * 9.0 / 16.0)
	art.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var colors := {"hz_xihu": Color("bedde6"), "hz_duanqiao": Color("cbdccc"), "hz_leifeng": Color("edd5ac"), "hz_hefang": Color("cec8e0")}
	art.add_theme_stylebox_override("panel", _make_flat_style(colors.get(photo_id, Color("bedde6")), 10))
	parent.add_child(art)
	var texture: Texture2D = null
	var image_path := String(photo.get("path", ""))
	if not image_path.is_empty() and ResourceLoader.exists(image_path, "Texture2D"):
		texture = ResourceLoader.load(image_path, "Texture2D") as Texture2D
	if texture == null and not image_path.is_empty() and FileAccess.file_exists(image_path):
		var raw_image := Image.load_from_file(ProjectSettings.globalize_path(image_path))
		if raw_image != null and not raw_image.is_empty():
			texture = ImageTexture.create_from_image(raw_image)
	if texture != null:
		var image := TextureRect.new()
		image.texture = texture
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		image.mouse_filter = Control.MOUSE_FILTER_IGNORE
		art.add_child(image)
		image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	else:
		push_warning("旅行照片无法加载（未导入、缺失或损坏）: %s [%s]" % [photo_id, image_path])
		var note := _label("旅行照片暂不可用", 11, Color("536e85"))
		note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		art.add_child(note)
		note.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not caption.is_empty():
		parent.add_child(_wrapped(caption, 12))


func open_album() -> void:
	_open_stage5(_album_overlay)
	_refresh_album()


func close_album() -> void:
	_album_overlay.visible = false


func _on_album_changed() -> void:
	if _album_overlay.visible:
		_refresh_album()


func _refresh_album() -> void:
	_clear_content(_album_content)
	var album := GameState.get_album()
	if album.is_empty():
		_empty_message(_album_content, "相簿里还没有照片")
		return
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 9)
	grid.add_theme_constant_override("v_separation", 14)
	_album_content.add_child(grid)
	for photo in album:
		var card := VBoxContainer.new()
		card.custom_minimum_size.x = 160
		grid.add_child(card)
		var button := _button("")
		button.name = "Album_" + photo["photo_id"]
		button.custom_minimum_size = Vector2(160, 90)
		button.pressed.connect(_open_album_photo.bind(photo))
		card.add_child(button)
		var art_box := VBoxContainer.new()
		art_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(art_box)
		_add_photo(art_box, photo["photo_id"], "", 160, GameState.get_photo(photo["location"], photo["photo_id"]))
		card.add_child(_wrapped(photo["caption"], 12))
		card.add_child(_label(_place_seat(photo), 11, Color("718aa4")))


func _open_album_photo(photo: Dictionary) -> void:
	_open_stage5(_letter_overlay)
	_detail_source = "album"
	$Root/LetterOverlay/LetterPanel/Title.text = "照片详情"
	_clear_content(_letter_content)
	_letter_content.add_child(_label(_place_seat(photo), 19))
	_add_photo(_letter_content, photo["photo_id"], photo["caption"], 320, GameState.get_photo(photo["location"], photo["photo_id"]))
	_letter_content.add_child(_label("收藏于 " + String(photo["added_at"]).left(16).replace("T", " "), 11, Color("718aa4")))
	var back := _button("返回相簿")
	back.custom_minimum_size.y = 36
	back.pressed.connect(open_album)
	_letter_content.add_child(back)
	(_letter_content.get_parent() as ScrollContainer).scroll_vertical = 0


func _make_badge(parent: Control, rectangle: Rect2) -> Label:
	var badge := _label("", 10, Color.WHITE)
	badge.name = "UnreadBadge"
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_theme_stylebox_override("normal", _make_flat_style(Color("d84b5f"), 9))
	_place(badge, parent, rectangle)
	badge.visible = false
	return badge


func _build_chat() -> void:
	var panel: Control = $Root/ChatOverlay/ChatPanel
	_place(_label("聊天与来信", 19), panel, Rect2(16, 12, 200, 32))
	var close := _button("×")
	close.name = "CloseButton"
	close.pressed.connect(close_chat)
	_place(close, panel, Rect2(321, 12, 30, 30))
	_place(_label("用户 DSH · 聊天与来信", 12, Color("718aa4")), panel, Rect2(16, 53, 333, 24))
	_chat_content = _scroll_content(panel, Rect2(16, 92, 333, 334))
	_chat_input = LineEdit.new()
	_chat_input.name = "ChatInput"
	_chat_input.placeholder_text = "说点什么…"
	_chat_input.max_length = 500
	_chat_input.add_theme_color_override("font_color", COLOR_ITEM_TEXT)
	_chat_input.add_theme_color_override("font_placeholder_color", Color("718aa4"))
	_chat_input.add_theme_color_override("caret_color", Color("3986c9"))
	for state_name in ["normal", "focus"]:
		var input_style := _make_flat_style(Color("f4f9ff"), 10)
		input_style.set_border_width_all(1)
		input_style.border_color = Color("3986c9") if state_name == "focus" else Color("bdd8ef")
		input_style.content_margin_left = 10
		input_style.content_margin_right = 10
		_chat_input.add_theme_stylebox_override(state_name, input_style)
	_chat_input.add_theme_font_size_override("font_size", 14)
	_place(_chat_input, panel, Rect2(16, 472, 259, 38))
	_chat_input.text_submitted.connect(func(_text: String): _send_chat())
	_send_button = _button("发送")
	_send_button.name = "SendChatButton"
	_send_button.pressed.connect(_send_chat)
	_place(_send_button, panel, Rect2(281, 472, 68, 38))
	_chat_status = _label("", 11, Color("718aa4"))
	_chat_status.name = "ChatStatus"
	_place(_chat_status, panel, Rect2(16, 435, 278, 28))
	_retry_button = _button("重试")
	_retry_button.name = "RetryChatButton"
	_place(_retry_button, panel, Rect2(298, 435, 51, 28))
	_retry_button.visible = false
	_retry_button.pressed.connect(_retry_chat)
	# 重启只恢复未获回复的消息供手动重试，不自动联网。
	var history := GameState.get_chat_messages()
	for message in history:
		if message.get("kind") == "chat" and message.get("role") == "user" and not history.any(func(m: Dictionary): return m.get("reply_to", "") == message["id"]):
			_failed_message = message
	if not _failed_message.is_empty():
		_chat_status.text = "未接入 DSH，或 DSH 暂时不可用"
		_retry_button.visible = true
	_read_button = _button("全部标记已读")
	_read_button.name = "MarkReadButton"
	_read_button.pressed.connect(_mark_chat_read)
	_place(_read_button, panel, Rect2(16, 524, 333, 36))
	_chat.visible = false


func _send_chat() -> void:
	if _chat_pending:
		return
	var text := _chat_input.text.strip_edges()
	if text.is_empty():
		return
	var message := GameState.append_chat(text, "user", _chat_session)
	if message.is_empty():
		_chat_status.text = "保存失败，请重试"
		return
	_chat_input.clear()
	_request_chat(message)


func _retry_chat() -> void:
	if not _chat_pending and not _failed_message.is_empty():
		_request_chat(_failed_message)


func _request_chat(message: Dictionary) -> void:
	_chat_pending = true
	_send_button.disabled = true
	_send_button.text = "发送中"
	_retry_button.visible = false
	_chat_status.text = "正在输入…"
	_scroll_chat_bottom.call_deferred()
	var session := String(message.get("session_id", _chat_session))
	var response: Dictionary = await _companion.post("/chat", {"session_id": session, "messages": GameState.chat_context(session, message["id"]), "user_message": message["text"], "persona": "ds"})
	var reply: Variant = response.get("data", {}).get("reply", "")
	var success := false
	if response["ok"] and reply is String and not reply.strip_edges().is_empty() and reply.length() <= 500:
		success = not GameState.append_chat(reply, "ds", session, message["id"]).is_empty()
	_chat_pending = false
	_send_button.disabled = false
	_send_button.text = "发送"
	if success:
		_failed_message = {}
		_chat_status.text = ""
	else:
		_failed_message = message
		_chat_status.text = "DS 暂时没回应，等会儿再试"
		_retry_button.visible = true
	_scroll_chat_bottom.call_deferred()


func _scroll_chat_bottom() -> void:
	var scroll := _chat_content.get_parent() as ScrollContainer
	scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)


func open_chat() -> void:
	_refresh_dsh_status()
	close_settings()
	_close_stage5()
	close_menu()
	close_calendar()
	close_shop()
	close_backpack()
	_hide_toast()
	_chat.visible = true
	_refresh_chat()


func close_chat() -> void:
	_chat.visible = false


func _mark_chat_read() -> void:
	if not GameState.mark_chat_read() and GameState.get_unread_count() > 0:
		show_toast("保存失败，请重试")


func _on_messages_changed() -> void:
	var has_new := false
	var has_letter := false
	for message in GameState.get_chat_messages():
		if not _seen_message_ids.has(message["id"]):
			has_new = has_new or message.get("role", "ds") == "ds"
			has_letter = has_letter or message["kind"] == "travel_letter"
			_seen_message_ids[message["id"]] = true
	var unread := GameState.get_unread_count()
	for badge in [_chat_badge, _entry_badge]:
		badge.visible = unread > 0
		badge.text = str(unread) if unread < 100 else "99+"
	if _chat.visible:
		_refresh_chat()
	elif has_new and not (_letter_overlay.visible and _detail_source == "chat"):
		show_toast("收到一封旅行来信" if has_letter else "收到一条消息")


func _refresh_chat() -> void:
	_clear_content(_chat_content)
	var messages := GameState.get_chat_messages()
	_read_button.disabled = GameState.get_unread_count() == 0
	_read_button.text = "全部已读" if _read_button.disabled else "全部标记已读"
	if messages.is_empty():
		_empty_message(_chat_content, "还没有新消息")
		return
	for message in messages:
		if message["kind"] == "travel_letter":
			_add_envelope(message)
			continue
		var card := PanelContainer.new()
		card.name = String(message["id"])
		var style := _make_flat_style(Color("e5f4ee") if message.get("role", "ds") == "user" else Color("eef6ff"), 12)
		style.content_margin_left = 14
		style.content_margin_right = 14
		style.content_margin_top = 12
		style.content_margin_bottom = 12
		card.add_theme_stylebox_override("panel", style)
		_chat_content.add_child(card)
		var content := VBoxContainer.new()
		content.add_theme_constant_override("separation", 8)
		card.add_child(content)
		content.add_child(_label("%s  ·  %s  ·  %s" % ["我" if message.get("role", "ds") == "user" else _dsh_name(), String(message["created_at"]).left(16).replace("T", " "), "已读" if message["read"] else "未读"], 11, Color("718aa4")))
		var text := _label(message["text"], 14)
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		content.add_child(text)

func _dsh_name() -> String:
	if not _companion.connection.has("connected"):
		return "正在读取 DSH 状态…"
	return str(_companion.connection.get("display_name", "DSH")) if _companion.connection.get("connected", false) else "未接入 DSH"

func _refresh_dsh_status() -> void:
	var connection: Dictionary = await _companion.refresh_connection()
	if _letter_content.has_node("DshSender"):
		var sender: Label = _letter_content.get_node("DshSender")
		sender.text = _dsh_name() + " · " + str(sender.get_meta("date", ""))
	if _chat.visible:
		_refresh_chat()
	if not _chat_pending:
		_chat_status.text = "已接入 DSH · " + _dsh_name() if connection.get("connected", false) else "未接入 DSH · 旅行信件等待生成"

func open_diary() -> void:
	close_calendar()
	close_menu()
	close_chat()
	close_settings()
	_close_stage5()
	close_shop()
	close_backpack()
	if $Root.has_node("DiaryPanel"):
		$Root.get_node("DiaryPanel").queue_free()
	if $Root.has_node("DiaryBackdrop"):
		$Root.get_node("DiaryBackdrop").queue_free()
	var backdrop := ColorRect.new()
	backdrop.name = "DiaryBackdrop"
	backdrop.color = Color(0, 0, 0, 0.35)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	$Root.add_child(backdrop)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var diary := preload("res://scripts/ui/diary_panel.gd").new()
	diary.client = _companion
	$Root.add_child(diary)
	diary.tree_exiting.connect(func():
		if is_instance_valid(backdrop):
			backdrop.queue_free()
	)


func _build_action_panel() -> void:
	var room := get_parent()
	if not room.has_signal("character_clicked"):
		return
	_action_panel = PanelContainer.new()
	_action_panel.name = "ActionPanel"
	_action_panel.theme = preload("res://assets/ui/theme/game_theme.tres")
	_action_panel.add_theme_stylebox_override("panel", _make_flat_style(Color("f9fcff"), 12))
	_action_panel.z_index = 25
	$Root.add_child(_action_panel)
	_action_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_action_panel.offset_left = -150
	_action_panel.offset_right = -10
	_action_panel.offset_top = 170
	_action_panel.offset_bottom = 328
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	_action_panel.add_child(column)
	var close := _button("动作 · 关闭")
	close.custom_minimum_size.y = 30
	close.pressed.connect(_action_panel.hide)
	column.add_child(close)
	var scroll := ScrollContainer.new()
	scroll.name = "ActionScroll"
	scroll.custom_minimum_size = Vector2(124, 116)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	column.add_child(scroll)
	var actions := VBoxContainer.new()
	actions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_theme_constant_override("separation", 4)
	scroll.add_child(actions)
	var whale := room.get_node("CharacterLayer/WhaleGirl")
	var manifest: Dictionary = whale.available_actions()
	for action in manifest:
		var button := _button("")
		button.name = "Action_" + action
		button.text = {"idle": "待机/发呆", "work_think": "思考"}.get(action, manifest[action].get("display_name", action))
		button.custom_minimum_size.y = 36
		button.add_theme_font_size_override("font_size", 14)
		button.pressed.connect(_play_character_action.bind(String(action)))
		actions.add_child(button)
	_action_panel.hide()
	room.character_clicked.connect(_toggle_action_panel)


func _toggle_action_panel() -> void:
	if GameState.is_traveling():
		_action_panel.hide()
		return
	_action_panel.visible = not _action_panel.visible


func _play_character_action(action: String) -> void:
	if GameState.is_traveling():
		_action_panel.hide()
		return
	get_parent().get_node("CharacterLayer/WhaleGirl").play(action)
