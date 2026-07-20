extends Node3D
class_name NexusVFXDirector

## Procedural, renderer-portable feedback for the Nexus board surfaces.
##
## All positions are global coordinates. Effects are built from Godot primitives at
## runtime; this system never loads images, shaders, models, or third-party assets.
## The public methods return effect IDs so callers can cancel individual feedback
## without retaining scene nodes.

signal effect_started(effect_id: int, effect_kind: String)
signal effect_finished(effect_id: int, effect_kind: String)

const CYAN := Color("#64e8ff")
const VIOLET := Color("#a979ff")
const LIME := Color("#9bf59b")
const AMBER := Color("#ffca74")
const REJECT := Color("#ff667f")

const KIND_SELECTION := "selection_pulse"
const KIND_LEGAL_TARGET := "legal_target"
const KIND_CAPTURE := "capture_burst"
const KIND_COMMIT := "commit_ring"
const KIND_REJECT := "reject_flash"
const KIND_MODULE_MOUNT := "module_mount_wave"
const KIND_LAST_MOVE := "last_move_trail"

@export var reduced_motion := false
@export_range(0.25, 2.0, 0.05) var intensity := 1.0
@export_range(8, 96, 1) var active_effect_limit := 48
@export_range(0, 16, 1) var pool_limit_per_kind := 6

var _next_effect_id := 1
var _active: Dictionary = {}
var _pools: Dictionary = {}
var _legal_target_ids: Array[int] = []
var _shutting_down := false
var _stats := {
	"created": 0,
	"reused": 0,
	"released": 0,
}


func configure(options: Dictionary = {}) -> void:
	reduced_motion = bool(options.get("reduced_motion", reduced_motion))
	intensity = clampf(float(options.get("intensity", intensity)), 0.25, 2.0)
	active_effect_limit = clampi(int(options.get("active_effect_limit", active_effect_limit)), 8, 96)
	pool_limit_per_kind = clampi(int(options.get("pool_limit_per_kind", pool_limit_per_kind)), 0, 16)


func set_reduced_motion(enabled: bool) -> void:
	if enabled and not reduced_motion:
		# Do not let already-running particle sprays or travel tweens outlive a
		# user's accessibility change. Future effects use the reduced variants.
		reduced_motion = true
		clear_effects()
		return
	reduced_motion = enabled


