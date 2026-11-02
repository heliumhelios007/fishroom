extends RefCounted
## generate 提供待生成元数据；merge_ai 合并 DSH 标题与正文。
## 照片顺序和排期只读 JSON；网络由 GameUI 下 CompanionClient 独立处理。

var last_reason: Dictionary = {}
var last_warnings: Array = []
var last_letter_diagnostics: Array = []
# 仅检查照片目录中的专名；不能从 caption 首段猜出“傍晚”等通用词。
# 未知专名仍由 /letters 的独立语义审核负责。
const SCENERY_NAMES := ["西湖", "雷峰塔", "三潭印月", "西溪湿地", "虎跑公园", "九溪十八涧", "城隍阁", "吴山", "深度求索", "DeepSeek", "星河鲸王"]

func generate(location: Dictionary, seat: Dictionary) -> Array:
	var result: Array = []
	for plan in seat.get("letters", []):
		var captions: Array[String] = []
		for photo_id in plan["photo_ids"]:
			for photo in location.get("photos", []):
				if photo["id"] == photo_id:
					captions.append(photo["caption"])
		var body := ""
		result.append({"index": int(plan["index"]), "hour": int(plan["hour"]),
			"title": "旅行来信", "photo_ids": plan["photo_ids"].duplicate(), "body": body, "status": "pending", "source": "pending"})
	return result


## AI 提供标题与正文，排期/照片始终沿用配置；任一封不合法则整批拒绝。
func merge_ai(value: Variant, location: Dictionary, seat: Dictionary) -> Array:
	last_reason = {}
	last_warnings = []
	last_letter_diagnostics = []
	var batch_context := {"index":-1, "body_chars":-1, "caption_match":false, "caption_hits":[], "title":""}
	if not value is Array:
		return _reject("MERGE_BATCH_TYPE", batch_context)
	var plans: Array = seat.get("letters", [])
	if value.is_empty() or value.size() != plans.size():
		return _reject("MERGE_SIZE_MISMATCH", batch_context, {"expected":plans.size(), "actual":value.size()})
	var result := generate(location, seat)
	var forbidden := ["写一封", "请根据", "写作", "提示词", "系统提示", "语言模型", "prompt", "字数", "以下是", "生成要求", "作为AI", "作为 AI"]
	for i in range(value.size()):
		var letter: Variant = value[i]
		var plan: Dictionary = plans[i]
		var context := batch_context.duplicate(true)
		context["index"] = int(plan["index"])
		context["position"] = i
		if not letter is Dictionary:
			return _reject("MERGE_LETTER_TYPE", context)
		context["title"] = display_title(letter, true)
		if letter.get("body") is String:
			context["body_chars"] = String(letter["body"]).strip_edges().length()
			for photo_id in plan["photo_ids"]:
				var hits: Array = location.get("photos", []).filter(func(photo: Dictionary): return photo["id"] == photo_id)
				context["caption_hits"].append(not hits.is_empty() and String(letter["body"]).contains(String(hits[0]["caption"])))
			context["caption_match"] = not context["caption_hits"].is_empty() and context["caption_hits"].all(func(hit: bool): return hit)
		last_letter_diagnostics.append(context)
		var index: Variant = letter.get("index")
		if not (index is int or index is float):
			return _reject("MERGE_INDEX_TYPE", context)
		if not is_finite(float(index)) or float(index) != float(int(index)) or int(index) != int(plan["index"]):
			return _reject("MERGE_INDEX_MISMATCH", context)
		if not letter.get("body") is String:
			return _reject("MERGE_BODY_TYPE", context)
		var body := String(letter["body"]).strip_edges()
		var allowed_scene := String(plan.get("scene_prompt", ""))
		var ordered_photos: Array = []
		for photo_id in plan["photo_ids"]:
			var matches: Array = location.get("photos", []).filter(func(photo: Dictionary): return photo["id"] == photo_id)
			if matches.size() != 1 or String(matches[0].get("caption", "")).is_empty():
				return _reject("MERGE_PHOTO_MISSING", context, {"photo_id":photo_id})
			ordered_photos.append(matches[0])
			allowed_scene += "\n" + String(matches[0]["caption"])
		if letter.has("photo_ids") and letter["photo_ids"] != plan["photo_ids"]:
			return _reject("MERGE_PHOTO_ORDER", context)
		if body.length() < 120:
			return _reject("MERGE_BODY_TOO_SHORT", context)
		if body.length() > 360:
			return _reject("MERGE_BODY_TOO_LONG", context)
		if body.length() > 300:
			_warn("MERGE_BODY_OVER_TARGET", context)
		for word in forbidden:
			if body.to_lower().contains(word.to_lower()):
				return _reject("MERGE_META_TEXT", context, {"word":word})
		var previous_position := -1
		for photo in ordered_photos:
			var position := body.find(String(photo["caption"]))
			if position < 0:
				return _reject("MERGE_CAPTION_MISSING", context, {"photo_id":photo["id"]})
			if position <= previous_position:
				return _reject("MERGE_CAPTION_ORDER", context, {"photo_id":photo["id"]})
			previous_position = position
			if photo.get("fictional", false):
				var reason := fiction_violation(body)
				if reason != "":
					return _reject("MERGE_FICTION", context, {"detail":reason})
		for photo in location.get("photos", []):
			if photo["id"] in plan["photo_ids"]:
				continue
			for name in SCENERY_NAMES:
				if String(photo["caption"]).to_lower().contains(name.to_lower()) and body.to_lower().contains(name.to_lower()) and not allowed_scene.to_lower().contains(name.to_lower()):
					return _reject("MERGE_UNEXPECTED_SCENERY", context, {"word":name})
		result[i]["title"] = display_title(letter, true)
		if result[i]["title"] != letter.get("title", ""):
			_warn("MERGE_TITLE_INVALID", context)
		result[i]["title_source"] = "dsh"
		result[i]["body"] = body
		result[i]["source"] = "ai"
		print("LETTER_MERGE_VALIDATED " + JSON.stringify(context))
	return result


