extends RefCounted
class_name FabricNetworkSettings

## Validated, simulation-first settings contract for the Nexus / Forge fabric.
##
## This component contains no network clients and never loads credentials. It
## produces a fail-closed initialization plan for separately audited adapters.
## Authority fields are opaque handles into a host keystore, never key material.

const SCHEMA := "nexus-fabric-settings/1"
const EXPORT_SCHEMA := "nexus-fabric-settings-export/1"
const COMPONENT_ID := "nexus.fabric.network-settings"
const COMPONENT_VERSION := "1.0.0"
const INTERFACE_MODE := "INTERFACE_CONFIGURATION_ONLY"
const EXTERNAL_WRITE_ACKNOWLEDGEMENT := "I CONSENT TO EXTERNAL NETWORK WRITES"

const PROFILES := ["simulation", "local", "testnet_review"]
const DATA_TIERS := ["public", "lobby", "private", "secret"]
const PROTECTED_TIERS := ["lobby", "private"]
const SECRET_KEY_MARKERS := [
	"api_key",
	"apikey",
	"authorization",
	"bearer",
	"cookie",
	"credential",
	"mnemonic",
	"password",
	"private_key",
	"secret",
	"seed_phrase",
	"session_token",
	"signing_key",
	"token",
	"wallet_key",
]
const SECRET_VALUE_MARKERS := [
	"-----begin private key-----",
	"-----begin encrypted private key-----",
	"-----begin openssh private key-----",
	"bearer ",
	"xprv",
	"sk-proj-",
	"sk_live_",
]


func default_profile() -> Dictionary:
	return profile_settings("simulation")


func profile_settings(profile_name: String = "simulation") -> Dictionary:
	var settings := _simulation_profile()
	match profile_name:
		"simulation":
			pass
		"local":
			settings["profile"] = "local"
			settings["execution_mode"] = "local"
			settings["ipfs"]["mode"] = "local_daemon"
			settings["ipfs"]["gateway_url"] = "http://localhost:8080"
			settings["ipfs"]["api_url"] = "http://localhost:5001/api/v0"
			settings["libp2p"]["mode"] = "local"
		"testnet_review":
			settings["profile"] = "testnet_review"
			settings["execution_mode"] = "live"
			settings["ipfs"]["mode"] = "remote_gateway"
			settings["ipfs"]["gateway_url"] = ""
			settings["ipfs"]["api_url"] = ""
			settings["ipfs"]["read_enabled"] = false
			settings["libp2p"]["mode"] = "live"
			settings["hive"]["network"] = "testnet"
			settings["solana"]["cluster"] = "devnet"
		_:
			settings["profile"] = profile_name
	return settings


func merge_overrides(base: Dictionary, overrides: Dictionary) -> Dictionary:
	## Deep merge helper for UI setting forms. Validation is intentionally a
	## separate mandatory step, so merging never implies approval.
	var merged: Dictionary = base.duplicate(true)
	_deep_merge_into(merged, overrides)
	return merged


func validate(settings: Dictionary) -> Dictionary:
	var errors: Array[Dictionary] = []
	var warnings: Array[Dictionary] = []

	_scan_for_secrets_and_addresses(settings, "settings", errors)
	_validate_known_keys(settings, [
		"schema", "profile", "execution_mode", "ipfs", "libp2p", "hive",
		"solana", "ml_kem", "retention", "logging", "upcycle", "consent",
	], "settings", errors)
	_require_string_fields(settings, ["schema", "profile", "execution_mode"], "settings", errors)

	if String(settings.get("schema", "")) != SCHEMA:
		_error(errors, "schema_mismatch", "settings.schema", "Unsupported or missing settings schema.")
	if String(settings.get("profile", "")) not in PROFILES:
		_error(errors, "unknown_profile", "settings.profile", "Profile must be simulation, local, or testnet_review.")
	var execution_mode := String(settings.get("execution_mode", ""))
	if execution_mode not in ["simulation", "local", "live"]:
		_error(errors, "invalid_execution_mode", "settings.execution_mode", "Execution mode must be simulation, local, or live.")

	var ipfs := _section(settings, "ipfs", errors)
	var libp2p := _section(settings, "libp2p", errors)
	var hive := _section(settings, "hive", errors)
	var solana := _section(settings, "solana", errors)
	var ml_kem := _section(settings, "ml_kem", errors)
	var retention := _section(settings, "retention", errors)
	var logging := _section(settings, "logging", errors)
	var upcycle := _section(settings, "upcycle", errors)
	var consent := _section(settings, "consent", errors)

	_validate_ipfs(ipfs, execution_mode, consent, errors)
	_validate_libp2p(libp2p, execution_mode, consent, errors)
	_validate_hive(hive, execution_mode, consent, errors)
	_validate_solana(solana, execution_mode, consent, errors)
	_validate_ml_kem(ml_kem, errors)
	_validate_retention(retention, errors)
	_validate_logging(logging, errors)
	_validate_upcycle(upcycle, errors)
	_validate_consent(consent, errors)

	if execution_mode == "simulation":
		for service in [ipfs, hive, solana]:
			if bool(service.get("publish_enabled", service.get("anchor_enabled", false))):
				_error(errors, "simulation_write_requested", "settings.execution_mode", "Simulation mode cannot request a network write.")

	if execution_mode != "simulation" and String(ml_kem.get("policy", "")) == "disabled":
		_error(errors, "pq_policy_required", "settings.ml_kem.policy", "Local and live protected-tier operation requires an ML-KEM policy.")

	return {
		"ok": errors.is_empty(),
		"errors": errors,
		"warnings": warnings,
		"schema": SCHEMA,
	}


