extends RefCounted
class_name ShardFabric

## Security-first shard directory and catalog foundation.
##
## Every network, cryptographic, IPFS, Hive, and Solana result in this class is an
## interface simulation.  It is deliberately useful for UI and protocol work, but
## it must not be mistaken for deployed cryptography or a live-chain adapter.

signal state_changed(previous_state: int, next_state: int, receipt: Dictionary)
signal fabric_ready(snapshot: Dictionary)
signal catalog_changed(node_id: String, record_id: String)

const INTERFACE_SIMULATION := "INTERFACE_SIMULATION_ONLY"
const SCHEMA_VERSION := "shard-fabric/0.1"

enum InitState {
	IDLE,
	DEVICE_IDENTITY,
	ML_KEM_768_CAPABILITY,
	LIBP2P_RELAY,
	IPFS_IPNS_DIRECTORY,
	HIVE_COMMITMENT,
	SOLANA_PDA_COMMITMENT,
	READY,
	FAILED,
}

enum DataTier {
	PUBLIC,
	LOBBY,
	PRIVATE,
	SECRET,
}

const STATE_NAMES := {
	InitState.IDLE: "idle",
	InitState.DEVICE_IDENTITY: "device_identity",
	InitState.ML_KEM_768_CAPABILITY: "ml_kem_768_capability",
	InitState.LIBP2P_RELAY: "libp2p_relay_peer_id",
	InitState.IPFS_IPNS_DIRECTORY: "ipfs_ipns_directory",
	InitState.HIVE_COMMITMENT: "hive_commitment",
	InitState.SOLANA_PDA_COMMITMENT: "solana_pda_commitment",
	InitState.READY: "ready",
	InitState.FAILED: "failed",
}

const TIER_NAMES := {
	DataTier.PUBLIC: "public",
	DataTier.LOBBY: "lobby",
	DataTier.PRIVATE: "private",
	DataTier.SECRET: "secret",
}

const FORBIDDEN_FIELD_NAMES := {
	"private_key": true,
	"private_keys": true,
	"secret_key": true,
	"secret_keys": true,
	"seed_phrase": true,
	"mnemonic": true,
	"raw_ip": true,
	"raw_ips": true,
	"ip_address": true,
	"ip_addresses": true,
	"ipv4": true,
	"ipv6": true,
	"socket_address": true,
	"friend_graph": true,
	"friend_list": true,
	"friends": true,
	"dm": true,
	"direct_message": true,
	"message": true,
	"message_body": true,
	"body": true,
}

var state: int = InitState.IDLE

var _simulation_seed := ""
var _device_id := ""
var _node_id := ""
var _peer_id := ""
var _relay_route := ""
var _directory_cid := ""
var _ipns_name := ""
var _hive_commitment := ""
var _solana_pda := ""
var _sequence := 0

var _initialization_trace: Array[Dictionary] = []
var _adapter_receipts: Array[Dictionary] = []
var _key_hierarchy: Dictionary = {}
## This is the only location containing simulated derived secret material.  It is
## never included in snapshots, records, receipts, exports, or query results.
var _volatile_key_material: Dictionary = {}
var _volatile_secrets_cleared := false
var _catalogs_by_node: Dictionary = {}


