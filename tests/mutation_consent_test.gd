extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load("res://node_3d.tscn")
	var game := packed.instantiate()
	root.add_child(game)
	await process_frame
	await process_frame

	var review: MutationReview = game.front_end.mutation_review
	review.open_review({
		"world": "VIOLET MYCELIUM REACH",
		"module": "CHESS CORE",
		"mode": "CO-OP",
		"state": "LIVE · MUTATION M-013 SEALED",
		"seed": 827401,
	})
	review._simulate()
	await create_timer(1.0).timeout
	var failures: Array[String] = []
	if review.phase != 1 or review.replay_status.text != "PASS":
		failures.append("deterministic simulation did not verify")
	review._consent()
	if review.phase != 2 or "2 / 2" not in review.consensus_label.text:
		failures.append("peer consent did not seal")
	review._advance()
	await create_timer(0.4).timeout
	if game.morph_count != 13 or "Bridge Memory" not in game.mutation_label.text:
		failures.append("sealed mutation was not mounted in gameplay")
	if game.front_end.visible or not game.game_canvas.visible:
		failures.append("mutation launch did not enter the shard")

	if failures.is_empty():
		print("MUTATION_CONSENT_TEST: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("MUTATION_CONSENT_TEST: " + failure)
		quit(1)
