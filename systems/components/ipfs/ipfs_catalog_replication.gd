extends RefCounted
class_name IpfsCatalogReplication

## Authorization-preserving catalog replication boundary.
##
## Records contain content pointers and commitments, never inline protected
## plaintext. Host-provided hooks may further restrict built-in authorization;
## they can never grant access that the built-in tier policy denies.

const IpfsDagManifestScript = preload("res://systems/components/ipfs/ipfs_dag_manifest.gd")
const IpfsSafeValueScript = preload("res://systems/components/ipfs/ipfs_safe_value.gd")

const COMPONENT_ID := "ipfs.authorized-catalog-replication/v1"
const INTERFACE_MODE := "LOCAL_CATALOG_REPLICATION_SIMULATION"
const RECORD_SCHEMA := "nexus.ipfs.catalog-record/v1"
const PACKAGE_SCHEMA := "nexus.ipfs.catalog-package/v1"
const MAX_RECORDS_PER_PACKAGE := 1024
const ALLOWED_TIERS := ["public", "lobby", "private"]

var _configured := false
var _local_node_id := ""
var _authorization_hook: Callable
var _origin_verifier: Callable
var _catalogs: Dictionary = {}
var _seen_record_ids: Dictionary = {}
var _package_sequence := 0


func configure(
	local_node_id: String,
	authorization_hook: Callable = Callable(),
	origin_verifier: Callable = Callable()
) -> Dictionary:
	if _configured:
		return _failure("replicator_already_configured")
	if not _valid_identifier(local_node_id):
		return _failure("invalid_local_node_id")
	_local_node_id = local_node_id
	_authorization_hook = authorization_hook
	_origin_verifier = origin_verifier
	_catalogs[_local_node_id] = []
	_seen_record_ids[_local_node_id] = {}
	_configured = true
	return {"ok": true, "receipt": _receipt("configured", {"catalog_count": 1})}


func create_catalog_record(spec: Dictionary) -> Dictionary:
	if not _configured:
		return _failure("replicator_not_configured")
	var safety := IpfsSafeValueScript.validate(spec, "$record_spec", false)
	if not safety.get("ok", false):
		return _failure(String(safety.get("reason", "unsafe_record_spec")))
	var tier := String(spec.get("tier", ""))
	if tier == "secret":
		return _failure("secret_tier_must_not_replicate")
	if tier not in ALLOWED_TIERS:
		return _failure("unsupported_record_tier")
	var allowed_spec_fields := ["cid", "content_commitment", "kind", "origin_node_id", "sequence", "tier"]
	match tier:
		"lobby":
			allowed_spec_fields.append_array(["lobby_id", "member_ids"])
		"private":
			allowed_spec_fields.append_array(["owner_id", "reader_ids"])
	for key_value in spec.keys():
		if String(key_value) not in allowed_spec_fields:
			return _failure("unknown_record_spec_field_" + String(key_value))
	var origin_node_id := String(spec.get("origin_node_id", _local_node_id))
	var sequence := int(spec.get("sequence", 0))
	var kind := String(spec.get("kind", ""))
	var cid := String(spec.get("cid", ""))
	var content_commitment := String(spec.get("content_commitment", ""))
	if not _valid_identifier(origin_node_id) or not _valid_kind(kind) or sequence < 1:
		return _failure("invalid_record_identity")
	if not _valid_cid_contract(cid) or not _valid_sha256_commitment(content_commitment):
		return _failure("invalid_content_pointer")

	var access_result := _build_access(tier, spec)
	if not access_result.get("ok", false):
		return access_result
	var record_without_id := {
		"access": access_result["access"],
		"content": {
			"cid": cid,
			"content_commitment": content_commitment,
			"encrypted": tier != "public",
			"plaintext_in_catalog": false,
		},
		"interface_mode": INTERFACE_MODE,
		"kind": kind,
		"origin_node_id": origin_node_id,
		"schema": RECORD_SCHEMA,
		"sequence": sequence,
		"tier": tier,
	}
	var canonical := _canonical(record_without_id)
	if not canonical.get("ok", false):
		return canonical
	var record := record_without_id.duplicate(true)
	record["record_id"] = "rec_" + IpfsSafeValueScript.sha256_hex(canonical["bytes"]).substr(0, 40)
	var final_canonical := _canonical(record)
	if not final_canonical.get("ok", false):
		return final_canonical
	record["record_commitment"] = "sha256:" + IpfsSafeValueScript.sha256_hex(final_canonical["bytes"])
	return {"ok": true, "record": record}