func initialize(config: Dictionary = {}) -> Dictionary:
	if state != InitState.IDLE and state != InitState.FAILED:
		return _failure("fabric_already_initialized")
	var unsafe_reason := _unsafe_value_reason(config, "config")
	if not unsafe_reason.is_empty():
		state = InitState.FAILED
		return _failure(unsafe_reason)

	_reset_runtime()
	_simulation_seed = String(config.get("simulation_seed", "local-prototype-seed"))
	if _simulation_seed.is_empty():
		_simulation_seed = "local-prototype-seed"
	var device_alias := String(config.get("device_alias", "nexus-device"))

	var root_key_id := _derive_key_handle("root", "", "fabric-root")
	var device_key_id := _derive_key_handle("device", root_key_id, device_alias)
	_device_id = "dev_" + _digest(device_alias + "|" + device_key_id).substr(0, 24)
	_node_id = "node_" + _digest(_device_id + "|catalog").substr(0, 24)
	_transition(InitState.DEVICE_IDENTITY, _mock_receipt(
		"DeviceIdentityMockAdapter",
		"create_non_exportable_identity",
		{
			"device_id": _device_id,
			"node_id": _node_id,
			"root_key_handle": root_key_id,
			"device_key_handle": device_key_id,
			"private_material_exported": false,
		}
	))

	_transition(InitState.ML_KEM_768_CAPABILITY, _mock_receipt(
		"MlKem768MockAdapter",
		"probe_and_bind_device_capability",
		{
			"algorithm": "ML-KEM-768",
			"capability": "simulated_available",
			"public_key_fingerprint": "sha256:" + _digest(device_key_id + "|ml-kem"),
			"bulk_encryption": "XChaCha20-Poly1305 interface contract",
		}
	))

	_peer_id = "12D3KooW" + _digest(_device_id + "|libp2p").substr(0, 36)
	_relay_route = "/p2p-circuit/p2p/" + _peer_id
	_transition(InitState.LIBP2P_RELAY, _mock_receipt(
		"Libp2pRelayMockAdapter",
		"derive_peer_id_and_relay_route",
		{
			"peer_id": _peer_id,
			"relay_route": _relay_route,
			"raw_network_coordinates_persisted": false,
		}
	))

	_directory_cid = "bafy" + _digest(_node_id + "|directory").substr(0, 52)
	_ipns_name = "k51qzi5uqu5d" + _digest(_peer_id + "|ipns").substr(0, 40)
	_transition(InitState.IPFS_IPNS_DIRECTORY, _mock_receipt(
		"IpfsIpnsMockAdapter",
		"publish_signed_directory_envelope",
		{
			"directory_cid": _directory_cid,
			"ipns_name": _ipns_name,
			"content": "commitments_and_ciphertext_only",
		}
	))

	_hive_commitment = "hive_sim_" + _digest(_directory_cid + "|hive").substr(0, 40)
	_transition(InitState.HIVE_COMMITMENT, _mock_receipt(
		"HiveCommitmentMockAdapter",
		"anchor_directory_commitment",
		{
			"transaction_commitment": _hive_commitment,
			"plaintext_social_data_on_chain": false,
		}
	))

	_solana_pda = "pda_sim_" + _digest(_hive_commitment + "|solana").substr(0, 40)
	_transition(InitState.SOLANA_PDA_COMMITMENT, _mock_receipt(
		"SolanaPdaMockAdapter",
		"derive_and_commit_directory_pda",
		{
			"pda_commitment": _solana_pda,
			"program_execution": "not_performed",
		}
	))

	_catalogs_by_node[_node_id] = []
	_transition(InitState.READY, _mock_receipt(
		"ShardFabricCoordinator",
		"mark_ready",
		{"catalog_node": _node_id, "adapter_count": _adapter_receipts.size() + 1}
	))
	var snapshot := get_public_snapshot()
	fabric_ready.emit(snapshot)
	return {"ok": true, "snapshot": snapshot}


func get_state_name() -> String:
	return String(STATE_NAMES.get(state, "unknown"))


func get_device_id() -> String:
	return _device_id


func get_node_id() -> String:
	return _node_id


func get_peer_id() -> String:
	return _peer_id


func get_initialization_trace() -> Array[Dictionary]:
	return _initialization_trace.duplicate(true)


func get_adapter_receipts() -> Array[Dictionary]:
	return _adapter_receipts.duplicate(true)


