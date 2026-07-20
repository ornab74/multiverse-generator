extends RefCounted
class_name IpfsSafeValue

## Shared fail-closed validation for every local IPFS-facing component.
##
## The component rejects secret-bearing field names and literal network
## coordinates before values can enter a manifest, mutable-name record, peer
## directory, or replication envelope. Relay-only libp2p routes are allowed
## because they contain Peer IDs, not IP/DNS coordinates.

const FORBIDDEN_FIELD_NAMES := {
	"credential": true,
	"credentials": true,
	"dm_plaintext": true,
	"ip_address": true,
	"ip_addresses": true,
	"ipv4": true,
	"ipv6": true,
	"message_body": true,
	"mnemonic": true,
	"password": true,
	"private_key": true,
	"private_keys": true,
	"raw_ip": true,
	"raw_ips": true,
	"recovery_phrase": true,
	"secret_key": true,
	"secret_keys": true,
	"seed_phrase": true,
	"socket_address": true,
	"wallet_seed": true,
}

const MAX_VALIDATION_DEPTH := 48
const MAX_COLLECTION_ITEMS := 4096
const MAX_STRING_BYTES := 256 * 1024
const MAX_BYTE_ARRAY_BYTES := 16 * 1024 * 1024


static func validate(value: Variant, path: String = "$", allow_bytes: bool = true) -> Dictionary:
	var reason := _unsafe_reason(value, path, allow_bytes, 0)
	return {"ok": reason.is_empty(), "reason": reason}


static func contains_network_coordinate(value: Variant) -> bool:
	var text := String(value) if value is String else JSON.stringify(value)
	if text.is_empty():
		return false

	var ipv4 := RegEx.new()
	ipv4.compile("(^|[^0-9])([0-9]{1,3}\\.){3}[0-9]{1,3}([^0-9]|$)")
	if ipv4.search(text) != null:
		return true

	# A deliberately broad IPv6 detector. False positives are safer than
	# persisting an endpoint; ordinary commitments only contain one colon.
	var ipv6 := RegEx.new()
	ipv6.compile("(^|[^A-Za-z0-9])(([0-9A-Fa-f]{0,4}:){2,}[0-9A-Fa-f]{0,4})([^A-Za-z0-9]|$)")
	if ipv6.search(text) != null or "::" in text:
		return true

	# Direct DNS/IP transports are not valid in the relay-only directory.
	var lowered := text.to_lower()
	for marker in ["/ip4/", "/ip6/", "/dns/", "/dns4/", "/dns6/"]:
		if marker in lowered:
			return true
	return false


static func sha256_hex(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	var start_error := context.start(HashingContext.HASH_SHA256)
	if start_error != OK:
		return ""
	var update_error := context.update(bytes)
	if update_error != OK:
		return ""
	return context.finish().hex_encode()


static func sha256_text(value: String) -> String:
	return sha256_hex(value.to_utf8_buffer())


static func _unsafe_reason(value: Variant, path: String, allow_bytes: bool, depth: int) -> String:
	if depth > MAX_VALIDATION_DEPTH:
		return "validation_depth_exceeded_at_" + path
	if value == null or value is bool or value is int:
		return ""
	if value is String:
		if value.to_utf8_buffer().size() > MAX_STRING_BYTES:
			return "string_too_large_at_" + path
		if contains_network_coordinate(value):
			return "network_coordinate_rejected_at_" + path
		return ""
	if value is PackedByteArray:
		if not allow_bytes:
			return "bytes_not_allowed_at_" + path
		return "" if value.size() <= MAX_BYTE_ARRAY_BYTES else "byte_array_too_large_at_" + path
	if value is float:
		return "float_not_canonical_at_" + path
	if value is Array:
		if value.size() > MAX_COLLECTION_ITEMS:
			return "array_too_large_at_" + path
		for index in value.size():
			var child_reason := _unsafe_reason(value[index], path + "[" + str(index) + "]", allow_bytes, depth + 1)
			if not child_reason.is_empty():
				return child_reason
		return ""
	if value is Dictionary:
		if value.size() > MAX_COLLECTION_ITEMS:
			return "map_too_large_at_" + path
		for key_value in value.keys():
			if not key_value is String:
				return "non_string_map_key_at_" + path
			var key := String(key_value)
			var lowered_key := key.to_lower()
			if key.to_utf8_buffer().size() > MAX_STRING_BYTES:
				return "map_key_too_large_at_" + path
			if contains_network_coordinate(key):
				return "network_coordinate_rejected_at_" + path + ".<key>"
			if FORBIDDEN_FIELD_NAMES.has(lowered_key):
				return "forbidden_field_" + lowered_key + "_at_" + path
			var child_reason := _unsafe_reason(value[key_value], path + "." + key, allow_bytes, depth + 1)
			if not child_reason.is_empty():
				return child_reason
		return ""
	return "unsupported_value_type_at_" + path
