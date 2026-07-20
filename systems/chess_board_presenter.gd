extends RefCounted

## Reducer-state to Godot scene adapter for Chess Core.
##
## This class owns no game rules.  It probes the supplied deterministic reducer,
## then reconciles an existing Node3D piece root from the accepted state.  Piece
## identity is stable across movement, castling, en-passant, and promotion.
##
## Public integration surface:
##   configure(piece_root, chess_reducer, options)
##   reconcile_state(state)
##   legal_destinations(state, from_square, actor)
##   preview_action(state, action) -> reducer result plus `diff`
##   cancel_preview()
##   commit_preview()
##
## Optional callbacks in `options`:
##   piece_factory(code, piece_id, square) -> Node3D
##   piece_updater(node, old_code, new_code) -> void
##   square_position(square, options) -> Vector3

signal piece_spawned(piece_id: String, piece: Node3D, square: int, code: String)
signal piece_moved(piece_id: String, piece: Node3D, from_square: int, to_square: int)
signal piece_removed(piece_id: String, piece: Node3D, square: int, code: String)
signal piece_promoted(piece_id: String, piece: Node3D, old_code: String, new_code: String)
signal piece_input(piece: Node3D, camera: Node, event: InputEvent, event_position: Vector3, normal: Vector3, shape_index: int)
signal preview_started(diff: Dictionary, result: Dictionary)
signal preview_cancelled(diff: Dictionary)
signal preview_committed(diff: Dictionary, state: Dictionary)

const BOARD_SQUARES := 64
const VALID_CODES := ["wK", "wQ", "wR", "wB", "wN", "wP", "bK", "bQ", "bR", "bB", "bN", "bP"]
const CODE_TO_KIND := {
	"K": "King",
	"Q": "Queen",
	"R": "Rook",
	"B": "Bishop",
	"N": "Knight",
	"P": "Pawn",
}
const KIND_TO_CODE := {
	"King": "K",
	"Queen": "Q",
	"Rook": "R",
	"Bishop": "B",
	"Knight": "N",
	"Pawn": "P",
}

var _piece_root: Node3D
var _reducer: RefCounted
var _options := {
	"tile_size": 0.9,
	"piece_y": 0.22,
	"origin": Vector3.ZERO,
	"white_color": Color("#d7ecff"),
	"black_color": Color("#17223a"),
	"white_emission": Color("#58dff5"),
	"black_emission": Color("#835cf2"),
}
var _piece_by_square: Dictionary = {}
var _piece_by_id: Dictionary = {}
var _presented_state: Dictionary = {}
var _pending: Dictionary = {}
var _snapshot: Dictionary = {}
var _serial := 0


func configure(piece_root: Node3D, chess_reducer: RefCounted, options: Dictionary = {}) -> Dictionary:
	if piece_root == null or not is_instance_valid(piece_root):
		return _invalid("piece_root", "A live Node3D piece root is required.")
	if chess_reducer == null or not chess_reducer.has_method("reduce") or not chess_reducer.has_method("state_hash"):
		return _invalid("reducer", "A Chess Core compatible deterministic reducer is required.")
	if not _pending.is_empty():
		cancel_preview()
	_piece_root = piece_root
	_reducer = chess_reducer
	_options.merge(options, true)
	_piece_by_square.clear()
	_piece_by_id.clear()
	_adopt_existing_pieces()
	return {
		"ok": true,
		"code": "configured",
		"adopted": _piece_by_id.size(),
	}


func is_configured() -> bool:
	return _piece_root != null and is_instance_valid(_piece_root) and _reducer != null


