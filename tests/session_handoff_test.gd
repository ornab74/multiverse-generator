extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load("res://node_3d.tscn")
	var game := packed.instantiate()
	root.add_child(game)
	await process_frame
	await process_frame

	game.front_end._open_briefing("EMBER ARCHIVE", "TERRITORIES", Color("#a979ff"), "LIVE · TEST ROUTE")
	game.front_end._set_briefing_mode("RIVALS")
	game.front_end._launch_briefing()
	await create_timer(0.4).timeout

	var failures: Array[String] = []
	if game.world_title_label.text != "EMBER ARCHIVE":
		failures.append("world title was not handed off")
	if game.current_module != "Territories":
		failures.append("module was not mounted")
	if game.session_crumb_label.text != "EMBER ARCHIVE   /   RIVALS":
		failures.append("session mode was not reflected in HUD")
	if not game.game_canvas.visible or game.front_end.visible:
		failures.append("front-end/game visibility transition failed")

	if failures.is_empty():
		print("SESSION_HANDOFF_TEST: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("SESSION_HANDOFF_TEST: " + failure)
		quit(1)
