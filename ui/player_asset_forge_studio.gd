extends PanelContainer

## Reusable, proposal-only studio for player-authored game assets.
##
## The studio deliberately performs no network, model, filesystem, IPFS, or
## blockchain operations. It emits a bounded request envelope that an owning
## scene can pass through its own consent, moderation, generation, provenance,
## voting, and publication pipeline.

signal game_selected(game_id: String)
signal request_changed(request: Dictionary)
signal asset_request_drafted(request: Dictionary)
signal asset_publish_requested(request: Dictionary)

const SCHEMA_VERSION := "nexus.asset-proposal.v1"
const MAX_TITLE_LENGTH := 96
const MAX_PROMPT_LENGTH := 6000
const MAX_CONSTRAINT_LENGTH := 1200
const MAX_MEMBER_COUNT := 64
const MAX_MEMBER_LABEL_LENGTH := 48
const MAX_METADATA_VALUE_LENGTH := 160

const CYAN := Color("#5de1f4")
const VIOLET := Color("#8d6cff")
const LIME := Color("#77e58f")
const AMBER := Color("#ffd166")
const RED := Color("#ff6b82")
const TEXT := Color("#edf4ff")
const MUTED := Color("#8995aa")
const LINE := Color("#29364b")
const DEEP := Color("#070b13")
const PANEL := Color("#0c1320")
const SURFACE := Color("#111a29")

const GAMES := [
	{
		"id": "chess_core",
		"label": "CHESS CORE",
		"short": "CHESS",
		"description": "Pieces, boards, clocks, move feedback, and readable competitive themes.",
	},
	{
		"id": "four_line",
		"label": "FOUR LINE",
		"short": "CONNECT FOUR",
		"description": "Grid frames, tokens, drop trails, win lines, and playful table environments.",
	},
	{
		"id": "draughts",
		"label": "DRAUGHTS",
		"short": "CHECKERS",
		"description": "Boards, men, kings, capture paths, crowns, and high-contrast match themes.",
	},
	{
		"id": "property_grid",
		"label": "PROPERTY GRID",
		"short": "PROPERTY",
		"description": "Loop boards, original districts, pawns, cards, deeds, currency, and event feedback.",
	},
]

const MODALITIES := [
	{"id": "image", "label": "IMAGE", "hint": "2D art, textures, cards, icons, and concept sheets"},
	{"id": "audio", "label": "AUDIO", "hint": "Music, ambience, voices, and interaction cues"},
	{"id": "world", "label": "WORLD", "hint": "Coherent environment kits and spatial themes"},
	{"id": "ui_kit", "label": "UI KIT", "hint": "Accessible controls, HUD surfaces, and state feedback"},
	{"id": "voice_to_text", "label": "VOICE → TEXT", "hint": "Private opt-in transcription briefs with correction and discard controls"},
]

const MODELS := [
	{"id": "community_auto", "label": "COMMUNITY AUTO ROUTER"},
	{"id": "local_visual", "label": "LOCAL VISUAL ADAPTER"},
	{"id": "local_bark", "label": "LOCAL BARK AUDIO ADAPTER"},
	{"id": "local_stt", "label": "LOCAL SPEECH-TO-TEXT ADAPTER"},
	{"id": "hive_world", "label": "HIVE WORLD PIPELINE"},
]

const POLICIES := [
	{"id": "strict_original", "label": "STRICT ORIGINAL + LICENSE REVIEW"},
	{"id": "family_safe", "label": "FAMILY-SAFE COMMUNITY REVIEW"},
	{"id": "trusted_lobby", "label": "TRUSTED LOBBY REVIEW"},
	{"id": "public_consensus", "label": "PUBLIC SHARD CONSENSUS"},
]

const VISIBILITIES := [
	{"id": "private_draft", "label": "PRIVATE / LOCAL DRAFT"},
	{"id": "lobby_encrypted", "label": "LOBBY / MEMBER-KEYED"},
	{"id": "public_proposal", "label": "PUBLIC / PROPOSAL RECORD"},
]

const VOTE_STATES := ["approve", "reject", "pending", "abstain"]

var game_tabs: TabBar
var preview_rect: TextureRect
var preview_empty_label: Label
var preview_caption: Label
var capacity_summary_label: Label
var game_context_label: Label
var proposal_title: LineEdit
var prompt_editor: TextEdit
var constraints_editor: TextEdit
var prompt_counter: Label
var modality_buttons: Dictionary = {}
var budget_spinbox: SpinBox
var compute_spinbox: SpinBox
var stake_spinbox: SpinBox
var model_selector: OptionButton
var policy_selector: OptionButton
var visibility_selector: OptionButton
var proposal_summary: Label
var vote_summary: Label
var vote_members: VBoxContainer
var template_button: Button
var draft_button: Button
var publish_button: Button
var safety_label: Label

var _built := false
var _selected_game := "chess_core"
var _selected_modality := "image"
var _preview_metadata: Dictionary = {}
var _capacity_state: Dictionary = {}
var _vote_state: Array[Dictionary] = []
var _quorum_required := 1
var _config := {
	"max_token_budget": 1000000,
	"max_compute_gb": 4096.0,
	"max_stake_units": 10000,
	"publication_locked": false,
}
var _suppress_changes := false


func _ready() -> void:
	if _built:
		return
	_build_surface()
	_apply_configuration()
	_refresh_context(false)
	_refresh_summary(false)
	_wire_focus_order()
	_built = true


