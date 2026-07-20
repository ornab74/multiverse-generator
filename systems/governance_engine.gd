extends RefCounted
class_name GovernanceEngine

## Deterministic, fail-closed governance for shared shard mutations.
##
## Cryptographic proof verification is deliberately injected by the host. This
## class never treats a boolean supplied by proposal content as a signature.

enum ChangeType {
	COSMETIC,
	RULE,
	ASSET,
	CODE,
}

enum DiffOperation {
	ADD,
	REPLACE,
	REMOVE,
}

enum ProposalState {
	DRAFT,
	QUARANTINED,
	AWAITING_REVIEW,
	AWAITING_CONSENT,
	APPROVED,
	REJECTED,
	EXPIRED,
}

const SCHEMA_VERSION := 1
const DOMAIN_SEPARATOR := "NEXUS_GOVERNANCE_PROPOSAL_V1"
const MIN_REPLAY_COUNT := 3
const MAX_PROPOSAL_LIFETIME_SECONDS := 7 * 24 * 60 * 60
const MAX_DELEGATION_LIFETIME_SECONDS := 30 * 24 * 60 * 60
const MAX_ADVISORY_MEMBER_SHARE := 0.35
const MAX_PLAYTIME_SECONDS := 500 * 60 * 60
const MAX_ACTIVITY_EVENTS := 1000

const CAPABILITY_ALLOWLIST := [
	"assets.mount",
	"code.module.mount",
	"rules.propose",
	"telemetry.aggregate",
	"world.read",
	"world.visual.write",
]

const SENSITIVE_SCOPES := ["rule", "asset", "code"]

const INJECTION_MARKERS := [
	"ignore previous instructions",
	"ignore all instructions",
	"reveal the system prompt",
	"system message",
	"developer message",
	"<tool_call",
	"</tool_call",
	"bypass safety",
	"override policy",
	"act as root",
	"exfiltrate",
]


class ProposalDiff:
	extends RefCounted

	var change_type: int = ChangeType.COSMETIC
	var operation: int = DiffOperation.REPLACE
	var target := ""
	var before_value = null
	var after_value = null
	var before_hash := ""
	var after_hash := ""
	var capability := ""
	var metadata: Dictionary = {}


	func to_manifest_entry() -> Dictionary:
		return {
			"after_hash": after_hash,
			"before_hash": before_hash,
			"capability": capability,
			"change_type": change_type,
			"metadata": metadata.duplicate(true),
			"operation": operation,
			"target": target,
		}


class Proposal:
	extends RefCounted

	var proposal_id := ""
	var lobby_id := ""
	var author_id := ""
	var title := ""
	var summary := ""
	var nonce := 0
	var created_at_unix := 0
	var expires_at_unix := 0
	var diffs: Array = []
	var requested_capabilities := PackedStringArray()
	var manifest: Dictionary = {}
	var manifest_hash := ""
	var proposal_hash := ""
	var state: int = ProposalState.DRAFT
	var quarantine_reasons: Array[String] = []
	var deterministic_report: Dictionary = {}
	var security_review: Dictionary = {}
	var consents: Dictionary = {}
	var advisory_score := 0.5
	var advisory_breakdown: Dictionary = {}


	func is_sensitive() -> bool:
		for diff in diffs:
			if diff.change_type in [ChangeType.RULE, ChangeType.ASSET, ChangeType.CODE]:
				return true
		return false


	func snapshot() -> Dictionary:
		return {
			"advisory_score": advisory_score,
			"author_id": author_id,
			"lobby_id": lobby_id,
			"manifest": manifest.duplicate(true),
			"manifest_hash": manifest_hash,
			"proposal_hash": proposal_hash,
			"proposal_id": proposal_id,
			"quarantine_reasons": quarantine_reasons.duplicate(),
			"state": state,
		}


var _proof_verifier: Callable
var _lobbies: Dictionary = {}
var _delegations: Dictionary = {}


func _init(proof_verifier: Callable = Callable()) -> void:
	_proof_verifier = proof_verifier


func set_proof_verifier(proof_verifier: Callable) -> void:
	_proof_verifier = proof_verifier