func reconcile_state(state: Dictionary) -> Dictionary:
	var state_verdict := _validate_state(state)
	if not state_verdict.ok:
		return state_verdict
	if not is_configured():
		return _invalid("not_configured", "Configure a piece root and reducer before reconciliation.")
	if not _pending.is_empty():
		cancel_preview()

	# Reserve exact square/code matches first.  Remaining identical pieces are
	# reused in stable-id order, which keeps remote snapshot reconciliation
	# deterministic without inventing identity in the reducer's JSON state.
	var assigned_ids: Dictionary = {}
	var assigned_squares: Dictionary = {}
	for square in range(BOARD_SQUARES):
		var code := str(state.board[square])
		if code == "":
			continue
		var exact: Node3D = _piece_by_square.get(square)
		if exact != null and str(exact.get_meta("chess_piece_code", "")) == code:
			var exact_id := str(exact.get_meta("chess_piece_id", ""))
			assigned_ids[exact_id] = true
			assigned_squares[square] = exact

	var reusable: Array[Node3D] = []
	for piece_variant in _piece_by_id.values():
		var piece: Node3D = piece_variant
		var piece_id := str(piece.get_meta("chess_piece_id", ""))
		if not assigned_ids.has(piece_id):
			reusable.append(piece)
	reusable.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		return str(a.get_meta("chess_piece_id", "")) < str(b.get_meta("chess_piece_id", ""))
	)

	for square in range(BOARD_SQUARES):
		var code := str(state.board[square])
		if code == "" or assigned_squares.has(square):
			continue
		var selected: Node3D
		for candidate in reusable:
			if str(candidate.get_meta("chess_piece_code", "")) == code:
				selected = candidate
				break
		if selected != null:
			reusable.erase(selected)
			var selected_id := str(selected.get_meta("chess_piece_id", ""))
			assigned_ids[selected_id] = true
			assigned_squares[square] = selected
		else:
			var spawned := _spawn_piece(code, square)
			var spawned_id := str(spawned.get_meta("chess_piece_id", ""))
			assigned_ids[spawned_id] = true
			assigned_squares[square] = spawned

	# Remove unassigned scene pieces immediately.  This path reconciles an
	# authoritative committed snapshot, unlike preview where captures stay alive.
	for piece_variant in _piece_by_id.values().duplicate():
		var piece: Node3D = piece_variant
		var piece_id := str(piece.get_meta("chess_piece_id", ""))
		if not assigned_ids.has(piece_id):
			_destroy_piece(piece)

	_piece_by_square.clear()
	for square_variant in assigned_squares:
		var square := int(square_variant)
		var piece: Node3D = assigned_squares[square_variant]
		_set_piece_square(piece, square)
		_set_piece_code(piece, str(state.board[square]))
		_set_piece_available(piece, true)
		_piece_by_square[square] = piece

	_presented_state = state.duplicate(true)
	return {
		"ok": true,
		"code": "reconciled",
		"pieces": _piece_by_id.size(),
		"state_hash": _reducer.state_hash(_presented_state),
	}


func legal_destinations(state: Dictionary, from_square: int, actor: String = "") -> Array[int]:
	var destinations: Array[int] = []
	if not is_configured() or not _validate_state(state).ok:
		return destinations
	if from_square < 0 or from_square >= BOARD_SQUARES:
		return destinations
	var resolved_actor := actor
	if resolved_actor.is_empty():
		var turn := str(state.get("turn", ""))
		resolved_actor = str(state.get("players", {}).get(turn, ""))
	if resolved_actor.is_empty():
		return destinations
	for destination in range(BOARD_SQUARES):
		var action := {
			"type": "move",
			"actor": resolved_actor,
			"from": from_square,
			"to": destination,
			"expected_revision": int(state.get("revision", 0)),
			"expected_state_hash": _reducer.state_hash(state),
		}
		# Chess Core defaults last-rank promotion to a queen when omitted, so the
		# same reducer probe covers ordinary moves and promotion destinations.
		var result: Dictionary = _reducer.reduce(state, action)
		if result.get("ok", false):
			destinations.append(destination)
	return destinations


func legal_actions(state: Dictionary, from_square: int, actor: String = "") -> Array[Dictionary]:
	var actions: Array[Dictionary] = []
	var resolved_actor := actor
	if resolved_actor.is_empty():
		var turn := str(state.get("turn", ""))
		resolved_actor = str(state.get("players", {}).get(turn, ""))
	for destination in legal_destinations(state, from_square, resolved_actor):
		actions.append({
			"type": "move",
			"actor": resolved_actor,
			"from": from_square,
			"to": destination,
		})
	return actions


