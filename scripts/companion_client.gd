extends Node
## 每个请求独立 HTTPRequest；只访问本机。无密钥、无启动问候、无自动聊天。

class PendingRequest extends HTTPRequest:
	signal finished(response: Dictionary)
	var completed := false
	var response: Dictionary = {}
	var _started := 0
	var _deadline := 0
	var _connect_deadline := 0
	var _connected := false

	func _init() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		body_size_limit = 32768
		request_completed.connect(_on_completed, CONNECT_ONE_SHOT)
		set_process(false)

	func begin(url: String, method: HTTPClient.Method, body: String, hard_timeout: float, connection_timeout: float) -> void:
		_started = Time.get_ticks_msec()
		_deadline = _started + int(hard_timeout * 1000)
		_connect_deadline = _started + int(connection_timeout * 1000)
		timeout = hard_timeout
		set_process(true)
		var error := request(url, PackedStringArray(["Content-Type: application/json"]), method, body)
		if error != OK:
			_complete({"ok":false, "code":"REQUEST_FAILED", "stage":"connection", "http_status":0, "request_error":error}, true)

	func _process(_delta: float) -> void:
		if completed:
			return
		# Wall time, independent of game time, Engine.time_scale and SceneTree pause.
		if Time.get_ticks_msec() >= _deadline:
			abort("TIMEOUT")
			return
		if get_http_client_status() in [HTTPClient.STATUS_CONNECTED, HTTPClient.STATUS_REQUESTING, HTTPClient.STATUS_BODY]:
			_connected = true
		if not _connected and Time.get_ticks_msec() >= _connect_deadline:
			abort("CONNECT_TIMEOUT")

	func _on_completed(result: int, status: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
		if result == HTTPRequest.RESULT_TIMEOUT:
			abort("TIMEOUT")
		else:
			_complete({"http_result":result, "http_status":status, "body":body, "body_bytes":body.size()})

	func abort(code: String) -> void:
		_complete({"ok":false, "code":code, "stage":"connection", "http_status":0, "http_result":HTTPRequest.RESULT_TIMEOUT if code in ["TIMEOUT", "CONNECT_TIMEOUT"] else -1}, true)

	func _complete(value: Dictionary, cancel := false) -> void:
		if completed:
			return
		completed = true
		response = value
		response["elapsed_ms"] = maxi(0, Time.get_ticks_msec() - _started)
		if not response.has("body_bytes"):
			response["body_bytes"] = get_downloaded_bytes()
		set_process(false)
		# Set completed before cancel_request: late/reentrant signals are harmless.
		if cancel:
			cancel_request()
		finished.emit(response)

	func _exit_tree() -> void:
		# Scene reload/removal must release awaiters even without request_completed.
		abort("REQUEST_CANCELLED")

var enabled := true
var base_url := "http://127.0.0.1:8765"
var memory_url := "http://127.0.0.1:8770"
const RUNTIME_CONFIG := "user://runtime_endpoints.json"
var connect_timeout := 3.0
var request_timeout := 22.0
@onready var _game_state: Node = get_node("/root/GameState")
var _active := 0
var connection: Dictionary = {}
signal connection_changed
var _connection_refreshing := false
var _letter_jobs: Array = []
var _letters_busy := false
var _letter_retry_after := 0
var _letter_attempts: Dictionary = {}
var _letter_blocked: Dictionary = {}
var _letters_disconnected := false
var _letter_request_ticket_id := ""
var _request_sequence := 0
var last_merge_reason: Dictionary = {}
const LETTER_MAX_ATTEMPTS := 3
const LETTER_REQUEST_TIMEOUT := 60.0
const LETTER_JOBS := "user://dsh_pending_letters.json"
const _MEMORY_QUEUE := "user://stage11_memory_outbox.json"
var _memory_pending: Array = []
var _memory_seen: Dictionary = {}
var _memory_travel: Dictionary = {}
var _memory_flushing := false
var _memory_completed_candidate: Dictionary = {}

func _ready() -> void:
	var config: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/companion.json"))
	if config is Dictionary:
		enabled = config.get("enabled", true) == true
		base_url = str(config.get("base_url", base_url)).trim_suffix("/")
		connect_timeout = clampf(float(config.get("connect_timeout", 3.0)), 0.1, 10.0)
		request_timeout = clampf(float(config.get("request_timeout", 22.0)), connect_timeout, 65.0)
	if OS.has_feature("android"):
		enabled = false
	if FileAccess.file_exists(RUNTIME_CONFIG):
		var local: Variant = JSON.parse_string(FileAccess.get_file_as_string(RUNTIME_CONFIG))
		if local is Dictionary and valid_endpoint(str(local.get("companion", ""))) and valid_endpoint(str(local.get("memory", ""))):
			base_url = str(local["companion"])
			memory_url = str(local["memory"])
			enabled = local.get("enabled", false) == true
	if FileAccess.file_exists(LETTER_JOBS):
		var jobs: Variant = JSON.parse_string(FileAccess.get_file_as_string(LETTER_JOBS))
		if jobs is Array:
			_letter_jobs = jobs
	_memory_init()
	_queue_travel(_game_state.get_active_travel())
	for travel in _game_state.get_pending_travels():
		_queue_travel(travel)

# Stage11 observes new events only; it never changes GameState or imports old messages.
func _memory_init() -> void:
	for message in _game_state.get_chat_messages():
		_memory_seen[str(message.get("id", ""))] = true
	_memory_travel = _game_state.get_active_travel().duplicate(true)
	if FileAccess.file_exists(_MEMORY_QUEUE):
		var pending: Variant = JSON.parse_string(FileAccess.get_file_as_string(_MEMORY_QUEUE))
		if pending is Array:
			_memory_pending = pending
	_game_state.messages_changed.connect(_memory_messages)
	_game_state.travel_changed.connect(_memory_travel_changed)
	_game_state.travel_completed.connect(_memory_completed)
	var retry := Timer.new()
	retry.wait_time = 5.0
	retry.timeout.connect(_memory_flush)
	add_child(retry)
	retry.start()

func _memory_messages() -> void:
	for message in _game_state.get_chat_messages():
		var id := str(message.get("id", ""))
		if _memory_seen.has(id):
			continue
		_memory_seen[id] = true
		if message.get("kind") == "travel_letter":
			_memory_enqueue(id, "travel_letter_delivered", JSON.stringify(message))

func _memory_travel_changed() -> void:
	var current: Dictionary = _game_state.get_active_travel()
	_queue_travel(current)
	if not current.is_empty() and current.get("id") != _memory_travel.get("id") and _game_state._travel_busy:
		_memory_enqueue(str(current.get("id")) + "-start", "travel_started", JSON.stringify({"event":"travel_started", "location":current.get("location"), "seat":current.get("seat"), "time":current.get("started_at")}))
	elif current.is_empty() and not _memory_travel.is_empty():
		_memory_completed_candidate = _memory_travel.duplicate(true)
	_memory_travel = current.duplicate(true)

func _memory_completed(_location_name: String) -> void:
	if _memory_completed_candidate.is_empty():
		return
	var travel: Dictionary = _memory_completed_candidate
	_memory_enqueue(str(travel.get("id")) + "-complete", "travel_completed", JSON.stringify({"event":"travel_completed", "location":travel.get("location"), "seat":travel.get("seat"), "time":travel.get("ends_at")}))
	_memory_completed_candidate = {}

func _memory_save() -> void:
	var file := FileAccess.open(_MEMORY_QUEUE + ".tmp", FileAccess.WRITE)
	if file == null:
		push_warning("MEMORY_QUEUE_WRITE_FAILED")
		return
	file.store_string(JSON.stringify(_memory_pending))
	file.close()
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(_MEMORY_QUEUE + ".tmp"), ProjectSettings.globalize_path(_MEMORY_QUEUE)) != OK:
		push_warning("MEMORY_QUEUE_RENAME_FAILED")

