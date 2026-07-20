extends Control
class_name MutationReview

signal enter_requested(payload: Dictionary)
signal closed

const INK := Color("#060912")
const PANEL := Color("#0b111dfb")
const LINE := Color("#2a3448")
const TEXT := Color("#f2f6ff")
const MUTED := Color("#8c98ae")
const CYAN := Color("#64e8ff")
const VIOLET := Color("#a979ff")
const LIME := Color("#9bf59b")
const AMBER := Color("#ffca74")

var context: Dictionary = {}
var primary_action: Button
var simulation_bar: ProgressBar
var simulation_status: Label
var consensus_label: Label
var q7_status: Label
var replay_status: Label
var stability_status: Label
var phase := 0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build()


func open_review(session_context: Dictionary = {}) -> void:
	context = session_context.duplicate(true)
	phase = 0
	simulation_bar.value = 0
	simulation_status.text = "WAITING FOR LOCAL SIMULATION"
	simulation_status.add_theme_color_override("font_color", MUTED)
	consensus_label.text = "CONSENSUS  1 / 2"
	consensus_label.add_theme_color_override("font_color", AMBER)
	q7_status.text = "REVIEWING"
	q7_status.add_theme_color_override("font_color", AMBER)
	replay_status.text = "PENDING"
	replay_status.add_theme_color_override("font_color", MUTED)
	stability_status.text = "92%  →  89% TRIAL FLOOR"
	primary_action.text = "SIMULATE 3 TURNS  →"
	primary_action.disabled = false
	visible = true
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 0.18)


func close_review() -> void:
	visible = false
	closed.emit()