func get_public_snapshot() -> Dictionary:
	return {
		"schema": SCHEMA_VERSION,
		"interface_mode": INTERFACE_SIMULATION,
		"state": get_state_name(),
		"device_id": _device_id,
		"node_id": _node_id,
		"peer_id": _peer_id,
		"relay_route": _relay_route,
		"directory_cid": _directory_cid,
		"ipns_name": _ipns_name,
		"hive_commitment": _hive_commitment,
		"solana_pda_commitment": _solana_pda,
		"key_hierarchy": get_key_hierarchy_manifest(),
		"private_material_persisted": false,
		"raw_network_coordinates_persisted": false,
	}


func get_key_hierarchy_manifest() -> Array[Dictionary]:
	var manifests: Array[Dictionary] = []
	var key_ids: Array = _key_hierarchy.keys()
	key_ids.sort()
	for key_id in key_ids:
		manifests.append(Dictionary(_key_hierarchy[key_id]).duplicate(true))
	return manifests


func ensure_lobby_epoch_key(lobby_id: String, epoch: int, member_peer_ids: Array = []) -> Dictionary:
	if not _is_ready():
		return _failure("fabric_not_ready")
	if lobby_id.is_empty() or epoch < 1:
		return _failure("invalid_lobby_epoch_scope")
	if _contains_ip_literal(lobby_id) or _array_contains_ip_literal(member_peer_ids):
		return _failure("raw_ip_literal_rejected")
	var device_key_id := _find_key_id("device", "")
	var scope := _digest(lobby_id) + ":" + str(epoch)
	var key_id := _derive_key_handle("lobby_epoch", device_key_id, scope)
	var manifest: Dictionary = _key_hierarchy[key_id]
	manifest["member_commitments"] = _commit_ids(member_peer_ids)
	_key_hierarchy[key_id] = manifest
	return {"ok": true, "key": manifest.duplicate(true)}


func ensure_dm_key(remote_peer_id: String) -> Dictionary:
	if not _is_ready():
		return _failure("fabric_not_ready")
	if remote_peer_id.is_empty() or _contains_ip_literal(remote_peer_id):
		return _failure("invalid_remote_peer_id")
	var device_key_id := _find_key_id("device", "")
	var key_id := _derive_key_handle("dm", device_key_id, _digest(remote_peer_id))
	return {"ok": true, "key": Dictionary(_key_hierarchy[key_id]).duplicate(true)}


func ensure_content_key(scope_id: String, tier: int, parent_key_id: String = "") -> Dictionary:
	if not _is_ready():
		return _failure("fabric_not_ready")
	if not TIER_NAMES.has(tier) or scope_id.is_empty() or _contains_ip_literal(scope_id):
		return _failure("invalid_content_key_scope")
	if parent_key_id.is_empty():
		parent_key_id = _find_key_id("device", "")
	if not _key_hierarchy.has(parent_key_id):
		return _failure("unknown_parent_key_handle")
	var scope := String(TIER_NAMES[tier]) + ":" + _digest(scope_id)
	var key_id := _derive_key_handle("content", parent_key_id, scope)
	return {"ok": true, "key": Dictionary(_key_hierarchy[key_id]).duplicate(true)}


func clear_volatile_secrets() -> void:
	for key_id in _volatile_key_material.keys():
		_volatile_key_material[key_id] = ""
	_volatile_key_material.clear()
	_simulation_seed = ""
	_volatile_secrets_cleared = true


