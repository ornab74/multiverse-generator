extends RefCounted

## State-driven, code-native presentation for the non-chess tabletop modules.
##
## This adapter deliberately owns no game rules. It validates reducer snapshot
## shape, builds only Godot primitive geometry, and reconciles the scene to the
## supplied authoritative state. Consumers remain responsible for sending any
## emitted target intent through a deterministic reducer before committing it.

signal target_clicked(kind: String, index: int, world_position: Vector3)

const SUPPORTED_MODULES := ["four_line", "draughts", "property_grid"]
const MODULE_ALIASES := {
	"four line": "four_line",
	"four_line": "four_line",
	"connect four": "four_line",
	"connect_four": "four_line",
	"connect_4": "four_line",
	"draughts": "draughts",
	"checkers": "draughts",
	"property grid": "property_grid",
	"property_grid": "property_grid",
	"property loop": "property_grid",
	"property_loop": "property_grid",
	"monopoly": "property_grid",
}
const DRAUGHTS_CODES := ["", "r", "R", "b", "B"]
const PROPERTY_KINDS := ["start", "property", "tax", "grant", "rest"]
const PROPERTY_ACTIONS := ["roll", "buy", "pass", "end_turn"]
const PLAYER_COLORS := [
	Color("#5de1f4"),
	Color("#8d6cff"),
	Color("#ff6b82"),
	Color("#ffd166"),
	Color("#77e58f"),
	Color("#f29ce4"),
]
const MAX_ID_LENGTH := 128
const MAX_LABEL_LENGTH := 160

var _board_root: Node3D
var _piece_root: Node3D
var _board_layer: Node3D
var _piece_layer: Node3D
var _module_id := ""
var _options := {
	"tile_size": 0.9,
	"origin": Vector3.ZERO,
	"board_y": 0.10,
	"piece_y": 0.22,
	"light_color": Color("#26364d"),
	"dark_color": Color("#0c1424"),
	"line_color": Color("#26384f"),
	"cyan": Color("#5de1f4"),
	"violet": Color("#8d6cff"),
	"red": Color("#ff6278"),
	"black": Color("#121a2a"),
}
var _targets: Dictionary = {}
var _piece_by_slot: Dictionary = {}
var _piece_by_id: Dictionary = {}
var _space_nodes: Dictionary = {}
var _ownership_accents: Dictionary = {}
var _presented_state: Dictionary = {}
var _materials: Dictionary = {}
var _serial := 0
var _stats := {
	"configured": false,
	"reconciliations": 0,
	"created": 0,
	"reused": 0,
	"removed": 0,
	"last_created": 0,
	"last_reused": 0,
	"last_removed": 0,
	"last_code": "not_configured",
	"last_message": "",
}


func configure(board_root: Node3D, piece_root: Node3D, module_id: String, options: Dictionary = {}) -> Dictionary:
	if board_root == null or not is_instance_valid(board_root):
		return _remember_invalid("board_root", "A live Node3D board root is required.")
	if piece_root == null or not is_instance_valid(piece_root):
		return _remember_invalid("piece_root", "A live Node3D piece root is required.")
	var normalized := _normalize_module_id(module_id)
	if normalized not in SUPPORTED_MODULES:
		return _remember_invalid("unsupported_module", "Only Four Line, Draughts, and Property Grid are supported.")
	var safe_options := _validated_options(options)
	if not safe_options.get("ok", false):
		return _remember_invalid(str(safe_options.code), str(safe_options.message))

	_dispose_layers()
	_board_root = board_root
	_piece_root = piece_root
	_module_id = normalized
	_options = safe_options.value
	_targets.clear()
	_piece_by_slot.clear()
	_piece_by_id.clear()
	_space_nodes.clear()
	_ownership_accents.clear()
	_presented_state.clear()
	_materials.clear()
	_serial = 0

	_board_layer = Node3D.new()
	_board_layer.name = "TabletopPresenterBoard"
	_board_layer.set_meta("tabletop_presenter_owned", true)
	_board_root.add_child(_board_layer)
	_piece_layer = Node3D.new()
	_piece_layer.name = "TabletopPresenterPieces"
	_piece_layer.set_meta("tabletop_presenter_owned", true)
	_piece_root.add_child(_piece_layer)

	match _module_id:
		"four_line":
			_build_four_line_board()
		"draughts":
			_build_draughts_board()
		"property_grid":
			_build_property_board()

	_stats.configured = true
	_stats.last_code = "configured"
	_stats.last_message = ""
	return {
		"ok": true,
		"code": "configured",
		"module_id": _module_id,
		"target_count": _targets.size(),
		"diagnostics": diagnostics(),
	}


func is_configured() -> bool:
	return (
		_module_id in SUPPORTED_MODULES
		and _board_root != null
		and is_instance_valid(_board_root)
		and _piece_root != null
		and is_instance_valid(_piece_root)
		and _board_layer != null
		and is_instance_valid(_board_layer)
		and _piece_layer != null
		and is_instance_valid(_piece_layer)
	)


func module_id() -> String:
	return _module_id