func _reject(code: String, context: Dictionary, details: Dictionary = {}) -> Array:
	last_reason = context.duplicate(true)
	last_reason.merge(details, true)
	last_reason["reason"] = code
	print("LETTER_MERGE_REJECTED " + JSON.stringify(last_reason))
	return []


func _warn(code: String, context: Dictionary) -> void:
	var warning := context.duplicate(true)
	warning["reason"] = code
	last_warnings.append(warning)
	print("LETTER_MERGE_WARNING " + JSON.stringify(warning))


func fiction_violation(body: String) -> String:
	var marker := RegEx.new()
	marker.compile("虚构插画|虚构彩蛋|梦|幻想")
	if marker.search(body) == null:
		return "missing_fiction_marker"
	var forbidden := RegEx.new()
	forbidden.compile("创始人|梁文锋|真人|本人|真实照片|真实事件|公司内部|内部消息")
	if forbidden.search(body) != null:
		return "real_person_or_internal_fact"
	var reality := RegEx.new()
	reality.compile("(?:现实|真实|实地|现场)[^。！？\n]{0,16}(?:拍摄|拍到|合影|遇到|遇见|见到)|(?:拍摄|拍到|合影)[^。！？\n]{0,16}(?:星河鲸王|彩蛋)|(?:星河鲸王|彩蛋)[^。！？\n]{0,16}(?:现实|真实|拍摄|拍到|合影)")
	if reality.search(body) != null:
		return "real_world_easter_egg"
	return ""


func display_title(message: Dictionary, generated: bool = false) -> String:
	var title = message.get("title", "")
	if not title is String:
		return "旅行来信"
	var rule := RegEx.new()
	rule.compile("^[\\x{4e00}-\\x{9fff}]{2,20}$")
	if rule.search(title) == null:
		return "旅行来信"
	for word in ["小时", "系统", "日期", "编号", "账号", "密钥", "姓名"]:
		if title.contains(word):
			return "旅行来信"
	if not generated and message.get("title_source", "") != "dsh" and title == "给主人的信":
		return "旅行来信"
	return title
