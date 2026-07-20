extends SceneTree

const ChessCore = preload("res://game_modules/chess_core.gd")
const ChessHistory = preload("res://systems/chess_history.gd")


func _initialize() -> void:
	var chess := ChessCore.new()
	var history := ChessHistory.new(8)
	var state: Dictionary = chess.initial_state({"players": {"white": "player", "black": "vexel"}})
	var started: Dictionary = history.new_game(state, chess.state_hash(state))
	assert(started.ok and not history.can_undo())
	assert(ChessHistory.square_name(0) == "a8" and ChessHistory.square_name(63) == "h1")

	var first_action := _action(state, 52, 36)
	var first_result: Dictionary = chess.reduce(state, first_action)
	var first_record: Dictionary = history.commit(state, first_action, first_result, {"message": "Claims the center."})
	assert(first_record.ok and first_record.record.uci == "e2e4")
	assert(first_record.record.algebraic == "e2-e4")
	assert(history.can_undo() and history.current_snapshot() == first_result.state)
	state = first_result.state

	var second_action := _action(state, 12, 28)
	var second_result: Dictionary = chess.reduce(state, second_action)
	assert(history.commit(state, second_action, second_result).ok)
	state = second_result.state
	assert(history.records().size() == 2)
	assert(history.prompt_context(2)[1].uci == "e7e5")
	assert(not history.prompt_context(2)[1].has("before_state"))

	var undone: Dictionary = history.undo()
	assert(undone.ok and int(undone.state.revision) == 1 and history.can_redo())
	var redone: Dictionary = history.redo()
	assert(redone.ok and redone.state == state and not history.can_redo())

	var rejected_result: Dictionary = chess.reduce(state, {"type": "move", "actor": "vexel", "from": 51, "to": 35})
	assert(not rejected_result.ok)
	assert(not history.commit(state, {"type": "move", "actor": "vexel", "from": 51, "to": 35}, rejected_result).ok)
	var stale := history.current_snapshot()
	stale.revision = 0
	var next_action := _action(state, 62, 45)
	var next_result: Dictionary = chess.reduce(state, next_action)
	var conflict: Dictionary = history.commit(stale, next_action, next_result)
	assert(not conflict.ok and conflict.code == "history_conflict")

	var restarted: Dictionary = history.restart()
	assert(restarted.ok and int(restarted.state.revision) == 0 and history.records().is_empty())

	# The retained timeline is bounded even across a much longer legal game.
	state = restarted.state
	var cycle := [[62, 45], [6, 21], [45, 62], [21, 6]]
	for cycle_index in range(3):
		for pair in cycle:
			var action := _action(state, int(pair[0]), int(pair[1]))
			var result: Dictionary = chess.reduce(state, action)
			assert(result.ok)
			assert(history.commit(state, action, result).ok)
			state = result.state
	assert(history.records().size() == 8)
	assert(int(history.retained_base_snapshot().revision) == 4)
	assert(history.summary().total_plies == 12)

	var castle_state: Dictionary = chess.initial_state({"players": {"white": "player", "black": "vexel"}})
	assert(ChessHistory.algebraic_for_action(castle_state, {"from": 60, "to": 62}) == "O-O")
	assert(ChessHistory.uci_for_action({"from": 8, "to": 0, "promotion": "N"}) == "a7a8n")

	print("CHESS_HISTORY_TEST: PASS")
	quit(0)


func _action(state: Dictionary, from_square: int, to_square: int) -> Dictionary:
	return {
		"type": "move",
		"actor": str(state.players[state.turn]),
		"from": from_square,
		"to": to_square,
		"expected_revision": int(state.revision),
	}
