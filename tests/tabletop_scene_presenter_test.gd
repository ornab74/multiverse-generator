extends SceneTree

const Registry = preload("res://game_modules/game_module_registry.gd")
const TabletopScenePresenter = preload("res://systems/tabletop_scene_presenter.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_four_line_scene_and_click_contract()
	_test_draughts_reconciliation_and_crowning()
	_test_property_grid_state_surface()
	_test_invalid_state_is_non_mutating()

	if failures.is_empty():
		print("TABLETOP_SCENE_PRESENTER_TEST: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("TABLETOP_SCENE_PRESENTER_TEST: " + failure)
		quit(1)


func _test_four_line_scene_and_click_contract() -> void:
	var context := _context("four_line")
	var presenter: RefCounted = context.presenter
	var reducer: RefCounted = Registry.create("four_line")
	var state: Dictionary = reducer.initial_state({"players": ["cyan", "violet"]})
	var first: Dictionary = presenter.reconcile_state(state)
	_check(first.ok and presenter.target_count("column") == 7, "Four Line did not expose exactly seven column targets")
	_check(presenter.piece_count() == 0, "empty Four Line state rendered tokens")
	for column in range(7):
		var target: Area3D = presenter.target_for("column", column)
		_check(target != null and target.get_node_or_null("HitShape") is CollisionShape3D, "Four Line column %d has no primitive hit target" % column)
		_check(str(target.get_meta("action", {}).get("type", "")) == "drop", "Four Line column metadata omitted its normalized drop action")

	var clicked := {"kind": "", "index": -1, "position": Vector3.INF}
	presenter.target_clicked.connect(func(kind: String, index: int, position: Vector3) -> void:
		clicked.kind = kind
		clicked.index = index
		clicked.position = position
	)
	var activated: Dictionary = presenter.activate_target("column", 3)
	_check(activated.ok and clicked.kind == "column" and int(clicked.index) == 3, "normalized target_clicked signal did not report the activated column")
	_check(clicked.position is Vector3 and clicked.position == presenter.target_for("column", 3).global_position, "target_clicked did not emit a world position")

	state = _reduce(reducer, state, {"type": "drop", "actor": "cyan", "column": 0})
	presenter.reconcile_state(state)
	var first_token: Node3D = presenter.piece_for_slot(35)
	_check(first_token != null and str(first_token.get_meta("actor", "")) == "cyan", "Four Line landing token did not reconcile to row 5")
	state = _reduce(reducer, state, {"type": "drop", "actor": "violet", "column": 1})
	var second_reconcile: Dictionary = presenter.reconcile_state(state)
	_check(presenter.piece_for_slot(35) == first_token, "Four Line replaced an unchanged stable token node")
	_check(presenter.piece_count() == 2 and int(second_reconcile.reused) >= 1, "Four Line reuse diagnostics are inconsistent")
	_cleanup_context(context)


func _test_draughts_reconciliation_and_crowning() -> void:
	var context := _context("draughts")
	var presenter: RefCounted = context.presenter
	var reducer: RefCounted = Registry.create("draughts")
	var state: Dictionary = reducer.initial_state({"players": {"red": "rhea", "black": "blake"}})
	var initial: Dictionary = presenter.reconcile_state(state)
	_check(initial.ok and presenter.target_count("square") == 64, "Draughts did not expose all 64 square targets")
	_check(presenter.piece_count() == 24, "Draughts initial state did not render 24 pieces")
	var red_piece: Node3D = presenter.piece_for_slot(40)
	state = _reduce(reducer, state, {"type": "move", "actor": "rhea", "path": [40, 33]})
	presenter.reconcile_state(state)
	_check(presenter.piece_for_slot(33) == red_piece, "Draughts move did not preserve the moving node")

	var crown_state := state.duplicate(true)
	for index in range(64):
		crown_state.board[index] = ""
	crown_state.board[33] = "R"
	crown_state.turn = "black"
	var crowned: Dictionary = presenter.reconcile_state(crown_state)
	var king: Node3D = presenter.piece_for_slot(33)
	_check(crowned.ok and king == red_piece, "Draughts crowning did not reuse the surviving piece node")
	_check(bool(king.get_meta("is_king", false)) and king.get_node_or_null("KingCrown") is MeshInstance3D, "Draughts king is not visually distinct")
	_check(presenter.target_for("square", 17).get_meta("coord") == Vector2i(1, 2), "Draughts square metadata is not normalized")
	_cleanup_context(context)


func _test_property_grid_state_surface() -> void:
	var context := _context("property_grid")
	var presenter: RefCounted = context.presenter
	var reducer: RefCounted = Registry.create("property_grid")
	var state: Dictionary = reducer.initial_state({"players": ["nova", "quill", "vex"], "seed": 42})
	var initial: Dictionary = presenter.reconcile_state(state)
	_check(initial.ok and presenter.target_count("space") == 16, "Property Grid did not expose its 16-space perimeter")
	_check(presenter.target_count("action") == 4, "Property Grid did not expose its reducer action metadata")
	_check(presenter.piece_count() == 3 and presenter.target_count("player") == 3, "Property Grid did not render all player pawns")
	var nova: Node3D = presenter.piece_for_id("property_player:nova")
	_check(nova != null and int(nova.get_meta("space", -1)) == 0, "Property Grid pawn metadata is missing its initial space")
	for action_index in range(4):
		var action_target: Area3D = presenter.target_for("action", action_index)
		_check(str(action_target.get_meta("action", {}).get("type", "")) in ["roll", "buy", "pass", "end_turn"], "Property Grid action target has malformed metadata")

	state.players[0].position = 1
	state.properties["1"] = "nova"
	var reconciled: Dictionary = presenter.reconcile_state(state)
	var owned_space: Area3D = presenter.space_for_index(1)
	var accent := owned_space.get_node_or_null("OwnershipAccent") as MeshInstance3D
	_check(reconciled.ok and presenter.piece_for_id("property_player:nova") == nova, "Property Grid replaced a moving player pawn")
	_check(str(owned_space.get_meta("owner_id", "")) == "nova" and accent != null and accent.visible, "Property Grid did not render ownership state")
	_check(str(owned_space.get_meta("space_data", {}).get("kind", "")) == "property", "Property Grid space metadata omitted reducer data")
	_check(int(nova.get_meta("space", -1)) == 1, "Property Grid pawn did not move to its reducer position")
	_cleanup_context(context)


func _test_invalid_state_is_non_mutating() -> void:
	var context := _context("four_line")
	var presenter: RefCounted = context.presenter
	var reducer: RefCounted = Registry.create("four_line")
	var state: Dictionary = reducer.initial_state({"players": ["one", "two"]})
	presenter.reconcile_state(state)
	var target_before: Area3D = presenter.target_for("column", 0)
	var invalid := state.duplicate(true)
	invalid.board.pop_back()
	var rejected: Dictionary = presenter.reconcile_state(invalid)
	_check(not rejected.ok and rejected.code == "state_board_size", "malformed state was not rejected with a clear diagnostic")
	_check(presenter.target_for("column", 0) == target_before and presenter.presented_state() == state, "invalid reconciliation mutated the accepted presentation")
	_check(str(presenter.diagnostics().last_code) == "state_board_size", "invalid-state diagnostics did not retain the rejection code")
	_cleanup_context(context)


func _context(module_id: String) -> Dictionary:
	var root := Node3D.new()
	get_root().add_child(root)
	var board_root := Node3D.new()
	board_root.name = "BoardRoot"
	root.add_child(board_root)
	var piece_root := Node3D.new()
	piece_root.name = "PieceRoot"
	root.add_child(piece_root)
	var presenter := TabletopScenePresenter.new()
	var configured: Dictionary = presenter.configure(board_root, piece_root, module_id)
	_check(configured.ok, "presenter configuration failed for %s" % module_id)
	return {"root": root, "board_root": board_root, "piece_root": piece_root, "presenter": presenter}


func _cleanup_context(context: Dictionary) -> void:
	context.presenter.dispose()
	context.root.queue_free()


func _reduce(reducer: RefCounted, state: Dictionary, action: Dictionary) -> Dictionary:
	var result: Dictionary = reducer.reduce(state, action)
	_check(result.get("ok", false), "test setup reducer action was rejected: %s" % str(result.get("code", "unknown")))
	return result.state if result.get("ok", false) else state


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
