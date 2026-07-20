extends RefCounted
class_name FabricInitializationWorkflow

## Fail-closed startup composition for settings, IPFS/IPNS/libp2p, Hive, and Solana.
##
## This workflow never performs network I/O, cryptographic signing, wallet access,
## or chain submission. It only validates settings and assembles redacted local
## interface receipts and unsigned commitment drafts.

const FabricSettingsScript = preload("res://systems/components/fabric_network_settings.gd")
const IpfsCoordinatorScript = preload("res://systems/components/ipfs/ipfs_startup_coordinator.gd")
const HiveComponentScript = preload("res://systems/components/hive_commitment_component.gd")
const SolanaComponentScript = preload("res://systems/components/solana_checkpoint_component.gd")

const COMPONENT_ID := "nexus.fabric.initialization-workflow/v1"
const INTERFACE_MODE := "LOCAL_MULTI_CHAIN_INTERFACE_SIMULATION"
const SOLANA_PROGRAM_ID := "NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN"
const SOLANA_AUTHORITY_ID := "QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
const HIVE_AUTHORITY_ACCOUNT := "qseven-forge"

const CONTEXT_FIELDS := {
	"accepted_member_ids": true,
	"directory_commitment": true,
	"epoch": true,
	"ipns_name": true,
	"lobby_id": true,
	"local_member_id": true,
	"local_peer_id": true,
	"node_id": true,
	"public_directory_cid": true,
	"relay_peer_id": true,
	"rules_commitment": true,
	"shard_commitment": true,
	"signing_key_handle": true,
	"world_state_commitment": true,
}

const FORBIDDEN_FIELD_PARTS := [
	"private_key", "secret_key", "seed_phrase", "mnemonic", "wallet_key",
	"raw_ip", "ip_address", "socket_address", "message_body", "direct_message",
	"friend_list", "peer_list", "rpc_url", "rpc_endpoint",
]

enum State {
	IDLE,
	SETTINGS_VERIFIED,
	COMPONENTS_READY,
	FAILED,
}

var state: int = State.IDLE
var _settings_model: RefCounted
var _ipfs: RefCounted
var _hive: RefCounted
var _solana: RefCounted
var _receipts: Array[Dictionary] = []
var _public_snapshot: Dictionary = {}
var _failure_stage := ""


