extends "res://game_modules/deterministic_game_module.gd"

const BOARD_SIZE := 8
const PROMOTIONS := ["Q", "R", "B", "N"]


func manifest() -> Dictionary:
	return {
		"id": "chess_core",
		"title": "Chess Core",
		"version": "1.0.0",
		"players": {"min": 2, "max": 2, "roles": ["white", "black"]},
		"deterministic": true,
		"board": {"kind": "square_grid", "width": 8, "height": 8},
		"actions": {
			"move": {
				"required": ["actor", "from", "to"],
				"optional": ["promotion", "expected_revision", "expected_state_hash"],
			},
		},
		"rules": {
			"included": ["check", "checkmate", "stalemate", "castling", "en_passant", "promotion"],
			"excluded": ["threefold_repetition", "fifty_move_claim", "insufficient_material"],
		},
		"rendering": {
			"asset_policy": "procedural_native",
			"piece_codes": ["K", "Q", "R", "B", "N", "P"],
		},
	}


func _initial_state(config: Dictionary) -> Dictionary:
	var configured_players: Dictionary = config.get("players", {})
	var white_player := str(configured_players.get("white", "white"))
	var black_player := str(configured_players.get("black", "black"))
	if white_player == black_player:
		white_player = "white"
		black_player = "black"
	var board := [
		"bR", "bN", "bB", "bQ", "bK", "bB", "bN", "bR",
		"bP", "bP", "bP", "bP", "bP", "bP", "bP", "bP",
		"", "", "", "", "", "", "", "",
		"", "", "", "", "", "", "", "",
		"", "", "", "", "", "", "", "",
		"", "", "", "", "", "", "", "",
		"wP", "wP", "wP", "wP", "wP", "wP", "wP", "wP",
		"wR", "wN", "wB", "wQ", "wK", "wB", "wN", "wR",
	]
	return {
		"module_id": "chess_core",
		"revision": 0,
		"players": {"white": white_player, "black": black_player},
		"turn": "white",
		"board": board,
		"castling": {
			"white_kingside": true,
			"white_queenside": true,
			"black_kingside": true,
			"black_queenside": true,
		},
		"en_passant": -1,
		"halfmove_clock": 0,
		"fullmove_number": 1,
		"status": "active",
		"winner": "",
		"winner_player": "",
		"result": "",
		"check": false,
	}


func validate_action(state: Dictionary, action: Dictionary) -> Dictionary:
	if str(state.get("status", "")) != "active":
		return _invalid("game_complete", "No moves are accepted after the game completes.")
	if str(action.get("type", "")) != "move":
		return _invalid("action_type", "Chess Core accepts only move actions.")
	if not action.has("actor"):
		return _invalid("actor_required", "A signed actor id is required.")
	var color := str(state.turn)
	if str(action.actor) != str(state.players[color]):
		return _invalid("out_of_turn", "Only the active side can move.")
	if not action.get("from", null) is int or not action.get("to", null) is int:
		return _invalid("square_type", "Move squares must be integer board indices.")
	var promotion := str(action.get("promotion", "")).to_upper()
	return _legal_move_details(state, int(action.from), int(action.to), promotion, color)


func _reduce_validated(state: Dictionary, action: Dictionary) -> Dictionary:
	var color := str(state.turn)
	var opponent := _opponent(color)
	var from_index := int(action.from)
	var to_index := int(action.to)
	var promotion := str(action.get("promotion", "")).to_upper()
	var details := _legal_move_details(state, from_index, to_index, promotion, color)
	var moving_piece := str(state.board[from_index])
	var captured_piece := str(state.board[to_index])

	state.board = _apply_board_move(state.board, from_index, to_index, details)
	state.en_passant = -1
	if moving_piece.substr(1, 1) == "P" and absi(to_index / 8 - from_index / 8) == 2:
		state.en_passant = (from_index + to_index) / 2

	_update_castling_rights(state.castling, moving_piece, from_index)
	if captured_piece != "":
		_update_castling_rights(state.castling, captured_piece, to_index)

	if moving_piece.substr(1, 1) == "P" or captured_piece != "" or int(details.get("en_passant_capture", -1)) >= 0:
		state.halfmove_clock = 0
	else:
		state.halfmove_clock = int(state.halfmove_clock) + 1
	if color == "black":
		state.fullmove_number = int(state.fullmove_number) + 1

	state.turn = opponent
	var opponent_king := _find_king(state.board, opponent)
	state.check = _is_square_attacked(state.board, opponent_king, color)
	if not _has_any_legal_move(state, opponent):
		if state.check:
			state.status = "won"
			state.winner = color
			state.winner_player = str(state.players[color])
			state.result = "checkmate"
		else:
			state.status = "draw"
			state.result = "stalemate"
	return state


