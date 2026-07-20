extends RefCounted

## Scene-independent affordance and preview controller for the non-chess reducers.
##
## The controller never owns game rules. Candidate UI actions are generated from
## a sanitized reducer state and must survive `reduce()` before they are exposed.
## A preview caches the reducer result while the committed state remains unchanged;
## commit probes the reducer again and verifies the deterministic result hash.

signal preview_started(preview: Dictionary)
signal preview_cancelled(summary: Dictionary)
signal state_committed(summary: Dictionary)

const SUPPORTED_MODULES := ["four_line", "draughts", "property_grid"]
const MODULE_ALIASES := {
	"connect_4": "four_line",
	"connect_four": "four_line",
	"four_line": "four_line",
	"checkers": "draughts",
	"draughts": "draughts",
	"monopoly": "property_grid",
	"property": "property_grid",
	"property_grid": "property_grid",
	"property_loop": "property_grid",
}
const DRAUGHTS_CODES := ["", "r", "R", "b", "B"]
const MAX_STRING_LENGTH := 4096
const MAX_COLLECTION_ITEMS := 8192
const MAX_NESTING_DEPTH := 32
const MAX_DRAUGHTS_GENERATION_STEPS := 8192
const MAX_DRAUGHTS_PATHS := 4096

var _module_id := ""
var _reducer: RefCounted
var _state: Dictionary = {}
var _pending: Dictionary = {}
var _probe_count := 0
var _probe_rejections: Dictionary = {}
var _generation_steps := 0
var _generation_limited := false
var _last_code := "not_configured"


func configure(module: String, reducer: RefCounted, state: Dictionary) -> Dictionary:
	var normalized_id := _normalize_module_id(module)
	if normalized_id not in SUPPORTED_MODULES:
		return _remember(_invalid("unsupported_module", "Only the built-in non-chess tabletop modules are supported."))
	if reducer == null or not reducer.has_method("manifest") or not reducer.has_method("reduce") or not reducer.has_method("state_hash"):
		return _remember(_invalid("reducer", "A compatible deterministic reducer is required."))
	var manifest_variant: Variant = reducer.manifest()
	if not manifest_variant is Dictionary:
		return _remember(_invalid("manifest", "The reducer manifest is malformed."))
	var reducer_id := _normalize_module_id(str(manifest_variant.get("id", "")))
	if reducer_id != normalized_id:
		return _remember(_invalid("module_mismatch", "The requested module does not match the reducer manifest."))

	var safe_state := _sanitize_copy(state)
	if not safe_state.ok:
		return _remember(_invalid("state_sanitization", str(safe_state.message)))
	var shape := _validate_state_shape(normalized_id, safe_state.value)
	if not shape.ok:
		return _remember(shape)

	_module_id = normalized_id
	_reducer = reducer
	_state = safe_state.value.duplicate(true)
	_pending.clear()
	_reset_probe_diagnostics()
	_last_code = "configured"
	return _remember({
		"ok": true,
		"code": "configured",
		"module_id": _module_id,
		"revision": int(_state.revision),
		"state_hash": _state_hash(),
	})


func is_configured() -> bool:
	return _reducer != null and _module_id in SUPPORTED_MODULES and not _state.is_empty()


func module_id() -> String:
	return _module_id


func committed_state() -> Dictionary:
	return _state.duplicate(true)


func has_preview() -> bool:
	return not _pending.is_empty()


func pending_preview() -> Dictionary:
	if _pending.is_empty():
		return {}
	var response := _public_preview(_pending)
	response["diagnostics"] = diagnostics()
	return response


func replace_state(state: Dictionary) -> Dictionary:
	if not is_configured():
		return _remember(_invalid("not_configured", "Configure a reducer before replacing state."))
	if has_preview():
		return _remember(_invalid("preview_active", "Commit or cancel the current preview before replacing state."))
	var safe_state := _sanitize_copy(state)
	if not safe_state.ok:
		return _remember(_invalid("state_sanitization", str(safe_state.message)))
	var shape := _validate_state_shape(_module_id, safe_state.value)
	if not shape.ok:
		return _remember(shape)
	_state = safe_state.value.duplicate(true)
	_last_code = "state_replaced"
	return _remember({
		"ok": true,
		"code": "state_replaced",
		"module_id": _module_id,
		"revision": int(_state.revision),
		"state_hash": _state_hash(),
	})


