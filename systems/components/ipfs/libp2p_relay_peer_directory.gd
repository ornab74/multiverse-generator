extends RefCounted
class_name Libp2pRelayPeerDirectory

## Capability-scoped lobby peer directory that accepts relay circuits only.
##
## Raw IP, DNS, TCP, and UDP coordinates are rejected. Membership is stored as
## commitments, so snapshots never expose the accepted member list.

signal directory_changed(revision: int, change_commitment: String)

const IpfsSafeValueScript = preload("res://systems/components/ipfs/ipfs_safe_value.gd")

const COMPONENT_ID := "ipfs.libp2p-relay-peer-directory/v1"
const INTERFACE_MODE := "LOCAL_RELAY_DIRECTORY_SIMULATION"
const MAX_MEMBERS := 256
const MAX_PEERS := 128
const MAX_ROUTES_PER_PEER := 4
const MAX_ENTRY_LIFETIME_SECONDS := 24 * 60 * 60
const CAPABILITY_ALLOWLIST := [
	"catalog.read",
	"catalog.replicate",
	"lobby.presence",
	"lobby.sync",
	"rules.vote",
]

var _configured := false
var _lobby_commitment := ""
var _epoch := 0
var _revision := 0
var _authorized_member_commitments: Dictionary = {}
var _entries: Dictionary = {}


func configure(lobby_id: String, accepted_member_ids: Array, epoch: int) -> Dictionary:
	if _configured:
		return _failure("directory_already_configured")
	if not _valid_scope_id(lobby_id) or accepted_member_ids.is_empty() or epoch < 1:
		return _failure("invalid_directory_scope")
	var member_result := _member_commitment_set(accepted_member_ids)
	if not member_result.get("ok", false):
		return member_result
	_lobby_commitment = _commit(lobby_id)
	_authorized_member_commitments = member_result["members"]
	_epoch = epoch
	_configured = true
	return {
		"ok": true,
		"receipt": _redacted_receipt("configured"),
	}


func upsert_peer(
	actor_member_id: String,
	peer_id: String,
	relay_routes: Array,
	capabilities: Array,
	expires_at_unix: int,
	now_unix: int
) -> Dictionary:
	if not _configured:
		return _failure("directory_not_configured")
	if not _authorized(actor_member_id):
		return _failure("member_not_authorized")
	if not _valid_peer_id(peer_id):
		return _failure("invalid_peer_id")
	if relay_routes.is_empty() or relay_routes.size() > MAX_ROUTES_PER_PEER:
		return _failure("invalid_relay_route_count")
	if expires_at_unix <= now_unix or expires_at_unix - now_unix > MAX_ENTRY_LIFETIME_SECONDS:
		return _failure("peer_entry_expiry_out_of_range")
	if not _entries.has(peer_id) and _entries.size() >= MAX_PEERS:
		return _failure("peer_directory_full")

	var normalized_routes: Array[String] = []
	for route_value in relay_routes:
		var route := String(route_value)
		if not _valid_relay_route(route, peer_id):
			return _failure("non_relay_or_unsafe_route_rejected")
		if route not in normalized_routes:
			normalized_routes.append(route)
	normalized_routes.sort()

	var normalized_capabilities_result := _normalize_capabilities(capabilities)
	if not normalized_capabilities_result.get("ok", false):
		return normalized_capabilities_result
	_revision += 1
	_entries[peer_id] = {
		"capabilities": normalized_capabilities_result["capabilities"],
		"epoch": _epoch,
		"expires_at_unix": expires_at_unix,
		"peer_id": peer_id,
		"relay_routes": normalized_routes,
		"revision": _revision,
	}
	var change_commitment := _commit(peer_id + "|" + str(_revision) + "|" + str(_epoch))
	directory_changed.emit(_revision, change_commitment)
	return {
		"ok": true,
		"change_commitment": change_commitment,
		"revision": _revision,
		"raw_network_coordinates_persisted": false,
	}


func remove_peer(actor_member_id: String, peer_id: String) -> Dictionary:
	if not _configured or not _authorized(actor_member_id):
		return _failure("member_not_authorized")
	if not _entries.has(peer_id):
		return _failure("peer_not_found")
	_entries.erase(peer_id)
	_revision += 1
	var commitment := _commit(peer_id + "|removed|" + str(_revision))
	directory_changed.emit(_revision, commitment)
	return {"ok": true, "change_commitment": commitment, "revision": _revision}


