extends "res://game_modules/deterministic_game_module.gd"

const WIDTH := 7
const HEIGHT := 6
const CONNECT := 4


func manifest() -> Dictionary:
	return {
		"id": "four_line",
		"title": "Four Line",
		"version": "1.0.0",
		"players": {"min": 2, "max": 2},
		"deterministic": true,
		"board": {"kind": "rect_grid", "width": WIDTH, "height": HEIGHT},
		"actions": {
			"drop": {"required": ["actor", "column"], "column": [0, WIDTH - 1]},
		},
		"rendering": {
			"asset_policy": "procedural_native",
			"tokens": ["disc_a", "disc_b"],
		},
	}


func _initial_state(config: Dictionary) -> Dictionary:
	var requested: Array = config.get("players", ["p1", "p2"])
	var players := ["p1", "p2"]
	if requested.size() == 2 and str(requested[0]) != str(requested[1]):
		players = [str(requested[0]), str(requested[1])]
	var board: Array = []
	board.resize(WIDTH * HEIGHT)
	board.fill("")
	return {
		"module_id": "four_line",
		"revision": 0,
		"players": players,
		"turn_index": 0,
		"board": board,
		"status": "active",
		"winner": "",
		"winning_cells": [],
		"move_count": 0,
	}


func validate_action(state: Dictionary, action: Dictionary) -> Dictionary:
	if str(state.get("status", "")) != "active":
		return _invalid("game_complete", "No actions are accepted after the game completes.")
	if str(action.get("type", "")) != "drop":
		return _invalid("action_type", "Four Line accepts only drop actions.")
	if not action.has("actor"):
		return _invalid("actor_required", "A signed actor id is required.")
	var expected_actor := str(state.players[int(state.turn_index)])
	if str(action.actor) != expected_actor:
		return _invalid("out_of_turn", "Only the active player can drop a token.")
	if not action.get("column", null) is int:
		return _invalid("column_type", "Column must be an integer.")
	var column := int(action.column)
	if column < 0 or column >= WIDTH:
		return _invalid("column_range", "Column is outside the board.")
	if str(state.board[column]) != "":
		return _invalid("column_full", "That column is full.")
	return _valid()


func _reduce_validated(state: Dictionary, action: Dictionary) -> Dictionary:
	var column := int(action.column)
	var actor := str(action.actor)
	var landing_row := -1
	for row in range(HEIGHT - 1, -1, -1):
		var index := row * WIDTH + column
		if str(state.board[index]) == "":
			state.board[index] = actor
			landing_row = row
			break

	state.move_count = int(state.move_count) + 1
	var line := _winning_line(state.board, landing_row, column, actor)
	if line.size() >= CONNECT:
		state.status = "won"
		state.winner = actor
		state.winning_cells = line
	elif int(state.move_count) == WIDTH * HEIGHT:
		state.status = "draw"
	else:
		state.turn_index = (int(state.turn_index) + 1) % 2
	return state


func _winning_line(board: Array, row: int, column: int, actor: String) -> Array:
	for direction in [[0, 1], [1, 0], [1, 1], [1, -1]]:
		var cells := [row * WIDTH + column]
		for sign_value in [-1, 1]:
			var scan_row: int = row + int(direction[0]) * int(sign_value)
			var scan_column: int = column + int(direction[1]) * int(sign_value)
			while _inside(scan_row, scan_column):
				var index: int = scan_row * WIDTH + scan_column
				if str(board[index]) != actor:
					break
				if sign_value < 0:
					cells.push_front(index)
				else:
					cells.append(index)
				scan_row += int(direction[0]) * sign_value
				scan_column += int(direction[1]) * sign_value
		if cells.size() >= CONNECT:
			return cells
	return []


func _inside(row: int, column: int) -> bool:
	return row >= 0 and row < HEIGHT and column >= 0 and column < WIDTH