func reconcile_state(state: Dictionary) -> Dictionary:
	if not is_configured():
		return _remember_invalid("not_configured", "Configure live board and piece roots before reconciliation.")
	var verdict := _validate_state(state)
	if not verdict.get("ok", false):
		return _remember_invalid(str(verdict.code), str(verdict.message))

	_stats.last_created = 0
	_stats.last_reused = 0
	_stats.last_removed = 0
	match _module_id:
		"four_line":
			_reconcile_four_line(state)
		"draughts":
			_reconcile_draughts(state)
		"property_grid":
			_reconcile_property_grid(state)
	_presented_state = state.duplicate(true)
	_stats.reconciliations = int(_stats.reconciliations) + 1
	_stats.last_code = "reconciled"
	_stats.last_message = ""
	return {
		"ok": true,
		"code": "reconciled",
		"module_id": _module_id,
		"revision": int(state.get("revision", 0)),
		"piece_count": _piece_by_id.size(),
		"target_count": _targets.size(),
		"created": int(_stats.last_created),
		"reused": int(_stats.last_reused),
		"removed": int(_stats.last_removed),
		"diagnostics": diagnostics(),
	}


func presented_state() -> Dictionary:
	return _presented_state.duplicate(true)


func piece_count() -> int:
	return _piece_by_id.size()


func target_count(kind: String = "") -> int:
	return target_nodes(kind).size()


func piece_for_slot(index: int) -> Node3D:
	return _piece_by_slot.get(index)


func piece_for_id(piece_id: String) -> Node3D:
	return _piece_by_id.get(piece_id)


func space_for_index(index: int) -> Area3D:
	return _space_nodes.get(index)


func target_for(kind: String, index: int) -> Area3D:
	return _targets.get(_target_key(kind, index))


func target_nodes(kind: String = "") -> Array[Area3D]:
	var result: Array[Area3D] = []
	for target_variant in _targets.values():
		var target: Area3D = target_variant
		if target == null or not is_instance_valid(target):
			continue
		if kind.is_empty() or str(target.get_meta("target_kind", "")) == kind:
			result.append(target)
	result.sort_custom(func(left: Area3D, right: Area3D) -> bool:
		var left_kind := str(left.get_meta("target_kind", ""))
		var right_kind := str(right.get_meta("target_kind", ""))
		if left_kind == right_kind:
			return int(left.get_meta("target_index", -1)) < int(right.get_meta("target_index", -1))
		return left_kind < right_kind
	)
	return result


func activate_target(kind: String, index: int) -> Dictionary:
	var target := target_for(kind, index)
	if target == null or not is_instance_valid(target):
		return _remember_invalid("target_missing", "The requested presentation target does not exist.")
	var world_position := target.global_position
	target_clicked.emit(str(target.get_meta("target_kind", kind)), int(target.get_meta("target_index", index)), world_position)
	_stats.last_code = "target_activated"
	_stats.last_message = ""
	return {
		"ok": true,
		"code": "target_activated",
		"kind": str(target.get_meta("target_kind", kind)),
		"index": int(target.get_meta("target_index", index)),
		"world_position": world_position,
	}


func diagnostics() -> Dictionary:
	var by_kind := {}
	for target_variant in _targets.values():
		var target: Area3D = target_variant
		if target == null or not is_instance_valid(target):
			continue
		var kind := str(target.get_meta("target_kind", "unknown"))
		by_kind[kind] = int(by_kind.get(kind, 0)) + 1
	return {
		"configured": is_configured(),
		"module_id": _module_id,
		"revision": int(_presented_state.get("revision", -1)),
		"piece_count": _piece_by_id.size(),
		"target_count": _targets.size(),
		"targets_by_kind": by_kind,
		"reconciliations": int(_stats.reconciliations),
		"created": int(_stats.created),
		"reused": int(_stats.reused),
		"removed": int(_stats.removed),
		"last_created": int(_stats.last_created),
		"last_reused": int(_stats.last_reused),
		"last_removed": int(_stats.last_removed),
		"last_code": str(_stats.last_code),
		"last_message": str(_stats.last_message),
		"asset_policy": "procedural_native",
	}


func dispose() -> void:
	_dispose_layers()
	_board_root = null
	_piece_root = null
	_module_id = ""
	_targets.clear()
	_piece_by_slot.clear()
	_piece_by_id.clear()
	_space_nodes.clear()
	_ownership_accents.clear()
	_presented_state.clear()
	_materials.clear()
	_stats.configured = false
	_stats.last_code = "disposed"
	_stats.last_message = ""


