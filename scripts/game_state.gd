extends Node
## fishroom — 本地状态、模拟、旅行及 Stage 6 可选AI正文/用户发起聊天。
##
## 存档只写手机本地 user://save.json，不做云同步；换机导出/导入的 API 先留着，
## 可选 checkin/inventory/tickets、模拟时间、DS 提醒、travel/album，版本仍为 1：
##   version   存档结构版本（迁移用，Stage 1 = 1）
##   currency  鲸元券余额（新号 120）
##   hunger    饥饿值 0–100
##   thirst    口渴值 0–100
##
## 购买只增加库存；食物效果仅由手动使用和定时自动消耗执行。
##
## 保存时机（不在 _process 里保存）：
##   1) 首次运行没有存档 → 立刻写一份 120 的默认档；
##   2) 余额变化（add_currency / set_currency）→ 立即写；
##   3) 退出/关闭窗口/安卓返回键/切后台 → 写一次兜底。
##   4) 自动消耗/新提醒/手动使用/已读立即保存；普通模拟最多每六十秒保存。

## 余额变化时发；UI 的钱包显示只听这个信号，不每帧读。
signal currency_changed(value: int)
signal checkin_changed
signal inventory_changed
signal furniture_changed
signal stats_changed
signal travel_changed
signal album_changed
signal travel_completed(location_name: String)
signal messages_changed
signal ticket_purchased(ticket: Dictionary)
signal content_changed

const ContentManager := preload("res://scripts/content_manager.gd")
var content = ContentManager.new()
var content_version := ContentManager.BASE_VERSION
var _content_archive: Dictionary = {}
var _save_extras: Dictionary = {}
var _food_lots: Dictionary = {}
var _content_unavailable := false
var last_content_error := ""
var last_content_backup_path := ""

const SAVE_PATH := "user://save.json"
const SAVE_VERSION := 1
## 默认窗户已画在 room_base，旧商品 id 仅用于兼容过滤，不退款。
const ROOM_FIXTURE_IDS := ["window_day"]
## 新号初始 120 鲸元券，和 data/economy.json 的 starting_currency 保持一致。
const STARTING_CURRENCY := 120
const DEFAULT_HUNGER := 100.0
const DEFAULT_THIRST := 100.0
const DAILY_REWARD := 40
const STREAK_BONUS := 100
const STREAK_INTERVAL := 7

var currency: int = STARTING_CURRENCY
var hunger: float = DEFAULT_HUNGER
var thirst: float = DEFAULT_THIRST
var version: int = SAVE_VERSION
var _checkin: Dictionary = {"last_date": "", "streak": 0, "month": "", "days": []}
var _checkin_busy := false
var _food_inventory: Dictionary = {}
var _tickets: Array = []
var _purchase_busy := false
var _food_catalog: Array = []
var _furniture_catalog: Array = []
var _owned_furniture: Array[String] = []
var _location_catalog: Array = []
var _shop_data_loaded := false
var last_sim_time := ""
var alerted_hunger := false
var alerted_thirst := false
var _chat_messages: Array = []
var _travel: Dictionary = {}
var _pending_travels: Array = []
var _album: Array = []
var _travel_busy := false
var _travel_save_pending := false
var session_completed_location := ""
var letter_provider: RefCounted = preload("res://scripts/letter_provider.gd").new()
## 仅记录本次运行新生成的提醒，供 UI 首次挂载时补 toast，不写存档。
var session_new_message_ids: Array[String] = []
var _sim_busy := false
var _last_save_msec := 0
## 最近一次 load_game() 的数据来源，只用于日志/排查：
## "created" = 首次运行新建、"loaded" = 读到已有存档、"fallback" = 存档损坏/打不开、"imported" = 导入成功。
var last_load_source := "unknown"
var last_import_error := ""
var _import_busy := false
const IMPORT_BACKUP_PATH := "user://save_before_import.json"
const MAX_IMPORT_BYTES := 8 * 1024 * 1024
const SaveImportValidator := preload("res://scripts/save_import_validator.gd")


func _ready() -> void:
	load_game()
	if last_load_source != "fallback":
		advance_sim_to(_purchase_timestamp())
	var timer := Timer.new()
	timer.wait_time = 5.0
	timer.timeout.connect(tick_sim)
	add_child(timer)
	timer.start()
	print("[GameState] 存档路径：%s（source=%s, currency=%d, version=%d）" % [
		get_save_file_path(), last_load_source, currency, version
	])


func _notification(what: int) -> void:
	# 关窗口 / 安卓返回键 / 切后台 / 退出场景树时落盘。
	# get_tree().quit() 不会发 WM_CLOSE_REQUEST，所以 EXIT_TREE 是最后一道保险。
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_WM_GO_BACK_REQUEST, \
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_EXIT_TREE:
			if last_load_source != "fallback":
				advance_sim_to(_purchase_timestamp(), false)
			save_game()
		NOTIFICATION_APPLICATION_RESUMED:
			tick_sim()


# —————————————————— 存档读写 ——————————————————

## 读存档。返回 true 表示读到了已有存档；false 表示走了默认值（首次运行/损坏/打不开）。
func load_game() -> bool:
	var defaults := _default_state()
	if not FileAccess.file_exists(SAVE_PATH):
		# 首次运行（或玩家手动删档）：先套默认值再立刻写盘，
		# 保证「第一次启动就存在 user://save.json」，而不是等第一次改动才创建。
		_apply_state(defaults)
		save_game()
		last_load_source = "created"
		return false

	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		push_warning("[GameState] 存档打不开（error=%d），本次使用默认值" % FileAccess.get_open_error())
		_apply_state(defaults)
		last_load_source = "fallback"
		return false
	var text := file.get_as_text()
	file.close()

	var json := JSON.new()
	var err := json.parse(text)
	if err != OK or typeof(json.data) != TYPE_DICTIONARY:
		# 损坏的存档只回退内存值，不立刻覆盖磁盘文件，方便事后排查/手工修复。
		push_warning("[GameState] 存档损坏（JSON error=%d），本次使用默认值" % err)
		_apply_state(defaults)
		last_load_source = "fallback"
		return false

	_apply_state(json.data)
	last_load_source = "loaded"
	if version > SAVE_VERSION:
		# 高于当前版本的存档：先按已知字段读，下一次写入会写成当前版本。
		push_warning("[GameState] 存档版本 %d 高于当前 %d，只读取已知字段" % [version, SAVE_VERSION])
	elif version < SAVE_VERSION:
		# 迁移占位：Stage 1 只有 v1，等结构变化时在这里补迁移。
		push_warning("[GameState] 存档版本 %d 低于当前 %d，按 v%d 字段读取" % [
			version, SAVE_VERSION, SAVE_VERSION
		])
	return true


## 把内存状态写成 user://save.json；失败只 warning，不抛异常。
func save_game() -> bool:
	if last_load_source == "fallback" or _content_unavailable:
		return false
	# 先写临时文件再替换正式档；写入失败不破坏原档，购买才能安全回滚内存。
	var temporary := SAVE_PATH + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		push_warning("[GameState] 存档写入失败（error=%d）" % FileAccess.get_open_error())
		return false
	# sort_keys=false：保持 version/currency/hunger/thirst 的书写顺序，方便人眼对档。
	file.store_string(JSON.stringify(_state_to_dict(), "\t", false))
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK or DirAccess.rename_absolute(temporary, SAVE_PATH) != OK:
		DirAccess.remove_absolute(temporary)
		push_warning("[GameState] 存档替换失败，保留原档")
		return false
	_last_save_msec = Time.get_ticks_msec()
	return true


## user:// 相对路径（逻辑用；实际落盘位置由 Godot 决定）。
func get_save_path() -> String:
	return SAVE_PATH


## 展开成绝对路径，只用于打印/调试。
func get_save_file_path() -> String:
	return ProjectSettings.globalize_path(SAVE_PATH)


func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


# —————————————————— 鲸元券 ——————————————————

func get_currency() -> int:
	return currency


## 加/扣鲸元券，返回新余额；不会低于 0。写盘 + 发信号，UI 自动刷新。
func add_currency(amount: int) -> int:
	return set_currency(currency + amount)


func set_currency(value: int) -> int:
	currency = maxi(0, value)
	save_game()
	currency_changed.emit(currency)
	return currency


# —————————————————— 开发者调试 ——————————————————
# 仅 DevPanel 调用；不改变正式玩法规则。时间推进复用 Stage 4/5 的模拟与旅行投递。

func debug_set_currency(value: int) -> int:
	return set_currency(value)


## 从上一次模拟时间再推进 seconds，返回新的 last_sim_time；用于快速测试旅行信/饥饿。
func debug_advance_time(seconds: int) -> String:
	if seconds <= 0 or _sim_busy:
		return last_sim_time
	var now := _decode_sim_time(_purchase_timestamp())
	if now.is_empty():
		return last_sim_time
	var base := _decode_sim_time(last_sim_time)
	var cursor: int = int(base["epoch"]) if not base.is_empty() else int(now["epoch"])
	var target := _sim_iso(cursor + seconds, int(now["bias"]))
	advance_sim_to(target, true)
	return last_sim_time