func build_initialization_plan(settings: Dictionary, runtime_capabilities: Dictionary = {}) -> Dictionary:
	var validation := validate(settings)
	var gates: Array[Dictionary] = []
	var blockers: Array[String] = []
	var actions: Array[Dictionary] = []
	var runtime_errors: Array[Dictionary] = []
	_scan_for_secrets_and_addresses(runtime_capabilities, "runtime_capabilities", runtime_errors)
	_validate_known_keys(runtime_capabilities, [
		"ml_kem_768_available", "ml_kem_1024_available", "libp2p_relay_available",
		"ipfs_read_adapter_available", "ipfs_write_adapter_available",
		"hive_adapter_available", "solana_adapter_available",
	], "runtime_capabilities", runtime_errors)

	if not bool(validation.get("ok", false)) or not runtime_errors.is_empty():
		var reasons: Array[String] = []
		for issue in validation.get("errors", []):
			reasons.append(String(issue.get("code", "invalid_settings")))
		for issue in runtime_errors:
			reasons.append(String(issue.get("code", "invalid_runtime_capability")))
		gates.append(_gate("settings_validation", "blocked", reasons))
		for gate_id in [
			"secret_boundary", "ml_kem_capability", "libp2p_relay", "ipfs_directory",
			"hive_identity_anchor", "solana_program_anchor", "data_lifecycle", "write_consent",
		]:
			gates.append(_gate(gate_id, "blocked", ["settings_validation_failed"]))
		return {
			"component_id": COMPONENT_ID,
			"component_version": COMPONENT_VERSION,
			"ok": false,
			"ready_for_initialization": false,
			"simulation_only": true,
			"profile": String(settings.get("profile", "unknown")),
			"gates": gates,
			"blockers": reasons,
			"actions": actions,
			"validation": validation,
			"settings_gate_receipt": build_settings_gate_receipt(settings),
		}

	var mode := String(settings["execution_mode"])
	var simulation := mode == "simulation"
	gates.append(_gate("settings_validation", "ready", []))
	gates.append(_gate("secret_boundary", "ready", ["authority_handles_only", "raw_addresses_rejected"]))

	var ml_kem: Dictionary = settings["ml_kem"]
	var kem_policy := String(ml_kem["policy"])
	var kem_parameter := String(ml_kem["parameter_set"])
	var kem_capability_key := "ml_kem_1024_available" if kem_parameter == "ML-KEM-1024" else "ml_kem_768_available"
	if simulation:
		gates.append(_gate("ml_kem_capability", "simulated", [kem_parameter, kem_policy]))
	elif kem_policy == "disabled":
		gates.append(_gate("ml_kem_capability", "disabled", ["policy_disabled"]))
	elif bool(runtime_capabilities.get(kem_capability_key, false)):
		gates.append(_gate("ml_kem_capability", "ready", [kem_parameter, "non_exportable_handle_required"]))
	elif kem_policy == "preferred":
		gates.append(_gate("ml_kem_capability", "degraded", ["capability_unavailable", "protected_tiers_must_remain_locked"]))
	else:
		gates.append(_gate("ml_kem_capability", "blocked", ["required_capability_unavailable"]))
		blockers.append("ml_kem_capability")

	var libp2p: Dictionary = settings["libp2p"]
	if String(libp2p["mode"]) == "simulation":
		gates.append(_gate("libp2p_relay", "simulated", ["relay_only", "no_raw_address_advertising"]))
	elif String(libp2p["mode"]) == "disabled":
		gates.append(_gate("libp2p_relay", "disabled", []))
	elif bool(runtime_capabilities.get("libp2p_relay_available", false)):
		gates.append(_gate("libp2p_relay", "ready", ["relay_only", "peer_id_surface_only"]))
	else:
		gates.append(_gate("libp2p_relay", "blocked", ["relay_adapter_unavailable"]))
		blockers.append("libp2p_relay")

	var ipfs: Dictionary = settings["ipfs"]
	var ipfs_status := "simulated" if String(ipfs["mode"]) == "simulation" else "ready"
	var ipfs_reasons: Array[String] = ["cid_and_ipns_handles_only"]
	if String(ipfs["mode"]) == "disabled":
		ipfs_status = "disabled"
	elif not simulation:
		if bool(ipfs["read_enabled"]) and not bool(runtime_capabilities.get("ipfs_read_adapter_available", false)):
			ipfs_status = "blocked"
			ipfs_reasons.append("read_adapter_unavailable")
		if bool(ipfs["publish_enabled"]) and not bool(runtime_capabilities.get("ipfs_write_adapter_available", false)):
			ipfs_status = "blocked"
			ipfs_reasons.append("write_adapter_unavailable")
	if ipfs_status == "blocked":
		blockers.append("ipfs_directory")
	gates.append(_gate("ipfs_directory", ipfs_status, ipfs_reasons))
	if bool(ipfs["publish_enabled"]):
		actions.append(_action("ipfs", "publish_directory", true, _ipfs_write_consent(settings["consent"])))

	var hive: Dictionary = settings["hive"]
	var hive_status := "disabled"
	var hive_reasons: Array[String] = []
	if String(hive["network"]) == "simulation":
		hive_status = "simulated"
		hive_reasons.append("custom_json_commitment_only")
	elif bool(hive["anchor_enabled"]):
		hive_status = "ready" if bool(runtime_capabilities.get("hive_adapter_available", false)) else "blocked"
		hive_reasons.append("posting_authority_handle_only")
		if hive_status == "blocked":
			blockers.append("hive_identity_anchor")
		actions.append(_action("hive", "broadcast_custom_json_commitment", true, _hive_write_consent(settings["consent"])))
	elif bool(hive["read_enabled"]):
		hive_status = "ready" if bool(runtime_capabilities.get("hive_adapter_available", false)) else "blocked"
		hive_reasons.append("read_only")
		if hive_status == "blocked":
			blockers.append("hive_identity_anchor")
	gates.append(_gate("hive_identity_anchor", hive_status, hive_reasons))

	var solana: Dictionary = settings["solana"]
	var solana_status := "disabled"
	var solana_reasons: Array[String] = []
	if String(solana["cluster"]) == "simulation":
		solana_status = "simulated"
		solana_reasons.append("pda_derivation_interface_only")
	elif bool(solana["anchor_enabled"]):
		solana_status = "ready" if bool(runtime_capabilities.get("solana_adapter_available", false)) else "blocked"
		solana_reasons.append("signer_authority_handle_only")
		if solana_status == "blocked":
			blockers.append("solana_program_anchor")
		actions.append(_action("solana", "submit_commitment_instruction", true, _solana_write_consent(settings["consent"])))
	elif bool(solana["read_enabled"]):
		solana_status = "ready" if bool(runtime_capabilities.get("solana_adapter_available", false)) else "blocked"
		solana_reasons.append("read_only")
		if solana_status == "blocked":
			blockers.append("solana_program_anchor")
	gates.append(_gate("solana_program_anchor", solana_status, solana_reasons))

	gates.append(_gate("data_lifecycle", "ready", [
		"payload_logging_disabled", "secret_tier_excluded_from_upcycle", "tier_retention_applied",
	]))
	var consent_status := "ready"
	for action in actions:
		if not bool(action["consent_verified"]):
			consent_status = "blocked"
			blockers.append("write_consent")
			break
	gates.append(_gate("write_consent", consent_status, ["no_action_is_executed_by_this_plan"]))

	return {
		"component_id": COMPONENT_ID,
		"component_version": COMPONENT_VERSION,
		"ok": blockers.is_empty(),
		"ready_for_initialization": blockers.is_empty(),
		"simulation_only": simulation,
		"profile": String(settings["profile"]),
		"gates": gates,
		"blockers": blockers,
		"actions": actions,
		"validation": validation,
		"settings_gate_receipt": build_settings_gate_receipt(settings),
	}