func register_lobby(lobby_id: String, members: Array[Dictionary]) -> Dictionary:
	var clean_lobby_id := _sanitize_identifier(lobby_id)
	if clean_lobby_id.is_empty():
		return _result(false, "invalid_lobby_id")
	var member_map: Dictionary = {}
	for raw_member in members:
		var member_id := _sanitize_identifier(str(raw_member.get("member_id", "")))
		if member_id.is_empty() or member_map.has(member_id):
			return _result(false, "invalid_or_duplicate_member")
		member_map[member_id] = {
			"activity_events": clampi(int(raw_member.get("activity_events", 0)), 0, MAX_ACTIVITY_EVENTS),
			"member_id": member_id,
			"online": bool(raw_member.get("online", false)),
			"playtime_seconds": clampi(int(raw_member.get("playtime_seconds", 0)), 0, MAX_PLAYTIME_SECONDS),
		}
	if member_map.is_empty():
		return _result(false, "lobby_requires_members")
	_lobbies[clean_lobby_id] = member_map
	if not _delegations.has(clean_lobby_id):
		_delegations[clean_lobby_id] = {}
	return {
		"ok": true,
		"lobby_id": clean_lobby_id,
		"member_count": member_map.size(),
	}


func set_member_online(lobby_id: String, member_id: String, online: bool) -> bool:
	if not _has_member(lobby_id, member_id):
		return false
	_lobbies[lobby_id][member_id]["online"] = online
	return true


func create_proposal(spec: Dictionary, now_unix: int) -> Proposal:
	var proposal := Proposal.new()
	proposal.proposal_id = _sanitize_identifier(str(spec.get("proposal_id", "")))
	proposal.lobby_id = _sanitize_identifier(str(spec.get("lobby_id", "")))
	proposal.author_id = _sanitize_identifier(str(spec.get("author_id", "")))
	proposal.nonce = int(spec.get("nonce", 0))
	proposal.created_at_unix = now_unix
	proposal.expires_at_unix = int(spec.get("expires_at_unix", now_unix + 3600))
	proposal.title = _sanitize_text(str(spec.get("title", "Untitled proposal")), 120)
	proposal.summary = _sanitize_text(str(spec.get("summary", "")), 2000)

	if proposal.proposal_id.is_empty():
		_add_quarantine(proposal, "invalid_proposal_id")
	if not _has_member(proposal.lobby_id, proposal.author_id):
		_add_quarantine(proposal, "author_not_in_lobby")
	if proposal.nonce < 0:
		_add_quarantine(proposal, "invalid_nonce")
	if proposal.expires_at_unix <= now_unix:
		_add_quarantine(proposal, "proposal_already_expired")
	if proposal.expires_at_unix - now_unix > MAX_PROPOSAL_LIFETIME_SECONDS:
		_add_quarantine(proposal, "proposal_expiry_exceeds_limit")
	if _contains_prompt_injection(proposal.title) or _contains_prompt_injection(proposal.summary):
		_add_quarantine(proposal, "prompt_injection_marker")

	var capabilities_result := _sanitize_capabilities(spec.get("requested_capabilities", []))
	proposal.requested_capabilities = capabilities_result["capabilities"]
	for reason in capabilities_result["reasons"]:
		_add_quarantine(proposal, reason)

	var raw_diffs = spec.get("diffs", [])
	if not raw_diffs is Array or raw_diffs.is_empty() or raw_diffs.size() > 64:
		_add_quarantine(proposal, "invalid_diff_count")
	else:
		for raw_diff in raw_diffs:
			var parsed = _parse_diff(raw_diff, proposal)
			if parsed != null:
				proposal.diffs.append(parsed)

	_validate_least_privilege(proposal)
	proposal.manifest = _build_manifest(proposal)
	proposal.manifest_hash = hash_value(proposal.manifest)
	proposal.proposal_hash = hash_value({
		"domain": DOMAIN_SEPARATOR,
		"manifest_hash": proposal.manifest_hash,
		"nonce": proposal.nonce,
	})
	if proposal.quarantine_reasons.is_empty():
		proposal.state = ProposalState.AWAITING_REVIEW
	else:
		proposal.state = ProposalState.QUARANTINED
	return proposal