func legal_intents(actor: String = "") -> Dictionary:
	if not is_configured():
		return _remember(_invalid("not_configured", "Configure a reducer before requesting legal intents."))
	_reset_probe_diagnostics()
	var active_actor := _active_actor()
	if not actor.is_empty() and actor != active_actor:
		return _remember(_with_diagnostics(_invalid("actor_scope", "The requested actor is not active in this state.")))

	var result: Dictionary
	match _module_id:
		"four_line":
			result = _four_line_intents(active_actor)
		"draughts":
			result = _draughts_intents(active_actor)
		"property_grid":
			result = _property_grid_intents(active_actor)
		_:
			result = _invalid("unsupported_module", "The configured module has no interaction adapter.")
	if result.get("ok", false):
		result["module_id"] = _module_id
		result["revision"] = int(_state.revision)
		result["state_hash"] = _state_hash()
		result["active_actor"] = active_actor
		result["pending_preview"] = has_preview()
	result = _with_diagnostics(result)
	return _remember(result)


func preview_action(action: Dictionary) -> Dictionary:
	return preview_intent({"action": action})


func preview_intent(intent: Dictionary) -> Dictionary:
	if not is_configured():
		return _remember(_invalid("not_configured", "Configure a reducer before previewing an intent."))
	if has_preview():
		return _remember(_with_diagnostics(_invalid("preview_active", "Commit or cancel the current preview first.")))
	var safe_intent := _sanitize_copy(intent)
	if not safe_intent.ok:
		return _remember(_with_diagnostics(_invalid("intent_sanitization", str(safe_intent.message))))
	var normalized := _normalize_intent(safe_intent.value)
	if not normalized.ok:
		return _remember(_with_diagnostics(normalized))

	_reset_probe_diagnostics()
	var base_hash := _state_hash()
	var action: Dictionary = normalized.action.duplicate(true)
	action["expected_revision"] = int(_state.revision)
	action["expected_state_hash"] = base_hash
	var probe := _probe(action)
	if not probe.get("ok", false):
		return _remember(_with_diagnostics(_reducer_rejection(probe)))
	if not probe.get("state", null) is Dictionary:
		return _remember(_with_diagnostics(_invalid("reducer_state", "The reducer returned no valid preview state.")))
	var safe_next := _sanitize_copy(probe.state)
	if not safe_next.ok:
		return _remember(_with_diagnostics(_invalid("reducer_state_sanitization", str(safe_next.message))))
	var shape := _validate_state_shape(_module_id, safe_next.value)
	if not shape.ok:
		return _remember(_with_diagnostics(shape))
	var next_hash := str(_reducer.state_hash(safe_next.value))
	var reported_hash := str(probe.get("state_hash", ""))
	if not reported_hash.is_empty() and reported_hash != next_hash:
		return _remember(_with_diagnostics(_invalid("reducer_hash_mismatch", "The reducer receipt does not match its canonical preview state hash.")))
	_pending = {
		"module_id": _module_id,
		"base_revision": int(_state.revision),
		"base_hash": base_hash,
		"action": action.duplicate(true),
		"intent": str(normalized.intent),
		"state": safe_next.value.duplicate(true),
		"state_hash": next_hash,
	}
	var response := _public_preview(_pending)
	response = _remember(response)
	preview_started.emit(response.duplicate(true))
	return response


func cancel_preview() -> Dictionary:
	if not is_configured():
		return _remember(_invalid("not_configured", "Configure a reducer before cancelling a preview."))
	if not has_preview():
		return _remember(_with_diagnostics(_invalid("no_preview", "There is no pending preview to cancel.")))
	var cancelled_action: Dictionary = _public_action(_pending.action)
	_pending.clear()
	var response := _remember({
		"ok": true,
		"code": "preview_cancelled",
		"module_id": _module_id,
		"action": cancelled_action,
		"revision": int(_state.revision),
		"state_hash": _state_hash(),
		"state": _state.duplicate(true),
	})
	preview_cancelled.emit(response.duplicate(true))
	return response


