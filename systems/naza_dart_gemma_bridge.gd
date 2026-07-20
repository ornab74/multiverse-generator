extends Node
class_name NazaDartGemmaBridge

## Owns the local, CPU-only Dart/Gemma process and its authenticated loopback
## transport. The bearer token is generated for each process launch, inherited
## by that child only, and is never included in a public snapshot.

const DEFAULT_PORT := 47621
const LOOPBACK_HOST := "127.0.0.1"
const HEALTH_TIMEOUT_SECONDS := 4.0
const INFERENCE_TIMEOUT_SECONDS := 330.0
const PROBE_INTERVAL_SECONDS := 0.55
const MAX_REQUEST_BYTES := 64 * 1024
const MAX_RESPONSE_BYTES := 1024 * 1024
const TOKEN_BYTES := 32
const BACKEND_SCHEMA := "nexus.chess-llm/1"
const MODEL_FILE_NAME := "gemma-4-E2B-it.litertlm"
const RELEASE_EXECUTABLE := "res://chess_llm_backend/build/linux/x64/release/bundle/nexus_chess_llm"
const DEBUG_EXECUTABLE := "res://chess_llm_backend/build/linux/x64/debug/bundle/nexus_chess_llm"
const DEFAULT_MODEL_PATH := "res://chess_llm_backend/models/" + MODEL_FILE_NAME
const ALLOWED_ROUTES := {
"/health": true,
"/v1/chat": true,
"/v1/chess/turn": true,
"/v1/chess/analyze": true,
"/v1/history": true,
"/v1/games": true,
"/v1/preferences": true,
}

signal ready_changed(is_ready: bool, detail: String)
signal progress_changed(progress: int, phase: String)
signal snapshot_changed(snapshot: Dictionary)
signal status_changed(status: String, detail: String)
signal process_changed(status: String, pid: int)

@export var auto_start := true
@export_range(1024, 65535, 1) var port := DEFAULT_PORT
@export_file("*.litertlm") var configured_model_path := ""

var pid := -1
var status := "stopped"
var status_detail := "local chess model is stopped"
var is_ready := false
var ready_detail := "local chess model is stopped"
var initialization_progress := 0
var initialization_phase := "stopped"
var activity := "idle"
var model_ready := false
var sample_ready := false
var sample_reply := ""
var last_error := ""
var model_source := ""
var generation_busy := false
var history_ready := false
var history_entries := 0
var saved_games := 0
var model_verification_cached := false

var endpoint: String:
	get:
		return "http://%s:%d" % [LOOPBACK_HOST, port]

var _bearer_token := ""
var _owned_pid := -1
var _lifecycle_epoch := 0
var _probe_in_flight := false
var _health_in_flight := false
var _request_in_flight := false
var _probe_timer: Timer
var _health_http: HTTPRequest
var _request_http: HTTPRequest


func _ready() -> void:
	_health_http = _make_http_request(HEALTH_TIMEOUT_SECONDS)
	_request_http = _make_http_request(INFERENCE_TIMEOUT_SECONDS)
	_probe_timer = Timer.new()
	_probe_timer.wait_time = PROBE_INTERVAL_SECONDS
	_probe_timer.one_shot = false
	_probe_timer.timeout.connect(_probe)
	add_child(_probe_timer)
	if auto_start:
		call_deferred("start_backend")
	else:
		_emit_snapshot()


func _exit_tree() -> void:
	# Never discover or terminate a process by port. Only the PID returned by
	# OS.create_process is eligible for shutdown.
	_lifecycle_epoch += 1
	_cancel_requests()
	_kill_owned_process()


func configure(new_port: int = DEFAULT_PORT, model_path: String = "") -> Dictionary:
	if _owned_process_is_running():
		return _operation_result(false, "backend_running", "Stop the local backend before changing its configuration.")
	if not _valid_port(new_port):
		return _operation_result(false, "port_invalid", "The loopback port must be between 1024 and 65535.")
	if not model_path.strip_edges().is_empty():
		var resolved := _resolve_local_path(model_path)
		var path_error := _validate_model_path(resolved)
		if not path_error.is_empty():
			return _operation_result(false, "model_path_invalid", path_error)
		configured_model_path = resolved
	else:
		configured_model_path = ""
	port = new_port
	_emit_snapshot()
	return _operation_result(true, "configured", "Local backend configuration updated.")