func _build_four_line_board() -> void:
	var tile := float(_options.tile_size)
	var origin: Vector3 = _options.origin
	var board_width := tile * 7.0 + 0.48
	var board_depth := tile * 6.0 + 0.48
	var base := _box_instance(Vector3(board_width, 0.22, board_depth), _material("board_base", Color("#08111f"), Color("#102f49"), 0.22, 0.42))
	base.name = "FourLineBase"
	base.position = origin + Vector3(0.0, -0.08, 0.0)
	_board_layer.add_child(base)

	var socket_material := _material("four_socket", Color("#16243a"), Color("#173c58"), 0.22, 0.30)
	for index in range(42):
		var socket := _cylinder_instance(tile * 0.31, 0.09, 28, socket_material)
		socket.name = "Socket_%02d" % index
		socket.position = _grid_position(index, 7, 6, float(_options.board_y))
		_board_layer.add_child(socket)

	var frame_material := _material("four_frame", Color("#122c43"), Color("#2bbbd2"), 0.42, 0.26)
	for column in range(8):
		var rail := _box_instance(Vector3(0.055, 0.15, board_depth), frame_material)
		rail.position = origin + Vector3((float(column) - 3.5) * tile, 0.10, 0.0)
		_board_layer.add_child(rail)
	for column in range(7):
		var target_position := origin + Vector3((float(column) - 3.0) * tile, 0.34, 0.0)
		var target := _create_target("column", column, target_position, Vector3(tile * 0.86, 0.52, tile * 6.0))
		target.name = "ColumnTarget_%d" % column
		target.set_meta("column", column)
		target.set_meta("action", {"type": "drop", "column": column})


func _build_draughts_board() -> void:
	var tile := float(_options.tile_size)
	var origin: Vector3 = _options.origin
	var base := _box_instance(Vector3(tile * 8.0 + 0.50, 0.22, tile * 8.0 + 0.50), _material("board_base", Color("#08111f"), Color("#102f49"), 0.22, 0.42))
	base.name = "DraughtsBase"
	base.position = origin + Vector3(0.0, -0.08, 0.0)
	_board_layer.add_child(base)
	var light := _material("draughts_light", _options.light_color, Color.TRANSPARENT, 0.04, 0.58)
	var dark := _material("draughts_dark", _options.dark_color, Color("#182d47"), 0.12, 0.48)
	for index in range(64):
		var row := index / 8
		var column := index % 8
		var position := _grid_position(index, 8, 8, float(_options.board_y))
		var target := _create_target("square", index, position, Vector3(tile * 0.97, 0.20, tile * 0.97))
		target.name = "Square_%02d" % index
		target.set_meta("square", index)
		target.set_meta("coord", Vector2i(column, row))
		target.set_meta("playable", (row + column) % 2 == 1)
		var surface := _box_instance(Vector3(tile * 0.94, 0.10, tile * 0.94), light if (row + column) % 2 == 0 else dark)
		surface.name = "Surface"
		target.add_child(surface)


func _build_property_board() -> void:
	var tile := float(_options.tile_size) * 1.18
	var origin: Vector3 = _options.origin
	var base := _box_instance(Vector3(tile * 5.0 + 0.48, 0.20, tile * 5.0 + 0.48), _material("property_base", Color("#091321"), Color("#122b43"), 0.26, 0.42))
	base.name = "PropertyGridBase"
	base.position = origin + Vector3(0.0, -0.08, 0.0)
	_board_layer.add_child(base)

	for index in range(16):
		var position := _property_position(index, float(_options.board_y))
		var target := _create_target("space", index, position, Vector3(tile * 0.92, 0.22, tile * 0.92))
		target.name = "Space_%02d" % index
		target.set_meta("space", index)
		var surface := _box_instance(Vector3(tile * 0.88, 0.12, tile * 0.88), _property_kind_material("rest"))
		surface.name = "Surface"
		target.add_child(surface)
		var inset := _cylinder_instance(tile * 0.19, 0.04, 20, _material("property_inset", Color("#17273b"), Color("#27516d"), 0.18, 0.34))
		inset.name = "KindInset"
		inset.position.y = 0.09
		target.add_child(inset)
		var accent := _box_instance(Vector3(tile * 0.70, 0.045, tile * 0.10), _material("owner_neutral", Color("#4b5b72"), Color.TRANSPARENT, 0.14, 0.40))
		accent.name = "OwnershipAccent"
		accent.position = Vector3(0.0, 0.11, -tile * 0.31)
		accent.visible = false
		target.add_child(accent)
		_space_nodes[index] = target
		_ownership_accents[index] = accent

	var action_colors := [Color("#42cae2"), Color("#73df91"), Color("#f0b94d"), Color("#8b6cf4")]
	for action_index in range(PROPERTY_ACTIONS.size()):
		var action_type: String = PROPERTY_ACTIONS[action_index]
		var action_position := origin + Vector3((float(action_index) - 1.5) * tile * 0.70, 0.12, 0.0)
		var action_target := _create_target("action", action_index, action_position, Vector3(tile * 0.58, 0.22, tile * 0.48))
		action_target.name = "Action_%s" % action_type.capitalize().replace(" ", "")
		action_target.set_meta("action_type", action_type)
		action_target.set_meta("action", {"type": action_type})
		var action_surface := _box_instance(Vector3(tile * 0.54, 0.10, tile * 0.44), _material("property_action_%d" % action_index, action_colors[action_index].darkened(0.42), action_colors[action_index], 0.26, 0.30))
		action_surface.name = "Surface"
		action_target.add_child(action_surface)