func commit_preview() -> Dictionary:
	if not is_configured():
		return _remember(_invalid("not_configured", "Configure a reducer before committing a preview."))
	if not has_preview():
		return _remember(_with_diagnostics(_invalid("no_preview", "There is no pending preview to commit.")))
	if _state_hash() != str(_pending.base_hash) or int(_state.revision) != int(_pending.base_revision):
		_pending.clear()
		return _remember(_with_diagnostics(_invalid("preview_stale", "The committed state changed after this preview was created.")))

	_reset_probe_diagnostics()
	var action: Dictionary = _pending.action.duplicate(true)
	var expected_hash := str(_pending.state_hash)
	var result := _probe(action)
	if not result.get("ok", false):
		_pending.clear()
		return _remember(_with_diagnostics(_reducer_rejection(result)))
	var safe_next := _sanitize_copy(result.get("state", null))
	if not safe_next.ok or not safe_next.value is Dictionary:
		_pending.clear()
		return _remember(_with_diagnostics(_invalid("reducer_state_sanitization", "The committed reducer state was malformed.")))
	var shape := _validate_state_shape(_module_id, safe_next.value)
	if not shape.ok:
		_pending.clear()
		return _remember(_with_diagnostics(shape))
	var canonical_hash := str(_reducer.state_hash(safe_next.value))
	var reported_hash := str(result.get("state_hash", ""))
	if not reported_hash.is_empty() and reported_hash != canonical_hash:
		_pending.clear()
		return _remember(_with_diagnostics(_invalid("reducer_hash_mismatch", "The reducer receipt does not match its canonical committed state hash.")))
	if canonical_hash != expected_hash:
		_pending.clear()
		return _remember(_with_diagnostics(_invalid("nondeterministic_result", "The reducer result changed between preview and commit.")))

	var previous_hash := _state_hash()
	var committed_action := _public_action(action)
	_state = safe_next.value.duplicate(true)
	_pending.clear()
	var response := _remember({
		"ok": true,
		"code": "preview_committed",
		"module_id": _module_id,
		"action": committed_action,
		"previous_hash": previous_hash,
		"state_hash": _state_hash(),
		"revision": int(_state.revision),
		"state": _state.duplicate(true),
	})
	state_committed.emit(response.duplicate(true))
	return response


func diagnostics() -> Dictionary:
	return {
		"configured": is_configured(),
		"module_id": _module_id,
		"revision": int(_state.get("revision", -1)),
		"pending_preview": has_preview(),
		"probe_count": _probe_count,
		"probe_rejections": _probe_rejections.duplicate(true),
		"generation_steps": _generation_steps,
		"generation_limited": _generation_limited,
		"last_code": _last_code,
	}


func _four_line_intents(actor: String) -> Dictionary:
	var intents: Array = []
	var legal_columns: Array = []
	if str(_state.get("status", "")) == "active":
		for column in range(7):
			var action := {"type": "drop", "actor": actor, "column": column}
			var probe := _probe(action)
			if not probe.get("ok", false):
				continue
			var landing_row := -1
			for row in range(5, -1, -1):
				if str(_state.board[row * 7 + column]) == "":
					landing_row = row
					break
			legal_columns.append(column)
			intents.append(_normalized_intent(
				"drop",
				action,
				{"column": column, "landing_row": landing_row, "landing_index": landing_row * 7 + column}
			))
	return {
		"ok": true,
		"code": "legal_intents",
		"intents": intents,
		"affordances": {"legal_columns": legal_columns},
	}