func get_redacted_public_snapshot(settings: Dictionary) -> Dictionary:
	var snapshot := safe_export(settings)
	snapshot["component_id"] = COMPONENT_ID
	snapshot["component_version"] = COMPONENT_VERSION
	snapshot["interface_mode"] = INTERFACE_MODE
	snapshot["settings_gate_receipt"] = build_settings_gate_receipt(settings)
	return snapshot


func build_settings_gate_receipt(settings: Dictionary) -> Dictionary:
	var validation := validate(settings)
	var exported := safe_export(settings)
	var consent_value = settings.get("consent", {})
	var external_writes_authorized := false
	if consent_value is Dictionary:
		external_writes_authorized = _global_write_consent(consent_value)
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(JSON.stringify(_canonicalize(exported)).to_utf8_buffer())
	return {
		"component_id": COMPONENT_ID,
		"component_version": COMPONENT_VERSION,
		"gate_id": "fabric_network_settings",
		"interface_mode": INTERFACE_MODE,
		"status": "ready" if bool(validation.get("ok", false)) else "blocked",
		"profile": String(settings.get("profile", "unknown")),
		"redacted_settings_sha256": context.finish().hex_encode(),
		"external_writes_authorized": external_writes_authorized,
		"raw_addresses_exported": false,
		"secret_material_exported": false,
		"error_codes": safe_export(settings).get("validation_error_codes", []),
	}


func safe_export(settings: Dictionary) -> Dictionary:
	## Whitelist construction is deliberate: extension or injected fields cannot
	## escape merely because their names were not recognized by a redactor.
	var validation := validate(settings)
	var exported := {
		"schema": EXPORT_SCHEMA,
		"source_schema": String(settings.get("schema", "")),
		"profile": String(settings.get("profile", "")),
		"execution_mode": String(settings.get("execution_mode", "")),
		"ipfs": _export_section(settings.get("ipfs", {}), [
			"mode", "gateway_url", "api_url", "read_enabled", "publish_enabled",
			"ipns_enabled", "pin_policy", "request_timeout_ms", "max_object_bytes",
		]),
		"libp2p": _export_section(settings.get("libp2p", {}), [
			"mode", "relay_only", "advertise_raw_addresses", "relay_peer_ids",
			"peer_discovery_enabled", "autonat_enabled",
		]),
		"hive": _export_section(settings.get("hive", {}), [
			"network", "rpc_url", "account", "posting_authority_handle", "read_enabled",
			"anchor_enabled", "custom_json_id",
		]),
		"solana": _export_section(settings.get("solana", {}), [
			"cluster", "rpc_url", "program_id", "signer_authority_handle", "commitment",
			"read_enabled", "anchor_enabled",
		]),
		"ml_kem": _export_section(settings.get("ml_kem", {}), [
			"policy", "parameter_set", "hybrid_classical", "require_non_exportable_keys",
			"protected_tiers",
		]),
		"retention": _export_section(settings.get("retention", {}), [
			"public_seconds", "lobby_seconds", "private_seconds", "secret_seconds",
			"max_local_cache_bytes", "delete_on_lobby_exit",
		]),
		"logging": _export_section(settings.get("logging", {}), [
			"level", "local_only", "include_payloads", "include_peer_addresses",
			"telemetry_enabled", "retention_seconds",
		]),
		"upcycle": _export_section(settings.get("upcycle", {}), [
			"enabled", "readable_tiers", "require_capability_for", "excluded_tiers",
			"allow_cross_node",
		]),
		"consent": _export_section(settings.get("consent", {}), [
			"external_network_reads", "external_network_writes", "p2p_participation",
			"ipfs_publish", "hive_broadcast", "solana_submit",
		]),
		"export_valid": bool(validation.get("ok", false)),
		"validation_error_codes": [],
	}
	for issue in validation.get("errors", []):
		exported["validation_error_codes"].append(String(issue.get("code", "invalid_settings")))
	return redact_for_diagnostics(exported)


func redact_for_diagnostics(value: Variant) -> Variant:
	if value is Dictionary:
		var output := {}
		for key in value:
			var key_text := String(key)
			if _is_secret_key_name(key_text):
				output[key_text] = "[REDACTED]"
			else:
				output[key_text] = redact_for_diagnostics(value[key])
		return output
	if value is Array:
		var output_array := []
		for item in value:
			output_array.append(redact_for_diagnostics(item))
		return output_array
	if value is String:
		var text := String(value)
		if _string_has_secret_marker(text):
			return "[REDACTED]"
		if _contains_raw_ip_literal(text):
			return "[REDACTED_RAW_ADDRESS]"
		if _url_contains_credentials(text):
			return "[REDACTED_CREDENTIAL_URL]"
	return value


func _simulation_profile() -> Dictionary:
	return {
		"schema": SCHEMA,
		"profile": "simulation",
		"execution_mode": "simulation",
		"ipfs": {
			"mode": "simulation",
			"gateway_url": "http://localhost:8080",
			"api_url": "http://localhost:5001/api/v0",
			"read_enabled": true,
			"publish_enabled": false,
			"ipns_enabled": true,
			"pin_policy": "session",
			"request_timeout_ms": 8000,
			"max_object_bytes": 16 * 1024 * 1024,
		},
		"libp2p": {
			"mode": "simulation",
			"relay_only": true,
			"advertise_raw_addresses": false,
			"relay_peer_ids": [],
			"peer_discovery_enabled": false,
			"autonat_enabled": true,
		},
		"hive": {
			"network": "simulation",
			"rpc_url": "",
			"account": "",
			"posting_authority_handle": "",
			"read_enabled": false,
			"anchor_enabled": false,
			"custom_json_id": "nexus-forge",
		},
		"solana": {
			"cluster": "simulation",
			"rpc_url": "",
			"program_id": "",
			"signer_authority_handle": "",
			"commitment": "confirmed",
			"read_enabled": false,
			"anchor_enabled": false,
		},
		"ml_kem": {
			"policy": "required",
			"parameter_set": "ML-KEM-768",
			"hybrid_classical": true,
			"require_non_exportable_keys": true,
			"protected_tiers": PROTECTED_TIERS.duplicate(),
		},
		"retention": {
			"public_seconds": 0,
			"lobby_seconds": 7 * 24 * 60 * 60,
			"private_seconds": 30 * 24 * 60 * 60,
			"secret_seconds": 0,
			"max_local_cache_bytes": 256 * 1024 * 1024,
			"delete_on_lobby_exit": true,
		},
		"logging": {
			"level": "security",
			"local_only": true,
			"include_payloads": false,
			"include_peer_addresses": false,
			"telemetry_enabled": false,
			"retention_seconds": 7 * 24 * 60 * 60,
		},
		"upcycle": {
			"enabled": true,
			"readable_tiers": ["public"],
			"require_capability_for": PROTECTED_TIERS.duplicate(),
			"excluded_tiers": ["secret"],
			"allow_cross_node": false,
		},
		"consent": {
			"external_network_reads": false,
			"external_network_writes": false,
			"p2p_participation": false,
			"ipfs_publish": false,
			"hive_broadcast": false,
			"solana_submit": false,
			"write_acknowledgement": "",
		},
	}