func verify_manifest(proposal: Proposal) -> Dictionary:
	var rebuilt := _build_manifest(proposal)
	var rebuilt_hash := hash_value(rebuilt)
	var valid := (
		rebuilt_hash == proposal.manifest_hash
		and canonical_json(rebuilt) == canonical_json(proposal.manifest)
		and proposal.proposal_hash == hash_value({
			"domain": DOMAIN_SEPARATOR,
			"manifest_hash": rebuilt_hash,
			"nonce": proposal.nonce,
		})
	)
	return {
		"actual_manifest_hash": rebuilt_hash,
		"expected_manifest_hash": proposal.manifest_hash,
		"ok": valid,
	}


func verify_deterministic_replays(proposal: Proposal, replays: Array[Dictionary]) -> Dictionary:
	var reasons: Array[String] = []
	var manifest_check := verify_manifest(proposal)
	if not manifest_check["ok"]:
		reasons.append("manifest_hash_mismatch")
	if replays.size() < MIN_REPLAY_COUNT:
		reasons.append("insufficient_replays")

	var baseline: Dictionary = {}
	for replay in replays:
		for required_key in ["proposal_hash", "input_hash", "output_state_hash", "event_log_hash", "reducer_version", "tick_count"]:
			if not replay.has(required_key):
				reasons.append("replay_missing_" + required_key)
		if str(replay.get("proposal_hash", "")) != proposal.proposal_hash:
			reasons.append("replay_proposal_hash_mismatch")
		if baseline.is_empty():
			baseline = replay.duplicate(true)
		else:
			for stable_key in ["input_hash", "output_state_hash", "event_log_hash", "reducer_version", "tick_count"]:
				if replay.get(stable_key) != baseline.get(stable_key):
					reasons.append("nondeterministic_" + stable_key)

	reasons = _unique_sorted_strings(reasons)
	var report := {
		"checked_at_unix": proposal.created_at_unix,
		"fingerprint": "",
		"ok": reasons.is_empty(),
		"reasons": reasons,
		"replay_count": replays.size(),
	}
	if not baseline.is_empty():
		report["fingerprint"] = hash_value({
			"event_log_hash": baseline.get("event_log_hash", ""),
			"input_hash": baseline.get("input_hash", ""),
			"output_state_hash": baseline.get("output_state_hash", ""),
			"reducer_version": baseline.get("reducer_version", ""),
			"tick_count": baseline.get("tick_count", -1),
		})
	proposal.deterministic_report = report
	if not report["ok"]:
		_add_quarantine(proposal, "determinism_failed")
	else:
		_refresh_review_state(proposal)
	return report


func attach_security_review(proposal: Proposal, review: Dictionary) -> Dictionary:
	var reasons: Array[String] = []
	var unhashed_review := review.duplicate(true)
	var supplied_review_hash := str(unhashed_review.get("review_hash", ""))
	unhashed_review.erase("review_hash")
	if supplied_review_hash.is_empty() or supplied_review_hash != hash_value(unhashed_review):
		reasons.append("security_review_hash_mismatch")
	if str(review.get("proposal_hash", "")) != proposal.proposal_hash:
		reasons.append("security_review_proposal_mismatch")
	if str(review.get("manifest_hash", "")) != proposal.manifest_hash:
		reasons.append("security_review_manifest_mismatch")
	if str(review.get("source", "")) != "mock":
		reasons.append("only_mock_review_supported")
	if bool(review.get("authoritative", true)):
		reasons.append("ai_review_must_be_non_authoritative")
	var disposition := str(review.get("disposition", "quarantine"))
	if disposition not in ["allow", "quarantine", "reject"]:
		reasons.append("invalid_security_disposition")
	proposal.security_review = review.duplicate(true)
	if disposition != "allow":
		reasons.append("security_review_" + disposition)
	for reason in reasons:
		_add_quarantine(proposal, reason)
	if reasons.is_empty():
		_refresh_review_state(proposal)
	return {
		"ok": reasons.is_empty(),
		"reasons": reasons,
		"state": proposal.state,
	}