func publish_record(kind: String, payload: Dictionary, tier: int, access: Dictionary = {}) -> Dictionary:
	if not _is_ready():
		return _failure("fabric_not_ready")
	if not TIER_NAMES.has(tier):
		return _failure("unknown_data_tier")
	if kind.strip_edges().is_empty():
		return _failure("record_kind_required")
	var unsafe_reason := _unsafe_value_reason(payload, "payload")
	if not unsafe_reason.is_empty():
		return _failure(unsafe_reason)
	if _contains_ip_literal(access):
		return _failure("raw_ip_literal_rejected")
	if _volatile_secrets_cleared and tier != DataTier.PUBLIC:
		return _failure("volatile_key_material_unavailable")

	var normalized_access_result := _normalize_access(tier, access)
	if not normalized_access_result.get("ok", false):
		return normalized_access_result
	var normalized_access: Dictionary = normalized_access_result["access"]

	_sequence += 1
	var payload_json := JSON.stringify(payload)
	var record_id := "rec_" + _digest(_node_id + "|" + kind + "|" + str(_sequence) + "|" + payload_json).substr(0, 32)
	var record := {
		"schema": SCHEMA_VERSION,
		"interface_mode": INTERFACE_SIMULATION,
		"record_id": record_id,
		"origin_node_id": _node_id,
		"kind": kind,
		"tier": String(TIER_NAMES[tier]),
		"tier_code": tier,
		"sequence": _sequence,
		"content_commitment": "sha256:" + _digest(payload_json),
		"access": normalized_access,
		"propagation": _propagation_policy(tier),
		"anchors": {
			"ipns": _ipns_name,
			"hive": _hive_commitment,
			"solana_pda": _solana_pda,
		},
	}
	if tier == DataTier.PUBLIC:
		record["payload"] = payload.duplicate(true)
	else:
		var envelope_result := _create_protected_envelope(record_id, payload, tier, normalized_access)
		if not envelope_result.get("ok", false):
			return envelope_result
		record["envelope"] = envelope_result["envelope"]

	var local_catalog: Array = _catalogs_by_node.get(_node_id, [])
	local_catalog.append(record)
	_catalogs_by_node[_node_id] = local_catalog
	catalog_changed.emit(_node_id, record_id)
	return {"ok": true, "record": record.duplicate(true)}


func commit_friend_edge(remote_peer_id: String, status: String = "accepted") -> Dictionary:
	if remote_peer_id.is_empty() or _contains_ip_literal(remote_peer_id):
		return _failure("invalid_remote_peer_id")
	if status not in ["invited", "accepted", "revoked"]:
		return _failure("invalid_friend_edge_status")
	var peer_pair: Array[String] = [_peer_id, remote_peer_id]
	peer_pair.sort()
	var edge_commitment := _digest(peer_pair[0] + "|" + peer_pair[1] + "|friend-edge")
	return publish_record("friend_edge_commitment", {
		"edge_commitment": "sha256:" + edge_commitment,
		"status": status,
		"plaintext_friend_graph": false,
	}, DataTier.PUBLIC)


func publish_lobby_peer_bucket(
	lobby_id: String,
	relay_peer_ids: Array,
	member_peer_ids: Array,
	epoch: int = 1
) -> Dictionary:
	if lobby_id.is_empty() or relay_peer_ids.is_empty() or member_peer_ids.is_empty():
		return _failure("lobby_peer_bucket_requires_scope_relays_and_members")
	if _contains_ip_literal(lobby_id) or _array_contains_ip_literal(relay_peer_ids) or _array_contains_ip_literal(member_peer_ids):
		return _failure("raw_ip_literal_rejected_use_relay_peer_ids")
	return publish_record("lobby_peer_bucket", {
		"relay_peer_ids": relay_peer_ids.duplicate(true),
		"peer_count": relay_peer_ids.size(),
		"directory_link": _ipns_name,
		"epoch": epoch,
	}, DataTier.LOBBY, {
		"lobby_id": lobby_id,
		"member_peer_ids": member_peer_ids,
		"epoch": epoch,
	})