func _build() -> void:
	var shade := ColorRect.new()
	shade.color = Color("#02040aeb")
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	shade.gui_input.connect(_on_shade_input)
	add_child(shade)

	var panel := PanelContainer.new()
	panel.position = Vector2(160, 70)
	panel.size = Vector2(1120, 720)
	panel.add_theme_stylebox_override("panel", _panel(PANEL, 22, Color("#46516a"), 1))
	add_child(panel)
	var margin := _margin(24, 20, 24, 20)
	panel.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	var header := HBoxContainer.new()
	var header_copy := VBoxContainer.new()
	header_copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_copy.add_child(_label("MUTATION M-013  /  QUIET MACHINE  /  REVIEW REQUIRED", 10, AMBER))
	header_copy.add_child(_label("Bridge Memory", 29, TEXT))
	header.add_child(header_copy)
	var close := _button("×", false)
	close.custom_minimum_size = Vector2(42, 38)
	close.pressed.connect(close_review)
	header.add_child(close)
	column.add_child(header)
	column.add_child(HSeparator.new())

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 20)
	column.add_child(body)
	var diff_col := VBoxContainer.new()
	diff_col.custom_minimum_size.x = 650
	diff_col.add_theme_constant_override("separation", 9)
	body.add_child(diff_col)
	diff_col.add_child(_label("MACHINE RATIONALE", 10, VIOLET))
	var rationale := _label("Observed 7 repeated crossings after allied pings. Memory may reduce redundant communication. This proposal creates no new legal moves.", 12, Color("#c8d1e0"))
	rationale.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rationale.custom_minimum_size.y = 48
	diff_col.add_child(rationale)
	diff_col.add_child(_label("TYPED STATE DIFF", 10, CYAN))
	diff_col.add_child(_diff_row("EVENT / piece.crossed_bridge", "NO-OP", "WRITE last_piece_id", CYAN))
	diff_col.add_child(_diff_row("WORLD / bridge.memory_window", "0", "2 TURNS", VIOLET))
	diff_col.add_child(_diff_row("PRESENTATION / bridge.echo", "HIDDEN", "SHARED LIGHT TRACE", LIME))
	diff_col.add_child(_diff_row("REDUCER / state digest", "UNCHANGED", "APPEND memory_stamp", AMBER))
	diff_col.add_child(_label("SIMULATION WINDOW  /  THREE DETERMINISTIC TURNS", 10, MUTED))
	var sim_panel := PanelContainer.new()
	sim_panel.add_theme_stylebox_override("panel", _panel(Color("#101824"), 12, LINE, 1))
	var sim_margin := _margin(14, 12, 14, 12)
	sim_panel.add_child(sim_margin)
	var sim_col := VBoxContainer.new()
	sim_col.add_theme_constant_override("separation", 10)
	sim_margin.add_child(sim_col)
	for entry in [
		["T+01", "Ivory scout crosses bridge 4B", "memory_stamp: Q7-SCOUT"],
		["T+02", "Vexel receives shared light trace", "legal state unchanged"],
		["T+03", "Trace expires at window boundary", "inverse transform clean"],
	]:
		sim_col.add_child(_timeline_row(entry[0], entry[1], entry[2]))
	simulation_bar = ProgressBar.new()
	simulation_bar.value = 0
	simulation_bar.show_percentage = false
	simulation_bar.custom_minimum_size.y = 8
	simulation_bar.add_theme_stylebox_override("background", _panel(Color("#1c2432"), 4))
	simulation_bar.add_theme_stylebox_override("fill", _panel(CYAN, 4))
	sim_col.add_child(simulation_bar)
	simulation_status = _label("WAITING FOR LOCAL SIMULATION", 10, MUTED)
	sim_col.add_child(simulation_status)
	diff_col.add_child(sim_panel)

	var verify_col := VBoxContainer.new()
	verify_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	verify_col.add_theme_constant_override("separation", 10)
	body.add_child(verify_col)
	verify_col.add_child(_label("VERIFICATION ENVELOPE", 10, LIME))
	replay_status = _verification_row(verify_col, "REPLAY HASH  9E6A-41C2", "PENDING", MUTED)
	_verification_row(verify_col, "MUTATION RISK", "0.18 / LOW", LIME)
	stability_status = _verification_row(verify_col, "WORLD STABILITY", "92%  →  89% TRIAL FLOOR", AMBER)
	_verification_row(verify_col, "MUTATION DEBT", "+0 / REVIEWED", CYAN)
	_verification_row(verify_col, "ROLLBACK ANCHOR", "SEED 827401 / M-012", VIOLET)
	verify_col.add_child(HSeparator.new())
	verify_col.add_child(_label("PEER CONSENT", 10, AMBER))
	var vexel := _peer_row("VX", "VEXEL", "SIGNED · 24ms", LIME)
	verify_col.add_child(vexel)
	var q7 := _peer_row("Q7", "YOU", "REVIEWING", AMBER)
	q7_status = q7.get_meta("status_label")
	verify_col.add_child(q7)
	consensus_label = _label("CONSENSUS  1 / 2", 12, AMBER)
	consensus_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	verify_col.add_child(consensus_label)
	var consent_note := _label("Rule changes require every active peer. Cosmetic-only proposals may be auto-applied by profile policy.", 10, MUTED)
	consent_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	consent_note.custom_minimum_size.y = 44
	verify_col.add_child(consent_note)
	var defer := _button("DEFER PROPOSAL", false)
	defer.pressed.connect(_defer)
	verify_col.add_child(defer)
	primary_action = _button("SIMULATE 3 TURNS  →", true)
	primary_action.custom_minimum_size.y = 44
	primary_action.pressed.connect(_advance)
	verify_col.add_child(primary_action)
	var footer := _label("No generated code executes before verification and unanimous consent.", 9, MUTED)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	verify_col.add_child(footer)


func _advance() -> void:
	if phase == 0:
		_simulate()
	elif phase == 1:
		_consent()
	else:
		var payload := context.duplicate(true)
		payload["action"] = "shard"
		payload["mutation"] = "M-013 / BRIDGE MEMORY"
		payload["mutation_sealed"] = true
		visible = false
		enter_requested.emit(payload)


func _simulate() -> void:
	phase = -1
	primary_action.disabled = true
	primary_action.text = "SIMULATING…"
	simulation_status.text = "REPLAYING SIGNED INTENT LOG"
	simulation_status.add_theme_color_override("font_color", AMBER)
	var tween := create_tween()
	tween.tween_property(simulation_bar, "value", 100, 0.85).set_trans(Tween.TRANS_CUBIC)
	await tween.finished
	replay_status.text = "PASS"
	replay_status.add_theme_color_override("font_color", LIME)
	stability_status.text = "92%  →  91.6% VERIFIED"
	stability_status.add_theme_color_override("font_color", LIME)
	simulation_status.text = "3 / 3 TURNS MATCHED  ·  INVERSE CLEAN"
	simulation_status.add_theme_color_override("font_color", LIME)
	phase = 1
	primary_action.disabled = false
	primary_action.text = "CONSENT & SEAL  →"