func start_backend(requested_port: int = -1, requested_model_path: String = "") -> Dictionary:
	if _owned_process_is_running():
		return _operation_result(true, "already_running", "The owned local backend is already running.")
	if _owned_pid > 0:
		# A stale owned PID is never reused and is never replaced by a process
		# discovered through the listening port.
		_owned_pid = -1
		pid = -1

	if requested_port >= 0:
		if not _valid_port(requested_port):
			return _fail_start("port_invalid", "The loopback port must be between 1024 and 65535.")
		port = requested_port
	elif not _valid_port(port):
		return _fail_start("port_invalid", "The loopback port must be between 1024 and 65535.")

	var model_path := _resolve_model_path(requested_model_path)
	var path_error := _validate_model_path(model_path)
	if not path_error.is_empty():
		return _fail_start("model_path_invalid", path_error)
	configured_model_path = model_path

	var executable := _resolve_backend_executable()
	if executable.is_empty():
		return _fail_start(
			"backend_binary_missing",
			"The Flutter backend for %s is not installed beside the game." % OS.get_name()
		)

	_bearer_token = _generate_bearer_token()
	if _bearer_token.length() != TOKEN_BYTES * 2:
		_bearer_token = ""
		return _fail_start("token_generation_failed", "Could not generate the local session credential.")

	_lifecycle_epoch += 1
	_reset_runtime_fields()
	_set_status("starting", "launching the CPU-only chess model")
	_set_progress(1, "launching local CPU backend")

	# OS.create_process inherits the environment. Restore the Godot process's
	# original values immediately afterwards so the bearer token is scoped to
	# the child instead of lingering in the parent environment.
	var child_environment := {
		"NEXUS_CHESS_LLM_TOKEN": _bearer_token,
		"NEXUS_CHESS_LLM_PORT": str(port),
		"NEXUS_CHESS_MODEL_PATH": model_path,
		# Compatibility alias for launchers following the longer naming pattern.
		"NEXUS_CHESS_LLM_MODEL_PATH": model_path,
		"NEXUS_CHESS_LLM_CPU_ONLY": "1",
		# Flutter still needs a renderer for its Linux engine; software Mesa keeps
		# that renderer from selecting a discrete GPU. Gemma separately enforces
		# PreferredBackend.cpu and reports it in /health.
		"LIBGL_ALWAYS_SOFTWARE": "1",
		"DRI_PRIME": "0",
	}
	var previous_environment := _apply_child_environment(child_environment)
	var created_pid := OS.create_process(executable, PackedStringArray(), false)
	_restore_environment(previous_environment)

	if created_pid <= 0:
		_bearer_token = ""
		return _fail_start("backend_launch_failed", "Godot could not launch the local Dart backend binary.")

	_owned_pid = created_pid
	pid = created_pid
	_set_status("starting", "backend process launched; waiting for authenticated health")
	process_changed.emit(status, pid)
	_probe_timer.start()
	_emit_snapshot()
	call_deferred("_probe")
	return _operation_result(true, "backend_started", "The local CPU backend process was launched.")


func stop_backend() -> Dictionary:
	_lifecycle_epoch += 1
	if _probe_timer != null:
		_probe_timer.stop()
	_cancel_requests()
	var stopped_pid := _owned_pid
	var kill_error := _kill_owned_process()
	_bearer_token = ""
	_reset_runtime_fields()
	_set_status("stopped", "local chess model is stopped")
	_set_progress(0, "stopped")
	process_changed.emit(status, pid)
	_emit_snapshot()
	if kill_error != OK:
		return _operation_result(false, "backend_stop_failed", "Could not stop owned backend PID %d (error %d)." % [stopped_pid, kill_error])
	return _operation_result(true, "backend_stopped", "The owned local backend was stopped.")


func restart_backend() -> Dictionary:
	var restart_port := port
	var restart_model := configured_model_path
	stop_backend()
	# Yield once so the operating system can release the loopback listener.
	if is_inside_tree():
		await get_tree().process_frame
	return start_backend(restart_port, restart_model)


func test_backend() -> Dictionary:
	if not _owned_process_is_running():
		return _operation_result(false, "backend_not_running", "Start the local backend before testing it.")
	var result: Dictionary = await health()
	if bool(result.get("ok", false)):
		result["test_ok"] = true
		result["detail"] = "Authenticated loopback health and startup sample passed."
	else:
		result["test_ok"] = false
		result["detail"] = str(result.get("error", result.get("code", "The backend is not ready.")))
	return result


