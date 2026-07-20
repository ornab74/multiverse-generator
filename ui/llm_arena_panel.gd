extends PanelContainer
class_name NexusLLMArenaPanel

## The single-player chess surface.  The reducer owns legality; the local
## model can only choose from the reducer's current allowlist.

const ChessCoreScript = preload("res://game_modules/chess_core.gd")
const AgentScript = preload("res://systems/llm_game_agent.gd")
const HistoryScript = preload("res://systems/chess_history.gd")
const BridgeScript = preload("res://systems/naza_dart_gemma_bridge.gd")
const BODY_FONT_PATH := "res://assets/fonts/InterVariable.ttf"
const DISPLAY_FONT_PATH := "res://assets/fonts/SpaceGroteskVariable.ttf"
const MONO_FONT_PATH := "res://assets/fonts/JetBrainsMonoVariable.ttf"

const TEXT := Color("#f2f6ff")
const MUTED := Color("#8c98ae")
const CYAN := Color("#64e8ff")
const VIOLET := Color("#a979ff")
const LIME := Color("#9bf59b")
const AMBER := Color("#ffca74")
const PANEL := Color("#0a111df2")
const LINE := Color("#2a3a55")
const LIGHT_SQUARE := Color("#dfe3e9")
const DARK_SQUARE := Color("#929dab")
const LEGAL_SQUARE := Color("#72b9ad")
const SELECTED_SQUARE := Color("#9b84c9")
const MAX_AGENT_ATTEMPTS := 3
const MAX_GAME_HISTORY := 512
const MOBILE_LAYOUT_BREAKPOINT := 900.0
const DESKTOP_CONTENT_MAX_WIDTH := 1160.0

signal navigate_requested(screen: String)

var bridge: Node
var body_font: FontFile
var display_font: FontFile
var mono_font: FontFile
var reducer: RefCounted
var state: Dictionary = {}
var history: Array[Dictionary] = []
var legal_actions: Array[Dictionary] = []
var selected_square := -1
var selected_destinations: Array[int] = []
var thinking := false
var game_over := false
var state_generation := 0
var session_id := ""
var pending_history_events: Array[Dictionary] = []
var history_flush_active := false
var autosave_pending := false
var autosave_active := false
var agent_preferences := {
	"memory_enabled": true,
	"skill_color": "yellow",
	"style_id": "adaptive",
	"player_side": "white",
}
var game_player_side := "white"

var board_grid: GridContainer
var board_card: PanelContainer
var side_panel: VBoxContainer
var desktop_body: HBoxContainer
var mobile_body: VBoxContainer
var outer_margin: MarginContainer
var board_margin: MarginContainer
var responsive_layout_active := false
var compact_layout_active := false
var square_buttons: Array[Button] = []
var chat_log: RichTextLabel
var chat_input: LineEdit
var status_label: Label
var turn_label: Label
var move_list: Label
var new_game_button: Button
var saved_games_button: Button
var settings_button: Button
var send_button: Button


func set_bridge(value: Node) -> void:
	bridge = value
	if is_inside_tree():
		_bind_bridge()


func set_agent_preferences(value: Dictionary) -> void:
	agent_preferences = AgentScript.normalized_preferences(value)


func _ready() -> void:
	body_font = load(BODY_FONT_PATH)
	display_font = load(DISPLAY_FONT_PATH)
	mono_font = load(MONO_FONT_PATH)
	var app_theme := Theme.new()
	app_theme.default_font = body_font
	app_theme.default_font_size = 13
	theme = app_theme
	add_theme_stylebox_override("panel", _panel(PANEL, 18, LINE, 1))
	if bridge == null:
		bridge = BridgeScript.new()
		bridge.set("auto_start", false)
		add_child(bridge)
	_bind_bridge()
	_build()
	get_viewport().size_changed.connect(_apply_responsive_layout)
	_new_game()
	call_deferred("_apply_responsive_layout")


func _bind_bridge() -> void:
	if bridge == null:
		return
	if bridge.has_signal("snapshot_changed") and not bridge.snapshot_changed.is_connected(_on_backend_snapshot):
		bridge.snapshot_changed.connect(_on_backend_snapshot)
	if bridge.has_signal("ready_changed") and not bridge.ready_changed.is_connected(_on_backend_ready):
		bridge.ready_changed.connect(_on_backend_ready)
	if bridge.has_signal("status_changed") and not bridge.status_changed.is_connected(_on_backend_status):
		bridge.status_changed.connect(_on_backend_status)
	if bridge.has_signal("progress_changed") and not bridge.progress_changed.is_connected(_on_backend_progress):
		bridge.progress_changed.connect(_on_backend_progress)
	if bridge.has_method("get_snapshot"):
		call_deferred("_on_backend_snapshot", bridge.get_snapshot())