func _memory_enqueue(id: String, event: String, text: String) -> void:
	_memory_pending.append({"id":id, "event":event, "text":text, "ts":Time.get_datetime_string_from_system(true) + "Z"})
	_memory_save()

func _memory_flush() -> void:
	_retry_letters()
	if _memory_flushing or _memory_pending.is_empty():
		return
	_memory_flushing = true
	while not _memory_pending.is_empty():
		var result := await post("/events", _memory_pending[0])
		if not result.get("ok", false):
			break
		_memory_pending.pop_front()
		_memory_save()
	_memory_flushing = false

func post(endpoint: String, payload: Dictionary) -> Dictionary:
	var context: Dictionary = {}
	if endpoint == "/letters":
		_request_sequence += 1
		context = {"request_id":"%s-%d-%d" % [get_instance_id(), Time.get_ticks_msec(), _request_sequence], "ticket_id":_letter_request_ticket_id if not _letter_request_ticket_id.is_empty() else str(payload.get("generation_key", "")).rsplit(":", true, 1)[0], "seat":payload.get("seat", ""), "indices":payload.get("letter_indices", []), "elapsed_ms":0, "status":0, "body_bytes":0}
		# Catalog-only payload, retained for same-payload direct POST verification.
		var entry := context.duplicate(true)
		entry.merge({"url":base_url + endpoint, "content_type":"application/json", "payload":payload})
		print("LETTER_REQUEST " + JSON.stringify(entry))
	if not enabled or endpoint not in ["/letters", "/chat", "/events", "/connection", "/connection/test", "/connection/presets"]:
		return _finish_post(endpoint, {"ok": false, "code": "DISABLED", "stage":"connection", "http_status":0}, context)
	if _active >= 4:
		return _finish_post(endpoint, {"ok": false, "code": "BUSY", "stage":"connection", "http_status":0}, context)
	_active += 1
	var hard_timeout := LETTER_REQUEST_TIMEOUT if endpoint == "/letters" else request_timeout
	var response := await _request_http(base_url + endpoint, HTTPClient.METHOD_POST, JSON.stringify(payload), hard_timeout, connect_timeout)
	_active -= 1
	return _finish_post(endpoint, response, context)