func _legal_move_details(
	state: Dictionary,
	from_index: int,
	to_index: int,
	promotion: String,
	color: String
) -> Dictionary:
	if from_index < 0 or from_index >= 64 or to_index < 0 or to_index >= 64:
		return _invalid("square_range", "Move square is outside the board.")
	if from_index == to_index:
		return _invalid("same_square", "A piece must move to a different square.")
	var board: Array = state.board
	var piece := str(board[from_index])
	if piece == "" or _piece_color(piece) != color:
		return _invalid("source_piece", "Source square has no active-side piece.")
	var target := str(board[to_index])
	if target != "" and _piece_color(target) == color:
		return _invalid("friendly_target", "A piece cannot capture its own side.")
	if target.ends_with("K"):
		return _invalid("king_capture", "Kings are checked, never captured.")

	var from_row := from_index / 8
	var from_column := from_index % 8
	var to_row := to_index / 8
	var to_column := to_index % 8
	var row_delta := to_row - from_row
	var column_delta := to_column - from_column
	var kind := piece.substr(1, 1)
	if kind != "P" and promotion != "":
		return _invalid("promotion_piece", "Only a pawn reaching the last rank can promote.")
	var details := _valid({
		"en_passant_capture": -1,
		"castle_rook_from": -1,
		"castle_rook_to": -1,
		"promotion": "",
	})

	match kind:
		"P":
			var direction := -1 if color == "white" else 1
			var start_row := 6 if color == "white" else 1
			var promotion_row := 0 if color == "white" else 7
			if column_delta == 0 and row_delta == direction and target == "":
				pass
			elif column_delta == 0 and row_delta == direction * 2 and from_row == start_row and target == "":
				var between := (from_row + direction) * 8 + from_column
				if str(board[between]) != "":
					return _invalid("blocked", "Pawn double-step path is blocked.")
			elif absi(column_delta) == 1 and row_delta == direction:
				if target == "":
					if to_index != int(state.get("en_passant", -1)):
						return _invalid("pawn_capture", "Pawn diagonal moves require a capture.")
					var capture_index := from_row * 8 + to_column
					if str(board[capture_index]) != _color_prefix(_opponent(color)) + "P":
						return _invalid("en_passant", "No capturable pawn is present.")
					details.en_passant_capture = capture_index
			else:
				return _invalid("piece_movement", "Pawn cannot move that way.")
			if to_row == promotion_row:
				var chosen := "Q" if promotion == "" else promotion
				if chosen not in PROMOTIONS:
					return _invalid("promotion", "Promotion must be Q, R, B, or N.")
				details.promotion = chosen
			elif promotion != "":
				return _invalid("promotion_square", "Promotion is valid only on the last rank.")
		"N":
			if not (absi(row_delta) == 2 and absi(column_delta) == 1) and not (absi(row_delta) == 1 and absi(column_delta) == 2):
				return _invalid("piece_movement", "Knight cannot move that way.")
		"B":
			if absi(row_delta) != absi(column_delta) or not _path_is_clear(board, from_row, from_column, to_row, to_column):
				return _invalid("piece_movement", "Bishop path is illegal or blocked.")
		"R":
			if not (row_delta == 0 or column_delta == 0) or not _path_is_clear(board, from_row, from_column, to_row, to_column):
				return _invalid("piece_movement", "Rook path is illegal or blocked.")
		"Q":
			var aligned := row_delta == 0 or column_delta == 0 or absi(row_delta) == absi(column_delta)
			if not aligned or not _path_is_clear(board, from_row, from_column, to_row, to_column):
				return _invalid("piece_movement", "Queen path is illegal or blocked.")
		"K":
			if absi(row_delta) <= 1 and absi(column_delta) <= 1:
				pass
			elif row_delta == 0 and absi(column_delta) == 2:
				var castle := _castle_details(state, color, from_index, to_index)
				if not castle.ok:
					return castle
				details.castle_rook_from = castle.castle_rook_from
				details.castle_rook_to = castle.castle_rook_to
			else:
				return _invalid("piece_movement", "King cannot move that way.")
		_:
			return _invalid("piece_code", "Unknown chess piece code.")

	var simulated := _apply_board_move(board, from_index, to_index, details)
	var own_king := _find_king(simulated, color)
	if own_king < 0 or _is_square_attacked(simulated, own_king, _opponent(color)):
		return _invalid("king_exposed", "Move would leave the active king in check.")
	return details


