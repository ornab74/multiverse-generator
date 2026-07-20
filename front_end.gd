extends CanvasLayer
class_name NexusFrontEnd

## Minimal shell for the AI chess product.  Godot owns the one Flutter sidecar
## for the lifetime of this surface; the settings page controls that owned PID.

const ArenaScript = preload("res://ui/llm_arena_panel.gd")
const BridgeScript = preload("res://systems/naza_dart_gemma_bridge.gd")
const AgentScript = preload("res://systems/llm_game_agent.gd")
const BODY_FONT_PATH := "res://assets/fonts/InterVariable.ttf"
const DISPLAY_FONT_PATH := "res://assets/fonts/SpaceGroteskVariable.ttf"
const MONO_FONT_PATH := "res://assets/fonts/JetBrainsMonoVariable.ttf"

const INK := Color("#050812")
const PANEL := Color("#0b1220f2")
const LINE := Color("#2a3a55")
const TEXT := Color("#f2f6ff")
const MUTED := Color("#8c98ae")
const CYAN := Color("#64e8ff")
const VIOLET := Color("#a979ff")
const LIME := Color("#9bf59b")
const AMBER := Color("#ffca74")

signal enter_game(request: Dictionary)
signal presentation_settings_changed(settings: Dictionary)
signal ui_surface_rebuilt(root_node: Node)

var root: Control
var body_font: FontFile
var display_font: FontFile
var mono_font: FontFile
var screen_content: Control
var play_panel: NexusLLMArenaPanel
var backend: Node
var current_screen := "PLAY"
var settings_page: Control
var saved_games_page: Control
var loading_page: Control
var loading_card: PanelContainer
var loading_spinner: Label
var loading_status: Label
var loading_detail: Label
var loading_progress: ProgressBar
var loading_tween: Tween
var settings_status: Label
var settings_detail: Label
var port_input: LineEdit
var model_input: LineEdit
var start_button: Button
var stop_button: Button
var test_button: Button
var restart_button: Button
var install_model_button: Button
var game_name_input: LineEdit
var saved_games_list: VBoxContainer
var saved_games_status: Label
var saved_refresh_active := false
var memory_toggle: CheckButton
var skill_option: OptionButton
var style_option: OptionButton
var side_option: OptionButton
var skill_swatch: ColorRect
var agent_profile_detail: Label
var agent_preferences := {
	"memory_enabled": true,
	"skill_color": "yellow",
	"style_id": "adaptive",
	"player_side": "white",
}
var preferences_loaded := false
var preferences_request_active := false
var preferences_save_pending := false
var previous_focus: Control
var presentation_settings := {
	"master_volume": 0.74,
	"music": 0.62,
	"ui_effects": 0.88,
	"reduced_motion": false,
	"high_contrast_targets": true,
}


func _ready() -> void:
	layer = 20
	body_font = load(BODY_FONT_PATH)
	display_font = load(DISPLAY_FONT_PATH)
	mono_font = load(MONO_FONT_PATH)
	backend = BridgeScript.new()
	backend.set("auto_start", OS.get_environment("NEXUS_BACKEND_AUTOSTART") != "0")
	add_child(backend)
	_build_shell()
	_show_screen("PLAY")
	if backend.has_signal("snapshot_changed"):
		backend.snapshot_changed.connect(_on_backend_snapshot)
	if backend.has_signal("ready_changed"):
		backend.ready_changed.connect(_on_backend_ready)
	if backend.has_signal("status_changed"):
		backend.status_changed.connect(_on_backend_status)
	if backend.has_signal("progress_changed"):
		backend.progress_changed.connect(_on_backend_progress)
	call_deferred("_sync_backend_snapshot")
	if OS.get_environment("NEXUS_SETTINGS") == "1":
		call_deferred("_show_screen", "SETTINGS")


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if current_screen in ["SETTINGS", "SAVED GAMES"]:
			_show_screen("PLAY")
			get_viewport().set_input_as_handled()


func open(screen := "PLAY") -> void:
	visible = true
	_show_screen("PLAY" if screen in ["HOME", "ARENA", "PLAY"] else screen)
	presentation_settings_changed.emit(presentation_settings.duplicate(true))


func get_presentation_settings() -> Dictionary:
	return presentation_settings.duplicate(true)


func close_to_game(request: Variant = "resume") -> void:
	var payload: Dictionary = request if request is Dictionary else {"action": str(request)}
	enter_game.emit(payload)