func _build() -> void:
	outer_margin = MarginContainer.new()
	outer_margin.add_theme_constant_override("margin_left", 22)
	outer_margin.add_theme_constant_override("margin_right", 22)
	outer_margin.add_theme_constant_override("margin_top", 20)
	outer_margin.add_theme_constant_override("margin_bottom", 20)
	add_child(outer_margin)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer_margin.add_child(scroll)
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 14)
	scroll.add_child(root)

	var command_bar := HBoxContainer.new()
	command_bar.add_theme_constant_override("separation", 10)
	root.add_child(command_bar)
	var turn_stack := VBoxContainer.new()
	turn_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	turn_stack.add_theme_constant_override("separation", 0)
	command_bar.add_child(turn_stack)
	turn_label = Label.new()
	turn_label.text = "YOUR TURN  ·  WHITE"
	turn_label.add_theme_font_override("font", display_font)
	turn_label.add_theme_font_size_override("font_size", 17)
	turn_label.add_theme_color_override("font_color", CYAN)
	turn_stack.add_child(turn_label)
	new_game_button = _secondary_button("NEW GAME")
	new_game_button.custom_minimum_size.x = 122
	new_game_button.pressed.connect(_new_game)
	command_bar.add_child(new_game_button)
	settings_button = _icon_button("⚙", "Settings")
	settings_button.pressed.connect(func(): navigate_requested.emit("SETTINGS"))
	command_bar.add_child(settings_button)

	desktop_body = HBoxContainer.new()
	desktop_body.alignment = BoxContainer.ALIGNMENT_CENTER
	desktop_body.add_theme_constant_override("separation", 18)
	desktop_body.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	desktop_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(desktop_body)
	mobile_body = VBoxContainer.new()
	mobile_body.add_theme_constant_override("separation", 14)
	mobile_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mobile_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mobile_body.visible = false
	root.add_child(mobile_body)

	board_card = PanelContainer.new()
	board_card.custom_minimum_size = Vector2(720, 594)
	board_card.size_flags_horizontal = Control.SIZE_FILL
	board_card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	board_card.add_theme_stylebox_override("panel", _panel(Color("#0a111bf2"), 18, Color("#3a485c"), 1))
	desktop_body.add_child(board_card)
	board_margin = MarginContainer.new()
	board_margin.add_theme_constant_override("margin_left", 24)
	board_margin.add_theme_constant_override("margin_right", 24)
	board_margin.add_theme_constant_override("margin_top", 22)
	board_margin.add_theme_constant_override("margin_bottom", 18)
	board_card.add_child(board_margin)
	var board_col := VBoxContainer.new()
	board_col.alignment = BoxContainer.ALIGNMENT_CENTER
	board_col.add_theme_constant_override("separation", 12)
	board_margin.add_child(board_col)
	board_grid = GridContainer.new()
	board_grid.columns = 8
	board_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	board_grid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	board_grid.add_theme_constant_override("h_separation", 1)
	board_grid.add_theme_constant_override("v_separation", 1)
	board_col.add_child(board_grid)
	for square in range(64):
		var button := Button.new()
		button.custom_minimum_size = Vector2(73, 73)
		button.focus_mode = Control.FOCUS_NONE
		button.add_theme_font_size_override("font_size", 43)
		button.pressed.connect(_on_square_pressed.bind(square))
		board_grid.add_child(button)
		square_buttons.append(button)
	side_panel = VBoxContainer.new()
	side_panel.custom_minimum_size.x = 420
	side_panel.size_flags_horizontal = Control.SIZE_FILL
	side_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side_panel.add_theme_constant_override("separation", 10)
	desktop_body.add_child(side_panel)

	var chat_title := Label.new()
	chat_title.text = "Caissa"
	chat_title.add_theme_font_override("font", display_font)
	chat_title.add_theme_font_size_override("font_size", 18)
	chat_title.add_theme_color_override("font_color", TEXT)
	side_panel.add_child(chat_title)
	chat_log = RichTextLabel.new()
	chat_log.bbcode_enabled = true
	chat_log.fit_content = false
	chat_log.scroll_active = true
	chat_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chat_log.custom_minimum_size.y = 245
	chat_log.add_theme_font_override("normal_font", body_font)
	chat_log.add_theme_font_size_override("normal_font_size", 13)
	chat_log.add_theme_color_override("default_color", TEXT)
	var chat_style := _panel(Color("#080e19"), 12, LINE, 1)
	chat_style.content_margin_left = 16
	chat_style.content_margin_right = 16
	chat_style.content_margin_top = 12
	chat_style.content_margin_bottom = 12
	chat_log.add_theme_stylebox_override("normal", chat_style)
	side_panel.add_child(chat_log)

	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 8)
	chat_input = LineEdit.new()
	chat_input.placeholder_text = "Message Caissa…"
	chat_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat_input.text_submitted.connect(_send_chat)
	_style_input(chat_input)
	input_row.add_child(chat_input)
	send_button = _secondary_button("SEND")
	send_button.custom_minimum_size.x = 82
	send_button.pressed.connect(func(): _send_chat(chat_input.text))
	input_row.add_child(send_button)
	side_panel.add_child(input_row)

	var move_card := PanelContainer.new()
	move_card.add_theme_stylebox_override("panel", _panel(Color("#101a2a"), 12, LINE, 1))
	side_panel.add_child(move_card)
	var move_margin := MarginContainer.new()
	move_margin.add_theme_constant_override("margin_left", 12)
	move_margin.add_theme_constant_override("margin_right", 12)
	move_margin.add_theme_constant_override("margin_top", 10)
	move_margin.add_theme_constant_override("margin_bottom", 10)
	move_card.add_child(move_margin)
	var move_col := VBoxContainer.new()
	move_col.add_theme_constant_override("separation", 6)
	move_margin.add_child(move_col)
	move_col.add_child(_eyebrow("MOVE LOG", MUTED))
	move_list = Label.new()
	move_list.text = "No moves yet"
	move_list.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	move_list.custom_minimum_size.y = 70
	move_list.add_theme_font_override("font", mono_font)
	move_list.add_theme_font_size_override("font_size", 11)
	move_list.add_theme_color_override("font_color", TEXT)
	move_col.add_child(move_list)

	status_label = Label.new()
	status_label.text = "Your turn."
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_font_size_override("font_size", 10)
	status_label.add_theme_color_override("font_color", MUTED)
	side_panel.add_child(status_label)

	var footer := HBoxContainer.new()
	footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(footer)
	saved_games_button = _secondary_button("Saved Games")
	saved_games_button.custom_minimum_size.x = 142
	saved_games_button.pressed.connect(func(): navigate_requested.emit("SAVED GAMES"))
	footer.add_child(saved_games_button)