func configure(options: Dictionary = {}) -> Dictionary:
	var allowed := {
		"default_game": true,
		"default_modality": true,
		"token_budget": true,
		"compute_offer_gb": true,
		"stake_units": true,
		"max_token_budget": true,
		"max_compute_gb": true,
		"max_stake_units": true,
		"model_profile": true,
		"policy_profile": true,
		"visibility": true,
		"publication_locked": true,
	}
	var rejected_keys: Array[String] = []
	for key_variant in options.keys():
		var key := str(key_variant)
		if not allowed.has(key):
			rejected_keys.append(key)

	var requested_game := _allowlisted_id(str(options.get("default_game", _selected_game)), GAMES, _selected_game)
	var requested_modality := _allowlisted_id(str(options.get("default_modality", _selected_modality)), MODALITIES, _selected_modality)
	_selected_game = requested_game
	_selected_modality = requested_modality
	_config.max_token_budget = clampi(int(options.get("max_token_budget", _config.max_token_budget)), 1, 100000000)
	_config.max_compute_gb = clampf(float(options.get("max_compute_gb", _config.max_compute_gb)), 0.25, 1048576.0)
	_config.max_stake_units = clampi(int(options.get("max_stake_units", _config.max_stake_units)), 1, 100000000)
	_config.publication_locked = bool(options.get("publication_locked", _config.publication_locked))
	_config.token_budget = clampi(int(options.get("token_budget", _config.get("token_budget", 1200))), 0, int(_config.max_token_budget))
	_config.compute_offer_gb = clampf(float(options.get("compute_offer_gb", _config.get("compute_offer_gb", 4.0))), 0.0, float(_config.max_compute_gb))
	_config.stake_units = clampi(int(options.get("stake_units", _config.get("stake_units", 100))), 0, int(_config.max_stake_units))
	_config.model_profile = _allowlisted_id(str(options.get("model_profile", _config.get("model_profile", "community_auto"))), MODELS, "community_auto")
	_config.policy_profile = _allowlisted_id(str(options.get("policy_profile", _config.get("policy_profile", "strict_original"))), POLICIES, "strict_original")
	_config.visibility = _allowlisted_id(str(options.get("visibility", _config.get("visibility", "private_draft"))), VISIBILITIES, "private_draft")
	if _built:
		_apply_configuration()
		_refresh_context(false)
		_refresh_summary(false)
	return {
		"ok": rejected_keys.is_empty(),
		"code": "configured" if rejected_keys.is_empty() else "unknown_options_ignored",
		"rejected_keys": rejected_keys,
		"state": request_snapshot(),
	}


func select_game(game_id: String, notify := true) -> bool:
	var index := _index_for_id(GAMES, game_id)
	if index < 0:
		return false
	_selected_game = str(GAMES[index].id)
	if _built:
		_suppress_changes = true
		game_tabs.current_tab = index
		_suppress_changes = false
		_refresh_context(notify)
	if notify:
		game_selected.emit(_selected_game)
	return true


func select_modality(modality_id: String, notify := true) -> bool:
	if _index_for_id(MODALITIES, modality_id) < 0:
		return false
	_selected_modality = modality_id
	if _built:
		_suppress_changes = true
		for id_variant in modality_buttons.keys():
			var button: Button = modality_buttons[id_variant]
			button.button_pressed = str(id_variant) == modality_id
		_suppress_changes = false
		_refresh_summary(notify)
	return true


func set_preview(texture: Texture2D, metadata: Dictionary = {}) -> Dictionary:
	if texture == null:
		return clear_preview()
	_preview_metadata = _sanitize_preview_metadata(metadata)
	if _built:
		preview_rect.texture = texture
		preview_empty_label.visible = false
		preview_caption.text = _preview_caption_text()
		_refresh_summary(true)
	return {"ok": true, "code": "preview_set", "metadata": _preview_metadata.duplicate(true)}


func clear_preview() -> Dictionary:
	_preview_metadata.clear()
	if _built:
		preview_rect.texture = null
		preview_empty_label.visible = true
		preview_caption.text = "NO GENERATED ASSET ATTACHED  ·  LOCAL REVIEW BUFFER"
		_refresh_summary(true)
	return {"ok": true, "code": "preview_cleared"}


func set_capacity_summary(summary: Dictionary) -> Dictionary:
	_capacity_state = {
		"opt_in_contributors": clampi(int(summary.get("opt_in_contributors", summary.get("online_contributors", 0))), 0, 10000000),
		"offered_ram_gb": snappedf(clampf(float(summary.get("offered_ram_gb", 0.0)), 0.0, 104857600.0), 0.25),
		"available_ram_gb": snappedf(clampf(float(summary.get("available_ram_gb", 0.0)), 0.0, 104857600.0), 0.25),
		"queued_proposals": clampi(int(summary.get("queued_proposals", 0)), 0, 100000000),
		"source": _sanitize_single_line(str(summary.get("source", "host aggregate")), MAX_METADATA_VALUE_LENGTH),
	}
	_capacity_state.available_ram_gb = minf(float(_capacity_state.available_ram_gb), float(_capacity_state.offered_ram_gb))
	if _built:
		_refresh_capacity_summary()
		_refresh_summary(true)
	return {"ok": true, "code": "capacity_summary_set", "summary": _capacity_state.duplicate(true)}


func set_vote_status(status, quorum_required: int = 1) -> Dictionary:
	var members: Array = []
	if status is Dictionary:
		members = status.get("members", []) if status.get("members", []) is Array else []
		quorum_required = int(status.get("quorum_required", quorum_required))
	elif status is Array:
		members = status
	else:
		return {"ok": false, "code": "invalid_vote_status", "accepted_members": 0, "quorum_required": 1}
	var safe_members: Array[Dictionary] = []
	var seen_ids := {}
	for member_variant in members:
		if safe_members.size() >= MAX_MEMBER_COUNT or not (member_variant is Dictionary):
			continue
		var member: Dictionary = member_variant
		var member_id := _sanitize_single_line(str(member.get("id", "")), MAX_MEMBER_LABEL_LENGTH)
		if member_id.is_empty() or seen_ids.has(member_id):
			continue
		seen_ids[member_id] = true
		var display_name := _sanitize_single_line(str(member.get("display_name", member_id)), MAX_MEMBER_LABEL_LENGTH)
		var vote := str(member.get("vote", "pending")).to_lower()
		if vote not in VOTE_STATES:
			vote = "pending"
		var online := bool(member.get("online", false))
		var activity_weight := clampf(float(member.get("activity_weight", 1.0)), 0.0, 100.0)
		safe_members.append({
			"id": member_id,
			"display_name": display_name if not display_name.is_empty() else member_id,
			"vote": vote,
			"online": online,
			"activity_weight": snappedf(activity_weight, 0.01),
		})
	_vote_state = safe_members
	_quorum_required = clampi(quorum_required, 1, maxi(safe_members.size(), 1))
	if _built:
		_rebuild_vote_rows()
		_refresh_summary(true)
	return {
		"ok": true,
		"code": "vote_status_set",
		"accepted_members": safe_members.size(),
		"quorum_required": _quorum_required,
	}