func _build_shell() -> void:
	root = Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var app_theme := Theme.new()
	app_theme.default_font = body_font
	app_theme.default_font_size = 13
	root.theme = app_theme
	add_child(root)
	root.resized.connect(_layout_shell)
	var background := TextureRect.new()
	var background_gradient := Gradient.new()
	background_gradient.colors = PackedColorArray([Color("#05070d"), Color("#0a111c"), Color("#101827")])
	background_gradient.offsets = PackedFloat32Array([0.0, 0.48, 1.0])
	var background_texture := GradientTexture2D.new()
	background_texture.gradient = background_gradient
	background_texture.width = 1440
	background_texture.height = 900
	background_texture.fill_from = Vector2(0.08, 0.0)
	background_texture.fill_to = Vector2(0.92, 1.0)
	background.texture = background_texture
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(background)
	var glow := ColorRect.new()
	glow.color = Color("#26395a20")
	glow.position = Vector2(0, 0)
	glow.size = Vector2(1440, 900)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(glow)
	screen_content = Control.new()
	screen_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(screen_content)
	call_deferred("_layout_shell")


func _show_screen(screen: String) -> void:
	current_screen = screen if screen in ["PLAY", "SAVED GAMES", "SETTINGS"] else "PLAY"
	if current_screen == "PLAY":
		if _backend_is_ready():
			if loading_tween and loading_tween.is_valid():
				loading_tween.kill()
			if is_instance_valid(loading_page):
				loading_page.visible = false
			if not is_instance_valid(play_panel):
				play_panel = ArenaScript.new()
				play_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
				play_panel.offset_left = 16
				play_panel.offset_top = 14
				play_panel.offset_right = -16
				play_panel.offset_bottom = -14
				play_panel.set_bridge(backend)
				play_panel.set_agent_preferences(agent_preferences)
				play_panel.navigate_requested.connect(_show_screen)
				screen_content.add_child(play_panel)
			play_panel.visible = true
		else:
			if is_instance_valid(play_panel):
				play_panel.visible = false
			if not is_instance_valid(loading_page):
				_build_loading_page()
			loading_page.visible = true
		if is_instance_valid(settings_page):
			settings_page.visible = false
		if is_instance_valid(saved_games_page):
			saved_games_page.visible = false
	elif current_screen == "SETTINGS":
		if not is_instance_valid(settings_page):
			_build_settings_page()
		settings_page.visible = true
		if is_instance_valid(play_panel):
			play_panel.visible = false
		if is_instance_valid(saved_games_page):
			saved_games_page.visible = false
		if is_instance_valid(loading_page):
			loading_page.visible = false
	else:
		if not is_instance_valid(saved_games_page):
			_build_saved_games_page()
		saved_games_page.visible = true
		if is_instance_valid(play_panel):
			play_panel.visible = false
		if is_instance_valid(settings_page):
			settings_page.visible = false
		if is_instance_valid(loading_page):
			loading_page.visible = false
		_refresh_saved_games()
	ui_surface_rebuilt.emit(screen_content)


func _build_loading_page() -> void:
	loading_page = Control.new()
	loading_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen_content.add_child(loading_page)
	loading_card = PanelContainer.new()
	loading_card.set_anchors_preset(Control.PRESET_CENTER)
	loading_card.add_theme_stylebox_override("panel", _panel(PANEL, 20, LINE, 1))
	loading_page.add_child(loading_card)
	var margin := _margin(34, 30, 34, 30)
	loading_card.add_child(margin)
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 14)
	margin.add_child(col)
	var eyebrow := _eyebrow("NEXUS / LOCAL MODEL STARTUP", CYAN)
	eyebrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(eyebrow)
	loading_spinner = Label.new()
	loading_spinner.text = "♞"
	loading_spinner.custom_minimum_size = Vector2(100, 100)
	loading_spinner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading_spinner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	loading_spinner.pivot_offset = Vector2(50, 50)
	loading_spinner.add_theme_font_size_override("font_size", 76)
	loading_spinner.add_theme_color_override("font_color", CYAN)
	col.add_child(loading_spinner)
	loading_tween = create_tween().set_loops().set_trans(Tween.TRANS_LINEAR)
	loading_tween.tween_property(loading_spinner, "rotation", TAU, 1.7)
	var title := Label.new()
	title.text = "Warming Caissa"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", TEXT)
	col.add_child(title)
	loading_status = Label.new()
	loading_status.text = "LOADING LOCAL LLM  ·  0%"
	loading_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading_status.add_theme_font_size_override("font_size", 11)
	loading_status.add_theme_color_override("font_color", VIOLET)
	col.add_child(loading_status)
	loading_progress = ProgressBar.new()
	loading_progress.custom_minimum_size.y = 10
	loading_progress.show_percentage = false
	loading_progress.add_theme_stylebox_override("background", _panel(Color("#172337"), 5, LINE, 1))
	loading_progress.add_theme_stylebox_override("fill", _panel(CYAN, 5, CYAN, 0))
	col.add_child(loading_progress)
	loading_detail = Label.new()
	loading_detail.text = "Opening the secure local channel…"
	loading_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	loading_detail.custom_minimum_size.y = 42
	loading_detail.add_theme_font_size_override("font_size", 10)
	loading_detail.add_theme_color_override("font_color", MUTED)
	col.add_child(loading_detail)
	_layout_shell()
	_update_loading_snapshot(backend.get_snapshot() if backend != null else {})


