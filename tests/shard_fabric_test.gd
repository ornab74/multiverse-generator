extends SceneTree

const ShardFabricScript = preload("res://systems/shard_fabric.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var fabric: ShardFabric = ShardFabricScript.new()
	var initialized := fabric.initialize({
		"device_alias": "test-forge",
		"simulation_seed": "deterministic-shard-fabric-test",
	})
	_expect(initialized.get("ok", false), "fabric initialization failed")
	_expect(fabric.state == ShardFabric.InitState.READY, "fabric did not reach ready")

	var expected_states: Array[String] = [
		"device_identity",
		"ml_kem_768_capability",
		"libp2p_relay_peer_id",
		"ipfs_ipns_directory",
		"hive_commitment",
		"solana_pda_commitment",
		"ready",
	]
	var actual_states: Array[String] = []
	for step in fabric.get_initialization_trace():
		actual_states.append(String(step.get("name", "")))
	_expect(actual_states == expected_states, "initialization states were out of order")
	for receipt in fabric.get_adapter_receipts():
		_expect(
			String(receipt.get("interface_mode", "")) == ShardFabric.INTERFACE_SIMULATION,
			"adapter output was not labeled as an interface simulation"
		)
		_expect(String(receipt.get("status", "")) == "simulated", "adapter status implied a live integration")

	var lobby_key := fabric.ensure_lobby_epoch_key("lobby-lattice", 4, ["peer-alpha", "peer-gamma"])
	var dm_key := fabric.ensure_dm_key("peer-beta")
	var content_key := fabric.ensure_content_key("ruleset-v9", ShardFabric.DataTier.PRIVATE)
	_expect(lobby_key.get("ok", false), "lobby epoch key handle was not created")
	_expect(dm_key.get("ok", false), "DM key handle was not created")
	_expect(content_key.get("ok", false), "content key handle was not created")
	var key_kinds: Array[String] = []
	for manifest in fabric.get_key_hierarchy_manifest():
		key_kinds.append(String(manifest.get("kind", "")))
		_expect(not manifest.has("material"), "key manifest exported simulated secret material")
		_expect(bool(manifest.get("non_exportable", false)), "key handle was marked exportable")
	for expected_kind in ["root", "device", "lobby_epoch", "dm", "content"]:
		_expect(expected_kind in key_kinds, "missing key hierarchy kind: " + expected_kind)

	var public_result := fabric.publish_record("world_manifest", {
		"title": "Violet Mycelium",
		"rules_commitment": "sha256:public-rule-commitment",
	}, ShardFabric.DataTier.PUBLIC)
	var lobby_result := fabric.publish_record("lobby_rule_proposal", {
		"proposal_commitment": "sha256:lobby-proposal",
		"asset_manifest_cid": "bafy-protected-assets",
	}, ShardFabric.DataTier.LOBBY, {
		"lobby_id": "lobby-lattice",
		"member_peer_ids": ["peer-alpha", "peer-gamma"],
		"epoch": 4,
	})
	var private_result := fabric.publish_record("private_profile_pointer", {
		"ciphertext_cid": "bafy-private-profile",
	}, ShardFabric.DataTier.PRIVATE, {
		"owner_peer_id": "peer-alpha",
		"reader_peer_ids": ["peer-beta"],
	})
	var secret_result := fabric.publish_record("device_recovery_policy", {
		"policy_commitment": "sha256:device-only",
	}, ShardFabric.DataTier.SECRET, {
		"owner_device_id": fabric.get_device_id(),
	})
	_expect(public_result.get("ok", false), "public record was rejected")
	_expect(lobby_result.get("ok", false), "lobby record was rejected")
	_expect(private_result.get("ok", false), "private record was rejected")
	_expect(secret_result.get("ok", false), "secret record was rejected")
	_expect(lobby_result["record"].has("envelope"), "lobby payload was not converted to an envelope")
	_expect(not lobby_result["record"].has("payload"), "lobby plaintext remained in the catalog")
	_expect(private_result["record"].has("envelope"), "private payload was not converted to an envelope")
	_expect(secret_result["record"]["propagation"] == "device_local_no_replication", "secret record could propagate")

	var friend_result := fabric.commit_friend_edge("peer-friend", "accepted")
	var peer_bucket_result := fabric.publish_lobby_peer_bucket(
		"lobby-lattice",
		["12D3KooWrelay-one", "12D3KooWrelay-two"],
		["peer-alpha", "peer-gamma"],
		4
	)
	var dm_pointer_result := fabric.publish_dm_ciphertext_pointer("peer-beta", "bafy-encrypted-dm", "peer-alpha")
	_expect(friend_result.get("ok", false), "friend edge commitment failed")
	_expect(peer_bucket_result.get("ok", false), "relay-only peer bucket failed")
	_expect(dm_pointer_result.get("ok", false), "DM ciphertext pointer failed")

	var rejected_ip := fabric.publish_record("unsafe_endpoint", {"relay": "10.24.3.9"}, ShardFabric.DataTier.PUBLIC)
	var rejected_ipv6 := fabric.publish_record("unsafe_endpoint_v6", {"relay": "fd00:1:2::9"}, ShardFabric.DataTier.PUBLIC)
	var rejected_private_key := fabric.publish_record("unsafe_key", {"private_key": "must-never-land"}, ShardFabric.DataTier.PRIVATE, {
		"owner_peer_id": "peer-alpha",
	})
	var rejected_dm := fabric.publish_record("unsafe_dm", {"body": "plaintext must never land"}, ShardFabric.DataTier.PRIVATE, {
		"owner_peer_id": "peer-alpha",
	})
	var rejected_bucket_ip := fabric.publish_lobby_peer_bucket(
		"lobby-lattice",
		["192.168.1.10"],
		["peer-alpha"],
		4
	)
	_expect(not rejected_ip.get("ok", true), "raw IPv4 literal entered the catalog")
	_expect(not rejected_ipv6.get("ok", true), "raw IPv6 literal entered the catalog")
	_expect(not rejected_private_key.get("ok", true), "private key entered the catalog")
	_expect(not rejected_dm.get("ok", true), "plaintext DM entered the catalog")
	_expect(not rejected_bucket_ip.get("ok", true), "raw lobby IP entered a peer bucket")

	var outsider_records := fabric.upcycle_query({}, {"peer_id": "peer-outsider"})
	_expect(_only_tier(outsider_records, "public"), "outsider observed protected local data")
	var lobby_member_records := fabric.upcycle_query({}, {
		"peer_id": "peer-gamma",
		"lobby_ids": ["lobby-lattice"],
	})
	_expect(_has_tier(lobby_member_records, "lobby"), "accepted lobby member could not see lobby envelopes")
	_expect(not _has_tier(lobby_member_records, "private"), "lobby membership leaked private data")
	var owner_records := fabric.upcycle_query({}, {
		"peer_id": "peer-alpha",
		"lobby_ids": ["lobby-lattice"],
	})
	_expect(_has_tier(owner_records, "private"), "explicit private owner could not see private envelope")
	_expect(not _has_tier(owner_records, "secret"), "secret data leaked without device capability")
	var device_records := fabric.upcycle_query({}, {
		"device_id": fabric.get_device_id(),
		"include_secret": true,
	})
	_expect(_has_tier(device_records, "secret"), "device-bound secret was not visible to its device")

	var remote: ShardFabric = ShardFabricScript.new()
	remote.initialize({"device_alias": "remote-forge", "simulation_seed": "remote-test-seed"})
	remote.publish_record("remote_world_manifest", {"title": "Ember Archive"}, ShardFabric.DataTier.PUBLIC)
	remote.publish_record("remote_lobby_state", {"state_commitment": "sha256:remote-lobby"}, ShardFabric.DataTier.LOBBY, {
		"lobby_id": "remote-lobby",
		"member_peer_ids": ["remote-member"],
		"epoch": 2,
	})
	var remote_export := remote.export_catalog_for_replication({
		"peer_id": "remote-member",
		"lobby_ids": ["remote-lobby"],
	})
	var upcycled := fabric.upcycle_catalog({remote.get_node_id(): remote_export}, {"peer_id": "peer-outsider"})
	_expect(upcycled.get("ok", false), "remote catalog upcycle failed")
	_expect(_contains_kind(upcycled.get("records", []), "remote_world_manifest"), "authorized remote public record was absent")
	_expect(not _contains_kind(upcycled.get("records", []), "remote_lobby_state"), "remote lobby record leaked to outsider")
	var remote_member_view := fabric.upcycle_query({}, {
		"peer_id": "remote-member",
		"lobby_ids": ["remote-lobby"],
	})
	_expect(_contains_kind(remote_member_view, "remote_lobby_state"), "authorized remote lobby record was filtered out")
	var repeated_registration := fabric.register_remote_catalog(remote.get_node_id(), remote_export)
	_expect(repeated_registration.get("accepted", -1) == 0, "duplicate remote records were accepted twice")
	_expect(
		_contains_kind(fabric.upcycle_query({}, {"peer_id": "peer-outsider"}), "remote_world_manifest"),
		"duplicate registration erased the last known-good remote catalog"
	)
	var filtered_remote := fabric.upcycle_query({"kind": "remote_world_manifest"}, {"peer_id": "peer-outsider"})
	_expect(filtered_remote.size() == 1, "cross-node kind filter was not deterministic")

	var serialized_snapshot := JSON.stringify(fabric.get_public_snapshot())
	var serialized_catalog := JSON.stringify(fabric.upcycle_query({}, {
		"peer_id": "peer-alpha",
		"lobby_ids": ["lobby-lattice"],
	}))
	for forbidden_value in ["10.24.3.9", "must-never-land", "plaintext must never land", "bafy-private-profile"]:
		_expect(forbidden_value not in serialized_snapshot, "sensitive input leaked into snapshot: " + forbidden_value)
		_expect(forbidden_value not in serialized_catalog, "sensitive input leaked into catalog: " + forbidden_value)

	fabric.clear_volatile_secrets()
	var after_clear := fabric.publish_record("protected_after_clear", {"commitment": "sha256:x"}, ShardFabric.DataTier.PRIVATE, {
		"owner_peer_id": "peer-alpha",
	})
	_expect(not after_clear.get("ok", true), "protected publishing survived volatile key clearing")

	if failures.is_empty():
		print("SHARD_FABRIC_TEST: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("SHARD_FABRIC_TEST: " + failure)
		quit(1)


func _expect(condition: bool, failure: String) -> void:
	if not condition:
		failures.append(failure)


func _only_tier(records: Array, tier: String) -> bool:
	for record in records:
		if String(record.get("tier", "")) != tier:
			return false
	return true


func _has_tier(records: Array, tier: String) -> bool:
	for record in records:
		if String(record.get("tier", "")) == tier:
			return true
	return false


func _contains_kind(records: Array, kind: String) -> bool:
	for record in records:
		if String(record.get("kind", "")) == kind:
			return true
	return false
