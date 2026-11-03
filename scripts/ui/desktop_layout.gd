extends Node
## Positions existing controls; all game actions stay in GameUI.
## No font/canvas scaling: headers keep their size and scroll regions absorb resize.

const PANEL_PATHS := [
	"ShopOverlay/ShopPanel", "BackpackOverlay/BackpackPanel", "ChatOverlay/ChatPanel",
	"TravelOverlay/TravelPanel", "AlbumOverlay/AlbumPanel", "LetterOverlay/LetterPanel",
]
const DESIGN_SIZE := Vector2(365, 576)

var _root: Control
var _panels: Array[Dictionary] = []
var _settings_body: Control
var _settings_scroll: ScrollContainer
var _settings_rows: Array[Dictionary] = []


func setup(root: Control) -> void:
	_root = root
	for path in PANEL_PATHS:
		var panel: Control = root.get_node(path)
		var rows: Array[Dictionary] = []
		for child in panel.get_children():
			if child is Control:
				rows.append({"node": child, "rect": Rect2(child.position, child.size)})
		_panels.append({"node": panel, "rows": rows})
	_build_settings_scroll()
	var fullscreen := Button.new()
	fullscreen.name = "FullscreenButton"
	fullscreen.text = "全屏 · F11"
	fullscreen.tooltip_text = "切换窗口 / 全屏（F11 或 Alt+Enter，Esc 返回窗口）"
	fullscreen.pressed.connect(DisplayProfile.toggle_fullscreen)
	_root.add_child(fullscreen)
	get_viewport().size_changed.connect(apply_layout)
	apply_layout()


func _rect(control: Control, rectangle: Rect2) -> void:
	control.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	control.position = rectangle.position
	control.size = rectangle.size


func _center(control: Control, desired_size: Vector2) -> void:
	_rect(control, Rect2((_root.size - desired_size) * 0.5, desired_size))


func apply_layout() -> void:
	if not is_instance_valid(_root):
		return
	var view := get_viewport().get_visible_rect().size
	# Root is anchored to the viewport; use the new size even during size_changed.
	_root.size = view
	var panel_size := DisplayProfile.main_panel_size(view)
	_rect(_root.get_node("TopLeft"), Rect2(24, 24, 184, 30))
	_rect(_root.get_node("MenuButton"), Rect2(view.x - 64, 24, 40, 40))
	_rect(_root.get_node("FullscreenButton"), Rect2(view.x - 180, 24, 104, 40))
	var menu: Control = _root.get_node("MenuPanel")
	_rect(menu, Rect2(view.x - 204, 76, 180, 360))
	menu.pivot_offset = Vector2(180, 0)
	var toast: Control = _root.get_node("Toast")
	_rect(toast, Rect2((view.x - 560) * 0.5, view.y - 68, 560, 44))
	var toast_label: Label = toast.get_node("ToastLabel")
	toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for entry in _panels:
		var panel: Control = entry["node"]
		_center(panel, panel_size)
		for row in entry["rows"]:
			var control: Control = row["node"]
			var original: Rect2 = row["rect"]
			var target := horizontal_rect(original, panel_size.x)
			if control is ScrollContainer:
				target.size.y += panel_size.y - DESIGN_SIZE.y
			elif original.position.y >= 430:
				target.position.y += panel_size.y - DESIGN_SIZE.y
			_rect(control, target)
			if control is Label:
				control.clip_text = true
				control.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	# Calendar keeps its readable seven-column grid at every desktop size.
	_center(_root.get_node("CalendarOverlay/CalendarPanel"), Vector2(340, 480))
	_layout_settings(panel_size)
	var action: Control = _root.get_node_or_null("ActionPanel")
	if action != null:
		_rect(action, Rect2(view.x - 184, 160, 160, 158))
	# Diary and confirmation views are built on demand.
	layout_transients()


static func horizontal_rect(original: Rect2, width: float) -> Rect2:
	var target := original
	var extra := width - DESIGN_SIZE.x
	if original.position.x >= 230:
		# Wallet, close, retry and send stay against the right edge.
		target.position.x += extra
	elif original.size.x >= 240:
		# Titles, tabs, inputs and scrolls use the available width.
		target.size.x += extra
	return target


func _build_settings_scroll() -> void:
	var panel: Control = _root.get_node("SettingsOverlay/SettingsPanel")
	_settings_scroll = ScrollContainer.new()
	_settings_scroll.name = "DesktopSettingsScroll"
	_settings_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_settings_body = Control.new()
	_settings_body.name = "Body"
	_settings_body.custom_minimum_size = Vector2(0, 536)
	_settings_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Keep the title and close button above the scroll region.
	for child in panel.get_children():
		if child is Control and child.position.y >= 56:
			_settings_rows.append({"node": child, "rect": Rect2(child.position, child.size)})
			child.reparent(_settings_body, false)
	panel.add_child(_settings_scroll)
	_settings_scroll.add_child(_settings_body)


func _layout_settings(panel_size: Vector2) -> void:
	var panel: Control = _root.get_node("SettingsOverlay/SettingsPanel")
	_center(panel, panel_size)
	_rect(panel.get_node("CloseButton"), Rect2(panel_size.x - 44, 12, 30, 30))
	_rect(_settings_scroll, Rect2(16, 56, panel_size.x - 32, panel_size.y - 72))
	for row in _settings_rows:
		var control: Control = row["node"]
		var target := horizontal_rect(row["rect"], panel_size.x)
		if control.name == "ExportButton" or control.name == "ImportButton":
			target.size.x = (panel_size.x - 48) * 0.5
			target.position.x = 16 if control.name == "ExportButton" else panel_size.x * 0.5 + 8
		target.position -= Vector2(16, 56)
		_rect(control, target)


func layout_transients() -> void:
	var diary: Control = _root.get_node_or_null("DiaryPanel")
	if diary != null:
		_center(diary, DisplayProfile.main_panel_size(_root.size))
	for path in ["ShopOverlay/FoodPurchaseConfirmation", "ShopOverlay/PurchaseConfirmation", "SettingsOverlay/ImportConfirmation"]:
		var overlay: Control = _root.get_node_or_null(path)
		if overlay == null:
			continue
		overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		# Import's shade was created with the mobile fixed rectangle.
		for child in overlay.get_children():
			if child is ColorRect:
				child.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		if overlay.has_meta("desktop_scroll"):
			var scroll: ScrollContainer = overlay.get_meta("desktop_scroll")
			var panel: Control = scroll.get_node("Panel")
			_center(scroll, Vector2(panel.size.x + 16, minf(panel.size.y, _root.size.y - 48)))
			continue
		var panel: Control = overlay.get_node("Panel")
		if panel.size.y > _root.size.y - 48:
			# Food confirmation is taller than the 960x540 safe area. Scroll it
			# without shrinking art or moving its quantity/confirm controls.
			var scroll := ScrollContainer.new()
			scroll.name = "DesktopConfirmationScroll"
			scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			overlay.add_child(scroll)
			panel.reparent(scroll, false)
			panel.custom_minimum_size = panel.size
			overlay.set_meta("desktop_scroll", scroll)
			_center(scroll, Vector2(panel.size.x + 16, _root.size.y - 48))
		else:
			_center(panel, panel.size)
