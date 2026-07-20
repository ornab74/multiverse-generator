extends SceneTree

const BridgeScript = preload("res://systems/naza_dart_gemma_bridge.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var bridge: NazaDartGemmaBridge = BridgeScript.new()
	bridge.auto_start = false
	root.add_child(bridge)
	await process_frame

	var snapshot := bridge.get_snapshot()
	assert(snapshot.host == "127.0.0.1")
	assert(snapshot.port == 47621)
	assert(snapshot.status == "stopped")
	assert(not snapshot.ready and not snapshot.process_running)
	assert(not snapshot.has("token"))
	assert(not snapshot.has("bearer_token"))

	var token: String = bridge._generate_bearer_token()
	assert(token.length() == 64)
	assert(token.is_valid_hex_number(false))

	var invalid_port := bridge.configure(80)
	assert(not invalid_port.ok and invalid_port.code == "port_invalid")
	var model_path := ProjectSettings.globalize_path(
		"res://chess_llm_backend/models/gemma-4-E2B-it.litertlm"
	)
	var configured := bridge.configure(47621, model_path)
	assert(configured.ok and configured.host == "127.0.0.1")
	assert(bridge.endpoint == "http://127.0.0.1:47621")
	assert(bridge._resolve_backend_executable().ends_with("/release/bundle/nexus_chess_llm"))

	var stopped := bridge.stop_backend()
	assert(stopped.ok and bridge.pid == -1)
	bridge.queue_free()
	await process_frame
	print("NAZA_DART_GEMMA_BRIDGE_TEST: PASS")
	quit(0)
