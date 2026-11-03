extends Node
## One display policy for room and UI. Never reads or writes game/save data.

enum LayoutMode { MOBILE, DESKTOP }

const MOBILE_DESIGN := Vector2i(405, 720)
const DESKTOP_DEFAULT := Vector2i(1280, 720)
const DESKTOP_MINIMUM := Vector2i(960, 540)
const ROOM_SIZE := Vector2(1920, 1080)
const SAFE_MARGIN := 24.0

var mode: LayoutMode = LayoutMode.MOBILE
var _windowed_size := DESKTOP_DEFAULT
var _windowed_position := Vector2i.ZERO


static func choose_mode(mobile: bool, windows: bool, window_size: Vector2i) -> LayoutMode:
	# A wide Android device must still use the existing mobile viewfinder.
	if mobile:
		return LayoutMode.MOBILE
	if windows or float(window_size.x) / maxf(window_size.y, 1.0) >= 1.2:
		return LayoutMode.DESKTOP
	return LayoutMode.MOBILE


func _enter_tree() -> void:
	mode = choose_mode(OS.has_feature("mobile"), OS.has_feature("windows"), get_window().size)
	if not is_desktop():
		return
	var window := get_window()
	# Desktop uses actual window pixels. Mobile keeps canvas_items / expand intact.
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	window.content_scale_size = Vector2i.ZERO
	window.min_size = DESKTOP_MINIMUM
	window.unresizable = false
	RenderingServer.set_default_clear_color(Color("172d46"))


func is_desktop() -> bool:
	return mode == LayoutMode.DESKTOP


func camera_zoom(viewport_size: Vector2) -> float:
	if is_desktop():
		return minf(viewport_size.x / ROOM_SIZE.x, viewport_size.y / ROOM_SIZE.y)
	return maxf(viewport_size.x / ROOM_SIZE.x, viewport_size.y / ROOM_SIZE.y)


func main_panel_size(viewport_size: Vector2) -> Vector2:
	return Vector2(minf(620.0, viewport_size.x * 0.75), minf(640.0, viewport_size.y - SAFE_MARGIN * 2.0))


func _input(event: InputEvent) -> void:
	if not is_desktop() or not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.keycode == KEY_F11 or (event.keycode == KEY_ENTER and event.alt_pressed):
		toggle_fullscreen()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_ESCAPE and get_window().mode == Window.MODE_FULLSCREEN:
		set_fullscreen(false)
		get_viewport().set_input_as_handled()


func toggle_fullscreen() -> void:
	set_fullscreen(get_window().mode != Window.MODE_FULLSCREEN)


func set_fullscreen(enabled: bool) -> void:
	if not is_desktop():
		return
	var window := get_window()
	if enabled:
		_windowed_size = window.size
		_windowed_position = window.position
		window.mode = Window.MODE_FULLSCREEN
	else:
		window.mode = Window.MODE_WINDOWED
		window.size = _windowed_size
		window.position = _windowed_position