func preview_action(state: Dictionary, action: Dictionary) -> Dictionary:
	if not is_configured():
		return _invalid("not_configured", "Configure a piece root and reducer before previewing.")
	if not _pending.is_empty():
		return _invalid("preview_active", "Commit or cancel the current preview first.")
	var state_verdict := _validate_state(state)
	if not state_verdict.ok:
		return state_verdict

	# If an external peer advanced the state, first make the presentation agree
	# with that authoritative snapshot.  Hash comparison avoids needless churn.
	if _presented_state.is_empty() or _reducer.state_hash(_presented_state) != _reducer.state_hash(state):
		var reconciliation := reconcile_state(state)
		if not reconciliation.ok:
			return reconciliation

	var result: Dictionary = _reducer.reduce(state, action)
	if not result.get("ok", false):
		return result
	if not result.get("state", null) is Dictionary:
		return _invalid("reducer_state", "The reducer returned no valid preview state.")
	var next_state: Dictionary = Dictionary(result.state).duplicate(true)
	var canonical_hash := str(_reducer.state_hash(next_state))
	var reported_hash := str(result.get("state_hash", ""))
	if not reported_hash.is_empty() and reported_hash != canonical_hash:
		return _invalid("reducer_hash_mismatch", "The reducer receipt does not match its canonical preview state hash.")
	result["state"] = next_state
	result["state_hash"] = canonical_hash
	var diff := calculate_diff(state, next_state, action)
	if not diff.ok:
		return diff
	_snapshot = _capture_snapshot()
	var applied := _apply_preview_diff(diff)
	if not applied.ok:
		_restore_snapshot()
		_snapshot.clear()
		return applied
	_pending = {
		"result": result.duplicate(true),
		"diff": diff.duplicate(true),
		"action": action.duplicate(true),
		"base_revision": int(state.get("revision", 0)),
		"base_hash": str(_reducer.state_hash(state)),
	}
	var response := result.duplicate(true)
	response["code"] = "previewed"
	response["diff"] = diff.duplicate(true)
	preview_started.emit(diff.duplicate(true), response.duplicate(true))
	return response


func cancel_preview() -> Dictionary:
	if _pending.is_empty():
		return _invalid("no_preview", "There is no chess preview to cancel.")
	var diff: Dictionary = _pending.diff.duplicate(true)
	_restore_snapshot()
	_pending.clear()
	_snapshot.clear()
	preview_cancelled.emit(diff)
	return {
		"ok": true,
		"code": "preview_cancelled",
		"diff": diff,
		"state": _presented_state.duplicate(true),
	}


func commit_preview(authoritative_state: Dictionary = {}) -> Dictionary:
	if _pending.is_empty():
		return _invalid("no_preview", "There is no chess preview to commit.")
	var base_state: Dictionary = _presented_state if authoritative_state.is_empty() else authoritative_state
	var state_verdict := _validate_state(base_state)
	if not state_verdict.ok:
		return _abort_pending_preview("authoritative_state", "The authoritative chess state is malformed.")
	var base_hash := str(_reducer.state_hash(base_state))
	if base_hash != str(_pending.base_hash) or int(base_state.get("revision", -1)) != int(_pending.base_revision):
		return _abort_pending_preview("preview_stale", "The authoritative chess state changed after this preview was created.")
	var reprobe: Dictionary = _reducer.reduce(base_state, Dictionary(_pending.action).duplicate(true))
	if not reprobe.get("ok", false):
		return _abort_pending_preview("preview_rejected", "The reducer no longer accepts the pending chess action.")
	if not reprobe.get("state", null) is Dictionary:
		return _abort_pending_preview("reducer_state", "The reducer returned no valid committed chess state.")
	var reprobed_state: Dictionary = Dictionary(reprobe.state).duplicate(true)
	var canonical_hash := str(_reducer.state_hash(reprobed_state))
	var reported_hash := str(reprobe.get("state_hash", ""))
	if not reported_hash.is_empty() and reported_hash != canonical_hash:
		return _abort_pending_preview("reducer_hash_mismatch", "The reducer receipt does not match its canonical committed state hash.")
	var expected_hash := str(_pending.result.get("state_hash", _reducer.state_hash(_pending.result.state)))
	if canonical_hash != expected_hash:
		return _abort_pending_preview("nondeterministic_result", "The reducer result changed between preview and commit.")
	var result: Dictionary = reprobe.duplicate(true)
	result["state"] = reprobed_state
	result["state_hash"] = canonical_hash
	var diff: Dictionary = _pending.diff.duplicate(true)
	for removed_variant in diff.removes:
		var removed: Dictionary = removed_variant
		var piece_id := str(removed.get("piece_id", ""))
		var piece: Node3D = _piece_by_id.get(piece_id)
		if piece != null:
			_destroy_piece(piece)
	_presented_state = result.state.duplicate(true)
	_pending.clear()
	_snapshot.clear()
	preview_committed.emit(diff.duplicate(true), _presented_state.duplicate(true))
	return {
		"ok": true,
		"code": "preview_committed",
		"diff": diff,
		"state": _presented_state.duplicate(true),
		"state_hash": str(result.get("state_hash", _reducer.state_hash(_presented_state))),
	}