func play_selection_pulse(world_position: Vector3, accent: Color = CYAN) -> int:
	var effect_id := _acquire_effect(KIND_SELECTION, Callable(self, "_build_selection_pulse"))
	var root := get_effect_node(effect_id)
	if root == null:
		return -1
	root.global_position = _safe_position(world_position)
	var primary := root.get_node("Primary") as MeshInstance3D
	var echo := root.get_node("Echo") as MeshInstance3D
	primary.visible = true
	echo.visible = not reduced_motion
	primary.scale = Vector3.ONE * 0.62
	echo.scale = Vector3.ONE * 0.48
	_set_mesh_color(primary, accent, 0.82, 3.0)
	_set_mesh_color(echo, accent.lightened(0.18), 0.48, 2.2)

	var duration := _duration(0.72)
	var travel := 1.03 if reduced_motion else 1.58 * intensity
	var tween := create_tween().set_parallel(true)
	tween.bind_node(root)
	tween.tween_property(primary, "scale", Vector3.ONE * travel, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(primary.material_override, "albedo_color", _alpha(accent, 0.0), duration)
	if not reduced_motion:
		tween.tween_property(echo, "scale", Vector3.ONE * travel * 1.16, duration * 0.78).set_delay(0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_property(echo.material_override, "albedo_color", _alpha(accent, 0.0), duration * 0.78).set_delay(0.12)
	_bind_release(effect_id, tween)
	return effect_id


func show_legal_target(world_position: Vector3, accent: Color = LIME, lifetime := 1.35) -> int:
	var effect_id := _acquire_effect(KIND_LEGAL_TARGET, Callable(self, "_build_legal_target"))
	var root := get_effect_node(effect_id)
	if root == null:
		return -1
	root.global_position = _safe_position(world_position)
	var disc := root.get_node("Disc") as MeshInstance3D
	var ring := root.get_node("Ring") as MeshInstance3D
	disc.scale = Vector3.ONE * 0.72
	ring.scale = Vector3.ONE * 0.82
	_set_mesh_color(disc, accent, 0.16, 1.4)
	_set_mesh_color(ring, accent, 0.68, 2.6)
	_legal_target_ids.append(effect_id)

	var safe_lifetime := clampf(lifetime, 0.2, 4.0)
	var duration := minf(safe_lifetime, _duration(safe_lifetime)) if reduced_motion else safe_lifetime
	var destination_scale := 1.01 if reduced_motion else 1.16
	var tween := create_tween().set_parallel(true)
	tween.bind_node(root)
	tween.tween_property(ring, "scale", Vector3.ONE * destination_scale, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(ring.material_override, "albedo_color", _alpha(accent, 0.0), duration).set_delay(duration * 0.58)
	tween.tween_property(disc.material_override, "albedo_color", _alpha(accent, 0.0), duration).set_delay(duration * 0.68)
	_bind_release(effect_id, tween)
	return effect_id


func play_capture_burst(world_position: Vector3, accent: Color = AMBER, direction := Vector3.UP) -> int:
	var effect_id := _acquire_effect(KIND_CAPTURE, Callable(self, "_build_capture_burst"))
	var root := get_effect_node(effect_id)
	if root == null:
		return -1
	root.global_position = _safe_position(world_position)
	var particles := root.get_node("Particles") as CPUParticles3D
	var shock_ring := root.get_node("ShockRing") as MeshInstance3D
	var safe_direction: Vector3 = direction.normalized() if direction.is_finite() and direction.length_squared() > 0.001 else Vector3.UP
	particles.direction = safe_direction
	particles.amount = 7 if reduced_motion else clampi(int(round(22.0 * intensity)), 10, 36)
	particles.lifetime = _duration(0.56)
	particles.visible = not reduced_motion
	particles.emitting = false
	_set_particle_color(particles, accent)
	shock_ring.scale = Vector3.ONE * 0.35
	_set_mesh_color(shock_ring, accent, 0.8, 3.6)
	if not reduced_motion:
		particles.restart()
		particles.emitting = true

	var duration := _duration(0.68)
	var tween := create_tween().set_parallel(true)
	tween.bind_node(root)
	tween.tween_property(shock_ring, "scale", Vector3.ONE * (1.05 if reduced_motion else 1.72 * intensity), duration * 0.7).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tween.tween_property(shock_ring.material_override, "albedo_color", _alpha(accent, 0.0), duration * 0.7)
	tween.tween_interval(duration)
	_bind_release(effect_id, tween)
	return effect_id


func play_commit_ring(world_position: Vector3, accent: Color = CYAN) -> int:
	var effect_id := _acquire_effect(KIND_COMMIT, Callable(self, "_build_commit_ring"))
	var root := get_effect_node(effect_id)
	if root == null:
		return -1
	root.global_position = _safe_position(world_position)
	var duration := _duration(0.9)
	var tween := create_tween().set_parallel(true)
	tween.bind_node(root)
	for index in range(3):
		var ring := root.get_node("Ring%d" % index) as MeshInstance3D
		var delay := 0.0 if reduced_motion else float(index) * 0.1
		ring.visible = index == 0 or not reduced_motion
		ring.position = Vector3.ZERO
		ring.scale = Vector3.ONE * (0.64 + float(index) * 0.08)
		_set_mesh_color(ring, accent.lightened(float(index) * 0.09), 0.78 - float(index) * 0.15, 3.0)
		tween.tween_property(ring, "scale", Vector3.ONE * (1.02 if reduced_motion else 1.54 + float(index) * 0.13), duration - delay).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tween.tween_property(ring, "position:y", 0.025 if reduced_motion else 0.18 + float(index) * 0.09, duration - delay).set_delay(delay)
		tween.tween_property(ring.material_override, "albedo_color", _alpha(accent, 0.0), duration - delay).set_delay(delay)
	_bind_release(effect_id, tween)
	return effect_id


func play_reject_flash(world_position: Vector3, accent: Color = REJECT) -> int:
	var effect_id := _acquire_effect(KIND_REJECT, Callable(self, "_build_reject_flash"))
	var root := get_effect_node(effect_id)
	if root == null:
		return -1
	root.global_position = _safe_position(world_position)
	var flash := root.get_node("Flash") as MeshInstance3D
	var boundary := root.get_node("Boundary") as MeshInstance3D
	flash.scale = Vector3.ONE * 0.24
	boundary.scale = Vector3.ONE * 0.54
	_set_mesh_color(flash, accent, 0.34, 4.5)
	_set_mesh_color(boundary, accent, 0.88, 4.0)
	var duration := _duration(0.42)
	var tween := create_tween().set_parallel(true)
	tween.bind_node(root)
	tween.tween_property(flash, "scale", Vector3.ONE * (0.62 if reduced_motion else 1.18 * intensity), duration).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tween.tween_property(boundary, "scale", Vector3.ONE * (0.9 if reduced_motion else 1.42 * intensity), duration).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(flash.material_override, "albedo_color", _alpha(accent, 0.0), duration)
	tween.tween_property(boundary.material_override, "albedo_color", _alpha(accent, 0.0), duration)
	_bind_release(effect_id, tween)
	return effect_id


func play_module_mount_wave(world_position: Vector3, radius := 2.5, accent: Color = VIOLET) -> int:
	var effect_id := _acquire_effect(KIND_MODULE_MOUNT, Callable(self, "_build_module_mount_wave"))
	var root := get_effect_node(effect_id)
	if root == null:
		return -1
	root.global_position = _safe_position(world_position)
	var safe_radius := clampf(radius, 0.5, 8.0) * intensity
	var duration := _duration(1.15)
	var tween := create_tween().set_parallel(true)
	tween.bind_node(root)
	for index in range(3):
		var ring := root.get_node("Wave%d" % index) as MeshInstance3D
		var delay := 0.0 if reduced_motion else float(index) * 0.14
		ring.visible = index == 0 or not reduced_motion
		ring.scale = Vector3.ONE * (0.42 + float(index) * 0.12)
		_set_mesh_color(ring, accent.lightened(float(index) * 0.08), 0.64 - float(index) * 0.11, 2.8)
		tween.tween_property(ring, "scale", Vector3.ONE * (minf(safe_radius, 1.05) if reduced_motion else safe_radius), duration - delay).set_delay(delay).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
		tween.tween_property(ring.material_override, "albedo_color", _alpha(accent, 0.0), duration - delay).set_delay(delay)
	_bind_release(effect_id, tween)
	return effect_id


func play_last_move_trail(from_world: Vector3, to_world: Vector3, accent: Color = CYAN) -> int:
	var effect_id := _acquire_effect(KIND_LAST_MOVE, Callable(self, "_build_last_move_trail"))
	var root := get_effect_node(effect_id)
	if root == null:
		return -1
	var safe_from := _safe_position(from_world)
	var safe_to := _safe_position(to_world)
	var delta := safe_to - safe_from
	if delta.length_squared() < 0.0001:
		delta = Vector3(0.0, 0.01, 0.0)
	root.global_position = safe_from
	var beam := root.get_node("Beam") as MeshInstance3D
	var origin := root.get_node("Origin") as MeshInstance3D
	var destination := root.get_node("Destination") as MeshInstance3D
	var beam_mesh := beam.mesh as CylinderMesh
	beam_mesh.height = delta.length()
	beam.position = delta * 0.5
	beam.quaternion = Quaternion(Vector3.UP, delta.normalized())
	origin.position = Vector3.ZERO
	destination.position = delta
	origin.scale = Vector3.ONE * 0.72
	destination.scale = Vector3.ONE * 0.9
	_set_mesh_color(beam, accent, 0.45, 2.3)
	_set_mesh_color(origin, accent, 0.72, 2.8)
	_set_mesh_color(destination, accent.lightened(0.18), 0.88, 3.2)

	var duration := _duration(1.05)
	var tween := create_tween().set_parallel(true)
	tween.bind_node(root)
	tween.tween_property(origin, "scale", Vector3.ONE * (0.8 if reduced_motion else 1.26), duration).set_trans(Tween.TRANS_SINE)
	tween.tween_property(destination, "scale", Vector3.ONE * (0.96 if reduced_motion else 1.45), duration).set_trans(Tween.TRANS_SINE)
	tween.tween_property(beam.material_override, "albedo_color", _alpha(accent, 0.0), duration).set_delay(duration * 0.5)
	tween.tween_property(origin.material_override, "albedo_color", _alpha(accent, 0.0), duration).set_delay(duration * 0.52)
	tween.tween_property(destination.material_override, "albedo_color", _alpha(accent, 0.0), duration).set_delay(duration * 0.52)
	_bind_release(effect_id, tween)
	return effect_id


func clear_legal_targets() -> void:
	for effect_id in _legal_target_ids.duplicate():
		_release_effect(effect_id)
	_legal_target_ids.clear()


func cancel_effect(effect_id: int) -> void:
	_release_effect(effect_id)


func clear_effects() -> void:
	for effect_id in _active.keys().duplicate():
		_release_effect(int(effect_id))
	_legal_target_ids.clear()


func get_effect_node(effect_id: int) -> Node3D:
	if not _active.has(effect_id):
		return null
	return _active[effect_id].get("node") as Node3D


func get_debug_snapshot() -> Dictionary:
	var by_kind := {}
	for record in _active.values():
		var kind := str(record.get("kind", "unknown"))
		by_kind[kind] = int(by_kind.get(kind, 0)) + 1
	var pooled := {}
	var pooled_total := 0
	for kind in _pools:
		var count: int = (_pools[kind] as Array).size()
		pooled[str(kind)] = count
		pooled_total += count
	return {
		"active": _active.size(),
		"active_by_kind": by_kind,
		"legal_targets": _legal_target_ids.size(),
		"pooled": pooled,
		"pooled_total": pooled_total,
		"reduced_motion": reduced_motion,
		"particles_enabled": not reduced_motion,
		"created": int(_stats.created),
		"reused": int(_stats.reused),
		"released": int(_stats.released),
	}


func _acquire_effect(kind: String, builder: Callable) -> int:
	while _active.size() >= active_effect_limit:
		_release_effect(_oldest_effect_id())
	var root: Node3D
	var pool: Array = _pools.get(kind, [])
	if not pool.is_empty():
		root = pool.pop_back() as Node3D
		_stats.reused = int(_stats.reused) + 1
	else:
		root = builder.call() as Node3D
		add_child(root)
		_stats.created = int(_stats.created) + 1
	_pools[kind] = pool
	root.visible = true
	root.position = Vector3.ZERO
	root.rotation = Vector3.ZERO
	root.scale = Vector3.ONE
	var effect_id := _next_effect_id
	_next_effect_id += 1
	root.set_meta("nexus_vfx_effect_id", effect_id)
	_active[effect_id] = {
		"kind": kind,
		"node": root,
		"tween": null,
		"started_usec": Time.get_ticks_usec(),
	}
	effect_started.emit(effect_id, kind)
	return effect_id


func _bind_release(effect_id: int, tween: Tween) -> void:
	if not _active.has(effect_id):
		tween.kill()
		return
	var record: Dictionary = _active[effect_id]
	record.tween = tween
	_active[effect_id] = record
	tween.finished.connect(_release_effect.bind(effect_id), CONNECT_ONE_SHOT)


func _release_effect(effect_id: int) -> void:
	if not _active.has(effect_id):
		return
	var record: Dictionary = _active[effect_id]
	_active.erase(effect_id)
	_legal_target_ids.erase(effect_id)
	var kind := str(record.get("kind", "unknown"))
	var root := record.get("node") as Node3D
	var tween := record.get("tween") as Tween
	if tween != null and tween.is_valid():
		tween.kill()
	if is_instance_valid(root):
		_stop_particles(root)
		root.visible = false
		root.remove_meta("nexus_vfx_effect_id")
		var pool: Array = _pools.get(kind, [])
		if not _shutting_down and pool.size() < pool_limit_per_kind:
			pool.append(root)
			_pools[kind] = pool
		else:
			root.queue_free()
	_stats.released = int(_stats.released) + 1
	if not _shutting_down:
		effect_finished.emit(effect_id, kind)


func _oldest_effect_id() -> int:
	var oldest_id := -1
	var oldest_time := 9223372036854775807
	for effect_id in _active:
		var started := int((_active[effect_id] as Dictionary).get("started_usec", oldest_time))
		if started < oldest_time:
			oldest_time = started
			oldest_id = int(effect_id)
	return oldest_id


func _stop_particles(root: Node3D) -> void:
	var particles := root.get_node_or_null("Particles") as CPUParticles3D
	if particles != null:
		particles.emitting = false


func _duration(base_duration: float) -> float:
	return maxf(0.12, base_duration * 0.28) if reduced_motion else base_duration


func _safe_position(value: Vector3) -> Vector3:
	return value if value.is_finite() else Vector3.ZERO


func _alpha(color: Color, alpha_value: float) -> Color:
	return Color(color.r, color.g, color.b, clampf(alpha_value, 0.0, 1.0))


func _set_mesh_color(mesh_instance: MeshInstance3D, color: Color, alpha_value: float, energy: float) -> void:
	var material := mesh_instance.material_override as StandardMaterial3D
	material.albedo_color = _alpha(color, alpha_value)
	material.emission = color
	material.emission_energy_multiplier = energy * intensity


func _set_particle_color(particles: CPUParticles3D, color: Color) -> void:
	particles.color = color
	var particle_mesh := particles.mesh as PrimitiveMesh
	if particle_mesh != null:
		var material := particle_mesh.material as StandardMaterial3D
		if material != null:
			material.albedo_color = color
			material.emission = color
			material.emission_energy_multiplier = 3.2 * intensity


func _material(color: Color, alpha_value := 1.0, energy := 2.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = _alpha(color, alpha_value)
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = energy
	return material


func _ring(inner_radius := 0.38, outer_radius := 0.46) -> MeshInstance3D:
	var mesh := TorusMesh.new()
	mesh.inner_radius = inner_radius
	mesh.outer_radius = outer_radius
	mesh.rings = 32
	mesh.ring_segments = 8
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _material(CYAN, 0.75, 2.8)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _disc(radius := 0.38, height := 0.018) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 32
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _material(CYAN, 0.18, 1.5)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _sphere(radius := 0.32) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 16
	mesh.rings = 8
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _material(CYAN, 0.38, 3.0)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _build_selection_pulse() -> Node3D:
	var root := Node3D.new()
	root.name = "SelectionPulse"
	var primary := _ring(0.39, 0.48)
	primary.name = "Primary"
	primary.position.y = 0.025
	root.add_child(primary)
	var echo := _ring(0.43, 0.47)
	echo.name = "Echo"
	echo.position.y = 0.035
	root.add_child(echo)
	return root


func _build_legal_target() -> Node3D:
	var root := Node3D.new()
	root.name = "LegalTarget"
	var disc := _disc(0.31, 0.016)
	disc.name = "Disc"
	disc.position.y = 0.018
	root.add_child(disc)
	var ring := _ring(0.29, 0.34)
	ring.name = "Ring"
	ring.position.y = 0.03
	root.add_child(ring)
	return root


func _build_capture_burst() -> Node3D:
	var root := Node3D.new()
	root.name = "CaptureBurst"
	var particles := CPUParticles3D.new()
	particles.name = "Particles"
	particles.amount = 22
	particles.lifetime = 0.56
	particles.one_shot = true
	particles.explosiveness = 0.96
	particles.randomness = 0.38
	particles.local_coords = true
	particles.direction = Vector3.UP
	particles.spread = 72.0
	particles.gravity = Vector3(0.0, -2.8, 0.0)
	particles.initial_velocity_min = 1.7
	particles.initial_velocity_max = 3.5
	particles.angular_velocity_min = -160.0
	particles.angular_velocity_max = 160.0
	particles.scale_amount_min = 0.45
	particles.scale_amount_max = 1.2
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	particles.emission_sphere_radius = 0.15
	var particle_mesh := SphereMesh.new()
	particle_mesh.radius = 0.035
	particle_mesh.height = 0.07
	particle_mesh.radial_segments = 8
	particle_mesh.rings = 4
	particle_mesh.material = _material(AMBER, 0.94, 3.2)
	particles.mesh = particle_mesh
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.emitting = false
	root.add_child(particles)
	var shock_ring := _ring(0.31, 0.39)
	shock_ring.name = "ShockRing"
	shock_ring.position.y = 0.035
	root.add_child(shock_ring)
	return root


func _build_commit_ring() -> Node3D:
	var root := Node3D.new()
	root.name = "CommitRing"
	for index in range(3):
		var ring := _ring(0.37 + float(index) * 0.035, 0.43 + float(index) * 0.035)
		ring.name = "Ring%d" % index
		ring.position.y = 0.02 + float(index) * 0.012
		root.add_child(ring)
	return root


func _build_reject_flash() -> Node3D:
	var root := Node3D.new()
	root.name = "RejectFlash"
	var flash := _sphere(0.34)
	flash.name = "Flash"
	flash.position.y = 0.24
	root.add_child(flash)
	var boundary := _ring(0.36, 0.45)
	boundary.name = "Boundary"
	boundary.position.y = 0.03
	root.add_child(boundary)
	return root


func _build_module_mount_wave() -> Node3D:
	var root := Node3D.new()
	root.name = "ModuleMountWave"
	for index in range(3):
		var ring := _ring(0.36 + float(index) * 0.025, 0.43 + float(index) * 0.025)
		ring.name = "Wave%d" % index
		ring.position.y = 0.015 + float(index) * 0.012
		root.add_child(ring)
	return root


func _build_last_move_trail() -> Node3D:
	var root := Node3D.new()
	root.name = "LastMoveTrail"
	var beam_mesh := CylinderMesh.new()
	beam_mesh.top_radius = 0.035
	beam_mesh.bottom_radius = 0.035
	beam_mesh.height = 1.0
	beam_mesh.radial_segments = 8
	var beam := MeshInstance3D.new()
	beam.name = "Beam"
	beam.mesh = beam_mesh
	beam.material_override = _material(CYAN, 0.45, 2.4)
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(beam)
	var origin := _sphere(0.09)
	origin.name = "Origin"
	root.add_child(origin)
	var destination := _sphere(0.12)
	destination.name = "Destination"
	root.add_child(destination)
	return root


func _exit_tree() -> void:
	_shutting_down = true
	clear_effects()