func start(
	settings_profile: Dictionary,
	context: Dictionary,
	now_unix: int,
	runtime_capabilities: Dictionary = {}
) -> Dictionary:
	if state != State.IDLE:
		return _failure("workflow_already_started", "workflow")
	_settings_model = FabricSettingsScript.new()
	var plan: Dictionary = _settings_model.build_initialization_plan(
		settings_profile,
		runtime_capabilities
	)
	if not plan.get("ready_for_initialization", false):
		state = State.FAILED
		return _failure(
			"settings_preflight_blocked:" + ",".join(plan.get("blockers", [])),
			"settings"
		)
	_receipts.append(Dictionary(plan.get("settings_gate_receipt", {})).duplicate(true))
	state = State.SETTINGS_VERIFIED

	var context_result := _validate_context(context)
	if not context_result.get("ok", false):
		state = State.FAILED
		return _failure(String(context_result.get("reason", "invalid_context")), "context")
	var safe_context: Dictionary = context_result["context"]

	_ipfs = IpfsCoordinatorScript.new()
	var ipfs_result: Dictionary = _ipfs.initialize({
		"schema": IpfsCoordinatorScript.SETTINGS_SCHEMA,
		"node_id": safe_context["node_id"],
		"lobby_id": safe_context["lobby_id"],
		"accepted_member_ids": safe_context["accepted_member_ids"],
		"local_member_id": safe_context["local_member_id"],
		"local_peer_id": safe_context["local_peer_id"],
		"relay_peer_id": safe_context["relay_peer_id"],
		"epoch": safe_context["epoch"],
		"ipns_name": safe_context["ipns_name"],
		"signing_key_handle": safe_context["signing_key_handle"],
		"capabilities": ["catalog.read", "catalog.replicate", "lobby.presence"],
	}, now_unix)
	if not ipfs_result.get("ok", false):
		state = State.FAILED
		return _failure(String(ipfs_result.get("reason", "ipfs_failed")), "ipfs")
	_receipts.append(Dictionary(ipfs_result["receipt"]).duplicate(true))

	_hive = HiveComponentScript.new()
	var hive_init: Dictionary = _hive.initialize({
		"network_label": "hive-interface",
		"custom_json_id": "nexus.shard.commitment.v1",
		"authority_policy": {HIVE_AUTHORITY_ACCOUNT: ["posting"]},
	})
	if not hive_init.get("ok", false):
		state = State.FAILED
		return _failure(String(hive_init.get("error", "hive_initialize_failed")), "hive_initialize")
	_receipts.append(Dictionary(hive_init["receipt"]).duplicate(true))
	var hive_draft: Dictionary = _hive.prepare_commitment({
		"record_id": "rec_" + _digest(String(safe_context["node_id"]) + "|hive|1").substr(0, 32),
		"record_kind": "shard_directory_commitment",
		"directory_cid": safe_context["public_directory_cid"],
		"content_commitment": safe_context["directory_commitment"],
		"sequence": 1,
		"epoch": safe_context["epoch"],
		"timestamp_bucket": maxi(0, now_unix / 300),
		"visibility": "commitment_only",
	}, {
		"account": HIVE_AUTHORITY_ACCOUNT,
		"permission": "posting",
		"nonce": 1,
	})
	if not hive_draft.get("ok", false):
		state = State.FAILED
		return _failure(String(hive_draft.get("error", "hive_draft_failed")), "hive_commitment")
	_receipts.append(_redact_chain_receipt(
		HiveComponentScript.COMPONENT_ID,
		Dictionary(hive_draft["receipt"]),
		String(hive_draft.get("operation_commitment", ""))
	))

	_solana = SolanaComponentScript.new()
	var solana_init: Dictionary = _solana.initialize({
		"network_label": "solana-interface",
		"program_id": SOLANA_PROGRAM_ID,
		"authority_policy": {SOLANA_AUTHORITY_ID: ["checkpoint_writer"]},
	})
	if not solana_init.get("ok", false):
		state = State.FAILED
		return _failure(String(solana_init.get("error", "solana_initialize_failed")), "solana_initialize")
	_receipts.append(Dictionary(solana_init["receipt"]).duplicate(true))
	var solana_draft: Dictionary = _solana.prepare_commitment({
		"shard_commitment": safe_context["shard_commitment"],
		"directory_commitment": safe_context["directory_commitment"],
		"rules_commitment": safe_context["rules_commitment"],
		"world_state_commitment": safe_context["world_state_commitment"],
		"revision": 1,
		"epoch": safe_context["epoch"],
		"visibility": "commitment_only",
	}, {
		"public_key": SOLANA_AUTHORITY_ID,
		"capability": "checkpoint_writer",
		"nonce": 1,
	})
	if not solana_draft.get("ok", false):
		state = State.FAILED
		return _failure(String(solana_draft.get("error", "solana_draft_failed")), "solana_checkpoint")
	_receipts.append(_redact_chain_receipt(
		SolanaComponentScript.COMPONENT_ID,
		Dictionary(solana_draft["receipt"]),
		String(solana_draft.get("instruction_commitment", ""))
	))

	state = State.COMPONENTS_READY
	var ipfs_pointer: Dictionary = _ipfs.get_public_pointer()
	_public_snapshot = {
		"component_id": COMPONENT_ID,
		"interface_mode": INTERFACE_MODE,
		"state": "components_ready",
		"settings_profile": String(settings_profile.get("profile", "unknown")),
		"receipt_count": _receipts.size(),
		"receipts": _receipts.duplicate(true),
		"pointers": {
			"ipfs_cid_preview": String(ipfs_pointer.get("cid_preview", "")),
			"ipfs_cid_is_live": false,
			"ipns_published": false,
			"hive_operation_commitment": String(hive_draft.get("operation_commitment", "")),
			"hive_broadcast": false,
			"solana_instruction_commitment": String(solana_draft.get("instruction_commitment", "")),
			"solana_submitted": false,
		},
		"network_calls_performed": false,
		"signing_performed": false,
		"private_material_requested": false,
		"raw_network_coordinates_persisted": false,
	}
	return {"ok": true, "snapshot": _public_snapshot.duplicate(true)}