func _castle_details(state: Dictionary, color: String, from_index: int, to_index: int) -> Dictionary:
	var row := 7 if color == "white" else 0
	if from_index != row * 8 + 4:
		return _invalid("castle_origin", "King is not on its castling origin.")
	var kingside := to_index % 8 == 6
	if not kingside and to_index % 8 != 2:
		return _invalid("castle_target", "Invalid castling destination.")
	var right_key := color + ("_kingside" if kingside else "_queenside")
	if not bool(state.castling.get(right_key, false)):
		return _invalid("castle_rights", "Castling rights are no longer available.")
	var rook_column := 7 if kingside else 0
	var rook_target_column := 5 if kingside else 3
	if str(state.board[row * 8 + rook_column]) != _color_prefix(color) + "R":
		return _invalid("castle_rook", "Required rook is missing.")
	var empty_columns := [5, 6] if kingside else [1, 2, 3]
	for column in empty_columns:
		if str(state.board[row * 8 + int(column)]) != "":
			return _invalid("castle_blocked", "Castling path is blocked.")
	var opponent := _opponent(color)
	if _is_square_attacked(state.board, from_index, opponent):
		return _invalid("castle_check", "Cannot castle out of check.")
	var middle_column := 5 if kingside else 3
	var middle_board: Array = state.board.duplicate()
	middle_board[from_index] = ""
	middle_board[row * 8 + middle_column] = _color_prefix(color) + "K"
	if _is_square_attacked(middle_board, row * 8 + middle_column, opponent):
		return _invalid("castle_through_check", "Cannot castle through check.")
	return _valid({
		"castle_rook_from": row * 8 + rook_column,
		"castle_rook_to": row * 8 + rook_target_column,
	})


func _apply_board_move(board: Array, from_index: int, to_index: int, details: Dictionary) -> Array:
	var next: Array = board.duplicate()
	var piece := str(next[from_index])
	next[from_index] = ""
	var en_passant_capture := int(details.get("en_passant_capture", -1))
	if en_passant_capture >= 0:
		next[en_passant_capture] = ""
	var promotion := str(details.get("promotion", ""))
	if promotion != "":
		piece = piece.substr(0, 1) + promotion
	next[to_index] = piece
	var rook_from := int(details.get("castle_rook_from", -1))
	var rook_to := int(details.get("castle_rook_to", -1))
	if rook_from >= 0:
		next[rook_to] = next[rook_from]
		next[rook_from] = ""
	return next


func _update_castling_rights(rights: Dictionary, piece: String, square: int) -> void:
	match piece:
		"wK":
			rights.white_kingside = false
			rights.white_queenside = false
		"bK":
			rights.black_kingside = false
			rights.black_queenside = false
		"wR":
			if square == 63:
				rights.white_kingside = false
			elif square == 56:
				rights.white_queenside = false
		"bR":
			if square == 7:
				rights.black_kingside = false
			elif square == 0:
				rights.black_queenside = false


func _has_any_legal_move(state: Dictionary, color: String) -> bool:
	for from_index in range(64):
		var piece := str(state.board[from_index])
		if piece == "" or _piece_color(piece) != color:
			continue
		for to_index in range(64):
			var promotion := ""
			if piece.ends_with("P") and (to_index / 8 == 0 or to_index / 8 == 7):
				promotion = "Q"
			if _legal_move_details(state, from_index, to_index, promotion, color).ok:
				return true
	return false


func _is_square_attacked(board: Array, square: int, by_color: String) -> bool:
	if square < 0:
		return false
	var target_row := square / 8
	var target_column := square % 8
	for source in range(64):
		var piece := str(board[source])
		if piece == "" or _piece_color(piece) != by_color:
			continue
		var source_row := source / 8
		var source_column := source % 8
		var row_delta := target_row - source_row
		var column_delta := target_column - source_column
		match piece.substr(1, 1):
			"P":
				var direction := -1 if by_color == "white" else 1
				if row_delta == direction and absi(column_delta) == 1:
					return true
			"N":
				if (absi(row_delta) == 2 and absi(column_delta) == 1) or (absi(row_delta) == 1 and absi(column_delta) == 2):
					return true
			"B":
				if absi(row_delta) == absi(column_delta) and _path_is_clear(board, source_row, source_column, target_row, target_column):
					return true
			"R":
				if (row_delta == 0 or column_delta == 0) and _path_is_clear(board, source_row, source_column, target_row, target_column):
					return true
			"Q":
				var aligned := row_delta == 0 or column_delta == 0 or absi(row_delta) == absi(column_delta)
				if aligned and _path_is_clear(board, source_row, source_column, target_row, target_column):
					return true
			"K":
				if absi(row_delta) <= 1 and absi(column_delta) <= 1:
					return true
	return false


func _path_is_clear(board: Array, from_row: int, from_column: int, to_row: int, to_column: int) -> bool:
	var row_step := signi(to_row - from_row)
	var column_step := signi(to_column - from_column)
	var row := from_row + row_step
	var column := from_column + column_step
	while row != to_row or column != to_column:
		if str(board[row * 8 + column]) != "":
			return false
		row += row_step
		column += column_step
	return true


func _find_king(board: Array, color: String) -> int:
	return board.find(_color_prefix(color) + "K")


func _piece_color(piece: String) -> String:
	return "white" if piece.begins_with("w") else "black"


func _color_prefix(color: String) -> String:
	return "w" if color == "white" else "b"


func _opponent(color: String) -> String:
	return "black" if color == "white" else "white"