func _request_http(url: String, method: HTTPClient.Method, body: String, hard_timeout: float, connection_timeout: float) -> Dictionary:
	if not is_inside_tree() or is_queued_for_deletion():
		return {"ok":false, "code":"REQUEST_CANCELLED", "stage":"connection", "http_status":0, "body_bytes":0, "elapsed_ms":0}
	var request := PendingRequest.new()
	add_child(request)
	request.begin(url, method, body, hard_timeout, connection_timeout)
	# request() may fail/finish synchronously, before await can subscribe.
	var response: Dictionary = request.response if request.completed else await request.finished
	if is_instance_valid(request) and not request.is_queued_for_deletion():
		request.queue_free()
	if response.has("body"):
		var decoded := _decode_post_response(response["http_result"], response["http_status"], response["body"])
		decoded["body_bytes"] = response["body_bytes"]
		decoded["elapsed_ms"] = response["elapsed_ms"]
		return decoded
	return response


func _decode_post_response(result: int, status: int, body: PackedByteArray) -> Dictionary:
	if body.size() > 32768 or result == HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
		return {"ok":false, "code":"RESPONSE_TOO_LARGE", "stage":"connection", "http_status":status, "http_result":result}
	var parser := JSON.new()
	var parsed := parser.parse(body.get_string_from_utf8())
	var data: Variant = parser.data if parsed == OK else null
	var response := {"ok":false, "code":"HTTP_%d_%d" % [result, status], "http_status":status, "http_result":result, "stage":"connection"}
	if data is Dictionary and data.get("error") is Dictionary:
		# Keep the structured server error even when HTTP failed. No raw body logging.
		response["error"] = data["error"].duplicate(true)
	if result != HTTPRequest.RESULT_SUCCESS:
		return response
	if status != 200:
		response["stage"] = "HTTP"
		return response
	if parsed != OK or not data is Dictionary:
		response["stage"] = "JSON"
		response["code"] = "INVALID_JSON_RESPONSE"
		return response
	if data.has("error"):
		response["stage"] = "HTTP"
		response["code"] = "SERVER_ERROR"
		return response
	return {"ok":true, "data":data, "http_status":status, "http_result":result, "stage":"complete"}


func _finish_post(endpoint: String, response: Dictionary, context: Dictionary = {}) -> Dictionary:
	if endpoint == "/letters":
		for key in context:
			if not response.has(key):
				response[key] = context[key]
		response["status"] = response.get("http_status", 0)
		_log_letter_result(response)
	return response