func publish_dm_ciphertext_pointer(
	remote_peer_id: String,
	ciphertext_cid: String,
	owner_peer_id: String = ""
) -> Dictionary:
	if remote_peer_id.is_empty() or ciphertext_cid.is_empty():
		return _failure("dm_pointer_requires_peer_and_ciphertext_cid")
	if _contains_ip_literal(remote_peer_id) or _contains_ip_literal(ciphertext_cid):
		return _failure("raw_ip_literal_rejected")
	if owner_peer_id.is_empty():
		owner_peer_id = _peer_id
	var dm_key_result := ensure_dm_key(remote_peer_id)
	if not dm_key_result.get("ok", false):
		return dm_key_result
	return publish_record("dm_ciphertext_pointer", {
		"ciphertext_cid_commitment": "sha256:" + _digest(ciphertext_cid),
		"plaintext_dm_persisted": false,
	}, DataTier.PRIVATE, {
		"owner_peer_id": owner_peer_id,
		"reader_peer_ids": [remote_peer_id],
		"key_handle": dm_key_result["key"]["key_id"],
	})


func export_catalog_for_replication(auth: Dictionary = {}) -> Array[Dictionary]:
	var exported: Array[Dictionary] = []
	for record in upcycle_query({}, auth):
		if String(record.get("tier", "")) == "secret":
			continue
		exported.append(record.duplicate(true))
	return exported


func register_remote_catalog(node_id: String, records: Array) -> Dictionary:
	if not _is_ready():
		return _failure("fabric_not_ready")
	if node_id.is_empty() or _contains_ip_literal(node_id):
		return _failure("invalid_remote_node_id")
	# Preserve already accepted records. Re-registering a node is idempotent and a
	# duplicate batch must never erase the last known-good catalog.
	var accepted: Array = Array(_catalogs_by_node.get(node_id, [])).duplicate(true)
	var newly_accepted := 0
	var rejected: Array[Dictionary] = []
	var seen_ids: Dictionary = {}
	for existing in accepted:
		seen_ids[String(existing.get("record_id", ""))] = true
	for candidate in records:
		if not candidate is Dictionary:
			rejected.append({"record_id": "", "reason": "record_must_be_dictionary"})
			continue
		var record: Dictionary = candidate
		var reason := _replica_rejection_reason(node_id, record)
		var record_id := String(record.get("record_id", ""))
		if reason.is_empty() and seen_ids.has(record_id):
			reason = "duplicate_record_id"
		if not reason.is_empty():
			rejected.append({"record_id": record_id, "reason": reason})
			continue
		seen_ids[record_id] = true
		accepted.append(record.duplicate(true))
		newly_accepted += 1
	_catalogs_by_node[node_id] = accepted
	return {
		"ok": true,
		"accepted": newly_accepted,
		"catalog_size": accepted.size(),
		"rejected": rejected,
	}


func upcycle_catalog(remote_catalogs: Dictionary, auth: Dictionary = {}, filters: Dictionary = {}) -> Dictionary:
	var registrations: Dictionary = {}
	for node_id_value in remote_catalogs.keys():
		var node_id := String(node_id_value)
		var records_value = remote_catalogs[node_id_value]
		if not records_value is Array:
			registrations[node_id] = _failure("catalog_must_be_array")
			continue
		registrations[node_id] = register_remote_catalog(node_id, records_value)
	return {
		"ok": true,
		"interface_mode": INTERFACE_SIMULATION,
		"registrations": registrations,
		"records": upcycle_query(filters, auth),
	}


func upcycle_query(filters: Dictionary = {}, auth: Dictionary = {}) -> Array[Dictionary]:
	var visible: Array[Dictionary] = []
	var node_ids: Array = _catalogs_by_node.keys()
	node_ids.sort()
	for node_id_value in node_ids:
		var node_id := String(node_id_value)
		for candidate in _catalogs_by_node[node_id]:
			var record: Dictionary = candidate
			if not _is_authorized(record, auth):
				continue
			if not _matches_filters(record, filters):
				continue
			var view: Dictionary = record.duplicate(true)
			view["catalog_node_id"] = node_id
			visible.append(view)
	visible.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var left := String(a.get("origin_node_id", "")) + ":" + str(a.get("sequence", 0))
		var right := String(b.get("origin_node_id", "")) + ":" + str(b.get("sequence", 0))
		return left < right
	)
	return visible