func _validate_ipfs(ipfs: Dictionary, execution_mode: String, consent: Dictionary, errors: Array[Dictionary]) -> void:
	_validate_known_keys(ipfs, [
		"mode", "gateway_url", "api_url", "read_enabled", "publish_enabled",
		"ipns_enabled", "pin_policy", "request_timeout_ms", "max_object_bytes",
	], "settings.ipfs", errors)
	_require_string_fields(ipfs, ["mode", "gateway_url", "api_url", "pin_policy"], "settings.ipfs", errors)
	_require_bool_fields(ipfs, ["read_enabled", "publish_enabled", "ipns_enabled"], "settings.ipfs", errors)
	_require_int_fields(ipfs, ["request_timeout_ms", "max_object_bytes"], "settings.ipfs", errors)
	if not _exact_types(
		ipfs,
		["mode", "gateway_url", "api_url", "pin_policy"],
		["read_enabled", "publish_enabled", "ipns_enabled"],
		["request_timeout_ms", "max_object_bytes"],
		[]
	):
		return
	var mode := String(ipfs.get("mode", ""))
	if mode not in ["disabled", "simulation", "local_daemon", "remote_gateway"]:
		_error(errors, "invalid_ipfs_mode", "settings.ipfs.mode", "Unknown IPFS mode.")
	var gateway_required := mode in ["local_daemon", "remote_gateway"] and bool(ipfs.get("read_enabled", false))
	var api_required := mode in ["local_daemon", "remote_gateway"] and bool(ipfs.get("publish_enabled", false))
	_validate_endpoint(String(ipfs.get("gateway_url", "")), "settings.ipfs.gateway_url", gateway_required, mode == "local_daemon", errors)
	_validate_endpoint(String(ipfs.get("api_url", "")), "settings.ipfs.api_url", api_required, mode == "local_daemon", errors)
	if String(ipfs.get("pin_policy", "")) not in ["none", "session", "retained"]:
		_error(errors, "invalid_pin_policy", "settings.ipfs.pin_policy", "Pin policy must be none, session, or retained.")
	if int(ipfs.get("request_timeout_ms", 0)) < 500 or int(ipfs.get("request_timeout_ms", 0)) > 120000:
		_error(errors, "invalid_timeout", "settings.ipfs.request_timeout_ms", "IPFS timeout must be between 500 and 120000 milliseconds.")
	if int(ipfs.get("max_object_bytes", 0)) < 1024 or int(ipfs.get("max_object_bytes", 0)) > 64 * 1024 * 1024:
		_error(errors, "invalid_object_limit", "settings.ipfs.max_object_bytes", "IPFS object limit must be between 1 KiB and 64 MiB.")
	if mode == "disabled" and (bool(ipfs.get("read_enabled", false)) or bool(ipfs.get("publish_enabled", false))):
		_error(errors, "disabled_ipfs_action", "settings.ipfs", "Disabled IPFS cannot read or publish.")
	if bool(ipfs.get("publish_enabled", false)):
		if execution_mode == "simulation":
			_error(errors, "simulation_ipfs_publish", "settings.ipfs.publish_enabled", "Simulation cannot publish to an IPFS adapter.")
		if not _ipfs_write_consent(consent):
			_error(errors, "ipfs_write_without_consent", "settings.consent", "IPFS publishing requires explicit external-write and IPFS consent.")
	if mode == "remote_gateway" and bool(ipfs.get("read_enabled", false)) and not bool(consent.get("external_network_reads", false)):
		_error(errors, "ipfs_read_without_consent", "settings.consent.external_network_reads", "Remote IPFS reads require consent.")


func _validate_libp2p(libp2p: Dictionary, execution_mode: String, consent: Dictionary, errors: Array[Dictionary]) -> void:
	_validate_known_keys(libp2p, [
		"mode", "relay_only", "advertise_raw_addresses", "relay_peer_ids",
		"peer_discovery_enabled", "autonat_enabled",
	], "settings.libp2p", errors)
	_require_string_fields(libp2p, ["mode"], "settings.libp2p", errors)
	_require_bool_fields(libp2p, [
		"relay_only", "advertise_raw_addresses", "peer_discovery_enabled", "autonat_enabled",
	], "settings.libp2p", errors)
	_require_string_array(libp2p, "relay_peer_ids", "settings.libp2p", errors)
	if not _exact_types(
		libp2p,
		["mode"],
		["relay_only", "advertise_raw_addresses", "peer_discovery_enabled", "autonat_enabled"],
		[],
		["relay_peer_ids"]
	):
		return
	if String(libp2p.get("mode", "")) not in ["disabled", "simulation", "local", "live"]:
		_error(errors, "invalid_libp2p_mode", "settings.libp2p.mode", "Unknown libp2p mode.")
	if not bool(libp2p.get("relay_only", false)):
		_error(errors, "relay_only_required", "settings.libp2p.relay_only", "The fabric requires relay-only lobby routing.")
	if bool(libp2p.get("advertise_raw_addresses", true)):
		_error(errors, "raw_address_advertising_forbidden", "settings.libp2p.advertise_raw_addresses", "Raw address advertising is forbidden.")
	var peers = libp2p.get("relay_peer_ids", [])
	if not peers is Array:
		_error(errors, "invalid_relay_peer_ids", "settings.libp2p.relay_peer_ids", "Relay peer IDs must be an array.")
	else:
		for peer in peers:
			if not _valid_peer_id(String(peer)):
				_error(errors, "invalid_relay_peer_id", "settings.libp2p.relay_peer_ids", "Relay entries must be Peer IDs, not multiaddresses or network coordinates.")
	if bool(libp2p.get("peer_discovery_enabled", false)):
		if execution_mode == "simulation":
			_error(errors, "simulation_peer_discovery", "settings.libp2p.peer_discovery_enabled", "Simulation cannot join peer discovery.")
		if not bool(consent.get("external_network_reads", false)) or not bool(consent.get("p2p_participation", false)):
			_error(errors, "p2p_without_consent", "settings.consent", "Peer discovery requires network-read and P2P participation consent.")