func get_public_snapshot() -> Dictionary:
	return _public_snapshot.duplicate(true)


func get_receipts() -> Array[Dictionary]:
	return _receipts.duplicate(true)


func get_state_name() -> String:
	match state:
		State.IDLE:
			return "idle"
		State.SETTINGS_VERIFIED:
			return "settings_verified"
		State.COMPONENTS_READY:
			return "components_ready"
		State.FAILED:
			return "failed"
	return "unknown"


func _validate_context(context: Dictionary) -> Dictionary:
	for key_value in context.keys():
		var key := String(key_value)
		if not CONTEXT_FIELDS.has(key):
			return {"ok": false, "reason": "unsupported_context_field_" + key}
	for key in CONTEXT_FIELDS.keys():
		if not context.has(key):
			return {"ok": false, "reason": "missing_context_field_" + String(key)}
	var unsafe_reason := _unsafe_reason(context, "context")
	if not unsafe_reason.is_empty():
		return {"ok": false, "reason": unsafe_reason}
	if not context["accepted_member_ids"] is Array or context["accepted_member_ids"].is_empty():
		return {"ok": false, "reason": "accepted_members_required"}
	for field in ["directory_commitment", "rules_commitment", "shard_commitment", "world_state_commitment"]:
		if not _valid_sha256_commitment(String(context[field])):
			return {"ok": false, "reason": "invalid_" + field}
	if int(context["epoch"]) < 1:
		return {"ok": false, "reason": "invalid_epoch"}
	return {"ok": true, "context": context.duplicate(true)}


func _redact_chain_receipt(component_id: String, receipt: Dictionary, draft_commitment: String) -> Dictionary:
	return {
		"component_id": component_id,
		"interface_mode": String(receipt.get("interface_mode", "INTERFACE_SIMULATION_ONLY")),
		"status": String(receipt.get("status", "unsigned_interface_built")),
		"draft_commitment": draft_commitment,
		"signing_performed": false,
		"broadcast_performed": false,
		"live_rpc_used": false,
		"private_material_requested": false,
	}


func _unsafe_reason(value: Variant, path: String) -> String:
	if value is Dictionary:
		for key_value in value.keys():
			var key := String(key_value).to_lower()
			for forbidden in FORBIDDEN_FIELD_PARTS:
				if key.contains(String(forbidden)):
					return "forbidden_field_" + path + "." + key
			var child_reason := _unsafe_reason(value[key_value], path + "." + key)
			if not child_reason.is_empty():
				return child_reason
	elif value is Array:
		for index in range(value.size()):
			var child_reason := _unsafe_reason(value[index], path + "[" + str(index) + "]")
			if not child_reason.is_empty():
				return child_reason
	elif value is String:
		var text := String(value)
		if _contains_ip_literal(text):
			return "raw_ip_literal_rejected_" + path
		var lowered := text.to_lower()
		if "-----begin" in lowered or lowered.begins_with("xprv") or lowered.begins_with("sk-"):
			return "private_material_rejected_" + path
	return ""


func _contains_ip_literal(value: String) -> bool:
	var ipv4 := RegEx.new()
	ipv4.compile("(^|[^0-9])([0-9]{1,3}\\.){3}[0-9]{1,3}([^0-9]|$)")
	if ipv4.search(value) != null:
		return true
	var ipv6 := RegEx.new()
	ipv6.compile("(^|[^A-Fa-f0-9])([A-Fa-f0-9]{0,4}:){2,7}[A-Fa-f0-9]{0,4}([^A-Fa-f0-9]|$)")
	return ipv6.search(value) != null


func _valid_sha256_commitment(value: String) -> bool:
	var expression := RegEx.new()
	expression.compile("^sha256:[0-9a-f]{64}$")
	return expression.search(value) != null


func _digest(value: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(value.to_utf8_buffer())
	return context.finish().hex_encode()


func _failure(reason: String, stage: String) -> Dictionary:
	_failure_stage = stage
	return {
		"ok": false,
		"reason": reason,
		"stage": stage,
		"component_id": COMPONENT_ID,
		"network_calls_performed": false,
		"private_material_requested": false,
	}
