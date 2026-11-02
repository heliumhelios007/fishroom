extends Node2D
signal action_finished(action: String)
## dsh-pet 鲸鱼娘帧动画播放器（技术验证版）
##
## 素材来自 PC2005-cloud/dsh-pet：
##   代码 MIT；美术非商业使用，公开二创需署名。详见 assets/character/dsh_pet/CREDITS.md。
##
## 原始素材是 640×360 的 VP9-alpha WebM，Godot 不能直接播透明 WebM，
## 所以离线用 ffmpeg 转成 15fps PNG 序列（每帧已裁到角色/特效的并集 bbox）。
## manifest 里的 anchor 是“脚底中心”在裁剪图里的坐标；根节点放在房间地面，
## Sprite2D 用 centered=false 往左上偏移，切换不同尺寸的动作时脚底仍然贴地。

const DEFAULT_MANIFEST := "res://assets/character/dsh_pet/character_manifest.json"

@export_file("*.json") var manifest_path: String = DEFAULT_MANIFEST
@export var start_action := "idle"
@export var autoplay := true
# 点击回应/伸懒腰这类一次性动作播完自动回 idle；想让它停在最后一帧就关掉。
@export var return_to_idle := true

@onready var sprite: Sprite2D = $Sprite
@onready var shadow: Sprite2D = $Shadow

var _actions: Dictionary = {}
var _frames: Array[Texture2D] = []
var _fps := 15.0
var _clock := 0.0
var _playing := false
var _loop := true
var _current := ""


func _ready() -> void:
	_read_manifest()
	if autoplay:
		play(start_action)


func _read_manifest() -> void:
	var text := FileAccess.get_file_as_string(manifest_path)
	var data = JSON.parse_string(text)
	if data is Dictionary:
		_actions = data.get("actions", {})
	else:
		push_error("whale_girl: manifest 解析失败: " + manifest_path)


# 播放一个动作。技术验证版只缓存当前动作，切动作时旧帧会释放，
# 避免 150+ 张 640×360 RGBA 纹理同时占显存；正式版建议做图集/压缩纹理。
func play(action: String) -> void:
	if not _actions.has(action):
		push_warning("whale_girl: 没有动作 " + action)
		return
	if action == _current and _playing:
		return

	var entry: Dictionary = _actions[action]
	var loaded: Array[Texture2D] = []
	for path in entry.get("frames", []):
		var tex = load(String(path))
		if tex is Texture2D:
			loaded.append(tex)
	if loaded.is_empty():
		push_warning("whale_girl: 动作没有加载到帧: " + action)
		return

	_frames = loaded
	_fps = float(entry.get("fps", 15.0))
	_loop = bool(entry.get("loop", true))
	_clock = 0.0
	_current = action
	_playing = true
	sprite.texture = _frames[0]

	# 从 manifest 取裁剪图尺寸和脚底锚点；不同动作的裁剪尺寸不同，
	# 所以每次切换都要重算 Sprite2D 的偏移，保证脚底始终在根节点 (0,0)。
	var size: Array = entry.get("size", [0, 0])
	var anchor: Array = entry.get("anchor", [float(size[0]) / 2.0, float(size[1])])
	sprite.centered = false
	sprite.position = Vector2(-float(anchor[0]), -float(anchor[1]))

	# 影子按角色宽度缩放，固定贴在脚底；影子纹理原宽 256。
	if shadow:
		shadow.scale = Vector2(float(size[0]) / 256.0, 0.8)


func _process(delta: float) -> void:
	if not _playing or _frames.is_empty():
		return
	_clock += delta * _fps
	var idx := int(_clock)
	if idx >= _frames.size():
		if _loop:
			idx = idx % _frames.size()
		else:
			# 一次性动作：停在最后一帧，发信号；默认自动回 idle，
			# 这样点击回应不会一直循环爱心/生气。
			_playing = false
			sprite.texture = _frames[_frames.size() - 1]
			action_finished.emit(_current)
			if return_to_idle and _current != "idle":
				play("idle")
			return
	if sprite.texture != _frames[idx]:
		sprite.texture = _frames[idx]


func current_action() -> String:
	return _current


func available_actions() -> Dictionary:
	return _actions.duplicate(true)


func contains_screen_point(point: Vector2) -> bool:
	return is_visible_in_tree() and sprite.texture != null and sprite.get_rect().has_point(sprite.get_global_transform_with_canvas().affine_inverse() * point)


func stop() -> void:
	_playing = false