func _validate_hive(hive: Dictionary, execution_mode: String, consent: Dictionary, errors: Array[Dictionary]) -> void:
	_validate_known_keys(hive, [
		"network", "rpc_url", "account", "posting_authority_handle", "read_enabled",
		"anchor_enabled", "custom_json_id",
	], "settings.hive", errors)
	_require_string_fields(hive, [
		"network", "rpc_url", "account", "posting_authority_handle", "custom_json_id",
	], "settings.hive", errors)
	_require_bool_fields(hive, ["read_enabled", "anchor_enabled"], "settings.hive", errors)
	if not _exact_types(
		hive,
		["network", "rpc_url", "account", "posting_authority_handle", "custom_json_id"],
		["read_enabled", "anchor_enabled"],
		[],
		[]
	):
		return
	var network := String(hive.get("network", ""))
	if network not in ["simulation", "testnet", "mainnet", "custom"]:
		_error(errors, "invalid_hive_network", "settings.hive.network", "Unknown Hive network.")
	var rpc_required := network != "simulation" and (bool(hive.get("read_enabled", false)) or bool(hive.get("anchor_enabled", false)))
	_validate_endpoint(String(hive.get("rpc_url", "")), "settings.hive.rpc_url", rpc_required, false, errors)
	var account := String(hive.get("account", ""))
	if not account.is_empty() and not _matches(account, "^[a-z][a-z0-9.-]{2,15}$"):
		_error(errors, "invalid_hive_account", "settings.hive.account", "Hive account format is invalid.")
	var handle := String(hive.get("posting_authority_handle", ""))
	if not handle.is_empty() and not _valid_authority_handle(handle, "hive-posting"):
		_error(errors, "invalid_hive_authority_handle", "settings.hive.posting_authority_handle", "Use an opaque hive-posting authority handle, never a posting key.")
	if bool(hive.get("anchor_enabled", false)):
		if execution_mode == "simulation" or network == "simulation":
			_error(errors, "simulation_hive_broadcast", "settings.hive.anchor_enabled", "Simulation cannot broadcast a Hive operation.")
		if account.is_empty() or handle.is_empty():
			_error(errors, "hive_authority_required", "settings.hive", "Hive writes require an account and posting-authority handle.")
		if not _hive_write_consent(consent):
			_error(errors, "hive_write_without_consent", "settings.consent", "Hive broadcasting requires explicit external-write and Hive consent.")
	if network != "simulation" and bool(hive.get("read_enabled", false)) and not bool(consent.get("external_network_reads", false)):
		_error(errors, "hive_read_without_consent", "settings.consent.external_network_reads", "Hive network reads require consent.")
	var custom_json_id := String(hive.get("custom_json_id", ""))
	if not _matches(custom_json_id, "^[a-z0-9-]{3,32}$"):
		_error(errors, "invalid_hive_custom_json_id", "settings.hive.custom_json_id", "Hive custom_json ID must be a short lowercase namespace.")


func _validate_solana(solana: Dictionary, execution_mode: String, consent: Dictionary, errors: Array[Dictionary]) -> void:
	_validate_known_keys(solana, [
		"cluster", "rpc_url", "program_id", "signer_authority_handle", "commitment",
		"read_enabled", "anchor_enabled",
	], "settings.solana", errors)
	_require_string_fields(solana, [
		"cluster", "rpc_url", "program_id", "signer_authority_handle", "commitment",
	], "settings.solana", errors)
	_require_bool_fields(solana, ["read_enabled", "anchor_enabled"], "settings.solana", errors)
	if not _exact_types(
		solana,
		["cluster", "rpc_url", "program_id", "signer_authority_handle", "commitment"],
		["read_enabled", "anchor_enabled"],
		[],
		[]
	):
		return
	var cluster := String(solana.get("cluster", ""))
	if cluster not in ["simulation", "localnet", "devnet", "testnet", "mainnet-beta", "custom"]:
		_error(errors, "invalid_solana_cluster", "settings.solana.cluster", "Unknown Solana cluster.")
	var rpc_required := cluster != "simulation" and (bool(solana.get("read_enabled", false)) or bool(solana.get("anchor_enabled", false)))
	_validate_endpoint(String(solana.get("rpc_url", "")), "settings.solana.rpc_url", rpc_required, cluster == "localnet", errors)
	var program_id := String(solana.get("program_id", ""))
	if not program_id.is_empty() and not _valid_solana_address(program_id):
		_error(errors, "invalid_solana_program_id", "settings.solana.program_id", "Solana program ID must be a 32–44 character base58 public address.")
	var handle := String(solana.get("signer_authority_handle", ""))
	if not handle.is_empty() and not _valid_authority_handle(handle, "solana-signer"):
		_error(errors, "invalid_solana_authority_handle", "settings.solana.signer_authority_handle", "Use an opaque solana-signer authority handle, never a private key.")
	if String(solana.get("commitment", "")) not in ["processed", "confirmed", "finalized"]:
		_error(errors, "invalid_solana_commitment", "settings.solana.commitment", "Solana commitment must be processed, confirmed, or finalized.")
	if bool(solana.get("anchor_enabled", false)):
		if execution_mode == "simulation" or cluster == "simulation":
			_error(errors, "simulation_solana_submit", "settings.solana.anchor_enabled", "Simulation cannot submit a Solana instruction.")
		if program_id.is_empty() or handle.is_empty():
			_error(errors, "solana_authority_required", "settings.solana", "Solana writes require a program ID and signer-authority handle.")
		if not _solana_write_consent(consent):
			_error(errors, "solana_write_without_consent", "settings.consent", "Solana submitting requires explicit external-write and Solana consent.")
	if cluster not in ["simulation", "localnet"] and bool(solana.get("read_enabled", false)) and not bool(consent.get("external_network_reads", false)):
		_error(errors, "solana_read_without_consent", "settings.consent.external_network_reads", "Solana network reads require consent.")


