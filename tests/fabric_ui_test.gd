extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load("res://node_3d.tscn")
	var game := packed.instantiate()
	root.add_child(game)
	await process_frame
	await process_frame
	game.front_end.open("FABRIC")
	await process_frame
	game.front_end._run_fabric_initialization()
	await create_timer(2.2).timeout

	var failures: Array[String] = []
	if game.front_end.fabric_phase != 7:
		failures.append("initialization did not complete all seven gates")
	if game.front_end.fabric_settings_status.text != "VERIFIED":
		failures.append("settings preflight was not verified before initialization")
	if int(game.front_end.fabric_component_snapshot.get("receipt_count", 0)) < 6:
		failures.append("component workflow receipts were not integrated")
	if game.front_end.fabric_component_snapshot.get("network_calls_performed", true):
		failures.append("local component workflow claimed a network call")
	if game.front_end.fabric_progress.value < 99.0:
		failures.append("fabric progress did not reach verified state")
	for status in game.front_end.fabric_stage_labels:
		if status.text != "VERIFIED":
			failures.append("a fabric gate remained unverified")
			break
	game.front_end._run_upcycle_query()
	if "private tiers excluded" not in game.front_end.fabric_detail_body.text.to_lower():
		failures.append("upcycle query did not report authorization filtering")
	game.front_end._run_policy_review()
	if "gpt-5.6-sol" not in game.front_end.fabric_detail_body.text.to_lower():
		failures.append("security review contract was not surfaced")
	if "non-authoritative" not in game.front_end.fabric_detail_body.text.to_lower():
		failures.append("security review was not labeled advisory")

	if failures.is_empty():
		print("FABRIC_UI_TEST: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("FABRIC_UI_TEST: " + failure)
		quit(1)