func _apply_responsive_layout() -> void:
	if responsive_layout_active or not is_instance_valid(board_card) or not is_instance_valid(side_panel) or not is_instance_valid(desktop_body) or not is_instance_valid(mobile_body):
		return
	responsive_layout_active = true
	var viewport_width := size.x if size.x > 1.0 else get_viewport_rect().size.x
	var compact := viewport_width < MOBILE_LAYOUT_BREAKPOINT
	_set_compact_layout(compact)
	var outer_space := 8 if compact else 22
	var board_space := 10 if compact else 24
	outer_margin.add_theme_constant_override("margin_left", outer_space)
	outer_margin.add_theme_constant_override("margin_right", outer_space)
	outer_margin.add_theme_constant_override("margin_top", 10 if compact else 20)
	outer_margin.add_theme_constant_override("margin_bottom", 10 if compact else 20)
	board_margin.add_theme_constant_override("margin_left", board_space)
	board_margin.add_theme_constant_override("margin_right", board_space)
	board_margin.add_theme_constant_override("margin_top", board_space)
	board_margin.add_theme_constant_override("margin_bottom", board_space)
	var available := maxf(viewport_width - float(outer_space * 2), 300.0)
	var square_size := 62.0
	if compact:
		square_size = clampf(floor((available - float(board_space * 2) - 7.0) / 8.0), 32.0, 54.0)
		board_card.custom_minimum_size = Vector2(available, square_size * 8.0 + float(board_space * 2) + 16.0)
		board_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		side_panel.custom_minimum_size = Vector2(available, 430.0)
		side_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chat_log.custom_minimum_size.y = 190.0
	else:
		var content_width := minf(DESKTOP_CONTENT_MAX_WIDTH, available)
		var side_width := clampf(content_width * 0.35, 360.0, 400.0)
		var board_width := content_width - side_width - 18.0
		desktop_body.custom_minimum_size.x = content_width
		board_card.custom_minimum_size = Vector2(board_width, 594.0)
		board_card.size_flags_horizontal = Control.SIZE_FILL
		side_panel.custom_minimum_size = Vector2(side_width, 594.0)
		side_panel.size_flags_horizontal = Control.SIZE_FILL
		chat_log.custom_minimum_size.y = 220.0
	for button in square_buttons:
		button.custom_minimum_size = Vector2(square_size, square_size)
		button.add_theme_font_size_override("font_size", clampi(int(square_size * 0.59), 23, 43))
	responsive_layout_active = false


func _set_compact_layout(compact: bool) -> void:
	var target: BoxContainer = mobile_body if compact else desktop_body
	if board_card.get_parent() != target:
		board_card.reparent(target)
		side_panel.reparent(target)
	desktop_body.visible = not compact
	mobile_body.visible = compact
	compact_layout_active = compact


func _new_game() -> void:
	if thinking:
		return
	state_generation += 1
	session_id = "game-%d" % Time.get_ticks_usec()
	reducer = ChessCoreScript.new()
	game_player_side = str(agent_preferences.get("player_side", "white"))
	if game_player_side not in ["white", "black"]:
		game_player_side = "white"
	var players := {"white": "YOU", "black": "CAISSA"}
	if game_player_side == "black":
		players = {"white": "CAISSA", "black": "YOU"}
	state = reducer.initial_state({"players": players})
	history.clear()
	legal_actions.clear()
	selected_square = -1
	selected_destinations.clear()
	game_over = false
	if is_instance_valid(chat_log):
		chat_log.text = "[color=#a979ff]CAISSA[/color]  New game ready. %s\n" % ("I’ll make the opening move." if game_player_side == "black" else "Make the first move when you’re ready.")
	_refresh_board()
	_refresh_controls()
	_schedule_autosave()
	if game_player_side == "black" and _backend_is_ready():
		call_deferred("_request_agent_turn")