func issue_delegation(
	lobby_id: String,
	delegator_id: String,
	delegate_id: String,
	scopes_value,
	expires_at_unix: int,
	proof: Dictionary,
	now_unix: int
) -> Dictionary:
	if not _has_member(lobby_id, delegator_id) or not _has_member(lobby_id, delegate_id):
		return _result(false, "delegation_member_not_in_lobby")
	if delegator_id == delegate_id:
		return _result(false, "self_delegation_forbidden")
	if expires_at_unix <= now_unix or expires_at_unix - now_unix > MAX_DELEGATION_LIFETIME_SECONDS:
		return _result(false, "invalid_delegation_expiry")
	var scopes := _sanitize_scopes(scopes_value)
	if scopes.is_empty():
		return _result(false, "delegation_requires_sensitive_scope")
	var expected := {
		"delegate_id": delegate_id,
		"delegator_id": delegator_id,
		"expires_at_unix": expires_at_unix,
		"lobby_id": lobby_id,
		"purpose": "trusted_lobby_delegation",
		"scopes": Array(scopes),
	}
	if not _verify_proof(proof, expected):
		return _result(false, "invalid_delegation_proof")
	var authorization_hash := hash_value({"expected": expected, "proof": proof})
	_delegations[lobby_id][delegator_id] = {
		"authorization_hash": authorization_hash,
		"delegate_id": delegate_id,
		"delegator_id": delegator_id,
		"expires_at_unix": expires_at_unix,
		"issued_at_unix": now_unix,
		"lobby_id": lobby_id,
		"revoked": false,
		"scopes": scopes,
	}
	return {
		"authorization_hash": authorization_hash,
		"ok": true,
	}


func revoke_delegation(
	lobby_id: String,
	delegator_id: String,
	proof: Dictionary,
	now_unix: int
) -> Dictionary:
	var lobby_delegations: Dictionary = _delegations.get(lobby_id, {})
	if not lobby_delegations.has(delegator_id):
		return _result(false, "delegation_not_found")
	var delegation: Dictionary = lobby_delegations[delegator_id]
	var expected := {
		"authorization_hash": delegation["authorization_hash"],
		"delegator_id": delegator_id,
		"lobby_id": lobby_id,
		"purpose": "revoke_trusted_lobby_delegation",
	}
	if not _verify_proof(proof, expected):
		return _result(false, "invalid_revocation_proof")
	delegation["revoked"] = true
	delegation["revoked_at_unix"] = now_unix
	lobby_delegations[delegator_id] = delegation
	return {"ok": true, "revoked_at_unix": now_unix}


func consent_requirements(proposal: Proposal, now_unix: int) -> Dictionary:
	var requirements: Array[Dictionary] = []
	var members: Dictionary = _lobbies.get(proposal.lobby_id, {})
	var member_ids := _sorted_dictionary_keys(members)
	var scopes := _proposal_scopes(proposal)
	for member_id in member_ids:
		var member: Dictionary = members[member_id]
		if bool(member.get("online", false)):
			requirements.append({
				"member_id": member_id,
				"mode": "direct",
				"signer_id": member_id,
			})
		else:
			var delegation := _active_delegation(proposal.lobby_id, member_id, scopes, now_unix)
			if not delegation.is_empty():
				requirements.append({
					"member_id": member_id,
					"mode": "delegated",
					"signer_id": delegation["delegate_id"],
				})
	return {
		"proposal_hash": proposal.proposal_hash,
		"requirements": requirements,
		"scopes": Array(scopes),
	}


func record_consent(
	proposal: Proposal,
	member_id: String,
	decision: String,
	proof: Dictionary,
	now_unix: int
) -> Dictionary:
	if not _has_member(proposal.lobby_id, member_id):
		return _result(false, "consenter_not_in_lobby")
	if not bool(_lobbies[proposal.lobby_id][member_id].get("online", false)):
		return _result(false, "direct_consenter_must_be_online")
	if decision not in ["approve", "reject"]:
		return _result(false, "invalid_consent_decision")
	if now_unix >= proposal.expires_at_unix:
		proposal.state = ProposalState.EXPIRED
		return _result(false, "proposal_expired")
	var expected := {
		"decision": decision,
		"lobby_id": proposal.lobby_id,
		"member_id": member_id,
		"proposal_hash": proposal.proposal_hash,
		"purpose": "proposal_consent",
	}
	if not _verify_proof(proof, expected):
		return _result(false, "invalid_consent_proof")
	proposal.consents[member_id] = {
		"consented_at_unix": now_unix,
		"decision": decision,
		"proof_hash": hash_value({"expected": expected, "proof": proof}),
	}
	if decision == "reject":
		proposal.state = ProposalState.REJECTED
	return {"ok": true, "state": proposal.state}