func _build_saved_games_page() -> void:
	saved_games_page = Control.new()
	saved_games_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen_content.add_child(saved_games_page)
	var page := PanelContainer.new()
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.offset_left = 18
	page.offset_top = 16
	page.offset_right = -18
	page.offset_bottom = -16
	page.add_theme_stylebox_override("panel", _panel(Color("#0c1421ed"), 24, Color("#3b4d67"), 1))
	saved_games_page.add_child(page)
	var page_scroll := ScrollContainer.new()
	page_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	page.add_child(page_scroll)
	var margin := _margin(30, 26, 30, 26)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page_scroll.add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 13)
	margin.add_child(col)
	var heading_row := HBoxContainer.new()
	col.add_child(heading_row)
	var title_col := VBoxContainer.new()
	title_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading_row.add_child(title_col)
	var heading := Label.new()
	heading.text = "Saved games"
	heading.add_theme_font_override("font", display_font)
	heading.add_theme_font_size_override("font_size", 30)
	heading.add_theme_color_override("font_color", TEXT)
	title_col.add_child(heading)
	var back := _secondary_button("←  BOARD")
	back.pressed.connect(_show_screen.bind("PLAY"))
	heading_row.add_child(back)
	var copy := Label.new()
	copy.text = "Save the current position or resume an earlier game. AI turns keep their state while this page is open."
	copy.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	copy.add_theme_font_size_override("font_size", 11)
	copy.add_theme_color_override("font_color", MUTED)
	col.add_child(copy)
	var action_card := PanelContainer.new()
	action_card.add_theme_stylebox_override("panel", _panel(Color("#142239b8"), 14, Color("#35547a"), 1))
	col.add_child(action_card)
	var action_margin := _margin(12, 10, 12, 10)
	action_card.add_child(action_margin)
	var actions := HFlowContainer.new()
	actions.add_theme_constant_override("h_separation", 8)
	actions.add_theme_constant_override("v_separation", 8)
	action_margin.add_child(actions)
	game_name_input = LineEdit.new()
	game_name_input.placeholder_text = "Name this position…"
	game_name_input.text = "My Caissa game"
	game_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	game_name_input.custom_minimum_size.y = 38
	_style_input(game_name_input)
	actions.add_child(game_name_input)
	var save_button := _primary_button("SAVE CURRENT GAME")
	save_button.pressed.connect(_save_current_game)
	actions.add_child(save_button)
	var refresh_button := _secondary_button("REFRESH")
	refresh_button.pressed.connect(_refresh_saved_games)
	actions.add_child(refresh_button)
	saved_games_status = Label.new()
	saved_games_status.text = "Loading saved positions…"
	saved_games_status.add_theme_font_size_override("font_size", 10)
	saved_games_status.add_theme_color_override("font_color", MUTED)
	col.add_child(saved_games_status)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	saved_games_list = VBoxContainer.new()
	saved_games_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	saved_games_list.add_theme_constant_override("separation", 8)
	scroll.add_child(saved_games_list)


func _refresh_saved_games() -> void:
	if saved_refresh_active:
		return
	if not is_instance_valid(saved_games_list) or not _backend_is_ready():
		if is_instance_valid(saved_games_status):
			saved_games_status.text = "Backend is still warming; saved games will appear when ready."
		return
	saved_refresh_active = true
	var result: Dictionary = await backend.request_games({
		"operation": "list_games",
		"limit": 64,
	})
	saved_refresh_active = false
	if not is_instance_valid(saved_games_list):
		return
	for child in saved_games_list.get_children():
		child.queue_free()
	if not result.get("ok", false):
		saved_games_status.text = "Could not load saved games · " + str(result.get("code", "unavailable"))
		return
	var games: Array = result.get("games", [])
	saved_games_status.text = "%d saved position%s · local only" % [games.size(), "" if games.size() == 1 else "s"]
	if games.is_empty():
		var empty := Label.new()
		empty.text = "No saved positions yet. Save the current board to create your first slot."
		empty.add_theme_font_size_override("font_size", 13)
		empty.add_theme_color_override("font_color", MUTED)
		saved_games_list.add_child(empty)
		return
	for game_variant in games:
		var game: Dictionary = game_variant
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", _panel(Color("#101c30cc"), 14, Color("#304766"), 1))
		saved_games_list.add_child(card)
		var row_margin := _margin(14, 10, 14, 10)
		card.add_child(row_margin)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		row_margin.add_child(row)
		var detail := VBoxContainer.new()
		detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(detail)
		var name := Label.new()
		name.text = str(game.get("name", "Saved game"))
		name.add_theme_font_size_override("font_size", 14)
		name.add_theme_color_override("font_color", TEXT)
		detail.add_child(name)
		var meta := Label.new()
		meta.text = "%d moves  ·  %s" % [int(game.get("move_count", 0)), str(game.get("status", "active")).to_upper()]
		meta.add_theme_font_size_override("font_size", 10)
		meta.add_theme_color_override("font_color", MUTED)
		detail.add_child(meta)
		var load_button := _secondary_button("LOAD")
		load_button.pressed.connect(_load_saved_game.bind(str(game.get("game_id", ""))))
		row.add_child(load_button)
		var delete_button := _secondary_button("DELETE")
		delete_button.pressed.connect(_delete_saved_game.bind(str(game.get("game_id", ""))))
		row.add_child(delete_button)