## 只把模拟基线拉回当前时间；不回滚已经结算的事件/旅行。
func debug_reset_sim_to_now() -> String:
	last_sim_time = _purchase_timestamp()
	save_game()
	stats_changed.emit()
	return last_sim_time


# —————————————————— 饥饿/口渴 ——————————————————

func get_hunger() -> float:
	return hunger


func get_thirst() -> float:
	return thirst


## ISO 必须保留偏移；epoch 只用于间隔比较，餐点按目标时间的本地日期寻找。
func _decode_sim_time(value: Variant) -> Dictionary:
	var bias := int(Time.get_time_zone_from_system()["bias"])
	var text: String
	if value is Dictionary:
		bias = int(value.get("bias", bias))
		text = Time.get_datetime_string_from_datetime_dict(value, false)
	elif value is String:
		text = value
	else:
		return {}
	var local := text.left(19)
	if local.length() != 19 or date_string_to_ordinal(local.left(10)) == 0:
		return {}
	var clock := local.substr(11)
	if local.substr(10, 1) != "T" or clock.length() != 8 or clock.substr(2, 1) != ":" or clock.substr(5, 1) != ":":
		return {}
	if not clock.replace(":", "").is_valid_int() or int(clock.left(2)) > 23 or int(clock.substr(3, 2)) > 59 or int(clock.right(2)) > 59:
		return {}
	if text.length() > 19:
		var suffix := text.substr(19)
		if suffix == "Z":
			bias = 0
		elif suffix.length() == 6 and suffix.left(1) in ["+", "-"] and suffix.substr(3, 1) == ":" and suffix.substr(1).replace(":", "").is_valid_int():
			if int(suffix.substr(1, 2)) > 23 or int(suffix.right(2)) > 59:
				return {}
			bias = (int(suffix.substr(1, 2)) * 60 + int(suffix.right(2))) * (-1 if suffix.left(1) == "-" else 1)
		else:
			return {}
	var epoch := int(Time.get_unix_time_from_datetime_string(local)) - bias * 60
	return {"epoch": epoch, "bias": bias, "iso": _sim_iso(epoch, bias)}


func _sim_iso(epoch: int, bias: int) -> String:
	@warning_ignore("integer_division")
	var offset := "%s%02d:%02d" % ["+" if bias >= 0 else "-", absi(bias) / 60, absi(bias) % 60]
	return Time.get_datetime_string_from_unix_time(epoch + bias * 60) + offset


func tick_sim() -> void:
	if last_load_source == "fallback":
		return
	# 开发者调试把模拟时间推到未来后，保持该未来基线，避免 5 秒 tick 立刻拉回现实。
	var now := _decode_sim_time(_purchase_timestamp())
	var last := _decode_sim_time(last_sim_time)
	if not now.is_empty() and not last.is_empty() and int(last["epoch"]) > int(now["epoch"]):
		return
	advance_sim_to(_purchase_timestamp(), false)


## 显式推进默认保存一次；五秒 tick 仅在消耗/提醒或距上次保存满六十秒时写盘。
func advance_sim_to(now_iso_or_datetime: Variant, force_save: bool = true) -> void:
	if _sim_busy:
		return
	var target := _decode_sim_time(now_iso_or_datetime)
	if target.is_empty():
		return
	_sim_busy = true
	var previous_inventory := _food_inventory.duplicate(true)
	var previous_messages := _chat_messages.size()
	var previous_hunger := hunger
	var previous_thirst := thirst
	var last := _decode_sim_time(last_sim_time)
	var cursor: int = int(target["epoch"]) if last.is_empty() else int(last["epoch"])
	var finish := int(target["epoch"])
	if finish < cursor:
		_sim_busy = false
		return
	var bias := int(target["bias"])
	# 旧档首次只建立基线；启动已有低值仍补一次提醒。未来档/回拨只校时，不倒扣。
	_check_stat_alerts(cursor if cursor <= finish else finish, bias)
	while cursor < finish:
		var event := _next_meal_after(cursor, bias)
		var endpoint := mini(int(event["epoch"]), finish)
		# 离线补算严格按时间顺序：先连续衰减，再吃主食，12 点随后喝饮品。
		_decay_segment(cursor, endpoint, bias)
		cursor = endpoint
		if cursor == int(event["epoch"]):
			_auto_consume("主食")
			if int(event["hour"]) == 12:
				_auto_consume("饮品")
			_check_stat_alerts(cursor, bias)
	last_sim_time = String(target["iso"])
	var travel_events := _advance_travel(target)
	var inventory_updated := previous_inventory != _food_inventory
	var messages_updated := previous_messages != _chat_messages.size()
	if force_save or _travel_save_pending or travel_events["changed"] or inventory_updated or messages_updated or Time.get_ticks_msec() - _last_save_msec >= 60000:
		# 事件保存失败后下个 tick 重试，不改变 delivered 状态，也不会再次生成消息。
		var saved := save_game()
		_travel_save_pending = (_travel_save_pending or travel_events["changed"]) and not saved
	if previous_hunger != hunger or previous_thirst != thirst:
		stats_changed.emit()
	if inventory_updated:
		inventory_changed.emit()
	if messages_updated:
		messages_changed.emit()
	if travel_events["changed"]:
		travel_changed.emit()
		inventory_changed.emit()
	if travel_events["completed"] != "":
		travel_completed.emit(travel_events["completed"])
	_sim_busy = false


func _next_meal_after(epoch: int, bias: int) -> Dictionary:
	var local_seconds := epoch + bias * 60
	var day_start := local_seconds - posmod(local_seconds, 86400)
	for hour in [8, 12, 18]:
		var candidate: int = day_start + hour * 3600 - bias * 60
		if candidate > epoch:
			return {"epoch": candidate, "hour": hour}
	return {"epoch": day_start + 86400 + 8 * 3600 - bias * 60, "hour": 8}


func _decay_segment(start: int, finish: int, bias: int) -> void:
	# 阈值提醒记录实际跌破时刻，不能漏掉餐前跌破、餐后恢复的短暂低值。
	var crossings: Array = []
	if hunger > 30.0 and not alerted_hunger:
		crossings.append({"at": float(start) + (hunger - 30.0) * 48.0 * 36.0, "kind": "hunger"})
	if thirst > 30.0 and not alerted_thirst:
		crossings.append({"at": float(start) + (thirst - 30.0) * 168.0 * 36.0, "kind": "thirst"})
	crossings.sort_custom(func(a: Dictionary, b: Dictionary): return a["at"] < b["at"])
	for crossing in crossings:
		if float(crossing["at"]) <= float(finish) + 0.000001:
			_add_stat_message(crossing["kind"], int(ceil(float(crossing["at"]))), bias)
	var seconds := float(finish - start)
	hunger = clampf(hunger - seconds * 100.0 / (48.0 * 3600.0), 0.0, 100.0)
	thirst = clampf(thirst - seconds * 100.0 / (168.0 * 3600.0), 0.0, 100.0)
	# 消除分段浮点尾差，保证恰好 48/168 小时显示并存储为 0。
	if hunger < 0.000000001:
		hunger = 0.0
	if thirst < 0.000000001:
		thirst = 0.0
	if absf(hunger - 30.0) < 0.000000001:
		hunger = 30.0
	if absf(thirst - 30.0) < 0.000000001:
		thirst = 30.0
	_check_stat_alerts(finish, bias)


func _check_stat_alerts(epoch: int, bias: int) -> void:
	# 同一轮低值只提醒一次；只有恢复到严格大于 30 才重新布防。
	if hunger > 30.0:
		alerted_hunger = false
	elif not alerted_hunger:
		_add_stat_message("hunger", epoch, bias)
	if thirst > 30.0:
		alerted_thirst = false
	elif not alerted_thirst:
		_add_stat_message("thirst", epoch, bias)


func _add_stat_message(kind: String, epoch: int, bias: int) -> void:
	if (kind == "hunger" and alerted_hunger) or (kind == "thirst" and alerted_thirst):
		return
	var templates: Array = ["主人，我有点饿了……", "肚子在咕咕叫了，主人，陪我吃点东西好不好？", "主人，想吃一点暖暖的饭……"] if kind == "hunger" else ["主人，我有点渴了……", "想喝一点水，主人能帮我看看背包吗？", "主人，嗓子有点干，想喝水了……"]
	var id := "msg-%d-%d-%d" % [epoch, Time.get_ticks_usec(), _chat_messages.size()]
	_chat_messages.append({"id": id, "role": "ds", "kind": kind,
		"text": templates[_chat_messages.size() % templates.size()],
		"created_at": _sim_iso(epoch, bias), "read": false})
	session_new_message_ids.append(id)
	if kind == "hunger":
		alerted_hunger = true
	else:
		alerted_thirst = true


