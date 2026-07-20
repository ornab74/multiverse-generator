extends SceneTree

const CatalogScript = preload("res://systems/components/ipfs/ipfs_catalog_replication.gd")
const CommitmentScript = preload("res://systems/components/ipfs/ipfs_content_commitment.gd")
const CoordinatorScript = preload("res://systems/components/ipfs/ipfs_startup_coordinator.gd")
const DagScript = preload("res://systems/components/ipfs/ipfs_dag_manifest.gd")
const IpnsScript = preload("res://systems/components/ipfs/ipns_record_adapter.gd")
const RelayScript = preload("res://systems/components/ipfs/libp2p_relay_peer_directory.gd")
const SafetyScript = preload("res://systems/components/ipfs/ipfs_safe_value.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_dag_and_commitment()
	_test_ipns_records()
	_test_relay_directory()
	_test_catalog_replication()
	_test_startup_coordinator()
	if failures.is_empty():
		print("IPFS_COMPONENTS_TEST: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("IPFS_COMPONENTS_TEST: " + failure)
		quit(1)


func _test_dag_and_commitment() -> void:
	var dag = DagScript.new()
	var first := dag.build("world/catalog", {"zeta": 7, "alpha": "violet"}, [
		{"name": "rules", "cid": _placeholder_cid("b"), "role": "rules"},
		{"name": "assets", "cid": _placeholder_cid("c"), "role": "asset"},
	])
	var second := dag.build("world/catalog", {"alpha": "violet", "zeta": 7}, [
		{"role": "asset", "cid": _placeholder_cid("c"), "name": "assets"},
		{"role": "rules", "cid": _placeholder_cid("b"), "name": "rules"},
	])
	_expect(first.get("ok", false), "canonical DAG manifest was not built")
	_expect(second.get("ok", false), "equivalent DAG manifest was not built")
	if first.get("ok", false) and second.get("ok", false):
		_expect(first["canonical_text"] == second["canonical_text"], "map/link ordering changed canonical bytes")
		_expect(first["manifest"]["links"][0]["name"] == "assets", "manifest links were not canonically sorted")
		var commitment = CommitmentScript.new()
		var receipt := commitment.commit_manifest(first["manifest"])
		_expect(receipt.get("ok", false), "manifest commitment failed")
		if receipt.get("ok", false):
			_expect(not receipt["receipt"]["cid_is_live"], "preview CID was marked live")
			_expect(String(receipt["receipt"]["cid_preview"]).begins_with("cid-sim-b"), "preview CID lacks simulation namespace")
			_expect(commitment.verify_manifest(first["manifest"], receipt["receipt"]).get("ok", false), "manifest commitment did not verify")
			var tampered: Dictionary = first["manifest"].duplicate(true)
			tampered["root"]["zeta"] = 8
			_expect(not commitment.verify_manifest(tampered, receipt["receipt"]).get("ok", true), "tampered manifest verified")
	var unsafe := dag.build("world/catalog", {"endpoint": "10.0.0.4"})
	_expect(not unsafe.get("ok", true), "raw IPv4 entered a DAG manifest")
	var non_canonical_float := dag.build("world/catalog", {"ratio": 0.5})
	_expect(not non_canonical_float.get("ok", true), "float entered canonical interface encoding")


func _test_ipns_records() -> void:
	var adapter = IpnsScript.new()
	var name := "k51qzi5uqu5dabcdef1234567890"
	var cid := _placeholder_cid("d")
	var first_unsigned := adapter.create_unsigned(name, cid, 4, 60000000000, 2000, 1000)
	var next_unsigned := adapter.create_unsigned(name, cid, 5, 60000000000, 2000, 1001)
	_expect(first_unsigned.get("ok", false) and next_unsigned.get("ok", false), "IPNS unsigned record creation failed")
	if not first_unsigned.get("ok", false) or not next_unsigned.get("ok", false):
		return
	var first := adapter.simulate_sign(first_unsigned["unsigned"], "kh_ipns_test_device")
	var next := adapter.simulate_sign(next_unsigned["unsigned"], "kh_ipns_test_device")
	_expect(first.get("ok", false) and next.get("ok", false), "IPNS simulation signing failed")
	if not first.get("ok", false) or not next.get("ok", false):
		return
	var verified := adapter.verify_record(first["record"], 1500)
	_expect(verified.get("ok", false), "valid IPNS simulation record failed verification")
	_expect(not verified.get("cryptographic_signature_verified", true), "simulation signature claimed cryptographic verification")
	_expect(adapter.select_newer(first["record"], next["record"], 1500).get("ok", false), "monotonic IPNS update was rejected")
	_expect(not adapter.select_newer(next["record"], first["record"], 1500).get("ok", true), "IPNS replay sequence was accepted")
	_expect(not adapter.verify_record(first["record"], 2000).get("ok", true), "expired IPNS record verified")
	var tampered: Dictionary = first["record"].duplicate(true)
	tampered["proof"]["signature"] = "simsig:tampered"
	_expect(not adapter.verify_record(tampered, 1500).get("ok", true), "tampered IPNS simulation proof verified")

	var external := adapter.sign_with_adapter(first_unsigned["unsigned"], Callable(self, "_mock_ipns_signer"))
	_expect(external.get("ok", false), "IPNS external signer boundary failed")
	if external.get("ok", false):
		_expect(not adapter.verify_record(external["record"], 1500).get("ok", true), "external IPNS proof verified without adapter")
		_expect(adapter.verify_record(external["record"], 1500, Callable(self, "_mock_ipns_verifier")).get("ok", false), "external IPNS verifier boundary failed")


func _test_relay_directory() -> void:
	var directory = RelayScript.new()
	var configured := directory.configure("lobby-violet", ["member-q7", "member-vx"], 3)
	_expect(configured.get("ok", false), "relay directory configuration failed")
	var route := "/p2p/12D3KooWRelayAlpha/p2p-circuit/p2p/12D3KooWLocalOmega"
	var inserted := directory.upsert_peer(
		"member-q7",
		"12D3KooWLocalOmega",
		[route],
		["catalog.read", "lobby.sync"],
		1900,
		1000
	)
	_expect(inserted.get("ok", false), "relay-only peer route was rejected")
	var visible := directory.export_for_member("member-vx", 1200)
	_expect(visible.get("ok", false), "accepted member could not read relay directory")
	_expect(not directory.export_for_member("member-outsider", 1200).get("ok", true), "outsider read relay directory")
	if visible.get("ok", false):
		var serialized := JSON.stringify(visible)
		_expect("member-q7" not in serialized and "member-vx" not in serialized, "raw membership leaked from directory")
		_expect("ip4" not in serialized and "ip6" not in serialized, "direct network coordinate leaked from directory")
	var direct_ip := directory.upsert_peer(
		"member-q7",
		"12D3KooWOtherPeer",
		["/ip4/10.1.1.2/tcp/4001/p2p/12D3KooWOtherPeer"],
		["catalog.read"],
		1900,
		1000
	)
	_expect(not direct_ip.get("ok", true), "direct IP multiaddr entered relay directory")
	var direct_peer := directory.upsert_peer(
		"member-q7",
		"12D3KooWOtherPeer",
		["/p2p/12D3KooWOtherPeer"],
		["catalog.read"],
		1900,
		1000
	)
	_expect(not direct_peer.get("ok", true), "non-circuit peer route entered relay directory")
	var rotated := directory.rotate_epoch("member-q7", ["member-q7"], 4)
	_expect(rotated.get("ok", false), "relay directory epoch rotation failed")
	var after_rotation := directory.export_for_member("member-q7", 1200)
	if after_rotation.get("ok", false):
		_expect(after_rotation["directory"]["peers"].is_empty(), "old peer routes survived epoch rotation")


func _test_catalog_replication() -> void:
	var local = CatalogScript.new()
	var configured := local.configure("node-local", Callable(self, "_allow_all_hook"))
	_expect(configured.get("ok", false), "catalog replicator configuration failed")
	var cid := _placeholder_cid("e")
	var digest := "sha256:" + SafetyScript.sha256_text("catalog-content")
	var public_record := local.create_catalog_record({
		"sequence": 1,
		"kind": "world_manifest",
		"tier": "public",
		"cid": cid,
		"content_commitment": digest,
	})
	var lobby_record := local.create_catalog_record({
		"sequence": 2,
		"kind": "lobby_snapshot",
		"tier": "lobby",
		"cid": cid,
		"content_commitment": digest,
		"lobby_id": "lobby-violet",
		"member_ids": ["member-q7", "member-vx"],
	})
	var private_record := local.create_catalog_record({
		"sequence": 3,
		"kind": "dm_pointer",
		"tier": "private",
		"cid": cid,
		"content_commitment": digest,
		"owner_id": "member-q7",
		"reader_ids": ["member-vx"],
	})
	for pair in [public_record, lobby_record, private_record]:
		_expect(pair.get("ok", false), "catalog record build failed")
		if pair.get("ok", false):
			_expect(local.register_local_record(pair["record"]).get("ok", false), "catalog record registration failed")
	var secret := local.create_catalog_record({
		"sequence": 4,
		"kind": "device_secret",
		"tier": "secret",
		"cid": cid,
		"content_commitment": digest,
	})
	_expect(not secret.get("ok", true), "secret record entered replication catalog")
	var unsafe := local.create_catalog_record({
		"sequence": 4,
		"kind": "endpoint",
		"tier": "public",
		"cid": cid,
		"content_commitment": digest,
		"relay": "172.16.1.4",
	})
	_expect(not unsafe.get("ok", true), "raw IP entered catalog record spec")

	var outsider := local.query({"member_id": "member-outsider"})
	var lobby_member := local.query({"member_id": "member-vx", "lobby_ids": ["lobby-violet"]})
	_expect(_tier_count(outsider.get("records", []), "public") == 1, "outsider did not receive exactly the public record")
	_expect(outsider.get("records", []).size() == 1, "built-in policy allowed hook to widen outsider access")
	_expect(_tier_count(lobby_member.get("records", []), "lobby") == 1, "lobby member could not see lobby record")
	_expect(_tier_count(lobby_member.get("records", []), "private") == 1, "explicit private reader could not see record")
	var export := local.prepare_export({"member_id": "member-vx", "lobby_ids": ["lobby-violet"]})
	_expect(export.get("ok", false), "authorized catalog export failed")
	if export.get("ok", false):
		var serialized_export := JSON.stringify(export["package"])
		_expect("member-vx" not in serialized_export and "lobby-violet" not in serialized_export, "raw access identities leaked into export")
		_expect("dm_pointer" in serialized_export, "authorized private pointer was absent from export")

	var remote = CatalogScript.new()
	remote.configure("node-remote")
	var remote_record := remote.create_catalog_record({
		"sequence": 1,
		"kind": "remote_world",
		"tier": "public",
		"cid": _placeholder_cid("f"),
		"content_commitment": "sha256:" + SafetyScript.sha256_text("remote-content"),
	})
	if remote_record.get("ok", false):
		remote.register_local_record(remote_record["record"])
	var remote_export := remote.prepare_export({"member_id": "member-outsider"})
	_expect(remote_export.get("ok", false), "remote catalog export failed")
	if remote_export.get("ok", false):
		var ingested := local.ingest_package(remote_export["package"], {"member_id": "member-outsider"})
		_expect(ingested.get("ok", false) and ingested.get("accepted", 0) == 1, "authorized remote package was not ingested")
		var remote_query := local.query({"member_id": "member-outsider"}, {"origin_node_id": "node-remote"})
		_expect(remote_query.get("records", []).size() == 1, "replicated remote catalog was not queryable")
		var tampered: Dictionary = remote_export["package"].duplicate(true)
		tampered["unsigned"]["package_sequence"] = 999
		_expect(not local.ingest_package(tampered, {"member_id": "member-outsider"}).get("ok", true), "tampered catalog package was ingested")


func _test_startup_coordinator() -> void:
	var settings := {
		"schema": CoordinatorScript.SETTINGS_SCHEMA,
		"node_id": "node-q7-primary",
		"lobby_id": "lobby-violet",
		"accepted_member_ids": ["member-q7", "member-vx"],
		"local_member_id": "member-q7",
		"local_peer_id": "12D3KooWLocalOmega",
		"relay_peer_id": "12D3KooWRelayAlpha",
		"epoch": 1,
		"ipns_name": "k51qzi5uqu5dabcdef1234567890",
		"signing_key_handle": "kh_ipns_device_primary",
		"capabilities": ["catalog.read", "catalog.replicate", "lobby.presence"],
	}
	var unsafe_settings := settings.duplicate(true)
	unsafe_settings["relay_peer_id"] = "10.2.3.4"
	_expect(not CoordinatorScript.new().initialize(unsafe_settings, 1000).get("ok", true), "startup accepted raw IP setting")

	var coordinator = CoordinatorScript.new()
	var initialized := coordinator.initialize(settings, 1000)
	_expect(initialized.get("ok", false), "settings-driven IPFS startup failed: " + String(initialized.get("reason", "")))
	if not initialized.get("ok", false):
		return
	var receipt_text := JSON.stringify(initialized["receipt"])
	for raw_value in ["node-q7-primary", "lobby-violet", "member-q7", "member-vx", "12D3KooWLocalOmega", "12D3KooWRelayAlpha", "kh_ipns_device_primary"]:
		_expect(raw_value not in receipt_text, "startup receipt leaked redacted value: " + raw_value)
	_expect(String(initialized["receipt"].get("component_id", "")) == CoordinatorScript.COMPONENT_ID, "startup receipt missing stable component ID")
	_expect(String(initialized["receipt"].get("interface_mode", "")) == CoordinatorScript.INTERFACE_MODE, "startup receipt missing simulation label")
	_expect(not initialized["receipt"]["publication"]["network_calls_performed"], "startup receipt claimed a network call")
	var authorized_directory := coordinator.get_authorized_peer_directory("member-vx", 1100)
	_expect(authorized_directory.get("ok", false), "startup directory unavailable to accepted member")
	_expect(not coordinator.get_authorized_peer_directory("member-outsider", 1100).get("ok", true), "startup directory leaked to outsider")
	var pointer := coordinator.get_public_pointer()
	_expect(pointer.get("ok", false) and not pointer.get("published", true), "startup public pointer claimed publication")


func _mock_ipns_signer(_payload: PackedByteArray, _unsigned: Dictionary) -> Dictionary:
	return {
		"ok": true,
		"algorithm": "test-signature-adapter",
		"signature": "adapter-signature-placeholder",
		"signer_key_id": "adapter-key-01",
	}


func _mock_ipns_verifier(_payload: PackedByteArray, proof: Dictionary) -> Dictionary:
	return {
		"ok": true,
		"valid": String(proof.get("signature", "")) == "adapter-signature-placeholder",
	}


func _allow_all_hook(_operation: String, _record: Dictionary, _auth: Dictionary) -> bool:
	return true


func _placeholder_cid(character: String) -> String:
	return "cid-sim-b" + character.repeat(52)


func _tier_count(records: Array, tier: String) -> int:
	var count := 0
	for record in records:
		if String(record.get("tier", "")) == tier:
			count += 1
	return count


func _expect(condition: bool, failure: String) -> void:
	if not condition:
		failures.append(failure)