func get_visible_catalog_metrics(auth: Dictionary = {}) -> Dictionary:
	var metrics := {"total": 0, "public": 0, "lobby": 0, "private": 0, "secret": 0, "nodes": {}}
	for record in upcycle_query({}, auth):
		metrics["total"] += 1
		var tier := String(record.get("tier", ""))
		if metrics.has(tier):
			metrics[tier] += 1
		var node_id := String(record.get("catalog_node_id", ""))
		metrics["nodes"][node_id] = int(metrics["nodes"].get(node_id, 0)) + 1
	return metrics


func _reset_runtime() -> void:
	state = InitState.IDLE
	_simulation_seed = ""
	_device_id = ""
	_node_id = ""
	_peer_id = ""
	_relay_route = ""
	_directory_cid = ""
	_ipns_name = ""
	_hive_commitment = ""
	_solana_pda = ""
	_sequence = 0
	_initialization_trace.clear()
	_adapter_receipts.clear()
	_key_hierarchy.clear()
	_volatile_key_material.clear()
	_volatile_secrets_cleared = false
	_catalogs_by_node.clear()


func _transition(next_state: int, receipt: Dictionary) -> void:
	var previous_state := state
	state = next_state
	_adapter_receipts.append(receipt.duplicate(true))
	_initialization_trace.append({
		"state": next_state,
		"name": String(STATE_NAMES[next_state]),
		"interface_mode": INTERFACE_SIMULATION,
		"receipt": receipt.duplicate(true),
	})
	state_changed.emit(previous_state, next_state, receipt.duplicate(true))


func _mock_receipt(adapter: String, operation: String, output: Dictionary) -> Dictionary:
	return {
		"interface_mode": INTERFACE_SIMULATION,
		"adapter": adapter,
		"operation": operation,
		"status": "simulated",
		"output": output,
	}


func _derive_key_handle(kind: String, parent_key_id: String, scope: String) -> String:
	var parent_material := _simulation_seed
	if not parent_key_id.is_empty():
		parent_material = String(_volatile_key_material.get(parent_key_id, "missing-parent"))
	var material := _digest(parent_material + "|" + kind + "|" + scope)
	var key_id := "kh_" + kind + "_" + _digest(kind + "|" + parent_key_id + "|" + scope).substr(0, 20)
	if _key_hierarchy.has(key_id):
		return key_id
	_volatile_key_material[key_id] = material
	_key_hierarchy[key_id] = {
		"key_id": key_id,
		"kind": kind,
		"parent_key_id": parent_key_id,
		"scope_commitment": "sha256:" + _digest(scope),
		"algorithm_contract": "HKDF-SHA-256",
		"interface_mode": INTERFACE_SIMULATION,
		"non_exportable": true,
		"volatile": true,
		"material_commitment": "sha256:" + _digest(material),
		"private_material_persisted": false,
	}
	return key_id


func _find_key_id(kind: String, scope_commitment: String) -> String:
	for key_id in _key_hierarchy.keys():
		var manifest: Dictionary = _key_hierarchy[key_id]
		if String(manifest.get("kind", "")) != kind:
			continue
		if scope_commitment.is_empty() or String(manifest.get("scope_commitment", "")) == scope_commitment:
			return String(key_id)
	return ""