func rotate_epoch(actor_member_id: String, accepted_member_ids: Array, next_epoch: int) -> Dictionary:
	if not _configured or not _authorized(actor_member_id):
		return _failure("member_not_authorized")
	if next_epoch != _epoch + 1:
		return _failure("epoch_must_increment_by_one")
	var member_result := _member_commitment_set(accepted_member_ids)
	if not member_result.get("ok", false):
		return member_result
	_authorized_member_commitments = member_result["members"]
	_epoch = next_epoch
	_entries.clear()
	_revision += 1
	var commitment := _commit(_lobby_commitment + "|epoch|" + str(_epoch))
	directory_changed.emit(_revision, commitment)
	return {
		"ok": true,
		"receipt": _redacted_receipt("epoch_rotated"),
		"previous_peer_entries_retained": false,
	}


func export_for_member(requester_member_id: String, now_unix: int) -> Dictionary:
	if not _configured:
		return _failure("directory_not_configured")
	if not _authorized(requester_member_id):
		return _failure("member_not_authorized")
	_prune_expired(now_unix)
	var peers: Array[Dictionary] = []
	var peer_ids: Array = _entries.keys()
	peer_ids.sort()
	for peer_id_value in peer_ids:
		peers.append(Dictionary(_entries[peer_id_value]).duplicate(true))
	return {
		"ok": true,
		"directory": {
			"component_id": COMPONENT_ID,
			"epoch": _epoch,
			"interface_mode": INTERFACE_MODE,
			"lobby_commitment": _lobby_commitment,
			"member_count": _authorized_member_commitments.size(),
			"peers": peers,
			"revision": _revision,
			"raw_network_coordinates_persisted": false,
		},
	}


func get_redacted_status() -> Dictionary:
	if not _configured:
		return {"configured": false, "component_id": COMPONENT_ID, "interface_mode": INTERFACE_MODE}
	return _redacted_receipt("status")


func _prune_expired(now_unix: int) -> void:
	var expired: Array[String] = []
	for peer_id_value in _entries.keys():
		var peer_id := String(peer_id_value)
		if int(_entries[peer_id].get("expires_at_unix", 0)) <= now_unix:
			expired.append(peer_id)
	if expired.is_empty():
		return
	for peer_id in expired:
		_entries.erase(peer_id)
	_revision += 1


func _normalize_capabilities(capabilities: Array) -> Dictionary:
	var normalized: Array[String] = []
	for capability_value in capabilities:
		var capability := String(capability_value)
		if capability not in CAPABILITY_ALLOWLIST:
			return _failure("capability_not_allowed")
		if capability not in normalized:
			normalized.append(capability)
	normalized.sort()
	return {"ok": true, "capabilities": normalized}


func _member_commitment_set(member_ids: Array) -> Dictionary:
	if member_ids.is_empty() or member_ids.size() > MAX_MEMBERS:
		return _failure("member_count_out_of_range")
	var members: Dictionary = {}
	for member_value in member_ids:
		var member_id := String(member_value)
		if not _valid_scope_id(member_id):
			return _failure("invalid_member_id")
		var commitment := _commit(member_id)
		if members.has(commitment):
			return _failure("duplicate_member_id")
		members[commitment] = true
	return {"ok": true, "members": members}


func _authorized(member_id: String) -> bool:
	return _valid_scope_id(member_id) and _authorized_member_commitments.has(_commit(member_id))


func _valid_relay_route(route: String, destination_peer_id: String) -> bool:
	if route.length() > 512 or IpfsSafeValueScript.contains_network_coordinate(route):
		return false
	var parts := route.split("/", false)
	if parts.size() != 5:
		return false
	if parts[0] != "p2p" or parts[2] != "p2p-circuit" or parts[3] != "p2p":
		return false
	var relay_peer_id := String(parts[1])
	var route_destination := String(parts[4])
	return _valid_peer_id(relay_peer_id) \
		and route_destination == destination_peer_id \
		and relay_peer_id != destination_peer_id


func _valid_peer_id(value: String) -> bool:
	if value.length() < 8 or value.length() > 128 or IpfsSafeValueScript.contains_network_coordinate(value):
		return false
	var expression := RegEx.new()
	expression.compile("^[A-Za-z0-9_-]+$")
	return expression.search(value) != null


func _valid_scope_id(value: String) -> bool:
	if value.length() < 2 or value.length() > 128 or IpfsSafeValueScript.contains_network_coordinate(value):
		return false
	var expression := RegEx.new()
	expression.compile("^[A-Za-z0-9:_-]+$")
	return expression.search(value) != null


func _redacted_receipt(operation: String) -> Dictionary:
	return {
		"component_id": COMPONENT_ID,
		"epoch": _epoch,
		"interface_mode": INTERFACE_MODE,
		"lobby_commitment": _lobby_commitment,
		"member_count": _authorized_member_commitments.size(),
		"operation": operation,
		"peer_count": _entries.size(),
		"raw_member_ids_exported": false,
		"raw_network_coordinates_persisted": false,
		"revision": _revision,
	}


func _commit(value: String) -> String:
	return "sha256:" + IpfsSafeValueScript.sha256_text(value)


func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "component_id": COMPONENT_ID}