func _save_current_game() -> void:
	if not is_instance_valid(play_panel):
		saved_games_status.text = "Start a game before saving a position."
		return
	var result: Dictionary = await play_panel.save_game(game_name_input.text if is_instance_valid(game_name_input) else "Chess game")
	if result.get("ok", false):
		saved_games_status.text = "Saved · ready to load from this tab."
		_refresh_saved_games()
	else:
		saved_games_status.text = "Save failed · " + str(result.get("error", result.get("code", "unavailable")))


func _load_saved_game(game_id: String) -> void:
	if not is_instance_valid(play_panel):
		saved_games_status.text = "The chess surface is not ready yet."
		return
	var result: Dictionary = await play_panel.load_game(game_id)
	if result.get("ok", false):
		_show_screen("PLAY")
	else:
		saved_games_status.text = "Load failed · " + str(result.get("error", result.get("code", "unavailable")))


func _delete_saved_game(game_id: String) -> void:
	if not _backend_is_ready():
		return
	var result: Dictionary = await backend.request_games({
		"operation": "delete_game",
		"game_id": game_id,
	})
	if result.get("ok", false):
		_refresh_saved_games()
	else:
		saved_games_status.text = "Delete failed · " + str(result.get("code", "unavailable"))


func _build_settings_page() -> void:
	settings_page = Control.new()
	settings_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen_content.add_child(settings_page)
	var page := PanelContainer.new()
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.offset_left = 18
	page.offset_top = 16
	page.offset_right = -18
	page.offset_bottom = -16
	page.add_theme_stylebox_override("panel", _panel(PANEL, 24, Color("#3b4d67"), 1))
	settings_page.add_child(page)
	var page_scroll := ScrollContainer.new()
	page_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	page.add_child(page_scroll)
	var margin := _margin(28, 24, 28, 24)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page_scroll.add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 13)
	margin.add_child(col)
	var heading_row := HBoxContainer.new()
	col.add_child(heading_row)
	var heading := Label.new()
	heading.text = "Settings"
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_theme_font_override("font", display_font)
	heading.add_theme_font_size_override("font_size", 30)
	heading.add_theme_color_override("font_color", TEXT)
	heading_row.add_child(heading)
	var back := _secondary_button("←  BOARD")
	back.pressed.connect(_show_screen.bind("PLAY"))
	heading_row.add_child(back)
	var copy := Label.new()
	copy.text = "Godot starts and owns the Flutter/Dart process. The sidecar is loopback-only and Gemma inference is CPU-only."
	copy.add_theme_font_size_override("font_size", 11)
	copy.add_theme_color_override("font_color", MUTED)
	col.add_child(copy)
	col.add_child(HSeparator.new())
	col.add_child(_eyebrow("LOCAL CONNECTION", CYAN))
	col.add_child(_field_row("PORT", "47621", false))
	col.add_child(_field_row("MODEL PATH", "", true))
	var endpoint := Label.new()
	endpoint.text = "Endpoint  ·  http://127.0.0.1:47621  ·  POST /health  ·  authenticated bearer token"
	endpoint.add_theme_font_size_override("font_size", 10)
	endpoint.add_theme_color_override("font_color", MUTED)
	col.add_child(endpoint)
	var actions := HFlowContainer.new()
	actions.add_theme_constant_override("h_separation", 8)
	actions.add_theme_constant_override("v_separation", 8)
	start_button = _primary_button("START BACKEND")
	start_button.pressed.connect(_start_backend)
	actions.add_child(start_button)
	stop_button = _secondary_button("STOP BACKEND")
	stop_button.pressed.connect(_stop_backend)
	actions.add_child(stop_button)
	restart_button = _secondary_button("RESTART")
	restart_button.pressed.connect(_restart_backend)
	actions.add_child(restart_button)
	test_button = _secondary_button("TEST /HEALTH")
	test_button.pressed.connect(_test_backend)
	actions.add_child(test_button)
	install_model_button = _secondary_button("INSTALL / REPAIR MODEL")
	install_model_button.pressed.connect(_install_or_repair_model)
	actions.add_child(install_model_button)
	col.add_child(actions)
	var status_card := PanelContainer.new()
	status_card.add_theme_stylebox_override("panel", _panel(Color("#101a2a"), 12, LINE, 1))
	col.add_child(status_card)
	var status_margin := _margin(14, 12, 14, 12)
	status_card.add_child(status_margin)
	var status_col := VBoxContainer.new()
	status_col.add_theme_constant_override("separation", 7)
	status_margin.add_child(status_col)
	settings_status = Label.new()
	settings_status.text = "Checking owned backend process…"
	settings_status.add_theme_font_size_override("font_size", 14)
	settings_status.add_theme_color_override("font_color", CYAN)
	status_col.add_child(settings_status)
	settings_detail = Label.new()
	settings_detail.text = "The model may take several minutes to verify and warm on first launch."
	settings_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	settings_detail.add_theme_font_size_override("font_size", 11)
	settings_detail.add_theme_color_override("font_color", MUTED)
	status_col.add_child(settings_detail)
	col.add_child(HSeparator.new())
	col.add_child(_eyebrow("CAISSA PLAY PROFILE", VIOLET))
	var profile_card := PanelContainer.new()
	profile_card.add_theme_stylebox_override("panel", _panel(Color("#101a2acc"), 14, Color("#34465f"), 1))
	col.add_child(profile_card)
	var profile_margin := _margin(14, 12, 14, 12)
	profile_card.add_child(profile_margin)
	var profile_col := VBoxContainer.new()
	profile_col.add_theme_constant_override("separation", 10)
	profile_margin.add_child(profile_col)
	memory_toggle = CheckButton.new()
	memory_toggle.text = "Past-game move memory"
	memory_toggle.button_pressed = bool(agent_preferences.memory_enabled)
	memory_toggle.add_theme_font_override("font", display_font)
	memory_toggle.add_theme_font_size_override("font_size", 13)
	memory_toggle.add_theme_color_override("font_color", TEXT)
	memory_toggle.add_theme_color_override("font_hover_color", TEXT)
	profile_col.add_child(memory_toggle)
	var side_row := HBoxContainer.new()
	side_row.add_theme_constant_override("separation", 10)
	profile_col.add_child(side_row)
	var side_label := Label.new()
	side_label.text = "YOUR PIECES"
	side_label.custom_minimum_size.x = 162
	side_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	side_label.add_theme_font_override("font", display_font)
	side_label.add_theme_font_size_override("font_size", 10)
	side_label.add_theme_color_override("font_color", MUTED)
	side_row.add_child(side_label)
	side_option = OptionButton.new()
	side_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side_option.custom_minimum_size.y = 40
	_style_option(side_option)
	side_option.add_item("White · move first")
	side_option.set_item_metadata(0, "white")
	side_option.add_item("Black · Caissa moves first")
	side_option.set_item_metadata(1, "black")
	side_row.add_child(side_option)
	var skill_row := HBoxContainer.new()
	skill_row.add_theme_constant_override("separation", 10)
	profile_col.add_child(skill_row)
	var skill_label := Label.new()
	skill_label.text = "SKILL SPECTRUM"
	skill_label.custom_minimum_size.x = 140
	skill_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	skill_label.add_theme_font_override("font", display_font)
	skill_label.add_theme_font_size_override("font_size", 10)
	skill_label.add_theme_color_override("font_color", MUTED)
	skill_row.add_child(skill_label)
	skill_swatch = ColorRect.new()
	skill_swatch.custom_minimum_size = Vector2(12, 32)
	skill_swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	skill_row.add_child(skill_swatch)
	skill_option = OptionButton.new()
	skill_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	skill_option.custom_minimum_size.y = 40
	_style_option(skill_option)
	for profile_variant in AgentScript.skill_profiles():
		var profile: Dictionary = profile_variant
		skill_option.add_item(str(profile.label))
		skill_option.set_item_metadata(skill_option.item_count - 1, str(profile.id))
	skill_row.add_child(skill_option)
	var style_row := HBoxContainer.new()
	style_row.add_theme_constant_override("separation", 10)
	profile_col.add_child(style_row)
	var style_label := Label.new()
	style_label.text = "PLAYING STYLE"
	style_label.custom_minimum_size.x = 162
	style_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	style_label.add_theme_font_override("font", display_font)
	style_label.add_theme_font_size_override("font_size", 10)
	style_label.add_theme_color_override("font_color", MUTED)
	style_row.add_child(style_label)
	style_option = OptionButton.new()
	style_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	style_option.custom_minimum_size.y = 40
	_style_option(style_option)
	for profile_variant in AgentScript.style_profiles():
		var profile: Dictionary = profile_variant
		style_option.add_item(str(profile.label))
		style_option.set_item_metadata(style_option.item_count - 1, str(profile.id))
	style_row.add_child(style_option)
	agent_profile_detail = Label.new()
	agent_profile_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	agent_profile_detail.add_theme_font_size_override("font_size", 10)
	agent_profile_detail.add_theme_color_override("font_color", MUTED)
	profile_col.add_child(agent_profile_detail)
	_sync_agent_preference_controls()
	memory_toggle.toggled.connect(_on_agent_preferences_changed)
	skill_option.item_selected.connect(_on_agent_preferences_changed)
	style_option.item_selected.connect(_on_agent_preferences_changed)
	side_option.item_selected.connect(_on_agent_preferences_changed)
	_sync_backend_snapshot()