func _abort_pending_preview(code: String, message: String) -> Dictionary:
	var diff: Dictionary = _pending.get("diff", {}).duplicate(true)
	_restore_snapshot()
	_pending.clear()
	_snapshot.clear()
	preview_cancelled.emit(diff)
	return _invalid(code, message)


func has_preview() -> bool:
	return not _pending.is_empty()


func presented_state() -> Dictionary:
	return _presented_state.duplicate(true)


func piece_for_square(square: int) -> Node3D:
	return _piece_by_square.get(square)


func piece_for_id(piece_id: String) -> Node3D:
	return _piece_by_id.get(piece_id)


func piece_count() -> int:
	return _piece_by_id.size()


func square_map() -> Dictionary:
	return _piece_by_square.duplicate()


func calculate_diff(before: Dictionary, after: Dictionary, action: Dictionary = {}) -> Dictionary:
	var before_verdict := _validate_state(before)
	if not before_verdict.ok:
		return before_verdict
	var after_verdict := _validate_state(after)
	if not after_verdict.ok:
		return after_verdict
	var moves: Array[Dictionary] = []
	var removes: Array[Dictionary] = []
	var spawns: Array[Dictionary] = []
	var promotions: Array[Dictionary] = []
	var move_sources: Dictionary = {}
	var move_targets: Dictionary = {}

	var from_square := int(action.get("from", -1))
	var to_square := int(action.get("to", -1))
	if from_square >= 0 and from_square < BOARD_SQUARES and to_square >= 0 and to_square < BOARD_SQUARES:
		var from_code := str(before.board[from_square])
		var to_code := str(after.board[to_square])
		if from_code != "" and to_code != "":
			moves.append({
				"role": "primary",
				"from": from_square,
				"to": to_square,
				"before_code": from_code,
				"after_code": to_code,
			})
			move_sources[from_square] = true
			move_targets[to_square] = true
			if from_code != to_code:
				promotions.append({
					"square": to_square,
					"before_code": from_code,
					"after_code": to_code,
				})

			# Castling is the only chess action moving a second friendly piece.
			if from_code.ends_with("K") and absi((to_square % 8) - (from_square % 8)) == 2:
				var row := from_square / 8
				var kingside := to_square % 8 == 6
				var rook_from := row * 8 + (7 if kingside else 0)
				var rook_to := row * 8 + (5 if kingside else 3)
				if str(before.board[rook_from]).ends_with("R") and str(after.board[rook_to]).ends_with("R"):
					moves.append({
						"role": "castle_rook",
						"from": rook_from,
						"to": rook_to,
						"before_code": str(before.board[rook_from]),
						"after_code": str(after.board[rook_to]),
					})
					move_sources[rook_from] = true
					move_targets[rook_to] = true

	# Any displaced before-piece that is not a move source is a capture.  This
	# naturally detects both ordinary target captures and off-target en-passant.
	for square in range(BOARD_SQUARES):
		var old_code := str(before.board[square])
		var new_code := str(after.board[square])
		if old_code != "" and old_code != new_code and not move_sources.has(square):
			removes.append({"square": square, "code": old_code})

	# State snapshots without a supplied action may contain additions.  Preserve
	# those in the diff so callers can inspect the transition deterministically.
	for square in range(BOARD_SQUARES):
		var old_code := str(before.board[square])
		var new_code := str(after.board[square])
		if new_code != "" and old_code != new_code and not move_targets.has(square):
			spawns.append({"square": square, "code": new_code})

	return {
		"ok": true,
		"code": "diff_ready",
		"moves": moves,
		"removes": removes,
		"spawns": spawns,
		"promotions": promotions,
		"before_revision": int(before.get("revision", 0)),
		"after_revision": int(after.get("revision", 0)),
	}


