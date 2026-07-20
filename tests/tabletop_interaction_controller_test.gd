extends SceneTree

const FourLine = preload("res://game_modules/four_line.gd")
const Draughts = preload("res://game_modules/draughts.gd")
const PropertyGrid = preload("res://game_modules/property_grid.gd")
const TabletopInteractionController = preload("res://systems/tabletop_interaction_controller.gd")

var failures: Array[String] = []


class ForgedReceiptReducer:
	extends RefCounted

	var _delegate: RefCounted
	var _forge_on_successful_call: int
	var _successful_calls := 0


	func _init(delegate: RefCounted, forge_on_successful_call: int) -> void:
		_delegate = delegate
		_forge_on_successful_call = forge_on_successful_call


	func manifest() -> Dictionary:
		return _delegate.manifest()


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
	_test_four_line_affordances_and_immutable_preview()
	_test_draughts_complete_capture_paths()
	_test_property_grid_phase_intents()
	_test_sanitization_and_module_guards()
	_test_forged_hash_receipts_are_rejected()

	if failures.is_empty():
		print("TABLETOP_INTERACTION_CONTROLLER_TEST: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("TABLETOP_INTERACTION_CONTROLLER_TEST: " + failure)
		quit(1)


func _test_four_line_affordances_and_immutable_preview() -> void:
	var reducer := FourLine.new()
	var source: Dictionary = reducer.initial_state({"players": ["cyan", "violet"]})
	var source_copy := source.duplicate(true)
	var controller := TabletopInteractionController.new()
	var configured: Dictionary = controller.configure("connect four", reducer, source)
	_check(configured.ok and configured.module_id == "four_line", "Four Line alias did not configure")
	var legal: Dictionary = controller.legal_intents()
	_check(legal.ok and legal.intents.size() == 7, "Four Line did not expose seven legal opening columns")
	_check(legal.affordances.legal_columns == [0, 1, 2, 3, 4, 5, 6], "Four Line legal columns are not normalized")
	_check(int(legal.diagnostics.probe_count) == 7, "Four Line affordances were not reducer-probed")
	_check(_is_json_safe(legal), "legal intents exposed a non-JSON value")
	_check(source == source_copy, "configure or legal probing mutated the caller's state")

	var preview: Dictionary = controller.preview_intent(legal.intents[3])
	_check(preview.ok and preview.code == "preview_ready", "Four Line legal intent did not preview")
	_check(int(controller.committed_state().revision) == 0, "preview mutated the committed revision")
	_check(str(controller.committed_state().board[38]) == "", "preview mutated the committed board")
	_check(str(preview.state.board[38]) == "cyan", "preview state did not show the reducer landing")
	preview.state.board[38] = "tampered"
	_check(str(controller.pending_preview().state.board[38]) == "cyan", "preview response leaked a mutable pending-state reference")
	var duplicate_preview: Dictionary = controller.preview_action({"type": "drop", "actor": "cyan", "column": 2})
	_check(not duplicate_preview.ok and duplicate_preview.code == "preview_active", "controller allowed more than one pending preview")
	var cancelled: Dictionary = controller.cancel_preview()
	_check(cancelled.ok and int(cancelled.state.revision) == 0, "preview cancel did not preserve committed state")

	controller.preview_action({"type": "drop", "actor": "cyan", "column": 3})
	var committed: Dictionary = controller.commit_preview()
	_check(committed.ok and int(committed.state.revision) == 1, "Four Line preview did not commit exactly once")
	_check(str(committed.state.board[38]) == "cyan", "Four Line commit returned the wrong reducer state")
	var escaped := controller.committed_state()
	escaped.board[38] = "tampered"
	_check(str(controller.committed_state().board[38]) == "cyan", "committed_state leaked a mutable internal reference")

	# Fill column zero legally; the reducer remains the authority that removes it.
	var state := reducer.initial_state({"players": ["cyan", "violet"]})
	for move_index in range(6):
		var actor := "cyan" if move_index % 2 == 0 else "violet"
		var reduced: Dictionary = reducer.reduce(state, {"type": "drop", "actor": actor, "column": 0})
		state = reduced.state
	controller.configure("four_line", reducer, state)
	legal = controller.legal_intents()
	_check(0 not in legal.affordances.legal_columns and legal.intents.size() == 6, "full Four Line column remained interactive")


func _test_draughts_complete_capture_paths() -> void:
	var reducer := Draughts.new()
	var state: Dictionary = reducer.initial_state({"players": {"red": "rhea", "black": "blake"}})
	state.board.fill("")
	state.board[42] = "r"
	state.board[35] = "b"
	state.board[21] = "b"
	var controller := TabletopInteractionController.new()
	var configured: Dictionary = controller.configure("checkers", reducer, state)
	_check(configured.ok, "Draughts did not configure")
	var legal: Dictionary = controller.legal_intents()
	_check(legal.ok, "Draughts legal path enumeration failed")
	_check(legal.affordances.selectable_pieces == [42], "mandatory capture exposed the wrong selectable piece")
	_check(bool(legal.affordances.mandatory_capture), "mandatory capture flag was not exposed")
	_check(legal.intents.size() == 1 and legal.intents[0].target.path == [42, 28, 14], "Draughts did not expose the complete multi-capture path")
	_check(int(legal.intents[0].target.captures) == 2, "Draughts capture count is wrong")
	var partial: Dictionary = controller.preview_action({"type": "move", "actor": "rhea", "path": [42, 28]})
	_check(not partial.ok and partial.code == "capture_chain", "controller bypassed reducer enforcement for an incomplete capture chain")
	var preview: Dictionary = controller.preview_intent(legal.intents[0])
	_check(preview.ok and str(preview.state.board[14]) == "r", "complete draughts path did not preview")
	_check(str(controller.committed_state().board[42]) == "r", "draughts preview mutated committed state")
	var committed: Dictionary = controller.commit_preview()
	_check(committed.ok and int(committed.state.capture_count) == 2, "draughts multi-capture did not commit through reducer")
	_check(str(committed.state.board[35]) == "" and str(committed.state.board[21]) == "", "draughts commit retained captured pieces")


func _test_property_grid_phase_intents() -> void:
	var reducer := PropertyGrid.new()
	var state: Dictionary = reducer.initial_state({"players": ["nova", "quill"], "seed": 424242})
	var controller := TabletopInteractionController.new()
	controller.configure("monopoly", reducer, state)
	var legal: Dictionary = controller.legal_intents()
	_check(legal.ok and legal.affordances.legal_actions == ["roll"], "await_roll exposed the wrong Property Grid action")
	_check(legal.intents[0].action.type == "roll", "roll intent did not preserve reducer action type")
	var roll_preview: Dictionary = controller.preview_intent(legal.intents[0])
	_check(roll_preview.ok and int(controller.committed_state().rng_state) == int(state.rng_state), "roll preview consumed committed RNG state")
	var roll_commit: Dictionary = controller.commit_preview()
	_check(roll_commit.ok, "Property Grid roll preview did not commit")

	# A reducer-valid purchase state exposes UI `decline`, normalized to reducer `pass`.
	var purchase_state: Dictionary = reducer.initial_state({"players": ["nova", "quill"]})
	purchase_state.players[0].position = 1
	purchase_state.phase = "await_purchase"
	purchase_state.last_event = {"type": "property_available", "actor": "nova", "space": 1, "price": 100}
	controller.configure("property_grid", reducer, purchase_state)
	legal = controller.legal_intents()
	_check(legal.affordances.legal_actions == ["buy", "decline"], "purchase phase did not expose buy and decline")
	var decline_intent: Dictionary = legal.intents[1]
	_check(decline_intent.intent == "decline" and decline_intent.action.type == "pass", "decline was not normalized to the reducer pass action")
	var decline: Dictionary = controller.preview_intent(decline_intent)
	_check(decline.ok and decline.state.phase == "await_end", "decline intent did not preview reducer state")
	controller.commit_preview()
	legal = controller.legal_intents()
	_check(legal.affordances.legal_actions == ["end_turn"], "await_end did not expose only end_turn")


func _test_sanitization_and_module_guards() -> void:
	var reducer := FourLine.new()
	var state: Dictionary = reducer.initial_state()
	var controller := TabletopInteractionController.new()
	var mismatch: Dictionary = controller.configure("draughts", reducer, state)
	_check(not mismatch.ok and mismatch.code == "module_mismatch", "controller accepted a mismatched reducer")
	state["unsafe"] = Vector3.ONE
	var unsafe: Dictionary = controller.configure("four_line", reducer, state)
	_check(not unsafe.ok and unsafe.code == "state_sanitization", "controller accepted a non-JSON state value")
	state.erase("unsafe")
	controller.configure("four_line", reducer, state)
	var unsafe_intent: Dictionary = controller.preview_intent({"intent": "drop", "payload": {"column": Vector2.ZERO}})
	_check(not unsafe_intent.ok and unsafe_intent.code == "intent_sanitization", "controller accepted a non-JSON intent value")
	var wrong_actor: Dictionary = controller.legal_intents("intruder")
	_check(not wrong_actor.ok and wrong_actor.code == "actor_scope", "legal intent query accepted an out-of-turn actor scope")


func _test_forged_hash_receipts_are_rejected() -> void:
	var preview_module := FourLine.new()
	var preview_state: Dictionary = preview_module.initial_state({"players": ["cyan", "violet"]})
	var preview_reducer := ForgedReceiptReducer.new(preview_module, 1)
	var preview_controller := TabletopInteractionController.new()
	preview_controller.configure("four_line", preview_reducer, preview_state)
	var forged_preview: Dictionary = preview_controller.preview_action(
		{"type": "drop", "actor": "cyan", "column": 3}
	)
	_check(
		not forged_preview.ok and forged_preview.code == "reducer_hash_mismatch",
		"tabletop controller accepted a forged preview state_hash receipt"
	)
	_check(not preview_controller.has_preview(), "forged tabletop preview left pending state")
	_check(
		int(preview_controller.committed_state().revision) == 0
		and str(preview_controller.committed_state().board[38]) == "",
		"forged tabletop preview changed committed state"
	)

	var commit_module := FourLine.new()
	var commit_state: Dictionary = commit_module.initial_state({"players": ["cyan", "violet"]})
	var commit_reducer := ForgedReceiptReducer.new(commit_module, 2)
	var commit_controller := TabletopInteractionController.new()
	commit_controller.configure("four_line", commit_reducer, commit_state)
	var accepted_preview: Dictionary = commit_controller.preview_action(
		{"type": "drop", "actor": "cyan", "column": 3}
	)
	var forged_commit: Dictionary = commit_controller.commit_preview()
	_check(accepted_preview.ok, "tabletop forged-commit setup preview was unexpectedly rejected")
	_check(
		not forged_commit.ok and forged_commit.code == "reducer_hash_mismatch",
		"tabletop controller accepted a forged commit state_hash receipt"
	)
	_check(not commit_controller.has_preview(), "forged tabletop commit left pending state")
	_check(
		int(commit_controller.committed_state().revision) == 0
		and str(commit_controller.committed_state().board[38]) == "",
		"forged tabletop commit changed committed state"
	)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _is_json_safe(value: Variant, depth: int = 0) -> bool:
	if depth > 40:
		return false
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return true
		TYPE_FLOAT:
			return is_finite(float(value))
		TYPE_ARRAY:
			for item in value:
				if not _is_json_safe(item, depth + 1):
					return false
			return true
		TYPE_DICTIONARY:
			for key in value:
				if not key is String or not _is_json_safe(value[key], depth + 1):
					return false
			return true
	return false