func load_structured_prompt() -> String:
	var template := _prompt_template(_selected_game, _selected_modality)
	if _built:
		prompt_editor.text = template
		prompt_editor.set_caret_line(0)
		prompt_editor.set_caret_column(0)
		_refresh_summary(true)
	return template


func request_snapshot() -> Dictionary:
	var title := ""
	var prompt := ""
	var constraints := ""
	var token_budget := int(_config.get("token_budget", 1200))
	var compute_offer := float(_config.get("compute_offer_gb", 4.0))
	var stake_units := int(_config.get("stake_units", 100))
	var model_id := str(_config.get("model_profile", "community_auto"))
	var policy_id := str(_config.get("policy_profile", "strict_original"))
	var visibility_id := str(_config.get("visibility", "private_draft"))
	if _built:
		title = _sanitize_single_line(proposal_title.text, MAX_TITLE_LENGTH)
		prompt = _sanitize_multiline(prompt_editor.text, MAX_PROMPT_LENGTH)
		constraints = _sanitize_multiline(constraints_editor.text, MAX_CONSTRAINT_LENGTH)
		token_budget = clampi(int(budget_spinbox.value), 0, int(_config.max_token_budget))
		compute_offer = snappedf(clampf(float(compute_spinbox.value), 0.0, float(_config.max_compute_gb)), 0.25)
		stake_units = clampi(int(stake_spinbox.value), 0, int(_config.max_stake_units))
		model_id = _selected_option_id(model_selector, MODELS, "community_auto")
		policy_id = _selected_option_id(policy_selector, POLICIES, "strict_original")
		visibility_id = _selected_option_id(visibility_selector, VISIBILITIES, "private_draft")
	var prompt_digest := (prompt + "\n--constraints--\n" + constraints).sha256_text()
	return {
		"schema_version": SCHEMA_VERSION,
		"operation": "generation_proposal",
		"execution": "proposal_only",
		"network_calls_performed": false,
		"game_id": _selected_game,
		"modality": _selected_modality,
		"title": title,
		"prompt": prompt,
		"constraints": constraints,
		"prompt_digest_sha256": prompt_digest,
		"contribution": {
			"token_budget": token_budget,
			"compute_offer_gb": compute_offer,
			"stake_units": stake_units,
		},
		"routing": {
			"model_profile": model_id,
			"policy_profile": policy_id,
			"visibility": visibility_id,
		},
		"preview_receipt": _preview_metadata.duplicate(true),
		"capacity_snapshot": _capacity_state.duplicate(true),
		"vote_snapshot": {
			"quorum_required": _quorum_required,
			"members": _vote_state.duplicate(true),
			"tally": _vote_tally(),
		},
		"requirements": {
			"human_review": true,
			"license_review": true,
			"provenance_receipt": true,
			"deterministic_gameplay_unchanged": true,
			"unanimous_online_consent_not_replaceable_by_stake": true,
		},
	}


func submit_draft() -> Dictionary:
	var request := request_snapshot()
	request["intent"] = "save_draft"
	asset_request_drafted.emit(request.duplicate(true))
	return request


func request_publish() -> Dictionary:
	var request := request_snapshot()
	request["intent"] = "request_publication"
	request["publication_locked"] = bool(_config.publication_locked)
	asset_publish_requested.emit(request.duplicate(true))
	return request


func _build_surface() -> void:
	name = "PlayerAssetForgeStudio"
	custom_minimum_size = Vector2(1120, 720)
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", _panel(DEEP, 20, Color("#304059"), 1))

	var outer := MarginContainer.new()
	outer.add_theme_constant_override("margin_left", 20)
	outer.add_theme_constant_override("margin_top", 18)
	outer.add_theme_constant_override("margin_right", 20)
	outer.add_theme_constant_override("margin_bottom", 18)
	add_child(outer)
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 12)
	outer.add_child(page)

	page.add_child(_build_header())
	page.add_child(_build_game_tabs())
	var divider := HSeparator.new()
	divider.add_theme_color_override("separator", LINE)
	page.add_child(divider)

	var main_row := HBoxContainer.new()
	main_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_row.add_theme_constant_override("separation", 14)
	main_row.add_child(_build_preview_column())
	main_row.add_child(_build_composer_column())
	page.add_child(main_row)
	page.add_child(_build_action_bar())


func _build_header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	var mark := Label.new()
	mark.text = "◇"
	mark.add_theme_font_size_override("font_size", 29)
	mark.add_theme_color_override("font_color", CYAN)
	mark.tooltip_text = "Nexus community creation surface"
	row.add_child(mark)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_theme_constant_override("separation", 1)
	var title := Label.new()
	title.text = "PLAYER ASSET FORGE"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", TEXT)
	titles.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "DESIGN THESIS  /  0.001% HARNESS  ·  99.999% COMMUNITY EVOLUTION  /  BRIEF → REVIEW → VOTE → PUBLISH"
	subtitle.add_theme_font_size_override("font_size", 9)
	subtitle.add_theme_color_override("font_color", MUTED)
	titles.add_child(subtitle)
	row.add_child(titles)
	var status := Label.new()
	status.text = "●  PROPOSAL-ONLY  /  ZERO NETWORK CALLS"
	status.tooltip_text = "This control only composes requests; it cannot run a model or publish data."
	status.add_theme_font_size_override("font_size", 9)
	status.add_theme_color_override("font_color", LIME)
	status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(status)
	return row


func _build_game_tabs() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	game_tabs = TabBar.new()
	game_tabs.name = "GameTabs"
	game_tabs.focus_mode = Control.FOCUS_ALL
	game_tabs.tooltip_text = "Choose which deterministic demo game this asset proposal targets"
	game_tabs.add_theme_font_size_override("font_size", 11)
	game_tabs.add_theme_color_override("font_selected", CYAN)
	game_tabs.add_theme_color_override("font_unselected", MUTED)
	for game in GAMES:
		game_tabs.add_tab(str(game.label))
		game_tabs.set_tab_tooltip(game_tabs.tab_count - 1, str(game.description))
	game_tabs.tab_changed.connect(_on_game_tab_changed)
	box.add_child(game_tabs)
	game_context_label = Label.new()
	game_context_label.name = "GameContext"
	game_context_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	game_context_label.add_theme_font_size_override("font_size", 10)
	game_context_label.add_theme_color_override("font_color", Color("#aab7ca"))
	box.add_child(game_context_label)
	return box