func _draughts_intents(actor: String) -> Dictionary:
	_generation_steps = 0
	_generation_limited = false
	var candidates := _draughts_candidate_paths()
	if _generation_limited:
		return _invalid("enumeration_limit", "The draughts position exceeded the safe legal-path enumeration bound.")
	var intents: Array = []
	var selectable: Array = []
	var paths_by_source: Dictionary = {}
	for path_variant in candidates:
		var path: Array = path_variant
		var action := {"type": "move", "actor": actor, "path": path.duplicate()}
		var probe := _probe(action)
		if not probe.get("ok", false):
			continue
		var source := int(path[0])
		var destination := int(path[path.size() - 1])
		var captures := _capture_count(path)
		if source not in selectable:
			selectable.append(source)
		var source_key := str(source)
		if not paths_by_source.has(source_key):
			paths_by_source[source_key] = []
		paths_by_source[source_key].append(path.duplicate())
		intents.append(_normalized_intent(
			"move",
			action,
			{
				"source": source,
				"destination": destination,
				"path": path.duplicate(),
				"captures": captures,
				"is_capture": captures > 0,
			}
		))
	selectable.sort()
	return {
		"ok": true,
		"code": "legal_intents",
		"intents": intents,
		"affordances": {
			"selectable_pieces": selectable,
			"complete_paths_by_source": paths_by_source,
			"mandatory_capture": not intents.is_empty() and bool(intents[0].target.is_capture),
		},
	}


func _property_grid_intents(actor: String) -> Dictionary:
	var intents: Array = []
	var legal_actions: Array = []
	if str(_state.get("status", "")) == "active":
		for action_type in ["roll", "buy", "pass", "end_turn"]:
			var action := {"type": action_type, "actor": actor}
			var probe := _probe(action)
			if not probe.get("ok", false):
				continue
			var ui_intent: String = "decline" if action_type == "pass" else str(action_type)
			legal_actions.append(ui_intent)
			intents.append(_normalized_intent(
				ui_intent,
				action,
				{"phase": str(_state.phase)}
			))
	return {
		"ok": true,
		"code": "legal_intents",
		"intents": intents,
		"affordances": {
			"phase": str(_state.get("phase", "complete")),
			"legal_actions": legal_actions,
		},
	}


func _draughts_candidate_paths() -> Array:
	if str(_state.get("status", "")) != "active":
		return []
	var board: Array = _state.board
	var color := str(_state.turn)
	var capture_paths: Array = []
	for source in range(64):
		var piece := str(board[source])
		if piece == "" or _draughts_piece_color(piece) != color:
			continue
		_expand_capture_paths(board, source, color, [source], capture_paths)
		if _generation_limited:
			return []
	if not capture_paths.is_empty():
		return capture_paths

	var simple_paths: Array = []
	for source in range(64):
		var piece := str(board[source])
		if piece == "" or _draughts_piece_color(piece) != color:
			continue
		var row := int(source / 8)
		var column := source % 8
		for row_direction in _draughts_directions(piece, color):
			for column_direction in [-1, 1]:
				_generation_steps += 1
				if _generation_steps > MAX_DRAUGHTS_GENERATION_STEPS:
					_generation_limited = true
					return []
				var target_row: int = row + int(row_direction)
				var target_column: int = column + int(column_direction)
				if _draughts_inside(target_row, target_column):
					var destination := target_row * 8 + target_column
					if str(board[destination]) == "":
						simple_paths.append([source, destination])
	return simple_paths


func _expand_capture_paths(board: Array, source: int, color: String, path: Array, output: Array) -> void:
	if _generation_limited:
		return
	_generation_steps += 1
	if _generation_steps > MAX_DRAUGHTS_GENERATION_STEPS or output.size() >= MAX_DRAUGHTS_PATHS:
		_generation_limited = true
		return
	var piece := str(board[source])
	var steps := _draughts_capture_steps(board, source, color)
	if steps.is_empty():
		if path.size() > 1:
			output.append(path.duplicate())
		return
	for destination_variant in steps:
		var destination := int(destination_variant)
		var source_row := int(source / 8)
		var source_column := source % 8
		var destination_row := int(destination / 8)
		var destination_column := destination % 8
		var jumped := int((source_row + destination_row) / 2) * 8 + int((source_column + destination_column) / 2)
		var next_board := board.duplicate()
		next_board[source] = ""
		next_board[jumped] = ""
		next_board[destination] = piece
		var next_path := path.duplicate()
		next_path.append(destination)
		var crown_row := 0 if color == "red" else 7
		if piece == piece.to_lower() and destination_row == crown_row:
			output.append(next_path)
		else:
			_expand_capture_paths(next_board, destination, color, next_path, output)
		if _generation_limited:
			return