func _consent() -> void:
	phase = 2
	q7_status.text = "SIGNED · LOCAL"
	q7_status.add_theme_color_override("font_color", LIME)
	consensus_label.text = "CONSENSUS  2 / 2  ·  SEALED"
	consensus_label.add_theme_color_override("font_color", LIME)
	primary_action.text = "ENTER SHARD WITH MUTATION  →"


func _defer() -> void:
	context["mutation_deferred"] = true
	close_review()


func _on_shade_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		close_review()


func _diff_row(path: String, before: String, after: String, accent: Color) -> PanelContainer:
	var row_panel := PanelContainer.new()
	row_panel.custom_minimum_size.y = 47
	row_panel.add_theme_stylebox_override("panel", _panel(Color("#111927"), 10, LINE, 1))
	var margin := _margin(12, 7, 12, 7)
	row_panel.add_child(margin)
	var row := HBoxContainer.new()
	margin.add_child(row)
	var path_label := _label(path, 10, TEXT)
	path_label.custom_minimum_size.x = 260
	row.add_child(path_label)
	var before_label := _label(before, 10, MUTED)
	before_label.custom_minimum_size.x = 125
	row.add_child(before_label)
	row.add_child(_label("→", 12, accent))
	var after_label := _label(after, 10, accent)
	after_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(after_label)
	return row_panel


func _timeline_row(turn: String, event_text: String, result: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var turn_label := _label(turn, 10, CYAN)
	turn_label.custom_minimum_size.x = 48
	row.add_child(turn_label)
	var event_label := _label(event_text, 10, TEXT)
	event_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(event_label)
	row.add_child(_label(result, 10, MUTED))
	return row


func _verification_row(parent: VBoxContainer, label_text: String, value: String, accent: Color) -> Label:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel(Color("#111927"), 9, LINE, 1))
	var margin := _margin(10, 7, 10, 7)
	panel.add_child(margin)
	var row := HBoxContainer.new()
	margin.add_child(row)
	var key := _label(label_text, 10, MUTED)
	key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(key)
	var value_label := _label(value, 10, accent)
	row.add_child(value_label)
	parent.add_child(panel)
	return value_label


func _peer_row(initials: String, peer_name: String, state: String, accent: Color) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel(Color("#111927"), 10, LINE, 1))
	var margin := _margin(10, 7, 10, 7)
	panel.add_child(margin)
	var row := HBoxContainer.new()
	margin.add_child(row)
	var badge := _label(initials, 15, accent)
	badge.custom_minimum_size.x = 38
	row.add_child(badge)
	var name := _label(peer_name, 10, TEXT)
	name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name)
	var status := _label(state, 10, accent)
	row.add_child(status)
	panel.set_meta("status_label", status)
	return panel


func _label(value: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


func _button(value: String, primary: bool) -> Button:
	var button := Button.new()
	button.text = value
	button.add_theme_font_size_override("font_size", 10)
	if primary:
		button.add_theme_color_override("font_color", Color("#061018"))
		button.add_theme_stylebox_override("normal", _panel(CYAN, 9))
		button.add_theme_stylebox_override("hover", _panel(CYAN.lightened(0.12), 9))
	else:
		button.add_theme_color_override("font_color", TEXT)
		button.add_theme_stylebox_override("normal", _panel(Color("#121a28"), 9, LINE, 1))
		button.add_theme_stylebox_override("hover", _panel(Color("#1b293a"), 9, CYAN, 1))
	return button


func _panel(color: Color, radius: int, border := Color.TRANSPARENT, width := 0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	style.border_color = border
	style.border_width_left = width
	style.border_width_top = width
	style.border_width_right = width
	style.border_width_bottom = width
	return style


func _margin(left: int, top: int, right: int, bottom: int) -> MarginContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", left)
	margin.add_theme_constant_override("margin_top", top)
	margin.add_theme_constant_override("margin_right", right)
	margin.add_theme_constant_override("margin_bottom", bottom)
	return margin