func _reconcile_four_line(state: Dictionary) -> void:
	_reconcile_slot_codes(state.board, "four_token")
	var players: Array = state.players
	for slot_variant in _piece_by_slot:
		var slot := int(slot_variant)
		var token: Node3D = _piece_by_slot[slot_variant]
		var actor := str(state.board[slot])
		var player_index := players.find(actor)
		if player_index < 0:
			player_index = 0
		_update_four_token(token, actor, player_index, slot)


func _reconcile_draughts(state: Dictionary) -> void:
	_reconcile_slot_codes(state.board, "draughts_piece")
	for slot_variant in _piece_by_slot:
		var slot := int(slot_variant)
		var piece: Node3D = _piece_by_slot[slot_variant]
		_update_draughts_piece(piece, str(state.board[slot]), slot)


func _reconcile_property_grid(state: Dictionary) -> void:
	var player_index_by_id := {}
	for index in range(state.players.size()):
		player_index_by_id[str(state.players[index].id)] = index

	for index in range(16):
		var space: Dictionary = state.board[index]
		var target: Area3D = _space_nodes[index]
		var kind := str(space.kind)
		var surface := target.get_node_or_null("Surface") as MeshInstance3D
		if surface != null:
			surface.material_override = _property_kind_material(kind)
		target.set_meta("space_name", str(space.get("name", "Space %d" % index)))
		target.set_meta("space_kind", kind)
		target.set_meta("space_data", _property_space_metadata(space))
		var owner_id := str(state.properties.get(str(index), ""))
		target.set_meta("owner_id", owner_id)
		var accent: MeshInstance3D = _ownership_accents[index]
		accent.visible = not owner_id.is_empty()
		if not owner_id.is_empty():
			accent.material_override = _player_material(int(player_index_by_id.get(owner_id, 0)))

	for action_index in range(PROPERTY_ACTIONS.size()):
		var action_target := target_for("action", action_index)
		if action_target != null:
			action_target.set_meta("phase", str(state.get("phase", "")))
			action_target.set_meta("active_player_index", int(state.get("turn_index", 0)))
			action_target.set_meta("active_actor", str(state.players[int(state.turn_index)].id))

	var desired_ids := {}
	var occupant_counts := {}
	_piece_by_slot.clear()
	for player_index in range(state.players.size()):
		var player: Dictionary = state.players[player_index]
		var player_id := str(player.id)
		desired_ids[player_id] = true
		# Keep the dictionary identity lossless. Sanitization is only appropriate
		# for the display node name because distinct peer IDs may share a slug.
		var pawn_id := "property_player:%s" % player_id
		var pawn: Area3D = _piece_by_id.get(pawn_id)
		if pawn == null:
			pawn = _create_property_pawn(pawn_id, player_index)
			_note_created()
		else:
			_note_reused()
		var position_index := int(player.position)
		var occupancy := int(occupant_counts.get(position_index, 0))
		occupant_counts[position_index] = occupancy + 1
		_unregister_target(pawn)
		_register_target(pawn, "player", player_index)
		pawn.set_meta("player_id", player_id)
		pawn.set_meta("player_index", player_index)
		pawn.set_meta("space", position_index)
		pawn.set_meta("balance", int(player.get("balance", 0)))
		pawn.set_meta("bankrupt", bool(player.get("bankrupt", false)))
		pawn.position = _property_position(position_index, float(_options.piece_y)) + _pawn_offset(occupancy)
		pawn.scale = Vector3.ONE * (0.78 if bool(player.get("bankrupt", false)) else 1.0)
		_piece_by_slot[player_index] = pawn

	for piece_id_variant in _piece_by_id.keys().duplicate():
		var piece_id := str(piece_id_variant)
		if not piece_id.begins_with("property_player:"):
			continue
		var pawn: Node3D = _piece_by_id[piece_id_variant]
		var player_id := str(pawn.get_meta("player_id", ""))
		if not desired_ids.has(player_id):
			_remove_piece(pawn)


func _reconcile_slot_codes(board: Array, family: String) -> void:
	var assigned_ids := {}
	var assigned_slots := {}
	for slot in range(board.size()):
		var code := str(board[slot])
		if code.is_empty():
			continue
		var exact: Node3D = _piece_by_slot.get(slot)
		if exact != null and str(exact.get_meta("piece_code", "")) == code:
			var exact_id := str(exact.get_meta("piece_id", ""))
			assigned_ids[exact_id] = true
			assigned_slots[slot] = exact
			_note_reused()

	var reusable: Array[Node3D] = []
	for piece_variant in _piece_by_id.values():
		var piece: Node3D = piece_variant
		if str(piece.get_meta("piece_family", "")) != family:
			continue
		if not assigned_ids.has(str(piece.get_meta("piece_id", ""))):
			reusable.append(piece)
	reusable.sort_custom(func(left: Node3D, right: Node3D) -> bool:
		return str(left.get_meta("piece_id", "")) < str(right.get_meta("piece_id", ""))
	)

	for slot in range(board.size()):
		var code := str(board[slot])
		if code.is_empty() or assigned_slots.has(slot):
			continue
		var selected: Node3D
		for candidate in reusable:
			if str(candidate.get_meta("piece_code", "")) == code:
				selected = candidate
				break
		if selected == null and family == "draughts_piece":
			for candidate in reusable:
				if str(candidate.get_meta("piece_code", "")).to_lower() == code.to_lower():
					selected = candidate
					break
		if selected != null:
			reusable.erase(selected)
			assigned_ids[str(selected.get_meta("piece_id", ""))] = true
			assigned_slots[slot] = selected
			_note_reused()
		else:
			var spawned := _create_slot_piece(family, code, slot)
			assigned_ids[str(spawned.get_meta("piece_id", ""))] = true
			assigned_slots[slot] = spawned
			_note_created()

	for piece_variant in _piece_by_id.values().duplicate():
		var piece: Node3D = piece_variant
		if str(piece.get_meta("piece_family", "")) == family and not assigned_ids.has(str(piece.get_meta("piece_id", ""))):
			_remove_piece(piece)

	_piece_by_slot.clear()
	for slot_variant in assigned_slots:
		var slot := int(slot_variant)
		var piece: Node3D = assigned_slots[slot_variant]
		_set_slot_piece(piece, family, str(board[slot]), slot)
		_piece_by_slot[slot] = piece