func _field_row(label_text: String, value: String, model_field: bool) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 110
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", MUTED)
	row.add_child(label)
	var input := LineEdit.new()
	input.text = value
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.custom_minimum_size.y = 38
	_style_input(input)
	row.add_child(input)
	if model_field:
		model_input = input
		model_input.placeholder_text = "Automatic installation (recommended)"
	else:
		port_input = input
	return row


func _on_agent_preferences_changed(_value: Variant = null) -> void:
	if not is_instance_valid(memory_toggle) or not is_instance_valid(skill_option) or not is_instance_valid(style_option) or not is_instance_valid(side_option):
		return
	agent_preferences = AgentScript.normalized_preferences({
		"memory_enabled": memory_toggle.button_pressed,
		"skill_color": str(skill_option.get_selected_metadata()),
		"style_id": str(style_option.get_selected_metadata()),
		"player_side": str(side_option.get_selected_metadata()),
	})
	preferences_loaded = true
	preferences_save_pending = true
	_apply_agent_preferences()
	_sync_agent_preference_controls()
	call_deferred("_save_agent_preferences")


func _apply_agent_preferences() -> void:
	if is_instance_valid(play_panel):
		play_panel.set_agent_preferences(agent_preferences)


func _sync_agent_preference_controls() -> void:
	if is_instance_valid(memory_toggle):
		memory_toggle.set_pressed_no_signal(bool(agent_preferences.get("memory_enabled", true)))
	if is_instance_valid(skill_option):
		_select_option_metadata(skill_option, str(agent_preferences.get("skill_color", "yellow")))
	if is_instance_valid(style_option):
		_select_option_metadata(style_option, str(agent_preferences.get("style_id", "adaptive")))
	if is_instance_valid(side_option):
		_select_option_metadata(side_option, str(agent_preferences.get("player_side", "white")))
	if is_instance_valid(skill_swatch):
		skill_swatch.color = _skill_color(str(agent_preferences.get("skill_color", "yellow")))
	if is_instance_valid(agent_profile_detail):
		var skill := AgentScript.skill_profile(str(agent_preferences.get("skill_color", "yellow")))
		var style := AgentScript.playing_style(str(agent_preferences.get("style_id", "adaptive")))
		agent_profile_detail.text = "%s  ·  %s  ·  Memory %s  ·  Next game: %s" % [
			str(skill.instruction),
			str(style.instruction),
			"on" if bool(agent_preferences.get("memory_enabled", true)) else "off",
			str(agent_preferences.get("player_side", "white")).capitalize(),
		]