func register_local_record(record: Dictionary) -> Dictionary:
	if not _configured:
		return _failure("replicator_not_configured")
	var validation := _validate_record(record, _local_node_id)
	if not validation.get("ok", false):
		return validation
	if _seen_record_ids[_local_node_id].has(String(record["record_id"])):
		return _failure("duplicate_record_id")
	_seen_record_ids[_local_node_id][record["record_id"]] = true
	_catalogs[_local_node_id].append(record.duplicate(true))
	_sort_records(_catalogs[_local_node_id])
	return {"ok": true, "catalog_size": _catalogs[_local_node_id].size()}


func prepare_export(auth: Dictionary, signing_hook: Callable = Callable()) -> Dictionary:
	if not _configured:
		return _failure("replicator_not_configured")
	var auth_safety := IpfsSafeValueScript.validate(auth, "$export_auth", false)
	if not auth_safety.get("ok", false):
		return _failure(String(auth_safety.get("reason", "unsafe_export_auth")))
	var selected: Array[Dictionary] = []
	for candidate in _catalogs.get(_local_node_id, []):
		var record: Dictionary = candidate
		if _record_authorized(record, auth, "export"):
			selected.append(record.duplicate(true))
	if selected.size() > MAX_RECORDS_PER_PACKAGE:
		return _failure("export_record_limit_exceeded")
	_sort_records(selected)
	_package_sequence += 1
	var unsigned_package := {
		"component_id": COMPONENT_ID,
		"interface_mode": INTERFACE_MODE,
		"origin_node_id": _local_node_id,
		"package_sequence": _package_sequence,
		"records": selected,
		"schema": PACKAGE_SCHEMA,
	}
	var canonical := _canonical(unsigned_package)
	if not canonical.get("ok", false):
		return canonical
	var package_commitment := "sha256:" + IpfsSafeValueScript.sha256_hex(canonical["bytes"])
	var proof_result := _build_package_proof(canonical["bytes"], package_commitment, signing_hook)
	if not proof_result.get("ok", false):
		return proof_result
	return {
		"ok": true,
		"package": {
			"package_commitment": package_commitment,
			"proof": proof_result["proof"],
			"unsigned": unsigned_package,
		},
		"receipt": _receipt("export_prepared", {
			"package_commitment": package_commitment,
			"record_count": selected.size(),
		}),
	}


