extends SceneTree

const Arena = preload("res://ui/llm_arena_panel.gd")

func _initialize() -> void:
	var arena: PanelContainer = Arena.new()
	root.add_child(arena)
	await process_frame
	assert(not arena.bridge.get_snapshot().ready)
	assert(arena.new_game_button != null)
	assert(arena.saved_games_button != null)
	assert(arena.settings_button != null)
	assert(arena.chat_input.editable == false)
	assert(arena.square_buttons.size() == 64)
	assert(arena.state.board.size() == 64)
	# Reproduce the AI-turn ordering: commit while thinking, then release the
	# thinking gate.  The board must become interactive again for White.
	var player_move: Dictionary = arena._action_for(52, 36, "YOU")
	var player_result: Dictionary = arena.reducer.reduce(arena.state, player_move)
	arena._commit_state(player_result, "YOU", player_move)
	arena.thinking = true
	var agent_move: Dictionary = arena._action_for(12, 28, "CAISSA")
	var agent_result: Dictionary = arena.reducer.reduce(arena.state, agent_move)
	arena._commit_state(agent_result, "CAISSA", agent_move)
	assert(arena.square_buttons[52].disabled)
	arena.thinking = false
	arena._refresh_controls()
	assert(not arena.square_buttons[52].disabled)
	# Choosing Black applies to the next game, rotates the board, and leaves the
	# opening White turn to Caissa.
	arena.set_agent_preferences({"player_side": "black"})
	arena._new_game()
	assert(arena.game_player_side == "black")
	assert(arena.state.players.white == "CAISSA" and arena.state.players.black == "YOU")
	assert(arena.square_buttons[0].tooltip_text.begins_with("h1"))
	assert(arena.square_buttons[0].disabled)
	print("LLM_ARENA_GATE_TEST: PASS")
	quit(0)
