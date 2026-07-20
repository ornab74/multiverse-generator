extends RefCounted
class_name SolanaCheckpointComponent

## A production-shaped Solana checkpoint boundary that is intentionally offline.
##
## PDA addresses in this component are deterministic interface placeholders. They
## are not curve-checked Solana addresses. Instructions are never signed, assigned
## a recent blockhash, sent to RPC, or accepted with private key material.

const INTERFACE_MODE := "INTERFACE_SIMULATION_ONLY"
const COMPONENT_ID := "nexus.solana.pda_checkpoint"
const SCHEMA_VERSION := "nexus.solana-checkpoint/1"
const SYSTEM_PROGRAM_ID := "11111111111111111111111111111111"
const PDA_SEED_PREFIX := "nexus_checkpoint_v1"

const CONFIG_FIELDS := {
	"network_label": true,
	"program_id": true,
	"authority_policy": true,
}

const AUTHORITY_FIELDS := {
	"public_key": true,
	"capability": true,
	"nonce": true,
}

const CHECKPOINT_FIELDS := {
	"shard_commitment": true,
	"directory_commitment": true,
	"rules_commitment": true,
	"world_state_commitment": true,
	"revision": true,
	"epoch": true,
	"previous_checkpoint_commitment": true,
	"visibility": true,
}

const INSTRUCTION_FIELDS := {
	"program_id": true,
	"accounts": true,
	"data": true,
}

const DATA_FIELDS := {
	"schema": true,
	"interface_mode": true,
	"network_label": true,
	"instruction": true,
	"nonce": true,
	"authority_capability": true,
	"checkpoint": true,
	"checkpoint_commitment": true,
}

const ACCOUNT_META_FIELDS := {
	"name": true,
	"pubkey": true,
	"is_signer": true,
	"is_writable": true,
}

const FORBIDDEN_FIELD_PARTS: Array[String] = [
	"private_key",
	"secret_key",
	"seed_phrase",
	"mnemonic",
	"signing_key",
	"rpc_url",
	"rpc_endpoint",
	"raw_ip",
	"ip_address",
	"socket_address",
	"friend",
	"member_list",
	"peer_list",
	"peer_id",
	"direct_message",
	"message_body",
	"presence",
	"email",
	"phone",
]

var _configured := false
var _network_label := ""
var _program_id := ""
var _authority_policy: Dictionary = {}

var _outbound_nonce_by_scope: Dictionary = {}
var _inbound_nonce_by_scope: Dictionary = {}
var _outbound_revision_by_pda: Dictionary = {}
var _inbound_revision_by_pda: Dictionary = {}
var _outbound_checkpoint_by_pda: Dictionary = {}
var _inbound_checkpoint_by_pda: Dictionary = {}
var _outbound_commitments: Dictionary = {}
var _inbound_commitments: Dictionary = {}


func initialize(config: Dictionary = {}) -> Dictionary:
	if _configured:
		return _failure("component_already_initialized")
	var unknown_field := _unknown_field(config, CONFIG_FIELDS)
	if not unknown_field.is_empty():
		return _failure("unsupported_config_field_" + unknown_field)
	var unsafe_reason := _unsafe_reason(config, "config")
	if not unsafe_reason.is_empty():
		return _failure(unsafe_reason)

	var network_label := String(config.get("network_label", "solana-interface"))
	var program_id := String(config.get("program_id", ""))
	var authority_value = config.get("authority_policy", {})
	if not _matches(network_label, "^[a-z0-9][a-z0-9_-]{1,47}$"):
		return _failure("invalid_network_label")
	if not _valid_public_key(program_id) or program_id == SYSTEM_PROGRAM_ID:
		return _failure("invalid_program_id")
	if not authority_value is Dictionary:
		return _failure("authority_policy_must_be_dictionary")
	var policy_result := _normalize_authority_policy(authority_value)
	if not policy_result.get("ok", false):
		return policy_result

	_network_label = network_label
	_program_id = program_id
	_authority_policy = policy_result["policy"]
	_configured = true
	var snapshot := get_public_snapshot()
	return {
		"ok": true,
		"snapshot": snapshot,
		"receipt": {
			"component_id": COMPONENT_ID,
			"interface_mode": INTERFACE_MODE,
			"status": "offline_simulation_ready",
			"configuration_commitment": "sha256:" + _digest(_canonical_json(snapshot)),
			"authority_count": _authority_policy.size(),
			"live_rpc_used": false,
			"signing_performed": false,
			"private_material_requested": false,
		},
	}


