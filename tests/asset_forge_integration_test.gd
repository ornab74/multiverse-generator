extends SceneTree

const MainSceneScript = preload("res://main.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := MainSceneScript.new()
	root.add_child(game)
	await process_frame
	game.front_end.open_asset_studio_for_module("Four Line")
	await process_frame
	var studio: PanelContainer = game.front_end.asset_forge_studio
	_check(game.front_end.current_screen == "STUDIO", "gameplay handoff did not open the Asset Forge Studio")
	_check(studio != null and is_instance_valid(studio), "Asset Forge Studio was not mounted")
	if studio != null:
		var snapshot: Dictionary = studio.request_snapshot()
		_check(snapshot.game_id == "four_line", "module handoff did not select the Four Line generation surface")
		_check(snapshot.execution == "proposal_only" and not bool(snapshot.network_calls_performed), "studio handoff claimed an external generation call")
		_check(studio.preview_rect.texture != null and studio.preview_rect.texture.resource_path.ends_with("four_line_forge.png"), "Four Line project-owned preview was not mounted")
		var expected_art := {
			"chess_core": "chess_core_forge.png",
			"four_line": "four_line_forge.png",
			"draughts": "draughts_forge.png",
			"property_grid": "property_grid_forge.png",
		}
		for game_id in expected_art:
			studio.select_game(str(game_id))
			_check(studio.preview_rect.texture.resource_path.ends_with(str(expected_art[game_id])), "%s preview did not follow its game tab" % game_id)
			_check(not studio.prompt_editor.text.is_empty(), "%s did not load an advanced generation blueprint" % game_id)
		studio.proposal_title.text = "Community orbital parcel kit"
		var drafted: Dictionary = studio.submit_draft()
		_check(not game.front_end.asset_forge_last_request.is_empty(), "studio draft did not reach the front-end controller")
		_check(drafted.prompt_digest_sha256 == game.front_end.asset_forge_last_request.prompt_digest_sha256, "draft handoff changed the prompt receipt")
		var compiler_receipt: Dictionary = game.front_end.asset_forge_last_request.get("compiler_receipt", {})
		_check(bool(compiler_receipt.get("ok", false)), "studio draft did not compile into a provenance-bound generation contract: " + str(compiler_receipt.get("code", "missing")))
		var pipeline_receipt: Dictionary = game.front_end.asset_forge_last_request.get("pipeline_receipt", {})
		_check(bool(pipeline_receipt.get("ok", false)), "studio draft did not create a local generation-pipeline receipt: " + str(pipeline_receipt.get("reason", "missing")))
		_check(str(pipeline_receipt.get("interface_mode", "")) == "LOCAL_INTERFACE_SIMULATION_ONLY", "studio draft overstated live generation availability")
		_check(not bool(pipeline_receipt.get("network_io_performed", true)), "studio draft performed unexpected network I/O")
		_check(str(pipeline_receipt.get("job", {}).get("state_name", "")) == "draft", "studio draft skipped the required review/consent lifecycle")
		_check(not bool(pipeline_receipt.get("stake", {}).get("authoritative", true)), "advisory stake became authoritative")
		var drafted_job_id := str(pipeline_receipt.get("job_id", ""))
		var publication: Dictionary = studio.request_publish()
		_check(bool(publication.publication_locked), "unreviewed studio publication was not locked")
		_check(game.front_end.asset_forge_last_request.intent == "request_publication", "publication request did not reach the locked host path")
		_check(str(game.front_end.asset_forge_last_request.get("pipeline_receipt", {}).get("job_id", "")) == drafted_job_id, "locked publication duplicated an unchanged draft job")

	game.queue_free()
	await process_frame
	await create_timer(0.12).timeout
	if failures.is_empty():
		print("ASSET_FORGE_INTEGRATION_TEST: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("ASSET_FORGE_INTEGRATION_TEST: " + failure)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