func _log_letter_result(response: Dictionary) -> void:
	var error: Dictionary = response.get("error", {})
	print("LETTER_RESPONSE " + JSON.stringify({"request_id":response.get("request_id", ""), "ticket_id":response.get("ticket_id", ""), "seat":response.get("seat", ""), "indices":response.get("indices", []), "elapsed_ms":response.get("elapsed_ms", 0), "status":response.get("http_status", 0), "body_bytes":response.get("body_bytes", 0), "ok":response.get("ok", false), "stage":response.get("stage", "unknown"), "http_status":response.get("http_status", 0), "http_result":response.get("http_result", -1), "code":response.get("code", ""), "error_code":error.get("code", ""), "merge_reason":response.get("merge_reason", {})}))

static func valid_endpoint(value: String) -> bool:
	var pattern := RegEx.new()
	pattern.compile("^https?://([a-zA-Z0-9.-]+)(:([0-9]{1,5}))?$")
	var found := pattern.search(value)
	if found == null:
		return false
	var port := found.get_string(3)
	if not port.is_empty() and (int(port) < 1 or int(port) > 65535):
		return false
	var host := found.get_string(1).to_lower()
	if value.begins_with("https://"):
		return true
	if host in ["localhost", "127.0.0.1"] or host.ends_with(".ts.net"):
		return true
	var parts := host.split(".")
	if parts.size() != 4:
		return false
	for part in parts:
		if not part.is_valid_int() or int(part) < 0 or int(part) > 255:
			return false
	return int(parts[0]) == 10 or (int(parts[0]) == 192 and int(parts[1]) == 168) or (int(parts[0]) == 172 and int(parts[1]) >= 16 and int(parts[1]) <= 31) or (int(parts[0]) == 100 and int(parts[1]) >= 64 and int(parts[1]) <= 127)


func configure_endpoints(companion: String, memory: String, use_services: bool) -> bool:
	companion = companion.strip_edges().trim_suffix("/")
	memory = memory.strip_edges().trim_suffix("/")
	if not valid_endpoint(companion) or not valid_endpoint(memory) or _active > 0:
		return false
	var file := FileAccess.open(RUNTIME_CONFIG + ".tmp", FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify({"companion":companion, "memory":memory, "enabled":use_services}))
	file.flush()
	var err := file.get_error()
	file.close()
	if err != OK or DirAccess.rename_absolute(RUNTIME_CONFIG + ".tmp", RUNTIME_CONFIG) != OK:
		return false
	base_url = companion
	memory_url = memory
	enabled = use_services
	connection = {"connected":false}
	connection_changed.emit()
	return true


func prepare_ticket(_ticket: Dictionary) -> void:
	_retry_letters.call_deferred()

func get_local(endpoint: String, memory := false) -> Dictionary:
	if not enabled:
		return {}
	var url := memory_url if memory else base_url
	# Connection refresh is also awaited by the letter worker; bound it as well.
	if endpoint == "/connection" and not memory:
		var response := await _request_http(url + endpoint, HTTPClient.METHOD_GET, "", 4.0, connect_timeout)
		return response["data"] if response.get("ok", false) else {}
	var request := HTTPRequest.new()
	request.timeout = 4.0
	add_child(request)
	if request.request(url + endpoint) != OK:
		request.queue_free()
		return {}
	var result: Array = await request.request_completed
	request.queue_free()
	if result[0] != HTTPRequest.RESULT_SUCCESS or result[1] != 200:
		return {}
	var value: Variant = JSON.parse_string(result[3].get_string_from_utf8())
	return value if value is Dictionary else {}


func _exit_tree() -> void:
	_letters_busy = false
	_connection_refreshing = false
	connection_changed.emit()
	for child in get_children():
		if child is PendingRequest:
			child.abort("REQUEST_CANCELLED")

func refresh_connection() -> Dictionary:
	if _connection_refreshing:
		await connection_changed
		return connection
	_connection_refreshing = true
	connection = await get_local("/connection")
	if not connection.has("connected"):
		connection = {"connected":false, "error":"CONNECTION_UNAVAILABLE"}
	_connection_refreshing = false
	connection_changed.emit()
	return connection