func reset_readiness() -> void:
	_set_ready(false, "waiting for the local chess model")
	_emit_snapshot()


func health() -> Dictionary:
	return await _post_health({"schema": BACKEND_SCHEMA})


func request_chat(payload: Dictionary) -> Dictionary:
	return await _post_request("/v1/chat", payload)


func request_turn(payload: Dictionary) -> Dictionary:
	return await _post_request("/v1/chess/turn", payload)


func request_chess_turn(payload: Dictionary) -> Dictionary:
	return await request_turn(payload)


func request_analysis(payload: Dictionary) -> Dictionary:
	return await _post_request("/v1/chess/analyze", payload)


func request_history(payload: Dictionary) -> Dictionary:
	return await _post_request("/v1/history", payload)


func request_games(payload: Dictionary) -> Dictionary:
	return await _post_request("/v1/games", payload)


func request_preferences(payload: Dictionary) -> Dictionary:
	return await _post_request("/v1/preferences", payload)


func get_snapshot() -> Dictionary:
	return {
		"endpoint": endpoint,
		"host": LOOPBACK_HOST,
		"port": port,
		"pid": pid,
		"owned_process": _owned_pid > 0,
		"process_running": _owned_process_is_running(),
		"status": status,
		"status_detail": status_detail,
		"ready": is_ready,
		"detail": ready_detail,
		"progress": initialization_progress,
		"phase": initialization_phase,
		"activity": activity,
		"model_ready": model_ready,
		"sample_ready": sample_ready,
		"sample_reply": sample_reply,
		"generation_busy": generation_busy,
		"model_source": model_source,
		"history_ready": history_ready,
		"history_entries": history_entries,
		"saved_games": saved_games,
		"model_verification_cached": model_verification_cached,
		"inference_backend": "cpu",
		"gpu_inference_allowed": false,
		"schema": BACKEND_SCHEMA,
		"error": last_error,
	}


func _probe() -> void:
	if _probe_in_flight:
		return
	if not _owned_process_is_running():
		if _owned_pid > 0:
			_owned_pid = -1
			pid = -1
			_bearer_token = ""
			_set_ready(false, "local backend process exited")
			_set_status("failed", "local backend process exited before becoming ready")
			last_error = "The owned Dart backend process exited."
			process_changed.emit(status, pid)
			_emit_snapshot()
		if _probe_timer != null:
			_probe_timer.stop()
		return

	_probe_in_flight = true
	var epoch := _lifecycle_epoch
	var result: Dictionary = await health()
	_probe_in_flight = false
	if epoch != _lifecycle_epoch:
		return
	if bool(result.get("transport_ok", false)):
		_apply_health(result)
	else:
		_set_ready(false, "backend process is starting; waiting for loopback health")
		_set_status("starting", "waiting for the authenticated health endpoint")
		_emit_snapshot()


func _apply_health(result: Dictionary) -> void:
	var schema_ok := str(result.get("schema", "")) == BACKEND_SCHEMA
	var local_only := bool(result.get("local_only", false))
	var cpu_only := str(result.get("inference_backend", "")) == "cpu" and not bool(result.get("gpu_inference_allowed", true))
	model_ready = bool(result.get("model_ready", false))
	sample_ready = bool(result.get("sample_ready", false))
	sample_reply = _bounded_text(result.get("sample_reply", ""), 512)
	activity = _bounded_text(result.get("activity", "initializing"), 160)
	model_source = _bounded_text(result.get("model_source", ""), 256)
	generation_busy = bool(result.get("generation_busy", false))
	history_ready = bool(result.get("local_history_ready", false))
	history_entries = maxi(0, int(result.get("history_entries", 0)))
	saved_games = maxi(0, int(result.get("saved_games", 0)))
	model_verification_cached = bool(result.get("model_verification_cached", false))
	last_error = _bounded_text(result.get("error", ""), 1024)
	_set_progress(clampi(int(result.get("progress", 0)), 0, 100), _bounded_text(result.get("phase", "initializing"), 200))

	var backend_ready := bool(result.get("ok", false)) and schema_ok and local_only and cpu_only and model_ready and sample_ready and history_ready
	if backend_ready:
		_set_ready(true, "Gemma chess agent ready on CPU · authenticated loopback")
		_set_status("busy" if generation_busy else "ready", activity)
	elif not schema_ok:
		last_error = "Unexpected backend schema."
		_set_ready(false, last_error)
		_set_status("failed", last_error)
	elif not local_only or not cpu_only:
		last_error = "Backend security policy check failed: loopback and CPU-only inference are required."
		_set_ready(false, last_error)
		_set_status("failed", last_error)
	elif not last_error.is_empty():
		_set_ready(false, last_error)
		_set_status("failed", initialization_phase)
	else:
		_set_ready(false, "%d%% · %s" % [initialization_progress, initialization_phase])
		_set_status("initializing", initialization_phase)
	_emit_snapshot()


