extends Node2D
## source 已是 1920×1080 透明画布，anchor 只描述内容位置。
## render_offset_y 是单件家具的房间渲染偏移，不影响 source 或商店 icon。

const MANIFEST := "res://assets/furniture/furniture_manifest.json"
var _items: Dictionary = {}


func _ready() -> void:
	GameState.content_changed.connect(_reload_content)
	_reload_content()
	GameState.furniture_changed.connect(_rebuild)


func _reload_content() -> void:
	_items.clear()
	var data: Variant = {"items":GameState.content.catalogs["furniture_render"]}
	if data is Dictionary and data.get("items") is Array:
		for item in data["items"]:
			if item is Dictionary and item.get("id") is String:
				_items[item["id"]] = item
	else:
		push_warning("[FurnitureLayer] 家具 manifest 无效")
	_rebuild()


func _rebuild() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	for item_id in GameState.get_owned_furniture():
		var resolved: String = GameState.content.resolve("furniture", item_id)
		if not _items.has(resolved):
			continue
		# 当前默认窗户已在 room_base 中，不能再叠加一层窗户。
		if _items[resolved].get("room_fixture", false):
			continue
		var source := String(_items[resolved].get("source", ""))
		if source.is_empty():
			push_warning("[FurnitureLayer] 家具 source 不存在：" + source)
			continue
		var texture: Texture2D = GameState.ContentManager.texture(source)
		if texture == null:
			push_warning("[FurnitureLayer] 家具 source 无法加载：" + source)
			continue
		var sprite := Sprite2D.new()
		sprite.name = String(item_id)
		sprite.texture = texture
		sprite.centered = false
		sprite.position = Vector2(0, float(_items[resolved].get("render_offset_y", 0)))
		sprite.z_index = 0
		add_child(sprite)