func _validate_ml_kem(ml_kem: Dictionary, errors: Array[Dictionary]) -> void:
	_validate_known_keys(ml_kem, [
		"policy", "parameter_set", "hybrid_classical", "require_non_exportable_keys", "protected_tiers",
	], "settings.ml_kem", errors)
	_require_string_fields(ml_kem, ["policy", "parameter_set"], "settings.ml_kem", errors)
	_require_bool_fields(ml_kem, ["hybrid_classical", "require_non_exportable_keys"], "settings.ml_kem", errors)
	_require_string_array(ml_kem, "protected_tiers", "settings.ml_kem", errors)
	if not _exact_types(
		ml_kem,
		["policy", "parameter_set"],
		["hybrid_classical", "require_non_exportable_keys"],
		[],
		["protected_tiers"]
	):
		return
	if String(ml_kem.get("policy", "")) not in ["required", "preferred", "disabled"]:
		_error(errors, "invalid_ml_kem_policy", "settings.ml_kem.policy", "ML-KEM policy must be required, preferred, or disabled.")
	if String(ml_kem.get("parameter_set", "")) not in ["ML-KEM-768", "ML-KEM-1024"]:
		_error(errors, "invalid_ml_kem_parameter_set", "settings.ml_kem.parameter_set", "Only ML-KEM-768 and ML-KEM-1024 are accepted for protected tiers.")
	if not bool(ml_kem.get("require_non_exportable_keys", false)):
		_error(errors, "exportable_kem_keys_forbidden", "settings.ml_kem.require_non_exportable_keys", "ML-KEM key handles must be non-exportable.")
	if not bool(ml_kem.get("hybrid_classical", false)):
		_error(errors, "hybrid_kem_required", "settings.ml_kem.hybrid_classical", "Protected tiers require a hybrid classical + ML-KEM policy.")
	var tiers = ml_kem.get("protected_tiers", [])
	if not tiers is Array or not _same_string_set(tiers, PROTECTED_TIERS):
		_error(errors, "protected_tiers_must_use_ml_kem", "settings.ml_kem.protected_tiers", "Lobby and private tiers must both use the ML-KEM policy.")


func _validate_retention(retention: Dictionary, errors: Array[Dictionary]) -> void:
	_validate_known_keys(retention, [
		"public_seconds", "lobby_seconds", "private_seconds", "secret_seconds",
		"max_local_cache_bytes", "delete_on_lobby_exit",
	], "settings.retention", errors)
	_require_int_fields(retention, [
		"public_seconds", "lobby_seconds", "private_seconds", "secret_seconds", "max_local_cache_bytes",
	], "settings.retention", errors)
	_require_bool_fields(retention, ["delete_on_lobby_exit"], "settings.retention", errors)
	if not _exact_types(
		retention,
		[],
		["delete_on_lobby_exit"],
		["public_seconds", "lobby_seconds", "private_seconds", "secret_seconds", "max_local_cache_bytes"],
		[]
	):
		return
	for key in ["public_seconds", "lobby_seconds", "private_seconds", "secret_seconds"]:
		var seconds := int(retention.get(key, -1))
		if seconds < 0 or seconds > 365 * 24 * 60 * 60:
			_error(errors, "invalid_retention", "settings.retention." + key, "Retention must be between zero and one year.")
	if int(retention.get("secret_seconds", -1)) != 0:
		_error(errors, "secret_retention_forbidden", "settings.retention.secret_seconds", "Secret material must be memory-only and use zero persisted retention.")
	if int(retention.get("max_local_cache_bytes", 0)) < 1024 * 1024 or int(retention.get("max_local_cache_bytes", 0)) > 4 * 1024 * 1024 * 1024:
		_error(errors, "invalid_cache_limit", "settings.retention.max_local_cache_bytes", "Cache limit must be between 1 MiB and 4 GiB.")


func _validate_logging(logging: Dictionary, errors: Array[Dictionary]) -> void:
	_validate_known_keys(logging, [
		"level", "local_only", "include_payloads", "include_peer_addresses",
		"telemetry_enabled", "retention_seconds",
	], "settings.logging", errors)
	_require_string_fields(logging, ["level"], "settings.logging", errors)
	_require_bool_fields(logging, [
		"local_only", "include_payloads", "include_peer_addresses", "telemetry_enabled",
	], "settings.logging", errors)
	_require_int_fields(logging, ["retention_seconds"], "settings.logging", errors)
	if not _exact_types(
		logging,
		["level"],
		["local_only", "include_payloads", "include_peer_addresses", "telemetry_enabled"],
		["retention_seconds"],
		[]
	):
		return
	if String(logging.get("level", "")) not in ["off", "security", "audit"]:
		_error(errors, "invalid_log_level", "settings.logging.level", "Logging level must be off, security, or audit.")
	if not bool(logging.get("local_only", false)):
		_error(errors, "remote_logging_forbidden", "settings.logging.local_only", "Fabric logs must remain local.")
	if bool(logging.get("include_payloads", true)):
		_error(errors, "payload_logging_forbidden", "settings.logging.include_payloads", "Payload logging is forbidden.")
	if bool(logging.get("include_peer_addresses", true)):
		_error(errors, "peer_address_logging_forbidden", "settings.logging.include_peer_addresses", "Peer address logging is forbidden.")
	if bool(logging.get("telemetry_enabled", false)):
		_error(errors, "telemetry_forbidden", "settings.logging.telemetry_enabled", "Telemetry export is disabled for this security profile.")
	if int(logging.get("retention_seconds", -1)) < 0 or int(logging.get("retention_seconds", -1)) > 30 * 24 * 60 * 60:
		_error(errors, "invalid_log_retention", "settings.logging.retention_seconds", "Log retention must be at most 30 days.")


func _validate_upcycle(upcycle: Dictionary, errors: Array[Dictionary]) -> void:
	_validate_known_keys(upcycle, [
		"enabled", "readable_tiers", "require_capability_for", "excluded_tiers", "allow_cross_node",
	], "settings.upcycle", errors)
	_require_bool_fields(upcycle, ["enabled", "allow_cross_node"], "settings.upcycle", errors)
	for array_key in ["readable_tiers", "require_capability_for", "excluded_tiers"]:
		_require_string_array(upcycle, array_key, "settings.upcycle", errors)
	if not _exact_types(
		upcycle,
		[],
		["enabled", "allow_cross_node"],
		[],
		["readable_tiers", "require_capability_for", "excluded_tiers"]
	):
		return
	var readable = upcycle.get("readable_tiers", [])
	var capabilities = upcycle.get("require_capability_for", [])
	var excluded = upcycle.get("excluded_tiers", [])
	if not readable is Array or not capabilities is Array or not excluded is Array:
		_error(errors, "invalid_upcycle_tiers", "settings.upcycle", "Upcycle tier policies must be arrays.")
		return
	for tier in readable:
		if String(tier) not in DATA_TIERS:
			_error(errors, "unknown_upcycle_tier", "settings.upcycle.readable_tiers", "Unknown data tier in readable list.")
	if "secret" in readable:
		_error(errors, "secret_upcycle_forbidden", "settings.upcycle.readable_tiers", "Secret-tier data can never enter upcycle queries.")
	if "secret" not in excluded:
		_error(errors, "secret_exclusion_required", "settings.upcycle.excluded_tiers", "Secret tier must be explicitly excluded.")
	for tier in PROTECTED_TIERS:
		if tier in readable and tier not in capabilities:
			_error(errors, "upcycle_capability_required", "settings.upcycle.require_capability_for", "Protected readable tiers require an authorization capability.")