func _create_slot_piece(family: String, code: String, slot: int) -> Area3D:
	_serial += 1
	var piece := Area3D.new()
	piece.name = "%s_%03d" % [family.capitalize().replace(" ", ""), _serial]
	piece.input_ray_pickable = true
	piece.set_meta("tabletop_presenter_owned", true)
	var piece_id := "%s:%03d" % [family, _serial]
	piece.set_meta("piece_id", piece_id)
	piece.set_meta("piece_family", family)
	_piece_layer.add_child(piece)
	_piece_by_id[piece_id] = piece
	if family == "four_token":
		_build_four_token_visual(piece, 0)
	else:
		_build_draughts_visual(piece, code)
	return piece


func _set_slot_piece(piece: Node3D, family: String, code: String, slot: int) -> void:
	_unregister_target(piece)
	piece.set_meta("piece_code", code)
	piece.set_meta("slot", slot)
	if family == "four_token":
		piece.position = _grid_position(slot, 7, 6, float(_options.piece_y))
		_register_target(piece as Area3D, "token", slot)
	else:
		piece.position = _grid_position(slot, 8, 8, float(_options.piece_y))
		_register_target(piece as Area3D, "piece", slot)


func _build_four_token_visual(piece: Area3D, player_index: int) -> void:
	_clear_piece_visuals(piece)
	var tile := float(_options.tile_size)
	var material := _player_material(player_index)
	var disc := _cylinder_instance(tile * 0.285, 0.15, 28, material)
	disc.name = "Disc"
	disc.set_meta("tabletop_piece_visual", true)
	piece.add_child(disc)
	var sigil := _torus_instance(tile * 0.185, tile * 0.025, material)
	sigil.name = "Sigil"
	sigil.position.y = 0.085
	sigil.set_meta("tabletop_piece_visual", true)
	piece.add_child(sigil)
	_add_cylinder_collision(piece, tile * 0.30, 0.22, 0.04)


func _update_four_token(piece: Node3D, actor: String, player_index: int, slot: int) -> void:
	var previous_index := int(piece.get_meta("player_index", -1))
	if previous_index != player_index or piece.get_node_or_null("Disc") == null:
		_build_four_token_visual(piece as Area3D, player_index)
	piece.set_meta("actor", actor)
	piece.set_meta("player_index", player_index)
	piece.set_meta("row", slot / 7)
	piece.set_meta("column", slot % 7)


func _build_draughts_visual(piece: Area3D, code: String) -> void:
	_clear_piece_visuals(piece)
	var tile := float(_options.tile_size)
	var color_key := "draughts_red" if code.to_lower() == "r" else "draughts_black"
	var color: Color = _options.red if code.to_lower() == "r" else _options.black
	var emission := Color("#ff6a79") if code.to_lower() == "r" else Color("#7659e8")
	var material := _material(color_key, color, emission, 0.36, 0.28)
	var base := _cylinder_instance(tile * 0.31, 0.13, 30, material)
	base.name = "Disc"
	base.set_meta("tabletop_piece_visual", true)
	piece.add_child(base)
	var inset := _torus_instance(tile * 0.20, tile * 0.024, material)
	inset.name = "InsetRing"
	inset.position.y = 0.075
	inset.set_meta("tabletop_piece_visual", true)
	piece.add_child(inset)
	if code == code.to_upper() and not code.is_empty():
		var crown := _cylinder_instance(tile * 0.23, 0.10, 24, material)
		crown.name = "KingCrown"
		crown.position.y = 0.115
		crown.set_meta("tabletop_piece_visual", true)
		piece.add_child(crown)
		var crown_ring := _torus_instance(tile * 0.135, tile * 0.025, _material("king_sigil", Color("#f7e69a"), Color("#ffe47b"), 0.20, 0.24))
		crown_ring.name = "KingSigil"
		crown_ring.position.y = 0.175
		crown_ring.set_meta("tabletop_piece_visual", true)
		piece.add_child(crown_ring)
	_add_cylinder_collision(piece, tile * 0.32, 0.34 if code == code.to_upper() else 0.22, 0.07)


