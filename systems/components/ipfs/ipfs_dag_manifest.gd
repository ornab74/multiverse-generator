extends RefCounted
class_name IpfsDagManifest

## Deterministic DAG manifest boundary.
##
## This produces a canonical interface encoding for local protocol tests. It is
## intentionally *not* a DAG-CBOR encoder. A production adapter must encode the
## validated manifest as DAG-CBOR and calculate the real CID from those bytes.

const IpfsSafeValueScript = preload("res://systems/components/ipfs/ipfs_safe_value.gd")

const COMPONENT_ID := "ipfs.dag-manifest/v1"
const INTERFACE_MODE := "LOCAL_CANONICAL_DAG_SIMULATION"
const SCHEMA := "nexus.ipfs.dag-manifest/v1"
const CODEC_CONTRACT := "dag-cbor"
const LOCAL_ENCODING := "nexus-canonical-interface/v1"
const MAX_CANONICAL_BYTES := 1024 * 1024
const MAX_DEPTH := 48
const MAX_COLLECTION_ITEMS := 4096


func build(kind: String, root: Dictionary, links: Array = [], metadata: Dictionary = {}) -> Dictionary:
	if not _valid_kind(kind):
		return _failure("invalid_manifest_kind")
	var root_safety := IpfsSafeValueScript.validate(root, "$.root")
	if not root_safety.get("ok", false):
		return _failure(String(root_safety.get("reason", "unsafe_root")))
	var metadata_safety := IpfsSafeValueScript.validate(metadata, "$.metadata")
	if not metadata_safety.get("ok", false):
		return _failure(String(metadata_safety.get("reason", "unsafe_metadata")))

	var normalized_links_result := _normalize_links(links)
	if not normalized_links_result.get("ok", false):
		return normalized_links_result

	var manifest := {
		"canonical_encoding": LOCAL_ENCODING,
		"codec_contract": CODEC_CONTRACT,
		"kind": kind,
		"links": normalized_links_result["links"],
		"metadata": metadata.duplicate(true),
		"root": root.duplicate(true),
		"schema": SCHEMA,
	}
	var canonical_result := canonical_bytes(manifest)
	if not canonical_result.get("ok", false):
		return canonical_result
	return {
		"ok": true,
		"component_id": COMPONENT_ID,
		"interface_mode": INTERFACE_MODE,
		"manifest": manifest,
		"canonical_bytes": canonical_result["bytes"],
		"canonical_text": canonical_result["text"],
		"canonical_commitment": "sha256:" + IpfsSafeValueScript.sha256_hex(canonical_result["bytes"]),
		"dag_cbor_encoded": false,
		"production_adapter_required": true,
	}


func validate_manifest(manifest: Dictionary) -> Dictionary:
	var required := ["canonical_encoding", "codec_contract", "kind", "links", "metadata", "root", "schema"]
	if manifest.size() != required.size():
		return _failure("manifest_has_unexpected_fields")
	for field in required:
		if not manifest.has(field):
			return _failure("missing_manifest_field_" + field)
	if String(manifest.get("schema", "")) != SCHEMA:
		return _failure("unsupported_manifest_schema")
	if String(manifest.get("codec_contract", "")) != CODEC_CONTRACT:
		return _failure("unsupported_codec_contract")
	if String(manifest.get("canonical_encoding", "")) != LOCAL_ENCODING:
		return _failure("unsupported_local_encoding")
	if not _valid_kind(String(manifest.get("kind", ""))):
		return _failure("invalid_manifest_kind")
	if not manifest.get("root") is Dictionary or not manifest.get("metadata") is Dictionary:
		return _failure("root_and_metadata_must_be_maps")
	if not manifest.get("links") is Array:
		return _failure("links_must_be_array")

	var safety := IpfsSafeValueScript.validate(manifest, "$manifest")
	if not safety.get("ok", false):
		return _failure(String(safety.get("reason", "unsafe_manifest")))
	var normalized_links_result := _normalize_links(manifest["links"])
	if not normalized_links_result.get("ok", false):
		return normalized_links_result
	if normalized_links_result["links"] != manifest["links"]:
		return _failure("links_not_in_canonical_order")
	var canonical_result := canonical_bytes(manifest)
	if not canonical_result.get("ok", false):
		return canonical_result
	return {
		"ok": true,
		"canonical_bytes": canonical_result["bytes"],
		"canonical_text": canonical_result["text"],
		"canonical_commitment": "sha256:" + IpfsSafeValueScript.sha256_hex(canonical_result["bytes"]),
	}


