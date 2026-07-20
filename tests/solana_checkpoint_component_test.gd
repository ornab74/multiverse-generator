extends SceneTree

const SolanaComponent = preload("res://systems/components/solana_checkpoint_component.gd")
const PROGRAM_ID := "NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN"
const AUTHORITY_ID := "QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
const OTHER_AUTHORITY_ID := "RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR"

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var config := {
		"network_label": "solana-interface",
		"program_id": PROGRAM_ID,
		"authority_policy": {
			AUTHORITY_ID: ["checkpoint_writer"],
			OTHER_AUTHORITY_ID: ["checkpoint_admin"],
		},
	}
	var producer: SolanaCheckpointComponent = SolanaComponent.new()
	var initialized := producer.initialize(config)
	_expect(initialized.get("ok", false), "valid Solana component configuration was rejected")
	_expect(
		String(initialized.get("snapshot", {}).get("component_id", "")) == SolanaComponent.COMPONENT_ID,
		"stable Solana component ID was missing"
	)
	_expect(
		String(initialized.get("snapshot", {}).get("interface_mode", "")) == SolanaComponent.INTERFACE_MODE,
		"Solana snapshot was not labeled as simulation"
	)
	_expect(not initialized["snapshot"]["live_rpc_configured"], "Solana snapshot implied live RPC")
	_expect(not initialized["snapshot"]["signing_available"], "Solana snapshot implied signing")

	var shard_commitment := _hash_commitment("violet-mycelium")
	var pda_first := producer.derive_checkpoint_pda(shard_commitment)
	var pda_repeat := producer.derive_checkpoint_pda(shard_commitment)
	var pda_other := producer.derive_checkpoint_pda(_hash_commitment("ember-archive"))
	_expect(pda_first.get("ok", false), "simulated PDA derivation failed")
	_expect(pda_first["address"] == pda_repeat["address"], "simulated PDA derivation was nondeterministic")
	_expect(pda_first["address"] != pda_other["address"], "different shard commitments shared a PDA")
	_expect(not pda_first["curve_check_performed"], "simulated PDA claimed a curve check")
	_expect(pda_first["production_pda_derivation_required"], "simulated PDA was not marked for replacement")

	var first_checkpoint := _checkpoint("first", shard_commitment, 1)
	var first := producer.prepare_commitment(first_checkpoint, {
		"public_key": AUTHORITY_ID,
		"capability": "checkpoint_writer",
		"nonce": 1,
	})
	_expect(first.get("ok", false), "first Solana checkpoint did not build")
	_expect(String(first.get("component_id", "")) == SolanaComponent.COMPONENT_ID, "prepared Solana result lacked component ID")
	_expect(first["instruction"]["accounts"].size() == 3, "checkpoint instruction account count was wrong")
	_expect(first["instruction"]["accounts"][0]["is_writable"], "checkpoint PDA was not writable")
	_expect(first["instruction"]["accounts"][1]["is_signer"], "checkpoint authority was not a signer")
	_expect(not first["instruction"]["accounts"][1]["is_writable"], "checkpoint authority was unexpectedly writable")
	_expect(first["transaction_draft"]["recent_blockhash"] == null, "draft fabricated a recent blockhash")
	_expect(first["transaction_draft"]["signatures"].is_empty(), "draft fabricated signatures")
	_expect(not first["receipt"]["signing_performed"], "Solana receipt claimed signing")
	_expect(not first["receipt"]["broadcast_performed"], "Solana receipt claimed broadcast")
	_expect(not first["receipt"]["live_rpc_used"], "Solana receipt claimed live RPC")
	_expect(AUTHORITY_ID not in JSON.stringify(first["receipt"]), "Solana receipt exposed authority public key")

	var repeated_outbound := producer.prepare_commitment(first_checkpoint, {
		"public_key": AUTHORITY_ID,
		"capability": "checkpoint_writer",
		"nonce": 1,
	})
	_expect(not repeated_outbound.get("ok", true), "outbound Solana nonce replay was accepted")
	_expect(String(repeated_outbound.get("error", "")).contains("nonce_replay"), "outbound Solana replay reason was not explicit")
	var outbound_gap := producer.prepare_commitment(_checkpoint("gap", shard_commitment, 2), {
		"public_key": AUTHORITY_ID,
		"capability": "checkpoint_writer",
		"nonce": 3,
	})
	_expect(not outbound_gap.get("ok", true), "outbound Solana nonce gap was accepted")

	var revision_gap := producer.prepare_commitment(_checkpoint("revision-gap", shard_commitment, 3), {
		"public_key": AUTHORITY_ID,
		"capability": "checkpoint_writer",
		"nonce": 2,
	})
	_expect(not revision_gap.get("ok", true), "outbound Solana revision gap was accepted")
	_expect(String(revision_gap.get("error", "")).contains("revision_gap"), "revision gap reason was not explicit")

	var second_checkpoint := _checkpoint("second", shard_commitment, 2)
	second_checkpoint["previous_checkpoint_commitment"] = first["checkpoint_commitment"]
	var second := producer.prepare_commitment(second_checkpoint, {
		"public_key": AUTHORITY_ID,
		"capability": "checkpoint_writer",
		"nonce": 2,
	})
	_expect(second.get("ok", false), "linked second Solana checkpoint did not build")

	var verifier: SolanaCheckpointComponent = SolanaComponent.new()
	_expect(verifier.initialize(config).get("ok", false), "Solana verifier initialization failed")
	var account_validation := verifier.validate_accounts(first["instruction"])
	_expect(account_validation.get("ok", false), "valid Solana account metas were rejected")
	_expect(AUTHORITY_ID not in JSON.stringify(account_validation), "account validation receipt exposed authority key")
	var accepted_first := verifier.validate_checkpoint_instruction(first["instruction"])
	_expect(accepted_first.get("ok", false), "valid inbound Solana checkpoint was rejected")
	_expect(not accepted_first["signature_verified"], "interface validator claimed Solana signature verification")
	var replayed_first := verifier.validate_checkpoint_instruction(first["instruction"])
	_expect(not replayed_first.get("ok", true), "inbound Solana replay was accepted")
	_expect(String(replayed_first.get("error", "")).contains("nonce_replay"), "inbound Solana replay reason was not explicit")
	_expect(verifier.validate_checkpoint_instruction(second["instruction"]).get("ok", false), "linked second Solana checkpoint was rejected")

	var preview_verifier: SolanaCheckpointComponent = SolanaComponent.new()
	preview_verifier.initialize(config)
	var preview := preview_verifier.validate_checkpoint_instruction(first["instruction"], false)
	_expect(preview.get("ok", false), "non-consuming Solana validation failed")
	_expect(not preview.get("nonce_consumed", true), "non-consuming Solana validation consumed replay state")
	_expect(
		preview_verifier.validate_checkpoint_instruction(first["instruction"]).get("ok", false),
		"non-consuming Solana validation still mutated replay state"
	)

	var gap_verifier: SolanaCheckpointComponent = SolanaComponent.new()
	gap_verifier.initialize(config)
	_expect(
		not gap_verifier.validate_checkpoint_instruction(second["instruction"]).get("ok", true),
		"inbound Solana nonce/revision gap was accepted"
	)

	var pda_tamper: Dictionary = first["instruction"].duplicate(true)
	pda_tamper["accounts"][0]["pubkey"] = String(pda_tamper["accounts"][0]["pubkey"]) + "x"
	_expect(
		not gap_verifier.validate_accounts(pda_tamper).get("ok", true),
		"substituted checkpoint PDA account was accepted"
	)
	var signer_tamper: Dictionary = first["instruction"].duplicate(true)
	signer_tamper["accounts"][1]["is_signer"] = false
	_expect(
		not gap_verifier.validate_accounts(signer_tamper).get("ok", true),
		"non-signing authority account was accepted"
	)
	var writable_tamper: Dictionary = first["instruction"].duplicate(true)
	writable_tamper["accounts"][0]["is_writable"] = false
	_expect(
		not gap_verifier.validate_accounts(writable_tamper).get("ok", true),
		"read-only checkpoint account was accepted"
	)
	var data_tamper: Dictionary = first["instruction"].duplicate(true)
	data_tamper["data"]["checkpoint"]["rules_commitment"] = _hash_commitment("hostile-rules")
	var data_tamper_result := gap_verifier.validate_checkpoint_instruction(data_tamper)
	_expect(not data_tamper_result.get("ok", true), "tampered checkpoint instruction data was accepted")
	_expect(
		String(data_tamper_result.get("error", "")) == "checkpoint_commitment_mismatch",
		"tampered checkpoint did not fail its commitment"
	)

	var unauthorized := producer.prepare_commitment(_checkpoint("unauthorized", _hash_commitment("other-shard"), 1), {
		"public_key": "SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS",
		"capability": "checkpoint_writer",
		"nonce": 1,
	})
	_expect(not unauthorized.get("ok", true), "unconfigured Solana authority was accepted")
	var capability_escalation := producer.prepare_commitment(_checkpoint("escalated", _hash_commitment("admin-shard"), 1), {
		"public_key": OTHER_AUTHORITY_ID,
		"capability": "checkpoint_writer",
		"nonce": 1,
	})
	_expect(not capability_escalation.get("ok", true), "unconfigured Solana capability was accepted")

	var raw_social_data := _checkpoint("social", _hash_commitment("social-shard"), 1)
	raw_social_data["friend_list"] = ["alice", "bob"]
	_expect(
		not producer.prepare_commitment(raw_social_data, {
			"public_key": OTHER_AUTHORITY_ID, "capability": "checkpoint_admin", "nonce": 1,
		}).get("ok", true),
		"plaintext friend list entered a Solana checkpoint"
	)
	var raw_ip := _checkpoint("raw-ip", _hash_commitment("ip-shard"), 1)
	raw_ip["visibility"] = "192.168.5.19"
	_expect(
		not producer.prepare_commitment(raw_ip, {
			"public_key": OTHER_AUTHORITY_ID, "capability": "checkpoint_admin", "nonce": 1,
		}).get("ok", true),
		"raw IP entered a Solana checkpoint"
	)

	var bad_link_producer: SolanaCheckpointComponent = SolanaComponent.new()
	bad_link_producer.initialize(config)
	var bad_link_first := bad_link_producer.prepare_commitment(_checkpoint("link-one", shard_commitment, 1), {
		"public_key": AUTHORITY_ID, "capability": "checkpoint_writer", "nonce": 1,
	})
	_expect(bad_link_first.get("ok", false), "bad-link fixture genesis failed")
	var bad_link_second := _checkpoint("link-two", shard_commitment, 2)
	bad_link_second["previous_checkpoint_commitment"] = _hash_commitment("wrong-parent")
	var bad_link_result := bad_link_producer.prepare_commitment(bad_link_second, {
		"public_key": AUTHORITY_ID, "capability": "checkpoint_writer", "nonce": 2,
	})
	_expect(not bad_link_result.get("ok", true), "broken Solana checkpoint link was accepted")
	_expect(String(bad_link_result.get("error", "")).contains("previous_checkpoint_mismatch"), "broken link reason was not explicit")

	var unsafe_config: SolanaCheckpointComponent = SolanaComponent.new()
	_expect(
		not unsafe_config.initialize({
			"network_label": "solana-interface",
			"program_id": PROGRAM_ID,
			"authority_policy": {AUTHORITY_ID: ["checkpoint_writer"]},
			"private_key": "must-never-enter",
		}).get("ok", true),
		"Solana component accepted a private key field"
	)
	var rpc_config: SolanaCheckpointComponent = SolanaComponent.new()
	_expect(
		not rpc_config.initialize({
			"network_label": "solana-interface",
			"program_id": PROGRAM_ID,
			"authority_policy": {AUTHORITY_ID: ["checkpoint_writer"]},
			"rpc_url": "https://example.invalid",
		}).get("ok", true),
		"Solana component accepted a live RPC field"
	)

	var replay_snapshot := verifier.get_replay_snapshot()
	_expect(String(replay_snapshot.get("component_id", "")) == SolanaComponent.COMPONENT_ID, "Solana replay snapshot lacked component ID")
	_expect(AUTHORITY_ID not in JSON.stringify(replay_snapshot), "Solana replay snapshot exposed authority key")

	if failures.is_empty():
		print("SOLANA_CHECKPOINT_COMPONENT_TEST: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("SOLANA_CHECKPOINT_COMPONENT_TEST: " + failure)
		quit(1)


func _checkpoint(label: String, shard_commitment: String, revision: int) -> Dictionary:
	return {
		"shard_commitment": shard_commitment,
		"directory_commitment": _hash_commitment("directory-" + label),
		"rules_commitment": _hash_commitment("rules-" + label),
		"world_state_commitment": _hash_commitment("state-" + label),
		"revision": revision,
		"epoch": 1,
		"visibility": "commitment_only",
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