func evaluate_unanimity(proposal: Proposal, now_unix: int) -> Dictionary:
	var requirement_report := consent_requirements(proposal, now_unix)
	var missing: Array[String] = []
	var rejected: Array[String] = []
	var represented: Dictionary = {}
	for requirement in requirement_report["requirements"]:
		var signer_id := str(requirement["signer_id"])
		var represented_member_id := str(requirement["member_id"])
		var consent: Dictionary = proposal.consents.get(signer_id, {})
		if consent.is_empty():
			missing.append(represented_member_id)
		elif consent.get("decision") != "approve":
			rejected.append(represented_member_id)
		else:
			represented[represented_member_id] = signer_id
	return {
		"missing": missing,
		"ok": missing.is_empty() and rejected.is_empty() and not requirement_report["requirements"].is_empty(),
		"rejected": rejected,
		"represented_by": represented,
		"required_count": requirement_report["requirements"].size(),
	}


func finalize(proposal: Proposal, now_unix: int) -> Dictionary:
	if now_unix >= proposal.expires_at_unix:
		proposal.state = ProposalState.EXPIRED
		return _result(false, "proposal_expired")
	if proposal.state == ProposalState.QUARANTINED:
		return _result(false, "proposal_quarantined")
	if proposal.state == ProposalState.REJECTED:
		return _result(false, "proposal_rejected")
	if not verify_manifest(proposal)["ok"]:
		_add_quarantine(proposal, "manifest_hash_mismatch")
		return _result(false, "manifest_hash_mismatch")
	if not bool(proposal.deterministic_report.get("ok", false)):
		return _result(false, "deterministic_verification_required")
	if str(proposal.security_review.get("disposition", "")) != "allow":
		return _result(false, "security_review_required")

	var unanimity := evaluate_unanimity(proposal, now_unix)
	if proposal.is_sensitive():
		if not unanimity["ok"]:
			return {
				"missing": unanimity["missing"],
				"ok": false,
				"reason": "unanimous_online_consent_required",
				"rejected": unanimity["rejected"],
			}
	else:
		var author_consent: Dictionary = proposal.consents.get(proposal.author_id, {})
		if author_consent.get("decision") != "approve":
			return _result(false, "author_consent_required")
	proposal.state = ProposalState.APPROVED
	return {
		"advisory_score": proposal.advisory_score,
		"consensus": unanimity,
		"ok": true,
		"proposal_hash": proposal.proposal_hash,
		"state": proposal.state,
	}


func calculate_advisory_score(lobby_id: String, preferences: Dictionary) -> Dictionary:
	var members: Dictionary = _lobbies.get(lobby_id, {})
	if members.is_empty():
		return {"ok": false, "reason": "lobby_not_found", "score": 0.5, "weights": {}}
	var raw_weights: Dictionary = {}
	var raw_total := 0.0
	for member_id in _sorted_dictionary_keys(members):
		var member: Dictionary = members[member_id]
		var playtime := float(member.get("playtime_seconds", 0)) / float(MAX_PLAYTIME_SECONDS)
		var activity := float(member.get("activity_events", 0)) / float(MAX_ACTIVITY_EVENTS)
		var raw := 1.0 + 0.6 * clampf(playtime, 0.0, 1.0) + 0.4 * clampf(activity, 0.0, 1.0)
		raw_weights[member_id] = raw
		raw_total += raw

	var weights: Dictionary = {}
	var score := 0.0
	var assigned_share := 0.0
	for member_id in _sorted_dictionary_keys(raw_weights):
		var normalized := float(raw_weights[member_id]) / raw_total
		var capped := minf(normalized, MAX_ADVISORY_MEMBER_SHARE)
		var preference := clampf(float(preferences.get(member_id, 0.5)), 0.0, 1.0)
		weights[member_id] = capped
		score += capped * preference
		assigned_share += capped
	# Unassigned influence remains neutral; it cannot be captured by a small or
	# highly active subset of the lobby.
	score += maxf(0.0, 1.0 - assigned_share) * 0.5
	return {
		"authoritative": false,
		"max_member_share": MAX_ADVISORY_MEMBER_SHARE,
		"ok": true,
		"score": clampf(score, 0.0, 1.0),
		"weights": weights,
	}