func _select_option_metadata(option: OptionButton, requested: String) -> void:
	for index in range(option.item_count):
		if str(option.get_item_metadata(index)) == requested:
			option.select(index)
			return


func _skill_color(value: String) -> Color:
	return {
		"red": Color("#ff6b72"),
		"orange": Color("#ffad5c"),
		"yellow": Color("#f4dc68"),
		"green": Color("#72d99b"),
		"blue": Color("#6bbcf6"),
		"indigo": Color("#818cf8"),
		"violet": Color("#b489ff"),
	}.get(value, Color("#f4dc68"))


func _load_agent_preferences() -> void:
	if preferences_loaded or preferences_request_active or not _backend_is_ready() or not backend.has_method("request_preferences"):
		return
	preferences_request_active = true
	var result: Dictionary = await backend.request_preferences({"operation": "get"})
	preferences_request_active = false
	if not result.get("ok", false) or not result.get("preferences", null) is Dictionary:
		return
	agent_preferences = AgentScript.normalized_preferences(Dictionary(result.preferences))
	preferences_loaded = true
	_apply_agent_preferences()
	_sync_agent_preference_controls()


func _save_agent_preferences() -> void:
	if not preferences_save_pending or preferences_request_active or not _backend_is_ready() or not backend.has_method("request_preferences"):
		return
	preferences_request_active = true
	preferences_save_pending = false
	var result: Dictionary = await backend.request_preferences({
		"operation": "set",
		"memory_enabled": bool(agent_preferences.get("memory_enabled", true)),
		"skill_color": str(agent_preferences.get("skill_color", "yellow")),
		"style_id": str(agent_preferences.get("style_id", "adaptive")),
		"player_side": str(agent_preferences.get("player_side", "white")),
	})
	preferences_request_active = false
	if not result.get("ok", false):
		preferences_save_pending = true


func _start_backend() -> void:
	var config := _read_backend_config()
	if not config.ok:
		_set_settings_status(str(config.get("error", "Invalid backend configuration.")), AMBER)
		return
	var result: Dictionary = backend.start_backend(int(config.port), str(config.model))
	_set_settings_status(str(result.get("operation_detail", result.get("code", "start requested"))), LIME if result.get("ok", false) else AMBER)
	_sync_backend_snapshot()