func _auto_consume(category: String) -> bool:
	if (category == "主食" and hunger >= 100.0) or (category == "饮品" and thirst >= 100.0):
		return false
	var candidates: Array = []
	for id in _food_inventory:
		var owned := get_owned_food_item(id)
		if not owned.is_empty():
			candidates.append(owned)
	candidates.sort_custom(func(a: Dictionary, b: Dictionary): return int(a["price"]) < int(b["price"]))
	for item in candidates:
		if item.get("category") == category and get_food_count(item["id"]) > 0:
			_consume_food(item)
			return true
	# 水果作为缺少主食/饮品库存时的候补，沿用原来的进食时间和一次一份。
	for item in candidates:
		var effect := "thirst" if category == "饮品" else "hunger"
		if item.get("category") == "水果" and float(item.get(effect, 0)) > 0 and get_food_count(item["id"]) > 0:
			_consume_food(item)
			return true
	return false


func _consume_food(item: Dictionary) -> void:
	var item_id := String(item["id"])
	var owned := get_owned_food_item(item_id)
	if not owned.is_empty():
		item = owned
	if _food_lots.has(item_id) and not _food_lots[item_id].is_empty():
		_food_lots[item_id][0]["count"] -= 1
		if _food_lots[item_id][0]["count"] <= 0:
			_food_lots[item_id].pop_front()
	var count := get_food_count(item_id) - 1
	if count > 0:
		_food_inventory[item_id] = count
	else:
		_food_inventory.erase(item_id)
	# 手动与自动共用 JSON 效果和 cap 100，吃一份只扣一次库存。
	hunger = clampf(hunger + float(item.get("hunger", 0)), 0.0, 100.0)
	thirst = clampf(thirst + float(item.get("thirst", 0)), 0.0, 100.0)
	if hunger > 30.0:
		alerted_hunger = false
	if thirst > 30.0:
		alerted_thirst = false


func food_use_reason(item_id: String) -> String:
	var item := get_owned_food_item(item_id)
	if item.is_empty():
		return "invalid_id"
	if get_food_count(item_id) <= 0:
		return "empty"
	if float(item.get("hunger", 0)) > 0 and hunger < 100.0:
		return ""
	if float(item.get("thirst", 0)) > 0 and thirst < 100.0:
		return ""
	return "not_thirsty" if float(item.get("thirst", 0)) > 0 else "full"


func use_food(item_id: String) -> Dictionary:
	var reason := "busy" if _sim_busy else food_use_reason(item_id)
	var result := {"ok": false, "reason": reason, "item": get_owned_food_item(item_id),
		"hunger": hunger, "thirst": thirst, "count": get_food_count(item_id)}
	if reason != "":
		return result
	_sim_busy = true
	var previous := _state_to_dict()
	_consume_food(result["item"])
	if not save_game():
		hunger = float(previous["hunger"])
		thirst = float(previous["thirst"])
		_food_inventory = previous["inventory"]["food"].duplicate(true)
		_food_lots = previous.get("food_lots", {}).duplicate(true)
		alerted_hunger = previous["alerted_hunger"]
		alerted_thirst = previous["alerted_thirst"]
		result["reason"] = "save_failed"
	else:
		result["ok"] = true
		stats_changed.emit()
		inventory_changed.emit()
	result["hunger"] = hunger
	result["thirst"] = thirst
	result["count"] = get_food_count(item_id)
	_sim_busy = false
	return result


func get_chat_messages() -> Array:
	return _chat_messages.duplicate(true)


func append_chat(text: String, role: String, session_id: String, reply_to: String = "") -> Dictionary:
	text = text.strip_edges()
	if _sim_busy or _travel_busy or _purchase_busy or text.is_empty() or text.length() > 500 or role not in ["user", "ds"] or session_id.is_empty():
		return {}
	if role == "ds":
		if not _chat_messages.any(func(m: Dictionary): return m["id"] == reply_to and m.get("role", "ds") == "user" and m.get("session_id") == session_id):
			return {}
		if _chat_messages.any(func(m: Dictionary): return m.get("reply_to", "") == reply_to):
			return {}
	_sim_busy = true
	var message := {"id": "chat-%d-%d" % [Time.get_ticks_usec(), _chat_messages.size()], "kind": "chat", "role": role,
		"source": "local" if role == "user" else "ai", "session_id": session_id, "text": text,
		"created_at": _purchase_timestamp(), "read": role == "user"}
	if role == "ds":
		message["reply_to"] = reply_to
	_chat_messages.append(message)
	var saved := save_game()
	if not saved:
		_chat_messages.pop_back()
	else:
		messages_changed.emit()
	_sim_busy = false
	return message.duplicate(true) if saved else {}


## 仅含普通聊天的 role/text，排除整份存档、旅行正文、提醒及其它会话。
func chat_context(session_id: String, before_id: String) -> Array:
	var result: Array = []
	for message in _chat_messages:
		if message["id"] == before_id:
			break
		if message.get("kind") == "chat" and message.get("session_id", "") == session_id:
			result.append({"role": message.get("role", "ds"), "text": message["text"]})
	return result.slice(maxi(0, result.size() - 20))


func get_unread_count() -> int:
	var count := 0
	for message in _chat_messages:
		if not message["read"]:
			count += 1
	return count


func mark_chat_read() -> bool:
	if _sim_busy or _travel_busy or get_unread_count() == 0:
		return false
	_sim_busy = true
	var previous := _chat_messages.duplicate(true)
	for message in _chat_messages:
		message["read"] = true
	var saved := save_game()
	if not saved:
		_chat_messages = previous
	else:
		messages_changed.emit()
	_sim_busy = false
	return saved


# —————————————————— 商品与购买（仅入背包）——————————————————

func _ensure_shop_data() -> void:
	if _shop_data_loaded:
		return
	_shop_data_loaded = true
	_food_catalog = content.catalogs["food"].duplicate(true)
	_furniture_catalog = content.catalogs["furniture"].duplicate(true)
	_location_catalog = content.catalogs["locations"].duplicate(true)


func _read_catalog(path: String, key: String) -> Array:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data is Dictionary and data.get(key) is Array:
		return data[key]
	push_error("[GameState] 商品数据无效：" + path)
	return []


func get_furniture_catalog() -> Array:
	_ensure_shop_data()
	var catalog := _furniture_catalog.filter(func(item: Dictionary): return not ROOM_FIXTURE_IDS.has(item.get("id")) and item.get("purchasable", true) != false).duplicate(true)
	catalog.sort_custom(func(a: Dictionary, b: Dictionary): return int(a.get("order", 0)) < int(b.get("order", 0)))
	return catalog


func get_owned_furniture() -> Array:
	return _owned_furniture.duplicate(true)


func has_furniture(item_id: String) -> bool:
	return _owned_furniture.any(func(old: String): return content.resolve("furniture", old) == content.resolve("furniture", item_id))


func buy_furniture(item_id: String) -> Dictionary:
	var item: Dictionary = {}
	for candidate in get_furniture_catalog():
		if candidate is Dictionary and candidate.get("id") == item_id:
			item = candidate
			break
	var raw_price: Variant = item.get("price")
	var result := {"ok": false, "reason": "invalid_id", "price": 0,
		"currency": currency, "owned": get_owned_furniture()}
	if item.is_empty():
		return result
	if not (raw_price is int or raw_price is float) or not is_finite(float(raw_price)) or float(raw_price) < 0 or float(raw_price) != floor(float(raw_price)) or int(raw_price) < 0 or float(int(raw_price)) != float(raw_price):
		result["reason"] = "invalid_price"
		return result
	var price := int(raw_price)
	result["price"] = price
	if _purchase_busy:
		result["reason"] = "busy"
		return result
	if has_furniture(item_id):
		result["reason"] = "already_owned"
		return result
	if currency < price:
		result["reason"] = "insufficient"
		return result
	_purchase_busy = true
	currency -= price
	_owned_furniture.append(item_id)
	# 单次原子落盘；失败回滚，不经过会额外保存/发信号的 set_currency。
	if save_game():
		result["ok"] = true
		result["reason"] = ""
		currency_changed.emit(currency)
		furniture_changed.emit()
	else:
		currency += price
		_owned_furniture.erase(item_id)
		result["reason"] = "save_failed"
	result["currency"] = currency
	result["owned"] = get_owned_furniture()
	_purchase_busy = false
	return result


func get_food_catalog() -> Array:
	_ensure_shop_data()
	return _food_catalog.duplicate(true)


func get_location_catalog() -> Array:
	_ensure_shop_data()
	return _location_catalog.duplicate(true)


func get_food_item(item_id: String) -> Dictionary:
	for item in get_food_catalog():
		if item is Dictionary and item.get("id") == content.resolve("food", item_id):
			return item
	return {}


func get_location(location: String) -> Dictionary:
	for item in get_location_catalog():
		if item is Dictionary and item.get("id") == content.resolve("locations", location):
			return item
	return {"id":location, "name":"已归档地点 · " + location, "photos":[], "seats":[], "archived":true}


func get_seat(location: String, seat: String) -> Dictionary:
	for item in get_location(location).get("seats", []):
		if item is Dictionary and item.get("id") == seat:
			return item.duplicate(true)
	return {}


func get_food_inventory() -> Dictionary:
	return _food_inventory.duplicate(true)


func get_food_count(item_id: String) -> int:
	return int(_food_inventory.get(item_id, 0))


func get_tickets() -> Array:
	return _tickets.duplicate(true)