func _validate_consent(consent: Dictionary, errors: Array[Dictionary]) -> void:
	_validate_known_keys(consent, [
		"external_network_reads", "external_network_writes", "p2p_participation",
		"ipfs_publish", "hive_broadcast", "solana_submit", "write_acknowledgement",
	], "settings.consent", errors)
	_require_bool_fields(consent, [
		"external_network_reads", "external_network_writes", "p2p_participation",
		"ipfs_publish", "hive_broadcast", "solana_submit",
	], "settings.consent", errors)
	_require_string_fields(consent, ["write_acknowledgement"], "settings.consent", errors)
	if not _exact_types(
		consent,
		["write_acknowledgement"],
		[
			"external_network_reads", "external_network_writes", "p2p_participation",
			"ipfs_publish", "hive_broadcast", "solana_submit",
		],
		[],
		[]
	):
		return
	var service_write := bool(consent.get("ipfs_publish", false)) or bool(consent.get("hive_broadcast", false)) or bool(consent.get("solana_submit", false))
	if service_write and not bool(consent.get("external_network_writes", false)):
		_error(errors, "service_consent_without_global_consent", "settings.consent.external_network_writes", "Service write consent requires the global external-write flag.")
	if bool(consent.get("external_network_writes", false)) and String(consent.get("write_acknowledgement", "")) != EXTERNAL_WRITE_ACKNOWLEDGEMENT:
		_error(errors, "write_acknowledgement_required", "settings.consent.write_acknowledgement", "External writes require the exact acknowledgement phrase.")


func _validate_endpoint(url: String, path: String, required: bool, allow_local_http: bool, errors: Array[Dictionary]) -> void:
	if url.is_empty():
		if required:
			_error(errors, "endpoint_required", path, "An endpoint is required for this enabled operation.")
		return
	if url.contains(" ") or url.contains("\t") or url.contains("\n"):
		_error(errors, "unsafe_endpoint", path, "Endpoint contains whitespace.")
		return
	if _url_contains_credentials(url):
		_error(errors, "credentialed_url_forbidden", path, "Credentials and user-info are forbidden in endpoint URLs.")
		return
	if url.contains("?") or url.contains("#"):
		_error(errors, "endpoint_query_forbidden", path, "Endpoint query strings and fragments are forbidden.")
		return
	var scheme_end := url.find("://")
	if scheme_end < 1:
		_error(errors, "invalid_endpoint_scheme", path, "Endpoint must be an explicit HTTP or HTTPS URL.")
		return
	var scheme := url.substr(0, scheme_end).to_lower()
	if scheme not in ["http", "https"]:
		_error(errors, "invalid_endpoint_scheme", path, "Only HTTP and HTTPS endpoints are accepted.")
		return
	var remainder := url.substr(scheme_end + 3)
	var slash := remainder.find("/")
	var authority := remainder if slash < 0 else remainder.substr(0, slash)
	if authority.is_empty():
		_error(errors, "invalid_endpoint_host", path, "Endpoint hostname is missing.")
		return
	var host := authority
	if authority.begins_with("["):
		var bracket_end := authority.find("]")
		host = authority.substr(1, bracket_end - 1) if bracket_end > 0 else authority
	else:
		var colon := authority.rfind(":")
		if colon > 0 and authority.find(":") == colon:
			var port_text := authority.substr(colon + 1)
			if not port_text.is_valid_int() or int(port_text) < 1 or int(port_text) > 65535:
				_error(errors, "invalid_endpoint_port", path, "Endpoint port is invalid.")
			return
			host = authority.substr(0, colon)
	if _is_ipv4(host) or _is_ipv6(host):
		_error(errors, "raw_ip_literal_rejected", path, "Use an approved hostname; raw IP literals are forbidden.")
		return
	if not _valid_hostname(host):
		_error(errors, "invalid_endpoint_host", path, "Endpoint hostname is invalid.")
		return
	var local_host := host.to_lower() == "localhost" or host.to_lower().ends_with(".localhost") or host.to_lower().ends_with(".local")
	if scheme == "http" and not (allow_local_http and local_host):
		_error(errors, "insecure_remote_http", path, "Remote endpoints require HTTPS; HTTP is limited to explicit local-daemon mode.")


func _scan_for_secrets_and_addresses(value: Variant, path: String, errors: Array[Dictionary]) -> void:
	if value is Dictionary:
		for key in value:
			var key_text := String(key)
			var child_path := path + "." + key_text
			if _is_secret_key_name(key_text) and key_text not in ["secret_seconds", "write_acknowledgement"]:
				_error(errors, "secret_field_forbidden", child_path, "Secret-bearing settings fields are forbidden; use an authority handle.")
			_scan_for_secrets_and_addresses(value[key], child_path, errors)
	elif value is Array:
		for index in range(value.size()):
			_scan_for_secrets_and_addresses(value[index], path + "[" + str(index) + "]", errors)
	elif value is String:
		var text := String(value)
		if _string_has_secret_marker(text):
			_error(errors, "secret_value_forbidden", path, "A value resembles secret material and was rejected.")
		if _contains_raw_ip_literal(text):
			_error(errors, "raw_ip_literal_rejected", path, "Raw IPv4/IPv6 literals are forbidden in fabric settings.")


func _section(settings: Dictionary, key: String, errors: Array[Dictionary]) -> Dictionary:
	var value = settings.get(key, null)
	if value is Dictionary:
		return value
	_error(errors, "section_required", "settings." + key, "Settings section is missing or malformed.")
	return {}


func _validate_known_keys(section: Dictionary, allowed: Array, path: String, errors: Array[Dictionary]) -> void:
	for key in section:
		if String(key) not in allowed:
			_error(errors, "unknown_setting", path + "." + String(key), "Unknown settings are rejected by the pinned schema.")


func _require_string_fields(section: Dictionary, fields: Array, path: String, errors: Array[Dictionary]) -> void:
	for field in fields:
		if not section.has(field) or not section[field] is String:
			_error(errors, "invalid_setting_type", path + "." + String(field), "Setting must be a string.")


func _require_bool_fields(section: Dictionary, fields: Array, path: String, errors: Array[Dictionary]) -> void:
	for field in fields:
		if not section.has(field) or not section[field] is bool:
			_error(errors, "invalid_setting_type", path + "." + String(field), "Setting must be a boolean.")


func _require_int_fields(section: Dictionary, fields: Array, path: String, errors: Array[Dictionary]) -> void:
	for field in fields:
		if not section.has(field) or not section[field] is int:
			_error(errors, "invalid_setting_type", path + "." + String(field), "Setting must be an integer.")


func _require_string_array(section: Dictionary, field: String, path: String, errors: Array[Dictionary]) -> void:
	if not section.has(field) or not section[field] is Array:
		_error(errors, "invalid_setting_type", path + "." + field, "Setting must be an array of strings.")
		return
	for item in section[field]:
		if not item is String:
			_error(errors, "invalid_setting_type", path + "." + field, "Setting must contain strings only.")
			return