func get_public_snapshot() -> Dictionary:
	var redacted_policy: Dictionary = {}
	for public_key_value in _authority_policy.keys():
		var public_key := String(public_key_value)
		redacted_policy["authority_" + _digest(public_key).substr(0, 16)] = \
			Array(_authority_policy[public_key]).duplicate()
	return {
		"schema": SCHEMA_VERSION,
		"component_id": COMPONENT_ID,
		"interface_mode": INTERFACE_MODE,
		"configured": _configured,
		"network_label": _network_label,
		"program_commitment": "sha256:" + _digest(_program_id) if not _program_id.is_empty() else "",
		"authority_policy": redacted_policy,
		"pda_curve_check_available": false,
		"live_rpc_configured": false,
		"signing_available": false,
		"private_material_accepted": false,
	}


func get_component_id() -> String:
	return COMPONENT_ID


func validate_authority(authority: Dictionary) -> Dictionary:
	if not _configured:
		return _failure("component_not_initialized")
	return _validate_authority(authority)


func derive_checkpoint_pda(shard_commitment: String) -> Dictionary:
	if not _configured:
		return _failure("component_not_initialized")
	if not _valid_sha256_commitment(shard_commitment):
		return _failure("invalid_shard_commitment_seed")
	var derivation_digest := _digest(
		PDA_SEED_PREFIX + "|" + shard_commitment + "|" + _program_id
	)
	var digest_bytes := derivation_digest.to_utf8_buffer()
	var bump := 255 - (int(digest_bytes[0]) % 32)
	return {
		"ok": true,
		"component_id": COMPONENT_ID,
		"interface_mode": INTERFACE_MODE,
		"address": "pda_sim_" + derivation_digest.substr(0, 44),
		"bump": bump,
		"seed_manifest": [
			{
				"name": "namespace",
				"commitment": "sha256:" + _digest(PDA_SEED_PREFIX),
			},
			{
				"name": "shard",
				"commitment": shard_commitment,
			},
		],
		"curve_check_performed": false,
		"production_pda_derivation_required": true,
	}


