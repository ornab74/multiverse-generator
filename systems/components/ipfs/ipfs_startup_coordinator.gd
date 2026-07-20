extends RefCounted
class_name IpfsStartupCoordinator

## High-level, settings-driven IPFS initialization workflow.
##
## The coordinator composes the lower-level components and returns a redacted
## receipt. It performs no network publication and no production cryptography.

const IpfsCatalogReplicationScript = preload("res://systems/components/ipfs/ipfs_catalog_replication.gd")
const IpfsContentCommitmentScript = preload("res://systems/components/ipfs/ipfs_content_commitment.gd")
const IpfsDagManifestScript = preload("res://systems/components/ipfs/ipfs_dag_manifest.gd")
const IpfsSafeValueScript = preload("res://systems/components/ipfs/ipfs_safe_value.gd")
const IpnsRecordAdapterScript = preload("res://systems/components/ipfs/ipns_record_adapter.gd")
const RelayPeerDirectoryScript = preload("res://systems/components/ipfs/libp2p_relay_peer_directory.gd")

const COMPONENT_ID := "ipfs.startup-coordinator/v1"
const INTERFACE_MODE := "LOCAL_IPFS_STACK_SIMULATION"
const SETTINGS_SCHEMA := "nexus.settings.ipfs/v1"
const ALLOWED_SETTING_KEYS := [
	"accepted_member_ids",
	"capabilities",
	"epoch",
	"ipns_name",
	"ipns_ttl_ns",
	"ipns_validity_seconds",
	"lobby_id",
	"local_member_id",
	"local_peer_id",
	"node_id",
	"peer_entry_ttl_seconds",
	"relay_peer_id",
	"schema",
	"signing_key_handle",
]

var _initialized := false
var _node_id := ""
var _local_member_id := ""
var _relay_directory: RefCounted
var _replicator: RefCounted
var _ipns_adapter: RefCounted
var _root_manifest: Dictionary = {}
var _root_commitment_receipt: Dictionary = {}
var _ipns_record: Dictionary = {}
var _redacted_receipt: Dictionary = {}