func attach_advisory_score(proposal: Proposal, preferences: Dictionary) -> Dictionary:
	var report := calculate_advisory_score(proposal.lobby_id, preferences)
	if report["ok"]:
		proposal.advisory_score = report["score"]
		proposal.advisory_breakdown = report.duplicate(true)
	return report


static func canonical_json(value) -> String:
	match typeof(value):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT:
			return str(value)
		TYPE_FLOAT:
			if is_nan(value) or is_inf(value):
				return "null"
			return JSON.stringify(value)
		TYPE_STRING, TYPE_STRING_NAME:
			return JSON.stringify(str(value))
		TYPE_ARRAY:
			var array_parts: Array[String] = []
			for item in value:
				array_parts.append(canonical_json(item))
			return "[" + ",".join(array_parts) + "]"
		TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			return canonical_json(Array(value))
		TYPE_DICTIONARY:
			var dictionary_parts: Array[String] = []
			for key in value.keys():
				dictionary_parts.append(JSON.stringify(str(key)) + ":" + canonical_json(value[key]))
			dictionary_parts.sort()
			return "{" + ",".join(dictionary_parts) + "}"
		_:
			return JSON.stringify(str(value))


static func hash_value(value) -> String:
	return canonical_json(value).sha256_text()


static func state_name(state: int) -> String:
	match state:
		ProposalState.DRAFT: return "draft"
		ProposalState.QUARANTINED: return "quarantined"
		ProposalState.AWAITING_REVIEW: return "awaiting_review"
		ProposalState.AWAITING_CONSENT: return "awaiting_consent"
		ProposalState.APPROVED: return "approved"
		ProposalState.REJECTED: return "rejected"
		ProposalState.EXPIRED: return "expired"
		_: return "unknown"


func _parse_diff(raw_diff, proposal: Proposal):
	var source: Dictionary = {}
	if raw_diff is ProposalDiff:
		source = {
			"after": raw_diff.after_value,
			"before": raw_diff.before_value,
			"capability": raw_diff.capability,
			"change_type": raw_diff.change_type,
			"metadata": raw_diff.metadata,
			"operation": raw_diff.operation,
			"target": raw_diff.target,
		}
	elif raw_diff is Dictionary:
		source = raw_diff
	else:
		_add_quarantine(proposal, "diff_must_be_dictionary")
		return null
	var diff := ProposalDiff.new()
	diff.change_type = int(source.get("change_type", -1))
	diff.operation = int(source.get("operation", -1))
	diff.target = _sanitize_text(str(source.get("target", "")), 256)
	diff.capability = _sanitize_text(str(source.get("capability", "")), 80)
	diff.before_value = _sanitize_value(source.get("before", null), proposal, 0)
	diff.after_value = _sanitize_value(source.get("after", null), proposal, 0)
	diff.metadata = _sanitize_value(source.get("metadata", {}), proposal, 0)
	if diff.change_type not in [ChangeType.COSMETIC, ChangeType.RULE, ChangeType.ASSET, ChangeType.CODE]:
		_add_quarantine(proposal, "invalid_change_type")
	if diff.operation not in [DiffOperation.ADD, DiffOperation.REPLACE, DiffOperation.REMOVE]:
		_add_quarantine(proposal, "invalid_diff_operation")
	if not _safe_target(diff.target):
		_add_quarantine(proposal, "unsafe_diff_target")
	if _contains_prompt_injection(canonical_json(diff.after_value)):
		_add_quarantine(proposal, "prompt_injection_marker")
	diff.before_hash = hash_value(diff.before_value)
	diff.after_hash = hash_value(diff.after_value)
	return diff