func _on_square_pressed(square: int) -> void:
	if thinking or game_over or str(state.get("turn", "")) != game_player_side:
		return
	if game_player_side == "black":
		square = 63 - square
	var piece := str(state.get("board", [])[square])
	var player_prefix := "w" if game_player_side == "white" else "b"
	if selected_square < 0:
		if not piece.begins_with(player_prefix):
			_set_status("Choose one of your %s pieces." % game_player_side, AMBER)
			return
		_select_piece(square)
		return
	if square == selected_square:
		_clear_selection()
		return
	if piece.begins_with(player_prefix):
		_select_piece(square)
		return
	if square not in selected_destinations:
		_set_status("That destination is not legal for this piece.", AMBER)
		return
	var action := _action_for(selected_square, square, "YOU")
	var result: Dictionary = reducer.reduce(state, action)
	if not result.get("ok", false):
		_set_status("The reducer rejected the move: " + str(result.get("message", result.get("code", "invalid"))), AMBER)
		return
	_commit_state(result, "YOU", action)
	_clear_selection()
	if not game_over and str(state.get("turn", "")) == _agent_side():
		_request_agent_turn()


func _select_piece(square: int) -> void:
	selected_square = square
	selected_destinations.clear()
	for action in _legal_actions_for_piece(state, square, "YOU"):
		selected_destinations.append(int(action.to))
	_refresh_board()


func _clear_selection() -> void:
	selected_square = -1
	selected_destinations.clear()
	_refresh_board()


func _request_agent_turn() -> void:
	if thinking or game_over or not _backend_is_ready():
		if not _backend_is_ready():
			_set_status("Caissa is still starting. Open Settings for details.", AMBER)
		return
	var agent_side := _agent_side()
	if str(state.get("turn", "")) != agent_side:
		_set_status("It is your turn.", MUTED)
		return
	var actions := _legal_actions_for_side(state, agent_side, "CAISSA")
	if actions.is_empty():
		_finish_game()
		return
	thinking = true
	var request_generation := state_generation
	var request_revision := int(state.get("revision", 0))
	_refresh_controls()
	_set_status("Caissa is considering one of %d legal moves…" % actions.size(), VIOLET)
	var position_memory: Array = []
	var current_vector: Array[float] = AgentScript.position_vector(state, history)
	if bool(agent_preferences.get("memory_enabled", true)) and bridge.has_method("request_history"):
		var memory_result: Dictionary = await bridge.request_history({
			"operation": "recall_moves",
			"session_id": session_id,
			"position_vector": current_vector,
			"limit": 16,
		})
		if memory_result.get("ok", false) and memory_result.get("items", null) is Array:
			position_memory = Array(memory_result.items).duplicate(true)
	if request_generation != state_generation or int(state.get("revision", 0)) != request_revision:
		thinking = false
		_refresh_controls()
		return
	var prompt_options := {
		"persona": "Caissa",
		"player_side": game_player_side,
		"memory_enabled": bool(agent_preferences.get("memory_enabled", true)),
		"skill_color": str(agent_preferences.get("skill_color", "yellow")),
		"style_id": str(agent_preferences.get("style_id", "adaptive")),
		"memory_records": position_memory,
	}
	var parsed: Dictionary = {}
	var last_rejection := ""
	var transport_failure: Dictionary = {}
	var avoided_moves: Array[String] = AgentScript.repetition_cycle_moves(history)
	var alternatives := 0
	for legal_action_variant in actions:
		if legal_action_variant is Dictionary and HistoryScript.uci_for_action(legal_action_variant) not in avoided_moves:
			alternatives += 1
	for attempt in range(MAX_AGENT_ATTEMPTS):
		prompt_options["invalid_reply"] = last_rejection
		var prompt := AgentScript.build_opponent_prompt(state, actions, history, prompt_options)
		var request_payload := {
			"schema": "naza.chess-llm/1",
			"game_id": "chess_core",
			"prompt": prompt,
			"state": state,
			"max_output_tokens": 32,
		}
		request_payload.merge(AgentScript.sampling_options(prompt_options), true)
		var result: Dictionary = await bridge.request_turn(request_payload)
		if request_generation != state_generation or int(state.get("revision", 0)) != request_revision:
			thinking = false
			_refresh_controls()
			return
		if not result.get("ok", false):
			transport_failure = result
			break
		parsed = AgentScript.parse_response(str(result.get("text", "")), actions, "opponent")
		if parsed.get("ok", false):
			var proposed_uci := str(parsed.get("uci", ""))
			if proposed_uci in avoided_moves and alternatives > 0:
				last_rejection = "repetition_cycle:" + proposed_uci
				parsed = {"ok": false, "code": "repetition_cycle"}
				continue
			break
		last_rejection = "%s:%s" % [str(parsed.get("code", "invalid")), str(result.get("text", "")).left(64)]
	if not transport_failure.is_empty():
		thinking = false
		_set_status("Caissa is unavailable: " + str(transport_failure.get("error", transport_failure.get("code", "request unavailable"))), AMBER)
		_refresh_controls()
		return
	var policy_recovery := false
	if not parsed.get("ok", false):
		parsed = AgentScript.select_policy_move(state, actions, history, prompt_options)
		policy_recovery = parsed.get("ok", false)
	if not parsed.get("ok", false):
		thinking = false
		_set_status("No reducer-approved move could be selected.", AMBER)
		_refresh_controls()
		return
	var action: Dictionary = Dictionary(parsed.get("action", {})).duplicate(true)
	var verified: Dictionary = reducer.reduce(state, action)
	if not verified.get("ok", false):
		thinking = false
		_set_status("Caissa’s move was rejected by the reducer and was not played.", AMBER)
		_refresh_controls()
		return
	_commit_state(verified, "CAISSA", action)
	var move_text := HistoryScript.uci_for_action(action).to_upper()
	_append_chat("CAISSA", move_text + ("  ·  reducer-safe recovery" if policy_recovery else ""))
	thinking = false
	if not game_over:
		_set_status("Your turn · %s." % game_player_side.capitalize(), CYAN)
	_refresh_controls()


