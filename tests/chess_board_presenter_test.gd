extends SceneTree

const ChessCore = preload("res://game_modules/chess_core.gd")
const ChessBoardPresenter = preload("res://systems/chess_board_presenter.gd")

var failures: Array[String] = []


class ForgedReceiptReducer:
	extends RefCounted

	var _delegate: RefCounted
	var _forge_on_successful_call: int
	var _successful_calls := 0


	func _init(delegate: RefCounted, forge_on_successful_call: int) -> void:
		_delegate = delegate
		_forge_on_successful_call = forge_on_successful_call


	func reduce(state: Dictionary, action: Dictionary) -> Dictionary:
		var result: Dictionary = _delegate.reduce(state, action)
		if result.get("ok", false):
			_successful_calls += 1
			if _successful_calls == _forge_on_successful_call:
				result = result.duplicate(true)
				result["state_hash"] = "forged-nonempty-receipt"
		return result


	func state_hash(state: Dictionary) -> String:
		return str(_delegate.state_hash(state))


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_initial_reconciliation_and_legal_probes()
	_test_capture_preview_cancel_and_commit()
	_test_stale_preview_is_restored_and_rejected()
	_test_forged_hash_receipts_are_rejected()
	_test_castling_moves_both_stable_nodes()
	_test_en_passant_removes_off_target_piece()
	_test_promotion_updates_one_stable_node()

	if failures.is_empty():
		print("CHESS_BOARD_PRESENTER_TEST: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("CHESS_BOARD_PRESENTER_TEST: " + failure)
		quit(1)


func _test_initial_reconciliation_and_legal_probes() -> void:
	var context := _context()
	var chess: RefCounted = context.chess
	var presenter: RefCounted = context.presenter
	var state: Dictionary = chess.initial_state({"players": {"white": "alice", "black": "bob"}})
	var reconciled: Dictionary = presenter.reconcile_state(state)
	_check(reconciled.ok and presenter.piece_count() == 32, "initial state did not reconcile 32 pieces")
	var pawn: Node3D = presenter.piece_for_square(52)
	_check(pawn != null and str(pawn.get_meta("chess_piece_code", "")) == "wP", "e2 pawn metadata is missing")
	_check(pawn is Area3D and _has_primitive_collision(pawn), "fallback chess piece has no primitive collision")
	_check(pawn.get_child_count() >= 4, "fallback chess piece was not built from procedural primitives")
	var knight_moves: Array[int] = presenter.legal_destinations(state, 57)
	_check(knight_moves == [40, 42], "legal reducer probing returned wrong b1 knight destinations")
	var enemy_moves: Array[int] = presenter.legal_destinations(state, 1, "bob")
	_check(enemy_moves.is_empty(), "legal probing bypassed the reducer turn guard")
	context.root.queue_free()


func _test_capture_preview_cancel_and_commit() -> void:
	var context := _context()
	var chess: RefCounted = context.chess
	var presenter: RefCounted = context.presenter
	var state: Dictionary = chess.initial_state({"players": {"white": "alice", "black": "bob"}})
	state = _reduce(chess, state, {"type": "move", "actor": "alice", "from": 52, "to": 36})
	state = _reduce(chess, state, {"type": "move", "actor": "bob", "from": 11, "to": 27})
	presenter.reconcile_state(state)
	var moving: Node3D = presenter.piece_for_square(36)
	var captured: Node3D = presenter.piece_for_square(27)
	var moving_id := str(moving.get_meta("chess_piece_id", ""))
	var captured_id := str(captured.get_meta("chess_piece_id", ""))

	var preview: Dictionary = presenter.preview_action(state, {
		"type": "move", "actor": "alice", "from": 36, "to": 27,
		"expected_revision": int(state.revision),
		"expected_state_hash": chess.state_hash(state),
	})
	_check(preview.ok and preview.code == "previewed", "legal pawn capture did not preview")
	_check(presenter.piece_for_square(27) == moving, "capturing piece did not move into target presentation square")
	_check(not captured.visible and presenter.piece_for_id(captured_id) == captured, "preview destroyed rather than staged the captured node")
	_check(str(moving.get_meta("chess_piece_id", "")) == moving_id, "capture changed moving piece identity")

	var cancelled: Dictionary = presenter.cancel_preview()
	_check(cancelled.ok and presenter.piece_for_square(36) == moving, "cancel did not restore moving piece")
	_check(presenter.piece_for_square(27) == captured and captured.visible, "cancel did not restore captured piece")

	var second_preview: Dictionary = presenter.preview_action(state, {"type": "move", "actor": "alice", "from": 36, "to": 27})
	var committed: Dictionary = presenter.commit_preview()
	_check(second_preview.ok and committed.ok, "capture could not be previewed and committed")
	_check(presenter.piece_count() == 31 and presenter.piece_for_id(captured_id) == null, "capture commit retained captured identity")
	_check(str(presenter.piece_for_square(27).get_meta("chess_piece_id", "")) == moving_id, "capture commit lost stable moving identity")
	_check(str(committed.state.board[27]) == "wP" and str(committed.state.board[36]) == "", "capture commit returned wrong reducer state")
	context.root.queue_free()


func _test_stale_preview_is_restored_and_rejected() -> void:
	var context := _context()
	var chess: RefCounted = context.chess
	var presenter: RefCounted = context.presenter
	var state: Dictionary = chess.initial_state({"players": {"white": "alice", "black": "bob"}})
	presenter.reconcile_state(state)
	var pawn: Node3D = presenter.piece_for_square(52)
	var preview: Dictionary = presenter.preview_action(state, {"type": "move", "actor": "alice", "from": 52, "to": 36})
	var advanced: Dictionary = _reduce(chess, state, {"type": "move", "actor": "alice", "from": 52, "to": 44})
	var rejected: Dictionary = presenter.commit_preview(advanced)
	_check(preview.ok and not rejected.ok and rejected.code == "preview_stale", "stale authoritative chess state was not rejected")
	_check(not presenter.has_preview(), "stale commit left the rejected preview active")
	_check(presenter.piece_for_square(52) == pawn and pawn.visible, "stale commit did not restore the exact pre-preview scene")
	context.root.queue_free()


func _test_forged_hash_receipts_are_rejected() -> void:
	var preview_root := Node3D.new()
	get_root().add_child(preview_root)
	var preview_chess := ChessCore.new()
	var preview_reducer := ForgedReceiptReducer.new(preview_chess, 1)
	var preview_presenter := ChessBoardPresenter.new()
	preview_presenter.configure(preview_root, preview_reducer)
	var preview_state: Dictionary = preview_chess.initial_state({"players": {"white": "alice", "black": "bob"}})
	preview_presenter.reconcile_state(preview_state)
	var preview_pawn: Node3D = preview_presenter.piece_for_square(52)
	var forged_preview: Dictionary = preview_presenter.preview_action(
		preview_state,
		{"type": "move", "actor": "alice", "from": 52, "to": 36}
	)
	_check(
		not forged_preview.ok and forged_preview.code == "reducer_hash_mismatch",
		"chess presenter accepted a forged preview state_hash receipt"
	)
	_check(not preview_presenter.has_preview(), "forged chess preview left pending state")
	_check(
		preview_presenter.piece_for_square(52) == preview_pawn and preview_presenter.piece_for_square(36) == null,
		"forged chess preview changed the presented scene"
	)
	preview_root.queue_free()

	var commit_root := Node3D.new()
	get_root().add_child(commit_root)
	var commit_chess := ChessCore.new()
	var commit_reducer := ForgedReceiptReducer.new(commit_chess, 2)
	var commit_presenter := ChessBoardPresenter.new()
	commit_presenter.configure(commit_root, commit_reducer)
	var commit_state: Dictionary = commit_chess.initial_state({"players": {"white": "alice", "black": "bob"}})
	commit_presenter.reconcile_state(commit_state)
	var commit_pawn: Node3D = commit_presenter.piece_for_square(52)
	var accepted_preview: Dictionary = commit_presenter.preview_action(
		commit_state,
		{"type": "move", "actor": "alice", "from": 52, "to": 36}
	)
	var forged_commit: Dictionary = commit_presenter.commit_preview()
	_check(accepted_preview.ok, "chess forged-commit setup preview was unexpectedly rejected")
	_check(
		not forged_commit.ok and forged_commit.code == "reducer_hash_mismatch",
		"chess presenter accepted a forged commit state_hash receipt"
	)
	_check(not commit_presenter.has_preview(), "forged chess commit left pending state")
	_check(
		commit_presenter.piece_for_square(52) == commit_pawn and commit_presenter.piece_for_square(36) == null,
		"forged chess commit did not restore the pre-preview scene"
	)
	commit_root.queue_free()


func _test_castling_moves_both_stable_nodes() -> void:
	var context := _context()
	var chess: RefCounted = context.chess
	var presenter: RefCounted = context.presenter
	var state := _minimal_state(chess)
	state.board[4] = "bK"
	state.board[60] = "wK"
	state.board[63] = "wR"
	state.castling.white_kingside = true
	presenter.reconcile_state(state)
	var king: Node3D = presenter.piece_for_square(60)
	var rook: Node3D = presenter.piece_for_square(63)
	var king_id := str(king.get_meta("chess_piece_id", ""))
	var rook_id := str(rook.get_meta("chess_piece_id", ""))
	var preview: Dictionary = presenter.preview_action(state, {"type": "move", "actor": "alice", "from": 60, "to": 62})
	_check(preview.ok, "legal kingside castle did not preview")
	_check(presenter.piece_for_square(62) == king and presenter.piece_for_square(61) == rook, "castling did not reconcile king and rook")
	_check(preview.diff.moves.size() == 2 and preview.diff.moves[1].role == "castle_rook", "castling diff did not identify its rook move")
	var committed: Dictionary = presenter.commit_preview()
	_check(committed.ok, "castling preview did not commit")
	_check(str(presenter.piece_for_square(62).get_meta("chess_piece_id", "")) == king_id, "castling changed king identity")
	_check(str(presenter.piece_for_square(61).get_meta("chess_piece_id", "")) == rook_id, "castling changed rook identity")
	context.root.queue_free()


func _test_en_passant_removes_off_target_piece() -> void:
	var context := _context()
	var chess: RefCounted = context.chess
	var presenter: RefCounted = context.presenter
	var state: Dictionary = chess.initial_state({"players": {"white": "alice", "black": "bob"}})
	for action in [
		{"type": "move", "actor": "alice", "from": 52, "to": 36},
		{"type": "move", "actor": "bob", "from": 8, "to": 16},
		{"type": "move", "actor": "alice", "from": 36, "to": 28},
		{"type": "move", "actor": "bob", "from": 11, "to": 27},
	]:
		state = _reduce(chess, state, action)
	presenter.reconcile_state(state)
	var white_pawn: Node3D = presenter.piece_for_square(28)
	var black_pawn: Node3D = presenter.piece_for_square(27)
	var black_id := str(black_pawn.get_meta("chess_piece_id", ""))
	var preview: Dictionary = presenter.preview_action(state, {"type": "move", "actor": "alice", "from": 28, "to": 19})
	_check(preview.ok, "legal en-passant did not preview")
	_check(preview.diff.removes.size() == 1 and int(preview.diff.removes[0].square) == 27, "en-passant diff missed its off-target capture")
	_check(presenter.piece_for_square(19) == white_pawn and presenter.piece_for_square(27) == null, "en-passant scene reconciliation diverged")
	_check(not black_pawn.visible, "en-passant capture was not staged reversibly")
	presenter.commit_preview()
	_check(presenter.piece_for_id(black_id) == null and presenter.piece_count() == 31, "en-passant commit retained captured pawn")
	context.root.queue_free()


func _test_promotion_updates_one_stable_node() -> void:
	var context := _context()
	var chess: RefCounted = context.chess
	var presenter: RefCounted = context.presenter
	var state := _minimal_state(chess)
	state.board[7] = "bK"
	state.board[8] = "wP"
	state.board[60] = "wK"
	presenter.reconcile_state(state)
	var pawn: Node3D = presenter.piece_for_square(8)
	var pawn_id := str(pawn.get_meta("chess_piece_id", ""))
	var original_child_count := pawn.get_child_count()
	var preview: Dictionary = presenter.preview_action(state, {
		"type": "move", "actor": "alice", "from": 8, "to": 0, "promotion": "N",
	})
	_check(preview.ok and preview.diff.promotions.size() == 1, "knight promotion did not preview as a promotion")
	_check(presenter.piece_for_square(0) == pawn and str(pawn.get_meta("chess_piece_code", "")) == "wN", "promotion replaced or mislabeled stable pawn node")
	_check(str(pawn.get_meta("chess_piece_id", "")) == pawn_id, "promotion changed piece identity")
	_check(pawn.get_child_count() >= original_child_count - 1, "procedural promotion visual was not rebuilt")
	presenter.cancel_preview()
	_check(presenter.piece_for_square(8) == pawn and str(pawn.get_meta("chess_piece_code", "")) == "wP", "promotion cancel did not restore pawn")
	var queen_preview: Dictionary = presenter.preview_action(state, {"type": "move", "actor": "alice", "from": 8, "to": 0, "promotion": "Q"})
	var committed: Dictionary = presenter.commit_preview()
	_check(queen_preview.ok and committed.ok and str(committed.state.board[0]) == "wQ", "queen promotion did not commit")
	_check(str(presenter.piece_for_square(0).get_meta("chess_piece_id", "")) == pawn_id, "committed promotion lost pawn identity")
	context.root.queue_free()


func _context() -> Dictionary:
	var root := Node3D.new()
	get_root().add_child(root)
	var chess := ChessCore.new()
	var presenter := ChessBoardPresenter.new()
	var configured: Dictionary = presenter.configure(root, chess)
	_check(configured.ok, "presenter configuration failed")
	return {"root": root, "chess": chess, "presenter": presenter}


func _minimal_state(chess: RefCounted) -> Dictionary:
	var state: Dictionary = chess.initial_state({"players": {"white": "alice", "black": "bob"}})
	state.board.fill("")
	state.turn = "white"
	state.castling = {
		"white_kingside": false,
		"white_queenside": false,
		"black_kingside": false,
		"black_queenside": false,
	}
	state.en_passant = -1
	state.status = "active"
	state.check = false
	return state


func _reduce(chess: RefCounted, state: Dictionary, action: Dictionary) -> Dictionary:
	var result: Dictionary = chess.reduce(state, action)
	_check(result.ok, "test setup reducer action was rejected: " + str(result.get("code", "unknown")))
	return result.state if result.ok else state


func _has_primitive_collision(piece: Node3D) -> bool:
	for child in piece.get_children():
		if child is CollisionShape3D and child.shape is CylinderShape3D:
			return true
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