func _update_draughts_piece(piece: Node3D, code: String, slot: int) -> void:
	var previous_code := str(piece.get_meta("visual_code", ""))
	if previous_code != code or piece.get_node_or_null("Disc") == null:
		_build_draughts_visual(piece as Area3D, code)
	piece.set_meta("visual_code", code)
	piece.set_meta("color", "red" if code.to_lower() == "r" else "black")
	piece.set_meta("is_king", code == code.to_upper())
	piece.set_meta("row", slot / 8)
	piece.set_meta("column", slot % 8)


func _create_property_pawn(piece_id: String, player_index: int) -> Area3D:
	var pawn := Area3D.new()
	pawn.name = "Player_%s" % _safe_fragment(piece_id)
	pawn.input_ray_pickable = true
	pawn.set_meta("tabletop_presenter_owned", true)
	pawn.set_meta("piece_id", piece_id)
	pawn.set_meta("piece_family", "property_player")
	_piece_layer.add_child(pawn)
	_piece_by_id[piece_id] = pawn
	var material := _player_material(player_index)
	var base := _cylinder_instance(0.20, 0.10, 20, material)
	base.name = "Base"
	base.set_meta("tabletop_piece_visual", true)
	pawn.add_child(base)
	var stem := _cylinder_instance(0.095, 0.28, 16, material, 0.15)
	stem.name = "Stem"
	stem.position.y = 0.18
	stem.set_meta("tabletop_piece_visual", true)
	pawn.add_child(stem)
	var beacon := _sphere_instance(0.13, material)
	beacon.name = "Beacon"
	beacon.position.y = 0.39
	beacon.set_meta("tabletop_piece_visual", true)
	pawn.add_child(beacon)
	_add_cylinder_collision(pawn, 0.22, 0.58, 0.20)
	return pawn


func _create_target(kind: String, index: int, position: Vector3, collision_size: Vector3) -> Area3D:
	var target := Area3D.new()
	target.input_ray_pickable = true
	target.position = position
	target.set_meta("tabletop_presenter_owned", true)
	target.set_meta("module_id", _module_id)
	var collision := CollisionShape3D.new()
	collision.name = "HitShape"
	var shape := BoxShape3D.new()
	shape.size = collision_size
	collision.shape = shape
	target.add_child(collision)
	_board_layer.add_child(target)
	_register_target(target, kind, index)
	return target


func _register_target(target: Area3D, kind: String, index: int) -> void:
	target.set_meta("target_kind", kind)
	target.set_meta("target_index", index)
	_targets[_target_key(kind, index)] = target
	var callable := _on_target_input.bind(target)
	if not target.input_event.is_connected(callable):
		target.input_event.connect(callable)


func _unregister_target(target: Node3D) -> void:
	if target == null or not target.has_meta("target_kind"):
		return
	var key := _target_key(str(target.get_meta("target_kind", "")), int(target.get_meta("target_index", -1)))
	if _targets.get(key) == target:
		_targets.erase(key)


func _on_target_input(_camera: Node, event: InputEvent, _event_position: Vector3, _normal: Vector3, _shape_index: int, target: Area3D) -> void:
	if not (event is InputEventMouseButton):
		return
	var mouse_event := event as InputEventMouseButton
	if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
		return
	if target == null or not is_instance_valid(target):
		return
	target_clicked.emit(str(target.get_meta("target_kind", "unknown")), int(target.get_meta("target_index", -1)), target.global_position)


func _validate_state(state: Dictionary) -> Dictionary:
	if _normalize_module_id(str(state.get("module_id", ""))) != _module_id:
		return _invalid("state_module", "Reducer state does not match the configured presentation module.")
	match _module_id:
		"four_line":
			return _validate_four_line_state(state)
		"draughts":
			return _validate_draughts_state(state)
		"property_grid":
			return _validate_property_state(state)
	return _invalid("unsupported_module", "The configured presentation module is unsupported.")


func _validate_four_line_state(state: Dictionary) -> Dictionary:
	if not state.get("board", null) is Array or state.board.size() != 42:
		return _invalid("state_board_size", "Four Line state must contain exactly 42 cells.")
	if not state.get("players", null) is Array or state.players.size() != 2:
		return _invalid("state_players", "Four Line state must contain exactly two players.")
	var players: Array = state.players
	for player_variant in players:
		if not _valid_identifier(str(player_variant)):
			return _invalid("player_id", "Four Line contains an invalid player identifier.")
	if str(players[0]) == str(players[1]):
		return _invalid("player_id", "Four Line player identifiers must be distinct.")
	for actor_variant in state.board:
		var actor := str(actor_variant)
		if not actor.is_empty() and actor not in players:
			return _invalid("piece_code", "Four Line contains a token for an unknown player.")
	return {"ok": true, "code": "valid_state"}


func _validate_draughts_state(state: Dictionary) -> Dictionary:
	if not state.get("board", null) is Array or state.board.size() != 64:
		return _invalid("state_board_size", "Draughts state must contain exactly 64 squares.")
	for code_variant in state.board:
		if str(code_variant) not in DRAUGHTS_CODES:
			return _invalid("piece_code", "Draughts contains an unsupported piece code.")
	return {"ok": true, "code": "valid_state"}


