extends RefCounted
class_name IpnsRecordAdapter

## Signed mutable-name record boundary for an eventual IPNS adapter.
##
## Local signatures are deterministic simulation receipts, never cryptographic
## claims. External records must be verified by an injected adapter callback.

const IpfsDagManifestScript = preload("res://systems/components/ipfs/ipfs_dag_manifest.gd")
const IpfsSafeValueScript = preload("res://systems/components/ipfs/ipfs_safe_value.gd")

const COMPONENT_ID := "ipfs.ipns-record-adapter/v1"
const INTERFACE_MODE := "LOCAL_IPNS_RECORD_SIMULATION"
const SCHEMA := "nexus.ipns.record-interface/v1"
const SIGNING_DOMAIN := "NEXUS_IPNS_RECORD_INTERFACE_V1"
const MAX_TTL_NS := 24 * 60 * 60 * 1000000000
const MAX_VALIDITY_WINDOW_SECONDS := 30 * 24 * 60 * 60


func create_unsigned(
	ipns_name: String,
	value_cid: String,
	sequence: int,
	ttl_ns: int,
	valid_until_unix: int,
	issued_at_unix: int
) -> Dictionary:
	if not _valid_ipns_name(ipns_name):
		return _failure("invalid_ipns_name")
	if not _valid_cid_contract(value_cid):
		return _failure("invalid_value_cid")
	if sequence < 0:
		return _failure("negative_sequence")
	if ttl_ns < 1 or ttl_ns > MAX_TTL_NS:
		return _failure("ttl_out_of_range")
	if issued_at_unix < 0:
		return _failure("issued_at_must_be_non_negative")
	if valid_until_unix <= issued_at_unix:
		return _failure("invalid_validity_window")
	if valid_until_unix - issued_at_unix > MAX_VALIDITY_WINDOW_SECONDS:
		return _failure("validity_window_too_large")
	var unsigned := {
		"ipns_name": ipns_name,
		"issued_at_unix": issued_at_unix,
		"schema": SCHEMA,
		"sequence": sequence,
		"signing_domain": SIGNING_DOMAIN,
		"ttl_ns": ttl_ns,
		"valid_until_unix": valid_until_unix,
		"value_cid": value_cid,
	}
	var canonical_result := _canonical_unsigned(unsigned)
	if not canonical_result.get("ok", false):
		return canonical_result
	return {
		"ok": true,
		"component_id": COMPONENT_ID,
		"interface_mode": INTERFACE_MODE,
		"unsigned": unsigned,
		"payload_bytes": canonical_result["bytes"],
		"payload_commitment": canonical_result["commitment"],
	}


func sign_with_adapter(unsigned: Dictionary, signer: Callable) -> Dictionary:
	var validation := validate_unsigned(unsigned)
	if not validation.get("ok", false):
		return validation
	if not signer.is_valid():
		return _failure("signer_adapter_required")
	var adapter_result = signer.call(validation["payload_bytes"], unsigned.duplicate(true))
	if not adapter_result is Dictionary:
		return _failure("signer_adapter_returned_invalid_result")
	if not adapter_result.get("ok", false):
		return _failure("signer_adapter_rejected_record")
	var proof := {
		"algorithm": String(adapter_result.get("algorithm", "")),
		"crypto_performed_by_local_component": false,
		"mode": "external_adapter",
		"payload_commitment": validation["payload_commitment"],
		"signature": String(adapter_result.get("signature", "")),
		"signer_key_id": String(adapter_result.get("signer_key_id", "")),
	}
	var proof_safety := IpfsSafeValueScript.validate(proof, "$.proof", false)
	if not proof_safety.get("ok", false):
		return _failure(String(proof_safety.get("reason", "unsafe_adapter_proof")))
	if proof["algorithm"].is_empty() or proof["signature"].is_empty() or proof["signer_key_id"].is_empty():
		return _failure("incomplete_signer_adapter_proof")
	if String(proof["signature"]).length() > 8192 or String(proof["signer_key_id"]).length() > 256:
		return _failure("signer_adapter_proof_too_large")
	return {"ok": true, "record": _attach_proof(unsigned, proof)}


func simulate_sign(unsigned: Dictionary, key_handle: String) -> Dictionary:
	var validation := validate_unsigned(unsigned)
	if not validation.get("ok", false):
		return validation
	if not _valid_key_handle(key_handle):
		return _failure("invalid_simulation_key_handle")
	var key_commitment := "sha256:" + IpfsSafeValueScript.sha256_text(key_handle)
	var signature := _simulation_signature(validation["payload_bytes"], key_commitment)
	var proof := {
		"algorithm_contract": "Ed25519",
		"crypto_performed": false,
		"key_handle_commitment": key_commitment,
		"mode": "deterministic_simulation",
		"payload_commitment": validation["payload_commitment"],
		"signature": signature,
	}
	return {"ok": true, "record": _attach_proof(unsigned, proof)}


func validate_unsigned(unsigned: Dictionary) -> Dictionary:
	var expected_fields := [
		"ipns_name",
		"issued_at_unix",
		"schema",
		"sequence",
		"signing_domain",
		"ttl_ns",
		"valid_until_unix",
		"value_cid",
	]
	if unsigned.size() != expected_fields.size():
		return _failure("unsigned_record_has_unexpected_fields")
	for field in expected_fields:
		if not unsigned.has(field):
			return _failure("missing_unsigned_field_" + field)
	var rebuilt := create_unsigned(
		String(unsigned.get("ipns_name", "")),
		String(unsigned.get("value_cid", "")),
		int(unsigned.get("sequence", -1)),
		int(unsigned.get("ttl_ns", 0)),
		int(unsigned.get("valid_until_unix", 0)),
		int(unsigned.get("issued_at_unix", 0))
	)
	if not rebuilt.get("ok", false):
		return rebuilt
	if unsigned != rebuilt["unsigned"]:
		return _failure("unsigned_record_not_canonical")
	return {
		"ok": true,
		"payload_bytes": rebuilt["payload_bytes"],
		"payload_commitment": rebuilt["payload_commitment"],
	}


