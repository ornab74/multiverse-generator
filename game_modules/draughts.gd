extends "res://game_modules/deterministic_game_module.gd"

const BOARD_SIZE := 8


func manifest() -> Dictionary:
	return {
		"id": "draughts",
		"title": "Draughts",
		"version": "1.0.0",
		"players": {"min": 2, "max": 2, "roles": ["red", "black"]},
		"deterministic": true,
		"board": {"kind": "dark_square_grid", "width": 8, "height": 8},
		"actions": {
			"move": {"required": ["actor", "path"], "path_minimum": 2},
		},
		"rules": {
			"variant": "forward-men-v1",
			"mandatory_capture": true,
			"complete_capture_chain": true,
			"crowning_ends_turn": true,
		},
		"rendering": {
			"asset_policy": "procedural_native",
			"piece_codes": ["r", "R", "b", "B"],
		},
	}


func _initial_state(config: Dictionary) -> Dictionary:
	var configured_players: Dictionary = config.get("players", {})
	var red_player := str(configured_players.get("red", "red"))
	var black_player := str(configured_players.get("black", "black"))
	if red_player == black_player:
		red_player = "red"
		black_player = "black"
	var board: Array = []
	board.resize(64)
	board.fill("")
	for row in range(3):
		for column in range(8):
			if (row + column) % 2 == 1:
				board[row * 8 + column] = "b"
	for row in range(5, 8):
		for column in range(8):
			if (row + column) % 2 == 1:
				board[row * 8 + column] = "r"
	return {
		"module_id": "draughts",
		"revision": 0,
		"players": {"red": red_player, "black": black_player},
		"turn": "red",
		"board": board,
		"status": "active",
		"winner": "",
		"winner_player": "",
		"result": "",
		"move_count": 0,
		"capture_count": 0,
	}


func validate_action(state: Dictionary, action: Dictionary) -> Dictionary:
	if str(state.get("status", "")) != "active":
		return _invalid("game_complete", "No moves are accepted after the game completes.")
	if str(action.get("type", "")) != "move":
		return _invalid("action_type", "Draughts accepts only move actions.")
	if not action.has("actor"):
		return _invalid("actor_required", "A signed actor id is required.")
	var color := str(state.turn)
	if str(action.actor) != str(state.players[color]):
		return _invalid("out_of_turn", "Only the active side can move.")
	if not action.get("path", null) is Array:
		return _invalid("path_type", "Move path must be an array of board indices.")
	return _simulate_path(state.board, action.path, color)


func _reduce_validated(state: Dictionary, action: Dictionary) -> Dictionary:
	var color := str(state.turn)
	var opponent := _opponent(color)
	var simulation := _simulate_path(state.board, action.path, color)
	state.board = simulation.board
	state.move_count = int(state.move_count) + 1
	state.capture_count = int(state.capture_count) + int(simulation.captures)
	state.turn = opponent
	if not _side_has_piece(state.board, opponent) or not _has_legal_turn(state.board, opponent):
		state.status = "won"
		state.winner = color
		state.winner_player = str(state.players[color])
		state.result = "no_pieces" if not _side_has_piece(state.board, opponent) else "no_legal_moves"
	return state