func _send_chat(text: String) -> void:
	var message := text.strip_edges()
	if message.is_empty() or thinking:
		return
	if not _backend_is_ready():
		_set_status("Caissa is still starting. Open Settings for details.", AMBER)
		return
	chat_input.clear()
	_append_chat("YOU", message)
	thinking = true
	_refresh_controls()
	_set_status("Caissa is replying from the current position…", VIOLET)
	var actions := _legal_actions_for_side(state, str(state.get("turn", "white")), str(state.get("players", {}).get(str(state.get("turn", "white")), "")))
	var prompt := AgentScript.build_chat_prompt(state, actions, history, message, {
		"persona": "Caissa",
		"style": "warm, precise, and conversational",
		"player_side": game_player_side,
	})
	var result: Dictionary = await bridge.request_chat({
		"schema": "naza.chess-llm/1",
		"game_id": "chess_core",
		"prompt": prompt,
		"state": state,
	})
	if result.get("ok", false):
		var parsed: Dictionary = AgentScript.parse_response(str(result.get("text", "")), actions, "chat")
		var reply := str(parsed.get("message", "")) if parsed.get("ok", false) else str(result.get("text", ""))
		_append_chat("CAISSA", reply if not reply.is_empty() else "I’m here. Ask me about the position or your last move.")
		_set_status("Chat active · board unchanged", CYAN)
	else:
		_append_chat("CAISSA", "I’m offline right now. The message stayed local.")
		_set_status("Chat unavailable: " + str(result.get("code", "request unavailable")), AMBER)
	thinking = false
	_refresh_controls()


func _legal_actions_for_side(position: Dictionary, side: String, actor: String) -> Array[Dictionary]:
	var actions: Array[Dictionary] = []
	var board: Array = position.get("board", [])
	if board.size() != 64:
		return actions
	var prefix := "w" if side == "white" else "b"
	for from_square in range(64):
		if not str(board[from_square]).begins_with(prefix):
			continue
		actions.append_array(_legal_actions_for_piece(position, from_square, actor))
	return actions


func _legal_actions_for_piece(position: Dictionary, from_square: int, actor: String) -> Array[Dictionary]:
	var actions: Array[Dictionary] = []
	var board: Array = position.get("board", [])
	if from_square < 0 or from_square >= board.size():
		return actions
	for to_square in range(64):
		var action := _action_for(from_square, to_square, actor)
		var result: Dictionary = reducer.reduce(position, action)
		if result.get("ok", false):
			actions.append(action)
	return actions


func _action_for(from_square: int, to_square: int, actor: String) -> Dictionary:
	return {
		"type": "move",
		"actor": actor,
		"from": from_square,
		"to": to_square,
		"expected_revision": int(state.get("revision", 0)),
		"expected_state_hash": reducer.state_hash(state),
	}


func _commit_state(result: Dictionary, actor: String, action: Dictionary) -> void:
	var before := state.duplicate(true)
	var move_vector: Array[float] = AgentScript.position_vector(before, history)
	var entropy := AgentScript.rgb_quantum_state(
		move_vector,
		str(agent_preferences.get("skill_color", "yellow")),
		str(agent_preferences.get("style_id", "adaptive"))
	)
	state = Dictionary(result.get("state", state)).duplicate(true)
	var record := {
		"ply": history.size() + 1,
		"side": str(before.get("turn", "")),
		"uci": HistoryScript.uci_for_action(action),
		"algebraic": HistoryScript.algebraic_for_action(before, action, state),
		"actor": actor,
		"state_hash": str(result.get("state_hash", reducer.state_hash(state))),
	}
	history.append(record)
	if history.size() > MAX_GAME_HISTORY:
		history.pop_front()
	_refresh_board()
	_update_move_log()
	var move_event := {
		"operation": "append_move",
		"session_id": session_id,
		"ply": int(record.ply),
		"actor": str(record.actor),
		"uci": str(record.uci),
		"algebraic": str(record.algebraic),
		"state_hash": str(record.state_hash),
	}
	if bool(agent_preferences.get("memory_enabled", true)):
		move_event.merge({
			"position_vector": move_vector,
			"quantum_state": str(entropy.quantum_state),
			"skill_color": str(agent_preferences.get("skill_color", "yellow")),
			"style_id": str(agent_preferences.get("style_id", "adaptive")),
		}, true)
	_queue_history_event(move_event)
	_schedule_autosave()
	if str(state.get("status", "active")) != "active":
		_finish_game()


func _finish_game() -> void:
	if game_over:
		return
	game_over = true
	var result := str(state.get("result", "game complete"))
	if bool(agent_preferences.get("memory_enabled", true)):
		_queue_history_event({
			"operation": "finalize_game",
			"session_id": session_id,
			"result": result,
			"winner": str(state.get("winner", "")),
		})
	_set_status("Game complete · " + result, LIME)
	_append_chat("CAISSA", "That position is complete: " + result + ". Start a new game whenever you’re ready.")