func _validate_property_state(state: Dictionary) -> Dictionary:
	if not state.get("board", null) is Array or state.board.size() != 16:
		return _invalid("state_board_size", "Property Grid state must contain exactly 16 spaces.")
	if not state.get("players", null) is Array or state.players.size() < 2 or state.players.size() > 6:
		return _invalid("state_players", "Property Grid supports two through six players.")
	var player_ids: Array[String] = []
	for player_variant in state.players:
		if not player_variant is Dictionary:
			return _invalid("state_player", "Property Grid player records must be dictionaries.")
		var player: Dictionary = player_variant
		var player_id := str(player.get("id", ""))
		if not _valid_identifier(player_id) or player_id in player_ids:
			return _invalid("player_id", "Property Grid contains an invalid or duplicate player identifier.")
		var position_variant: Variant = player.get("position", null)
		if not position_variant is int or int(position_variant) < 0 or int(position_variant) >= 16:
			return _invalid("player_position", "Property Grid contains an out-of-range player position.")
		player_ids.append(player_id)
	for space_variant in state.board:
		if not space_variant is Dictionary:
			return _invalid("state_space", "Property Grid spaces must be dictionaries.")
		var space: Dictionary = space_variant
		if str(space.get("kind", "")) not in PROPERTY_KINDS:
			return _invalid("space_kind", "Property Grid contains an unsupported space kind.")
		if str(space.get("name", "")).length() > MAX_LABEL_LENGTH:
			return _invalid("space_name", "Property Grid contains an oversized space label.")
	if not state.get("properties", null) is Dictionary:
		return _invalid("state_properties", "Property Grid ownership must be a dictionary.")
	for property_key_variant in state.properties:
		var key := str(property_key_variant)
		if not key.is_valid_int():
			return _invalid("property_index", "Property Grid contains a malformed ownership index.")
		var property_index := int(key)
		if property_index < 0 or property_index >= 16:
			return _invalid("property_index", "Property Grid contains an out-of-range ownership index.")
		if str(state.properties[property_key_variant]) not in player_ids:
			return _invalid("property_owner", "Property Grid contains an unknown property owner.")
	var turn_variant: Variant = state.get("turn_index", null)
	if not turn_variant is int or int(turn_variant) < 0 or int(turn_variant) >= state.players.size():
		return _invalid("turn_index", "Property Grid contains an invalid active player index.")
	return {"ok": true, "code": "valid_state"}


func _validated_options(options: Dictionary) -> Dictionary:
	var result := _options.duplicate(true)
	for key_variant in options:
		var key := str(key_variant)
		if key not in result:
			continue
		var value: Variant = options[key_variant]
		match key:
			"tile_size", "board_y", "piece_y":
				if not (value is float or value is int) or not is_finite(float(value)):
					return _invalid("option_number", "Presentation numeric options must be finite.")
				if key == "tile_size" and (float(value) < 0.25 or float(value) > 4.0):
					return _invalid("option_tile_size", "Tile size must be between 0.25 and 4.0.")
				result[key] = float(value)
			"origin":
				if not value is Vector3 or not _finite_vector(value):
					return _invalid("option_origin", "Presentation origin must be a finite Vector3.")
				result[key] = value
			_:
				if not value is Color:
					return _invalid("option_color", "Presentation color options must be Color values.")
				result[key] = value
	return {"ok": true, "code": "valid_options", "value": result}


func _grid_position(index: int, width: int, height: int, y: float) -> Vector3:
	var tile := float(_options.tile_size)
	var origin: Vector3 = _options.origin
	var column := index % width
	var row := index / width
	return origin + Vector3((float(column) - (float(width) - 1.0) * 0.5) * tile, y, (float(row) - (float(height) - 1.0) * 0.5) * tile)


func _property_position(index: int, y: float) -> Vector3:
	var coords := [
		Vector2i(-2, -2), Vector2i(-1, -2), Vector2i(0, -2), Vector2i(1, -2), Vector2i(2, -2),
		Vector2i(2, -1), Vector2i(2, 0), Vector2i(2, 1), Vector2i(2, 2),
		Vector2i(1, 2), Vector2i(0, 2), Vector2i(-1, 2), Vector2i(-2, 2),
		Vector2i(-2, 1), Vector2i(-2, 0), Vector2i(-2, -1),
	]
	var coord: Vector2i = coords[clampi(index, 0, 15)]
	var step := float(_options.tile_size) * 1.18
	var origin: Vector3 = _options.origin
	return origin + Vector3(float(coord.x) * step, y, float(coord.y) * step)


func _pawn_offset(occupancy: int) -> Vector3:
	var offsets := [
		Vector2(-0.17, -0.17), Vector2(0.17, -0.17), Vector2(-0.17, 0.17),
		Vector2(0.17, 0.17), Vector2(0.0, -0.23), Vector2(0.0, 0.23),
	]
	var offset: Vector2 = offsets[clampi(occupancy, 0, offsets.size() - 1)]
	return Vector3(offset.x, 0.0, offset.y)


