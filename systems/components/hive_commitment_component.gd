extends RefCounted
class_name HiveCommitmentComponent

## A production-shaped Hive `custom_json` boundary for public commitments.
##
## This component never connects to Hive, signs an operation, or accepts signing
## material. It builds and validates deterministic unsigned operation envelopes so
## UI, governance, and adapter code can be exercised before a separately audited
## wallet/RPC integration exists.

const INTERFACE_MODE := "INTERFACE_SIMULATION_ONLY"
const COMPONENT_ID := "nexus.hive.custom_json_commitment"
const SCHEMA_VERSION := "nexus.hive-commitment/1"
const DEFAULT_CUSTOM_JSON_ID := "nexus.shard.commitment.v1"
const MAX_JSON_BYTES := 8192

const ALLOWED_RECORD_KINDS: Array[String] = [
	"asset_manifest_commitment",
	"catalog_root_commitment",
	"friend_edge_commitment",
	"governance_checkpoint",
	"ruleset_commitment",
	"shard_directory_commitment",
	"world_manifest_commitment",
]

const CONFIG_FIELDS := {
	"network_label": true,
	"custom_json_id": true,
	"authority_policy": true,
}

const AUTHORITY_FIELDS := {
	"account": true,
	"permission": true,
	"nonce": true,
}

const COMMITMENT_FIELDS := {
	"record_id": true,
	"record_kind": true,
	"directory_cid": true,
	"content_commitment": true,
	"sequence": true,
	"previous_commitment": true,
	"visibility": true,
	"epoch": true,
	"timestamp_bucket": true,
}

const ENVELOPE_FIELDS := {
	"schema": true,
	"interface_mode": true,
	"network_label": true,
	"custom_json_id": true,
	"authority": true,
	"nonce": true,
	"commitment": true,
	"envelope_commitment": true,
}