func _normalize_access(tier: int, access: Dictionary) -> Dictionary:
	match tier:
		DataTier.PUBLIC:
			return {"ok": true, "access": {"audience": "anyone"}}
		DataTier.LOBBY:
			var lobby_id := String(access.get("lobby_id", ""))
			var members_value = access.get("member_peer_ids", [])
			if not members_value is Array:
				return _failure("lobby_members_must_be_array")
			var members: Array = members_value
			var epoch := int(access.get("epoch", 1))
			if lobby_id.is_empty() or members.is_empty() or epoch < 1:
				return _failure("lobby_tier_requires_lobby_members_and_epoch")
			var key_result := ensure_lobby_epoch_key(lobby_id, epoch, members)
			if not key_result.get("ok", false):
				return key_result
			return {"ok": true, "access": {
				"lobby_commitment": "sha256:" + _digest(lobby_id),
				"epoch": epoch,
				"member_commitments": _commit_ids(members),
				"key_handle": key_result["key"]["key_id"],
			}}
		DataTier.PRIVATE:
			var owner_peer_id := String(access.get("owner_peer_id", _peer_id))
			var readers_value = access.get("reader_peer_ids", [])
			if not readers_value is Array:
				return _failure("private_readers_must_be_array")
			var readers: Array = readers_value
			if owner_peer_id.is_empty():
				return _failure("private_tier_requires_owner")
			var all_readers: Array = readers.duplicate(true)
			all_readers.append(owner_peer_id)
			var supplied_key_handle := String(access.get("key_handle", ""))
			if not supplied_key_handle.is_empty() and not _key_hierarchy.has(supplied_key_handle):
				return _failure("unknown_private_key_handle")
			return {"ok": true, "access": {
				"owner_commitment": "sha256:" + _digest(owner_peer_id),
				"reader_commitments": _commit_ids(all_readers),
				"key_handle": supplied_key_handle,
			}}
		DataTier.SECRET:
			var owner_device_id := String(access.get("owner_device_id", _device_id))
			if owner_device_id != _device_id:
				return _failure("secret_tier_must_bind_local_device")
			return {"ok": true, "access": {
				"device_commitment": "sha256:" + _digest(owner_device_id),
				"exportable": false,
			}}
	return _failure("unknown_data_tier")


func _create_protected_envelope(record_id: String, payload: Dictionary, tier: int, access: Dictionary) -> Dictionary:
	var key_handle := String(access.get("key_handle", ""))
	if key_handle.is_empty():
		var content_key_result := ensure_content_key(record_id, tier)
		if not content_key_result.get("ok", false):
			return content_key_result
		key_handle = String(content_key_result["key"]["key_id"])
	var material := String(_volatile_key_material.get(key_handle, ""))
	if material.is_empty():
		return _failure("protected_envelope_key_unavailable")
	var serialized := JSON.stringify(payload)
	return {"ok": true, "envelope": {
		"interface_mode": INTERFACE_SIMULATION,
		"kem_contract": "ML-KEM-768",
		"kdf_contract": "HKDF-SHA-256",
		"aead_contract": "XChaCha20-Poly1305",
		"key_handle": key_handle,
		"ciphertext": "simct_" + _digest(material + "|" + record_id + "|" + serialized),
		"padding_policy": "production_adapter_required",
		"plaintext_persisted": false,
		"cryptography_performed": false,
	}}


func _propagation_policy(tier: int) -> String:
	match tier:
		DataTier.PUBLIC:
			return "ipfs_ipns_public_plus_chain_commitments"
		DataTier.LOBBY:
			return "ipfs_ciphertext_membership_capability"
		DataTier.PRIVATE:
			return "ipfs_ciphertext_explicit_readers"
		DataTier.SECRET:
			return "device_local_no_replication"
	return "deny"


func _is_authorized(record: Dictionary, auth: Dictionary) -> bool:
	var tier := String(record.get("tier", ""))
	var access: Dictionary = record.get("access", {})
	match tier:
		"public":
			return true
		"lobby":
			var peer_commitment := "sha256:" + _digest(String(auth.get("peer_id", "")))
			var lobby_commitments: Array[String] = []
			for lobby_id in auth.get("lobby_ids", []):
				lobby_commitments.append("sha256:" + _digest(String(lobby_id)))
			return peer_commitment in access.get("member_commitments", []) \
				and String(access.get("lobby_commitment", "")) in lobby_commitments
		"private":
			var private_peer_commitment := "sha256:" + _digest(String(auth.get("peer_id", "")))
			return private_peer_commitment in access.get("reader_commitments", [])
		"secret":
			if not bool(auth.get("include_secret", false)):
				return false
			var device_commitment := "sha256:" + _digest(String(auth.get("device_id", "")))
			return device_commitment == String(access.get("device_commitment", ""))
	return false


