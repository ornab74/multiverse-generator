extends SceneTree

const MainSceneScript = preload("res://main.gd")

var failures: Array[String] = []
var game: Node3D


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	game = MainSceneScript.new()
	root.add_child(game)
	await process_frame
	_check(game.chess_presenter != null, "live scene did not mount the chess presenter")
	_check(game.chess_presenter.piece_count() == 32, "presenter did not adopt all 32 scene pieces")
	var initial_hash: String = game.rule_engine.state_hash(game.rule_state)
	var pawn: Node3D = game.chess_presenter.piece_for_square(52)
	var destination: Area3D = _square_at(Vector2i(4, 4))
	_check(pawn != null and destination != null, "e2/e4 integration fixtures were missing")
	if pawn != null and destination != null:
		_click_piece(pawn)
		_check(game.move_label.text.contains("2 legal"), "selection did not expose reducer-backed legal destinations")
		_click_square(destination)
		_check(game.chess_presenter.has_preview(), "legal square did not create a reversible preview")
		_check(not game.commit_button.disabled and not game.cancel_button.disabled, "preview actions were not enabled")
		_check(game.chess_presenter.piece_for_square(36) == pawn, "preview did not present e2-e4")
		var advanced_result: Dictionary = game.rule_engine.reduce(game.rule_state, {"type": "move", "actor": "Q7", "from": 52, "to": 44})
		game.rule_state = Dictionary(advanced_result.state).duplicate(true)
		game._commit_move()
		_check(game.pending_rule_result.is_empty() and not game.chess_presenter.has_preview(), "stale main-scene commit left a deadlocked pending preview")
		_check(game.commit_button.disabled and game.cancel_button.disabled, "stale main-scene commit left preview controls enabled")
		_check(game.chess_presenter.piece_for_square(44) == pawn, "stale commit did not reconcile the authoritative e2-e3 snapshot")

		game.rule_state = game.rule_engine.initial_state({"players": {"white": "Q7", "black": "VX"}})
		game.chess_presenter.reconcile_state(game.rule_state)
		pawn = game.chess_presenter.piece_for_square(52)
		_click_piece(pawn)
		_click_square(destination)
		game._cancel_move_preview()
		_check(not game.chess_presenter.has_preview(), "cancel left a preview active")
		_check(game.chess_presenter.piece_for_square(52) == pawn, "cancel did not restore the pawn")
		_check(game.rule_engine.state_hash(game.rule_state) == initial_hash, "cancel changed the authoritative state hash")
		_click_piece(pawn)
		_click_square(destination)
		game._commit_move()
		_check(int(game.rule_state.revision) == 1, "commit did not advance reducer revision")
		_check(str(game.rule_state.board[36]) == "wP" and str(game.rule_state.board[52]) == "", "committed board diverged from e2-e4")
		_check(not game.chess_presenter.has_preview(), "commit left a preview active")
		var expected_position: Vector3 = game._board_position(4, 4, 0.9) + Vector3(0, 0.22, 0)
		_check(pawn.position.is_equal_approx(expected_position), "immediate commit left the piece between preview tween positions")

	game._select_module("Four Line")
	_check(game.hero_texture.texture.resource_path.ends_with("four_line_forge.png"), "Four Line generated UI plate was not wired into gameplay")
	_check(game.tabletop_controller != null and game.tabletop_presenter != null, "Four Line did not mount its live interaction and scene adapters")
	if game.tabletop_presenter != null and game.tabletop_controller != null:
		_check(game.tabletop_presenter.target_count("column") == 7, "Four Line live scene did not expose seven columns")
		var four_line_hash: String = game.rule_engine.state_hash(game.rule_state)
		game.tabletop_presenter.activate_target("column", 3)
		_check(game.tabletop_controller.has_preview(), "Four Line column did not create a reducer preview")
		_check(game.tabletop_presenter.piece_for_slot(38) != null, "Four Line preview did not render its landing token")
		game._cancel_session_preview()
		_check(not game.tabletop_controller.has_preview(), "Four Line cancel left a preview active")
		_check(game.tabletop_presenter.piece_for_slot(38) == null, "Four Line cancel retained its preview token")
		_check(game.rule_engine.state_hash(game.rule_state) == four_line_hash, "Four Line cancel changed the authoritative state")
		game.tabletop_presenter.activate_target("column", 3)
		game._commit_session_action()
		_check(int(game.rule_state.revision) == 1 and str(game.rule_state.board[38]) == "Q7", "Four Line live commit diverged from the reducer")
		_check(game.tabletop_presenter.piece_for_slot(38) != null, "Four Line commit was not reconciled into the scene")

	game._select_module("Draughts")
	_check(game.hero_texture.texture.resource_path.ends_with("draughts_forge.png"), "Draughts generated UI plate was not wired into gameplay")
	_check(game.tabletop_controller != null and game.tabletop_presenter != null, "Draughts did not mount its live interaction and scene adapters")
	if game.tabletop_presenter != null and game.tabletop_controller != null:
		var draughts_piece: Node3D = game.tabletop_presenter.piece_for_slot(40)
		game.tabletop_presenter.activate_target("piece", 40)
		game.tabletop_presenter.activate_target("square", 33)
		_check(game.tabletop_controller.has_preview(), "Draughts source and destination did not create a complete-path preview")
		_check(game.tabletop_presenter.piece_for_slot(33) == draughts_piece, "Draughts preview did not preserve the moving piece node")
		game._commit_session_action()
		_check(int(game.rule_state.revision) == 1 and str(game.rule_state.board[33]) == "r", "Draughts live commit diverged from the reducer")

	game._select_module("Property Grid")
	_check(game.hero_texture.texture.resource_path.ends_with("property_grid_forge.png"), "Property Grid generated UI plate was not wired into gameplay")
	_check(game.tabletop_controller != null and game.tabletop_presenter != null, "Property Grid did not mount its live interaction and scene adapters")
	if game.tabletop_presenter != null and game.tabletop_controller != null:
		game.tabletop_presenter.activate_target("action", 0)
		_check(game.tabletop_controller.has_preview(), "Property Grid roll did not create a deterministic preview")
		game._commit_session_action()
		var local_player: Dictionary = game.rule_state.players[0]
		var local_pawn: Node3D = game.tabletop_presenter.piece_for_id("property_player:Q7")
		_check(int(game.rule_state.revision) == 1 and int(local_player.position) > 0, "Property Grid roll did not advance reducer state")
		_check(local_pawn != null and int(local_pawn.get_meta("space", -1)) == int(local_player.position), "Property Grid pawn did not reconcile to the rolled space")

	var settings_sliders: Array[Node] = game.front_end.settings_overlay.find_children("*", "HSlider", true, false)
	var settings_toggles: Array[Node] = game.front_end.settings_overlay.find_children("*", "CheckButton", true, false)
	_check(settings_sliders.size() >= 3 and settings_toggles.size() >= 2, "presentation controls were not mounted in settings")
	if settings_sliders.size() >= 3:
		(settings_sliders[0] as HSlider).value = 50
		(settings_sliders[1] as HSlider).value = 40
		(settings_sliders[2] as HSlider).value = 30
	if settings_toggles.size() >= 2:
		(settings_toggles[0] as CheckButton).button_pressed = true
		(settings_toggles[1] as CheckButton).button_pressed = false
	await process_frame
	_check(game.reduced_motion and game.vfx_director.reduced_motion, "reduced-motion profile did not reach scene and VFX")
	var levels: Dictionary = game.audio_director.get_levels()
	_check(is_equal_approx(float(levels.master), 0.5) and is_equal_approx(float(levels.ui), 0.3), "presentation volume profile did not reach Nexus audio buses")
	var found_session_apply := false
	for button_node in game.front_end.settings_overlay.find_children("*", "Button", true, false):
		if (button_node as Button).text == "APPLY SESSION PROFILE":
			found_session_apply = true
	_check(found_session_apply, "settings still presented an unimplemented persistence action")
	game.front_end._toggle_settings()
	await process_frame
	_check(game.front_end.settings_overlay.visible, "settings modal did not open")
	_check(game.get_viewport().gui_get_focus_owner() == game.front_end.settings_close_button, "settings modal did not move keyboard focus inside")
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	game.front_end._input(escape)
	_check(not game.front_end.settings_overlay.visible, "Escape did not close the settings modal")

	game.queue_free()
	await process_frame
	await create_timer(0.12).timeout
	if failures.is_empty():
		print("PRESENTATION_INTEGRATION_TEST: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("PRESENTATION_INTEGRATION_TEST: " + failure)
		quit(1)


func _click_piece(piece: Node3D) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	game._on_piece_input(null, event, Vector3.ZERO, Vector3.UP, 0, piece)


func _click_square(square: Area3D) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	game._on_square_input(null, event, Vector3.ZERO, Vector3.UP, 0, square)


func _square_at(coord: Vector2i) -> Area3D:
	for child in game.board_root.get_children():
		if child is Area3D and child.get_meta("coord", Vector2i(-1, -1)) == coord:
			return child
	return null


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