func _save_letter_jobs() -> void:
	var serialized := JSON.stringify(_letter_jobs)
	if FileAccess.file_exists(LETTER_JOBS) and FileAccess.get_file_as_string(LETTER_JOBS) == serialized:
		return
	var file := FileAccess.open(LETTER_JOBS + ".tmp", FileAccess.WRITE)
	if file == null:
		_log_letter_result({"code":"LETTER_CACHE_WRITE_FAILED", "stage":"merge"})
		return
	file.store_string(serialized)
	file.close()
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(LETTER_JOBS + ".tmp"), ProjectSettings.globalize_path(LETTER_JOBS)) != OK:
		_log_letter_result({"code":"LETTER_CACHE_RENAME_FAILED", "stage":"merge"})

func _queue_travel(_travel: Dictionary) -> void:
	_retry_letters.call_deferred()

func _letter_payload(job: Dictionary) -> Dictionary:
	var location: Dictionary = _game_state.get_location(job["location"])
	var seat: Dictionary = _game_state.get_seat(job["location"], job["seat"])
	if location.is_empty() or seat.is_empty() or not job.get("indices") is Array or job["indices"].is_empty():
		return {}
	var plans: Array = []
	var ids: Array = []
	var indices: Array = []
	var wanted: Array = []
	for value in job["indices"]:
		wanted.append(int(value))
	for plan in seat["letters"]:
		if int(plan["index"]) in wanted:
			plans.append({"index":int(plan["index"]), "photo_ids":plan["photo_ids"], "scene_prompt":plan.get("scene_prompt", "")})
			ids.append_array(plan["photo_ids"])
			indices.append(int(plan["index"]))
	if indices.size() != wanted.size():
		return {}
	var photos: Array = []
	for photo in location["photos"]:
		if photo["id"] in ids:
			photos.append({"id":photo["id"], "caption":photo["caption"]})
	for id in ids:
		if not photos.any(func(photo: Dictionary): return photo["id"] == id and not String(photo["caption"]).strip_edges().is_empty()):
			return {}
	# 当前人格由 companion 使用已选 DSH preset，不发送身份或聊天原话。
	var parts: Array[String] = []
	for index in indices:
		parts.append(str(index))
	var key := str(job["ticket_id"]) + ":" + ".".join(parts)
	var pattern := RegEx.new()
	pattern.compile("^[a-zA-Z0-9_.:-]{1,180}$")
	if pattern.search(key) == null:
		return {}
	return {"location":job["location"], "seat":job["seat"], "letter_count":seat["letters"].size(), "letter_indices":indices, "generation_key":key, "plans":plans, "photos":photos}


func _letter_fingerprint(payload: Dictionary) -> String:
	return JSON.stringify(payload).sha256_text()


func _record_letter_failure(fingerprint: String, response: Dictionary) -> void:
	var status := int(response.get("http_status", 0))
	var error: Dictionary = response.get("error", {})
	var code := str(error.get("code", response.get("code", "UNKNOWN")))
	# Validation rejection stays blocked; transport failures must recover in-session.
	if (status >= 400 and status < 500) or (code.begins_with("INVALID_") and code != "INVALID_JSON_RESPONSE") or code in ["UNSAFE_FICTION", "UNEXPECTED_SCENERY"] or response.get("stage") == "merge":
		_letter_blocked[fingerprint] = true
	_schedule_letter_retry()
	print("LETTER_GENERATE_FAILED " + JSON.stringify({"request_id":response.get("request_id", ""), "ticket_id":response.get("ticket_id", _letter_request_ticket_id), "seat":response.get("seat", ""), "indices":response.get("indices", []), "elapsed_ms":response.get("elapsed_ms", 0), "body_bytes":response.get("body_bytes", 0), "stage":response.get("stage", "unknown"), "code":response.get("code", "UNKNOWN"), "http_status":status, "error_code":error.get("code", ""), "merge_reason":response.get("merge_reason", {}), "attempt":_letter_attempts.get(fingerprint, 0), "automatic_retry":not _letter_blocked.has(fingerprint)}))


