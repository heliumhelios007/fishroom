extends Node2D
signal character_clicked
## fishroom — 房间取景器
##
## 房间原图是 1920x1080 横屏。手机是竖屏，所以这里把「手机屏幕」当成一台
## 取景器：画面按高度铺满，左右拖动即可在房间里平移。后续的家具点击、
## 角色、UI 都挂在这个场景之上。

const ROOM_SIZE := Vector2(1920.0, 1080.0)
const KEYBOARD_PAN_SPEED := 900.0

@onready var camera: Camera2D = $Camera2D
@onready var hint: Label = $UI/Hint
@onready var character_layer: Node2D = $CharacterLayer

var _dragging := false
var _last_pointer_x := 0.0
var _hint_tween: Tween
const CLICK_DRAG_THRESHOLD := 10.0
var _press_position := Vector2.ZERO
var _max_pointer_distance := 0.0
var _pressed_character := false


func _ready() -> void:
	# Editor development only; Android export has no debug scene dependency.
	if OS.has_feature("editor") and OS.has_feature("debug") and not OS.has_feature("android") and not OS.has_feature("fishroom_clean"):
		var server_path := "res://autoload/" + "mcp_interaction_server.gd"
		if ResourceLoader.exists(server_path) and not get_tree().root.has_node("McpInteractionServer"):
			var server: Node = load(server_path).new()
			server.name = "McpInteractionServer"
			get_tree().root.add_child.call_deferred(server)
		var dev_path := "res://scenes/" + "debug/dev_panel.tscn"
		if ResourceLoader.exists(dev_path):
			add_child(load(dev_path).instantiate())
	get_viewport().size_changed.connect(_fit_camera)
	_fit_camera()
	camera.position = ROOM_SIZE * 0.5
	_clamp_camera()
	GameState.travel_changed.connect(_sync_travel_presence)
	GameState.travel_completed.connect(_on_travel_completed)
	$GameUI/CompanionClient.connection_changed.connect(_sync_travel_presence)
	_sync_travel_presence()
	_fade_hint()


func _sync_travel_presence() -> void:
	var was_away := not character_layer.visible
	character_layer.visible = not GameState.is_traveling()
	if was_away and character_layer.visible:
		$CharacterLayer/WhaleGirl.play("idle")
	if DisplayProfile.is_desktop():
		hint.text = "小鲸鱼去旅行了 · F11 全屏" if GameState.is_traveling() else "点击小鲸鱼选择动作 · F11 全屏"
	else:
		hint.text = "小鲸鱼去旅行了 · 环视房间" if GameState.is_traveling() else "按住左右拖动 · 环视房间"


func _on_travel_completed(_location_name: String) -> void:
	_sync_travel_presence()


func _process(delta: float) -> void:
	if DisplayProfile.is_desktop():
		return
	var axis := Input.get_axis("ui_left", "ui_right")
	if axis != 0.0:
		camera.position.x += axis * KEYBOARD_PAN_SPEED * delta
		_clamp_camera()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_begin_pointer(event.position)
		else:
			_end_pointer(event.position)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		_track_pointer(event.position)
		_drag_to(event.position.x)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenTouch and event.index == 0:
		if event.pressed:
			_begin_pointer(event.position)
		else:
			_end_pointer(event.position)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag and event.index == 0:
		_track_pointer(event.position)
		_drag_by(event.relative.x)
		get_viewport().set_input_as_handled()


func _begin_pointer(point: Vector2) -> void:
	_press_position = point
	_max_pointer_distance = 0.0
	_pressed_character = not GameState.is_traveling() and $CharacterLayer/WhaleGirl.contains_screen_point(point)
	_begin_drag(point.x)


func _track_pointer(point: Vector2) -> void:
	_max_pointer_distance = maxf(_max_pointer_distance, point.distance_to(_press_position))


func _end_pointer(point: Vector2) -> void:
	_track_pointer(point)
	var clicked := _dragging and _pressed_character and _max_pointer_distance <= CLICK_DRAG_THRESHOLD
	_end_drag()
	_pressed_character = false
	if clicked and not GameState.is_traveling() and $CharacterLayer/WhaleGirl.contains_screen_point(point):
		character_clicked.emit()


func _begin_drag(screen_x: float) -> void:
	_dragging = true
	_last_pointer_x = screen_x


func _end_drag() -> void:
	_dragging = false


func _drag_to(screen_x: float) -> void:
	_drag_by(screen_x - _last_pointer_x)
	_last_pointer_x = screen_x


func _drag_by(screen_dx: float) -> void:
	if DisplayProfile.is_desktop() or is_zero_approx(screen_dx):
		return
	# 手指往右拖，画面跟着往右走，所以相机往左移。
	camera.position.x -= screen_dx / camera.zoom.x
	_clamp_camera()


func _fit_camera() -> void:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	# Mobile keeps cover; desktop fits the entire room without moving world nodes.
	var fit_zoom := DisplayProfile.camera_zoom(viewport_size)
	camera.zoom = Vector2(fit_zoom, fit_zoom)
	# Fit may see beyond the room on non-16:9 windows. Allow symmetric margins.
	var visible_size := viewport_size / fit_zoom
	var margin := (visible_size - ROOM_SIZE).max(Vector2.ZERO) * 0.5 if DisplayProfile.is_desktop() else Vector2.ZERO
	camera.limit_left = -ceili(margin.x)
	camera.limit_right = int(ROOM_SIZE.x) + ceili(margin.x)
	camera.limit_top = -ceili(margin.y)
	camera.limit_bottom = int(ROOM_SIZE.y) + ceili(margin.y)
	_clamp_camera()


# 把相机中心夹在房间内部：half_w/half_h 是当前 zoom 下可见区域的一半。
# 竖屏 405×720 时 half_w≈303.75、half_h=540，所以 x 只能落在 [303.75, 1616.25]，
# 否则画面边缘会露出房间图外的底色。
func _clamp_camera() -> void:
	if DisplayProfile.is_desktop():
		camera.position = ROOM_SIZE * 0.5
		return
	var viewport_size := get_viewport_rect().size
	var half_w := viewport_size.x / (2.0 * camera.zoom.x)
	var half_h := viewport_size.y / (2.0 * camera.zoom.y)
	camera.position.x = clampf(camera.position.x, half_w, ROOM_SIZE.x - half_w)
	camera.position.y = clampf(camera.position.y, half_h, ROOM_SIZE.y - half_h)


func _fade_hint() -> void:
	if _hint_tween:
		_hint_tween.kill()
	_hint_tween = create_tween()
	_hint_tween.tween_interval(3.5)
	_hint_tween.tween_property(hint, "modulate:a", 0.0, 0.8)