func _post_health(payload: Dictionary) -> Dictionary:
	if _health_in_flight:
		return {"ok": false, "transport_ok": false, "code": "health_request_busy"}
	_health_in_flight = true
	var result: Dictionary = await _post("/health", payload, _health_http, true)
	_health_in_flight = false
	return result


func _post_request(path: String, payload: Dictionary) -> Dictionary:
	if _request_in_flight:
		return {"ok": false, "transport_ok": false, "code": "inference_request_busy", "error": "A local model request is already running."}
	_request_in_flight = true
	var result: Dictionary = await _post(path, payload, _request_http, false)
	_request_in_flight = false
	return result


func _post(path: String, payload: Dictionary, request: HTTPRequest, health_lane: bool) -> Dictionary:
	if not ALLOWED_ROUTES.has(path):
		return {"ok": false, "transport_ok": false, "code": "route_rejected"}
	if _bearer_token.is_empty() or not _owned_process_is_running():
		return {"ok": false, "transport_ok": false, "code": "backend_not_running"}
	if request == null or not is_instance_valid(request):
		return {"ok": false, "transport_ok": false, "code": "request_lane_unavailable"}

	var body := JSON.stringify(payload)
	if body.to_utf8_buffer().size() > MAX_REQUEST_BYTES:
		return {"ok": false, "transport_ok": false, "code": "request_too_large", "error": "The request exceeds 64 KiB."}

	request.timeout = HEALTH_TIMEOUT_SECONDS if health_lane else INFERENCE_TIMEOUT_SECONDS
	var start_error := request.request(
		endpoint + path,
		[
			"Authorization: Bearer " + _bearer_token,
			"Content-Type: application/json",
			"Accept: application/json",
			"Cache-Control: no-store",
		],
		HTTPClient.METHOD_POST,
		body
	)
	if start_error != OK:
		return {
			"ok": false,
			"transport_ok": false,
			"code": "request_start_failed",
			"error_code": start_error,
		}

	var completed: Array = await request.request_completed
	if completed.size() < 4:
		return {"ok": false, "transport_ok": false, "code": "request_completion_invalid"}
	var result_code := int(completed[0])
	var http_code := int(completed[1])
	var raw := completed[3] as PackedByteArray
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return {
			"ok": false,
			"transport_ok": false,
			"code": "backend_unavailable",
			"result": result_code,
			"http_code": http_code,
		}
	if raw.size() > MAX_RESPONSE_BYTES:
		return {"ok": false, "transport_ok": false, "code": "response_too_large", "http_code": http_code}
	var parsed = JSON.parse_string(raw.get_string_from_utf8())
	if not parsed is Dictionary:
		return {"ok": false, "transport_ok": false, "code": "response_invalid_json", "http_code": http_code}
	var response: Dictionary = parsed
	response["transport_ok"] = true
	response["http_code"] = http_code
	return response


func _make_http_request(timeout_seconds: float) -> HTTPRequest:
	var request := HTTPRequest.new()
	request.timeout = timeout_seconds
	request.max_redirects = 0
	request.body_size_limit = MAX_RESPONSE_BYTES
	add_child(request)
	return request


func _resolve_backend_executable() -> String:
	var executable_dir := OS.get_executable_path().get_base_dir()
	var candidates: Array[String] = []
	match OS.get_name():
		"Windows":
			candidates.append(executable_dir.path_join("backend/nexus_chess_llm.exe"))
		"macOS":
			candidates.append(executable_dir.get_base_dir().path_join("Helpers/NexusChessBackend.app/Contents/MacOS/nexus_chess_llm"))
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			candidates.append(executable_dir.path_join("backend/nexus_chess_llm"))
	for project_candidate in [RELEASE_EXECUTABLE, DEBUG_EXECUTABLE]:
		candidates.append(ProjectSettings.globalize_path(project_candidate))
	for absolute in candidates:
		if FileAccess.file_exists(absolute):
			return absolute
	return ""