const OPERATION_FIELDS := {
	"required_auths": true,
	"required_posting_auths": true,
	"id": true,
	"json": true,
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
var _custom_json_id := ""
var _authority_policy: Dictionary = {}

## Outbound reservations and inbound observations remain independent. Building an
## unsigned operation cannot be confused with observing a chain-accepted one.
var _outbound_nonce_by_scope: Dictionary = {}
var _inbound_nonce_by_scope: Dictionary = {}
var _outbound_envelopes: Dictionary = {}
var _inbound_envelopes: Dictionary = {}


func initialize(config: Dictionary = {}) -> Dictionary:
	if _configured:
		return _failure("component_already_initialized")
	var unknown_field := _unknown_field(config, CONFIG_FIELDS)
	if not unknown_field.is_empty():
		return _failure("unsupported_config_field_" + unknown_field)
	var unsafe_reason := _unsafe_reason(config, "config")
	if not unsafe_reason.is_empty():
		return _failure(unsafe_reason)

	var network_label := String(config.get("network_label", "hive-interface"))
	var custom_json_id := String(config.get("custom_json_id", DEFAULT_CUSTOM_JSON_ID))
	var authority_value = config.get("authority_policy", {})
	if not _matches(network_label, "^[a-z0-9][a-z0-9_-]{1,47}$"):
		return _failure("invalid_network_label")
	if not _matches(custom_json_id, "^[a-z][a-z0-9._-]{2,31}$"):
		return _failure("invalid_custom_json_id")
	if not authority_value is Dictionary:
		return _failure("authority_policy_must_be_dictionary")
	var normalized_policy_result := _normalize_authority_policy(authority_value)
	if not normalized_policy_result.get("ok", false):
		return normalized_policy_result

	_network_label = network_label
	_custom_json_id = custom_json_id
	_authority_policy = normalized_policy_result["policy"]
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
	var policy: Dictionary = {}
	var accounts: Array = _authority_policy.keys()
	accounts.sort()
	for account_value in accounts:
		var account := String(account_value)
		policy["authority_" + _digest(account).substr(0, 16)] = \
			Array(_authority_policy[account]).duplicate()
	return {
		"schema": SCHEMA_VERSION,
		"component_id": COMPONENT_ID,
		"interface_mode": INTERFACE_MODE,
		"configured": _configured,
		"network_label": _network_label,
		"custom_json_id": _custom_json_id,
		"authority_policy": policy,
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


func build_custom_json_commitment(commitment: Dictionary, authority: Dictionary) -> Dictionary:
	if not _configured:
		return _failure("component_not_initialized")
	var commitment_result := _normalize_commitment(commitment)
	if not commitment_result.get("ok", false):
		return commitment_result
	var authority_result := _validate_authority(authority)
	if not authority_result.get("ok", false):
		return authority_result
	var normalized_authority: Dictionary = authority_result["authority"]
	var nonce := int(normalized_authority["nonce"])
	var scope := _authority_scope(normalized_authority)
	var nonce_error := _nonce_error(_outbound_nonce_by_scope, scope, nonce)
	if not nonce_error.is_empty():
		return _failure("outbound_" + nonce_error)

	var envelope := {
		"schema": SCHEMA_VERSION,
		"interface_mode": INTERFACE_MODE,
		"network_label": _network_label,
		"custom_json_id": _custom_json_id,
		"authority": {
			"account": normalized_authority["account"],
			"permission": normalized_authority["permission"],
		},
		"nonce": nonce,
		"commitment": commitment_result["commitment"],
	}
	var envelope_commitment := "sha256:" + _digest(_canonical_json(envelope))
	envelope["envelope_commitment"] = envelope_commitment
	var payload_json := _canonical_json(envelope)
	if payload_json.to_utf8_buffer().size() > MAX_JSON_BYTES:
		return _failure("custom_json_payload_too_large")

	var account := String(normalized_authority["account"])
	var permission := String(normalized_authority["permission"])
	var operation := {
		"required_auths": [account] if permission == "active" else [],
		"required_posting_auths": [account] if permission == "posting" else [],
		"id": _custom_json_id,
		"json": payload_json,
	}
	var operation_commitment := "sha256:" + _digest(_canonical_json(operation))
	if _outbound_envelopes.has(envelope_commitment):
		return _failure("outbound_duplicate_envelope")
	_outbound_nonce_by_scope[scope] = nonce
	_outbound_envelopes[envelope_commitment] = true

	return {
		"ok": true,
		"component_id": COMPONENT_ID,
		"interface_mode": INTERFACE_MODE,
		"operation": operation,
		"envelope": envelope.duplicate(true),
		"operation_commitment": operation_commitment,
		"receipt": {
			"status": "unsigned_interface_built",
			"signing_performed": false,
			"broadcast_performed": false,
			"live_rpc_used": false,
			"wallet_material_requested": false,
		},
	}


func prepare_commitment(commitment: Dictionary, authority: Dictionary) -> Dictionary:
	## Stable startup-facing alias. The returned operation is always unsigned and
	## never broadcast by this component.
	return build_custom_json_commitment(commitment, authority)


func validate_custom_json_operation(operation: Dictionary, consume_nonce: bool = true) -> Dictionary:
	if not _configured:
		return _failure("component_not_initialized")
	var unknown_field := _unknown_field(operation, OPERATION_FIELDS)
	if not unknown_field.is_empty():
		return _failure("unsupported_operation_field_" + unknown_field)
	for required_field in OPERATION_FIELDS.keys():
		if not operation.has(required_field):
			return _failure("missing_operation_field_" + String(required_field))
	if String(operation.get("id", "")) != _custom_json_id:
		return _failure("custom_json_id_mismatch")
	var required_auths_value = operation.get("required_auths", null)
	var required_posting_value = operation.get("required_posting_auths", null)
	if not required_auths_value is Array or not required_posting_value is Array:
		return _failure("operation_authorities_must_be_arrays")
	var payload_json := String(operation.get("json", ""))
	if payload_json.is_empty() or payload_json.to_utf8_buffer().size() > MAX_JSON_BYTES:
		return _failure("invalid_custom_json_payload_size")

	var parser := JSON.new()
	if parser.parse(payload_json) != OK or not parser.data is Dictionary:
		return _failure("custom_json_payload_must_be_object")
	var envelope: Dictionary = parser.data
	var envelope_result := _validate_envelope(envelope)
	if not envelope_result.get("ok", false):
		return envelope_result
	var normalized_envelope: Dictionary = envelope_result["envelope"]
	var envelope_authority: Dictionary = normalized_envelope["authority"]
	var account := String(envelope_authority["account"])
	var permission := String(envelope_authority["permission"])
	var expected_active: Array = [account] if permission == "active" else []
	var expected_posting: Array = [account] if permission == "posting" else []
	if required_auths_value != expected_active or required_posting_value != expected_posting:
		return _failure("operation_authority_binding_mismatch")

	var authority_result := _validate_authority({
		"account": account,
		"permission": permission,
		"nonce": normalized_envelope["nonce"],
	})
	if not authority_result.get("ok", false):
		return authority_result
	var scope := _authority_scope(authority_result["authority"])
	var nonce := int(normalized_envelope["nonce"])
	var nonce_error := _nonce_error(_inbound_nonce_by_scope, scope, nonce)
	if not nonce_error.is_empty():
		return _failure("inbound_" + nonce_error)
	var envelope_commitment := String(normalized_envelope["envelope_commitment"])
	if _inbound_envelopes.has(envelope_commitment):
		return _failure("inbound_duplicate_envelope")

	if consume_nonce:
		_inbound_nonce_by_scope[scope] = nonce
		_inbound_envelopes[envelope_commitment] = true
	return {
		"ok": true,
		"interface_mode": INTERFACE_MODE,
		"envelope": normalized_envelope.duplicate(true),
		"operation_commitment": "sha256:" + _digest(_canonical_json(operation)),
		"nonce_consumed": consume_nonce,
		"signature_verified": false,
		"authority_policy_validated": true,
	}


func get_replay_snapshot() -> Dictionary:
	return {
		"component_id": COMPONENT_ID,
		"interface_mode": INTERFACE_MODE,
		"outbound": _redacted_nonce_ledger(_outbound_nonce_by_scope),
		"inbound": _redacted_nonce_ledger(_inbound_nonce_by_scope),
		"outbound_envelope_count": _outbound_envelopes.size(),
		"inbound_envelope_count": _inbound_envelopes.size(),
	}


func _normalize_authority_policy(policy: Dictionary) -> Dictionary:
	if policy.is_empty():
		return _failure("authority_policy_required")
	var normalized: Dictionary = {}
	for account_value in policy.keys():
		var account := String(account_value)
		if not _valid_hive_account(account):
			return _failure("invalid_authority_account")
		var permissions_value = policy[account_value]
		if not permissions_value is Array or permissions_value.is_empty():
			return _failure("authority_permissions_must_be_nonempty_array")
		var permissions: Array[String] = []
		for permission_value in permissions_value:
			var permission := String(permission_value)
			if permission not in ["posting", "active"]:
				return _failure("unsupported_hive_authority")
			if permission not in permissions:
				permissions.append(permission)
		permissions.sort()
		normalized[account] = permissions
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
	var account := String(authority.get("account", ""))
	var permission := String(authority.get("permission", ""))
	var nonce_result := _positive_integer(authority.get("nonce", null), "authority_nonce")
	if not nonce_result.get("ok", false):
		return nonce_result
	if not _authority_policy.has(account):
		return _failure("authority_account_not_allowed")
	if permission not in _authority_policy[account]:
		return _failure("authority_permission_not_allowed")
	return {"ok": true, "authority": {
		"account": account,
		"permission": permission,
		"nonce": nonce_result["value"],
	}}


func _normalize_commitment(commitment: Dictionary) -> Dictionary:
	var unknown_field := _unknown_field(commitment, COMMITMENT_FIELDS)
	if not unknown_field.is_empty():
		return _failure("unsupported_commitment_field_" + unknown_field)
	for required_field in ["record_id", "record_kind", "directory_cid", "content_commitment", "sequence"]:
		if not commitment.has(required_field):
			return _failure("missing_commitment_field_" + required_field)
	var unsafe_reason := _unsafe_reason(commitment, "commitment")
	if not unsafe_reason.is_empty():
		return _failure(unsafe_reason)
	var record_id := String(commitment.get("record_id", ""))
	var record_kind := String(commitment.get("record_kind", ""))
	var directory_cid := String(commitment.get("directory_cid", ""))
	var content_commitment := String(commitment.get("content_commitment", ""))
	if not _matches(record_id, "^rec_[0-9a-f]{32,64}$"):
		return _failure("invalid_record_id")
	if record_kind not in ALLOWED_RECORD_KINDS:
		return _failure("invalid_record_kind")
	if not _matches(directory_cid, "^(bafy|bafk|Qm)[A-Za-z0-9]{20,120}$"):
		return _failure("invalid_public_directory_cid")
	if not _valid_sha256_commitment(content_commitment):
		return _failure("invalid_content_commitment")
	var sequence_result := _positive_integer(commitment.get("sequence", null), "sequence")
	if not sequence_result.get("ok", false):
		return sequence_result

	var normalized := {
		"record_id": record_id,
		"record_kind": record_kind,
		"directory_cid": directory_cid,
		"content_commitment": content_commitment,
		"sequence": sequence_result["value"],
	}
	var previous := String(commitment.get("previous_commitment", ""))
	if not previous.is_empty():
		if not _valid_sha256_commitment(previous):
			return _failure("invalid_previous_commitment")
		normalized["previous_commitment"] = previous
	var visibility := String(commitment.get("visibility", "commitment_only"))
	if visibility not in ["public", "commitment_only"]:
		return _failure("unsupported_commitment_visibility")
	normalized["visibility"] = visibility
	if commitment.has("epoch"):
		var epoch_result := _positive_integer(commitment["epoch"], "epoch")
		if not epoch_result.get("ok", false):
			return epoch_result
		normalized["epoch"] = epoch_result["value"]
	if commitment.has("timestamp_bucket"):
		var bucket_result := _nonnegative_integer(commitment["timestamp_bucket"], "timestamp_bucket")
		if not bucket_result.get("ok", false):
			return bucket_result
		normalized["timestamp_bucket"] = bucket_result["value"]
	return {"ok": true, "commitment": normalized}


func _validate_envelope(envelope: Dictionary) -> Dictionary:
	var unknown_field := _unknown_field(envelope, ENVELOPE_FIELDS)
	if not unknown_field.is_empty():
		return _failure("unsupported_envelope_field_" + unknown_field)
	for required_field in ENVELOPE_FIELDS.keys():
		if not envelope.has(required_field):
			return _failure("missing_envelope_field_" + String(required_field))
	if String(envelope.get("schema", "")) != SCHEMA_VERSION:
		return _failure("envelope_schema_mismatch")
	if String(envelope.get("interface_mode", "")) != INTERFACE_MODE:
		return _failure("unlabeled_or_live_envelope_rejected")
	if String(envelope.get("network_label", "")) != _network_label:
		return _failure("envelope_network_mismatch")
	if String(envelope.get("custom_json_id", "")) != _custom_json_id:
		return _failure("envelope_custom_json_id_mismatch")
	if not envelope.get("authority") is Dictionary or not envelope.get("commitment") is Dictionary:
		return _failure("envelope_children_must_be_objects")
	var commitment_result := _normalize_commitment(envelope["commitment"])
	if not commitment_result.get("ok", false):
		return commitment_result
	var authority_value: Dictionary = envelope["authority"]
	var authority_unknown := _unknown_field(authority_value, {"account": true, "permission": true})
	if not authority_unknown.is_empty() or not authority_value.has("account") or not authority_value.has("permission"):
		return _failure("invalid_envelope_authority_shape")
	var nonce_result := _positive_integer(envelope.get("nonce", null), "envelope_nonce")
	if not nonce_result.get("ok", false):
		return nonce_result

	var normalized := {
		"schema": SCHEMA_VERSION,
		"interface_mode": INTERFACE_MODE,
		"network_label": _network_label,
		"custom_json_id": _custom_json_id,
		"authority": {
			"account": String(authority_value["account"]),
			"permission": String(authority_value["permission"]),
		},
		"nonce": nonce_result["value"],
		"commitment": commitment_result["commitment"],
	}
	var expected_envelope_commitment := "sha256:" + _digest(_canonical_json(normalized))
	if String(envelope.get("envelope_commitment", "")) != expected_envelope_commitment:
		return _failure("envelope_commitment_mismatch")
	normalized["envelope_commitment"] = expected_envelope_commitment
	return {"ok": true, "envelope": normalized}


func _authority_scope(authority: Dictionary) -> String:
	return _network_label + "|" + _custom_json_id + "|" \
		+ String(authority["account"]) + "|" + String(authority["permission"])


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
	return _matches(value, "^5[1-9A-HJ-NP-Za-km-z]{50,51}$")


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
	var result := _nonnegative_integer(value, label)
	if not result.get("ok", false):
		return result
	if int(result["value"]) < 1:
		return _failure(label + "_must_be_positive_integer")
	return result


func _nonnegative_integer(value: Variant, label: String) -> Dictionary:
	if not value is int and not value is float:
		return _failure(label + "_must_be_integer")
	var integer := int(value)
	if float(value) != float(integer) or integer < 0:
		return _failure(label + "_must_be_nonnegative_integer")
	return {"ok": true, "value": integer}


func _valid_hive_account(account: String) -> bool:
	return account.length() <= 63 and _matches(
		account,
		"^[a-z][a-z0-9-]{2,15}(\\.[a-z][a-z0-9-]{2,15})*$"
	)


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