func _schedule_letter_retry() -> void:
	_letter_retry_after = Time.get_ticks_msec() + 30000
	if is_inside_tree() and not is_queued_for_deletion():
		# Real-time retry also works while game time is paused or accelerated.
		get_tree().create_timer(30.0, true, false, true).timeout.connect(_retry_letters, CONNECT_ONE_SHOT)


func _letter_job_is_current(job: Dictionary) -> bool:
	var payload := _letter_payload(job)
	return _game_state.get_letter_work().any(func(item: Dictionary): return item["ticket_id"] == job["ticket_id"] and item["location"] == job["location"] and item["seat"] == job["seat"] and _letter_payload(item) == payload)


func _merge_letter_response(job: Dictionary, response: Dictionary) -> Dictionary:
	last_merge_reason = {}
	var location: Dictionary = _game_state.get_location(job["location"])
	var seat: Dictionary = _game_state.get_seat(job["location"], job["seat"]).duplicate(true)
	var indices: Array = job["indices"].map(func(index: Variant): return int(index))
	seat["letters"] = seat["letters"].filter(func(plan: Dictionary): return int(plan["index"]) in indices)
	var generated: Variant = response["data"].get("letters")
	var short_attempts: Dictionary = {}
	while true:
		if not _letter_job_is_current(job):
			return {"ok":false, "code":"STALE_TICKET", "stage":"merge"}
		var prepared: Array = _game_state.letter_provider.merge_ai(generated, location, seat)
		if not prepared.is_empty():
			return {"ok":true, "generated":prepared}
		last_merge_reason = _game_state.letter_provider.last_reason.duplicate(true)
		var failure := {"ok":false, "code":"INVALID_BATCH", "stage":"merge", "http_status":response.get("http_status", 200), "merge_reason":last_merge_reason}
		if last_merge_reason.get("reason") != "MERGE_BODY_TOO_SHORT":
			return failure
		var index := int(last_merge_reason["index"])
		var attempt := int(short_attempts.get(index, 0)) + 1
		if attempt >= LETTER_MAX_ATTEMPTS:
			return failure
		short_attempts[index] = attempt
		var retry_job := job.duplicate(true)
		retry_job["indices"] = [index]
		var retry_payload := _letter_payload(retry_job)
		# A fresh key is necessary: /letters caches successful (even short) responses.
		# Keep this bounded and tied to the complete original payload/ticket.
		retry_payload["generation_key"] = "merge-short:" + _letter_fingerprint(_letter_payload(job)) + ":%d:%d" % [index, attempt]
		print("LETTER_MERGE_RETRY " + JSON.stringify({"reason":last_merge_reason, "index":index, "attempt":attempt, "letter_indices":retry_payload["letter_indices"]}))
		var retry_response := await post("/letters", retry_payload)
		if not _letter_job_is_current(job):
			return {"ok":false, "code":"STALE_TICKET", "stage":"merge"}
		if not retry_response.get("ok", false):
			retry_response["merge_reason"] = last_merge_reason
			return retry_response
		var replacement: Variant = retry_response["data"].get("letters")
		var retry_seat := seat.duplicate(true)
		retry_seat["letters"] = retry_seat["letters"].filter(func(plan: Dictionary): return int(plan["index"]) == index)
		var checked: Array = _game_state.letter_provider.merge_ai(replacement, location, retry_seat)
		if checked.is_empty():
			last_merge_reason = _game_state.letter_provider.last_reason.duplicate(true)
			if last_merge_reason.get("reason") != "MERGE_BODY_TOO_SHORT":
				return {"ok":false, "code":"INVALID_BATCH", "stage":"merge", "http_status":retry_response.get("http_status", 200), "merge_reason":last_merge_reason}
		# Keep all fragments in memory until a complete batch validates; never apply here.
		generated = generated.duplicate(true)
		generated[int(failure["merge_reason"]["position"])] = replacement[0] if checked.is_empty() else checked[0]
	return {"ok":false, "code":"INVALID_BATCH", "stage":"merge", "merge_reason":last_merge_reason}

func _retry_letters() -> void:
	if _letters_busy or not enabled:
		return
	_letters_busy = true
	await _letter_worker()
	_letters_busy = false
	_letter_request_ticket_id = ""