func has_ticket(location: String, seat: String) -> bool:
	# 按座位限购：owned/traveling/visited 都锁住该座位，其它座位不受影响。
	for ticket in _tickets:
		if content.resolve("locations", ticket["location"]) == content.resolve("locations", location) and ticket["seat"] == seat:
			return true
	return false


## Variant 保留调用者的原始类型，防止 int 参数把 1.5 隐式截断后购买。
func buy_food(item_id: String, quantity: Variant = 1) -> Dictionary:
	var item := get_food_item(item_id)
	var raw_price: Variant = item.get("price", 0)
	var price := 0
	var result := {"ok": false, "reason": "invalid_id", "price": price,
		"quantity": quantity, "total_price": 0,
		"count": get_food_count(item_id), "currency": currency}
	if typeof(quantity) != TYPE_INT or quantity < 1 or quantity > 99:
		result["reason"] = "invalid_quantity"
		return result
	if item.is_empty():
		return result
	# JSON 数字是 float；只接受可精确表示且相乘不会溢出的非负整数价格。
	if not (raw_price is int or raw_price is float) or not is_finite(float(raw_price)) or float(raw_price) < 0 or float(raw_price) > 9007199254740991.0 or float(raw_price) != floorf(float(raw_price)):
		result["reason"] = "invalid_price"
		return result
	price = int(raw_price)
	var total_price: int = price * int(quantity)
	result["price"] = price
	result["total_price"] = total_price
	if get_food_count(item_id) > 9223372036854775807 - int(quantity):
		result["reason"] = "invalid_quantity"
		return result
	if _purchase_busy or _sim_busy or _travel_busy or _import_busy or _checkin_busy:
		result["reason"] = "busy"
		return result
	# 余额不足在修改状态之前返回，不扣费、不加物品、不保存。
	if currency < 0 or currency < total_price:
		result["reason"] = "insufficient"
		return result
	_purchase_busy = true
	var previous := _state_to_dict()
	freeze_food_inventory()
	if not _food_lots.has(item_id):
		_food_lots[item_id] = []
	_food_lots[item_id].append({"count":int(quantity), "item":item.duplicate(true)})
	currency -= total_price
	_food_inventory[item_id] = get_food_count(item_id) + int(quantity)
	result["ok"] = _commit_purchase(previous)
	result["reason"] = "" if result["ok"] else "save_failed"
	result["count"] = get_food_count(item_id)
	result["currency"] = currency
	_purchase_busy = false
	return result


func buy_ticket(location: String, seat: String) -> Dictionary:
	var item := get_seat(location, seat)
	var price := int(item.get("price", 0))
	var result := {"ok": false, "reason": "invalid_id", "price": price,
		"ticket": {}, "currency": currency}
	if item.is_empty() or price < 0:
		return result
	if _purchase_busy:
		result["reason"] = "busy"
		return result
	if has_ticket(location, seat):
		result["reason"] = "already_owned"
		return result
	if currency < price:
		result["reason"] = "insufficient"
		return result
	_purchase_busy = true
	var previous := _state_to_dict()
	var ticket := {"id": "%s-%s-%d-%d" % [location, seat, int(Time.get_unix_time_from_system()), Time.get_ticks_usec()],
		"location": location, "seat": seat, "status": "owned",
		"purchased_price":price, "catalog_snapshot":get_location(location).duplicate(true),
		"purchased_at": _purchase_timestamp(),
		"prepared_letters": letter_provider.generate(get_location(location), item)}
	currency -= price
	_tickets.append(ticket)
	result["ok"] = _commit_purchase(previous)
	result["reason"] = "" if result["ok"] else "save_failed"
	result["ticket"] = ticket.duplicate(true) if result["ok"] else {}
	result["currency"] = currency
	_purchase_busy = false
	if result["ok"]:
		ticket_purchased.emit(result["ticket"].duplicate(true))
	return result


func _purchase_timestamp() -> String:
	# 记录本地 ISO 时间及偏移，避免换时区后时间含糊；旅行复用同一设备本地时钟。
	var bias := int(Time.get_time_zone_from_system()["bias"])
	@warning_ignore("integer_division")
	var offset := "%s%02d:%02d" % ["+" if bias >= 0 else "-", absi(bias) / 60, absi(bias) % 60]
	return Time.get_datetime_string_from_system(false) + offset


func _commit_purchase(previous: Dictionary) -> bool:
	# 购买原子性：检查后同步扣费/入库，save_game 只调用一次；不用 set_currency。
	# 保存失败仅回滚内存，不发成功信号；临时文件写入保证正式档仍为旧值。
	if not save_game():
		currency = int(previous["currency"])
		_food_inventory = previous["inventory"]["food"].duplicate(true)
		_food_lots = previous.get("food_lots", {}).duplicate(true)
		_tickets = previous["tickets"].duplicate(true)
		return false
	# 落盘后才通知；忙标志覆盖信号回调，防止重入购买。
	currency_changed.emit(currency)
	inventory_changed.emit()
	return true


# —————————————————— 本地日期打卡 ——————————————————

## 返回深副本；跨月只投影本月日号，保留 last_date/streak 用于连续天数判断。
func get_checkin_state() -> Dictionary:
	var result := _checkin.duplicate(true)
	var month := local_date_string().left(7)
	if result["month"] != month:
		result["month"] = month
		result["days"] = []
	return result


func check_in_today() -> Dictionary:
	# 同步结算无 await；状态先更新，再发信号。信号回调重入也不能再发奖励。
	if _checkin_busy:
		return _checkin_result(false, true, 0, 0, int(_checkin["streak"]), "今日已打卡")
	_checkin_busy = true
	var result := evaluate_checkin(_checkin, local_date_string())
	if result["success"]:
		_checkin = result["state"].duplicate(true)
		currency += int(result["reward"]) + int(result["bonus"])
		# 余额和打卡一起落盘，只保存一次，不调用会额外保存的 add_currency。
		save_game()
		currency_changed.emit(currency)
		checkin_changed.emit()
	result.erase("state")
	_checkin_busy = false
	return result


static func local_date_string() -> String:
	# false 明确使用设备本地时区；不把 UTC 字符串当作本地日期。
	var date := Time.get_date_dict_from_system(false)
	return "%04d-%02d-%02d" % [date["year"], date["month"], date["day"]]


## 纯结算：不读系统时间、不改传入字典、不发信号或写盘，便于覆盖日期边界。
static func evaluate_checkin(state: Dictionary, today: String) -> Dictionary:
	var current := _sanitize_checkin(state)
	var today_ordinal := date_string_to_ordinal(today)
	if today_ordinal == 0:
		return _checkin_result(false, false, 0, 0, current["streak"], "日期无效")
	var last_ordinal := date_string_to_ordinal(current["last_date"])
	# 未来日期同样锁住，避免回拨时钟再次领取；不倒退 last_date。
	if last_ordinal >= today_ordinal:
		return _checkin_result(false, true, 0, 0, current["streak"], "今日已打卡")
	# 用公历日序比较昨天，跨月/跨年/夏令时均不依赖 24 小时秒数。
	var streak: int = int(current["streak"]) + 1 if last_ordinal == today_ordinal - 1 else 1
	var month := today.left(7)
	# 跨月清日号，连续天数在上面独立计算并保留。
	var days: Array = current["days"].duplicate() if current["month"] == month else []
	var day := int(today.right(2))
	if not days.has(day):
		days.append(day)
	days.sort()
	# 每满七天都奖励，包含 7/14/21…，不是只奖励第一次。
	var bonus := STREAK_BONUS if streak % STREAK_INTERVAL == 0 else 0
	var message := "连续 %d 天！额外 +100" % streak if bonus > 0 else "打卡成功 +40"
	var result := _checkin_result(true, false, DAILY_REWARD, bonus, streak, message)
	result["state"] = {"last_date": today, "streak": streak, "month": month, "days": days}
	return result


static func _checkin_result(success: bool, already: bool, reward: int, bonus: int, streak: int, message: String) -> Dictionary:
	return {"success": success, "already": already, "reward": reward,
		"bonus": bonus, "streak": streak, "message": message}


static func days_in_month(year: int, month: int) -> int:
	if year < 1 or year > 9999 or month < 1 or month > 12:
		return 0
	if month == 2:
		return 29 if year % 400 == 0 or (year % 4 == 0 and year % 100 != 0) else 28
	return 30 if month in [4, 6, 9, 11] else 31


## 公历 0001-01-01 为日序 1（周一）；无效日期返回 0，整数运算含世纪闰年。
static func date_to_ordinal(year: int, month: int, day: int) -> int:
	if day < 1 or day > days_in_month(year, month):
		return 0
	var previous := year - 1
	@warning_ignore("integer_division")
	var ordinal := 365 * previous + previous / 4 - previous / 100 + previous / 400 + day
	for m in range(1, month):
		ordinal += days_in_month(year, m)
	return ordinal


## 周一=0 … 周日=6；0 日序不对应合法日期。
static func ordinal_to_weekday(ordinal: int) -> int:
	return (ordinal - 1) % 7 if ordinal > 0 else -1