func _stop_backend() -> void:
	var result: Dictionary = backend.stop_backend()
	_set_settings_status(str(result.get("operation_detail", result.get("code", "stop requested"))), LIME if result.get("ok", false) else AMBER)
	_sync_backend_snapshot()


func _restart_backend() -> void:
	var config := _read_backend_config()
	if not config.ok:
		_set_settings_status(str(config.get("error", "Invalid backend configuration.")), AMBER)
		return
	_set_settings_status("Restarting the owned Flutter/Dart process…", AMBER)
	backend.stop_backend()
	await get_tree().process_frame
	var configured: Dictionary = backend.configure(int(config.port), str(config.model))
	if not configured.get("ok", false):
		_set_settings_status(str(configured.get("operation_detail", configured.get("code", "configuration failed"))), AMBER)
		_sync_backend_snapshot()
		return
	var result: Dictionary = backend.start_backend(int(config.port), str(config.model))
	_set_settings_status(str(result.get("operation_detail", result.get("code", "restart requested"))), LIME if result.get("ok", false) else AMBER)
	_sync_backend_snapshot()


func _test_backend() -> void:
	_set_settings_status("Testing authenticated POST /health…", AMBER)
	var result: Dictionary = await backend.test_backend()
	var passed := bool(result.get("test_ok", false))
	_set_settings_status(("PASS  ·  " if passed else "FAIL  ·  ") + str(result.get("detail", result.get("code", "unknown"))), LIME if passed else AMBER)
	_sync_backend_snapshot()


func _install_or_repair_model() -> void:
	if is_instance_valid(model_input):
		model_input.clear()
	_set_settings_status("Preparing the automatic model installation…", AMBER)
	var config := _read_backend_config()
	if not config.get("ok", false):
		_set_settings_status(str(config.get("error", "Invalid backend configuration.")), AMBER)
		return
	backend.stop_backend()
	await get_tree().process_frame
	var configured: Dictionary = backend.configure(int(config.port), "")
	if not configured.get("ok", false):
		_set_settings_status(str(configured.get("operation_detail", configured.get("code", "configuration failed"))), AMBER)
		return
	var result: Dictionary = backend.start_backend(int(config.port), "")
	_set_settings_status("Automatic model check started." if result.get("ok", false) else str(result.get("operation_detail", result.get("code", "start failed"))), LIME if result.get("ok", false) else AMBER)
	_sync_backend_snapshot()


func _read_backend_config() -> Dictionary:
	var port_text := port_input.text.strip_edges() if is_instance_valid(port_input) else "47621"
	var parsed_port := int(port_text)
	if parsed_port < 1024 or parsed_port > 65535:
		return {"ok": false, "error": "Port must be between 1024 and 65535."}
	var model := model_input.text.strip_edges() if is_instance_valid(model_input) else ""
	return {"ok": true, "port": parsed_port, "model": model}


func _layout_shell() -> void:
	if not is_instance_valid(root) or not is_instance_valid(loading_card):
		return
	var viewport_size := root.size
	var card_width := minf(660.0, maxf(330.0, viewport_size.x - 28.0))
	var card_height := minf(470.0, maxf(430.0, viewport_size.y - 28.0))
	loading_card.offset_left = -card_width * 0.5
	loading_card.offset_right = card_width * 0.5
	loading_card.offset_top = -card_height * 0.5
	loading_card.offset_bottom = card_height * 0.5


func _sync_backend_snapshot() -> void:
	if backend == null or not backend.has_method("get_snapshot"):
		return
	_on_backend_snapshot(backend.get_snapshot())


func _backend_is_ready() -> bool:
	return backend != null and bool(backend.get("is_ready"))


func _update_loading_snapshot(snapshot: Dictionary) -> void:
	if not is_instance_valid(loading_page):
		return
	var progress := clampi(int(snapshot.get("progress", 0)), 0, 100)
	var phase := str(snapshot.get("phase", snapshot.get("status_detail", "starting local backend")))
	if is_instance_valid(loading_progress):
		loading_progress.value = progress
	if is_instance_valid(loading_status):
		loading_status.text = "LOCAL INTELLIGENCE  ·  %d%%" % progress
	if is_instance_valid(loading_detail):
		loading_detail.text = _boot_message(progress, phase)


func _boot_message(progress: int, phase: String) -> String:
	if "verif" in phase.to_lower():
		return [
			"The knight is checking every grain of its memory…",
			"Caissa is counting the stars in her opening book…",
			"A tiny librarian is comparing the model’s fingerprints…",
			"The bishops are polishing the local crystal…",
			"Almost there — the rook insists on one last checksum…",
		][clampi(int(progress / 10), 0, 4)]
	if progress < 8:
		return "Waking the knight and opening the private study…"
	if progress < 60:
		return "Teaching the local pieces where the board begins…"
	if progress < 90:
		return "Caissa is taking her seat at the board…"
	return "One final quiet move before the game begins…"