func initialize(
	settings: Dictionary,
	now_unix: int,
	authorization_hook: Callable = Callable(),
	origin_verifier: Callable = Callable()
) -> Dictionary:
	if _initialized:
		return _failure("ipfs_stack_already_initialized")
	var settings_result := validate_settings(settings)
	if not settings_result.get("ok", false):
		return settings_result
	var normalized: Dictionary = settings_result["normalized"]

	_node_id = String(normalized["node_id"])
	_local_member_id = String(normalized["local_member_id"])
	_relay_directory = RelayPeerDirectoryScript.new()
	_replicator = IpfsCatalogReplicationScript.new()
	_ipns_adapter = IpnsRecordAdapterScript.new()

	var relay_config: Dictionary = _relay_directory.configure(
		String(normalized["lobby_id"]),
		normalized["accepted_member_ids"],
		int(normalized["epoch"])
	)
	if not relay_config.get("ok", false):
		return _stage_failure("relay_directory_configure", relay_config)
	var relay_route := "/p2p/%s/p2p-circuit/p2p/%s" % [
		String(normalized["relay_peer_id"]),
		String(normalized["local_peer_id"]),
	]
	var peer_upsert: Dictionary = _relay_directory.upsert_peer(
		_local_member_id,
		String(normalized["local_peer_id"]),
		[relay_route],
		normalized["capabilities"],
		now_unix + int(normalized["peer_entry_ttl_seconds"]),
		now_unix
	)
	if not peer_upsert.get("ok", false):
		return _stage_failure("relay_peer_register", peer_upsert)

	var replicator_config: Dictionary = _replicator.configure(_node_id, authorization_hook, origin_verifier)
	if not replicator_config.get("ok", false):
		return _stage_failure("catalog_replicator_configure", replicator_config)
	var authorized_directory: Dictionary = _relay_directory.export_for_member(_local_member_id, now_unix)
	if not authorized_directory.get("ok", false):
		return _stage_failure("relay_directory_snapshot", authorized_directory)
	var directory_canonical := IpfsDagManifestScript.new().canonical_bytes(authorized_directory["directory"])
	if not directory_canonical.get("ok", false):
		return _stage_failure("relay_directory_commitment", directory_canonical)
	var directory_commitment := "sha256:" + IpfsSafeValueScript.sha256_hex(directory_canonical["bytes"])

	var dag := IpfsDagManifestScript.new()
	var manifest_result := dag.build("shard-directory", {
		"catalog_component": IpfsCatalogReplicationScript.COMPONENT_ID,
		"epoch": int(normalized["epoch"]),
		"lobby_commitment": _commit(String(normalized["lobby_id"])),
		"node_commitment": _commit(_node_id),
		"relay_directory_commitment": directory_commitment,
		"transport_policy": "libp2p_circuit_relay_only",
	}, [], {
		"interface_mode": INTERFACE_MODE,
		"live_network_state": false,
	})
	if not manifest_result.get("ok", false):
		return _stage_failure("directory_manifest_build", manifest_result)
	_root_manifest = manifest_result["manifest"]

	var content_result := IpfsContentCommitmentScript.new().commit_manifest(_root_manifest)
	if not content_result.get("ok", false):
		return _stage_failure("directory_content_commitment", content_result)
	_root_commitment_receipt = content_result["receipt"]

	var unsigned_result: Dictionary = _ipns_adapter.create_unsigned(
		String(normalized["ipns_name"]),
		String(_root_commitment_receipt["cid_preview"]),
		0,
		int(normalized["ipns_ttl_ns"]),
		now_unix + int(normalized["ipns_validity_seconds"]),
		now_unix
	)
	if not unsigned_result.get("ok", false):
		return _stage_failure("ipns_record_prepare", unsigned_result)
	var signed_result: Dictionary = _ipns_adapter.simulate_sign(
		unsigned_result["unsigned"],
		String(normalized["signing_key_handle"])
	)
	if not signed_result.get("ok", false):
		return _stage_failure("ipns_record_sign", signed_result)
	_ipns_record = signed_result["record"]

	_initialized = true
	_redacted_receipt = {
		"component_id": COMPONENT_ID,
		"directory": {
			"epoch": int(normalized["epoch"]),
			"lobby_commitment": _commit(String(normalized["lobby_id"])),
			"member_count": normalized["accepted_member_ids"].size(),
			"relay_directory_commitment": directory_commitment,
		},
		"interface_mode": INTERFACE_MODE,
		"ipns": {
			"cryptography_performed": false,
			"name_commitment": _commit(String(normalized["ipns_name"])),
			"record_payload_commitment": String(_ipns_record["proof"].get("payload_commitment", "")),
		},
		"node_commitment": _commit(_node_id),
		"operation": "initialized",
		"publication": {
			"cid_is_live": false,
			"cid_preview": String(_root_commitment_receipt["cid_preview"]),
			"ipns_published": false,
			"network_calls_performed": false,
		},
		"raw_member_ids_exported": false,
		"raw_network_coordinates_persisted": false,
		"settings_schema": SETTINGS_SCHEMA,
		"signing_key_material_exported": false,
		"stages": [
			{"component_id": COMPONENT_ID, "stage": "settings_validated", "status": "simulated_ok"},
			{"component_id": RelayPeerDirectoryScript.COMPONENT_ID, "stage": "relay_directory_ready", "status": "simulated_ok"},
			{"component_id": IpfsCatalogReplicationScript.COMPONENT_ID, "stage": "catalog_replicator_ready", "status": "simulated_ok"},
			{"component_id": IpfsDagManifestScript.COMPONENT_ID, "stage": "directory_manifest_built", "status": "simulated_ok"},
			{"component_id": IpfsContentCommitmentScript.COMPONENT_ID, "stage": "content_committed", "status": "simulated_ok"},
			{"component_id": IpnsRecordAdapterScript.COMPONENT_ID, "stage": "ipns_record_prepared", "status": "simulated_ok"},
		],
	}
	return {"ok": true, "receipt": _redacted_receipt.duplicate(true)}