func _refresh_board() -> void:
	if not is_instance_valid(board_grid) or state.is_empty():
		return
	var board: Array = state.get("board", [])
	for display_square in range(mini(square_buttons.size(), 64)):
		var square := display_square if game_player_side == "white" else 63 - display_square
		var button := square_buttons[display_square]
		var code := str(board[square]) if square < board.size() else ""
		button.text = _piece_glyph(code)
		button.tooltip_text = HistoryScript.square_name(square) + (" · " + _piece_name(code) if not code.is_empty() else "")
		button.disabled = thinking or game_over or str(state.get("turn", "")) != game_player_side
		var color := LIGHT_SQUARE if ((square % 8) + (square / 8)) % 2 == 0 else DARK_SQUARE
		if square == selected_square:
			color = SELECTED_SQUARE
		elif square in selected_destinations:
			color = LEGAL_SQUARE
		var border := CYAN if square == selected_square else (LIME if square in selected_destinations else color)
		button.add_theme_stylebox_override("normal", _square_style(color, border, 2 if square == selected_square or square in selected_destinations else 0))
		button.add_theme_stylebox_override("hover", _square_style(color.lightened(0.10), border, 2))
		button.add_theme_stylebox_override("pressed", _square_style(color.darkened(0.08), border, 2))
		button.add_theme_stylebox_override("disabled", _square_style(color, border, 2 if square == selected_square or square in selected_destinations else 0))
		var piece_color := Color("#fffdf6") if code.begins_with("w") else Color("#18212d")
		var piece_outline := Color("#263241") if code.begins_with("w") else Color("#f4f7fb")
		button.add_theme_color_override("font_color", piece_color)
		button.add_theme_color_override("font_hover_color", piece_color)
		button.add_theme_color_override("font_pressed_color", piece_color)
		button.add_theme_color_override("font_disabled_color", piece_color)
		button.add_theme_color_override("font_outline_color", piece_outline)
		button.add_theme_color_override("font_shadow_color", Color("#00000055"))
		button.add_theme_constant_override("outline_size", 5 if code.begins_with("w") else 4)
		button.add_theme_constant_override("shadow_offset_x", 0)
		button.add_theme_constant_override("shadow_offset_y", 2)
	if is_instance_valid(turn_label):
		var turn := str(state.get("turn", "white"))
		turn_label.text = ("YOUR TURN  ·  %s" % game_player_side.to_upper() if turn == game_player_side else "CAISSA THINKING  ·  %s" % _agent_side().to_upper()) if not game_over else "GAME COMPLETE"
		turn_label.add_theme_color_override("font_color", CYAN if turn == game_player_side else VIOLET)


func _refresh_controls() -> void:
	if is_instance_valid(new_game_button):
		new_game_button.disabled = thinking
	if is_instance_valid(send_button):
		send_button.disabled = thinking or not _backend_is_ready()
	if is_instance_valid(chat_input):
		chat_input.editable = not thinking and _backend_is_ready()
	# _commit_state() can run while thinking is still true for the AI move.  A
	# final repaint here is required to re-enable the white squares after the
	# state changes back to the player's turn.
	_refresh_board()


func _update_move_log() -> void:
	if not is_instance_valid(move_list):
		return
	var lines: Array[String] = []
	for record in history.slice(maxi(0, history.size() - 8), history.size()):
		lines.append("%02d  %s  %s" % [int(record.get("ply", 0)), str(record.get("actor", "")), str(record.get("algebraic", record.get("uci", "")))])
	move_list.text = "\n".join(lines) if not lines.is_empty() else "No moves yet"


func _append_chat(speaker: String, message: String) -> void:
	if not is_instance_valid(chat_log):
		return
	var safe := str(message).replace("[", "［").replace("]", "］").strip_edges()
	chat_log.append_text("[color=#%s]%s[/color]  %s\n" % [("64e8ff" if speaker == "YOU" else "a979ff"), speaker, safe])
	chat_log.scroll_to_line(chat_log.get_line_count())
	_queue_history_event({
		"operation": "append_conversation",
		"session_id": session_id,
		"speaker": speaker,
		"message": str(message).strip_edges(),
	})


func _on_backend_snapshot(snapshot: Dictionary) -> void:
	var ready := bool(snapshot.get("ready", false))
	_refresh_controls()
	if ready:
		call_deferred("_flush_history_events")
		call_deferred("_flush_autosave")


func _on_backend_ready(ready: bool, _detail: String) -> void:
	if not ready:
		_set_status("Caissa is unavailable. Open Settings to reconnect.", AMBER)
	_refresh_controls()
	if ready and not thinking and not game_over and str(state.get("turn", "")) == _agent_side():
		call_deferred("_request_agent_turn")


func _on_backend_status(status: String, _detail: String) -> void:
	if status in ["failed", "stopped"]:
		_set_status("Caissa is unavailable. Open Settings to reconnect.", AMBER)
	_refresh_controls()


func _on_backend_progress(_progress: int, _phase: String) -> void:
	pass