static func date_string_to_ordinal(value: String) -> int:
	if value.length() != 10 or value.substr(4, 1) != "-" or value.substr(7, 1) != "-":
		return 0
	var digits := value.replace("-", "")
	if digits.length() != 8 or not digits.is_valid_int():
		return 0
	var year := int(value.left(4))
	var month := int(value.substr(5, 2))
	var day := int(value.right(2))
	if value != "%04d-%02d-%02d" % [year, month, day]:
		return 0
	return date_to_ordinal(year, month, day)


## 可选字段逐项容错，旧档缺少 checkin 时得到空状态，不影响原有余额和数值。
static func _sanitize_checkin(value: Variant) -> Dictionary:
	var result := {"last_date": "", "streak": 0, "month": "", "days": []}
	if not value is Dictionary:
		return result
	var last: Variant = value.get("last_date", "")
	if last is String and date_string_to_ordinal(last) > 0:
		result["last_date"] = last
	var streak: Variant = value.get("streak", 0)
	if (streak is int or streak is float) and is_finite(float(streak)):
		result["streak"] = maxi(0, int(streak)) if result["last_date"] != "" else 0
	var month: Variant = value.get("month", "")
	if month is String and date_string_to_ordinal(month + "-01") > 0:
		result["month"] = month
	var days: Variant = value.get("days", [])
	if days is Array and result["month"] != "":
		var limit := days_in_month(int(result["month"].left(4)), int(result["month"].right(2)))
		for day in days:
			if (day is int or day is float) and is_finite(float(day)):
				var number := int(day)
				if float(number) == float(day) and number >= 1 and number <= limit and not result["days"].has(number):
					result["days"].append(number)
		result["days"].sort()
	return result


# —————————————————— 本机存档导出/导入 —————————————————

## 导出当前存档为 JSON 文本。
func export_save_text() -> String:
	return JSON.stringify(_state_to_dict(), "\t", false)


## 预检不改变状态；严格接受本游戏完整的 v1 导出档。
func validate_save_text(text: String) -> Dictionary:
	if text.to_utf8_buffer().size() > MAX_IMPORT_BYTES:
		return {"ok": false, "error": "存档超过 8 MiB，无法导入"}
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"ok": false, "error": "JSON 格式错误（第 %d 行）" % json.get_error_line()}
	if not json.data is Dictionary:
		return {"ok": false, "error": "存档必须是 JSON 对象"}
	var error: String = SaveImportValidator.validate(json.data, self)
	return {"ok": error.is_empty(), "error": error, "data": json.data}


## 必须在用户确认后调用。备份、应用、保存均同步完成，不暴露中间状态。
func import_save_text(text: String) -> bool:
	last_import_error = ""
	if _import_busy or _purchase_busy or _sim_busy or _travel_busy or _checkin_busy:
		last_import_error = "存档正忙，请稍后重试"
		return false
	var validation := validate_save_text(text)
	if not validation["ok"]:
		last_import_error = validation["error"]
		return false
	_import_busy = true
	if not _backup_before_import():
		last_import_error = "导入前备份失败，当前存档未更改"
		_import_busy = false
		return false
	var previous := _state_to_dict()
	var previous_version := version
	var previous_session_ids: Array[String] = session_new_message_ids.duplicate()
	var previous_completed := session_completed_location
	var previous_pending := _travel_save_pending
	_apply_state(validation["data"], false)
	if not save_game():
		_apply_state(previous, false)
		version = previous_version
		session_new_message_ids = previous_session_ids
		session_completed_location = previous_completed
		_travel_save_pending = previous_pending
		last_import_error = "存档保存失败，已恢复原状态；导入前备份已保留"
		_import_busy = false
		return false
	last_load_source = "imported"
	_emit_state_changed()
	_import_busy = false
	return true


func _backup_before_import() -> bool:
	# 先复制到临时备份，成功后替换旧备份；失败不删除原档或已有备份。
	if not FileAccess.file_exists(SAVE_PATH):
		return false
	var temporary := IMPORT_BACKUP_PATH + ".tmp"
	if DirAccess.copy_absolute(SAVE_PATH, temporary) != OK:
		DirAccess.remove_absolute(temporary)
		return false
	if DirAccess.rename_absolute(temporary, IMPORT_BACKUP_PATH) != OK:
		DirAccess.remove_absolute(temporary)
		return false
	return true


# —————————————————— 内部工具 ——————————————————

func _state_to_dict() -> Dictionary:
	var result := _save_extras.duplicate(true)
	var inventory_record: Dictionary = result.get("inventory", {}).duplicate(true) if result.get("inventory", {}) is Dictionary else {}
	inventory_record["food"] = _food_inventory.duplicate(true)
	result.merge({
		"version": SAVE_VERSION,
		"content_version": content_version,
		"content_archive": _content_archive.duplicate(true),
		"food_lots": _food_lots.duplicate(true),
		"currency": currency,
		"hunger": hunger,
		"thirst": thirst,
		"checkin": _checkin.duplicate(true),
		"inventory": inventory_record,
		"tickets": _tickets.duplicate(true),
		"owned_furniture": get_owned_furniture(),
		"last_sim_time": last_sim_time,
		"alerted_hunger": alerted_hunger,
		"alerted_thirst": alerted_thirst,
		"chat_messages": _chat_messages.duplicate(true),
		"travel": _travel.duplicate(true),
		"pending_travels": _pending_travels.duplicate(true),
		"album": _album.duplicate(true),
	}, true)
	return result


func is_traveling() -> bool:
	return not _travel.is_empty()


func get_active_travel() -> Dictionary:
	return _travel.duplicate(true)


func get_pending_travels() -> Array:
	return _pending_travels.duplicate(true)


func simulation_now() -> Dictionary:
	var wall := _decode_sim_time(_purchase_timestamp())
	var last := _decode_sim_time(last_sim_time)
	return last if not last.is_empty() and int(last["epoch"]) > int(wall.get("epoch", 0)) else wall


func pending_letter_count(travel_id: String = "") -> int:
	# 默认只显示当前旅行；回房后才汇总历史补投队列。
	var scope := travel_id if travel_id != "" else String(_travel.get("id", ""))
	var seen := {}
	for travel in _pending_travels + ([_travel] if not _travel.is_empty() else []):
		if scope != "" and travel["id"] != scope:
			continue
		for letter in travel["letters"]:
			var key := JSON.stringify([travel["id"], travel["ticket_id"], letter["index"]])
			# 任一副本已有正文或已投递，就不再是待补项；不依赖遍历顺序。
			seen[key] = seen.get(key, false) or letter.get("status") == "delivered" or letter_ready(letter)
	return seen.values().filter(func(ready: bool): return not ready).size()


func get_album() -> Array:
	return _album.duplicate(true)


func get_photo(location_id: String, photo_id: String) -> Dictionary:
	# History uses its exact old identity; aliases never remap photos.
	var key := location_id + "/" + photo_id
	if _content_archive.get("photos", {}).has(key):
		return _content_archive["photos"][key].duplicate(true)
	for location in get_location_catalog():
		if location["id"] != location_id:
			continue
		for photo in location.get("photos", []):
			if photo["id"] == photo_id:
				return photo.duplicate(true)
	return {}


func start_travel(ticket_id: String, now: Variant = "") -> Dictionary:
	# 单 active travel：同步忙标志也覆盖保存后的信号回调，不能重入出发。
	if _travel_busy or _sim_busy:
		return {"ok": false, "reason": "busy"}
	if not _travel.is_empty():
		return {"ok": false, "reason": "active"}
	var start := simulation_now() if now == "" else _decode_sim_time(now)
	if start.is_empty():
		return {"ok": false, "reason": "invalid_time"}
	for ticket in _tickets:
		if ticket["id"] != ticket_id:
			continue
		if ticket["status"] != "owned":
			return {"ok": false, "reason": "unavailable"}
		var ticket_location: Dictionary = ticket.get("catalog_snapshot", get_location(ticket["location"]))
		var seat: Dictionary = {}
		for candidate in ticket_location.get("seats", []):
			if candidate["id"] == ticket["seat"]:
				seat = candidate.duplicate(true)
		if seat.is_empty():
			break
		# 先结算正常游玩落后的时间；显式 now 仍可供独立测试注入。
		advance_sim_to(start["iso"], false)
		start = _decode_sim_time(last_sim_time)
		_travel_busy = true
		var previous: Dictionary = ticket.duplicate(true)
		# 旧票没有预生成信时补生成；出发时才排期，购买时间不参与倒计时。
		if not valid_saved_letters(ticket.get("prepared_letters")):
			ticket["prepared_letters"] = letter_provider.generate(ticket_location, seat)
		var letters: Array = ticket["prepared_letters"].duplicate(true)
		for letter in letters:
			letter["title"] = letter.get("title", "旅行来信")
			letter["body"] = letter.get("body", "")
			letter["source"] = letter.get("source", "pending")
			letter["scheduled_at"] = _sim_iso(int(start["epoch"]) + int(letter["hour"]) * 3600, int(start["bias"]))
			letter["status"] = "pending"
		ticket["status"] = "traveling"
		_travel = {"id": "travel-%s-%d" % [ticket_id, Time.get_ticks_usec()],
			"location": ticket["location"], "seat": ticket["seat"], "ticket_id": ticket_id,
			"started_at": start["iso"],
			"ends_at": _sim_iso(int(start["epoch"]) + int(seat["duration_hours"]) * 3600, int(start["bias"])),
			"letters": letters}
		var saved := save_game()
		if not saved:
			ticket.clear()
			ticket.merge(previous)
			_travel = {}
		else:
			inventory_changed.emit()
			travel_changed.emit()
		_travel_busy = false
		return {"ok": saved, "reason": "" if saved else "save_failed"}
	return {"ok": false, "reason": "unavailable"}