func _on_backend_snapshot(snapshot: Dictionary) -> void:
	var ready := bool(snapshot.get("ready", false))
	var running := bool(snapshot.get("process_running", false))
	_update_loading_snapshot(snapshot)
	if ready:
		_set_settings_status("READY  ·  authenticated CPU model", LIME)
	elif running:
		_set_settings_status("STARTING  ·  " + str(snapshot.get("phase", "initializing")), AMBER)
	else:
		_set_settings_status("STOPPED  ·  start the local backend to play", AMBER)
	if ready and current_screen == "PLAY" and play_panel == null:
		_show_screen("PLAY")
	if ready and current_screen == "SAVED GAMES":
		_refresh_saved_games()
	if ready and not preferences_loaded:
		call_deferred("_load_agent_preferences")
	elif ready and preferences_save_pending:
		call_deferred("_save_agent_preferences")
	if is_instance_valid(settings_detail):
		settings_detail.text = "PID %s  ·  %s  ·  %s  ·  %s" % [str(snapshot.get("pid", "-")), str(snapshot.get("endpoint", "http://127.0.0.1:47621")), str(snapshot.get("activity", "idle")), str(snapshot.get("error", "no error"))]
	_refresh_settings_buttons(ready, running)


func _on_backend_ready(ready: bool, detail: String) -> void:
	_set_settings_status("READY  ·  " + detail if ready else detail, LIME if ready else AMBER)
	_sync_backend_snapshot()


func _on_backend_status(_status: String, detail: String) -> void:
	_set_settings_status(detail, LIME if _status == "ready" else AMBER)


func _on_backend_progress(progress: int, phase: String) -> void:
	_update_loading_snapshot({"progress": progress, "phase": phase, "endpoint": backend.endpoint})
	if current_screen == "SETTINGS":
		_set_settings_status("STARTING  ·  %d%%  ·  %s" % [progress, phase], AMBER)


func _refresh_settings_buttons(ready: bool, running: bool) -> void:
	if not is_instance_valid(start_button):
		return
	start_button.disabled = running
	stop_button.disabled = not running
	test_button.disabled = not running
	restart_button.disabled = not running


func _set_settings_status(value: String, color: Color) -> void:
	if is_instance_valid(settings_status):
		settings_status.text = value
		settings_status.add_theme_color_override("font_color", color)


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


func _margin(left: int, top: int, right: int, bottom: int) -> MarginContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", left)
	margin.add_theme_constant_override("margin_top", top)
	margin.add_theme_constant_override("margin_right", right)
	margin.add_theme_constant_override("margin_bottom", bottom)
	return margin


func _eyebrow(value: String, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_override("font", display_font)
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", color)
	return label


func _primary_button(value: String) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size.y = 44
	button.add_theme_font_override("font", display_font)
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_color_override("font_color", Color("#071116"))
	button.add_theme_color_override("font_hover_color", Color("#041015"))
	button.add_theme_color_override("font_pressed_color", Color("#071116"))
	button.add_theme_color_override("font_disabled_color", Color("#87909f"))
	button.add_theme_stylebox_override("normal", _button_style(Color("#79e7f2"), Color("#b8f5fb"), 1))
	button.add_theme_stylebox_override("hover", _button_style(Color("#a7f3fa"), Color("#e0fcff"), 2))
	button.add_theme_stylebox_override("pressed", _button_style(Color("#5bd2df"), Color("#8cecf5"), 1))
	button.add_theme_stylebox_override("disabled", _button_style(Color("#222c39"), Color("#344152"), 1))
	return button


func _secondary_button(value: String) -> Button:
	var button := Button.new()
	button.text = value
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


func _style_input(input: LineEdit) -> void:
	input.add_theme_font_override("font", body_font)
	input.add_theme_font_size_override("font_size", 13)
	input.add_theme_color_override("font_color", TEXT)
	input.add_theme_color_override("font_placeholder_color", MUTED)
	input.add_theme_stylebox_override("normal", _button_style(Color("#0c1420"), Color("#34445b"), 1))
	input.add_theme_stylebox_override("focus", _button_style(Color("#101b2a"), Color("#75deea"), 2))


func _style_option(option: OptionButton) -> void:
	option.add_theme_font_override("font", body_font)
	option.add_theme_font_size_override("font_size", 12)
	option.add_theme_color_override("font_color", TEXT)
	option.add_theme_color_override("font_hover_color", TEXT)
	option.add_theme_color_override("font_pressed_color", TEXT)
	option.add_theme_stylebox_override("normal", _button_style(Color("#182435"), Color("#394a61"), 1))
	option.add_theme_stylebox_override("hover", _button_style(Color("#23334a"), Color("#75deea"), 1))
	option.add_theme_stylebox_override("pressed", _button_style(Color("#111b29"), Color("#75deea"), 1))


func _button_style(color: Color, border: Color, width: int) -> StyleBoxFlat:
	var style := _panel(color, 12, border, width)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.shadow_color = Color("#00000080")
	style.shadow_size = 10
	style.shadow_offset = Vector2(0, 3)
	return style