func _build_preview_column() -> Control:
	var column := VBoxContainer.new()
	column.custom_minimum_size.x = 400
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 10)
	column.add_child(_section_label("GENERATED ART PREVIEW", CYAN))

	var preview_panel := PanelContainer.new()
	preview_panel.custom_minimum_size = Vector2(400, 285)
	preview_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview_panel.add_theme_stylebox_override("panel", _panel(Color("#050912"), 14, Color("#31425e"), 1))
	var preview_stack := Control.new()
	preview_stack.clip_contents = true
	preview_panel.add_child(preview_stack)
	preview_rect = TextureRect.new()
	preview_rect.name = "GeneratedArtPreview"
	preview_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview_rect.tooltip_text = "Local generated-asset preview; publication requires an external provenance receipt"
	preview_stack.add_child(preview_rect)
	var scan := ColorRect.new()
	scan.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scan.color = Color("#5de1f408")
	scan.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview_stack.add_child(scan)
	preview_empty_label = Label.new()
	preview_empty_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview_empty_label.text = "◇\n\nNO ASSET GENERATED\nATTACH A REVIEW PREVIEW THROUGH set_preview()"
	preview_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	preview_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	preview_empty_label.add_theme_font_size_override("font_size", 11)
	preview_empty_label.add_theme_color_override("font_color", MUTED)
	preview_empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview_stack.add_child(preview_empty_label)
	column.add_child(preview_panel)

	preview_caption = Label.new()
	preview_caption.text = "NO GENERATED ASSET ATTACHED  ·  LOCAL REVIEW BUFFER"
	preview_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preview_caption.add_theme_font_size_override("font_size", 9)
	preview_caption.add_theme_color_override("font_color", CYAN)
	column.add_child(preview_caption)
	capacity_summary_label = Label.new()
	capacity_summary_label.name = "CapacitySummary"
	capacity_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	capacity_summary_label.tooltip_text = "Host-supplied aggregate of voluntary compute offers; this UI never allocates peer resources"
	capacity_summary_label.add_theme_font_size_override("font_size", 9)
	capacity_summary_label.add_theme_color_override("font_color", VIOLET)
	column.add_child(capacity_summary_label)
	_refresh_capacity_summary()

	var vote_panel := PanelContainer.new()
	vote_panel.add_theme_stylebox_override("panel", _panel(SURFACE, 12, LINE, 1))
	var vote_margin := _margin(12, 10, 12, 10)
	vote_panel.add_child(vote_margin)
	var votes := VBoxContainer.new()
	votes.add_theme_constant_override("separation", 6)
	vote_margin.add_child(votes)
	var vote_head := HBoxContainer.new()
	var vote_title := _section_label("ONLINE MEMBER REVIEW", VIOLET)
	vote_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vote_head.add_child(vote_title)
	vote_summary = Label.new()
	vote_summary.add_theme_font_size_override("font_size", 9)
	vote_summary.add_theme_color_override("font_color", AMBER)
	vote_head.add_child(vote_summary)
	votes.add_child(vote_head)
	vote_members = VBoxContainer.new()
	vote_members.add_theme_constant_override("separation", 3)
	votes.add_child(vote_members)
	column.add_child(vote_panel)
	_rebuild_vote_rows()
	return column