func _sanitize_value(value, proposal: Proposal, depth: int):
	if depth > 8:
		_add_quarantine(proposal, "value_nesting_exceeds_limit")
		return null
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT:
			return value
		TYPE_FLOAT:
			if is_nan(value) or is_inf(value):
				_add_quarantine(proposal, "non_finite_number")
				return 0.0
			return value
		TYPE_STRING, TYPE_STRING_NAME:
			var raw_text := str(value)
			var clean_text := _sanitize_text(raw_text, 4096)
			if clean_text != raw_text.replace("\r\n", "\n").replace("\r", "\n"):
				_add_quarantine(proposal, "string_sanitized")
			return clean_text
		TYPE_ARRAY:
			if value.size() > 256:
				_add_quarantine(proposal, "array_exceeds_limit")
			var clean_array: Array = []
			for item in value.slice(0, 256):
				clean_array.append(_sanitize_value(item, proposal, depth + 1))
			return clean_array
		TYPE_DICTIONARY:
			if value.size() > 256:
				_add_quarantine(proposal, "dictionary_exceeds_limit")
			var clean_dictionary: Dictionary = {}
			var count := 0
			for key in value.keys():
				if count >= 256:
					break
				if not key is String and not key is StringName:
					_add_quarantine(proposal, "dictionary_key_must_be_string")
					continue
				var clean_key := _sanitize_text(str(key), 120)
				if clean_key.is_empty() or clean_dictionary.has(clean_key):
					_add_quarantine(proposal, "invalid_or_duplicate_dictionary_key")
					continue
				clean_dictionary[clean_key] = _sanitize_value(value[key], proposal, depth + 1)
				count += 1
			return clean_dictionary
		TYPE_PACKED_STRING_ARRAY:
			return _sanitize_value(Array(value), proposal, depth + 1)
		_:
			_add_quarantine(proposal, "unsupported_value_type")
			return null


func _sanitize_capabilities(capabilities_value) -> Dictionary:
	var reasons: Array[String] = []
	var capabilities: Array[String] = []
	if not capabilities_value is Array and not capabilities_value is PackedStringArray:
		reasons.append("capabilities_must_be_array")
		return {"capabilities": PackedStringArray(), "reasons": reasons}
	for capability_value in capabilities_value:
		var capability := _sanitize_text(str(capability_value), 80)
		if capability not in CAPABILITY_ALLOWLIST:
			reasons.append("capability_not_allowed:" + capability)
		elif capability not in capabilities:
			capabilities.append(capability)
	capabilities.sort()
	return {
		"capabilities": PackedStringArray(capabilities),
		"reasons": _unique_sorted_strings(reasons),
	}


func _validate_least_privilege(proposal: Proposal) -> void:
	var required: Array[String] = []
	for diff in proposal.diffs:
		var expected := _required_capability(diff.change_type)
		if diff.capability != expected:
			_add_quarantine(proposal, "diff_capability_mismatch:" + diff.target)
		if expected not in required:
			required.append(expected)
	for capability in required:
		if capability not in proposal.requested_capabilities:
			_add_quarantine(proposal, "missing_required_capability:" + capability)
	for capability in proposal.requested_capabilities:
		if capability not in required:
			_add_quarantine(proposal, "unneeded_capability:" + capability)


func _build_manifest(proposal: Proposal) -> Dictionary:
	var diff_entries: Array = []
	for diff in proposal.diffs:
		diff_entries.append(diff.to_manifest_entry())
	return {
		"author_id": proposal.author_id,
		"created_at_unix": proposal.created_at_unix,
		"diffs": diff_entries,
		"expires_at_unix": proposal.expires_at_unix,
		"lobby_id": proposal.lobby_id,
		"nonce": proposal.nonce,
		"proposal_id": proposal.proposal_id,
		"requested_capabilities": Array(proposal.requested_capabilities),
		"schema_version": SCHEMA_VERSION,
		"summary_hash": hash_value(proposal.summary),
		"title": proposal.title,
	}


func _refresh_review_state(proposal: Proposal) -> void:
	if not proposal.quarantine_reasons.is_empty():
		proposal.state = ProposalState.QUARANTINED
		return
	if bool(proposal.deterministic_report.get("ok", false)) and str(proposal.security_review.get("disposition", "")) == "allow":
		proposal.state = ProposalState.AWAITING_CONSENT
	else:
		proposal.state = ProposalState.AWAITING_REVIEW