func _apply_preview_diff(diff: Dictionary) -> Dictionary:
	# Captures leave the scene node alive but unavailable so cancel can restore it.
	for remove_index in range(diff.removes.size()):
		var removed: Dictionary = diff.removes[remove_index]
		var square := int(removed.square)
		var piece: Node3D = _piece_by_square.get(square)
		if piece == null:
			return _invalid("capture_piece_missing", "No presented piece exists at capture square %d." % square)
		var piece_id := str(piece.get_meta("chess_piece_id", ""))
		removed["piece_id"] = piece_id
		diff.removes[remove_index] = removed
		_piece_by_square.erase(square)
		_set_piece_available(piece, false)
		piece_removed.emit(piece_id, piece, square, str(removed.code))

	for move_index in range(diff.moves.size()):
		var move: Dictionary = diff.moves[move_index]
		var from_square := int(move.from)
		var to_square := int(move.to)
		var piece: Node3D = _piece_by_square.get(from_square)
		if piece == null:
			return _invalid("moving_piece_missing", "No presented piece exists at move source %d." % from_square)
		var piece_id := str(piece.get_meta("chess_piece_id", ""))
		move["piece_id"] = piece_id
		diff.moves[move_index] = move
		_piece_by_square.erase(from_square)
		_set_piece_square(piece, to_square)
		_piece_by_square[to_square] = piece
		piece_moved.emit(piece_id, piece, from_square, to_square)
		var new_code := str(move.after_code)
		if str(piece.get_meta("chess_piece_code", "")) != new_code:
			_set_piece_code(piece, new_code)

	for spawn_index in range(diff.spawns.size()):
		var spawn: Dictionary = diff.spawns[spawn_index]
		var spawned := _spawn_piece(str(spawn.code), int(spawn.square))
		spawn["piece_id"] = str(spawned.get_meta("chess_piece_id", ""))
		diff.spawns[spawn_index] = spawn

	return {"ok": true, "code": "preview_applied"}


func _capture_snapshot() -> Dictionary:
	var pieces: Dictionary = {}
	for piece_id_variant in _piece_by_id:
		var piece_id := str(piece_id_variant)
		var piece: Node3D = _piece_by_id[piece_id_variant]
		pieces[piece_id] = {
			"node": piece,
			"square": int(piece.get_meta("chess_square", -1)),
			"code": str(piece.get_meta("chess_piece_code", "")),
			"position": piece.position,
			"visible": piece.visible,
			"input_ray_pickable": piece.input_ray_pickable if piece is CollisionObject3D else false,
		}
	return {"pieces": pieces}


func _restore_snapshot() -> void:
	if _snapshot.is_empty():
		return
	var original_pieces: Dictionary = _snapshot.get("pieces", {})
	# Destroy only nodes spawned as part of the preview.
	for piece_id_variant in _piece_by_id.keys().duplicate():
		var piece_id := str(piece_id_variant)
		if not original_pieces.has(piece_id):
			var added: Node3D = _piece_by_id[piece_id_variant]
			_destroy_piece(added)
	_piece_by_square.clear()
	for piece_id_variant in original_pieces:
		var piece_id := str(piece_id_variant)
		var saved: Dictionary = original_pieces[piece_id_variant]
		var piece: Node3D = saved.node
		if piece == null or not is_instance_valid(piece):
			continue
		_set_piece_code(piece, str(saved.code))
		piece.position = saved.position
		piece.visible = bool(saved.visible)
		if piece is CollisionObject3D:
			piece.input_ray_pickable = bool(saved.input_ray_pickable)
		var square := int(saved.square)
		_set_piece_metadata_square(piece, square)
		_piece_by_id[piece_id] = piece
		_piece_by_square[square] = piece


func _adopt_existing_pieces() -> void:
	for child in _piece_root.get_children():
		if not child is Node3D:
			continue
		var piece: Node3D = child
		var code := str(piece.get_meta("chess_piece_code", ""))
		var square := int(piece.get_meta("chess_square", -1))
		if code.is_empty():
			code = _legacy_code(piece)
		if square < 0 and piece.has_meta("coord"):
			var coord_variant = piece.get_meta("coord")
			if coord_variant is Vector2i:
				var coord: Vector2i = coord_variant
				square = coord.y * 8 + coord.x
		if code not in VALID_CODES or square < 0 or square >= BOARD_SQUARES or _piece_by_square.has(square):
			continue
		var piece_id := str(piece.get_meta("chess_piece_id", ""))
		if piece_id.is_empty() or _piece_by_id.has(piece_id):
			piece_id = _allocate_piece_id(code, square)
		piece.set_meta("chess_piece_id", piece_id)
		piece.set_meta("chess_piece_code", code)
		_set_piece_metadata_square(piece, square)
		_piece_by_id[piece_id] = piece
		_piece_by_square[square] = piece


