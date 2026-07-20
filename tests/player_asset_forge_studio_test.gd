extends SceneTree

const PlayerAssetForgeStudio = preload("res://ui/player_asset_forge_studio.gd")

var failures: Array[String] = []
var studio: PanelContainer


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	studio = PlayerAssetForgeStudio.new()
	var preconfigured: Dictionary = studio.configure({
		"default_game": "property_grid",
		"default_modality": "world",
		"token_budget": 2400,
		"compute_offer_gb": 12.5,
		"stake_units": 175,
		"model_profile": "hive_world",
		"policy_profile": "public_consensus",
		"visibility": "lobby_encrypted",
		"publication_locked": true,
	})
	_check(preconfigured.ok, "valid pre-tree configuration was rejected")
	root.add_child(studio)
	await process_frame

	_test_component_contract()
	_test_every_game_tab_and_prompt_blueprint()
	_test_controls_and_sanitized_draft_signal()
	_test_vote_and_publish_signal()
	_test_preview_api()
	_test_configuration_allowlist()
	_test_accessibility_contract()

	studio.queue_free()
	await process_frame
	if failures.is_empty():
		print("PLAYER_ASSET_FORGE_STUDIO_TEST: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("PLAYER_ASSET_FORGE_STUDIO_TEST: " + failure)
		quit(1)


func _test_component_contract() -> void:
	_check(studio.game_tabs.tab_count == 4, "studio did not expose all four game tabs")
	var initial: Dictionary = studio.request_snapshot()
	_check(initial.game_id == "property_grid" and initial.modality == "world", "pre-tree game/modality configuration was not applied")
	_check(int(initial.contribution.token_budget) == 2400, "configured contribution budget was not applied")
	_check(is_equal_approx(float(initial.contribution.compute_offer_gb), 12.5), "configured compute offer was not applied")
	_check(int(initial.contribution.stake_units) == 175, "configured weighted stake was not applied")
	_check(initial.routing.model_profile == "hive_world", "configured model route was not applied")
	_check(initial.routing.policy_profile == "public_consensus", "configured policy route was not applied")
	_check(initial.routing.visibility == "lobby_encrypted", "configured visibility was not applied")
	_check(initial.execution == "proposal_only" and not bool(initial.network_calls_performed), "studio request incorrectly claimed external execution")
	_check(bool(initial.requirements.human_review) and bool(initial.requirements.provenance_receipt), "review/provenance requirements are missing")
	_check("PUBLICATION LOCKED" in studio.publish_button.text, "publication lock was not surfaced in the action UI")


func _test_every_game_tab_and_prompt_blueprint() -> void:
	var seen: Array[String] = []
	studio.game_selected.connect(func(game_id: String) -> void: seen.append(game_id))
	var expectations := {
		"chess_core": "tournament chess",
		"four_line": "four-in-a-row",
		"draughts": "draughts asset",
		"property_grid": "property-trading loop",
	}
	for game_id in expectations.keys():
		_check(studio.select_game(str(game_id)), "valid game tab could not be selected: %s" % game_id)
		studio.select_modality("image")
		var template: String = studio.load_structured_prompt()
		_check(studio.request_snapshot().game_id == game_id, "request snapshot did not follow game tab %s" % game_id)
		_check(str(expectations[game_id]) in template, "game-specific prompt blueprint missing for %s" % game_id)
		_check("ORIGINALITY + PROVENANCE" in template and "SYSTEM READABILITY" in template, "advanced prompt safeguards missing for %s" % game_id)
	_check(seen.size() == 4, "game_selected did not emit exactly once for each programmatic tab selection")
	var prior_game: String = studio.request_snapshot().game_id
	_check(not studio.select_game("unregistered_game"), "unknown game identifier was accepted")
	_check(studio.request_snapshot().game_id == prior_game, "unknown game selection mutated accepted state")
	studio.select_modality("audio")
	_check("loop-safe audio family" in studio.load_structured_prompt(), "audio modality did not produce its specialized prompt contract")
	studio.select_modality("ui_kit")
	_check("state-complete UI kit" in studio.load_structured_prompt(), "UI-kit modality did not produce its specialized prompt contract")
	studio.select_modality("voice_to_text")
	_check("privacy-first voice-to-text" in studio.load_structured_prompt(), "voice-to-text modality did not produce its privacy contract")


func _test_controls_and_sanitized_draft_signal() -> void:
	studio.select_game("four_line")
	studio.select_modality("image")
	studio.proposal_title.text = "  Neon\nGrid" + char(0x202E) + char(2) + "  "
	studio.prompt_editor.text = "  Build\r\nseven columns" + char(0x202E) + char(1) + " with clear tokens.  "
	studio.constraints_editor.text = "No copied logos" + char(0x2067) + "; no hidden legal states."
	studio.budget_spinbox.value = 9876
	studio.compute_spinbox.value = 24.75
	studio.stake_spinbox.value = 325
	studio.model_selector.select(1)
	studio.policy_selector.select(0)
	studio.visibility_selector.select(2)

	var holder := {"request": {}}
	studio.asset_request_drafted.connect(func(request: Dictionary) -> void: holder.request = request)
	var returned: Dictionary = studio.submit_draft()
	var captured: Dictionary = holder.request
	_check(not captured.is_empty() and captured == returned, "draft signal did not carry the returned request envelope")
	holder.request = {}
	studio.draft_button.pressed.emit()
	_check(not holder.request.is_empty() and holder.request.intent == "save_draft", "draft button was not wired to the draft signal")
	captured = returned
	_check(captured.intent == "save_draft", "draft intent was not explicit")
	_check(captured.title == "Neon Grid", "single-line title sanitization failed")
	_check(captured.prompt == "Build\nseven columns with clear tokens.", "prompt controls or directional marks were not sanitized")
	_check(captured.constraints == "No copied logos; no hidden legal states.", "constraint controls were not sanitized")
	_check(int(captured.contribution.token_budget) == 9876, "token control did not reach request envelope")
	_check(is_equal_approx(float(captured.contribution.compute_offer_gb), 24.75), "RAM control did not reach request envelope")
	_check(int(captured.contribution.stake_units) == 325, "stake control did not reach request envelope")
	_check(captured.routing.model_profile == "local_visual", "model selector did not emit allowlisted metadata")
	_check(captured.routing.policy_profile == "strict_original", "policy selector did not emit allowlisted metadata")
	_check(captured.routing.visibility == "public_proposal", "visibility selector did not emit allowlisted metadata")
	_check(str(captured.prompt_digest_sha256).length() == 64, "request omitted a SHA-256 prompt receipt")
	var changed_title: String = studio.proposal_title.text
	captured.title = "mutated downstream"
	_check(studio.proposal_title.text == changed_title, "signal consumer could mutate studio input state")


func _test_vote_and_publish_signal() -> void:
	var vote_result: Dictionary = studio.set_vote_status({"members": [
		{"id": "q7", "display_name": "Quill\nSeven", "vote": "approve", "online": true, "activity_weight": 1.25},
		{"id": "vex", "display_name": "Vex" + char(0x202E), "vote": "approve", "online": true, "activity_weight": 2.0},
		{"id": "mira", "display_name": "Mira", "vote": "invalid", "online": false, "activity_weight": 900.0},
		{"id": "q7", "display_name": "Duplicate", "vote": "reject", "online": true},
		"malformed",
	], "quorum_required": 2})
	var capacity: Dictionary = studio.set_capacity_summary({
		"online_contributors": 1000,
		"offered_ram_gb": 20000.0,
		"available_ram_gb": 24000.0,
		"queued_proposals": 12,
		"source": "signed host aggregate" + char(0x202E),
	})
	_check(capacity.ok and float(capacity.summary.available_ram_gb) == 20000.0, "capacity summary did not bound availability to opt-in offered RAM")
	_check("OPT-IN HIVE CAPACITY" in studio.capacity_summary_label.text and "20000.00 GB OFFERED" in studio.capacity_summary_label.text, "voluntary capacity aggregate was not surfaced")
	_check(vote_result.ok and int(vote_result.accepted_members) == 3, "vote surface did not reject malformed or duplicate members")
	var holder := {"request": {}}
	studio.asset_publish_requested.connect(func(request: Dictionary) -> void: holder.request = request)
	var returned: Dictionary = studio.request_publish()
	var captured: Dictionary = holder.request
	_check(captured == returned and captured.intent == "request_publication", "publish signal did not carry its sanitized proposal")
	holder.request = {}
	studio.publish_button.pressed.emit()
	_check(not holder.request.is_empty() and holder.request.intent == "request_publication", "publish button was not wired to the publication signal")
	captured = returned
	_check(bool(captured.publication_locked), "host publication lock was not included in the request")
	_check(int(captured.vote_snapshot.quorum_required) == 2, "vote quorum was not included")
	_check(int(captured.vote_snapshot.tally.approve) == 2 and int(captured.vote_snapshot.tally.pending) == 1, "vote tally was not normalized")
	_check(is_equal_approx(float(captured.vote_snapshot.tally.weighted_approve), 3.25), "weighted approval tally is incorrect")
	_check(captured.vote_snapshot.members[0].display_name == "Quill Seven", "member display label was not sanitized")
	_check(float(captured.vote_snapshot.members[2].activity_weight) == 100.0, "member activity weight was not bounded")


func _test_preview_api() -> void:
	var image := Image.create(8, 6, false, Image.FORMAT_RGBA8)
	image.fill(Color("#5de1f4"))
	var texture := ImageTexture.create_from_image(image)
	var result: Dictionary = studio.set_preview(texture, {
		"generator": "Local Adapter" + char(2),
		"seed": "forge-42",
		"width": 999999,
		"height": 6,
		"license_status": "human-review-required",
		"unknown_raw_payload": "must-not-leak",
	})
	_check(result.ok and studio.preview_rect.texture == texture, "preview texture was not mounted")
	var receipt: Dictionary = studio.request_snapshot().preview_receipt
	_check(receipt.generator == "Local Adapter" and not receipt.has("unknown_raw_payload"), "preview metadata allowlist/sanitization failed")
	_check(int(receipt.width) == 32768 and int(receipt.height) == 6, "preview dimensions were not bounded")
	_check(not studio.preview_empty_label.visible and "PROVENANCE REVIEW REQUIRED" in studio.preview_caption.text, "preview review state was not surfaced")
	studio.clear_preview()
	_check(studio.preview_rect.texture == null and studio.preview_empty_label.visible, "clear_preview did not restore the empty state")


func _test_configuration_allowlist() -> void:
	var result: Dictionary = studio.configure({
		"default_game": "bad-game",
		"model_profile": "remote-untrusted",
		"policy_profile": "skip-review",
		"visibility": "broadcast-secrets",
		"unknown_secret": "ignored",
		"max_compute_gb": 8,
		"compute_offer_gb": 200,
	})
	_check(not result.ok and result.code == "unknown_options_ignored", "unknown configuration key was not reported")
	_check("unknown_secret" in result.rejected_keys, "rejected configuration key was not identified")
	var snapshot: Dictionary = studio.request_snapshot()
	_check(snapshot.routing.model_profile in ["community_auto", "local_visual", "local_bark", "local_stt", "hive_world"], "unknown model profile escaped allowlisting")
	_check(snapshot.routing.policy_profile in ["strict_original", "family_safe", "trusted_lobby", "public_consensus"], "unknown policy profile escaped allowlisting")
	_check(snapshot.routing.visibility in ["private_draft", "lobby_encrypted", "public_proposal"], "unknown visibility escaped allowlisting")
	_check(float(snapshot.contribution.compute_offer_gb) == 8.0, "compute offer did not clamp to configured maximum")


func _test_accessibility_contract() -> void:
	var focus_controls: Array[Control] = [
		studio.game_tabs,
		studio.proposal_title,
		studio.prompt_editor,
		studio.constraints_editor,
		studio.budget_spinbox,
		studio.compute_spinbox,
		studio.stake_spinbox,
		studio.model_selector,
		studio.policy_selector,
		studio.visibility_selector,
		studio.template_button,
		studio.draft_button,
		studio.publish_button,
	]
	for control in focus_controls:
		_check(control.focus_mode == Control.FOCUS_ALL, "%s is not keyboard-focusable" % control.name)
		_check(not control.tooltip_text.is_empty(), "%s is missing descriptive tooltip text" % control.name)
		_check(not control.focus_next.is_empty() and not control.focus_previous.is_empty(), "%s is missing deterministic focus traversal" % control.name)
	for modality_id in ["image", "audio", "world", "ui_kit", "voice_to_text"]:
		var chip: Button = studio.modality_buttons[modality_id]
		_check(chip.focus_mode == Control.FOCUS_ALL and not chip.tooltip_text.is_empty(), "%s modality chip is inaccessible" % modality_id)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
