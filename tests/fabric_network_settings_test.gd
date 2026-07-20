extends SceneTree

const SettingsScript = preload("res://systems/components/fabric_network_settings.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var component = SettingsScript.new()
	var defaults: Dictionary = component.default_profile()
	var default_validation: Dictionary = component.validate(defaults)
	_check(default_validation["ok"], "simulation default did not validate: " + JSON.stringify(default_validation["errors"]))
	_check(defaults["profile"] == "simulation", "default profile is not simulation")
	_check(not defaults["consent"]["external_network_writes"], "default profile authorized network writes")
	_check(not defaults["ipfs"]["publish_enabled"], "default profile enabled IPFS publishing")
	_check(defaults["libp2p"]["relay_only"], "default profile was not relay-only")
	_check(not defaults["libp2p"]["advertise_raw_addresses"], "default profile advertises raw addresses")

	var default_plan: Dictionary = component.build_initialization_plan(defaults)
	_check(default_plan["ok"] and default_plan["ready_for_initialization"], "simulation initialization plan was not ready")
	_check(default_plan["simulation_only"], "simulation plan implied live integration")
	_check(default_plan["actions"].is_empty(), "simulation plan scheduled external actions")
	var expected_gate_order := [
		"settings_validation",
		"secret_boundary",
		"ml_kem_capability",
		"libp2p_relay",
		"ipfs_directory",
		"hive_identity_anchor",
		"solana_program_anchor",
		"data_lifecycle",
		"write_consent",
	]
	var actual_gate_order: Array[String] = []
	for gate in default_plan["gates"]:
		actual_gate_order.append(String(gate["id"]))
		_check(not gate["writes_external_state"], "an initialization gate claimed to execute a write")
	_check(actual_gate_order == expected_gate_order, "initialization gates were not stable and ordered")

	var receipt: Dictionary = component.build_settings_gate_receipt(defaults)
	_check(receipt["component_id"] == SettingsScript.COMPONENT_ID, "settings receipt component ID changed")
	_check(receipt["status"] == "ready", "valid settings receipt was blocked")
	_check(not receipt["secret_material_exported"], "settings receipt claimed to export secrets")
	_check(not receipt["raw_addresses_exported"], "settings receipt claimed to export raw addresses")
	_check(receipt["redacted_settings_sha256"].length() == 64, "settings receipt did not include a SHA-256 digest")
	_check(default_plan["settings_gate_receipt"]["redacted_settings_sha256"] == receipt["redacted_settings_sha256"], "plan receipt was not deterministic")

	var local: Dictionary = component.profile_settings("local")
	var local_validation: Dictionary = component.validate(local)
	_check(local_validation["ok"], "local read-only profile did not validate")
	_check(local["ipfs"]["api_url"].begins_with("http://localhost:"), "local profile did not use the hostname-only local daemon")
	var local_plan: Dictionary = component.build_initialization_plan(local)
	_check(not local_plan["ok"] and "ml_kem_capability" in local_plan["blockers"], "required ML-KEM capability did not fail closed")
	var local_ready_plan: Dictionary = component.build_initialization_plan(local, {
		"ml_kem_768_available": true,
		"libp2p_relay_available": true,
		"ipfs_read_adapter_available": true,
	})
	_check(local_ready_plan["ok"], "local profile remained blocked after its required capability was present")
	var wrong_type: Dictionary = defaults.duplicate(true)
	wrong_type["libp2p"]["relay_only"] = "true"
	_expect_error(component.validate(wrong_type), "invalid_setting_type", "string value was accepted as a security boolean")

	var unsafe_ip: Dictionary = defaults.duplicate(true)
	unsafe_ip["ipfs"]["gateway_url"] = "http://127.0.0.1:8080"
	_expect_error(component.validate(unsafe_ip), "raw_ip_literal_rejected", "raw IPv4 endpoint was accepted")
	var unsafe_ipv6: Dictionary = defaults.duplicate(true)
	unsafe_ipv6["ipfs"]["gateway_url"] = "http://[::1]:8080"
	_expect_error(component.validate(unsafe_ipv6), "raw_ip_literal_rejected", "raw IPv6 endpoint was accepted")
	var unsafe_relay: Dictionary = defaults.duplicate(true)
	unsafe_relay["libp2p"]["relay_peer_ids"] = ["/ip4/10.4.8.2/tcp/4001/p2p/12D3KooWUnsafe"]
	_expect_error(component.validate(unsafe_relay), "raw_ip_literal_rejected", "raw IP in a relay multiaddress was accepted")

	var credentialed_url: Dictionary = defaults.duplicate(true)
	credentialed_url["ipfs"]["api_url"] = "https://user:password@ipfs.example.test/api/v0"
	_expect_error(component.validate(credentialed_url), "credentialed_url_forbidden", "credential-bearing endpoint was accepted")
	var insecure_remote: Dictionary = defaults.duplicate(true)
	insecure_remote["ipfs"]["gateway_url"] = "http://gateway.example.test"
	_expect_error(component.validate(insecure_remote), "insecure_remote_http", "remote plaintext HTTP was accepted")

	var secret_injection: Dictionary = defaults.duplicate(true)
	secret_injection["private_key"] = "must-never-export"
	_expect_error(component.validate(secret_injection), "secret_field_forbidden", "private-key field was accepted")
	var secret_value: Dictionary = defaults.duplicate(true)
	secret_value["hive"]["posting_authority_handle"] = "-----BEGIN PRIVATE KEY-----"
	_expect_error(component.validate(secret_value), "secret_value_forbidden", "private-key-shaped value was accepted")
	var invalid_hive_handle: Dictionary = defaults.duplicate(true)
	invalid_hive_handle["hive"]["posting_authority_handle"] = "5JpostingPrivateKeyMaterial"
	_expect_error(component.validate(invalid_hive_handle), "invalid_hive_authority_handle", "Hive posting material was accepted as a handle")
	var invalid_solana: Dictionary = defaults.duplicate(true)
	invalid_solana["solana"]["program_id"] = "not-a-public-key"
	_expect_error(component.validate(invalid_solana), "invalid_solana_program_id", "malformed Solana program ID was accepted")

	var writable: Dictionary = _configured_live_profile(component)
	writable["consent"]["external_network_writes"] = false
	writable["consent"]["ipfs_publish"] = false
	writable["consent"]["hive_broadcast"] = false
	writable["consent"]["solana_submit"] = false
	writable["consent"]["write_acknowledgement"] = ""
	_expect_error(component.validate(writable), "ipfs_write_without_consent", "live IPFS write was accepted without consent")
	_expect_error(component.validate(writable), "hive_write_without_consent", "live Hive write was accepted without consent")
	_expect_error(component.validate(writable), "solana_write_without_consent", "live Solana write was accepted without consent")
	var blocked_plan: Dictionary = component.build_initialization_plan(writable, _live_capabilities())
	_check(not blocked_plan["ok"] and blocked_plan["gates"][0]["status"] == "blocked", "invalid live-write settings did not block the first gate")

	var consented: Dictionary = _configured_live_profile(component)
	var live_validation: Dictionary = component.validate(consented)
	_check(live_validation["ok"], "fully consented live profile did not validate: " + JSON.stringify(live_validation["errors"]))
	var live_plan: Dictionary = component.build_initialization_plan(consented, _live_capabilities())
	_check(live_plan["ok"], "fully capable live plan was blocked: " + JSON.stringify(live_plan["blockers"]))
	_check(live_plan["actions"].size() == 3, "live plan did not enumerate exactly three explicit write intents")
	for action in live_plan["actions"]:
		_check(action["consent_verified"], "live action did not carry verified consent")
		_check(not action["executed"], "settings plan executed an external action")

	var unsafe_upcycle: Dictionary = defaults.duplicate(true)
	unsafe_upcycle["upcycle"]["readable_tiers"] = ["public", "secret"]
	_expect_error(component.validate(unsafe_upcycle), "secret_upcycle_forbidden", "secret tier was allowed into upcycle")
	var unsafe_logs: Dictionary = defaults.duplicate(true)
	unsafe_logs["logging"]["include_payloads"] = true
	_expect_error(component.validate(unsafe_logs), "payload_logging_forbidden", "payload logging was accepted")
	var unsafe_retention: Dictionary = defaults.duplicate(true)
	unsafe_retention["retention"]["secret_seconds"] = 60
	_expect_error(component.validate(unsafe_retention), "secret_retention_forbidden", "persisted secret retention was accepted")

	var malicious: Dictionary = defaults.duplicate(true)
	malicious["private_key"] = "must-never-export"
	malicious["ipfs"]["api_url"] = "https://user:password@ipfs.example.test/api/v0"
	malicious["libp2p"]["relay_peer_ids"] = ["10.20.30.40"]
	var exported: Dictionary = component.get_redacted_public_snapshot(malicious)
	var serialized_export := JSON.stringify(exported)
	_check("must-never-export" not in serialized_export, "safe export leaked an injected private key")
	_check("user:password" not in serialized_export, "safe export leaked endpoint credentials")
	_check("10.20.30.40" not in serialized_export, "safe export leaked a raw network coordinate")
	_check("private_key" not in exported, "whitelist export retained an unknown secret field")
	_check(not exported["export_valid"], "unsafe configuration export was marked valid")
	_check(exported["settings_gate_receipt"]["status"] == "blocked", "unsafe public snapshot included a ready receipt")

	if failures.is_empty():
		print("FABRIC_NETWORK_SETTINGS_TEST: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("FABRIC_NETWORK_SETTINGS_TEST: " + failure)
		quit(1)


func _configured_live_profile(component: RefCounted) -> Dictionary:
	var settings: Dictionary = component.profile_settings("testnet_review")
	settings["ipfs"]["gateway_url"] = "https://gateway.ipfs.example.test"
	settings["ipfs"]["api_url"] = "https://api.ipfs.example.test/api/v0"
	settings["ipfs"]["read_enabled"] = true
	settings["ipfs"]["publish_enabled"] = true
	settings["libp2p"]["relay_peer_ids"] = ["12D3KooWQmYwAPJzv5CZsnAzt8auVZRnGi2"]
	settings["hive"]["rpc_url"] = "https://rpc.hive.example.test"
	settings["hive"]["account"] = "q7-forge"
	settings["hive"]["posting_authority_handle"] = "handle:hive-posting:q7-profile-01"
	settings["hive"]["read_enabled"] = true
	settings["hive"]["anchor_enabled"] = true
	settings["solana"]["rpc_url"] = "https://rpc.solana.example.test"
	settings["solana"]["program_id"] = "11111111111111111111111111111111"
	settings["solana"]["signer_authority_handle"] = "handle:solana-signer:q7-profile-01"
	settings["solana"]["read_enabled"] = true
	settings["solana"]["anchor_enabled"] = true
	settings["consent"]["external_network_reads"] = true
	settings["consent"]["external_network_writes"] = true
	settings["consent"]["ipfs_publish"] = true
	settings["consent"]["hive_broadcast"] = true
	settings["consent"]["solana_submit"] = true
	settings["consent"]["write_acknowledgement"] = SettingsScript.EXTERNAL_WRITE_ACKNOWLEDGEMENT
	return settings


func _live_capabilities() -> Dictionary:
	return {
		"ml_kem_768_available": true,
		"libp2p_relay_available": true,
		"ipfs_read_adapter_available": true,
		"ipfs_write_adapter_available": true,
		"hive_adapter_available": true,
		"solana_adapter_available": true,
	}


func _expect_error(result: Dictionary, code: String, failure: String) -> void:
	var found := false
	for issue in result.get("errors", []):
		if String(issue.get("code", "")) == code:
			found = true
			break
	_check(not result.get("ok", true) and found, failure + ": " + JSON.stringify(result.get("errors", [])))


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
