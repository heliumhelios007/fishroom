extends RefCounted
## Data-only ZIP installer. The save's content_version is the single commit pointer.
const BASE_VERSION := "base-1"
const GAME_VERSION := "1.0.0"
const ROOT := "user://content/"
const MAX_ZIP := 128 * 1024 * 1024
const MAX_TOTAL := 256 * 1024 * 1024
const MAX_FILE := 32 * 1024 * 1024
const CATALOGS := {"food": ["data/shop_food.json", "items"], "furniture": ["data/shop_furniture.json", "items"], "locations": ["data/travel_locations.json", "locations"], "furniture_render": ["assets/furniture/furniture_manifest.json", "items"]}
var content_version := BASE_VERSION
var catalogs: Dictionary = {}
var aliases: Dictionary = {}
var error := ""

func _init() -> void:
	reset()

func reset() -> void:
	content_version = BASE_VERSION
	aliases = {}
	catalogs = {}
	for kind in CATALOGS:
		var spec: Array = CATALOGS[kind]
		var value: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://" + spec[0]))
		catalogs[kind] = value.get(spec[1], []).duplicate(true) if value is Dictionary else []

static func safe_path(path: String) -> bool:
	if path.is_empty() or path.length() > 200 or path.contains("\\") or path.contains(":") or path.begins_with("/"):
		return false
	for part in path.split("/"):
		if part in ["", ".", ".."] or part.begins_with(".") or part.ends_with(".") or part.ends_with(" "):
			return false
		var stem := part.get_slice(".", 0).to_upper()
		if stem in ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"]:
			return false
		for c in part:
			if c.unicode_at(0) < 32:
				return false
	return true

static func allowed(path: String) -> bool:
	if not safe_path(path):
		return false
	if path == "content_manifest.json":
		return true
	if path.begins_with("data/"):
		return path.get_extension() == "json" and path.count("/") == 1
	return path.begins_with("assets/") and path.get_extension() in ["png", "jpg", "jpeg", "webp", "wav", "ogg", "mp3", "ttf", "otf", "json", "tscn"]

static func version_parts(value: String) -> Array:
	var parts := value.split(".")
	if parts.size() != 3:
		return []
	var result: Array = []
	for part in parts:
		if part.is_empty() or not part.is_valid_int() or int(part) < 0 or str(int(part)) != part:
			return []
		result.append(int(part))
	return result

static func supports(minimum: String) -> bool:
	var required := version_parts(minimum)
	var current := version_parts(GAME_VERSION)
	if required.is_empty():
		return false
	for i in range(3):
		if current[i] != required[i]:
			return current[i] > required[i]
	return true

func fail(message: String) -> Dictionary:
	error = message
	return {}