func build_checkpoint_instruction(checkpoint: Dictionary, authority: Dictionary) -> Dictionary:
	if not _configured:
		return _failure("component_not_initialized")
	var checkpoint_result := _normalize_checkpoint(checkpoint)
	if not checkpoint_result.get("ok", false):
		return checkpoint_result
	var authority_result := _validate_authority(authority)
	if not authority_result.get("ok", false):
		return authority_result
	var normalized_checkpoint: Dictionary = checkpoint_result["checkpoint"]
	var normalized_authority: Dictionary = authority_result["authority"]
	var pda_result := derive_checkpoint_pda(String(normalized_checkpoint["shard_commitment"]))
	if not pda_result.get("ok", false):
		return pda_result
	var pda := String(pda_result["address"])
	var nonce := int(normalized_authority["nonce"])
	var nonce_scope := _nonce_scope(pda, normalized_authority)
	var nonce_error := _nonce_error(_outbound_nonce_by_scope, nonce_scope, nonce)
	if not nonce_error.is_empty():
		return _failure("outbound_" + nonce_error)
	var revision_error := _revision_error(
		_outbound_revision_by_pda,
		_outbound_checkpoint_by_pda,
		pda,
		normalized_checkpoint
	)
	if not revision_error.is_empty():
		return _failure("outbound_" + revision_error)

	var instruction_data := {
		"schema": SCHEMA_VERSION,
		"interface_mode": INTERFACE_MODE,
		"network_label": _network_label,
		"instruction": "checkpoint",
		"nonce": nonce,
		"authority_capability": normalized_authority["capability"],
		"checkpoint": normalized_checkpoint,
	}
	var checkpoint_commitment := "sha256:" + _digest(_canonical_json(instruction_data))
	instruction_data["checkpoint_commitment"] = checkpoint_commitment
	var instruction := {
		"program_id": _program_id,
		"accounts": _expected_accounts(pda, String(normalized_authority["public_key"])),
		"data": instruction_data,
	}
	var instruction_commitment := "sha256:" + _digest(_canonical_json(instruction))
	if _outbound_commitments.has(checkpoint_commitment):
		return _failure("outbound_duplicate_checkpoint")

	_outbound_nonce_by_scope[nonce_scope] = nonce
	_outbound_revision_by_pda[pda] = int(normalized_checkpoint["revision"])
	_outbound_checkpoint_by_pda[pda] = checkpoint_commitment
	_outbound_commitments[checkpoint_commitment] = true
	return {
		"ok": true,
		"component_id": COMPONENT_ID,
		"interface_mode": INTERFACE_MODE,
		"instruction": instruction,
		"instruction_commitment": instruction_commitment,
		"checkpoint_commitment": checkpoint_commitment,
		"pda": pda_result,
		"transaction_draft": {
			"recent_blockhash": null,
			"instructions": [instruction],
			"signatures": [],
			"fee_payer": null,
		},
		"receipt": {
			"status": "unsigned_interface_built",
			"component_id": COMPONENT_ID,
			"checkpoint_commitment": checkpoint_commitment,
			"pda_commitment": "sha256:" + _digest(pda),
			"revision": normalized_checkpoint["revision"],
			"nonce": nonce,
			"signing_performed": false,
			"broadcast_performed": false,
			"live_rpc_used": false,
			"wallet_material_requested": false,
		},
	}


func prepare_commitment(checkpoint: Dictionary, authority: Dictionary) -> Dictionary:
	## Stable startup-facing alias. It only prepares an unsigned instruction draft.
	return build_checkpoint_instruction(checkpoint, authority)


func validate_accounts(instruction: Dictionary) -> Dictionary:
	if not _configured:
		return _failure("component_not_initialized")
	var shape_result := _validate_instruction_shape(instruction)
	if not shape_result.get("ok", false):
		return shape_result
	return {
		"ok": true,
		"component_id": COMPONENT_ID,
		"interface_mode": INTERFACE_MODE,
		"pda_commitment": "sha256:" + _digest(String(shape_result["pda"])),
		"authority_commitment": "sha256:" + _digest(String(shape_result["authority_public_key"])),
		"signer_flags_valid": true,
		"writable_flags_valid": true,
		"curve_check_performed": false,
	}


func validate_checkpoint_instruction(instruction: Dictionary, consume_nonce: bool = true) -> Dictionary:
	if not _configured:
		return _failure("component_not_initialized")
	var shape_result := _validate_instruction_shape(instruction)
	if not shape_result.get("ok", false):
		return shape_result
	var normalized_checkpoint: Dictionary = shape_result["checkpoint"]
	var nonce := int(shape_result["nonce"])
	var authority_result := _validate_authority({
		"public_key": shape_result["authority_public_key"],
		"capability": shape_result["authority_capability"],
		"nonce": nonce,
	})
	if not authority_result.get("ok", false):
		return authority_result
	var pda := String(shape_result["pda"])
	var nonce_scope := _nonce_scope(pda, authority_result["authority"])
	var nonce_error := _nonce_error(_inbound_nonce_by_scope, nonce_scope, nonce)
	if not nonce_error.is_empty():
		return _failure("inbound_" + nonce_error)
	var revision_error := _revision_error(
		_inbound_revision_by_pda,
		_inbound_checkpoint_by_pda,
		pda,
		normalized_checkpoint
	)
	if not revision_error.is_empty():
		return _failure("inbound_" + revision_error)
	var checkpoint_commitment := String(shape_result["checkpoint_commitment"])
	if _inbound_commitments.has(checkpoint_commitment):
		return _failure("inbound_duplicate_checkpoint")

	if consume_nonce:
		_inbound_nonce_by_scope[nonce_scope] = nonce
		_inbound_revision_by_pda[pda] = int(normalized_checkpoint["revision"])
		_inbound_checkpoint_by_pda[pda] = checkpoint_commitment
		_inbound_commitments[checkpoint_commitment] = true
	return {
		"ok": true,
		"component_id": COMPONENT_ID,
		"interface_mode": INTERFACE_MODE,
		"instruction_commitment": "sha256:" + _digest(_canonical_json(instruction)),
		"checkpoint_commitment": checkpoint_commitment,
		"nonce_consumed": consume_nonce,
		"signature_verified": false,
		"account_contract_validated": true,
		"authority_policy_validated": true,
	}