func ingest_package(package: Dictionary, auth: Dictionary) -> Dictionary:
	if not _configured:
		return _failure("replicator_not_configured")
	var safety := IpfsSafeValueScript.validate(package, "$package", false)
	if not safety.get("ok", false):
		return _failure(String(safety.get("reason", "unsafe_package")))
	var auth_safety := IpfsSafeValueScript.validate(auth, "$import_auth", false)
	if not auth_safety.get("ok", false):
		return _failure(String(auth_safety.get("reason", "unsafe_import_auth")))
	if package.size() != 3:
		return _failure("package_has_unexpected_fields")
	if not package.has("unsigned") or not package.get("unsigned") is Dictionary:
		return _failure("package_missing_unsigned_payload")
	if not package.has("proof") or not package.get("proof") is Dictionary:
		return _failure("package_missing_proof")
	var unsigned: Dictionary = package["unsigned"]
	if unsigned.size() != 6:
		return _failure("unsigned_package_has_unexpected_fields")
	if String(unsigned.get("schema", "")) != PACKAGE_SCHEMA:
		return _failure("unsupported_package_schema")
	if String(unsigned.get("component_id", "")) != COMPONENT_ID:
		return _failure("package_component_mismatch")
	if String(unsigned.get("interface_mode", "")) != INTERFACE_MODE:
		return _failure("package_interface_mode_mismatch")
	var origin_node_id := String(unsigned.get("origin_node_id", ""))
	if not _valid_identifier(origin_node_id) or origin_node_id == _local_node_id:
		return _failure("invalid_remote_origin")
	if not unsigned.get("records") is Array:
		return _failure("package_records_must_be_array")
	if int(unsigned.get("package_sequence", 0)) < 1:
		return _failure("invalid_package_sequence")
	var records: Array = unsigned["records"]
	if records.size() > MAX_RECORDS_PER_PACKAGE:
		return _failure("import_record_limit_exceeded")
	var sorted_records: Array = records.duplicate(true)
	_sort_records(sorted_records)
	if sorted_records != records:
		return _failure("package_records_not_canonically_sorted")

	var canonical := _canonical(unsigned)
	if not canonical.get("ok", false):
		return canonical
	var expected_commitment := "sha256:" + IpfsSafeValueScript.sha256_hex(canonical["bytes"])
	if String(package.get("package_commitment", "")) != expected_commitment:
		return _failure("package_commitment_mismatch")
	var proof_result := _verify_package_proof(canonical["bytes"], expected_commitment, package["proof"])
	if not proof_result.get("ok", false):
		return proof_result

	var accepted: Array = Array(_catalogs.get(origin_node_id, [])).duplicate(true)
	var seen: Dictionary = Dictionary(_seen_record_ids.get(origin_node_id, {})).duplicate(true)
	var accepted_count := 0
	var rejected: Array[Dictionary] = []
	for candidate in records:
		if not candidate is Dictionary:
			rejected.append({"record_id": "", "reason": "record_must_be_map"})
			continue
		var record: Dictionary = candidate
		var validation := _validate_record(record, origin_node_id)
		var record_id := String(record.get("record_id", ""))
		if not validation.get("ok", false):
			rejected.append({"record_id": record_id, "reason": validation.get("reason", "invalid_record")})
			continue
		if seen.has(record_id):
			rejected.append({"record_id": record_id, "reason": "duplicate_record_id"})
			continue
		if not _record_authorized(record, auth, "import"):
			rejected.append({"record_id": record_id, "reason": "not_authorized_for_replica"})
			continue
		seen[record_id] = true
		accepted.append(record.duplicate(true))
		accepted_count += 1
	_sort_records(accepted)
	_catalogs[origin_node_id] = accepted
	_seen_record_ids[origin_node_id] = seen
	return {
		"ok": true,
		"accepted": accepted_count,
		"rejected": rejected,
		"receipt": _receipt("package_ingested", {
			"origin_commitment": _commit(origin_node_id),
			"package_commitment": expected_commitment,
			"record_count": accepted_count,
		}),
	}


func query(auth: Dictionary, filters: Dictionary = {}) -> Dictionary:
	if not _configured:
		return _failure("replicator_not_configured")
	var auth_safety := IpfsSafeValueScript.validate(auth, "$query_auth", false)
	var filter_safety := IpfsSafeValueScript.validate(filters, "$query_filters", false)
	if not auth_safety.get("ok", false) or not filter_safety.get("ok", false):
		return _failure("unsafe_query_input")
	for filter_key in filters.keys():
		if String(filter_key) not in ["kind", "origin_node_id", "tier"]:
			return _failure("unsupported_query_filter")
	var visible: Array[Dictionary] = []
	var node_ids: Array = _catalogs.keys()
	node_ids.sort()
	for node_id_value in node_ids:
		for candidate in _catalogs[node_id_value]:
			var record: Dictionary = candidate
			if not _record_authorized(record, auth, "query") or not _matches_filters(record, filters):
				continue
			visible.append(record.duplicate(true))
	_sort_records(visible)
	return {
		"ok": true,
		"records": visible,
		"receipt": _receipt("query", {"visible_record_count": visible.size()}),
	}