func _draughts_capture_steps(board: Array, source: int, color: String) -> Array:
	var piece := str(board[source])
	var source_row := int(source / 8)
	var source_column := source % 8
	var result: Array = []
	for row_direction in _draughts_directions(piece, color):
		for column_direction in [-1, 1]:
			var middle_row: int = source_row + int(row_direction)
			var middle_column: int = source_column + int(column_direction)
			var destination_row: int = source_row + int(row_direction) * 2
			var destination_column: int = source_column + int(column_direction) * 2
			if not _draughts_inside(destination_row, destination_column):
				continue
			var middle_piece := str(board[middle_row * 8 + middle_column])
			var destination := destination_row * 8 + destination_column
			if middle_piece != "" and _draughts_piece_color(middle_piece) != color and str(board[destination]) == "":
				result.append(destination)
	return result


func _draughts_directions(piece: String, color: String) -> Array:
	if piece == piece.to_upper():
		return [-1, 1]
	return [-1] if color == "red" else [1]


func _draughts_piece_color(piece: String) -> String:
	return "red" if piece.to_lower() == "r" else "black"


func _draughts_inside(row: int, column: int) -> bool:
	return row >= 0 and row < 8 and column >= 0 and column < 8


func _capture_count(path: Array) -> int:
	var captures := 0
	for index in range(1, path.size()):
		var previous := int(path[index - 1])
		var current := int(path[index])
		if absi(int(current / 8) - int(previous / 8)) == 2:
			captures += 1
	return captures


func _normalize_intent(intent: Dictionary) -> Dictionary:
	var raw: Dictionary = intent.get("action", intent)
	if not raw is Dictionary:
		return _invalid("intent_shape", "An intent must contain a dictionary action.")
	var payload: Dictionary = intent.get("payload", {}) if intent.get("payload", {}) is Dictionary else {}
	var target: Dictionary = intent.get("target", {}) if intent.get("target", {}) is Dictionary else {}
	var requested := str(intent.get("intent", raw.get("type", ""))).strip_edges().to_lower()
	var actor := str(raw.get("actor", intent.get("actor", _active_actor()))).strip_edges()
	if actor.is_empty() or actor.length() > 256:
		return _invalid("actor", "The intent actor is missing or too long.")
	match _module_id:
		"four_line":
			var column_variant: Variant = raw.get("column", payload.get("column", target.get("column", null)))
			if requested != "drop" or not column_variant is int:
				return _invalid("intent_shape", "Four Line requires a drop intent with an integer column.")
			return {"ok": true, "intent": "drop", "action": {"type": "drop", "actor": actor, "column": int(column_variant)}}
		"draughts":
			var path_variant: Variant = raw.get("path", payload.get("path", target.get("path", null)))
			if requested != "move" or not path_variant is Array:
				return _invalid("intent_shape", "Draughts requires a move intent with a path array.")
			if path_variant.size() < 2 or path_variant.size() > 32:
				return _invalid("path_length", "The draughts path length is outside the safe range.")
			var path: Array = []
			for square in path_variant:
				if not square is int or int(square) < 0 or int(square) >= 64:
					return _invalid("square_range", "The draughts path contains an invalid square.")
				path.append(int(square))
			return {"ok": true, "intent": "move", "action": {"type": "move", "actor": actor, "path": path}}
		"property_grid":
			var action_type := str(raw.get("type", requested)).strip_edges().to_lower()
			if requested == "decline" or action_type == "decline":
				action_type = "pass"
			if action_type not in ["roll", "buy", "pass", "end_turn"]:
				return _invalid("intent_shape", "Property Grid requires roll, buy, decline, or end_turn.")
			return {
				"ok": true,
				"intent": "decline" if action_type == "pass" else action_type,
				"action": {"type": action_type, "actor": actor},
			}
	return _invalid("unsupported_module", "The configured module has no intent normalizer.")