func get_replay_snapshot() -> Dictionary:
	return {
		"component_id": COMPONENT_ID,
		"interface_mode": INTERFACE_MODE,
		"outbound": _redacted_nonce_ledger(_outbound_nonce_by_scope),
		"inbound": _redacted_nonce_ledger(_inbound_nonce_by_scope),
		"outbound_checkpoint_count": _outbound_commitments.size(),
		"inbound_checkpoint_count": _inbound_commitments.size(),
	}


func _normalize_authority_policy(policy: Dictionary) -> Dictionary:
	if policy.is_empty():
		return _failure("authority_policy_required")
	var normalized: Dictionary = {}
	for public_key_value in policy.keys():
		var public_key := String(public_key_value)
		if not _valid_public_key(public_key) or public_key == SYSTEM_PROGRAM_ID:
			return _failure("invalid_authority_public_key")
		var capabilities_value = policy[public_key_value]
		if not capabilities_value is Array or capabilities_value.is_empty():
			return _failure("authority_capabilities_must_be_nonempty_array")
		var capabilities: Array[String] = []
		for capability_value in capabilities_value:
			var capability := String(capability_value)
			if capability not in ["checkpoint_writer", "checkpoint_admin"]:
				return _failure("unsupported_checkpoint_capability")
			if capability not in capabilities:
				capabilities.append(capability)
		capabilities.sort()
		normalized[public_key] = capabilities
	return {"ok": true, "policy": normalized}


func _validate_authority(authority: Dictionary) -> Dictionary:
	var unknown_field := _unknown_field(authority, AUTHORITY_FIELDS)
	if not unknown_field.is_empty():
		return _failure("unsupported_authority_field_" + unknown_field)
	for required_field in AUTHORITY_FIELDS.keys():
		if not authority.has(required_field):
			return _failure("missing_authority_field_" + String(required_field))
	var unsafe_reason := _unsafe_reason(authority, "authority")
	if not unsafe_reason.is_empty():
		return _failure(unsafe_reason)
	var public_key := String(authority.get("public_key", ""))
	var capability := String(authority.get("capability", ""))
	var nonce_result := _positive_integer(authority.get("nonce", null), "authority_nonce")
	if not nonce_result.get("ok", false):
		return nonce_result
	if not _authority_policy.has(public_key):
		return _failure("authority_public_key_not_allowed")
	if capability not in _authority_policy[public_key]:
		return _failure("authority_capability_not_allowed")
	return {"ok": true, "authority": {
		"public_key": public_key,
		"capability": capability,
		"nonce": nonce_result["value"],
	}}


