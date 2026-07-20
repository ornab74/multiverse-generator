extends RefCounted

## Shared deterministic reducer contract for every built-in board module.
##
## State and actions intentionally contain JSON-safe primitives only.  That keeps
## hashes portable across peers and makes recorded fixtures safe to relay through
## content-addressed storage.


func manifest() -> Dictionary:
	return {}


func initial_state(config: Dictionary = {}) -> Dictionary:
	return _initial_state(config).duplicate(true)


func _initial_state(_config: Dictionary) -> Dictionary:
	return {}


func validate_action(_state: Dictionary, _action: Dictionary) -> Dictionary:
	return _invalid("not_implemented", "The module does not implement action validation.")


func reduce(state: Dictionary, action: Dictionary) -> Dictionary:
	var envelope := _validate_envelope(state, action)
	if not envelope.ok:
		return _rejected_result(state, envelope)

	var verdict := validate_action(state, action)
	if not verdict.get("ok", false):
		return _rejected_result(state, verdict)

	var next_state := _reduce_validated(state.duplicate(true), action.duplicate(true))
	next_state["revision"] = int(state.get("revision", 0)) + 1
	return {
		"ok": true,
		"code": "applied",
		"state": next_state,
		"previous_hash": state_hash(state),
		"state_hash": state_hash(next_state),
	}


func _reduce_validated(state: Dictionary, _action: Dictionary) -> Dictionary:
	return state


func state_hash(state: Dictionary) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	var canonical_json := JSON.stringify(_canonicalize(state), "", true, false)
	context.update(canonical_json.to_utf8_buffer())
	return context.finish().hex_encode()


func create_fixture(actions: Array, config: Dictionary = {}) -> Dictionary:
	return record_fixture(initial_state(config), actions)


func record_fixture(start_state: Dictionary, actions: Array) -> Dictionary:
	var state := start_state.duplicate(true)
	var fixture := {
		"format": "nexus.reducer.fixture.v1",
		"module_id": str(manifest().get("id", "")),
		"module_version": str(manifest().get("version", "")),
		"initial_state": state.duplicate(true),
		"initial_hash": state_hash(state),
		"steps": [],
		"valid": true,
	}

	for action_variant in actions:
		if not action_variant is Dictionary:
			fixture.valid = false
			fixture["error"] = "fixture_action_not_dictionary"
			break
		var action: Dictionary = action_variant
		var result := reduce(state, action)
		if not result.ok:
			fixture.valid = false
			fixture["error"] = str(result.code)
			fixture["rejected_action"] = action.duplicate(true)
			break
		state = result.state
		fixture.steps.append({
			"action": action.duplicate(true),
			"hash": result.state_hash,
		})

	fixture["final_hash"] = state_hash(state)
	fixture["final_state"] = state.duplicate(true)
	return fixture


func replay_fixture(fixture: Dictionary, stop_after: int = -1) -> Dictionary:
	if str(fixture.get("format", "")) != "nexus.reducer.fixture.v1":
		return _invalid("fixture_format", "Unsupported reducer fixture format.")
	if str(fixture.get("module_id", "")) != str(manifest().get("id", "")):
		return _invalid("fixture_module", "Fixture belongs to a different module.")
	if not fixture.get("initial_state", null) is Dictionary:
		return _invalid("fixture_state", "Fixture has no valid initial state.")
	if not fixture.get("steps", null) is Array:
		return _invalid("fixture_steps", "Fixture steps are malformed.")

	var state: Dictionary = fixture.initial_state.duplicate(true)
	if state_hash(state) != str(fixture.get("initial_hash", "")):
		return _invalid("fixture_initial_hash", "Fixture initial state hash does not match.")

	var limit: int = fixture.steps.size()
	if stop_after >= 0:
		limit = mini(stop_after, limit)
	for step_index in range(limit):
		var step_variant = fixture.steps[step_index]
		if not step_variant is Dictionary or not step_variant.get("action", null) is Dictionary:
			return _invalid("fixture_step", "Fixture step %d is malformed." % step_index)
		var result := reduce(state, step_variant.action)
		if not result.ok:
			return _invalid(
				"fixture_rejected",
				"Fixture step %d was rejected: %s" % [step_index, result.code]
			)
		if result.state_hash != str(step_variant.get("hash", "")):
			return _invalid("fixture_hash", "Fixture step %d diverged." % step_index)
		state = result.state

	return {
		"ok": true,
		"code": "fixture_verified",
		"state": state,
		"state_hash": state_hash(state),
		"applied": limit,
	}


func rollback_fixture(fixture: Dictionary, target_revision: int) -> Dictionary:
	if not fixture.get("initial_state", null) is Dictionary:
		return _invalid("fixture_state", "Fixture has no valid initial state.")
	var initial_revision := int(fixture.initial_state.get("revision", 0))
	var step_count := target_revision - initial_revision
	if step_count < 0 or step_count > int(fixture.get("steps", []).size()):
		return _invalid("rollback_range", "Target revision is outside the fixture history.")
	var replay := replay_fixture(fixture, step_count)
	if replay.get("ok", false):
		replay["code"] = "rolled_back"
		replay["target_revision"] = target_revision
	return replay


func _validate_envelope(state: Dictionary, action: Dictionary) -> Dictionary:
	var module_id := str(manifest().get("id", ""))
	if str(state.get("module_id", "")) != module_id:
		return _invalid("state_module", "State does not belong to %s." % module_id)
	if action.has("expected_revision") and int(action.expected_revision) != int(state.get("revision", 0)):
		return _invalid("revision_conflict", "Action targets a stale state revision.")
	if action.has("expected_state_hash") and str(action.expected_state_hash) != state_hash(state):
		return _invalid("hash_conflict", "Action targets a different deterministic state.")
	return _valid()


func _rejected_result(state: Dictionary, verdict: Dictionary) -> Dictionary:
	return {
		"ok": false,
		"code": str(verdict.get("code", "invalid_action")),
		"message": str(verdict.get("message", "Action rejected.")),
		"state": state.duplicate(true),
		"state_hash": state_hash(state),
	}


func _canonicalize(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort_custom(func(left: Variant, right: Variant) -> bool: return str(left) < str(right))
		var normalized := {}
		for key in keys:
			normalized[str(key)] = _canonicalize(value[key])
		return normalized
	if value is Array:
		var normalized_array: Array = []
		for item in value:
			normalized_array.append(_canonicalize(item))
		return normalized_array
	if value is PackedStringArray:
		return Array(value)
	if value is StringName:
		return str(value)
	return value


func _valid(extra: Dictionary = {}) -> Dictionary:
	var result := {"ok": true, "code": "valid"}
	result.merge(extra, true)
	return result


func _invalid(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
