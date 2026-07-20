extends SceneTree

const VFXDirector = preload("res://systems/nexus_vfx_director.gd")

var failures: Array[String] = []
var director: Node3D


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	director = VFXDirector.new()
	root.add_child(director)
	await process_frame
	_test_procedural_effect_api()
	_test_legal_target_group_cleanup()
	await _test_reduced_motion_contract()
	_test_pool_reuse_and_invalid_positions()
	await _test_normal_auto_cleanup()
	director.clear_effects()
	director.queue_free()
	await process_frame

	if failures.is_empty():
		print("NEXUS_VFX_DIRECTOR_TEST: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("NEXUS_VFX_DIRECTOR_TEST: " + failure)
		quit(1)


func _test_procedural_effect_api() -> void:
	var ids := [
		director.play_selection_pulse(Vector3(1.0, 0.1, 1.0)),
		director.show_legal_target(Vector3(2.0, 0.1, 1.0)),
		director.play_capture_burst(Vector3(3.0, 0.3, 1.0)),
		director.play_commit_ring(Vector3(4.0, 0.1, 1.0)),
		director.play_reject_flash(Vector3(5.0, 0.1, 1.0)),
		director.play_module_mount_wave(Vector3.ZERO, 3.0),
		director.play_last_move_trail(Vector3.ZERO, Vector3(2.0, 0.0, 2.0)),
	]
	var unique := {}
	for effect_id in ids:
		_check(effect_id > 0, "an effect did not return a valid ID")
		unique[effect_id] = true
		_check(director.get_effect_node(effect_id) != null, "an active effect ID did not resolve to its node")
	_check(unique.size() == 7, "effect IDs were not unique")
	var snapshot: Dictionary = director.get_debug_snapshot()
	_check(int(snapshot.active) == 7, "not all seven procedural effect families became active")
	_check(snapshot.active_by_kind.keys().size() == 7, "effect diagnostics omitted an effect family")
	var capture: Node3D = director.get_effect_node(ids[2])
	_check(capture.get_node_or_null("Particles") is CPUParticles3D, "capture feedback is not backed by CPU particles")
	var trail: Node3D = director.get_effect_node(ids[6])
	_check(trail.get_node_or_null("Beam") is MeshInstance3D, "last-move feedback is missing its procedural beam")
	director.clear_effects()
	_check(int(director.get_debug_snapshot().active) == 0, "clear_effects left transient feedback active")


func _test_legal_target_group_cleanup() -> void:
	var unrelated: int = director.play_commit_ring(Vector3.ZERO)
	for index in range(5):
		director.show_legal_target(Vector3(float(index), 0.0, 0.0), VFXDirector.LIME, 2.0)
	_check(int(director.get_debug_snapshot().legal_targets) == 5, "legal-target registry did not track all markers")
	director.clear_legal_targets()
	var snapshot: Dictionary = director.get_debug_snapshot()
	_check(int(snapshot.legal_targets) == 0, "clear_legal_targets left marker IDs registered")
	_check(int(snapshot.active) == 1 and director.get_effect_node(unrelated) != null, "clearing legal targets cancelled unrelated feedback")
	director.cancel_effect(unrelated)


func _test_reduced_motion_contract() -> void:
	director.set_reduced_motion(false)
	director.play_capture_burst(Vector3.ZERO)
	director.show_legal_target(Vector3.ONE, VFXDirector.LIME, 2.0)
	_check(int(director.get_debug_snapshot().active) == 2, "mid-flight accessibility fixture did not start")
	director.set_reduced_motion(true)
	_check(int(director.get_debug_snapshot().active) == 0, "enabling reduced motion did not stop active effects immediately")
	var capture_id: int = director.play_capture_burst(Vector3.ZERO)
	var capture: Node3D = director.get_effect_node(capture_id)
	var particles := capture.get_node("Particles") as CPUParticles3D
	_check(not particles.visible and not particles.emitting, "reduced motion did not suppress capture particle spray")
	var selection_id: int = director.play_selection_pulse(Vector3.ZERO)
	var selection: Node3D = director.get_effect_node(selection_id)
	_check(not (selection.get_node("Echo") as MeshInstance3D).visible, "reduced motion did not suppress the selection echo")
	var mount_id: int = director.play_module_mount_wave(Vector3.ZERO)
	var mount: Node3D = director.get_effect_node(mount_id)
	_check(not (mount.get_node("Wave1") as MeshInstance3D).visible, "reduced motion did not collapse the module wave")
	var snapshot: Dictionary = director.get_debug_snapshot()
	_check(bool(snapshot.reduced_motion) and not bool(snapshot.particles_enabled), "reduced-motion diagnostics are inconsistent")
	await create_timer(0.5).timeout
	_check(int(director.get_debug_snapshot().active) == 0, "reduced-motion effects did not clean themselves up promptly")
	director.set_reduced_motion(false)


func _test_pool_reuse_and_invalid_positions() -> void:
	var before: Dictionary = director.get_debug_snapshot()
	var first_id: int = director.play_reject_flash(Vector3.ZERO)
	director.cancel_effect(first_id)
	var pooled: Dictionary = director.get_debug_snapshot()
	_check(int(pooled.pooled.get(VFXDirector.KIND_REJECT, 0)) >= 1, "released reject feedback was not pooled")
	var second_id: int = director.play_reject_flash(Vector3(INF, NAN, -INF))
	var second_node: Node3D = director.get_effect_node(second_id)
	_check(second_node.global_position == Vector3.ZERO, "non-finite effect coordinates were not sanitized")
	var after: Dictionary = director.get_debug_snapshot()
	_check(int(after.reused) > int(before.reused), "a compatible pooled effect was not reused")
	director.cancel_effect(second_id)


func _test_normal_auto_cleanup() -> void:
	director.play_selection_pulse(Vector3.ZERO)
	director.play_capture_burst(Vector3.ZERO)
	director.play_commit_ring(Vector3.ZERO)
	director.play_reject_flash(Vector3.ZERO)
	director.play_module_mount_wave(Vector3.ZERO)
	director.play_last_move_trail(Vector3.ZERO, Vector3.RIGHT)
	var active_before_wait: int = int(director.get_debug_snapshot().active)
	_check(active_before_wait == 6, "normal-motion feedback registry expected 6 effects, got %d" % active_before_wait)
	await create_timer(1.75).timeout
	_check(int(director.get_debug_snapshot().active) == 0, "normal-motion effects did not clean themselves up")


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