func _set_status(message: String, color: Color) -> void:
	if is_instance_valid(status_label):
		status_label.text = message
		status_label.add_theme_color_override("font_color", color)


func _backend_is_ready() -> bool:
	return bridge != null and bool(bridge.get("is_ready"))


func _queue_history_event(event: Dictionary) -> void:
	if session_id.is_empty() or event.is_empty():
		return
	pending_history_events.append(event.duplicate(true))
	while pending_history_events.size() > 256:
		pending_history_events.pop_front()
	if _backend_is_ready():
		call_deferred("_flush_history_events")


func _flush_history_events() -> void:
	if history_flush_active or pending_history_events.is_empty() or not _backend_is_ready():
		return
	if not bridge.has_method("request_history"):
		pending_history_events.clear()
		return
	history_flush_active = true
	while not pending_history_events.is_empty() and _backend_is_ready():
		var result: Dictionary = await bridge.request_history(pending_history_events[0])
		var code := str(result.get("code", ""))
		if not result.get("ok", false) and code in ["backend_request_busy", "inference_request_busy"]:
			break
		pending_history_events.pop_front()
	history_flush_active = false


func _schedule_autosave() -> void:
	autosave_pending = true
	if _backend_is_ready():
		call_deferred("_flush_autosave")


func _flush_autosave() -> void:
	if autosave_active or not autosave_pending or not _backend_is_ready():
		return
	if not bridge.has_method("request_games"):
		return
	autosave_active = true
	while autosave_pending and _backend_is_ready():
		autosave_pending = false
		var result: Dictionary = await bridge.request_games(_game_save_payload("active-game", "Current game"))
		var code := str(result.get("code", ""))
		if not result.get("ok", false) and code in ["backend_request_busy", "inference_request_busy"]:
			autosave_pending = true
			break
	autosave_active = false


func _game_save_payload(game_id: String, name: String) -> Dictionary:
	return {
		"operation": "save_game",
		"game_id": game_id,
		"name": name,
		"session_id": session_id,
		"state": state.duplicate(true),
		"history": history.duplicate(true),
	}


func save_game(name: String) -> Dictionary:
	if thinking:
		return {"ok": false, "code": "game_busy", "error": "Wait for Caissa to finish the current turn."}
	if not _backend_is_ready():
		return {"ok": false, "code": "backend_not_ready", "error": "The local backend is not ready."}
	var clean_name := name.strip_edges()
	if clean_name.is_empty():
		clean_name = "Chess game"
	var result: Dictionary = await bridge.request_games(_game_save_payload(session_id, clean_name))
	if result.get("ok", false):
		_set_status("Saved game · %s" % clean_name, LIME)
	return result


func load_game(game_id: String) -> Dictionary:
	if thinking:
		return {"ok": false, "code": "game_busy", "error": "Wait for Caissa to finish the current turn."}
	if not _backend_is_ready():
		return {"ok": false, "code": "backend_not_ready", "error": "The local backend is not ready."}
	var result: Dictionary = await bridge.request_games({
		"operation": "load_game",
		"game_id": game_id,
	})
	if not result.get("ok", false):
		return result
	var payload := Dictionary(result.get("game", {}))
	var rebuilt := _rebuild_saved_game(payload)
	if not rebuilt.get("ok", false):
		return rebuilt
	state = Dictionary(rebuilt.state).duplicate(true)
	game_player_side = "black" if str(state.get("players", {}).get("black", "")) == "YOU" else "white"
	history.clear()
	for record_variant in Array(rebuilt.history):
		history.append(Dictionary(record_variant).duplicate(true))
	session_id = str(rebuilt.session_id)
	selected_square = -1
	selected_destinations.clear()
	game_over = str(state.get("status", "active")) != "active"
	_refresh_board()
	_update_move_log()
	_refresh_controls()
	_set_status("Loaded game · %s" % str(rebuilt.name), LIME)
	_schedule_autosave()
	if not game_over and str(state.get("turn", "")) == _agent_side():
		call_deferred("_request_agent_turn")
	return {"ok": true, "code": "game_loaded"}


func _agent_side() -> String:
	return "black" if game_player_side == "white" else "white"


func _rebuild_saved_game(payload: Dictionary) -> Dictionary:
	var loaded_state := Dictionary(payload.get("state", {})).duplicate(true)
	var loaded_history: Array = Array(payload.get("history", [])).duplicate(true)
	var players := Dictionary(loaded_state.get("players", {}))
	if loaded_state.is_empty() or players.is_empty() or not loaded_state.get("board", []) is Array:
		return {"ok": false, "code": "game_state_invalid", "error": "The saved position is malformed."}
	var replay_reducer := ChessCoreScript.new()
	var replay_state: Dictionary = replay_reducer.initial_state({"players": players})
	for record_variant in loaded_history:
		if not record_variant is Dictionary:
			return {"ok": false, "code": "game_history_invalid", "error": "The saved move history is malformed."}
		var record: Dictionary = record_variant
		var action := _action_from_uci(str(record.get("uci", "")), str(record.get("actor", "")), replay_state)
		if action.is_empty():
			return {"ok": false, "code": "game_history_invalid", "error": "A saved move could not be reconstructed."}
		var receipt: Dictionary = replay_reducer.reduce(replay_state, action)
		if not receipt.get("ok", false):
			return {"ok": false, "code": "game_history_invalid", "error": "The saved move history failed reducer replay."}
		if str(record.get("state_hash", "")) != str(receipt.get("state_hash", "")):
			return {"ok": false, "code": "game_history_invalid", "error": "A saved reducer receipt does not match replay."}
		replay_state = Dictionary(receipt.state).duplicate(true)
	if replay_reducer.state_hash(replay_state) != replay_reducer.state_hash(loaded_state):
		return {"ok": false, "code": "game_state_invalid", "error": "The saved position does not match its reducer history."}
	return {
		"ok": true,
		"state": loaded_state,
		"history": loaded_history,
		"session_id": str(payload.get("session_id", "")),
		"name": str(payload.get("name", "Chess game")),
	}