## Inspect central directory before decompression; ZIPReader does not expose Unix mode.
func zip_index(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > MAX_ZIP or file.get_length() < 22:
		return fail("内容包无法读取或超过 128 MiB")
	var bytes := file.get_buffer(file.get_length())
	file.close()
	var end := -1
	for i in range(bytes.size() - 22, maxi(-1, bytes.size() - 65558), -1):
		if bytes.decode_u32(i) == 0x06054b50 and i + 22 + bytes.decode_u16(i + 20) == bytes.size():
			end = i
			break
	if end < 0 or bytes.decode_u16(end + 4) != 0 or bytes.decode_u16(end + 6) != 0:
		return fail("不支持分卷或无效 ZIP")
	var count := bytes.decode_u16(end + 10)
	var offset := bytes.decode_u32(end + 16)
	if count < 1 or count > 1024 or bytes.decode_u16(end + 8) != count or offset + bytes.decode_u32(end + 12) != end:
		return fail("ZIP 目录无效（不支持 ZIP64）")
	var index := {}
	var folded := {}
	var total := 0
	for unused in range(count):
		if offset + 46 > end or bytes.decode_u32(offset) != 0x02014b50:
			return fail("ZIP 目录损坏")
		var flags := bytes.decode_u16(offset + 8)
		var method := bytes.decode_u16(offset + 10)
		var size := bytes.decode_u32(offset + 24)
		var name_size := bytes.decode_u16(offset + 28)
		var next := offset + 46 + name_size + bytes.decode_u16(offset + 30) + bytes.decode_u16(offset + 32)
		if next > end or name_size == 0:
			return fail("ZIP 文件名损坏")
		var raw := bytes.slice(offset + 46, offset + 46 + name_size)
		var name := raw.get_string_from_utf8()
		var mode := (bytes.decode_u32(offset + 38) >> 16) & 0xf000
		# Reject symlinks, devices, directories/reparse attributes and encrypted members.
		if name.to_utf8_buffer() != raw or not allowed(name) or folded.has(name.to_lower()) or mode not in [0, 0x8000] or (bytes.decode_u32(offset + 38) & 0x410) != 0 or (flags & 1) != 0 or method not in [0, 8] or size > MAX_FILE:
			return fail("拒绝非法路径、符号链接、重复项或非数据文件")
		var local := bytes.decode_u32(offset + 42)
		if local + 30 > offset or bytes.decode_u32(local) != 0x04034b50:
			return fail("ZIP 本地目录无效")
		var local_name_size := bytes.decode_u16(local + 26)
		if local + 30 + local_name_size > offset or bytes.slice(local + 30, local + 30 + local_name_size) != raw:
			return fail("ZIP 本地路径不一致")
		total += size
		if total > MAX_TOTAL:
			return fail("内容解压后超过 256 MiB")
		index[name] = size
		folded[name.to_lower()] = true
		offset = next
	if offset != end:
		return fail("ZIP 目录长度不一致")
	return index

func verify(path: String) -> Dictionary:
	error = ""
	var index := zip_index(path)
	if index.is_empty():
		return {}
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return fail("ZIP 无法打开")
	var manifest: Variant = JSON.parse_string(zip.read_file("content_manifest.json").get_string_from_utf8())
	if not manifest is Dictionary:
		zip.close()
		return fail("缺少 manifest")
	var result := verify_manifest(zip, index, manifest)
	zip.close()
	return result

func verify_manifest(zip: ZIPReader, index: Dictionary, manifest: Dictionary) -> Dictionary:
	var ver: Variant = manifest.get("content_version")
	var minimum: Variant = manifest.get("min_game_version")
	if not ver is String or version_parts(ver).is_empty() or not minimum is String or not supports(minimum):
		return fail("内容版本无效或游戏版本过低")
	var files: Variant = manifest.get("files")
	var hashes: Variant = manifest.get("sha256")
	var entries: Variant = manifest.get("entrypoints")
	if not files is Array or not hashes is Dictionary or not entries is Dictionary or files.size() + 1 != index.size() or hashes.size() != files.size():
		return fail("manifest 文件清单不完整")
	var seen := {}
	var payload := {}
	for path in files:
		if not path is String or path == "content_manifest.json" or not index.has(path) or seen.has(path) or not hashes.get(path) is String:
			return fail("manifest 含未知或重复文件")
		seen[path] = true
		var data := zip.read_file(path)
		if data.size() != index[path]:
			return fail("文件大小不一致")
		var digest := HashingContext.new()
		digest.start(HashingContext.HASH_SHA256)
		digest.update(data)
		if digest.finish().hex_encode() != hashes[path].to_lower():
			return fail("SHA256 校验失败：" + path)
		payload[path] = data
	for path in files:
		if path.get_extension() == "json":
			var value: Variant = JSON.parse_string(payload[path].get_string_from_utf8())
			if not value is Dictionary or not safe_values(value, files):
				return fail("JSON 或资源引用无效：" + path)
		elif path.get_extension() == "tscn" and not safe_scene(payload[path].get_string_from_utf8(), files):
			return fail("场景只允许无脚本的静态视觉资源")
	var merged := {}
	for kind in CATALOGS:
		merged[kind] = catalogs[kind].duplicate(true)
	for kind in entries:
		if not CATALOGS.has(kind) or not entries[kind] is String or not files.has(entries[kind]):
			return fail("entrypoints 无效")
		var doc: Dictionary = JSON.parse_string(payload[entries[kind]].get_string_from_utf8())
		var rows: Variant = doc.get(CATALOGS[kind][1])
		if not rows is Array or not valid_rows(kind, rows):
			return fail("catalog 结构无效：" + kind)
		merged[kind] = merge_rows(merged[kind], rewrite_paths(rows, ROOT + ver + "/"), doc.get("deleted_ids", []))
		if merged[kind].is_empty() and not error.is_empty():
			return {}
	var maps: Variant = manifest.get("aliases", manifest.get("migration_map", {}))
	if not valid_aliases(maps, merged):
		return fail("alias 无效、成环或目标不存在；照片 ID 不允许迁移")
	return {"manifest": manifest, "payload": payload, "catalogs": merged, "aliases": maps}

static func safe_values(value: Variant, files: Array) -> bool:
	if value is Dictionary:
		for key in value:
			if str(key).to_lower() in ["script", "script_path", "executable", "autoload"] or not safe_values(value[key], files):
				return false
	elif value is Array:
		for item in value:
			if not safe_values(item, files):
				return false
	elif value is String:
		if value.begins_with("res://"):
			return value.begins_with("res://assets/") and allowed(value.trim_prefix("res://")) and (FileAccess.file_exists(value) or ResourceLoader.exists(value))
		if value.begins_with("assets/"):
			return files.has(value)
		if value.contains("://") or value.begins_with("/") or value.contains("..\\") or value.contains("../") or (value.length() > 2 and value[1] == ":"):
			return false
	return true

static func safe_scene(source: String, files: Array) -> bool:
	# Content scenes are optional static assets, never automatically instantiated.
	var types := ["Node2D", "Sprite2D", "Control", "TextureRect", "Label", "ColorRect", "Texture2D", "FontFile", "StyleBoxFlat"]
	if not source.begins_with("[gd_scene"):
		return false
	var re := RegEx.new()
	re.compile('(?:type|path)="([^"]+)"')
	for line in source.split("\n"):
		var lower := line.to_lower()
		if lower.contains("script") or lower.contains("instance=") or lower.contains("[connection") or lower.contains("preload(") or lower.contains("load(") or lower.contains("uid://"):
			return false
		for match in re.search_all(line):
			var value := match.get_string(1)
			if match.get_string().begins_with("type") and value not in types:
				return false
			if match.get_string().begins_with("path") and not (value.begins_with("res://assets/") and safe_values(value, files)):
				return false
	return true

static func valid_archive(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	for kind in value:
		if not value[kind] is Dictionary:
			return false
		for id in value[kind]:
			if not value[kind][id] is Dictionary:
				return false
	return true

static func rewrite_paths(value: Variant, root: String) -> Variant:
	if value is Dictionary:
		var result := {}
		for key in value:
			result[key] = rewrite_paths(value[key], root)
		return result
	if value is Array:
		return value.map(func(item: Variant): return rewrite_paths(item, root))
	if value is String and value.begins_with("assets/"):
		return root + value
	return value

static func valid_rows(kind: String, rows: Array) -> bool:
	var ids := {}
	for row in rows:
		if not row is Dictionary or not row.get("id") is String or row["id"].is_empty() or ids.has(row["id"]):
			return false
		ids[row["id"]] = true
		if kind == "furniture_render":
			if not row.get("source") is String:
				return false
			continue
		if not row.get("name") is String:
			return false
		if kind in ["food", "furniture"]:
			if not whole(row.get("price")) or not row.get("icon") is String:
				return false
		if kind == "food":
			if not row.get("category") is String or not whole(row.get("hunger", 0), 100) or not whole(row.get("thirst", 0), 100):
				return false
		if kind == "locations" and not valid_location(row):
			return false
	return true

static func whole(value: Variant, maximum: int = 1000000000) -> bool:
	return (value is int or value is float) and is_finite(value) and value >= 0 and value <= maximum and floor(value) == value

static func valid_location(row: Dictionary) -> bool:
	if not row.get("seats") is Array or row["seats"].is_empty() or not row.get("photos") is Array or not row.get("ticket_art_crop") is String:
		return false
	var photos := {}
	for photo in row["photos"]:
		if not photo is Dictionary or not photo.get("id") is String or photos.has(photo["id"]) or not photo.get("path") is String or not photo.get("caption") is String:
			return false
		photos[photo["id"]] = true
	var seats := {}
	for seat in row["seats"]:
		if not seat is Dictionary or not seat.get("id") is String or seats.has(seat["id"]) or not seat.get("name") is String or not whole(seat.get("price")) or not whole(seat.get("duration_hours"), 8760) or seat["duration_hours"] < 1 or not seat.get("letters") is Array:
			return false
		seats[seat["id"]] = true
		for i in range(seat["letters"].size()):
			var plan: Variant = seat["letters"][i]
			if not plan is Dictionary or plan.get("index") != i or not whole(plan.get("hour"), int(seat["duration_hours"])) or not plan.get("photo_ids") is Array or not plan.get("scene_prompt", "") is String:
				return false
			for photo_id in plan["photo_ids"]:
				if not photos.has(photo_id):
					return false
	return true

func merge_rows(base: Array, rows: Array, deleted: Variant) -> Array:
	if not deleted is Array:
		fail("deleted_ids 必须是数组")
		return []
	var result: Array = base.filter(func(row: Dictionary): return not deleted.has(row["id"]))
	for row in rows:
		if deleted.has(row["id"]):
			fail("同一 ID 不可同时更新与删除")
			return []
		var found := false
		for i in range(result.size()):
			if result[i]["id"] == row["id"]:
				result[i] = row.duplicate(true)
				found = true
		if not found:
			result.append(row.duplicate(true))
	return result

static func valid_aliases(maps: Variant, merged: Dictionary) -> bool:
	if not maps is Dictionary:
		return false
	for kind in maps:
		if kind not in ["food", "furniture", "locations"] or not maps[kind] is Dictionary:
			return false
		for old in maps[kind]:
			if not old is String or old.is_empty() or not maps[kind][old] is String:
				return false
			var target: String = old
			var seen := {}
			while maps[kind].has(target):
				if seen.has(target):
					return false
				seen[target] = true
				target = maps[kind][target]
			if not merged[kind].any(func(row: Dictionary): return row["id"] == target):
				return false
	return true

func resolve(kind: String, id: String) -> String:
	var target := id
	var map: Dictionary = aliases.get(kind, {})
	for unused in range(map.size()):
		if not map.has(target):
			break
		target = map[target]
	return target

func stage(path: String) -> Dictionary:
	# Each package is cumulative against base, independent of installation order.
	var checker = get_script().new()
	var checked: Dictionary = checker.verify(path)
	if checked.is_empty():
		return fail(checker.error)
	var ver: String = checked["manifest"]["content_version"]
	var destination := ROOT + ver
	if DirAccess.dir_exists_absolute(destination):
		return fail("此版本已安装，请使用新的 content_version")
	var staging := ROOT + "staging-" + str(Time.get_ticks_usec())
	if DirAccess.make_dir_recursive_absolute(staging) != OK:
		return fail("无法创建内容目录")
	for entry in checked["payload"]:
		var target: String = staging.path_join(entry)
		if DirAccess.make_dir_recursive_absolute(target.get_base_dir()) != OK:
			return fail("创建目录失败；旧内容未切换")
		var file := FileAccess.open(target, FileAccess.WRITE)
		if file == null:
			return fail("内容写入失败；旧内容未切换")
		file.store_buffer(checked["payload"][entry])
		file.flush()
		var err := file.get_error()
		file.close()
		if err != OK:
			return fail("内容写入失败；旧内容未切换")
	# Keep verified source for full validation at startup; no unverified resource load.
	if DirAccess.copy_absolute(path, staging + "/package.zip") != OK or DirAccess.rename_absolute(staging, destination) != OK:
		return fail("内容原子安装失败；旧内容未切换")
	return checked

func activate(checked: Dictionary) -> void:
	catalogs = checked["catalogs"].duplicate(true)
	aliases = checked["aliases"].duplicate(true)
	content_version = checked["manifest"]["content_version"]

func restore(ver: String) -> bool:
	reset()
	if ver == BASE_VERSION:
		return true
	if version_parts(ver).is_empty():
		return false
	var checked := verify(ROOT + ver + "/package.zip")
	if checked.is_empty():
		return false
	# Compare installed payloads too: rehash against verified ZIP before use.
	for path in checked["payload"]:
		var target: String = ROOT + ver + "/" + path
		if FileAccess.get_file_as_bytes(target) != checked["payload"][path]:
			return false
	activate(checked)
	return true

static func texture(path: String) -> Texture2D:
	if path.begins_with("user://content/"):
		var image := Image.load_from_file(ProjectSettings.globalize_path(path))
		return ImageTexture.create_from_image(image) if image != null and not image.is_empty() else null
	return load(path) as Texture2D if ResourceLoader.exists(path, "Texture2D") else null