func _normalize_checkpoint(checkpoint: Dictionary) -> Dictionary:
	var unknown_field := _unknown_field(checkpoint, CHECKPOINT_FIELDS)
	if not unknown_field.is_empty():
		return _failure("unsupported_checkpoint_field_" + unknown_field)
	for required_field in ["shard_commitment", "directory_commitment", "rules_commitment", "revision"]:
		if not checkpoint.has(required_field):
			return _failure("missing_checkpoint_field_" + required_field)
	var unsafe_reason := _unsafe_reason(checkpoint, "checkpoint")
	if not unsafe_reason.is_empty():
		return _failure(unsafe_reason)
	var normalized: Dictionary = {}
	for commitment_field in ["shard_commitment", "directory_commitment", "rules_commitment"]:
		var commitment := String(checkpoint[commitment_field])
		if not _valid_sha256_commitment(commitment):
			return _failure("invalid_" + commitment_field)
		normalized[commitment_field] = commitment
	if checkpoint.has("world_state_commitment"):
		var world_state_commitment := String(checkpoint["world_state_commitment"])
		if not _valid_sha256_commitment(world_state_commitment):
			return _failure("invalid_world_state_commitment")
		normalized["world_state_commitment"] = world_state_commitment
	var revision_result := _positive_integer(checkpoint.get("revision", null), "revision")
	if not revision_result.get("ok", false):
		return revision_result
	normalized["revision"] = revision_result["value"]
	if checkpoint.has("epoch"):
		var epoch_result := _positive_integer(checkpoint["epoch"], "epoch")
		if not epoch_result.get("ok", false):
			return epoch_result
		normalized["epoch"] = epoch_result["value"]
	var previous := String(checkpoint.get("previous_checkpoint_commitment", ""))
	if not previous.is_empty() and not _valid_sha256_commitment(previous):
		return _failure("invalid_previous_checkpoint_commitment")
	if not previous.is_empty():
		normalized["previous_checkpoint_commitment"] = previous
	var visibility := String(checkpoint.get("visibility", "commitment_only"))
	if visibility not in ["public", "commitment_only"]:
		return _failure("unsupported_checkpoint_visibility")
	normalized["visibility"] = visibility
	return {"ok": true, "checkpoint": normalized}


func _validate_instruction_shape(instruction: Dictionary) -> Dictionary:
	var unknown_field := _unknown_field(instruction, INSTRUCTION_FIELDS)
	if not unknown_field.is_empty():
		return _failure("unsupported_instruction_field_" + unknown_field)
	for required_field in INSTRUCTION_FIELDS.keys():
		if not instruction.has(required_field):
			return _failure("missing_instruction_field_" + String(required_field))
	if String(instruction.get("program_id", "")) != _program_id:
		return _failure("instruction_program_id_mismatch")
	if not instruction.get("accounts") is Array or not instruction.get("data") is Dictionary:
		return _failure("instruction_accounts_or_data_shape_invalid")
	var data: Dictionary = instruction["data"]
	var data_unknown := _unknown_field(data, DATA_FIELDS)
	if not data_unknown.is_empty():
		return _failure("unsupported_instruction_data_field_" + data_unknown)
	for required_field in DATA_FIELDS.keys():
		if not data.has(required_field):
			return _failure("missing_instruction_data_field_" + String(required_field))
	if String(data.get("schema", "")) != SCHEMA_VERSION:
		return _failure("instruction_schema_mismatch")
	if String(data.get("interface_mode", "")) != INTERFACE_MODE:
		return _failure("unlabeled_or_live_instruction_rejected")
	if String(data.get("network_label", "")) != _network_label:
		return _failure("instruction_network_mismatch")
	if String(data.get("instruction", "")) != "checkpoint":
		return _failure("unsupported_instruction_command")
	if not data.get("checkpoint") is Dictionary:
		return _failure("checkpoint_data_must_be_object")
	var checkpoint_result := _normalize_checkpoint(data["checkpoint"])
	if not checkpoint_result.get("ok", false):
		return checkpoint_result
	var nonce_result := _positive_integer(data.get("nonce", null), "instruction_nonce")
	if not nonce_result.get("ok", false):
		return nonce_result

	var normalized_data := {
		"schema": SCHEMA_VERSION,
		"interface_mode": INTERFACE_MODE,
		"network_label": _network_label,
		"instruction": "checkpoint",
		"nonce": nonce_result["value"],
		"authority_capability": String(data.get("authority_capability", "")),
		"checkpoint": checkpoint_result["checkpoint"],
	}
	var expected_checkpoint_commitment := "sha256:" + _digest(_canonical_json(normalized_data))
	if String(data.get("checkpoint_commitment", "")) != expected_checkpoint_commitment:
		return _failure("checkpoint_commitment_mismatch")
	var pda_result := derive_checkpoint_pda(String(checkpoint_result["checkpoint"]["shard_commitment"]))
	if not pda_result.get("ok", false):
		return pda_result
	var accounts_result := _validate_account_metas(
		instruction["accounts"],
		String(pda_result["address"])
	)
	if not accounts_result.get("ok", false):
		return accounts_result
	return {
		"ok": true,
		"checkpoint": checkpoint_result["checkpoint"],
		"checkpoint_commitment": expected_checkpoint_commitment,
		"pda": pda_result["address"],
		"authority_public_key": accounts_result["authority_public_key"],
		"authority_capability": normalized_data["authority_capability"],
		"nonce": nonce_result["value"],
	}


