extends RefCounted
## 只检查数据，不加载 JSON 中的资源、路径或代码。历史不完整档须先由游戏导出完整 v1。

static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _whole(value: Variant, minimum: int = 0, maximum: int = 9007199254740991) -> bool:
	return _number(value) and value >= minimum and value <= maximum and float(value) == floor(float(value))


static func _strings(value: Variant) -> bool:
	if not value is Array:
		return false
	for item in value:
		if not item is String:
			return false
	return true


static func _fields(value: Variant, names: Array) -> bool:
	if not value is Dictionary:
		return false
	for key in names:
		if not value.get(key) is String:
			return false
	return true


static func validate(data: Dictionary, game: Node) -> String:
	if data.has("content_version") and (not data["content_version"] is String or (data["content_version"] != game.ContentManager.BASE_VERSION and game.ContentManager.version_parts(data["content_version"]).is_empty())):
		return "content_version 无效"
	if data.has("content_archive") and not game.ContentManager.valid_archive(data["content_archive"]):
		return "content_archive 结构无效"
	if not _whole(data.get("version"), 1, 1):
		return "仅支持 version=1 的 fishroom 存档"
	for key in ["currency", "hunger", "thirst", "checkin", "inventory", "tickets", "owned_furniture", "travel", "album", "chat_messages"]:
		if not data.has(key):
			return "不是完整的 fishroom 存档：缺少 %s" % key
	if not _whole(data["currency"]):
		return "currency 必须是非负整数且在安全范围内"
	for key in ["hunger", "thirst"]:
		if not _number(data[key]) or data[key] < 0 or data[key] > 100:
			return "%s 必须是 0–100 的数字" % key
	for key in ["alerted_hunger", "alerted_thirst"]:
		if data.has(key) and not data[key] is bool:
			return "%s 类型错误" % key
	if data.has("last_sim_time") and (not data["last_sim_time"] is String or (data["last_sim_time"] != "" and game._decode_sim_time(data["last_sim_time"]).is_empty())):
		return "last_sim_time 不是有效时间"
	var checkin: Variant = data["checkin"]
	if not _fields(checkin, ["last_date", "month"]) or not _whole(checkin.get("streak")) or not checkin.get("days") is Array:
		return "checkin 结构或字段类型错误"
	if checkin["last_date"] != "" and game.date_string_to_ordinal(checkin["last_date"]) == 0:
		return "checkin.last_date 日期无效"
	if checkin["month"] != "" and game.date_string_to_ordinal(checkin["month"] + "-01") == 0:
		return "checkin.month 月份无效"
	var days: Array = []
	for day in checkin["days"]:
		if not _whole(day, 1, 31) or checkin["month"] == "" or game.date_string_to_ordinal("%s-%02d" % [checkin["month"], int(day)]) == 0 or days.has(day):
			return "checkin.days 含无效或重复日期"
		days.append(day)
	var inventory: Variant = data["inventory"]
	if not inventory is Dictionary or not inventory.get("food") is Dictionary:
		return "inventory.food 必须是对象"
	for id in inventory["food"]:
		if not _whole(inventory["food"][id]):
			return "inventory.food 数量必须是非负整数"
	if not _strings(data["owned_furniture"]):
		return "owned_furniture 必须是字符串数组"
	# Unknown content IDs are valid historical references, never a reason to erase a save.
	if not data["tickets"] is Array:
		return "tickets 必须是数组"
	var ticket_ids: Array = []
	var seats: Array = []
	for ticket in data["tickets"]:
		if not _fields(ticket, ["id", "location", "seat"]) or ticket.get("status") not in ["owned", "traveling", "visited"]:
			return "tickets 内含无效车票"
		if ticket.has("catalog_snapshot") and (not ticket["catalog_snapshot"] is Dictionary or not game.ContentManager.valid_location(ticket["catalog_snapshot"])):
			return "tickets.catalog_snapshot 结构无效"
		var seat_key: String = ticket["location"] + "/" + ticket["seat"]
		if ticket["id"].is_empty() or ticket_ids.has(ticket["id"]) or seats.has(seat_key):
			return "tickets 含未知或重复车票"
		if ticket.has("prepared_letters") and not game.valid_saved_letters(ticket["prepared_letters"]):
			return "tickets.prepared_letters 无效"
		ticket_ids.append(ticket["id"])
		seats.append(seat_key)
	var travel_error := _travel(data["travel"], data["tickets"], game)
	if not data.get("pending_travels", []) is Array:
		return "pending_travels 必须是数组"
	for pending in data.get("pending_travels", []):
		if not game.valid_pending_travel(pending):
			return "pending_travels 待补信件无效"
	if not travel_error.is_empty():
		return travel_error
	if not data["album"] is Array:
		return "album 必须是数组"
	var photo_ids: Array = []
	for photo in data["album"]:
		if not _fields(photo, ["photo_id", "location", "seat", "caption", "added_at"]):
			return "album 照片字段类型错误"
		if photo_ids.has(photo["photo_id"]):
			return "album 含未知或重复照片"
		photo_ids.append(photo["photo_id"])
	if not data["chat_messages"] is Array:
		return "chat_messages 必须是数组"
	var message_ids: Array = []
	for message in data["chat_messages"]:
		if not _fields(message, ["id", "kind", "created_at"]) or message.get("role", "ds") not in ["user", "ds"] or message_ids.has(message["id"]):
			return "chat_messages 消息字段无效或 ID 重复"
		if message.has("read") and not message["read"] is bool:
			return "chat_messages.read 必须是布尔值"
		if message["kind"] == "travel_letter":
			if not game._valid_travel_message(message) or not _strings(message["photo_ids"]) or not _whole(message["letter_index"]):
				return "chat_messages 旅行信结构错误"
		elif message["kind"] in ["chat", "hunger", "thirst"]:
			if not message.get("text") is String or (message["kind"] != "chat" and message.get("role", "ds") != "ds"):
				return "chat_messages 正文字段错误"
		else:
			return "chat_messages 含未知消息类型"
		message_ids.append(message["id"])
	return ""


static func _travel(travel: Variant, tickets: Array, game: Node) -> String:
	if not travel is Dictionary:
		return "travel 必须是对象"
	var active_ticket: Dictionary = {}
	for ticket in tickets:
		if ticket["status"] == "traveling":
			if not active_ticket.is_empty():
				return "travel 存在多张旅行中车票"
			active_ticket = ticket
	if travel.is_empty():
		return "travel 缺少旅行中车票的行程" if not active_ticket.is_empty() else ""
	if not _fields(travel, ["id", "location", "seat", "ticket_id", "started_at", "ends_at"]):
		return "travel 行程字段类型错误"
	if active_ticket.is_empty() or active_ticket["id"] != travel["ticket_id"] or active_ticket["location"] != travel["location"] or active_ticket["seat"] != travel["seat"]:
		return "travel 与旅行中车票不匹配"
	var start: Dictionary = game._decode_sim_time(travel["started_at"])
	var end: Dictionary = game._decode_sim_time(travel["ends_at"])
	if start.is_empty() or end.is_empty() or end["epoch"] <= start["epoch"]:
		return "travel 起止时间无效"
	if not game.valid_saved_letters(travel.get("letters")):
		return "travel.letters 行程信件无效"
	for letter in travel["letters"]:
		if not letter.get("scheduled_at") is String or game._decode_sim_time(letter["scheduled_at"]).is_empty() or letter.get("status") not in ["pending", "delivered"]:
			return "travel.letters 排期或状态错误"
	return ""