func _build_access(tier: String, spec: Dictionary) -> Dictionary:
	match tier:
		"public":
			return {"ok": true, "access": {"audience": "anyone"}}
		"lobby":
			var lobby_id := String(spec.get("lobby_id", ""))
			var members_value = spec.get("member_ids", [])
			if not _valid_identifier(lobby_id) or not members_value is Array or members_value.is_empty():
				return _failure("lobby_access_requires_scope_and_members")
			var member_commitments_result := _commit_identifier_array(members_value)
			if not member_commitments_result.get("ok", false):
				return member_commitments_result
			return {"ok": true, "access": {
				"lobby_commitment": _commit(lobby_id),
				"member_commitments": member_commitments_result["commitments"],
			}}
		"private":
			var owner_id := String(spec.get("owner_id", ""))
			var readers_value = spec.get("reader_ids", [])
			if not _valid_identifier(owner_id) or not readers_value is Array:
				return _failure("private_access_requires_owner_and_readers")
			var readers: Array = readers_value.duplicate(true)
			readers.append(owner_id)
			var reader_commitments_result := _commit_identifier_array(readers)
			if not reader_commitments_result.get("ok", false):
				return reader_commitments_result
			return {"ok": true, "access": {
				"owner_commitment": _commit(owner_id),
				"reader_commitments": reader_commitments_result["commitments"],
			}}
	return _failure("unsupported_record_tier")


func _validate_record(record: Dictionary, expected_origin: String) -> Dictionary:
	var safety := IpfsSafeValueScript.validate(record, "$record", false)
	if not safety.get("ok", false):
		return _failure(String(safety.get("reason", "unsafe_record")))
	for field in ["access", "content", "interface_mode", "kind", "origin_node_id", "record_commitment", "record_id", "schema", "sequence", "tier"]:
		if not record.has(field):
			return _failure("missing_record_field_" + field)
	if record.size() != 10:
		return _failure("record_has_unexpected_fields")
	if String(record["schema"]) != RECORD_SCHEMA or String(record["interface_mode"]) != INTERFACE_MODE:
		return _failure("record_schema_or_mode_mismatch")
	if String(record["origin_node_id"]) != expected_origin:
		return _failure("record_origin_mismatch")
	if not _valid_identifier(expected_origin) or not _valid_kind(String(record["kind"])) or int(record["sequence"]) < 1:
		return _failure("invalid_record_identity")
	var record_id_expression := RegEx.new()
	record_id_expression.compile("^rec_[0-9a-f]{40}$")
	if record_id_expression.search(String(record["record_id"])) == null:
		return _failure("invalid_record_id")
	var tier := String(record["tier"])
	if tier not in ALLOWED_TIERS:
		return _failure("non_replicable_tier")
	if not record["access"] is Dictionary or not record["content"] is Dictionary:
		return _failure("record_access_and_content_must_be_maps")
	var access_validation := _validate_access(tier, record["access"])
	if not access_validation.get("ok", false):
		return access_validation
	var content: Dictionary = record["content"]
	if content.size() != 4:
		return _failure("record_content_has_unexpected_fields")
	for content_field in ["cid", "content_commitment", "encrypted", "plaintext_in_catalog"]:
		if not content.has(content_field):
			return _failure("missing_record_content_field_" + content_field)
	if not _valid_cid_contract(String(content.get("cid", ""))) \
		or not _valid_sha256_commitment(String(content.get("content_commitment", ""))):
		return _failure("invalid_record_content_pointer")
	if bool(content.get("plaintext_in_catalog", true)):
		return _failure("inline_plaintext_not_allowed")
	if bool(content.get("encrypted", false)) != (tier != "public"):
		return _failure("tier_encryption_marker_mismatch")
	var id_source := record.duplicate(true)
	id_source.erase("record_commitment")
	id_source.erase("record_id")
	var id_canonical := _canonical(id_source)
	if not id_canonical.get("ok", false):
		return id_canonical
	var expected_record_id := "rec_" + IpfsSafeValueScript.sha256_hex(id_canonical["bytes"]).substr(0, 40)
	if String(record["record_id"]) != expected_record_id:
		return _failure("record_id_commitment_mismatch")
	var without_commitment := record.duplicate(true)
	without_commitment.erase("record_commitment")
	var canonical := _canonical(without_commitment)
	if not canonical.get("ok", false):
		return canonical
	var expected_commitment := "sha256:" + IpfsSafeValueScript.sha256_hex(canonical["bytes"])
	if String(record["record_commitment"]) != expected_commitment:
		return _failure("record_commitment_mismatch")
	return {"ok": true}