func _build_composer_column() -> Control:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 8)

	var brief_head := HBoxContainer.new()
	var prompt_title := _section_label("ADVANCED GENERATION BRIEF", VIOLET)
	prompt_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	brief_head.add_child(prompt_title)
	template_button = _small_button("LOAD GAME BLUEPRINT", VIOLET)
	template_button.name = "LoadStructuredPrompt"
	template_button.tooltip_text = "Replace the prompt with an original, game-specific structured brief"
	template_button.pressed.connect(load_structured_prompt)
	brief_head.add_child(template_button)
	column.add_child(brief_head)

	proposal_title = LineEdit.new()
	proposal_title.name = "ProposalTitle"
	proposal_title.placeholder_text = "Proposal title — concise, original, and searchable"
	proposal_title.max_length = MAX_TITLE_LENGTH
	proposal_title.focus_mode = Control.FOCUS_ALL
	proposal_title.tooltip_text = "A short community-facing title; maximum %d characters" % MAX_TITLE_LENGTH
	_style_line_edit(proposal_title)
	proposal_title.text_changed.connect(_on_text_changed)
	column.add_child(proposal_title)

	prompt_editor = TextEdit.new()
	prompt_editor.name = "PromptComposer"
	prompt_editor.custom_minimum_size.y = 138
	prompt_editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	prompt_editor.placeholder_text = "Describe composition, materials, silhouettes, state readability, animation beats, sound layers, accessibility, originality constraints, and export targets…"
	prompt_editor.focus_mode = Control.FOCUS_ALL
	prompt_editor.tooltip_text = "Generation instructions are sanitized and capped at %d characters before emission" % MAX_PROMPT_LENGTH
	_style_text_edit(prompt_editor)
	prompt_editor.text_changed.connect(_on_prompt_changed)
	column.add_child(prompt_editor)

	var counter_row := HBoxContainer.new()
	safety_label = Label.new()
	safety_label.text = "SANITIZED ON EMIT  ·  HUMAN + LICENSE REVIEW REQUIRED"
	safety_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	safety_label.add_theme_font_size_override("font_size", 8)
	safety_label.add_theme_color_override("font_color", LIME)
	counter_row.add_child(safety_label)
	prompt_counter = Label.new()
	prompt_counter.text = "0 / %d" % MAX_PROMPT_LENGTH
	prompt_counter.add_theme_font_size_override("font_size", 8)
	prompt_counter.add_theme_color_override("font_color", MUTED)
	counter_row.add_child(prompt_counter)
	column.add_child(counter_row)

	constraints_editor = TextEdit.new()
	constraints_editor.name = "GenerationConstraints"
	constraints_editor.custom_minimum_size.y = 62
	constraints_editor.placeholder_text = "Negative constraints — avoid logos, copied characters, illegible states, unsafe content, or gameplay ambiguity"
	constraints_editor.focus_mode = Control.FOCUS_ALL
	constraints_editor.tooltip_text = "Explicit exclusions and acceptance constraints; maximum %d characters" % MAX_CONSTRAINT_LENGTH
	_style_text_edit(constraints_editor)
	constraints_editor.text_changed.connect(_on_text_changed)
	column.add_child(constraints_editor)

	column.add_child(_section_label("OUTPUT MODALITY", CYAN))
	var chip_row := HBoxContainer.new()
	chip_row.add_theme_constant_override("separation", 6)
	var modality_group := ButtonGroup.new()
	modality_group.allow_unpress = false
	for modality in MODALITIES:
		var chip := _chip(str(modality.label))
		chip.name = "Modality_" + str(modality.id)
		chip.toggle_mode = true
		chip.button_group = modality_group
		chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chip.tooltip_text = str(modality.hint)
		chip.toggled.connect(_on_modality_toggled.bind(str(modality.id)))
		modality_buttons[str(modality.id)] = chip
		chip_row.add_child(chip)
	column.add_child(chip_row)

	var resource_grid := GridContainer.new()
	resource_grid.columns = 3
	resource_grid.add_theme_constant_override("h_separation", 8)
	resource_grid.add_theme_constant_override("v_separation", 4)
	column.add_child(resource_grid)
	budget_spinbox = _resource_spin("TOKEN BUDGET", "TOKENS", 1.0)
	compute_spinbox = _resource_spin("RAM OFFER", "GB", 0.25)
	stake_spinbox = _resource_spin("STAKE WEIGHT", "UNITS", 1.0)
	resource_grid.add_child(_labeled_control("CONTRIBUTION BUDGET", budget_spinbox, "Maximum community token contribution offered to the host scheduler"))
	resource_grid.add_child(_labeled_control("COMPUTE / RAM OFFER", compute_spinbox, "Voluntary RAM capacity offer; no resource is allocated by this control"))
	resource_grid.add_child(_labeled_control("WEIGHTED STAKE", stake_spinbox, "Declared proposal stake; the governance engine must calculate final voting influence"))
	budget_spinbox.value_changed.connect(_on_numeric_changed)
	compute_spinbox.value_changed.connect(_on_numeric_changed)
	stake_spinbox.value_changed.connect(_on_numeric_changed)

	var routing_grid := GridContainer.new()
	routing_grid.columns = 3
	routing_grid.add_theme_constant_override("h_separation", 8)
	column.add_child(routing_grid)
	model_selector = _option(MODELS, "Select a host-owned generation adapter; this UI never invokes it")
	policy_selector = _option(POLICIES, "Select the review policy requested for this proposal")
	visibility_selector = _option(VISIBILITIES, "Select the requested data tier; enforcement belongs to the host")
	routing_grid.add_child(_labeled_control("MODEL ROUTE", model_selector, model_selector.tooltip_text))
	routing_grid.add_child(_labeled_control("REVIEW POLICY", policy_selector, policy_selector.tooltip_text))
	routing_grid.add_child(_labeled_control("VISIBILITY", visibility_selector, visibility_selector.tooltip_text))
	model_selector.item_selected.connect(_on_option_changed)
	policy_selector.item_selected.connect(_on_option_changed)
	visibility_selector.item_selected.connect(_on_option_changed)

	var summary_panel := PanelContainer.new()
	summary_panel.add_theme_stylebox_override("panel", _panel(Color("#0d1726"), 10, Color("#30445e"), 1))
	var summary_margin := _margin(10, 8, 10, 8)
	summary_panel.add_child(summary_margin)
	proposal_summary = Label.new()
	proposal_summary.name = "ProposalSummary"
	proposal_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	proposal_summary.add_theme_font_size_override("font_size", 9)
	proposal_summary.add_theme_color_override("font_color", Color("#c4d1e3"))
	proposal_summary.tooltip_text = "Read-only summary of the sanitized proposal envelope"
	summary_margin.add_child(proposal_summary)
	column.add_child(summary_panel)
	return column


func _build_action_bar() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var notice := Label.new()
	notice.text = "CAPACITY IS OPT-IN / OFFERED  ·  STAKE MAY PRIORITIZE REVIEW; IT NEVER REPLACES UNANIMOUS ONLINE-MEMBER CONSENT"
	notice.tooltip_text = "Compute remains voluntary and revocable. Every online lobby member must consent independently of stake."
	notice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	notice.add_theme_font_size_override("font_size", 8)
	notice.add_theme_color_override("font_color", MUTED)
	notice.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(notice)
	draft_button = _small_button("SAVE PROPOSAL DRAFT", Color("#9fb0c6"))
	draft_button.name = "SaveProposalDraft"
	draft_button.tooltip_text = "Emit a sanitized draft request to the owning scene"
	draft_button.pressed.connect(submit_draft)
	row.add_child(draft_button)
	publish_button = _primary_button("REQUEST MEMBER PUBLICATION", CYAN)
	publish_button.name = "RequestPublication"
	publish_button.tooltip_text = "Emit a publication request; the host must still review provenance, quorum, and signatures"
	publish_button.pressed.connect(request_publish)
	row.add_child(publish_button)
	return row


func _apply_configuration() -> void:
	if game_tabs == null:
		return
	_suppress_changes = true
	var game_index := maxi(_index_for_id(GAMES, _selected_game), 0)
	game_tabs.current_tab = game_index
	for id_variant in modality_buttons.keys():
		var button: Button = modality_buttons[id_variant]
		button.button_pressed = str(id_variant) == _selected_modality
	budget_spinbox.max_value = float(_config.max_token_budget)
	budget_spinbox.value = float(_config.get("token_budget", 1200))
	compute_spinbox.max_value = float(_config.max_compute_gb)
	compute_spinbox.value = float(_config.get("compute_offer_gb", 4.0))
	stake_spinbox.max_value = float(_config.max_stake_units)
	stake_spinbox.value = float(_config.get("stake_units", 100))
	_select_option(model_selector, str(_config.get("model_profile", "community_auto")))
	_select_option(policy_selector, str(_config.get("policy_profile", "strict_original")))
	_select_option(visibility_selector, str(_config.get("visibility", "private_draft")))
	publish_button.text = "REQUEST MEMBER PUBLICATION" if not bool(_config.publication_locked) else "REQUEST REVIEW / PUBLICATION LOCKED"
	publish_button.tooltip_text = (
		"Emit a publication request; the host must still review provenance, quorum, and signatures"
		if not bool(_config.publication_locked)
		else "Publication is host-locked; emit a review request without claiming publication"
	)
	_suppress_changes = false


