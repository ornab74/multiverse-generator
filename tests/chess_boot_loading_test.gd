extends SceneTree


func _initialize() -> void:
	OS.set_environment("NEXUS_BACKEND_AUTOSTART", "0")
	var scene: PackedScene = load("res://node_3d.tscn")
	var game := scene.instantiate()
	root.add_child(game)
	await process_frame
	await process_frame
	var front_end = game.front_end
	assert(front_end.current_screen == "PLAY")
	assert(front_end.loading_page != null)
	assert(front_end.loading_spinner.text == "♞")
	assert(front_end.loading_progress.value == 0.0)
	assert(front_end.play_panel == null)
	print("CHESS_BOOT_LOADING_TEST: PASS")
	game.queue_free()
	quit(0)