func validate_settings(settings: Dictionary) -> Dictionary:
	var safety := IpfsSafeValueScript.validate(settings, "$ipfs_settings", false)
	if not safety.get("ok", false):
		return _failure(String(safety.get("reason", "unsafe_ipfs_settings")))
	for key_value in settings.keys():
		if String(key_value) not in ALLOWED_SETTING_KEYS:
			return _failure("unknown_ipfs_setting_" + String(key_value))
	for required in [
		"accepted_member_ids",
		"epoch",
		"ipns_name",
		"lobby_id",
		"local_member_id",
		"local_peer_id",
		"node_id",
		"relay_peer_id",
		"schema",
		"signing_key_handle",
	]:
		if not settings.has(required):
			return _failure("missing_ipfs_setting_" + required)
	if String(settings.get("schema", "")) != SETTINGS_SCHEMA:
		return _failure("unsupported_ipfs_settings_schema")
	for string_field in ["ipns_name", "lobby_id", "local_member_id", "local_peer_id", "node_id", "relay_peer_id", "schema", "signing_key_handle"]:
		if not settings[string_field] is String:
			return _failure("ipfs_setting_must_be_string_" + string_field)
	if not settings["epoch"] is int:
		return _failure("ipfs_setting_must_be_integer_epoch")
	for optional_integer in ["ipns_ttl_ns", "ipns_validity_seconds", "peer_entry_ttl_seconds"]:
		if settings.has(optional_integer) and not settings[optional_integer] is int:
			return _failure("ipfs_setting_must_be_integer_" + optional_integer)
	if not settings.get("accepted_member_ids") is Array or settings["accepted_member_ids"].is_empty():
		return _failure("accepted_member_ids_required")
	if settings["accepted_member_ids"].size() > RelayPeerDirectoryScript.MAX_MEMBERS:
		return _failure("accepted_member_count_out_of_range")
	for member_value in settings["accepted_member_ids"]:
		if not member_value is String:
			return _failure("accepted_member_id_must_be_string")
	if settings.has("capabilities"):
		if not settings["capabilities"] is Array:
			return _failure("capabilities_must_be_array")
		for capability_value in settings["capabilities"]:
			if not capability_value is String:
				return _failure("capability_must_be_string")
	if String(settings["local_member_id"]) not in settings["accepted_member_ids"]:
		return _failure("local_member_must_be_accepted")
	if String(settings["local_peer_id"]) == String(settings["relay_peer_id"]):
		return _failure("relay_and_destination_peer_must_differ")

	var normalized := {
		"accepted_member_ids": settings["accepted_member_ids"].duplicate(true),
		"capabilities": settings.get("capabilities", ["catalog.read", "catalog.replicate", "lobby.presence"]),
		"epoch": int(settings["epoch"]),
		"ipns_name": String(settings["ipns_name"]),
		"ipns_ttl_ns": int(settings.get("ipns_ttl_ns", 5 * 60 * 1000000000)),
		"ipns_validity_seconds": int(settings.get("ipns_validity_seconds", 24 * 60 * 60)),
		"lobby_id": String(settings["lobby_id"]),
		"local_member_id": String(settings["local_member_id"]),
		"local_peer_id": String(settings["local_peer_id"]),
		"node_id": String(settings["node_id"]),
		"peer_entry_ttl_seconds": int(settings.get("peer_entry_ttl_seconds", 15 * 60)),
		"relay_peer_id": String(settings["relay_peer_id"]),
		"schema": SETTINGS_SCHEMA,
		"signing_key_handle": String(settings["signing_key_handle"]),
	}
	if int(normalized["epoch"]) < 1:
		return _failure("invalid_ipfs_epoch")
	if int(normalized["peer_entry_ttl_seconds"]) < 30 \
		or int(normalized["peer_entry_ttl_seconds"]) > RelayPeerDirectoryScript.MAX_ENTRY_LIFETIME_SECONDS:
		return _failure("peer_entry_ttl_out_of_range")
	if int(normalized["ipns_ttl_ns"]) < 1 or int(normalized["ipns_ttl_ns"]) > IpnsRecordAdapterScript.MAX_TTL_NS:
		return _failure("ipns_ttl_out_of_range")
	if int(normalized["ipns_validity_seconds"]) < 60 \
		or int(normalized["ipns_validity_seconds"]) > IpnsRecordAdapterScript.MAX_VALIDITY_WINDOW_SECONDS:
		return _failure("ipns_validity_out_of_range")
	# Component-level validators perform the final syntax and capability checks.
	var probe_directory := RelayPeerDirectoryScript.new()
	var probe_config := probe_directory.configure(
		String(normalized["lobby_id"]),
		normalized["accepted_member_ids"],
		int(normalized["epoch"])
	)
	if not probe_config.get("ok", false):
		return _stage_failure("settings_relay_scope", probe_config)
	var route := "/p2p/%s/p2p-circuit/p2p/%s" % [normalized["relay_peer_id"], normalized["local_peer_id"]]
	var probe_peer := probe_directory.upsert_peer(
		String(normalized["local_member_id"]),
		String(normalized["local_peer_id"]),
		[route],
		normalized["capabilities"],
		int(normalized["peer_entry_ttl_seconds"]),
		0
	)
	if not probe_peer.get("ok", false):
		return _stage_failure("settings_relay_peer", probe_peer)
	var ipns_probe := _ipns_settings_probe(normalized)
	if not ipns_probe.get("ok", false):
		return ipns_probe
	return {
		"ok": true,
		"normalized": normalized,
		"receipt": {
			"component_id": COMPONENT_ID,
			"interface_mode": INTERFACE_MODE,
			"lobby_commitment": _commit(String(normalized["lobby_id"])),
			"member_count": normalized["accepted_member_ids"].size(),
			"node_commitment": _commit(String(normalized["node_id"])),
			"settings_valid": true,
		},
	}