func _refresh_context(notify := true) -> void:
	if not _built and game_context_label == null:
		return
	var game: Dictionary = GAMES[maxi(_index_for_id(GAMES, _selected_game), 0)]
	game_context_label.text = "%s ASSET LATTICE  ·  %s" % [str(game.short), str(game.description)]
	if proposal_title != null and proposal_title.text.is_empty():
		proposal_title.placeholder_text = "%s community asset proposal" % str(game.short).capitalize()
	_refresh_summary(notify)


func _refresh_summary(notify := true) -> void:
	if proposal_summary == null:
		return
	var snapshot := request_snapshot()
	var game_label := _label_for_id(GAMES, str(snapshot.game_id))
	var modality_label := _label_for_id(MODALITIES, str(snapshot.modality))
	var contribution: Dictionary = snapshot.contribution
	var routing: Dictionary = snapshot.routing
	var tally: Dictionary = snapshot.vote_snapshot.tally
	proposal_summary.text = (
		"%s  /  %s  ·  %s tokens  ·  %.2f GB RAM  ·  %s stake units\n"
		+ "%s  ·  %s  ·  %s  ·  votes %s/%s  ·  preview %s"
	) % [
		game_label,
		modality_label,
		str(contribution.token_budget),
		float(contribution.compute_offer_gb),
		str(contribution.stake_units),
		_label_for_id(MODELS, str(routing.model_profile)),
		_label_for_id(POLICIES, str(routing.policy_profile)),
		_label_for_id(VISIBILITIES, str(routing.visibility)),
		str(tally.approve),
		str(_quorum_required),
		"attached" if not _preview_metadata.is_empty() else "pending",
	]
	if notify and not _suppress_changes:
		request_changed.emit(snapshot.duplicate(true))


func _rebuild_vote_rows() -> void:
	if vote_members == null:
		return
	for child in vote_members.get_children():
		child.queue_free()
	var tally := _vote_tally()
	var online_count := 0
	for member in _vote_state:
		if bool(member.online):
			online_count += 1
	vote_summary.text = "%d ONLINE  ·  %d/%d APPROVE" % [online_count, int(tally.approve), _quorum_required]
	vote_summary.add_theme_color_override("font_color", LIME if int(tally.approve) >= _quorum_required else AMBER)
	if _vote_state.is_empty():
		var empty := Label.new()
		empty.text = "No lobby receipt attached. The host supplies authenticated member status."
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_font_size_override("font_size", 9)
		empty.add_theme_color_override("font_color", MUTED)
		vote_members.add_child(empty)
		return
	for member in _vote_state.slice(0, 5):
		var row := HBoxContainer.new()
		var presence := Label.new()
		presence.text = "●" if bool(member.online) else "○"
		presence.tooltip_text = "Online" if bool(member.online) else "Offline"
		presence.add_theme_color_override("font_color", LIME if bool(member.online) else MUTED)
		row.add_child(presence)
		var name_label := Label.new()
		name_label.text = str(member.display_name)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.add_theme_font_size_override("font_size", 9)
		name_label.add_theme_color_override("font_color", TEXT)
		row.add_child(name_label)
		var weight := Label.new()
		weight.text = "×%.2f" % float(member.activity_weight)
		weight.tooltip_text = "Advisory activity weight supplied by the host; not calculated by this UI"
		weight.add_theme_font_size_override("font_size", 8)
		weight.add_theme_color_override("font_color", MUTED)
		row.add_child(weight)
		var vote := Label.new()
		vote.text = str(member.vote).to_upper()
		vote.add_theme_font_size_override("font_size", 8)
		vote.add_theme_color_override("font_color", _vote_color(str(member.vote)))
		row.add_child(vote)
		vote_members.add_child(row)
	if _vote_state.size() > 5:
		var remaining := Label.new()
		remaining.text = "+ %d more members in signed host snapshot" % (_vote_state.size() - 5)
		remaining.add_theme_font_size_override("font_size", 8)
		remaining.add_theme_color_override("font_color", MUTED)
		vote_members.add_child(remaining)


func _refresh_capacity_summary() -> void:
	if capacity_summary_label == null:
		return
	if _capacity_state.is_empty():
		capacity_summary_label.text = "OPT-IN HIVE CAPACITY  ·  NO HOST AGGREGATE ATTACHED  ·  0 GB ALLOCATED"
		return
	capacity_summary_label.text = (
		"OPT-IN HIVE CAPACITY  ·  %d CONTRIBUTORS  ·  %.2f GB OFFERED  ·  %.2f GB AVAILABLE  ·  %d QUEUED"
	) % [
		int(_capacity_state.opt_in_contributors),
		float(_capacity_state.offered_ram_gb),
		float(_capacity_state.available_ram_gb),
		int(_capacity_state.queued_proposals),
	]


func _vote_tally() -> Dictionary:
	var tally := {"approve": 0, "reject": 0, "pending": 0, "abstain": 0, "weighted_approve": 0.0}
	for member in _vote_state:
		var vote := str(member.get("vote", "pending"))
		tally[vote] = int(tally.get(vote, 0)) + 1
		if vote == "approve":
			tally.weighted_approve = snappedf(float(tally.weighted_approve) + float(member.get("activity_weight", 1.0)), 0.01)
	return tally


func _on_game_tab_changed(index: int) -> void:
	if _suppress_changes or index < 0 or index >= GAMES.size():
		return
	_selected_game = str(GAMES[index].id)
	_refresh_context(true)
	game_selected.emit(_selected_game)


func _on_modality_toggled(pressed: bool, modality_id: String) -> void:
	if _suppress_changes or not pressed:
		return
	_selected_modality = modality_id
	_refresh_summary(true)