func _matches_filters(record: Dictionary, filters: Dictionary) -> bool:
	if filters.has("kind") and String(record.get("kind", "")) != String(filters["kind"]):
		return false
	if filters.has("tier"):
		var requested_tier = filters["tier"]
		if requested_tier is int and int(record.get("tier_code", -1)) != requested_tier:
			return false
		if requested_tier is String and String(record.get("tier", "")) != requested_tier:
			return false
	if filters.has("origin_node_id") and String(record.get("origin_node_id", "")) != String(filters["origin_node_id"]):
		return false
	return true


func _replica_rejection_reason(node_id: String, record: Dictionary) -> String:
	if String(record.get("schema", "")) != SCHEMA_VERSION:
		return "unsupported_schema"
	if String(record.get("interface_mode", "")) != INTERFACE_SIMULATION:
		return "unlabeled_adapter_data"
	if String(record.get("record_id", "")).is_empty():
		return "record_id_required"
	if String(record.get("origin_node_id", "")) != node_id:
		return "origin_node_mismatch"
	if String(record.get("tier", "")) == "secret":
		return "secret_records_must_not_replicate"
	if _contains_ip_literal(record):
		return "raw_ip_literal_rejected"
	var unsafe_reason := _unsafe_value_reason(record, "replica")
	if not unsafe_reason.is_empty():
		return unsafe_reason
	return ""


func _unsafe_value_reason(value: Variant, path: String) -> String:
	if _contains_ip_literal(value):
		return "raw_ip_literal_rejected_at_" + path
	if value is Dictionary:
		for key_value in value.keys():
			var key := String(key_value).to_lower()
			if FORBIDDEN_FIELD_NAMES.has(key):
				return "forbidden_field_" + key + "_at_" + path
			var child_reason := _unsafe_value_reason(value[key_value], path + "." + key)
			if not child_reason.is_empty():
				return child_reason
	elif value is Array:
		for index in value.size():
			var item_reason := _unsafe_value_reason(value[index], path + "[" + str(index) + "]")
			if not item_reason.is_empty():
				return item_reason
	elif value != null and not value is String and not value is bool and not value is int and not value is float:
		return "unsupported_non_json_value_at_" + path
	return ""


func _contains_ip_literal(value: Variant) -> bool:
	var serialized := JSON.stringify(value) if not value is String else String(value)
	var ipv4 := RegEx.new()
	ipv4.compile("(^|[^0-9])([0-9]{1,3}\\.){3}[0-9]{1,3}([^0-9]|$)")
	if ipv4.search(serialized) != null:
		return true
	var ipv6 := RegEx.new()
	ipv6.compile("(?i)([0-9a-f]{1,4}:){2,}[0-9a-f]{0,4}")
	return ipv6.search(serialized) != null


func _array_contains_ip_literal(values: Array) -> bool:
	for value in values:
		if _contains_ip_literal(value):
			return true
	return false


func _commit_ids(values: Array) -> Array[String]:
	var commitments: Array[String] = []
	for value in values:
		var identifier := String(value)
		if identifier.is_empty():
			continue
		var commitment := "sha256:" + _digest(identifier)
		if commitment not in commitments:
			commitments.append(commitment)
	commitments.sort()
	return commitments


func _is_ready() -> bool:
	return state == InitState.READY


func _failure(reason: String) -> Dictionary:
	return {"ok": false, "error": reason, "interface_mode": INTERFACE_SIMULATION}


func _digest(value: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	var bytes := value.to_utf8_buffer()
	# Godot reports an error when HashingContext.update receives an empty buffer.
	# A domain byte keeps the simulation deterministic without touching that path.
	if bytes.is_empty():
		bytes = PackedByteArray([0])
	context.update(bytes)
	return context.finish().hex_encode()