func _normalized_intent(intent_name: String, action: Dictionary, target: Dictionary) -> Dictionary:
	return {
		"id": _intent_id(intent_name, action),
		"intent": intent_name,
		"actor": str(action.actor),
		"action": action.duplicate(true),
		"target": target.duplicate(true),
	}


func _intent_id(intent_name: String, action: Dictionary) -> String:
	var suffix := ""
	if action.has("column"):
		suffix = str(action.column)
	elif action.has("path"):
		var path_parts: Array[String] = []
		for square in action.path:
			path_parts.append(str(square))
		suffix = "-".join(path_parts)
	else:
		suffix = str(action.type)
	return "%s.%s.%s" % [_module_id, intent_name, suffix]


func _public_action(action: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in ["type", "actor", "column", "path"]:
		if action.has(key):
			result[key] = action[key].duplicate(true) if action[key] is Array or action[key] is Dictionary else action[key]
	return result


func _public_preview(pending: Dictionary) -> Dictionary:
	return {
		"ok": true,
		"code": "preview_ready",
		"module_id": str(pending.module_id),
		"intent": str(pending.intent),
		"action": _public_action(pending.action),
		"base_revision": int(pending.base_revision),
		"base_hash": str(pending.base_hash),
		"revision": int(pending.state.get("revision", -1)),
		"state_hash": str(pending.state_hash),
		"state": pending.state.duplicate(true),
	}


func _probe(action: Dictionary) -> Dictionary:
	_probe_count += 1
	var raw_variant: Variant = _reducer.reduce(_state.duplicate(true), action.duplicate(true))
	if not raw_variant is Dictionary:
		_record_probe_rejection("reducer_response")
		return _invalid("reducer_response", "The reducer returned a non-dictionary response.")
	var safe := _sanitize_copy(raw_variant)
	if not safe.ok or not safe.value is Dictionary:
		_record_probe_rejection("reducer_response_sanitization")
		return _invalid("reducer_response_sanitization", "The reducer response was not safe to expose.")
	var result: Dictionary = safe.value
	if not result.get("ok", false):
		_record_probe_rejection(str(result.get("code", "rejected")))
	return result


func _reducer_rejection(result: Dictionary) -> Dictionary:
	return {
		"ok": false,
		"code": str(result.get("code", "invalid_action")),
		"message": str(result.get("message", "The reducer rejected this intent.")),
		"state_hash": _state_hash(),
	}


func _record_probe_rejection(code: String) -> void:
	_probe_rejections[code] = int(_probe_rejections.get(code, 0)) + 1


func _reset_probe_diagnostics() -> void:
	_probe_count = 0
	_probe_rejections.clear()
	_generation_steps = 0
	_generation_limited = false


func _active_actor() -> String:
	match _module_id:
		"four_line":
			return str(_state.players[int(_state.turn_index)])
		"draughts":
			return str(_state.players.get(str(_state.turn), ""))
		"property_grid":
			return str(_state.players[int(_state.turn_index)].id)
	return ""


func _state_hash() -> String:
	if not is_configured():
		return ""
	return str(_reducer.state_hash(_state.duplicate(true)))


func _validate_state_shape(module: String, state: Dictionary) -> Dictionary:
	if str(state.get("module_id", "")) != module:
		return _invalid("state_module", "State does not belong to the configured module.")
	if not state.get("revision", null) is int or int(state.revision) < 0:
		return _invalid("state_revision", "State revision must be a non-negative integer.")
	if not state.get("status", null) is String:
		return _invalid("state_status", "State status must be a string.")
	match module:
		"four_line":
			if not state.get("players", null) is Array or state.players.size() != 2:
				return _invalid("state_players", "Four Line requires exactly two players.")
			if not _valid_player_id(state.players[0]) or not _valid_player_id(state.players[1]) or str(state.players[0]) == str(state.players[1]):
				return _invalid("state_players", "Four Line player ids must be distinct and non-empty.")
			if not state.get("turn_index", null) is int or int(state.turn_index) < 0 or int(state.turn_index) > 1:
				return _invalid("state_turn", "Four Line has an invalid turn index.")
			if not state.get("board", null) is Array or state.board.size() != 42:
				return _invalid("state_board", "Four Line requires a 42-cell board.")
			for cell in state.board:
				if not cell is String or (str(cell) != "" and str(cell) not in [str(state.players[0]), str(state.players[1])]):
					return _invalid("state_board", "Four Line contains an invalid board token.")
		"draughts":
			if not state.get("players", null) is Dictionary:
				return _invalid("state_players", "Draughts requires red and black player mappings.")
			if not _valid_player_id(state.players.get("red", null)) or not _valid_player_id(state.players.get("black", null)):
				return _invalid("state_players", "Draughts player ids must be non-empty.")
			if str(state.players.red) == str(state.players.black):
				return _invalid("state_players", "Draughts player ids must be distinct.")
			if str(state.get("turn", "")) not in ["red", "black"]:
				return _invalid("state_turn", "Draughts turn must be red or black.")
			if not state.get("board", null) is Array or state.board.size() != 64:
				return _invalid("state_board", "Draughts requires a 64-cell board.")
			for cell in state.board:
				if not cell is String or str(cell) not in DRAUGHTS_CODES:
					return _invalid("state_board", "Draughts contains an invalid piece code.")
		"property_grid":
			if not state.get("players", null) is Array or state.players.size() < 2 or state.players.size() > 6:
				return _invalid("state_players", "Property Grid requires two to six players.")
			if not state.get("board", null) is Array or state.board.is_empty() or state.board.size() > 128:
				return _invalid("state_board", "Property Grid has an invalid board.")
			if not state.get("turn_index", null) is int or int(state.turn_index) < 0 or int(state.turn_index) >= state.players.size():
				return _invalid("state_turn", "Property Grid has an invalid turn index.")
			if str(state.get("phase", "")) not in ["await_roll", "await_purchase", "await_end", "complete"]:
				return _invalid("state_phase", "Property Grid has an invalid phase.")
			var seen_ids: Dictionary = {}
			for player_variant in state.players:
				if not player_variant is Dictionary:
					return _invalid("state_players", "Property Grid contains a malformed player.")
				var player: Dictionary = player_variant
				var player_id := str(player.get("id", ""))
				if not _valid_player_id(player.get("id", null)) or seen_ids.has(player_id):
					return _invalid("state_players", "Property Grid player ids must be distinct and non-empty.")
				seen_ids[player_id] = true
				if not player.get("position", null) is int or int(player.position) < 0 or int(player.position) >= state.board.size():
					return _invalid("state_players", "Property Grid contains an invalid player position.")
				if not player.get("balance", null) is int or int(player.balance) < 0 or not player.get("bankrupt", null) is bool:
					return _invalid("state_players", "Property Grid contains invalid player accounting fields.")
			for space in state.board:
				if not space is Dictionary or not space.get("kind", null) is String:
					return _invalid("state_board", "Property Grid contains a malformed space.")
				var kind := str(space.kind)
				if kind not in ["start", "property", "tax", "grant", "rest"]:
					return _invalid("state_board", "Property Grid contains an unknown space kind.")
				if kind == "property" and (
					not space.get("price", null) is int or int(space.price) < 0
					or not space.get("rent", null) is int or int(space.rent) < 0
				):
					return _invalid("state_board", "Property Grid contains invalid property pricing.")
				if kind in ["tax", "grant"] and (not space.get("amount", null) is int or int(space.amount) < 0):
					return _invalid("state_board", "Property Grid contains an invalid transfer amount.")
			if not state.get("properties", null) is Dictionary or not state.get("rng_state", null) is int:
				return _invalid("state_fields", "Property Grid is missing deterministic state fields.")
			if not state.get("pass_reward", null) is int or int(state.pass_reward) < 0:
				return _invalid("state_fields", "Property Grid has an invalid pass reward.")
			if not state.get("round", null) is int or int(state.round) < 1 or not state.get("move_count", null) is int or int(state.move_count) < 0:
				return _invalid("state_fields", "Property Grid has invalid deterministic counters.")
			if not state.get("last_roll", null) is Array or state.last_roll.size() not in [0, 2]:
				return _invalid("state_fields", "Property Grid has a malformed last roll.")
			for die in state.last_roll:
				if not die is int or int(die) < 1 or int(die) > 6:
					return _invalid("state_fields", "Property Grid has an invalid die value.")
			if not state.get("last_event", null) is Dictionary:
				return _invalid("state_fields", "Property Grid has a malformed last event.")
			for property_key in state.properties:
				var position_text := str(property_key)
				if not position_text.is_valid_int():
					return _invalid("state_properties", "Property Grid contains an invalid property index.")
				var property_position := int(position_text)
				var owner := str(state.properties[property_key])
				if property_position < 0 or property_position >= state.board.size() or str(state.board[property_position].kind) != "property" or not seen_ids.has(owner):
					return _invalid("state_properties", "Property Grid contains an invalid property assignment.")
	return {"ok": true, "code": "valid"}


func _valid_player_id(value: Variant) -> bool:
	return value is String and not str(value).is_empty() and str(value).length() <= 256


func _sanitize_copy(value: Variant, depth: int = 0) -> Dictionary:
	if depth > MAX_NESTING_DEPTH:
		return {"ok": false, "message": "Value nesting exceeds the safe limit."}
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT:
			return {"ok": true, "value": value}
		TYPE_FLOAT:
			if not is_finite(float(value)):
				return {"ok": false, "message": "Non-finite numbers are not accepted."}
			return {"ok": true, "value": value}
		TYPE_STRING, TYPE_STRING_NAME:
			var string_value := str(value)
			if string_value.length() > MAX_STRING_LENGTH:
				return {"ok": false, "message": "A string exceeds the safe length limit."}
			return {"ok": true, "value": string_value}
		TYPE_ARRAY:
			if value.size() > MAX_COLLECTION_ITEMS:
				return {"ok": false, "message": "An array exceeds the safe item limit."}
			var safe_array: Array = []
			for item in value:
				var safe_item := _sanitize_copy(item, depth + 1)
				if not safe_item.ok:
					return safe_item
				safe_array.append(safe_item.value)
			return {"ok": true, "value": safe_array}
		TYPE_DICTIONARY:
			if value.size() > MAX_COLLECTION_ITEMS:
				return {"ok": false, "message": "A dictionary exceeds the safe item limit."}
			var safe_dictionary: Dictionary = {}
			for key_variant in value:
				if not key_variant is String and not key_variant is StringName:
					return {"ok": false, "message": "Dictionary keys must be strings."}
				var key := str(key_variant)
				if key.length() > 256 or safe_dictionary.has(key):
					return {"ok": false, "message": "A dictionary key is invalid or ambiguous."}
				var safe_item := _sanitize_copy(value[key_variant], depth + 1)
				if not safe_item.ok:
					return safe_item
				safe_dictionary[key] = safe_item.value
			return {"ok": true, "value": safe_dictionary}
		_:
			return {"ok": false, "message": "Only JSON-safe primitive values are accepted."}


func _normalize_module_id(module: String) -> String:
	var key := module.strip_edges().to_lower().replace("-", "_").replace(" ", "_")
	while "__" in key:
		key = key.replace("__", "_")
	return str(MODULE_ALIASES.get(key, key))


func _with_diagnostics(result: Dictionary) -> Dictionary:
	var response := result.duplicate(true)
	response["diagnostics"] = diagnostics()
	return response


func _remember(result: Dictionary) -> Dictionary:
	var response := result.duplicate(true)
	_last_code = str(response.get("code", "unknown"))
	response["diagnostics"] = diagnostics()
	return response


func _invalid(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