func get_redacted_receipt() -> Dictionary:
	return _redacted_receipt.duplicate(true)


func get_public_pointer() -> Dictionary:
	if not _initialized:
		return _failure("ipfs_stack_not_initialized")
	return {
		"ok": true,
		"cid_preview": String(_root_commitment_receipt.get("cid_preview", "")),
		"cid_is_live": false,
		"ipns_record": _ipns_record.duplicate(true),
		"published": false,
	}


func get_authorized_peer_directory(member_id: String, now_unix: int) -> Dictionary:
	if not _initialized:
		return _failure("ipfs_stack_not_initialized")
	return _relay_directory.export_for_member(member_id, now_unix)


func create_and_register_record(spec: Dictionary) -> Dictionary:
	if not _initialized:
		return _failure("ipfs_stack_not_initialized")
	var local_spec := spec.duplicate(true)
	if local_spec.has("origin_node_id") and String(local_spec["origin_node_id"]) != _node_id:
		return _failure("local_record_origin_override_rejected")
	local_spec["origin_node_id"] = _node_id
	var built: Dictionary = _replicator.create_catalog_record(local_spec)
	if not built.get("ok", false):
		return built
	var registered: Dictionary = _replicator.register_local_record(built["record"])
	if not registered.get("ok", false):
		return registered
	return {"ok": true, "record": built["record"], "catalog_size": registered["catalog_size"]}


func prepare_catalog_export(auth: Dictionary, signing_hook: Callable = Callable()) -> Dictionary:
	if not _initialized:
		return _failure("ipfs_stack_not_initialized")
	return _replicator.prepare_export(auth, signing_hook)


func ingest_catalog_package(package: Dictionary, auth: Dictionary) -> Dictionary:
	if not _initialized:
		return _failure("ipfs_stack_not_initialized")
	return _replicator.ingest_package(package, auth)


func query_catalog(auth: Dictionary, filters: Dictionary = {}) -> Dictionary:
	if not _initialized:
		return _failure("ipfs_stack_not_initialized")
	return _replicator.query(auth, filters)


func _ipns_settings_probe(settings: Dictionary) -> Dictionary:
	var placeholder_cid := "cid-sim-b" + "a".repeat(52)
	var adapter := IpnsRecordAdapterScript.new()
	var unsigned := adapter.create_unsigned(
		String(settings["ipns_name"]),
		placeholder_cid,
		0,
		int(settings["ipns_ttl_ns"]),
		int(settings["ipns_validity_seconds"]),
		0
	)
	if not unsigned.get("ok", false):
		return _stage_failure("settings_ipns_record", unsigned)
	var signed := adapter.simulate_sign(unsigned["unsigned"], String(settings["signing_key_handle"]))
	if not signed.get("ok", false):
		return _stage_failure("settings_ipns_key_handle", signed)
	return {"ok": true}


func _stage_failure(stage: String, result: Dictionary) -> Dictionary:
	return {
		"ok": false,
		"reason": String(result.get("reason", "stage_failed")),
		"stage": stage,
		"component_id": COMPONENT_ID,
	}


func _commit(value: String) -> String:
	return "sha256:" + IpfsSafeValueScript.sha256_text(value)


func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "component_id": COMPONENT_ID}