func is_legacy_travel_photo(location_id: String, photo_id: String) -> bool:
	return location_id == "hangzhou" and photo_id in ["hz_xihu", "hz_duanqiao", "hz_leifeng", "hz_hefang"]


func _valid_prepared(value: Variant, seat: Dictionary, allow_legacy: bool = false) -> bool:
	if not value is Array or value.size() != seat.get("letters", []).size():
		return false
	for i in range(value.size()):
		var letter: Variant = value[i]
		var plan: Dictionary = seat["letters"][i]
		if not letter is Dictionary or letter.get("body", "") is not String:
			return false
		if not letter.get("title", "旅行来信") is String or not letter.get("source", "pending") is String:
			return false
		var expected_ids: Array = plan["photo_ids"]
		# 只在载入/导入旧档时接受精确的旧排期；不修改照片 ID 或正文。
		if allow_legacy and seat in get_location("hangzhou").get("seats", []):
			var legacy_plans := {"business": [["hz_xihu"], ["hz_duanqiao"], ["hz_leifeng", "hz_hefang"]], "first": [["hz_xihu"], ["hz_duanqiao"]], "second": [["hz_xihu"]]}
			var legacy_ids: Array = legacy_plans.get(seat.get("id", ""), [])
			if i < legacy_ids.size() and letter.get("photo_ids") == legacy_ids[i]:
				expected_ids = legacy_ids[i]
		if letter.get("index") != plan["index"] or letter.get("hour") != plan["hour"] or letter.get("photo_ids") != expected_ids:
			return false
	return true


func apply_ai_letters(ticket_id: String, value: Variant) -> bool:
	if _sim_busy or _travel_busy or _purchase_busy:
		return false
	for ticket in _tickets:
		if ticket["id"] != ticket_id:
			continue
		if not value is Array or value.is_empty():
			return false
		var seat := get_seat(ticket["location"], ticket["seat"]).duplicate(true)
		var indices: Array = []
		for letter in value:
			if not letter is Dictionary or not (letter.get("index") is int or letter.get("index") is float):
				return false
			var index := int(letter["index"])
			if indices.has(index):
				return false
			indices.append(index)
		seat["letters"] = seat["letters"].filter(func(plan: Dictionary): return int(plan["index"]) in indices)
		if seat["letters"].size() != value.size():
			return false
		var prepared: Array = letter_provider.merge_ai(value, get_location(ticket["location"]), seat)
		if prepared.is_empty():
			return false
		_purchase_busy = true
		var previous: Array = ticket.get("prepared_letters", []).duplicate(true)
		var previous_active := _travel.duplicate(true)
		var previous_pending := _pending_travels.duplicate(true)
		var previous_messages := _chat_messages.duplicate(true)
		var previous_ids := session_new_message_ids.duplicate()
		var changed := _merge_letter_text(ticket["prepared_letters"], prepared)
		for travel in _pending_travels + ([_travel] if not _travel.is_empty() else []):
			if travel["ticket_id"] == ticket_id:
				changed = _merge_letter_text(travel["letters"], prepared) or changed
				changed = _deliver_travel_letters(travel, simulation_now()) or changed
		_pending_travels = _pending_travels.filter(func(job: Dictionary): return not job["letters"].all(func(letter: Dictionary): return letter.get("status") == "delivered"))
		var saved := not changed or save_game()
		if not saved:
			ticket["prepared_letters"] = previous
			_travel = previous_active
			_pending_travels = previous_pending
			_chat_messages = previous_messages
			session_new_message_ids = previous_ids
		_purchase_busy = false
		if saved and changed:
			if _chat_messages != previous_messages:
				messages_changed.emit()
			travel_changed.emit()
		return saved
	return false


func _merge_letter_text(target: Array, incoming: Array) -> bool:
	var changed := false
	for letter in target:
		if letter.get("status") == "delivered" or letter_ready(letter):
			continue
		for candidate in incoming:
			if candidate.get("index") != letter.get("index") or not letter_ready(candidate):
				continue
			# 排期、照片配置与已生成的标题均不重写。
			for key in ["title", "title_source", "body", "source"]:
				if candidate.has(key):
					letter[key] = candidate[key]
			changed = true
	return changed


func get_letter_work() -> Array:
	var work: Array = []
	for ticket in _tickets:
		var letters: Array = ticket.get("prepared_letters", [])
		for travel in _pending_travels + ([_travel] if not _travel.is_empty() else []):
			if travel["ticket_id"] == ticket["id"]:
				letters = travel["letters"]
		var missing: Array = []
		for letter in letters:
			if letter.get("status") != "delivered" and not letter_ready(letter):
				missing.append(letter["index"])
		if not missing.is_empty() and (ticket["status"] == "owned" or _travel.get("ticket_id") == ticket["id"] or _pending_travels.any(func(job: Dictionary): return job["ticket_id"] == ticket["id"])):
			work.append({"ticket_id":ticket["id"], "location":ticket["location"], "seat":ticket["seat"], "indices":missing})
	return work


func letter_ready(letter: Dictionary) -> bool:
	return not String(letter.get("body", "")).strip_edges().is_empty()


func _deliver_travel_letters(travel: Dictionary, target: Dictionary) -> bool:
	var changed := false
	# 离线补投按 scheduled_at 排序，先补齐到期信件，再处理终点。
	travel["letters"].sort_custom(func(a: Dictionary, b: Dictionary): return int(_decode_sim_time(a["scheduled_at"])["epoch"]) < int(_decode_sim_time(b["scheduled_at"])["epoch"]))
	for letter in travel["letters"]:
		var due := _decode_sim_time(letter["scheduled_at"])
		if letter["status"] == "delivered" or int(due["epoch"]) > int(target["epoch"]):
			continue
		if not letter_ready(letter):
			continue
		var id := "%s-letter-%d" % [travel["id"], int(letter["index"])]
		# 只投一次：状态和稳定消息 ID 双重防重，重启或重复 tick 都不追加第二封。
		if not _chat_messages.any(func(message: Dictionary): return message["id"] == id):
			_chat_messages.append({"id": id, "role": "ds", "kind": "travel_letter",
				"title": letter_provider.display_title(letter), "title_source": letter.get("title_source", ""),
				"location": travel["location"], "seat": travel["seat"], "travel_id": travel["id"],
				"letter_index": letter["index"], "photo_ids": letter["photo_ids"].duplicate(),
				"body": letter["body"], "source": letter.get("source", "local"), "created_at": letter["scheduled_at"], "read": false})
			session_new_message_ids.append(id)
		letter["status"] = "delivered"
		changed = true
	if changed:
		_chat_messages.sort_custom(func(a: Dictionary, b: Dictionary): return int(_decode_sim_time(a["created_at"]).get("epoch", 0)) < int(_decode_sim_time(b["created_at"]).get("epoch", 0)))
	return changed


func _advance_travel(target: Dictionary) -> Dictionary:
	var result := {"changed": false, "completed": ""}
	for pending in _pending_travels.duplicate():
		if _deliver_travel_letters(pending, target):
			result["changed"] = true
		if pending["letters"].all(func(letter: Dictionary): return letter.get("status") == "delivered"):
			_pending_travels.erase(pending)
			result["changed"] = true
	if _travel.is_empty():
		return result
	result["changed"] = _deliver_travel_letters(_travel, target) or result["changed"]
	if int(target["epoch"]) >= int(_decode_sim_time(_travel["ends_at"])["epoch"]):
		# visited 永久锁住这个座位；地点的其它座位仍可购买，完成后清空 active travel。
		for ticket in _tickets:
			if ticket["id"] == _travel["ticket_id"]:
				ticket["status"] = "visited"
		result["completed"] = get_location(_travel["location"])["name"]
		session_completed_location = result["completed"]
		if _travel["letters"].any(func(letter: Dictionary): return letter.get("status") != "delivered"):
			_pending_travels.append(_travel.duplicate(true))
		_travel = {}
		result["changed"] = true
	if result["changed"]:
		# 旅行补投也与已有日常提醒按实际发生时间排列，聊天不会先显示未来的提醒。
		_chat_messages.sort_custom(func(a: Dictionary, b: Dictionary): return int(_decode_sim_time(a["created_at"]).get("epoch", 0)) < int(_decode_sim_time(b["created_at"]).get("epoch", 0)))
	return result