func _active_delegation(
	lobby_id: String,
	delegator_id: String,
	required_scopes: PackedStringArray,
	now_unix: int
) -> Dictionary:
	var lobby_delegations: Dictionary = _delegations.get(lobby_id, {})
	var delegation: Dictionary = lobby_delegations.get(delegator_id, {})
	if delegation.is_empty() or bool(delegation.get("revoked", true)):
		return {}
	if int(delegation.get("expires_at_unix", 0)) <= now_unix:
		return {}
	var delegate_id := str(delegation.get("delegate_id", ""))
	if not _has_member(lobby_id, delegate_id):
		return {}
	if not bool(_lobbies[lobby_id][delegate_id].get("online", false)):
		return {}
	var delegated_scopes: PackedStringArray = delegation.get("scopes", PackedStringArray())
	for scope in required_scopes:
		if scope not in delegated_scopes:
			return {}
	return delegation.duplicate(true)


func _proposal_scopes(proposal: Proposal) -> PackedStringArray:
	var scopes: Array[String] = []
	for diff in proposal.diffs:
		var scope := _scope_for_change_type(diff.change_type)
		if not scope.is_empty() and scope not in scopes:
			scopes.append(scope)
	scopes.sort()
	return PackedStringArray(scopes)


func _sanitize_scopes(scopes_value) -> PackedStringArray:
	if not scopes_value is Array and not scopes_value is PackedStringArray:
		return PackedStringArray()
	var scopes: Array[String] = []
	for value in scopes_value:
		var scope := str(value).to_lower()
		if scope in SENSITIVE_SCOPES and scope not in scopes:
			scopes.append(scope)
	scopes.sort()
	return PackedStringArray(scopes)


func _verify_proof(proof: Dictionary, expected_payload: Dictionary) -> bool:
	if not _proof_verifier.is_valid():
		return false
	return bool(_proof_verifier.call(proof.duplicate(true), expected_payload.duplicate(true)))


func _has_member(lobby_id: String, member_id: String) -> bool:
	return _lobbies.has(lobby_id) and _lobbies[lobby_id].has(member_id)


func _required_capability(change_type: int) -> String:
	match change_type:
		ChangeType.COSMETIC: return "world.visual.write"
		ChangeType.RULE: return "rules.propose"
		ChangeType.ASSET: return "assets.mount"
		ChangeType.CODE: return "code.module.mount"
		_: return ""


func _scope_for_change_type(change_type: int) -> String:
	match change_type:
		ChangeType.RULE: return "rule"
		ChangeType.ASSET: return "asset"
		ChangeType.CODE: return "code"
		_: return ""


func _add_quarantine(proposal: Proposal, reason: String) -> void:
	if reason not in proposal.quarantine_reasons:
		proposal.quarantine_reasons.append(reason)
		proposal.quarantine_reasons.sort()
	proposal.state = ProposalState.QUARANTINED


func _contains_prompt_injection(text: String) -> bool:
	var normalized := text.to_lower()
	for marker in INJECTION_MARKERS:
		if normalized.contains(marker):
			return true
	return false


func _safe_target(target: String) -> bool:
	if target.is_empty() or target.length() > 256:
		return false
	if target.begins_with("/") or target.contains("..") or target.contains("\\") or target.contains("://"):
		return false
	for index in range(target.length()):
		var code := target.unicode_at(index)
		var allowed := (
			(code >= 48 and code <= 57)
			or (code >= 65 and code <= 90)
			or (code >= 97 and code <= 122)
			or code in [45, 46, 47, 95]
		)
		if not allowed:
			return false
	return true


func _sanitize_identifier(value: String) -> String:
	var clean := _sanitize_text(value, 96).strip_edges()
	if clean.is_empty():
		return ""
	for index in range(clean.length()):
		var code := clean.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or code in [45, 95]):
			return ""
	return clean


func _sanitize_text(value: String, maximum_length: int) -> String:
	var normalized := value.replace("\r\n", "\n").replace("\r", "\n")
	var clean := ""
	for index in range(mini(normalized.length(), maximum_length)):
		var code := normalized.unicode_at(index)
		if code == 9 or code == 10 or code >= 32:
			clean += String.chr(code)
	return clean


func _sorted_dictionary_keys(dictionary: Dictionary) -> Array[String]:
	var keys: Array[String] = []
	for key in dictionary.keys():
		keys.append(str(key))
	keys.sort()
	return keys


func _unique_sorted_strings(values: Array[String]) -> Array[String]:
	var unique: Array[String] = []
	for value in values:
		if value not in unique:
			unique.append(value)
	unique.sort()
	return unique


func _result(ok: bool, reason: String) -> Dictionary:
	return {"ok": ok, "reason": reason}
