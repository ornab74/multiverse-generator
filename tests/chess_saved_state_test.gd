extends SceneTree

func _initialize() -> void:
	OS.set_environment("NEXUS_BACKEND_AUTOSTART", "0")
	var scene: PackedScene = load("res://node_3d.tscn")
	var game := scene.instantiate()
	root.add_child(game)
	await process_frame
	await process_frame
	var front_end = game.front_end
	front_end.backend.set("is_ready", true)
	front_end._show_screen("PLAY")
	await process_frame
	var panel = front_end.play_panel
	assert(panel != null)
	var initial_revision := int(panel.state.get("revision", -1))
	panel.thinking = true
	panel.settings_button.pressed.emit()
	assert(front_end.current_screen == "SETTINGS")
	front_end._show_screen("PLAY")
	panel.saved_games_button.pressed.emit()
	assert(front_end.current_screen == "SAVED GAMES")
	front_end._show_screen("PLAY")
	assert(front_end.play_panel == panel)
	assert(int(panel.state.get("revision", -1)) == initial_revision)
	assert(panel.thinking)
	panel.thinking = false
	panel._refresh_controls()
	print("CHESS_SAVED_STATE_TEST: PASS")
	game.queue_free()
	quit(0)