func _on_prompt_changed() -> void:
	prompt_counter.text = "%d / %d" % [mini(prompt_editor.text.length(), MAX_PROMPT_LENGTH), MAX_PROMPT_LENGTH]
	prompt_counter.add_theme_color_override("font_color", AMBER if prompt_editor.text.length() > MAX_PROMPT_LENGTH else MUTED)
	_refresh_summary(true)


func _on_text_changed(_unused := "") -> void:
	_refresh_summary(true)


func _on_numeric_changed(_value: float) -> void:
	_refresh_summary(true)


func _on_option_changed(_index: int) -> void:
	_refresh_summary(true)


func _prompt_template(game_id: String, modality_id: String) -> String:
	var subject: String = {
		"chess_core": "an original tournament chess asset family with unmistakable piece silhouettes, rank/file orientation, legal-target clarity, and equal visual hierarchy for both sides",
		"four_line": "an original four-in-a-row asset family with seven readable columns, six rows, tactile drop channels, distinct token ownership, and an immediate four-token victory trace",
		"draughts": "an original draughts asset family with 8×8 orientation, clearly playable dark squares, distinct men and crowned kings, readable capture paths, and equal faction contrast",
		"property_grid": "an original property-trading loop with sixteen readable spaces, invented district identities, unambiguous ownership, original cards and currency, distinct pawns, and clear turn/economy feedback",
	}.get(game_id, "an original deterministic tabletop asset family")
	var output: String = {
		"image": "Produce a production-ready visual concept sheet plus isolated transparent-background asset candidates. Specify front, three-quarter, top-down, active, disabled, selected, and conflict states where applicable.",
		"audio": "Design a layered, loop-safe audio family: restrained ambience, interaction transients, success/failure cues, and optional speech cadence notes. Avoid copyrighted melodies or recognizable voice imitation.",
		"world": "Design a coherent modular world kit: table, arena boundary, lighting language, interaction landmarks, performance tiers, camera-safe silhouettes, and seamless material families.",
		"ui_kit": "Design an accessible state-complete UI kit: navigation, action controls, turn state, resource display, selection, warnings, votes, focus, disabled, hover, and reduced-motion variants.",
		"voice_to_text": "Design a privacy-first voice-to-text interaction contract: explicit recording consent, local buffering, partial transcript, confidence, correction, discard, speaker-neutral labels, and a separate reviewed publish action.",
	}.get(modality_id, "Produce a coherent original asset family.")
	return (
		"CREATIVE INTENT\n"
		+ "Create %s. The result should feel native to the Nexus / Forge universe: dark astronomical materials, restrained cyan telemetry, violet community signals, and warm exception states—without copying any existing game art, logo, character, board, or franchise treatment.\n\n" % subject
		+ "OUTPUT CONTRACT\n%s\n\n" % output
		+ "SYSTEM READABILITY\nDefine the full visual/audio state matrix. Preserve gameplay meaning at thumbnail scale, under color-vision deficiency simulation, in high contrast, and with reduced motion. Cosmetic layers must never hide legal moves, ownership, turn order, price, vote, or failure state.\n\n"
		+ "ORIGINALITY + PROVENANCE\nUse only newly described forms, symbols, names, rhythms, and materials. Include a proposed seed, generator/adapter identifier, source-policy receipt, dimensions or duration, export targets, and a SHA-256 content receipt for every accepted output. Mark uncertainty for human license review.\n\n"
		+ "TECHNICAL DELIVERY\nSeparate semantic gameplay layers from cosmetic layers. Name variants consistently. Prefer modular atlases and deterministic parameters. Budget memory and draw/audio voices for desktop and low-resource peers. Include graceful fallbacks when generation, decoding, or peer retrieval is unavailable."
	)


func _sanitize_multiline(value: String, max_length: int) -> String:
	var normalized := value.replace("\r\n", "\n").replace("\r", "\n")
	var output := ""
	for index in range(normalized.length()):
		var code := normalized.unicode_at(index)
		if code in [9, 10]:
			output += char(code)
		elif code >= 32 and code != 127 and not _is_directional_control(code):
			output += char(code)
		if output.length() >= max_length:
			break
	var lines := output.split("\n", true, 80)
	return "\n".join(lines).strip_edges()


func _sanitize_single_line(value: String, max_length: int) -> String:
	return _sanitize_multiline(value.replace("\n", " ").replace("\r", " ").replace("\t", " "), max_length).strip_edges()


func _is_directional_control(code: int) -> bool:
	return (code >= 0x202A and code <= 0x202E) or (code >= 0x2066 and code <= 0x2069) or code == 0xFEFF


func _sanitize_preview_metadata(metadata: Dictionary) -> Dictionary:
	var safe := {}
	var text_keys := ["generator", "adapter", "seed", "content_id", "prompt_digest_sha256", "license_status", "alt_text"]
	for key in text_keys:
		if metadata.has(key):
			safe[key] = _sanitize_single_line(str(metadata[key]), MAX_METADATA_VALUE_LENGTH)
	if metadata.has("width"):
		safe.width = clampi(int(metadata.width), 0, 32768)
	if metadata.has("height"):
		safe.height = clampi(int(metadata.height), 0, 32768)
	if metadata.has("duration_seconds"):
		safe.duration_seconds = snappedf(clampf(float(metadata.duration_seconds), 0.0, 86400.0), 0.001)
	return safe


func _preview_caption_text() -> String:
	var generator := str(_preview_metadata.get("generator", _preview_metadata.get("adapter", "UNREPORTED ADAPTER"))).to_upper()
	var size := ""
	if int(_preview_metadata.get("width", 0)) > 0 and int(_preview_metadata.get("height", 0)) > 0:
		size = "  ·  %d×%d" % [int(_preview_metadata.width), int(_preview_metadata.height)]
	return "LOCAL PREVIEW  ·  %s%s  ·  PROVENANCE REVIEW REQUIRED" % [generator, size]


func _allowlisted_id(value: String, source: Array, fallback: String) -> String:
	return value if _index_for_id(source, value) >= 0 else fallback