func _spawn_piece(code: String, square: int) -> Node3D:
	var piece_id := _allocate_piece_id(code, square)
	var piece: Node3D
	var factory_variant = _options.get("piece_factory")
	if factory_variant is Callable and factory_variant.is_valid():
		var created = factory_variant.call(code, piece_id, square)
		if created is Node3D:
			piece = created
	if piece == null:
		piece = _create_fallback_piece(code)
		piece.set_meta("chess_presenter_fallback", true)
	if piece.get_parent() != _piece_root:
		_piece_root.add_child(piece)
	piece.name = _safe_node_name(piece_id)
	piece.set_meta("chess_piece_id", piece_id)
	piece.set_meta("chess_piece_code", code)
	piece.set_meta("side", "Ivory" if code.begins_with("w") else "Obsidian")
	piece.set_meta("kind", CODE_TO_KIND.get(code.substr(1, 1), "Unknown"))
	piece.set_meta("chess_presenter_owned", true)
	_set_piece_square(piece, square)
	_set_piece_available(piece, true)
	_piece_by_id[piece_id] = piece
	_piece_by_square[square] = piece
	if piece is Area3D and not piece.input_event.is_connected(_forward_piece_input.bind(piece)):
		piece.input_event.connect(_forward_piece_input.bind(piece))
	piece_spawned.emit(piece_id, piece, square, code)
	return piece


func _destroy_piece(piece: Node3D) -> void:
	if piece == null or not is_instance_valid(piece):
		return
	var piece_id := str(piece.get_meta("chess_piece_id", ""))
	var square := int(piece.get_meta("chess_square", -1))
	_piece_by_id.erase(piece_id)
	if _piece_by_square.get(square) == piece:
		_piece_by_square.erase(square)
	if piece.get_parent() != null:
		piece.get_parent().remove_child(piece)
	piece.queue_free()


func _set_piece_square(piece: Node3D, square: int) -> void:
	_set_piece_metadata_square(piece, square)
	piece.position = _square_position(square)


func _set_piece_metadata_square(piece: Node3D, square: int) -> void:
	piece.set_meta("chess_square", square)
	piece.set_meta("coord", Vector2i(square % 8, square / 8))
	piece.set_meta("tile", float(_options.get("tile_size", 0.9)))


func _set_piece_code(piece: Node3D, code: String) -> void:
	var old_code := str(piece.get_meta("chess_piece_code", ""))
	if old_code == code:
		return
	piece.set_meta("chess_piece_code", code)
	piece.set_meta("side", "Ivory" if code.begins_with("w") else "Obsidian")
	piece.set_meta("kind", CODE_TO_KIND.get(code.substr(1, 1), "Unknown"))
	var updater_variant = _options.get("piece_updater")
	if updater_variant is Callable and updater_variant.is_valid():
		updater_variant.call(piece, old_code, code)
	elif bool(piece.get_meta("chess_presenter_fallback", false)):
		_rebuild_fallback_visual(piece, code)
	if not old_code.is_empty():
		piece_promoted.emit(str(piece.get_meta("chess_piece_id", "")), piece, old_code, code)


func _set_piece_available(piece: Node3D, available: bool) -> void:
	piece.visible = available
	if piece is CollisionObject3D:
		piece.input_ray_pickable = available


func _square_position(square: int) -> Vector3:
	var callback_variant = _options.get("square_position")
	if callback_variant is Callable and callback_variant.is_valid():
		var value = callback_variant.call(square, _options.duplicate())
		if value is Vector3:
			return value
	var tile := float(_options.get("tile_size", 0.9))
	var origin: Vector3 = _options.get("origin", Vector3.ZERO)
	return origin + Vector3(((square % 8) - 3.5) * tile, float(_options.get("piece_y", 0.22)), ((square / 8) - 3.5) * tile)


func _allocate_piece_id(code: String, square: int) -> String:
	var base := "chess:%s:%02d" % [code, square]
	var candidate := base
	while _piece_by_id.has(candidate):
		_serial += 1
		candidate = "%s:%03d" % [base, _serial]
	return candidate


func _safe_node_name(piece_id: String) -> String:
	return piece_id.replace(":", "_").replace("/", "_")


func _legacy_code(piece: Node3D) -> String:
	if not piece.has_meta("kind") or not piece.has_meta("side"):
		return ""
	var kind_code := str(KIND_TO_CODE.get(str(piece.get_meta("kind")), ""))
	var side := str(piece.get_meta("side", ""))
	var prefix := "w" if side.to_lower() in ["ivory", "white", "w"] else "b"
	return prefix + kind_code if not kind_code.is_empty() else ""