func _action_from_uci(uci: String, actor: String, position: Dictionary) -> Dictionary:
	var clean := uci.strip_edges().to_lower()
	if clean.length() < 4 or clean.length() > 5:
		return {}
	var from_square := _square_from_name(clean.substr(0, 2))
	var to_square := _square_from_name(clean.substr(2, 2))
	if from_square < 0 or to_square < 0:
		return {}
	var action := {
		"type": "move",
		"actor": actor,
		"from": from_square,
		"to": to_square,
		"expected_revision": int(position.get("revision", 0)),
		"expected_state_hash": reducer.state_hash(position),
	}
	if clean.length() == 5:
		action["promotion"] = clean.substr(4, 1).to_upper()
	return action


func _square_from_name(value: String) -> int:
	if value.length() != 2:
		return -1
	var file_index := "abcdefgh".find(value.substr(0, 1))
	var rank := int(value.substr(1, 1))
	if file_index < 0 or rank < 1 or rank > 8:
		return -1
	return (8 - rank) * 8 + file_index


func _piece_glyph(code: String) -> String:
	return {
		"wK": "♚", "wQ": "♛", "wR": "♜", "wB": "♝", "wN": "♞", "wP": "♟",
		"bK": "♚", "bQ": "♛", "bR": "♜", "bB": "♝", "bN": "♞", "bP": "♟",
	}.get(code, "")


func _piece_name(code: String) -> String:
	return {
		"K": "King", "Q": "Queen", "R": "Rook", "B": "Bishop", "N": "Knight", "P": "Pawn",
	}.get(code.substr(1, 1), "Piece")


func _panel(color: Color, radius: int, border: Color, width: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	style.border_color = border
	style.set_border_width_all(width)
	style.shadow_color = Color("#00000066")
	style.shadow_size = 8
	style.anti_aliasing = true
	return style


func _square_style(color: Color, border: Color, width: int) -> StyleBoxFlat:
	var style := _panel(color, 4, border, width)
	style.shadow_size = 0
	style.shadow_color = Color.TRANSPARENT
	return style


func _eyebrow(text: String, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", display_font)
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", color)
	return label


func _secondary_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 44
	button.add_theme_font_override("font", display_font)
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_hover_color", TEXT)
	button.add_theme_color_override("font_pressed_color", TEXT)
	button.add_theme_color_override("font_disabled_color", Color("#647083"))
	button.add_theme_stylebox_override("normal", _button_style(Color("#182435"), Color("#394a61"), 1))
	button.add_theme_stylebox_override("hover", _button_style(Color("#23334a"), Color("#75deea"), 1))
	button.add_theme_stylebox_override("pressed", _button_style(Color("#111b29"), Color("#75deea"), 1))
	button.add_theme_stylebox_override("disabled", _button_style(Color("#101722"), Color("#253044"), 1))
	return button


func _icon_button(glyph: String, tooltip: String) -> Button:
	var button := Button.new()
	button.text = glyph
	button.tooltip_text = tooltip
	button.custom_minimum_size = Vector2(48, 44)
	button.focus_mode = Control.FOCUS_ALL
	button.add_theme_font_size_override("font_size", 22)
	button.add_theme_color_override("font_color", Color("#eaf0f8"))
	button.add_theme_color_override("font_hover_color", Color("#ffffff"))
	button.add_theme_color_override("font_pressed_color", CYAN)
	button.add_theme_stylebox_override("normal", _button_style(Color("#182435"), Color("#394a61"), 1))
	button.add_theme_stylebox_override("hover", _button_style(Color("#23334a"), Color("#75deea"), 1))
	button.add_theme_stylebox_override("pressed", _button_style(Color("#111b29"), Color("#75deea"), 1))
	return button


func _style_input(input: LineEdit) -> void:
	input.add_theme_font_override("font", body_font)
	input.add_theme_font_size_override("font_size", 13)
	input.add_theme_color_override("font_color", TEXT)
	input.add_theme_color_override("font_placeholder_color", MUTED)
	input.add_theme_stylebox_override("normal", _button_style(Color("#0c1420"), Color("#34445b"), 1))
	input.add_theme_stylebox_override("focus", _button_style(Color("#101b2a"), Color("#75deea"), 2))


func _button_style(color: Color, border: Color, width: int) -> StyleBoxFlat:
	var style := _panel(color, 12, border, width)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.shadow_color = Color("#00000080")
	style.shadow_size = 10
	style.shadow_offset = Vector2(0, 3)
	return style