func open_travel_letter(message_id: String, now: Variant = "") -> Dictionary:
	if _travel_busy or _sim_busy:
		return {"ok": false, "reason": "busy"}
	var stamp := _decode_sim_time(_purchase_timestamp() if now == "" else now)
	if stamp.is_empty():
		return {"ok": false, "reason": "invalid_time"}
	for message in _chat_messages:
		if message["id"] != message_id or message["kind"] != "travel_letter":
			continue
		_travel_busy = true
		var previous_album := _album.duplicate(true)
		var was_read: bool = message["read"]
		message["read"] = true
		for photo_id in message["photo_ids"]:
			# 相册按 photo_id 全局去重；重复打开信件或其它座位获得同图都不重复添加。
			if _album.any(func(existing: Dictionary): return existing["photo_id"] == photo_id):
				continue
			var photo := get_photo(message["location"], photo_id)
			if not photo.is_empty():
				_album.append({"photo_id": photo_id, "location": message["location"], "seat": message["seat"],
					"caption": photo["caption"], "added_at": stamp["iso"]})
		var changed := not was_read or _album != previous_album
		if changed and not save_game():
			message["read"] = was_read
			_album = previous_album
			_travel_busy = false
			return {"ok": false, "reason": "save_failed"}
		if changed:
			messages_changed.emit()
			album_changed.emit()
		_travel_busy = false
		return {"ok": true, "message": message.duplicate(true)}
	return {"ok": false, "reason": "unavailable"}


func _valid_travel_message(value: Variant) -> bool:
	return value is Dictionary and value.get("id") is String and value.get("role", "ds") == "ds" and value.get("kind") == "travel_letter" and (not value.has("title") or value.get("title") is String) and value.get("location") is String and value.get("seat") is String and value.get("travel_id") is String and (value.get("letter_index") is int or value.get("letter_index") is float) and value.get("photo_ids") is Array and value.get("body") is String and value.get("created_at") is String


func _load_travel_album(state: Dictionary) -> void:
	_travel_save_pending = false
	session_completed_location = ""
	_travel = {}
	_pending_travels = []
	var pending: Variant = state.get("pending_travels", [])
	if pending is Array:
		for job in pending:
			if valid_pending_travel(job):
				_pending_travels.append(job.duplicate(true))
	_album = []
	var album: Variant = state.get("album", [])
	if album is Array:
		for photo in album:
			if photo is Dictionary and photo.get("photo_id") is String and photo.get("location") is String and photo.get("seat") is String and photo.get("caption") is String and photo.get("added_at") is String:
				if not _album.any(func(existing: Dictionary): return existing["photo_id"] == photo["photo_id"]):
					_album.append(photo.duplicate(true))
	var travel: Variant = state.get("travel", {})
	if not travel is Dictionary or travel.is_empty():
		return
	for key in ["id", "location", "seat", "ticket_id", "started_at", "ends_at"]:
		if not travel.get(key) is String:
			return
	if _decode_sim_time(travel["started_at"]).is_empty() or _decode_sim_time(travel["ends_at"]).is_empty():
		return
	if not valid_saved_letters(travel.get("letters")):
		return
	for letter in travel["letters"]:
		if not letter.get("scheduled_at") is String or _decode_sim_time(letter["scheduled_at"]).is_empty() or letter.get("status") not in ["pending", "delivered"]:
			return
	for ticket in _tickets:
		if ticket["id"] == travel["ticket_id"] and ticket["status"] == "traveling" and ticket["location"] == travel["location"] and ticket["seat"] == travel["seat"]:
			_travel = travel.duplicate(true)
			return


func _default_state() -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"currency": STARTING_CURRENCY,
		"hunger": DEFAULT_HUNGER,
		"thirst": DEFAULT_THIRST,
		"owned_furniture": [],
	}


## 把一份（可能来自坏档/手工编辑的）字典套进内存，逐字段做类型检查 + 夹紧，
## 避免存档里某个字段被写成字符串/数组时把 UI 弄崩。
func _apply_state(state: Dictionary, emit_changes: bool = true) -> void:
	_save_extras = state.duplicate(true)
	content_version = str(state.get("content_version", ContentManager.BASE_VERSION))
	_content_unavailable = not content.restore(content_version)
	_content_archive = state.get("content_archive", {}).duplicate(true) if ContentManager.valid_archive(state.get("content_archive", {})) else {}
	_food_lots = {}
	var lots: Variant = state.get("food_lots", {})
	if lots is Dictionary:
		for id in lots:
			if not lots[id] is Array:
				continue
			var valid := true
			var count := 0
			for lot in lots[id]:
				if not lot is Dictionary or not SaveImportValidator._whole(lot.get("count"), 1) or not lot.get("item") is Dictionary or not ContentManager.valid_rows("food", [lot["item"]]) or lot["item"]["id"] != id:
					valid = false
					break
				count += int(lot["count"])
			var inventory_value: Variant = state.get("inventory", {})
			var food_value: Variant = inventory_value.get("food", {}) if inventory_value is Dictionary else {}
			if valid and food_value is Dictionary and count == food_value.get(id, 0):
				_food_lots[id] = lots[id].duplicate(true)
	_shop_data_loaded = false
	version = _read_int(state, "version", SAVE_VERSION)
	currency = maxi(0, _read_int(state, "currency", STARTING_CURRENCY))
	hunger = clampf(_read_float(state, "hunger", DEFAULT_HUNGER), 0.0, 100.0)
	thirst = clampf(_read_float(state, "thirst", DEFAULT_THIRST), 0.0, 100.0)
	_checkin = _sanitize_checkin(state.get("checkin", null))
	_owned_furniture.clear()
	var furniture: Variant = state.get("owned_furniture", [])
	if furniture is Array:
		for item_id in furniture:
			# 只迁移默认结构 id；其它家具（含未知字符串）与经济/旅行字段照旧读取。
			if item_id is String and not _owned_furniture.has(item_id):
				_owned_furniture.append(item_id)
	# Stage 4 可选字段独立容错，不改变旧档的余额、打卡或库存。
	var sim_time: Variant = state.get("last_sim_time", "")
	last_sim_time = sim_time if sim_time is String and not _decode_sim_time(sim_time).is_empty() else ""
	alerted_hunger = state.get("alerted_hunger", false) == true
	alerted_thirst = state.get("alerted_thirst", false) == true
	_chat_messages = []
	session_new_message_ids.clear()
	var messages: Variant = state.get("chat_messages", [])
	var message_ids: Dictionary = {}
	if messages is Array:
		for message in messages:
			if message is Dictionary and message.get("id") is String and not message_ids.has(message["id"]) and message.get("kind") == "chat" and message.get("role", "ds") in ["user", "ds"] and message.get("text") is String and message.get("created_at") is String:
				message_ids[message["id"]] = true
				var chat: Dictionary = message.duplicate(true)
				chat["role"] = message.get("role", "ds")
				chat["source"] = "ai" if message.get("source") == "ai" else "local"
				chat["session_id"] = message.get("session_id", "game-local") if message.get("session_id", "game-local") is String else "game-local"
				chat["read"] = message.get("read", false) == true or chat["role"] == "user"
				_chat_messages.append(chat)
				continue
			if _valid_travel_message(message) and not message_ids.has(message["id"]):
				message_ids[message["id"]] = true
				var loaded_message: Dictionary = message.duplicate(true)
				loaded_message["role"] = "ds"
				loaded_message["source"] = "ai" if message.get("source") == "ai" else "local"
				loaded_message["read"] = message.get("read", false) == true
				_chat_messages.append(loaded_message)
				continue
			if message is Dictionary and message.get("id") is String and not message_ids.has(message["id"]) and message.get("role", "ds") == "ds" and message.get("kind") in ["hunger", "thirst"] and message.get("text") is String and message.get("created_at") is String:
				message_ids[message["id"]] = true
				_chat_messages.append({"id": message["id"], "role": "ds", "kind": message["kind"], "text": message["text"], "created_at": message["created_at"], "read": message.get("read", false) == true})
	# 旧档兼容：两个可选字段缺失或类型错误时用空库存，保留原余额/数值/打卡。
	_food_inventory = {}
	var inventory: Variant = state.get("inventory", {})
	if inventory is Dictionary and inventory.get("food") is Dictionary:
		for item_id in inventory["food"]:
			var count: Variant = inventory["food"][item_id]
			if item_id is String and (count is int or count is float) and is_finite(float(count)) and float(count) >= 0 and float(count) == floor(float(count)):
				_food_inventory[item_id] = int(count)
	_tickets = []
	var tickets: Variant = state.get("tickets", [])
	if tickets is Array:
		for ticket in tickets:
			if ticket is Dictionary and ticket.get("id") is String and ticket.get("location") is String and ticket.get("seat") is String and ticket.get("status") in ["owned", "traveling", "visited"]:
				if not _tickets.any(func(existing: Dictionary): return existing["id"] == ticket["id"]):
					var loaded_ticket: Dictionary = ticket.duplicate(true)
					if loaded_ticket.has("catalog_snapshot") and (not loaded_ticket["catalog_snapshot"] is Dictionary or not ContentManager.valid_location(loaded_ticket["catalog_snapshot"])):
						loaded_ticket.erase("catalog_snapshot")
					if loaded_ticket.get("prepared_letters") is Array:
						for letter in loaded_ticket["prepared_letters"]:
							if letter is Dictionary:
								letter["source"] = letter.get("source", "pending")
					_tickets.append(loaded_ticket)
	_load_travel_album(state)
	_normalize_pending_letters()
	if emit_changes:
		_emit_state_changed()