func _validate_access(tier: String, access: Dictionary) -> Dictionary:
	match tier:
		"public":
			if access.size() != 1 or String(access.get("audience", "")) != "anyone":
				return _failure("invalid_public_access_manifest")
			return {"ok": true}
		"lobby":
			if access.size() != 2 or not access.has("lobby_commitment") or not access.has("member_commitments"):
				return _failure("invalid_lobby_access_manifest")
			if not _valid_sha256_commitment(String(access["lobby_commitment"])):
				return _failure("invalid_lobby_commitment")
			return _validate_commitment_array(access["member_commitments"], "member")
		"private":
			if access.size() != 2 or not access.has("owner_commitment") or not access.has("reader_commitments"):
				return _failure("invalid_private_access_manifest")
			var owner := String(access["owner_commitment"])
			if not _valid_sha256_commitment(owner):
				return _failure("invalid_owner_commitment")
			var readers_result := _validate_commitment_array(access["reader_commitments"], "reader")
			if not readers_result.get("ok", false):
				return readers_result
			if owner not in access["reader_commitments"]:
				return _failure("owner_missing_from_reader_commitments")
			return {"ok": true}
	return _failure("unsupported_access_tier")


func _validate_commitment_array(value: Variant, label: String) -> Dictionary:
	if not value is Array:
		return _failure(label + "_commitments_must_be_array")
	var commitments: Array = value
	if commitments.is_empty() or commitments.size() > 256:
		return _failure(label + "_commitment_count_out_of_range")
	var normalized: Array[String] = []
	for commitment_value in commitments:
		var commitment := String(commitment_value)
		if not _valid_sha256_commitment(commitment) or commitment in normalized:
			return _failure("invalid_or_duplicate_" + label + "_commitment")
		normalized.append(commitment)
	var sorted := normalized.duplicate()
	sorted.sort()
	if normalized != sorted:
		return _failure(label + "_commitments_not_sorted")
	return {"ok": true}


func _record_authorized(record: Dictionary, auth: Dictionary, operation: String) -> bool:
	var built_in := false
	var tier := String(record.get("tier", ""))
	var access: Dictionary = record.get("access", {})
	match tier:
		"public":
			built_in = true
		"lobby":
			var member_id := String(auth.get("member_id", ""))
			var lobby_ids_value = auth.get("lobby_ids", [])
			if not _valid_identifier(member_id) or not lobby_ids_value is Array:
				return false
			var member_commitment := _commit(member_id)
			var lobby_commitments: Array[String] = []
			for lobby_value in lobby_ids_value:
				var lobby_id := String(lobby_value)
				if not _valid_identifier(lobby_id):
					return false
				lobby_commitments.append(_commit(lobby_id))
			built_in = member_commitment in access.get("member_commitments", []) \
				and String(access.get("lobby_commitment", "")) in lobby_commitments
		"private":
			var private_member_id := String(auth.get("member_id", ""))
			if not _valid_identifier(private_member_id):
				return false
			var reader_commitment := _commit(private_member_id)
			built_in = reader_commitment in access.get("reader_commitments", [])
	if not built_in:
		return false
	if not _authorization_hook.is_valid():
		return true
	var hook_result = _authorization_hook.call(operation, record.duplicate(true), auth.duplicate(true))
	if hook_result is bool:
		return hook_result
	if hook_result is Dictionary:
		return bool(hook_result.get("ok", false)) and bool(hook_result.get("allowed", false))
	return false


