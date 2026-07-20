extends SceneTree

const HiveComponent = preload("res://systems/components/hive_commitment_component.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var config := {
		"network_label": "hive-interface",
		"custom_json_id": "nexus.shard.commitment.v1",
		"authority_policy": {
			"qseven-forge": ["posting", "active"],
			"vexel-forge": ["posting"],
		},
	}
	var producer: HiveCommitmentComponent = HiveComponent.new()
	var initialized := producer.initialize(config)
	_expect(initialized.get("ok", false), "valid Hive component configuration was rejected")
	_expect(
		String(initialized.get("snapshot", {}).get("component_id", "")) == HiveComponent.COMPONENT_ID,
		"stable Hive component ID was missing"
	)
	_expect(
		String(initialized.get("snapshot", {}).get("interface_mode", "")) == HiveComponent.INTERFACE_MODE,
		"Hive snapshot was not labeled as simulation"
	)
	_expect(not initialized["snapshot"]["live_rpc_configured"], "Hive snapshot implied live RPC")
	_expect(not initialized["snapshot"]["signing_available"], "Hive snapshot implied signing")
	_expect("qseven-forge" not in JSON.stringify(initialized["snapshot"]), "Hive snapshot exposed authority identity")
	_expect("qseven-forge" not in JSON.stringify(initialized["receipt"]), "Hive init receipt exposed authority identity")

	var first_commitment := _commitment_record("alpha", 1)
	var first := producer.prepare_commitment(first_commitment, {
		"account": "qseven-forge",
		"permission": "posting",
		"nonce": 1,
	})
	_expect(first.get("ok", false), "first Hive commitment did not build")
	_expect(String(first.get("component_id", "")) == HiveComponent.COMPONENT_ID, "prepared Hive result lacked component ID")
	_expect(first["operation"]["required_auths"].is_empty(), "posting operation requested active authority")
	_expect(first["operation"]["required_posting_auths"] == ["qseven-forge"], "posting authority was not bound")
	_expect(not first["receipt"]["signing_performed"], "Hive receipt claimed a signature")
	_expect(not first["receipt"]["broadcast_performed"], "Hive receipt claimed a broadcast")
	_expect(not first["receipt"]["live_rpc_used"], "Hive receipt claimed live RPC")
	_expect("qseven-forge" not in JSON.stringify(first["receipt"]), "Hive receipt exposed authority identity")
	_expect(
		String(first["envelope"]["envelope_commitment"]).begins_with("sha256:"),
		"Hive envelope did not carry its commitment"
	)

	var repeated_outbound := producer.prepare_commitment(first_commitment, {
		"account": "qseven-forge",
		"permission": "posting",
		"nonce": 1,
	})
	_expect(not repeated_outbound.get("ok", true), "outbound Hive nonce replay was accepted")
	_expect(String(repeated_outbound.get("error", "")).contains("nonce_replay"), "outbound replay reason was not explicit")
	var outbound_gap := producer.prepare_commitment(_commitment_record("gap", 3), {
		"account": "qseven-forge",
		"permission": "posting",
		"nonce": 3,
	})
	_expect(not outbound_gap.get("ok", true), "outbound Hive nonce gap was accepted")
	_expect(String(outbound_gap.get("error", "")).contains("nonce_gap"), "outbound nonce gap reason was not explicit")

	var second_commitment := _commitment_record("beta", 2)
	second_commitment["previous_commitment"] = first["envelope"]["envelope_commitment"]
	second_commitment["epoch"] = 2
	var second := producer.prepare_commitment(second_commitment, {
		"account": "qseven-forge",
		"permission": "posting",
		"nonce": 2,
	})
	_expect(second.get("ok", false), "second sequential Hive commitment did not build")

	var active := producer.prepare_commitment(_commitment_record("active", 1), {
		"account": "qseven-forge",
		"permission": "active",
		"nonce": 1,
	})
	_expect(active.get("ok", false), "allowed active authority could not build")
	_expect(active["operation"]["required_auths"] == ["qseven-forge"], "active authority was not bound")
	_expect(active["operation"]["required_posting_auths"].is_empty(), "active operation also requested posting authority")

	var verifier: HiveCommitmentComponent = HiveComponent.new()
	_expect(verifier.initialize(config).get("ok", false), "Hive verifier initialization failed")
	var accepted_first := verifier.validate_custom_json_operation(first["operation"])
	_expect(accepted_first.get("ok", false), "valid inbound Hive operation was rejected")
	_expect(not accepted_first["signature_verified"], "interface validator claimed signature verification")
	var replayed_first := verifier.validate_custom_json_operation(first["operation"])
	_expect(not replayed_first.get("ok", true), "inbound Hive replay was accepted")
	_expect(String(replayed_first.get("error", "")).contains("nonce_replay"), "inbound replay reason was not explicit")
	_expect(verifier.validate_custom_json_operation(second["operation"]).get("ok", false), "linked second Hive operation was rejected")

	var preview_verifier: HiveCommitmentComponent = HiveComponent.new()
	preview_verifier.initialize(config)
	var preview := preview_verifier.validate_custom_json_operation(first["operation"], false)
	_expect(preview.get("ok", false), "non-consuming Hive validation failed")
	_expect(not preview.get("nonce_consumed", true), "non-consuming Hive validation consumed replay state")
	_expect(
		preview_verifier.validate_custom_json_operation(first["operation"]).get("ok", false),
		"non-consuming Hive validation still mutated replay state"
	)

	var gap_verifier: HiveCommitmentComponent = HiveComponent.new()
	gap_verifier.initialize(config)
	var inbound_gap := gap_verifier.validate_custom_json_operation(second["operation"])
	_expect(not inbound_gap.get("ok", true), "inbound Hive nonce gap was accepted")

	var tampered_authority_operation: Dictionary = first["operation"].duplicate(true)
	tampered_authority_operation["required_posting_auths"] = []
	var authority_tamper_result := gap_verifier.validate_custom_json_operation(tampered_authority_operation)
	_expect(not authority_tamper_result.get("ok", true), "Hive operation authority substitution was accepted")

	var tampered_payload_operation: Dictionary = first["operation"].duplicate(true)
	var parsed_envelope: Dictionary = JSON.parse_string(String(tampered_payload_operation["json"]))
	parsed_envelope["commitment"]["content_commitment"] = _hash_commitment("tampered")
	tampered_payload_operation["json"] = JSON.stringify(parsed_envelope)
	var payload_tamper_result := gap_verifier.validate_custom_json_operation(tampered_payload_operation)
	_expect(not payload_tamper_result.get("ok", true), "tampered Hive commitment payload was accepted")
	_expect(
		String(payload_tamper_result.get("error", "")) == "envelope_commitment_mismatch",
		"tampered Hive payload did not fail its envelope commitment"
	)

	var wrong_id_operation: Dictionary = first["operation"].duplicate(true)
	wrong_id_operation["id"] = "nexus.other.contract"
	_expect(
		not gap_verifier.validate_custom_json_operation(wrong_id_operation).get("ok", true),
		"wrong Hive custom_json ID was accepted"
	)

	var unauthorized := producer.prepare_commitment(_commitment_record("unauthorized", 1), {
		"account": "unknown-forge",
		"permission": "posting",
		"nonce": 1,
	})
	_expect(not unauthorized.get("ok", true), "unconfigured Hive authority was accepted")
	var elevated := producer.prepare_commitment(_commitment_record("elevated", 1), {
		"account": "vexel-forge",
		"permission": "active",
		"nonce": 1,
	})
	_expect(not elevated.get("ok", true), "unconfigured Hive authority level was accepted")

	var raw_social_data := _commitment_record("social", 9)
	raw_social_data["friend_list"] = ["alice", "bob"]
	_expect(
		not producer.prepare_commitment(raw_social_data, {
			"account": "vexel-forge", "permission": "posting", "nonce": 1,
		}).get("ok", true),
		"plaintext friend list entered a Hive commitment"
	)
	var raw_ip := _commitment_record("raw-ip", 9)
	raw_ip["record_id"] = "lobby:192.168.4.12"
	_expect(
		not producer.prepare_commitment(raw_ip, {
			"account": "vexel-forge", "permission": "posting", "nonce": 1,
		}).get("ok", true),
		"raw IP entered a Hive commitment"
	)

	var unsafe_config: HiveCommitmentComponent = HiveComponent.new()
	_expect(
		not unsafe_config.initialize({
			"network_label": "hive-interface",
			"custom_json_id": "nexus.shard.commitment.v1",
			"authority_policy": {"qseven-forge": ["posting"]},
			"private_key": "must-never-enter",
		}).get("ok", true),
		"Hive component accepted a private key field"
	)
	var rpc_config: HiveCommitmentComponent = HiveComponent.new()
	_expect(
		not rpc_config.initialize({
			"network_label": "hive-interface",
			"custom_json_id": "nexus.shard.commitment.v1",
			"authority_policy": {"qseven-forge": ["posting"]},
			"rpc_url": "https://example.invalid",
		}).get("ok", true),
		"Hive component accepted a live RPC field"
	)

	var replay_snapshot := verifier.get_replay_snapshot()
	_expect(String(replay_snapshot.get("component_id", "")) == HiveComponent.COMPONENT_ID, "Hive replay snapshot lacked component ID")
	_expect("qseven-forge" not in JSON.stringify(replay_snapshot), "Hive replay snapshot exposed authority identity")

	if failures.is_empty():
		print("HIVE_COMMITMENT_COMPONENT_TEST: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("HIVE_COMMITMENT_COMPONENT_TEST: " + failure)
		quit(1)


func _commitment_record(label: String, sequence: int) -> Dictionary:
	return {
		"record_id": "rec_" + _digest("record-" + label).substr(0, 32),
		"record_kind": "shard_directory_commitment",
		"directory_cid": "bafy" + _digest("directory-" + label).substr(0, 52),
		"content_commitment": _hash_commitment("content-" + label),
		"sequence": sequence,
		"visibility": "commitment_only",
		"timestamp_bucket": 4072,
	}


func _hash_commitment(value: String) -> String:
	return "sha256:" + _digest(value)


func _digest(value: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(value.to_utf8_buffer())
	return context.finish().hex_encode()


func _expect(condition: bool, failure: String) -> void:
	if not condition:
		failures.append(failure)