func _letter_worker() -> void:
	# Only payload-bound complete responses may be replayed; discard old snapshots.
	var work: Array = _game_state.get_letter_work()
	# 正式存档是唯一任务源。旧旅行快照不能复活已完成或已恢复的档。
	_letter_jobs = _letter_jobs.filter(func(cached: Variant): return cached is Dictionary and cached.get("generated") is Array and work.any(func(job: Dictionary): return job["ticket_id"] == cached.get("ticket_id") and cached.get("payload") == _letter_payload(job)))
	for cached in _letter_jobs.duplicate():
		if _game_state.apply_ai_letters(cached["ticket_id"], cached["generated"]):
			_letter_jobs.erase(cached)
		elif not _game_state.letter_provider.last_reason.is_empty():
			last_merge_reason = _game_state.letter_provider.last_reason.duplicate(true)
			_log_letter_result({"code":"INVALID_BATCH", "stage":"merge", "merge_reason":last_merge_reason})
	_save_letter_jobs()
	work = _game_state.get_letter_work()
	if Time.get_ticks_msec() < _letter_retry_after:
		return
	if not work.is_empty():
		var status := await refresh_connection()
		if not status.get("connected", false):
			if not _letters_disconnected:
				_log_letter_result({"code":"DSH_DISCONNECTED", "stage":"connection", "error":{"code":status.get("error", "DSH_DISCONNECTED")}})
			_letters_disconnected = true
			_schedule_letter_retry()
			return
		if _letters_disconnected:
			_letter_attempts.clear()
			_letter_blocked.clear()
			_letters_disconnected = false
	for job in work:
		# A previous await may have restored/replaced the save or filled this ticket.
		var current: Array = _game_state.get_letter_work().filter(func(item: Dictionary): return item["ticket_id"] == job["ticket_id"] and item["location"] == job["location"] and item["seat"] == job["seat"])
		if current.is_empty():
			continue
		job = current[0]
		if _letter_jobs.any(func(cached: Dictionary): return cached["ticket_id"] == job["ticket_id"]):
			continue
		var payload := _letter_payload(job)
		var fingerprint := _letter_fingerprint(payload)
		if _letter_blocked.has(fingerprint):
			continue
		if payload.is_empty():
			_record_letter_failure(fingerprint, {"code":"INVALID_CLIENT_PAYLOAD", "stage":"JSON"})
			continue
		_letter_attempts[fingerprint] = int(_letter_attempts.get(fingerprint, 0)) + 1
		_letter_request_ticket_id = str(job["ticket_id"])
		print("LETTER_GENERATE ticket=%s indices=%s" % [job["ticket_id"], str(job["indices"])])
		var result := await post("/letters", payload)
		if result.get("code") == "REQUEST_CANCELLED":
			_schedule_letter_retry()
			return
		if not result.get("ok", false):
			_record_letter_failure(fingerprint, result)
			break
		var merged := await _merge_letter_response(job, result)
		if merged.get("code") == "REQUEST_CANCELLED":
			_schedule_letter_retry()
			return
		if merged.get("code") == "STALE_TICKET":
			print("LETTER_RESPONSE_DISCARDED stage=merge code=STALE_TICKET")
			continue
		if not merged.get("ok", false):
			_record_letter_failure(fingerprint, merged)
			break
		var generated: Array = merged["generated"]
		var cached := {"ticket_id":job["ticket_id"], "payload":payload, "generated":generated}
		_letter_jobs.append(cached)
		_save_letter_jobs()
		if _game_state.apply_ai_letters(job["ticket_id"], generated):
			_letter_jobs.erase(cached)
		else:
			last_merge_reason = _game_state.letter_provider.last_reason.duplicate(true)
			_log_letter_result({"code":"SAVE_OR_MERGE_DEFERRED", "stage":"merge", "http_status":result.get("http_status", 200), "merge_reason":last_merge_reason})
		_save_letter_jobs()
	for travel in _game_state.get_pending_travels() + ([_game_state.get_active_travel()] if _game_state.is_traveling() else []):
		_game_state.deliver_pending_travel(travel)
	print("LETTER_PENDING count=%d" % _game_state.pending_letter_count())