func _build_package_proof(bytes: PackedByteArray, commitment: String, signing_hook: Callable) -> Dictionary:
	if not signing_hook.is_valid():
		return {"ok": true, "proof": {
			"cryptographic_signature_created": false,
			"mode": "local_commitment_only",
			"package_commitment": commitment,
		}}
	var result = signing_hook.call(bytes, commitment)
	if not result is Dictionary or not result.get("ok", false):
		return _failure("package_signing_adapter_failed")
	var proof := {
		"algorithm": String(result.get("algorithm", "")),
		"mode": "external_origin_signature",
		"package_commitment": commitment,
		"signature": String(result.get("signature", "")),
		"signer_key_id": String(result.get("signer_key_id", "")),
	}
	var safety := IpfsSafeValueScript.validate(proof, "$package_proof", false)
	if not safety.get("ok", false) or proof["signature"].is_empty() or proof["signer_key_id"].is_empty():
		return _failure("invalid_package_signing_proof")
	return {"ok": true, "proof": proof}


func _verify_package_proof(bytes: PackedByteArray, commitment: String, proof: Dictionary) -> Dictionary:
	if String(proof.get("package_commitment", "")) != commitment:
		return _failure("package_proof_commitment_mismatch")
	match String(proof.get("mode", "")):
		"local_commitment_only":
			if bool(proof.get("cryptographic_signature_created", true)):
				return _failure("local_proof_claims_signature")
			return {"ok": true, "cryptographic_origin_verified": false}
		"external_origin_signature":
			if not _origin_verifier.is_valid():
				return _failure("origin_verifier_required")
			var result = _origin_verifier.call(bytes, proof.duplicate(true))
			if not result is Dictionary or not result.get("ok", false) or not result.get("valid", false):
				return _failure("origin_signature_invalid")
			return {"ok": true, "cryptographic_origin_verified": true}
	return _failure("unsupported_package_proof")


func _commit_identifier_array(values: Array) -> Dictionary:
	var commitments: Array[String] = []
	for value in values:
		var identifier := String(value)
		if not _valid_identifier(identifier):
			return _failure("invalid_access_identifier")
		var commitment := _commit(identifier)
		if commitment not in commitments:
			commitments.append(commitment)
	commitments.sort()
	if commitments.is_empty():
		return _failure("access_identifier_list_empty")
	return {"ok": true, "commitments": commitments}


func _matches_filters(record: Dictionary, filters: Dictionary) -> bool:
	for field in ["kind", "origin_node_id", "tier"]:
		if filters.has(field) and String(filters[field]) != String(record.get(field, "")):
			return false
	return true


func _sort_records(records: Array) -> void:
	records.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		var left_key := String(left.get("origin_node_id", "")) + ":" + "%020d" % int(left.get("sequence", 0)) + ":" + String(left.get("record_id", ""))
		var right_key := String(right.get("origin_node_id", "")) + ":" + "%020d" % int(right.get("sequence", 0)) + ":" + String(right.get("record_id", ""))
		return left_key < right_key
	)


func _canonical(value: Variant) -> Dictionary:
	return IpfsDagManifestScript.new().canonical_bytes(value)


func _valid_identifier(value: String) -> bool:
	if value.length() < 2 or value.length() > 128 or IpfsSafeValueScript.contains_network_coordinate(value):
		return false
	var expression := RegEx.new()
	expression.compile("^[A-Za-z0-9:_-]+$")
	return expression.search(value) != null


func _valid_kind(value: String) -> bool:
	if value.is_empty() or value.length() > 96:
		return false
	var expression := RegEx.new()
	expression.compile("^[a-z][a-z0-9._/-]*$")
	return expression.search(value) != null and ".." not in value


func _valid_cid_contract(value: String) -> bool:
	var expression := RegEx.new()
	expression.compile("^(baf[a-z2-7]{20,120}|cid-sim-b[a-z2-7]{52})$")
	return expression.search(value) != null


func _valid_sha256_commitment(value: String) -> bool:
	var expression := RegEx.new()
	expression.compile("^sha256:[0-9a-f]{64}$")
	return expression.search(value) != null


func _receipt(operation: String, details: Dictionary) -> Dictionary:
	return {
		"component_id": COMPONENT_ID,
		"details": details.duplicate(true),
		"interface_mode": INTERFACE_MODE,
		"live_network_operation_performed": false,
		"operation": operation,
		"raw_network_coordinates_persisted": false,
	}


func _commit(value: String) -> String:
	return "sha256:" + IpfsSafeValueScript.sha256_text(value)


func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "component_id": COMPONENT_ID}