func verify_record(record: Dictionary, now_unix: int, external_verifier: Callable = Callable()) -> Dictionary:
	if not record.has("unsigned") or not record.get("unsigned") is Dictionary:
		return _failure("signed_record_missing_unsigned_payload")
	if not record.has("proof") or not record.get("proof") is Dictionary:
		return _failure("signed_record_missing_proof")
	if String(record.get("record_interface", "")) != SCHEMA:
		return _failure("unsupported_signed_record_interface")
	var unsigned: Dictionary = record["unsigned"]
	var proof: Dictionary = record["proof"]
	var validation := validate_unsigned(unsigned)
	if not validation.get("ok", false):
		return validation
	if now_unix < int(unsigned["issued_at_unix"]):
		return _failure("record_not_yet_valid")
	if now_unix >= int(unsigned["valid_until_unix"]):
		return _failure("record_expired")
	if String(proof.get("payload_commitment", "")) != String(validation["payload_commitment"]):
		return _failure("signed_payload_commitment_mismatch")
	var proof_safety := IpfsSafeValueScript.validate(proof, "$.proof", false)
	if not proof_safety.get("ok", false):
		return _failure(String(proof_safety.get("reason", "unsafe_proof")))

	match String(proof.get("mode", "")):
		"deterministic_simulation":
			if bool(proof.get("crypto_performed", true)):
				return _failure("simulation_proof_claims_cryptography")
			var expected_signature := _simulation_signature(
				validation["payload_bytes"],
				String(proof.get("key_handle_commitment", ""))
			)
			if String(proof.get("signature", "")) != expected_signature:
				return _failure("simulation_signature_mismatch")
			return {
				"ok": true,
				"signature_valid": true,
				"cryptographic_signature_verified": false,
				"mode": "deterministic_simulation",
			}
		"external_adapter":
			if not external_verifier.is_valid():
				return _failure("external_verifier_required")
			var verified = external_verifier.call(validation["payload_bytes"], proof.duplicate(true))
			if not verified is Dictionary or not verified.get("ok", false) or not verified.get("valid", false):
				return _failure("external_signature_invalid")
			return {
				"ok": true,
				"signature_valid": true,
				"cryptographic_signature_verified": true,
				"mode": "external_adapter",
			}
	return _failure("unsupported_signature_mode")


func select_newer(current: Dictionary, candidate: Dictionary, now_unix: int, verifier: Callable = Callable()) -> Dictionary:
	var current_verification := verify_record(current, now_unix, verifier)
	if not current_verification.get("ok", false):
		return _failure("current_record_invalid")
	var candidate_verification := verify_record(candidate, now_unix, verifier)
	if not candidate_verification.get("ok", false):
		return _failure("candidate_record_invalid")
	var current_unsigned: Dictionary = current["unsigned"]
	var candidate_unsigned: Dictionary = candidate["unsigned"]
	if String(current_unsigned["ipns_name"]) != String(candidate_unsigned["ipns_name"]):
		return _failure("ipns_name_mismatch")
	if int(candidate_unsigned["sequence"]) <= int(current_unsigned["sequence"]):
		return _failure("non_monotonic_sequence")
	return {"ok": true, "selected": candidate.duplicate(true)}


func _attach_proof(unsigned: Dictionary, proof: Dictionary) -> Dictionary:
	return {
		"component_id": COMPONENT_ID,
		"interface_mode": INTERFACE_MODE,
		"record_interface": SCHEMA,
		"unsigned": unsigned.duplicate(true),
		"proof": proof.duplicate(true),
		"published": false,
		"live_ipns_record": false,
	}


func _canonical_unsigned(unsigned: Dictionary) -> Dictionary:
	var dag := IpfsDagManifestScript.new()
	var canonical_result := dag.canonical_bytes(unsigned)
	if not canonical_result.get("ok", false):
		return canonical_result
	return {
		"ok": true,
		"bytes": canonical_result["bytes"],
		"commitment": "sha256:" + IpfsSafeValueScript.sha256_hex(canonical_result["bytes"]),
	}


func _simulation_signature(payload_bytes: PackedByteArray, key_commitment: String) -> String:
	return "simsig:" + IpfsSafeValueScript.sha256_text(
		SIGNING_DOMAIN + "|" + payload_bytes.hex_encode() + "|" + key_commitment
	)


func _valid_ipns_name(value: String) -> bool:
	if value.length() < 16 or value.length() > 128 or IpfsSafeValueScript.contains_network_coordinate(value):
		return false
	var expression := RegEx.new()
	expression.compile("^[A-Za-z0-9]+$")
	return expression.search(value) != null


func _valid_cid_contract(value: String) -> bool:
	var expression := RegEx.new()
	expression.compile("^(baf[a-z2-7]{20,120}|cid-sim-b[a-z2-7]{52})$")
	return expression.search(value) != null


func _valid_key_handle(value: String) -> bool:
	if value.length() < 3 or value.length() > 128 or IpfsSafeValueScript.contains_network_coordinate(value):
		return false
	var expression := RegEx.new()
	expression.compile("^[A-Za-z0-9:_-]+$")
	return expression.search(value) != null


func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
