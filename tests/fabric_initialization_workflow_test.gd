extends SceneTree

const WorkflowScript = preload("res://systems/fabric_initialization_workflow.gd")
const SettingsScript = preload("res://systems/components/fabric_network_settings.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var settings := SettingsScript.new().default_profile()
	var workflow = WorkflowScript.new()
	var result: Dictionary = workflow.start(settings, _safe_context(), 1_782_920_000)
	_expect(result.get("ok", false), "safe multi-component workflow failed: " + String(result.get("reason", "")))
	if result.get("ok", false):
		var snapshot: Dictionary = result["snapshot"]
		_expect(workflow.get_state_name() == "components_ready", "workflow did not reach components_ready")
		_expect(snapshot.get("receipt_count", 0) >= 6, "component receipts were incomplete")
		_expect(not snapshot.get("network_calls_performed", true), "workflow claimed a network call")
		_expect(not snapshot.get("signing_performed", true), "workflow claimed signing")
		_expect(not snapshot["pointers"].get("ipfs_cid_is_live", true), "IPFS preview was marked live")
		_expect(not snapshot["pointers"].get("ipns_published", true), "IPNS record was marked published")
		_expect(not snapshot["pointers"].get("hive_broadcast", true), "Hive operation was marked broadcast")
		_expect(not snapshot["pointers"].get("solana_submitted", true), "Solana instruction was marked submitted")
		var serialized := JSON.stringify(snapshot)
		for secret_value in [
			"node-q7-primary", "lobby-violet", "member-q7", "member-vx",
			"12D3KooWLocalOmega", "12D3KooWRelayAlpha", "kh_ipns_device_primary",
			WorkflowScript.HIVE_AUTHORITY_ACCOUNT, WorkflowScript.SOLANA_AUTHORITY_ID,
		]:
			_expect(secret_value not in serialized, "public workflow snapshot leaked: " + secret_value)
	var repeated := workflow.start(settings, _safe_context(), 1_782_920_001)
	_expect(not repeated.get("ok", true), "workflow accepted a second start")

	var unsafe_context := _safe_context()
	unsafe_context["relay_peer_id"] = "10.2.3.4"
	var unsafe := WorkflowScript.new().start(settings, unsafe_context, 1_782_920_000)
	_expect(not unsafe.get("ok", true), "raw IP context entered component initialization")
	_expect(String(unsafe.get("stage", "")) == "context", "unsafe context failed after a component started")

	var local_profile := SettingsScript.new().profile_settings("local")
	var blocked := WorkflowScript.new().start(local_profile, _safe_context(), 1_782_920_000)
	_expect(not blocked.get("ok", true), "local profile initialized without runtime capabilities")
	_expect(String(blocked.get("stage", "")) == "settings", "blocked settings did not stop at gate zero")

	if failures.is_empty():
		print("FABRIC_INITIALIZATION_WORKFLOW_TEST: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("FABRIC_INITIALIZATION_WORKFLOW_TEST: " + failure)
		quit(1)


func _safe_context() -> Dictionary:
	return {
		"accepted_member_ids": ["member-q7", "member-vx"],
		"directory_commitment": _commit("directory"),
		"epoch": 41,
		"ipns_name": "k51qzi5uqu5dabcdef1234567890",
		"lobby_id": "lobby-violet",
		"local_member_id": "member-q7",
		"local_peer_id": "12D3KooWLocalOmega",
		"node_id": "node-q7-primary",
		"public_directory_cid": "bafy" + _digest("directory-cid").substr(0, 52),
		"relay_peer_id": "12D3KooWRelayAlpha",
		"rules_commitment": _commit("rules"),
		"shard_commitment": _commit("shard"),
		"signing_key_handle": "kh_ipns_device_primary",
		"world_state_commitment": _commit("world-state"),
	}


func _commit(value: String) -> String:
	return "sha256:" + _digest(value)


func _digest(value: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(value.to_utf8_buffer())
	return context.finish().hex_encode()


func _expect(condition: bool, failure: String) -> void:
	if not condition:
		failures.append(failure)