func _validate_state(state: Dictionary) -> Dictionary:
	if state.has("module_id") and str(state.module_id) != "chess_core":
		return _invalid("state_module", "Presenter accepts only Chess Core reducer state.")
	if not state.get("board", null) is Array:
		return _invalid("state_board", "Chess state must contain a board array.")
	if state.board.size() != BOARD_SQUARES:
		return _invalid("state_board_size", "Chess board must contain exactly 64 squares.")
	for code_variant in state.board:
		var code := str(code_variant)
		if not code.is_empty() and code not in VALID_CODES:
			return _invalid("piece_code", "Chess board contains an unsupported piece code.")
	return {"ok": true, "code": "valid_state"}


func _create_fallback_piece(code: String) -> Area3D:
	var piece := Area3D.new()
	piece.input_ray_pickable = true
	_rebuild_fallback_visual(piece, code)
	return piece


func _rebuild_fallback_visual(piece: Node3D, code: String) -> void:
	for child in piece.get_children():
		if bool(child.get_meta("chess_presenter_visual", false)):
			piece.remove_child(child)
			child.queue_free()
	var is_white := code.begins_with("w")
	var color: Color = _options.get("white_color" if is_white else "black_color")
	var emission: Color = _options.get("white_emission" if is_white else "black_emission")
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = 0.42
	material.roughness = 0.28
	material.emission_enabled = true
	material.emission = emission
	material.emission_energy_multiplier = 0.24 if is_white else 0.38

	_add_cylinder_visual(piece, 0.28, 0.10, 24, 0.05, material)
	_add_cylinder_visual(piece, 0.215, 0.14, 24, 0.16, material)
	var kind := code.substr(1, 1)
	var stem_height := 0.18 if kind == "P" else 0.30
	_add_cylinder_visual(piece, 0.105, stem_height, 18, 0.25 + stem_height * 0.5, material, 0.15)
	match kind:
		"P":
			_add_sphere_visual(piece, 0.14, 0.51, material)
		"N":
			var crown := _add_box_visual(piece, Vector3(0.22, 0.34, 0.16), 0.59, material)
			crown.rotation_degrees.z = -18.0
		"B":
			var crown := _add_sphere_visual(piece, 0.18, 0.59, material)
			crown.scale.y = 1.42
		"R":
			_add_cylinder_visual(piece, 0.21, 0.22, 6, 0.60, material)
		"Q":
			_add_cylinder_visual(piece, 0.215, 0.24, 8, 0.61, material, 0.09)
			_add_sphere_visual(piece, 0.075, 0.76, material)
		"K":
			_add_box_visual(piece, Vector3(0.12, 0.36, 0.12), 0.64, material)
			_add_box_visual(piece, Vector3(0.30, 0.075, 0.09), 0.69, material)

	var collision := CollisionShape3D.new()
	collision.set_meta("chess_presenter_visual", true)
	var shape := CylinderShape3D.new()
	shape.height = 0.98
	shape.radius = 0.31
	collision.shape = shape
	collision.position.y = 0.42
	piece.add_child(collision)


func _add_cylinder_visual(parent: Node3D, radius: float, height: float, sides: int, y: float, material: Material, top_radius: float = -1.0) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.bottom_radius = radius
	mesh.top_radius = radius if top_radius < 0.0 else top_radius
	mesh.height = height
	mesh.radial_segments = sides
	var instance := _visual_instance(mesh, material)
	instance.position.y = y
	parent.add_child(instance)
	return instance


func _add_sphere_visual(parent: Node3D, radius: float, y: float, material: Material) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 16
	mesh.rings = 10
	var instance := _visual_instance(mesh, material)
	instance.position.y = y
	parent.add_child(instance)
	return instance


func _add_box_visual(parent: Node3D, size: Vector3, y: float, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := _visual_instance(mesh, material)
	instance.position.y = y
	parent.add_child(instance)
	return instance


func _visual_instance(mesh: Mesh, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.set_meta("chess_presenter_visual", true)
	return instance


func _forward_piece_input(camera: Node, event: InputEvent, event_position: Vector3, normal: Vector3, shape_index: int, piece: Node3D) -> void:
	piece_input.emit(piece, camera, event, event_position, normal, shape_index)


func _invalid(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