func _exact_types(
	section: Dictionary,
	string_fields: Array,
	bool_fields: Array,
	int_fields: Array,
	array_fields: Array
) -> bool:
	for field in string_fields:
		if not section.has(field) or not section[field] is String:
			return false
	for field in bool_fields:
		if not section.has(field) or not section[field] is bool:
			return false
	for field in int_fields:
		if not section.has(field) or not section[field] is int:
			return false
	for field in array_fields:
		if not section.has(field) or not section[field] is Array:
			return false
	return true


func _export_section(value: Variant, allowed: Array) -> Dictionary:
	if not value is Dictionary:
		return {}
	var output := {}
	for key in allowed:
		if value.has(key):
			output[key] = value[key]
	return output


func _ipfs_write_consent(consent: Dictionary) -> bool:
	return _global_write_consent(consent) and bool(consent.get("ipfs_publish", false))


func _hive_write_consent(consent: Dictionary) -> bool:
	return _global_write_consent(consent) and bool(consent.get("hive_broadcast", false))


func _solana_write_consent(consent: Dictionary) -> bool:
	return _global_write_consent(consent) and bool(consent.get("solana_submit", false))


func _global_write_consent(consent: Dictionary) -> bool:
	return (
		bool(consent.get("external_network_writes", false))
		and String(consent.get("write_acknowledgement", "")) == EXTERNAL_WRITE_ACKNOWLEDGEMENT
	)


func _valid_peer_id(value: String) -> bool:
	if value.contains("/") or value.contains(":") or value.length() < 12 or value.length() > 128:
		return false
	return _matches(value, "^[1-9A-HJ-NP-Za-km-z]+$")


func _valid_authority_handle(value: String, kind: String) -> bool:
	return _matches(value, "^handle:" + kind + ":[A-Za-z0-9._-]{8,96}$")


func _valid_solana_address(value: String) -> bool:
	return value.length() >= 32 and value.length() <= 44 and _matches(value, "^[1-9A-HJ-NP-Za-km-z]+$")


func _valid_hostname(value: String) -> bool:
	if value.length() < 1 or value.length() > 253 or value.begins_with(".") or value.ends_with("."):
		return false
	for label in value.split("."):
		if label.length() < 1 or label.length() > 63:
			return false
		if not _matches(label, "^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$"):
			return false
	return true


func _contains_raw_ip_literal(value: String) -> bool:
	var text := value.strip_edges()
	if text.is_empty():
		return false
	if _is_ipv4(text) or _is_ipv6(text):
		return true
	# Scan common URL, multiaddress, and free-text delimiters without treating
	# semantic versions as IPs unless all four octets form a valid address.
	var normalized := text
	for delimiter in ["/", "[", "]", "(", ")", ",", ";", "=", "@", " ", "\t", "\n"]:
		normalized = normalized.replace(delimiter, " ")
	for token in normalized.split(" ", false):
		var candidate := String(token).trim_prefix("http:").trim_prefix("https:")
		var port_split := candidate.split(":")
		if port_split.size() == 2 and String(port_split[1]).is_valid_int():
			candidate = String(port_split[0])
		if _is_ipv4(candidate) or _is_ipv6(candidate):
			return true
	return false


func _is_ipv4(value: String) -> bool:
	var parts := value.split(".")
	if parts.size() != 4:
		return false
	for part in parts:
		var item := String(part)
		if item.is_empty() or not item.is_valid_int() or (item.length() > 1 and item.begins_with("0")):
			return false
		var number := int(item)
		if number < 0 or number > 255:
			return false
	return true


func _is_ipv6(value: String) -> bool:
	var candidate := value.to_lower().trim_prefix("[").trim_suffix("]")
	var percent := candidate.find("%")
	if percent >= 0:
		candidate = candidate.substr(0, percent)
	if candidate.count(":") < 2:
		return false
	if not _matches(candidate, "^[0-9a-f:.]+$"):
		return false
	# This is a conservative syntax check. Settings reject anything that has an
	# IPv6 shape; adapters are never asked to normalize it.
	return candidate.length() >= 2


func _url_contains_credentials(value: String) -> bool:
	var scheme := value.find("://")
	if scheme < 0:
		return false
	var remainder := value.substr(scheme + 3)
	var authority := remainder.split("/", false, 1)[0]
	return authority.contains("@")


func _is_secret_key_name(value: String) -> bool:
	var normalized := value.to_lower().replace("-", "_")
	for marker in SECRET_KEY_MARKERS:
		if normalized == marker or normalized.ends_with("_" + marker) or normalized.begins_with(marker + "_"):
			return true
	return false


func _string_has_secret_marker(value: String) -> bool:
	var lower := value.to_lower()
	for marker in SECRET_VALUE_MARKERS:
		if lower.contains(marker):
			return true
	return false


func _same_string_set(left: Array, right: Array) -> bool:
	var normalized_left: Array[String] = []
	var normalized_right: Array[String] = []
	for item in left:
		normalized_left.append(String(item))
	for item in right:
		normalized_right.append(String(item))
	normalized_left.sort()
	normalized_right.sort()
	return normalized_left == normalized_right


func _matches(value: String, expression: String) -> bool:
	var regex := RegEx.new()
	if regex.compile(expression) != OK:
		return false
	return regex.search(value) != null


func _deep_merge_into(target: Dictionary, source: Dictionary) -> void:
	for key in source:
		if target.get(key) is Dictionary and source[key] is Dictionary:
			_deep_merge_into(target[key], source[key])
		else:
			target[key] = source[key]


func _canonicalize(value: Variant) -> Variant:
	if value is Dictionary:
		var output := {}
		var keys: Array = value.keys()
		keys.sort_custom(func(left, right): return String(left) < String(right))
		for key in keys:
			output[String(key)] = _canonicalize(value[key])
		return output
	if value is Array:
		var output_array := []
		for item in value:
			output_array.append(_canonicalize(item))
		return output_array
	return value


func _gate(gate_id: String, status: String, reasons: Array) -> Dictionary:
	return {
		"id": gate_id,
		"status": status,
		"reasons": reasons.duplicate(true),
		"writes_external_state": false,
	}


func _action(service: String, operation: String, external: bool, consent_verified: bool) -> Dictionary:
	return {
		"service": service,
		"operation": operation,
		"external": external,
		"consent_verified": consent_verified,
		"executed": false,
	}


func _error(errors: Array[Dictionary], code: String, path: String, message: String) -> void:
	errors.append({"code": code, "path": path, "message": message})


func _warning(warnings: Array[Dictionary], code: String, path: String, message: String) -> void:
	warnings.append({"code": code, "path": path, "message": message})
