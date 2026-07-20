extends RefCounted
class_name IpfsContentCommitment

## Local content-commitment calculator with a production CID adapter contract.
##
## SHA-256 is genuinely calculated over the supplied bytes. `cid_preview` is a
## deterministic UI/test identifier only; it is not a standards-compliant CID.

const IpfsDagManifestScript = preload("res://systems/components/ipfs/ipfs_dag_manifest.gd")
const IpfsSafeValueScript = preload("res://systems/components/ipfs/ipfs_safe_value.gd")

const COMPONENT_ID := "ipfs.content-commitment/v1"
const INTERFACE_MODE := "LOCAL_CONTENT_COMMITMENT_ONLY"
const MAX_CONTENT_BYTES := 16 * 1024 * 1024
const BASE32_ALPHABET := "abcdefghijklmnopqrstuvwxyz234567"
const ALLOWED_CODEC_CONTRACTS := ["dag-cbor", "dag-json", "raw"]


func commit_bytes(content: PackedByteArray, codec_contract: String = "raw") -> Dictionary:
	if codec_contract not in ALLOWED_CODEC_CONTRACTS:
		return _failure("unsupported_codec_contract")
	if content.size() > MAX_CONTENT_BYTES:
		return _failure("content_exceeds_local_commitment_limit")
	var digest_hex := IpfsSafeValueScript.sha256_hex(content)
	if digest_hex.is_empty():
		return _failure("sha256_calculation_failed")
	var digest_bytes := digest_hex.hex_decode()
	var preview := "cid-sim-b" + _base32_lower(digest_bytes)
	return {
		"ok": true,
		"receipt": {
			"byte_length": content.size(),
			"component_id": COMPONENT_ID,
			"cid_contract": "cidv1",
			"cid_is_live": false,
			"cid_preview": preview,
			"codec_contract": codec_contract,
			"digest_algorithm": "sha2-256",
			"digest_commitment": "sha256:" + digest_hex,
			"interface_mode": INTERFACE_MODE,
			"multihash_encoded": false,
			"production_cid_adapter_required": true,
		},
	}


func commit_manifest(manifest: Dictionary) -> Dictionary:
	var dag := IpfsDagManifestScript.new()
	var validation := dag.validate_manifest(manifest)
	if not validation.get("ok", false):
		return validation
	var result := commit_bytes(validation["canonical_bytes"], "dag-cbor")
	if result.get("ok", false):
		result["receipt"]["canonical_encoding"] = IpfsDagManifestScript.LOCAL_ENCODING
		result["receipt"]["dag_cbor_encoded"] = false
	return result


func verify_bytes(content: PackedByteArray, receipt: Dictionary) -> Dictionary:
	if String(receipt.get("interface_mode", "")) != INTERFACE_MODE:
		return _failure("unsupported_commitment_receipt")
	var expected := commit_bytes(content, String(receipt.get("codec_contract", "")))
	if not expected.get("ok", false):
		return expected
	var expected_receipt: Dictionary = expected["receipt"]
	if String(receipt.get("digest_commitment", "")) != String(expected_receipt["digest_commitment"]):
		return _failure("digest_commitment_mismatch")
	if String(receipt.get("cid_preview", "")) != String(expected_receipt["cid_preview"]):
		return _failure("cid_preview_mismatch")
	if int(receipt.get("byte_length", -1)) != content.size():
		return _failure("byte_length_mismatch")
	return {"ok": true, "verified": true, "live_cid_verified": false}


func verify_manifest(manifest: Dictionary, receipt: Dictionary) -> Dictionary:
	var dag := IpfsDagManifestScript.new()
	var validation := dag.validate_manifest(manifest)
	if not validation.get("ok", false):
		return validation
	return verify_bytes(validation["canonical_bytes"], receipt)


func _base32_lower(bytes: PackedByteArray) -> String:
	var output := ""
	var buffer := 0
	var buffered_bits := 0
	for byte_value in bytes:
		buffer = (buffer << 8) | int(byte_value)
		buffered_bits += 8
		while buffered_bits >= 5:
			buffered_bits -= 5
			var index := (buffer >> buffered_bits) & 31
			output += BASE32_ALPHABET[index]
		if buffered_bits == 0:
			buffer = 0
		else:
			buffer = buffer & ((1 << buffered_bits) - 1)
	if buffered_bits > 0:
		var final_index := (buffer << (5 - buffered_bits)) & 31
		output += BASE32_ALPHABET[final_index]
	return output


func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