func _validate_account_metas(accounts: Array, expected_pda: String) -> Dictionary:
	if accounts.size() != 3:
		return _failure("checkpoint_instruction_requires_three_accounts")
	for candidate in accounts:
		if not candidate is Dictionary:
			return _failure("account_meta_must_be_object")
		var unknown_field := _unknown_field(candidate, ACCOUNT_META_FIELDS)
		if not unknown_field.is_empty():
			return _failure("unsupported_account_meta_field_" + unknown_field)
		for required_field in ACCOUNT_META_FIELDS.keys():
			if not candidate.has(required_field):
				return _failure("missing_account_meta_field_" + String(required_field))
	var checkpoint_meta: Dictionary = accounts[0]
	var authority_meta: Dictionary = accounts[1]
	var system_meta: Dictionary = accounts[2]
	if checkpoint_meta != {
		"name": "checkpoint",
		"pubkey": expected_pda,
		"is_signer": false,
		"is_writable": true,
	}:
		return _failure("checkpoint_account_contract_mismatch")
	var authority_public_key := String(authority_meta.get("pubkey", ""))
	if String(authority_meta.get("name", "")) != "authority" \
		or not bool(authority_meta.get("is_signer", false)) \
		or bool(authority_meta.get("is_writable", true)) \
		or not _valid_public_key(authority_public_key):
		return _failure("authority_account_contract_mismatch")
	if system_meta != {
		"name": "system_program",
		"pubkey": SYSTEM_PROGRAM_ID,
		"is_signer": false,
		"is_writable": false,
	}:
		return _failure("system_program_account_contract_mismatch")
	return {"ok": true, "authority_public_key": authority_public_key}


func _expected_accounts(pda: String, authority_public_key: String) -> Array[Dictionary]:
	return [
		{
			"name": "checkpoint",
			"pubkey": pda,
			"is_signer": false,
			"is_writable": true,
		},
		{
			"name": "authority",
			"pubkey": authority_public_key,
			"is_signer": true,
			"is_writable": false,
		},
		{
			"name": "system_program",
			"pubkey": SYSTEM_PROGRAM_ID,
			"is_signer": false,
			"is_writable": false,
		},
	]


func _revision_error(
	revision_ledger: Dictionary,
	checkpoint_ledger: Dictionary,
	pda: String,
	checkpoint: Dictionary
) -> String:
	var last_revision := int(revision_ledger.get(pda, 0))
	var revision := int(checkpoint["revision"])
	var expected_revision := last_revision + 1
	if revision < expected_revision:
		return "revision_replay"
	if revision > expected_revision:
		return "revision_gap"
	var previous := String(checkpoint.get("previous_checkpoint_commitment", ""))
	if expected_revision == 1 and not previous.is_empty():
		return "unexpected_genesis_previous_checkpoint"
	if expected_revision > 1 and previous != String(checkpoint_ledger.get(pda, "")):
		return "previous_checkpoint_mismatch"
	return ""


func _nonce_scope(pda: String, authority: Dictionary) -> String:
	return _network_label + "|" + pda + "|" \
		+ String(authority["public_key"]) + "|" + String(authority["capability"])


func _nonce_error(ledger: Dictionary, scope: String, nonce: int) -> String:
	var expected := int(ledger.get(scope, 0)) + 1
	if nonce < expected:
		return "nonce_replay"
	if nonce > expected:
		return "nonce_gap"
	return ""


func _redacted_nonce_ledger(ledger: Dictionary) -> Dictionary:
	var output: Dictionary = {}
	for scope_value in ledger.keys():
		var scope := String(scope_value)
		output["scope_" + _digest(scope).substr(0, 16)] = int(ledger[scope_value])
	return output