func _simulate_path(board: Array, path: Array, color: String) -> Dictionary:
	if path.size() < 2:
		return _invalid("path_length", "A move path needs at least two squares.")
	for square in path:
		if not square is int or int(square) < 0 or int(square) >= 64:
			return _invalid("square_range", "Move path contains an invalid square.")

	var next: Array = board.duplicate()
	var source := int(path[0])
	var piece := str(next[source])
	if piece == "" or _piece_color(piece) != color:
		return _invalid("source_piece", "Path does not begin on an active-side piece.")
	var capture_required := not _all_captures(next, color).is_empty()
	var captures := 0
	var crowned_during_path := false

	for step_index in range(1, path.size()):
		var destination := int(path[step_index])
		if str(next[destination]) != "":
			return _invalid("occupied_target", "Every destination square must be empty.")
		var source_row := source / 8
		var source_column := source % 8
		var destination_row := destination / 8
		var destination_column := destination % 8
		var row_delta := destination_row - source_row
		var column_delta := destination_column - source_column
		var is_king := piece == piece.to_upper()
		var forward := -1 if color == "red" else 1

		if absi(row_delta) == 1 and absi(column_delta) == 1:
			if capture_required or path.size() != 2 or captures > 0:
				return _invalid("capture_required", "A capture is mandatory and must be completed.")
			if not is_king and row_delta != forward:
				return _invalid("piece_movement", "An uncrowned piece moves forward only.")
		elif absi(row_delta) == 2 and absi(column_delta) == 2:
			if not is_king and row_delta != forward * 2:
				return _invalid("piece_movement", "An uncrowned piece captures forward only.")
			var jumped_row := (source_row + destination_row) / 2
			var jumped_column := (source_column + destination_column) / 2
			var jumped_index := jumped_row * 8 + jumped_column
			var jumped_piece := str(next[jumped_index])
			if jumped_piece == "" or _piece_color(jumped_piece) == color:
				return _invalid("capture_target", "Capture step must jump an opposing piece.")
			next[jumped_index] = ""
			captures += 1
		else:
			return _invalid("piece_movement", "Pieces move one diagonal or capture across one piece.")

		next[source] = ""
		next[destination] = piece
		source = destination
		var crown_row := 0 if color == "red" else 7
		if not is_king and destination_row == crown_row:
			crowned_during_path = true
			if step_index < path.size() - 1:
				return _invalid("crown_ends_turn", "Crowning ends the capture turn in this variant.")

	if capture_required and captures == 0:
		return _invalid("capture_required", "An available capture must be taken.")
	if captures > 0 and not crowned_during_path and not _captures_from(next, source, color).is_empty():
		return _invalid("capture_chain", "The action must include the complete capture chain.")
	if crowned_during_path:
		next[source] = _piece_prefix(color).to_upper()
	return _valid({"board": next, "captures": captures, "destination": source})


func _all_captures(board: Array, color: String) -> Array:
	var captures: Array = []
	for source in range(64):
		var piece := str(board[source])
		if piece != "" and _piece_color(piece) == color:
			for destination in _captures_from(board, source, color):
				captures.append([source, destination])
	return captures


func _captures_from(board: Array, source: int, color: String) -> Array:
	var piece := str(board[source])
	if piece == "" or _piece_color(piece) != color:
		return []
	var directions := [-1, 1] if piece == piece.to_upper() else [-1 if color == "red" else 1]
	var source_row := source / 8
	var source_column := source % 8
	var result: Array = []
	for row_direction in directions:
		for column_direction in [-1, 1]:
			var middle_row: int = source_row + int(row_direction)
			var middle_column: int = source_column + int(column_direction)
			var destination_row: int = source_row + int(row_direction) * 2
			var destination_column: int = source_column + int(column_direction) * 2
			if not _inside(destination_row, destination_column):
				continue
			var middle_piece := str(board[middle_row * 8 + middle_column])
			var destination: int = destination_row * 8 + destination_column
			if middle_piece != "" and _piece_color(middle_piece) != color and str(board[destination]) == "":
				result.append(destination)
	return result


func _has_legal_turn(board: Array, color: String) -> bool:
	if not _all_captures(board, color).is_empty():
		return true
	for source in range(64):
		var piece := str(board[source])
		if piece == "" or _piece_color(piece) != color:
			continue
		var directions := [-1, 1] if piece == piece.to_upper() else [-1 if color == "red" else 1]
		var row := source / 8
		var column := source % 8
		for row_direction in directions:
			for column_direction in [-1, 1]:
				var target_row: int = row + int(row_direction)
				var target_column: int = column + int(column_direction)
				if _inside(target_row, target_column) and str(board[target_row * 8 + target_column]) == "":
					return true
	return false


func _side_has_piece(board: Array, color: String) -> bool:
	for piece_variant in board:
		var piece := str(piece_variant)
		if piece != "" and _piece_color(piece) == color:
			return true
	return false


func _piece_color(piece: String) -> String:
	return "red" if piece.to_lower() == "r" else "black"


func _piece_prefix(color: String) -> String:
	return "r" if color == "red" else "b"


func _opponent(color: String) -> String:
	return "black" if color == "red" else "red"


func _inside(row: int, column: int) -> bool:
	return row >= 0 and row < BOARD_SIZE and column >= 0 and column < BOARD_SIZE