func _index_for_id(source: Array, value: String) -> int:
	for index in range(source.size()):
		if str(source[index].id) == value:
			return index
	return -1


func _label_for_id(source: Array, value: String) -> String:
	var index := _index_for_id(source, value)
	return str(source[index].label) if index >= 0 else value.to_upper()


func _selected_option_id(option: OptionButton, source: Array, fallback: String) -> String:
	if option == null or option.selected < 0 or option.selected >= source.size():
		return fallback
	var metadata = option.get_item_metadata(option.selected)
	return _allowlisted_id(str(metadata), source, fallback)


func _select_option(option: OptionButton, target_id: String) -> void:
	for index in range(option.item_count):
		if str(option.get_item_metadata(index)) == target_id:
			option.select(index)
			return
	option.select(0)


func _wire_focus_order() -> void:
	var controls: Array[Control] = [game_tabs, proposal_title, prompt_editor, constraints_editor]
	for modality in MODALITIES:
		controls.append(modality_buttons[str(modality.id)])
	controls.append_array([budget_spinbox, compute_spinbox, stake_spinbox, model_selector, policy_selector, visibility_selector, template_button, draft_button, publish_button])
	for index in range(controls.size()):
		var control := controls[index]
		var next := controls[(index + 1) % controls.size()]
		var previous := controls[(index - 1 + controls.size()) % controls.size()]
		control.focus_next = control.get_path_to(next)
		control.focus_previous = control.get_path_to(previous)


func _resource_spin(label_text: String, suffix_text: String, step: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.name = label_text.to_pascal_case().replace(" ", "")
	spin.min_value = 0.0
	spin.step = step
	spin.suffix = " " + suffix_text
	spin.allow_greater = false
	spin.allow_lesser = false
	spin.focus_mode = Control.FOCUS_ALL
	spin.custom_minimum_size.x = 150
	spin.get_line_edit().add_theme_color_override("font_color", TEXT)
	spin.get_line_edit().add_theme_stylebox_override("normal", _panel(SURFACE, 7, LINE, 1))
	return spin


func _option(source: Array, tooltip: String) -> OptionButton:
	var option := OptionButton.new()
	option.focus_mode = Control.FOCUS_ALL
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.tooltip_text = tooltip
	option.add_theme_font_size_override("font_size", 9)
	option.add_theme_color_override("font_color", TEXT)
	option.add_theme_stylebox_override("normal", _panel(SURFACE, 8, LINE, 1))
	for entry in source:
		option.add_item(str(entry.label))
		option.set_item_metadata(option.item_count - 1, str(entry.id))
	return option


func _labeled_control(label_text: String, control: Control, tooltip: String) -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 3)
	var label := Label.new()
	label.text = label_text
	label.tooltip_text = tooltip
	label.add_theme_font_size_override("font_size", 8)
	label.add_theme_color_override("font_color", MUTED)
	box.add_child(label)
	control.tooltip_text = tooltip
	box.add_child(control)
	return box


func _section_label(value: String, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", 9)
	label.add_theme_color_override("font_color", color)
	return label


func _chip(value: String) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size.y = 30
	button.focus_mode = Control.FOCUS_ALL
	button.add_theme_font_size_override("font_size", 9)
	button.add_theme_color_override("font_color", MUTED)
	button.add_theme_color_override("font_hover_color", TEXT)
	button.add_theme_color_override("font_pressed_color", CYAN)
	button.add_theme_stylebox_override("normal", _panel(SURFACE, 8, LINE, 1))
	button.add_theme_stylebox_override("hover", _panel(Color("#18243a"), 8, Color("#405574"), 1))
	button.add_theme_stylebox_override("pressed", _panel(Color("#142b3a"), 8, CYAN, 1))
	return button


func _small_button(value: String, accent: Color) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size.y = 34
	button.focus_mode = Control.FOCUS_ALL
	button.add_theme_font_size_override("font_size", 9)
	button.add_theme_color_override("font_color", accent)
	button.add_theme_color_override("font_hover_color", TEXT)
	button.add_theme_stylebox_override("normal", _panel(SURFACE, 8, LINE, 1))
	button.add_theme_stylebox_override("hover", _panel(Color("#19243a"), 8, accent, 1))
	button.add_theme_stylebox_override("pressed", _panel(Color("#20314b"), 8, accent, 1))
	return button


func _primary_button(value: String, accent: Color) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size = Vector2(260, 38)
	button.focus_mode = Control.FOCUS_ALL
	button.add_theme_font_size_override("font_size", 9)
	button.add_theme_color_override("font_color", Color("#061019"))
	button.add_theme_stylebox_override("normal", _panel(accent, 9, accent, 1))
	button.add_theme_stylebox_override("hover", _panel(accent.lightened(0.14), 9, Color.WHITE, 1))
	button.add_theme_stylebox_override("pressed", _panel(accent.darkened(0.16), 9, accent, 1))
	return button


func _style_line_edit(editor: LineEdit) -> void:
	editor.add_theme_font_size_override("font_size", 11)
	editor.add_theme_color_override("font_color", TEXT)
	editor.add_theme_color_override("font_placeholder_color", MUTED)
	editor.add_theme_stylebox_override("normal", _panel(Color("#070c15"), 9, LINE, 1))
	editor.add_theme_stylebox_override("focus", _panel(Color("#09111e"), 9, CYAN, 1))


func _style_text_edit(editor: TextEdit) -> void:
	editor.add_theme_font_size_override("font_size", 10)
	editor.add_theme_color_override("font_color", TEXT)
	editor.add_theme_color_override("font_placeholder_color", MUTED)
	editor.add_theme_stylebox_override("normal", _panel(Color("#070c15"), 10, LINE, 1))
	editor.add_theme_stylebox_override("focus", _panel(Color("#09111e"), 10, CYAN, 1))


func _margin(left: int, top: int, right: int, bottom: int) -> MarginContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", left)
	margin.add_theme_constant_override("margin_top", top)
	margin.add_theme_constant_override("margin_right", right)
	margin.add_theme_constant_override("margin_bottom", bottom)
	return margin


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
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	return style


func _vote_color(vote: String) -> Color:
	match vote:
		"approve":
			return LIME
		"reject":
			return RED
		"abstain":
			return MUTED
		_:
			return AMBER