func _unknown_field(value: Dictionary, allowed: Dictionary) -> String:
	for key_value in value.keys():
		var key := String(key_value)
		if not allowed.has(key):
			return key
	return ""


func _unsafe_reason(value: Variant, path: String) -> String:
	if _contains_ip_literal(value):
		return "raw_ip_literal_rejected_at_" + path
	if value is String and _looks_like_private_material(String(value)):
		return "private_material_pattern_rejected_at_" + path
	if value is Dictionary:
		for key_value in value.keys():
			var key := String(key_value).to_lower()
			for forbidden in FORBIDDEN_FIELD_PARTS:
				if forbidden in key:
					return "forbidden_sensitive_field_" + key + "_at_" + path
			var child_reason := _unsafe_reason(value[key_value], path + "." + key)
			if not child_reason.is_empty():
				return child_reason
	elif value is Array:
		for index in value.size():
			var item_reason := _unsafe_reason(value[index], path + "[" + str(index) + "]")
			if not item_reason.is_empty():
				return item_reason
	elif value != null and not value is String and not value is bool and not value is int and not value is float:
		return "unsupported_non_json_value_at_" + path
	return ""


func _looks_like_private_material(value: String) -> bool:
	if "BEGIN PRIVATE KEY" in value or "BEGIN EC PRIVATE KEY" in value:
		return true
	if value.begins_with("PVT_") or value.begins_with("sk-"):
		return true
	# Common 64-byte Solana secret-key arrays never fit this component's strict
	# schemas. This catches an additional base58-encoded secret-shaped value.
	return _matches(value, "^[1-9A-HJ-NP-Za-km-z]{80,100}$")


func _contains_ip_literal(value: Variant) -> bool:
	var serialized := String(value) if value is String else JSON.stringify(value)
	var ipv4 := RegEx.new()
	ipv4.compile("(^|[^0-9])([0-9]{1,3}\\.){3}[0-9]{1,3}([^0-9]|$)")
	if ipv4.search(serialized) != null:
		return true
	var ipv6 := RegEx.new()
	ipv6.compile("(?i)([0-9a-f]{1,4}:){2,}[0-9a-f]{0,4}")
	return ipv6.search(serialized) != null


func _positive_integer(value: Variant, label: String) -> Dictionary:
	if not value is int and not value is float:
		return _failure(label + "_must_be_integer")
	var integer := int(value)
	if float(value) != float(integer) or integer < 1:
		return _failure(label + "_must_be_positive_integer")
	return {"ok": true, "value": integer}


func _valid_public_key(value: String) -> bool:
	return _matches(value, "^[1-9A-HJ-NP-Za-km-z]{32,44}$")


func _valid_sha256_commitment(value: String) -> bool:
	return _matches(value, "^sha256:[0-9a-f]{64}$")


func _matches(value: String, expression: String) -> bool:
	var regex := RegEx.new()
	if regex.compile(expression) != OK:
		return false
	var match_result := regex.search(value)
	return match_result != null and match_result.get_string() == value


func _canonical_json(value: Variant) -> String:
	return JSON.stringify(_canonicalize(value))


func _canonicalize(value: Variant) -> Variant:
	if value is Dictionary:
		var output: Dictionary = {}
		var keys: Array = value.keys()
		keys.sort_custom(func(left: Variant, right: Variant) -> bool:
			return String(left) < String(right)
		)
		for key_value in keys:
			output[String(key_value)] = _canonicalize(value[key_value])
		return output
	if value is Array:
		var output_array: Array = []
		for item in value:
			output_array.append(_canonicalize(item))
		return output_array
	return value


func _digest(value: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	var bytes := value.to_utf8_buffer()
	if bytes.is_empty():
		bytes = PackedByteArray([0])
	context.update(bytes)
	return context.finish().hex_encode()


func _failure(reason: String) -> Dictionary:
	return {
		"ok": false,
		"error": reason,
		"component_id": COMPONENT_ID,
		"interface_mode": INTERFACE_MODE,
	}
