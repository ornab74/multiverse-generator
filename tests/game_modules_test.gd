extends SceneTree

const Registry = preload("res://game_modules/game_module_registry.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_registry_and_manifests()
	_test_chess_core_and_fixtures()
	_test_chess_checkmate()
	_test_four_line()
	_test_draughts()
	_test_property_grid()

	if failures.is_empty():
		print("GAME_MODULES_TEST: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("GAME_MODULES_TEST: " + failure)
		quit(1)


func _test_registry_and_manifests() -> void:
	_check(Registry.list_ids() == ["chess_core", "draughts", "four_line", "property_grid"], "registry ids are unstable")
	_check(Registry.create("Chess Core") != null, "chess alias did not resolve")
	_check(Registry.create("connect four") != null, "four-line alias did not resolve")
	_check(Registry.create("checkers") != null, "draughts alias did not resolve")
	_check(Registry.create("unknown") == null, "unknown module should not resolve")
	for manifest in Registry.list_manifests():
		_check(str(manifest.get("id", "")) != "", "manifest is missing an id")
		_check(str(manifest.get("version", "")) == "1.0.0", "manifest version is not pinned")
		_check(bool(manifest.get("deterministic", false)), "manifest is not marked deterministic")
		_check(str(manifest.get("rendering", {}).get("asset_policy", "")) == "procedural_native", "manifest asset policy is unsafe")


func _test_chess_core_and_fixtures() -> void:
	var chess := Registry.create("chess_core")
	var config := {"players": {"white": "alice", "black": "bob"}}
	var initial: Dictionary = chess.initial_state(config)
	var initial_copy := initial.duplicate(true)
	var first: Dictionary = chess.reduce(initial, {
		"type": "move", "actor": "alice", "from": 52, "to": 36,
		"expected_revision": 0, "expected_state_hash": chess.state_hash(initial),
	})
	_check(first.ok, "legal e2-e4 chess move was rejected")
	_check(initial == initial_copy, "chess reducer mutated its input state")
	if first.ok:
		_check(str(first.state.board[36]) == "wP" and str(first.state.board[52]) == "", "chess move was reduced incorrectly")
		_check(int(first.state.en_passant) == 44, "chess en-passant target was not recorded")
		var wrong_actor: Dictionary = chess.reduce(first.state, {"type": "move", "actor": "alice", "from": 51, "to": 43})
		_check(not wrong_actor.ok and wrong_actor.code == "out_of_turn", "chess allowed an out-of-turn actor")
		var stale: Dictionary = chess.reduce(first.state, {"type": "move", "actor": "bob", "from": 12, "to": 28, "expected_revision": 0})
		_check(not stale.ok and stale.code == "revision_conflict", "chess accepted a stale revision")

	var actions := [
		{"type": "move", "actor": "alice", "from": 52, "to": 36},
		{"type": "move", "actor": "bob", "from": 12, "to": 28},
		{"type": "move", "actor": "alice", "from": 62, "to": 45},
	]
	var fixture: Dictionary = chess.create_fixture(actions, config)
	_check(fixture.valid and fixture.steps.size() == 3, "chess fixture could not be recorded")
	var replay: Dictionary = chess.replay_fixture(fixture)
	_check(replay.ok and replay.state_hash == fixture.final_hash, "chess fixture did not replay deterministically")
	var rollback: Dictionary = chess.rollback_fixture(fixture, 1)
	_check(rollback.ok and int(rollback.state.revision) == 1 and str(rollback.state.board[36]) == "wP", "chess fixture rollback returned the wrong revision")
	var tampered := fixture.duplicate(true)
	tampered.steps[1].hash = "00"
	var rejected_tamper: Dictionary = chess.replay_fixture(tampered)
	_check(not rejected_tamper.ok and rejected_tamper.code == "fixture_hash", "fixture hash tampering was not detected")


func _test_chess_checkmate() -> void:
	var chess := Registry.create("chess_core")
	var state: Dictionary = chess.initial_state({"players": {"white": "alice", "black": "bob"}})
	var actions := [
		{"type": "move", "actor": "alice", "from": 53, "to": 45},
		{"type": "move", "actor": "bob", "from": 12, "to": 28},
		{"type": "move", "actor": "alice", "from": 54, "to": 38},
		{"type": "move", "actor": "bob", "from": 3, "to": 39},
	]
	for action in actions:
		var result: Dictionary = chess.reduce(state, action)
		_check(result.ok, "legal checkmate fixture move was rejected")
		if not result.ok:
			return
		state = result.state
	_check(state.status == "won" and state.result == "checkmate", "Chess Core did not recognize checkmate")
	_check(state.winner_player == "bob" and state.check, "Chess Core recorded the wrong checkmate winner")


func _test_four_line() -> void:
	var module := Registry.create("four_line")
	var state: Dictionary = module.initial_state({"players": ["cyan", "violet"]})
	var columns := [0, 1, 0, 1, 0, 1, 0]
	for move_index in range(columns.size()):
		var actor := "cyan" if move_index % 2 == 0 else "violet"
		var result: Dictionary = module.reduce(state, {"type": "drop", "actor": actor, "column": columns[move_index]})
		_check(result.ok, "legal Four Line drop %d was rejected" % move_index)
		if not result.ok:
			return
		state = result.state
	_check(state.status == "won" and state.winner == "cyan", "Four Line did not detect a vertical win")
	_check(state.winning_cells == [14, 21, 28, 35], "Four Line winning cells are not deterministic")
	var after_win: Dictionary = module.reduce(state, {"type": "drop", "actor": "violet", "column": 2})
	_check(not after_win.ok and after_win.code == "game_complete", "Four Line accepted a post-win move")


func _test_draughts() -> void:
	var module := Registry.create("draughts")
	var state: Dictionary = module.initial_state({"players": {"red": "rhea", "black": "blake"}})
	var red_open: Dictionary = module.reduce(state, {"type": "move", "actor": "rhea", "path": [40, 33]})
	_check(red_open.ok, "legal draughts opening move was rejected")
	if not red_open.ok:
		return
	var capture_state: Dictionary = module.initial_state({"players": {"red": "rhea", "black": "blake"}})
	capture_state.board.fill("")
	capture_state.board[40] = "r"
	capture_state.board[42] = "r"
	capture_state.board[35] = "b"
	var skipped_capture: Dictionary = module.reduce(capture_state, {"type": "move", "actor": "rhea", "path": [40, 33]})
	_check(not skipped_capture.ok and skipped_capture.code == "capture_required", "draughts did not enforce a mandatory capture")
	var capture: Dictionary = module.reduce(capture_state, {"type": "move", "actor": "rhea", "path": [42, 28]})
	_check(capture.ok, "legal draughts capture was rejected")
	if capture.ok:
		_check(str(capture.state.board[28]) == "r" and str(capture.state.board[35]) == "", "draughts capture was reduced incorrectly")
		_check(int(capture.state.capture_count) == 1, "draughts capture counter diverged")


func _test_property_grid() -> void:
	var module := Registry.create("property_grid")
	var config := {"players": ["nova", "quill", "vex"], "seed": 424242}
	var state_a: Dictionary = module.initial_state(config)
	var state_b: Dictionary = module.initial_state(config)
	var roll_a: Dictionary = module.reduce(state_a, {"type": "roll", "actor": "nova"})
	var roll_b: Dictionary = module.reduce(state_b, {"type": "roll", "actor": "nova"})
	_check(roll_a.ok and roll_b.ok, "Property Grid deterministic roll was rejected")
	if not roll_a.ok or not roll_b.ok:
		return
	_check(roll_a.state.last_roll == roll_b.state.last_roll, "Property Grid seeded dice diverged")
	_check(roll_a.state_hash == roll_b.state_hash, "Property Grid equal rolls produced different hashes")
	var state: Dictionary = roll_a.state
	if state.phase == "await_purchase":
		var purchase: Dictionary = module.reduce(state, {"type": "buy", "actor": "nova"})
		_check(purchase.ok, "Property Grid purchase was rejected")
		if not purchase.ok:
			return
		state = purchase.state
	_check(state.phase == "await_end", "Property Grid landing did not reach a resolvable end phase")
	var turn_end: Dictionary = module.reduce(state, {"type": "end_turn", "actor": "nova"})
	_check(turn_end.ok, "Property Grid end-turn was rejected")
	if turn_end.ok:
		_check(int(turn_end.state.turn_index) == 1 and turn_end.state.phase == "await_roll", "Property Grid did not advance to the next player")
		var out_of_turn: Dictionary = module.reduce(turn_end.state, {"type": "roll", "actor": "nova"})
		_check(not out_of_turn.ok and out_of_turn.code == "out_of_turn", "Property Grid allowed a non-active player to roll")


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