func canonical_bytes(value: Variant) -> Dictionary:
	var safety := IpfsSafeValueScript.validate(value, "$canonical")
	if not safety.get("ok", false):
		return _failure(String(safety.get("reason", "unsafe_canonical_value")))
	var result := _canonical_value(value, 0)
	if not result.get("ok", false):
		return result
	var text_value := String(result["value"])
	var bytes := text_value.to_utf8_buffer()
	if bytes.size() > MAX_CANONICAL_BYTES:
		return _failure("canonical_value_too_large")
	return {"ok": true, "bytes": bytes, "text": text_value}


func _normalize_links(links: Array) -> Dictionary:
	if links.size() > MAX_COLLECTION_ITEMS:
		return _failure("too_many_links")
	var normalized: Array[Dictionary] = []
	var seen_names: Dictionary = {}
	for candidate in links:
		if not candidate is Dictionary:
			return _failure("link_must_be_map")
		var link: Dictionary = candidate
		var name := String(link.get("name", ""))
		var cid := String(link.get("cid", ""))
		var role := String(link.get("role", "child"))
		if not _valid_link_name(name) or seen_names.has(name):
			return _failure("invalid_or_duplicate_link_name")
		if not _valid_cid_contract(cid):
			return _failure("invalid_link_cid")
		if role not in ["asset", "catalog", "child", "rules", "snapshot"]:
			return _failure("invalid_link_role")
		seen_names[name] = true
		normalized.append({"cid": cid, "name": name, "role": role})
	normalized.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		var left_key := String(left["name"]) + "|" + String(left["cid"])
		var right_key := String(right["name"]) + "|" + String(right["cid"])
		return left_key < right_key
	)
	return {"ok": true, "links": normalized}


func _canonical_value(value: Variant, depth: int) -> Dictionary:
	if depth > MAX_DEPTH:
		return _failure("canonical_depth_exceeded")
	if value == null:
		return {"ok": true, "value": "null"}
	if value is bool:
		return {"ok": true, "value": "true" if value else "false"}
	if value is int:
		return {"ok": true, "value": str(value)}
	if value is String:
		return {"ok": true, "value": JSON.stringify(value)}
	if value is PackedByteArray:
		return {"ok": true, "value": "bytes(" + value.hex_encode() + ")"}
	if value is Array:
		if value.size() > MAX_COLLECTION_ITEMS:
			return _failure("canonical_array_too_large")
		var array_parts: Array[String] = []
		for item in value:
			var item_result := _canonical_value(item, depth + 1)
			if not item_result.get("ok", false):
				return item_result
			array_parts.append(String(item_result["value"]))
		return {"ok": true, "value": "[" + ",".join(array_parts) + "]"}
	if value is Dictionary:
		if value.size() > MAX_COLLECTION_ITEMS:
			return _failure("canonical_map_too_large")
		var keys: Array[String] = []
		for key_value in value.keys():
			if not key_value is String:
				return _failure("canonical_map_key_must_be_string")
			keys.append(String(key_value))
		keys.sort()
		var map_parts: Array[String] = []
		for key in keys:
			var child_result := _canonical_value(value[key], depth + 1)
			if not child_result.get("ok", false):
				return child_result
			map_parts.append(JSON.stringify(key) + ":" + String(child_result["value"]))
		return {"ok": true, "value": "{" + ",".join(map_parts) + "}"}
	return _failure("unsupported_canonical_type")


func _valid_kind(value: String) -> bool:
	if value.is_empty() or value.length() > 96 or ".." in value or value.begins_with("/"):
		return false
	var expression := RegEx.new()
	expression.compile("^[a-z][a-z0-9._/-]*$")
	return expression.search(value) != null


func _valid_link_name(value: String) -> bool:
	if value.is_empty() or value.length() > 128 or ".." in value or value.begins_with("/"):
		return false
	var expression := RegEx.new()
	expression.compile("^[A-Za-z0-9][A-Za-z0-9._/-]*$")
	return expression.search(value) != null


func _valid_cid_contract(value: String) -> bool:
	var expression := RegEx.new()
	expression.compile("^(baf[a-z2-7]{20,120}|cid-sim-b[a-z2-7]{52})$")
	return expression.search(value) != null


func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