func _resolve_model_path(requested_model_path: String) -> String:
	var candidate := requested_model_path.strip_edges()
	if candidate.is_empty():
		candidate = configured_model_path.strip_edges()
	if candidate.is_empty():
		var bundled := ProjectSettings.globalize_path(DEFAULT_MODEL_PATH)
		if FileAccess.file_exists(bundled):
			return bundled
		return ""
	return _resolve_local_path(candidate)


func _resolve_local_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return path.simplify_path()


func _validate_model_path(path: String) -> String:
	if path.is_empty():
		return ""
	if "\u0000" in path:
		return "The local model path is invalid."
	if not path.to_lower().ends_with(".litertlm"):
		return "The local model must be a .litertlm file."
	if not path.is_absolute_path():
		return "The local model path must resolve to an absolute path."
	if not FileAccess.file_exists(path):
		return "The pinned local model file was not found at %s." % path
	return ""


func _generate_bearer_token() -> String:
	var random_bytes := Crypto.new().generate_random_bytes(TOKEN_BYTES)
	if random_bytes.size() != TOKEN_BYTES:
		return ""
	return random_bytes.hex_encode()


func _apply_child_environment(values: Dictionary) -> Dictionary:
	var previous := {}
	for key in values:
		var name := str(key)
		previous[name] = {
			"present": OS.has_environment(name),
			"value": OS.get_environment(name),
		}
		OS.set_environment(name, str(values[key]))
	return previous


func _restore_environment(previous: Dictionary) -> void:
	for key in previous:
		var entry: Dictionary = previous[key]
		if bool(entry.get("present", false)):
			OS.set_environment(str(key), str(entry.get("value", "")))
		else:
			OS.unset_environment(str(key))


func _owned_process_is_running() -> bool:
	return _owned_pid > 0 and OS.is_process_running(_owned_pid)


func _kill_owned_process() -> Error:
	var owned := _owned_pid
	_owned_pid = -1
	pid = -1
	if owned <= 0 or not OS.is_process_running(owned):
		return OK
	return OS.kill(owned)


func _cancel_requests() -> void:
	if _health_http != null and is_instance_valid(_health_http):
		_health_http.cancel_request()
	if _request_http != null and is_instance_valid(_request_http):
		_request_http.cancel_request()
	_probe_in_flight = false
	_health_in_flight = false
	_request_in_flight = false


func _reset_runtime_fields() -> void:
	model_ready = false
	sample_ready = false
	sample_reply = ""
	model_source = ""
	generation_busy = false
	history_ready = false
	history_entries = 0
	saved_games = 0
	model_verification_cached = false
	activity = "initializing"
	last_error = ""
	initialization_progress = 0
	initialization_phase = "starting"
	_set_ready(false, "waiting for the local chess model")


func _fail_start(code: String, detail: String) -> Dictionary:
	last_error = detail
	_set_ready(false, detail)
	_set_status("failed", detail)
	_emit_snapshot()
	return _operation_result(false, code, detail)


func _set_progress(value: int, phase: String) -> void:
	var safe_value := clampi(value, 0, 100)
	var safe_phase := _bounded_text(phase, 200)
	if initialization_progress == safe_value and initialization_phase == safe_phase:
		return
	initialization_progress = safe_value
	initialization_phase = safe_phase
	progress_changed.emit(initialization_progress, initialization_phase)


func _set_ready(value: bool, detail: String) -> void:
	var safe_detail := _bounded_text(detail, 300)
	if is_ready == value and ready_detail == safe_detail:
		return
	is_ready = value
	ready_detail = safe_detail
	ready_changed.emit(is_ready, ready_detail)


func _set_status(value: String, detail: String) -> void:
	var safe_status := value.to_lower()
	var safe_detail := _bounded_text(detail, 300)
	if status == safe_status and status_detail == safe_detail:
		return
	status = safe_status
	status_detail = safe_detail
	status_changed.emit(status, safe_detail)


func _emit_snapshot() -> void:
	snapshot_changed.emit(get_snapshot())


func _operation_result(ok: bool, code: String, detail: String) -> Dictionary:
	var result := get_snapshot()
	result["ok"] = ok
	result["code"] = code
	result["operation_detail"] = detail
	return result


func _valid_port(value: int) -> bool:
	return value >= 1024 and value <= 65535


func _bounded_text(value: Variant, maximum: int) -> String:
	if value == null:
		return ""
	var text := str(value)
	if text.length() > maximum:
		return text.left(maximum)
	return text