func _property_space_metadata(space: Dictionary) -> Dictionary:
	var result := {
		"name": str(space.get("name", "")),
		"kind": str(space.get("kind", "")),
	}
	for numeric_key in ["price", "rent", "amount"]:
		if space.has(numeric_key):
			result[numeric_key] = int(space[numeric_key])
	return result


func _property_kind_material(kind: String) -> StandardMaterial3D:
	match kind:
		"start":
			return _material("space_start", Color("#16546a"), Color("#4bdff2"), 0.22, 0.34)
		"property":
			return _material("space_property", Color("#29375a"), Color("#7c67dd"), 0.20, 0.38)
		"tax":
			return _material("space_tax", Color("#653342"), Color("#ff6b82"), 0.18, 0.42)
		"grant":
			return _material("space_grant", Color("#28543f"), Color("#77e58f"), 0.16, 0.40)
		_:
			return _material("space_rest", Color("#283548"), Color("#48627d"), 0.12, 0.52)


func _player_material(index: int) -> StandardMaterial3D:
	var safe_index := posmod(index, PLAYER_COLORS.size())
	var color: Color = PLAYER_COLORS[safe_index]
	return _material("player_%d" % safe_index, color.darkened(0.18), color, 0.38, 0.24)


func _material(key: String, color: Color, emission: Color = Color.TRANSPARENT, metallic: float = 0.15, roughness: float = 0.42) -> StandardMaterial3D:
	if _materials.has(key):
		return _materials[key]
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = roughness
	if emission != Color.TRANSPARENT:
		material.emission_enabled = true
		material.emission = emission
		material.emission_energy_multiplier = 0.32
	_materials[key] = material
	return material


func _box_instance(size: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	return instance


func _cylinder_instance(radius: float, height: float, sides: int, material: Material, top_radius: float = -1.0) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.bottom_radius = radius
	mesh.top_radius = radius if top_radius < 0.0 else top_radius
	mesh.height = height
	mesh.radial_segments = sides
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	return instance


func _sphere_instance(radius: float, material: Material) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 18
	mesh.rings = 10
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	return instance


func _torus_instance(radius: float, tube: float, material: Material) -> MeshInstance3D:
	var mesh := TorusMesh.new()
	mesh.inner_radius = maxf(0.01, radius - tube)
	mesh.outer_radius = radius + tube
	mesh.rings = 24
	mesh.ring_segments = 10
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	return instance


func _add_cylinder_collision(parent: Area3D, radius: float, height: float, y: float) -> void:
	var collision := CollisionShape3D.new()
	collision.name = "HitShape"
	collision.set_meta("tabletop_piece_visual", true)
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	collision.shape = shape
	collision.position.y = y
	parent.add_child(collision)


func _clear_piece_visuals(piece: Node3D) -> void:
	for child in piece.get_children():
		if bool(child.get_meta("tabletop_piece_visual", false)):
			piece.remove_child(child)
			child.queue_free()


func _remove_piece(piece: Node3D) -> void:
	if piece == null or not is_instance_valid(piece):
		return
	_unregister_target(piece)
	var piece_id := str(piece.get_meta("piece_id", ""))
	var slot := int(piece.get_meta("slot", -1))
	_piece_by_id.erase(piece_id)
	if _piece_by_slot.get(slot) == piece:
		_piece_by_slot.erase(slot)
	if piece.get_parent() != null:
		piece.get_parent().remove_child(piece)
	piece.queue_free()
	_note_removed()


func _dispose_layers() -> void:
	for layer in [_board_layer, _piece_layer]:
		if layer != null and is_instance_valid(layer):
			if layer.get_parent() != null:
				layer.get_parent().remove_child(layer)
			layer.queue_free()
	_board_layer = null
	_piece_layer = null


func _note_created() -> void:
	_stats.created = int(_stats.created) + 1
	_stats.last_created = int(_stats.last_created) + 1


func _note_reused() -> void:
	_stats.reused = int(_stats.reused) + 1
	_stats.last_reused = int(_stats.last_reused) + 1


func _note_removed() -> void:
	_stats.removed = int(_stats.removed) + 1
	_stats.last_removed = int(_stats.last_removed) + 1


func _normalize_module_id(value: String) -> String:
	var normalized := value.strip_edges().to_lower().replace("-", "_")
	return str(MODULE_ALIASES.get(normalized, normalized))


func _target_key(kind: String, index: int) -> String:
	return "%s:%d" % [kind, index]


func _safe_fragment(value: String) -> String:
	var result := ""
	for character in value:
		if character.to_lower() in "abcdefghijklmnopqrstuvwxyz0123456789_":
			result += character
		else:
			result += "_"
	return result.left(64)


func _valid_identifier(value: String) -> bool:
	return not value.strip_edges().is_empty() and value.length() <= MAX_ID_LENGTH


func _finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


func _remember_invalid(code: String, message: String) -> Dictionary:
	_stats.last_code = code
	_stats.last_message = message
	return _invalid(code, message)


func _invalid(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