func _normalize_pending_letters() -> void:
	var unique: Array = []
	for job in _pending_travels:
		if not _tickets.any(func(ticket: Dictionary): return ticket["id"] == job["ticket_id"] and ticket["location"] == job["location"] and ticket["seat"] == job["seat"]):
			continue
		var canonical: Dictionary = _travel if _travel.get("ticket_id") == job["ticket_id"] else {}
		for existing in unique:
			if existing["ticket_id"] == job["ticket_id"]:
				canonical = existing
		if canonical.is_empty():
			unique.append(job)
		elif canonical["started_at"] == job["started_at"]:
			_merge_letter_text(canonical["letters"], job["letters"])
	_pending_travels = unique
	for travel in _pending_travels + ([_travel] if not _travel.is_empty() else []):
		for letter in travel["letters"]:
			var id := "%s-letter-%d" % [travel["id"], int(letter["index"])]
			for message in _chat_messages:
				if message["id"] == id and letter_ready(message):
					_merge_letter_text([letter], [message.merged({"index":letter["index"]})])
					letter["status"] = "delivered"
			if not letter_ready(letter):
				letter["status"] = "pending"
		for ticket in _tickets:
			if ticket["id"] == travel["ticket_id"]:
				_merge_letter_text(travel["letters"], ticket.get("prepared_letters", []))
				_merge_letter_text(ticket.get("prepared_letters", []), travel["letters"])
	_pending_travels = _pending_travels.filter(func(job: Dictionary): return not job["letters"].all(func(letter: Dictionary): return letter.get("status") == "delivered"))


func _emit_state_changed() -> void:
	furniture_changed.emit()
	currency_changed.emit(currency)
	checkin_changed.emit()
	inventory_changed.emit()
	stats_changed.emit()
	messages_changed.emit()
	travel_changed.emit()
	album_changed.emit()


# JSON 解析出来的数字统一是 float，所以这里接受 int/float 两种类型。
func _read_int(data: Dictionary, key: String, fallback: int) -> int:
	var value: Variant = data.get(key, null)
	if (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value)):
		return int(value)
	return fallback


func _read_float(data: Dictionary, key: String, fallback: float) -> float:
	var value: Variant = data.get(key, null)
	if (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value)):
		return float(value)
	return fallback

# Durable GameState outbox is authoritative; companion jobs are a retry cache.
func valid_pending_travel(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	for key in ["id", "location", "seat", "ticket_id", "started_at", "ends_at"]:
		if not value.get(key) is String:
			return false
	if not valid_saved_letters(value.get("letters")):
		return false
	for letter in value["letters"]:
		if _decode_sim_time(letter.get("scheduled_at", "")).is_empty() or letter.get("status") not in ["pending", "delivered"]:
			return false
	return not _decode_sim_time(value["started_at"]).is_empty() and not _decode_sim_time(value["ends_at"]).is_empty()


func valid_saved_letters(value: Variant) -> bool:
	if not value is Array:
		return false
	var indices := {}
	for letter in value:
		if not letter is Dictionary or not SaveImportValidator._whole(letter.get("index")) or indices.has(letter["index"]) or not SaveImportValidator._whole(letter.get("hour")) or not SaveImportValidator._strings(letter.get("photo_ids")) or not letter.get("body", "") is String:
			return false
		indices[letter["index"]] = true
	return true


func import_content_pack(path: String) -> bool:
	last_content_error = ""
	if _import_busy or _sim_busy or _purchase_busy or _travel_busy or _checkin_busy or last_load_source == "fallback" or _content_unavailable:
		last_content_error = "存档忙碌、损坏或缺少当前内容，请先恢复备份"
		return false
	_import_busy = true
	# Backup the exact disk bytes before validation. Never import a save from a pack.
	if not _backup_before_content():
		_import_busy = false
		last_content_error = "存档备份失败，未切换内容"
		return false
	var previous := _state_to_dict()
	var checked: Dictionary = content.stage(path)
	if checked.is_empty():
		_import_busy = false
		last_content_error = content.error
		return false
	archive_current_content()
	content.activate(checked)
	content_version = content.content_version
	_shop_data_loaded = false
	if not save_game():
		# No signals or simulation ran during the transaction; preserve memory verbatim.
		content_version = str(previous.get("content_version", ContentManager.BASE_VERSION))
		content.restore(content_version)
		_content_archive = previous.get("content_archive", {}).duplicate(true)
		_food_lots = previous.get("food_lots", {}).duplicate(true)
		_tickets = previous["tickets"].duplicate(true)
		_shop_data_loaded = false
		last_content_error = "保存失败，已回滚；备份与原档保留"
		_import_busy = false
		return false
	_import_busy = false
	content_changed.emit()
	furniture_changed.emit()
	inventory_changed.emit()
	travel_changed.emit()
	album_changed.emit()
	return true


func _backup_before_content() -> bool:
	var backup := "user://save_before_content_" + str(Time.get_ticks_usec()) + ".json"
	var ok := FileAccess.file_exists(SAVE_PATH) and DirAccess.copy_absolute(SAVE_PATH, backup) == OK
	last_content_backup_path = backup if ok else ""
	return ok


func archive_current_content() -> void:
	freeze_food_inventory()
	for ticket in _tickets:
		if not ticket.has("catalog_snapshot"):
			var location := get_location(ticket["location"])
			if ContentManager.valid_location(location):
				ticket["catalog_snapshot"] = location.duplicate(true)
	if not _content_archive.has("photos"):
		_content_archive["photos"] = {}
	for location in get_location_catalog():
		for photo in location.get("photos", []):
			var key: String = location["id"] + "/" + photo["id"]
			if not _content_archive["photos"].has(key):
				_content_archive["photos"][key] = photo.duplicate(true)
	# Purchase records, prepared letters, balances and raw IDs are never rewritten.
	for kind in ["food", "furniture", "locations"]:
		if not _content_archive.has(kind):
			_content_archive[kind] = {}
		for item in content.catalogs[kind]:
			if not _content_archive[kind].has(item["id"]):
				_content_archive[kind][item["id"]] = item.duplicate(true)


func freeze_food_inventory() -> void:
	for id in _food_inventory:
		if get_food_count(id) <= 0:
			continue
		if _food_lots.has(id) and not _food_lots[id].is_empty():
			continue
		var item := get_food_item(id)
		if not item.is_empty():
			item["id"] = id
			_food_lots[id] = [{"count":get_food_count(id), "item":item.duplicate(true)}]


func get_owned_food_item(id: String) -> Dictionary:
	if _food_lots.has(id) and not _food_lots[id].is_empty():
		return _food_lots[id][0]["item"].duplicate(true)
	var item := get_food_item(id).duplicate(true)
	if not item.is_empty():
		item["id"] = id
	return item


func deliver_pending_travel(travel: Dictionary) -> bool:
	if _sim_busy or _travel_busy or _purchase_busy or not valid_pending_travel(travel):
		return false
	var previous_messages := _chat_messages.duplicate(true)
	var previous_active := _travel.duplicate(true)
	var previous_pending := _pending_travels.duplicate(true)
	var previous_tickets := _tickets.duplicate(true)
	var previous_session_ids := session_new_message_ids.duplicate()
	var canonical: Dictionary = {}
	if _travel.get("id") == travel["id"]:
		canonical = _travel
	else:
		for job in _pending_travels:
			if job["id"] == travel["id"]:
				canonical = job
	# 只接受正式 outbox；旧 companion 缓存不能复活已完成/已恢复的旅行。
	if canonical.is_empty():
		return false
	for i in range(canonical["letters"].size()):
		var letter: Dictionary = canonical["letters"][i]
		if letter.get("status") != "delivered" and not letter_ready(letter) and letter_ready(travel["letters"][i]):
			for key in ["title", "title_source", "body", "source"]:
				if travel["letters"][i].has(key):
					letter[key] = travel["letters"][i][key]
	_deliver_travel_letters(canonical, simulation_now())
	for ticket in _tickets:
		if ticket["id"] == canonical["ticket_id"]:
			_merge_letter_text(ticket.get("prepared_letters", []), canonical["letters"])
	if canonical["letters"].all(func(letter: Dictionary): return letter.get("status") == "delivered"):
		_pending_travels.erase(canonical)
	var changed := _travel != previous_active or _pending_travels != previous_pending or _chat_messages != previous_messages or _tickets != previous_tickets
	if changed and not save_game():
		_chat_messages = previous_messages
		_travel = previous_active
		_pending_travels = previous_pending
		_tickets = previous_tickets
		session_new_message_ids = previous_session_ids
		return false
	travel["letters"] = canonical["letters"].duplicate(true)
	if _chat_messages != previous_messages:
		_chat_messages.sort_custom(func(x: Dictionary, y: Dictionary): return int(_decode_sim_time(x["created_at"]).get("epoch", 0)) < int(_decode_sim_time(y["created_at"]).get("epoch", 0)))
		messages_changed.emit()
	if changed:
		travel_changed.emit()
	return true
