extends Node3D
class_name ShardRunnerRig

var accent := Color("#64e8ff")
var animation_mode := "IDLE"
var animation_time := 0.0
var rig_root: Node3D
var chest: Node3D
var head: Node3D
var left_shoulder: Node3D
var right_shoulder: Node3D
var left_elbow: Node3D
var right_elbow: Node3D
var left_hip: Node3D
var right_hip: Node3D
var left_knee: Node3D
var right_knee: Node3D
var core_material: StandardMaterial3D
var armor_material: StandardMaterial3D
var joint_material: StandardMaterial3D


func _ready() -> void:
	_build_materials()
	_build_display_plinth()
	_build_hierarchical_rig()


func _process(delta: float) -> void:
	animation_time += delta
	match animation_mode:
		"RUN": _animate_run()
		"WAVE": _animate_wave()
		"SCAN": _animate_scan()
		_: _animate_idle()


func set_mode(mode: String) -> void:
	animation_mode = mode.to_upper()
	animation_time = 0.0


func set_accent(color: Color) -> void:
	accent = color
	if core_material:
		core_material.albedo_color = accent
		core_material.emission = accent


func _build_materials() -> void:
	armor_material = _material(Color("#171d29"), 0.32)
	armor_material.metallic = 0.72
	joint_material = _material(Color("#657084"), 0.24)
	joint_material.metallic = 0.88
	core_material = _material(accent, 0.1, accent)


func _build_display_plinth() -> void:
	var floor := _mesh(_cylinder(1.35, 0.10, 64), _material(Color("#0b101b"), 0.55))
	floor.position.y = 0.03
	add_child(floor)
	var ring := _mesh(_torus(1.08, 0.025), core_material)
	ring.position.y = 0.10
	ring.rotation_degrees.x = 90
	add_child(ring)
	for i in range(12):
		var marker := _mesh(_box(Vector3(0.035, 0.025, 0.14)), core_material)
		var angle := TAU * i / 12.0
		marker.position = Vector3(cos(angle) * 0.83, 0.11, sin(angle) * 0.83)
		marker.rotation.y = -angle
		add_child(marker)


func _build_hierarchical_rig() -> void:
	rig_root = Node3D.new()
	rig_root.position.y = 0.12
	add_child(rig_root)

	var pelvis := _part(_box(Vector3(0.48, 0.24, 0.30)), armor_material, Vector3(0, 0.95, 0), rig_root)
	chest = Node3D.new()
	chest.position = Vector3(0, 1.28, 0)
	rig_root.add_child(chest)
	var torso := _part(_box(Vector3(0.70, 0.58, 0.38)), armor_material, Vector3.ZERO, chest)
	torso.scale = Vector3(1.0, 1.0, 0.92)
	var core := _part(_sphere(0.205), core_material, Vector3(0, 0.03, 0.19), chest)
	core.scale = Vector3(0.80, 1.12, 0.45)
	_part(_box(Vector3(0.14, 0.06, 0.05)), core_material, Vector3(0, 0.36, 0.19), chest)

	head = Node3D.new()
	head.position = Vector3(0, 0.55, 0)
	chest.add_child(head)
	_part(_cylinder(0.11, 0.12, 20), joint_material, Vector3(0, -0.09, 0), head)
	var helmet := _part(_sphere(0.30), armor_material, Vector3(0, 0.18, 0), head)
	helmet.scale = Vector3(0.92, 0.86, 1.0)
	var face := _part(_sphere(0.23), core_material, Vector3(0, 0.18, 0.14), head)
	face.scale = Vector3(0.78, 0.64, 0.38)
	_part(_box(Vector3(0.42, 0.07, 0.31)), armor_material, Vector3(0, 0.38, 0), head)

	left_shoulder = _build_arm(-1.0, chest)
	right_shoulder = _build_arm(1.0, chest)
	left_elbow = left_shoulder.get_meta("elbow")
	right_elbow = right_shoulder.get_meta("elbow")
	left_hip = _build_leg(-1.0, pelvis)
	right_hip = _build_leg(1.0, pelvis)
	left_knee = left_hip.get_meta("knee")
	right_knee = right_hip.get_meta("knee")


func _build_arm(side: float, parent: Node3D) -> Node3D:
	var shoulder := Node3D.new()
	shoulder.position = Vector3(side * 0.47, 0.21, 0)
	parent.add_child(shoulder)
	var pauldron := _part(_sphere(0.22), armor_material, Vector3(side * 0.03, 0, 0), shoulder)
	pauldron.scale = Vector3(1.08, 0.76, 0.95)
	_part(_cylinder(0.105, 0.42, 16), armor_material, Vector3(0, -0.28, 0), shoulder)
	var elbow := Node3D.new()
	elbow.position = Vector3(0, -0.53, 0)
	shoulder.add_child(elbow)
	_part(_sphere(0.13), joint_material, Vector3.ZERO, elbow)
	_part(_cylinder(0.095, 0.38, 16), armor_material, Vector3(0, -0.24, 0), elbow)
	var hand := _part(_sphere(0.13), joint_material, Vector3(0, -0.49, 0), elbow)
	hand.scale = Vector3(0.78, 1.08, 0.85)
	shoulder.set_meta("elbow", elbow)
	return shoulder


func _build_leg(side: float, parent: Node3D) -> Node3D:
	var hip := Node3D.new()
	hip.position = Vector3(side * 0.22, -0.16, 0)
	parent.add_child(hip)
	_part(_sphere(0.145), joint_material, Vector3.ZERO, hip)
	var thigh := _part(_cylinder(0.15, 0.55, 18), armor_material, Vector3(0, -0.34, 0), hip)
	thigh.scale = Vector3(1.0, 1.0, 0.86)
	var knee := Node3D.new()
	knee.position = Vector3(0, -0.68, 0)
	hip.add_child(knee)
	_part(_sphere(0.15), joint_material, Vector3.ZERO, knee)
	_part(_box(Vector3(0.23, 0.18, 0.14)), armor_material, Vector3(0, 0.01, 0.12), knee)
	var shin := _part(_cylinder(0.135, 0.52, 18), armor_material, Vector3(0, -0.34, 0), knee)
	shin.scale = Vector3(0.9, 1.0, 0.84)
	var foot := _part(_box(Vector3(0.30, 0.16, 0.48)), armor_material, Vector3(0, -0.66, 0.10), knee)
	foot.position.z = 0.11
	hip.set_meta("knee", knee)
	return hip


func _animate_idle() -> void:
	var breathe := sin(animation_time * 1.7)
	chest.position.y = 1.28 + breathe * 0.018
	chest.rotation.z = sin(animation_time * 0.55) * 0.018
	head.rotation.y = sin(animation_time * 0.42) * 0.12
	left_shoulder.rotation.z = -0.07 + breathe * 0.025
	right_shoulder.rotation.z = 0.07 - breathe * 0.025
	left_shoulder.rotation.x = 0.02
	right_shoulder.rotation.x = -0.02
	left_elbow.rotation.x = 0.0
	right_elbow.rotation.x = 0.0
	left_hip.rotation.x = 0.0
	right_hip.rotation.x = 0.0
	left_knee.rotation.x = 0.0
	right_knee.rotation.x = 0.0
	rig_root.rotation.y = sin(animation_time * 0.24) * 0.08


func _animate_run() -> void:
	var cycle := sin(animation_time * 6.4)
	var inverse := sin(animation_time * 6.4 + PI)
	rig_root.position.y = 0.12 + abs(cos(animation_time * 6.4)) * 0.045
	chest.rotation.x = -0.10
	chest.rotation.z = cycle * 0.035
	left_shoulder.rotation.x = cycle * 0.75
	right_shoulder.rotation.x = inverse * 0.75
	left_elbow.rotation.x = -0.45 + max(0.0, -cycle) * -0.65
	right_elbow.rotation.x = -0.45 + max(0.0, -inverse) * -0.65
	left_hip.rotation.x = inverse * 0.68
	right_hip.rotation.x = cycle * 0.68
	left_knee.rotation.x = max(0.0, cycle) * 0.9
	right_knee.rotation.x = max(0.0, inverse) * 0.9


func _animate_wave() -> void:
	_animate_idle()
	right_shoulder.rotation.z = 2.55
	right_shoulder.rotation.x = -0.25
	right_elbow.rotation.x = -0.25
	right_elbow.rotation.y = sin(animation_time * 4.8) * 0.55
	head.rotation.y = -0.18


func _animate_scan() -> void:
	_animate_idle()
	head.rotation.y = sin(animation_time * 1.25) * 0.58
	left_shoulder.rotation.x = -0.95
	left_elbow.rotation.x = -1.0
	chest.rotation.y = sin(animation_time * 0.62) * 0.13


func _part(mesh: Mesh, material: Material, pos: Vector3, parent: Node3D) -> MeshInstance3D:
	var part := _mesh(mesh, material)
	part.position = pos
	parent.add_child(part)
	return part


func _mesh(mesh: Mesh, material: Material) -> MeshInstance3D:
	var item := MeshInstance3D.new()
	item.mesh = mesh
	item.material_override = material
	return item


func _material(color: Color, roughness: float, emission := Color.TRANSPARENT) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	# The loadout viewer uses deterministic unshaded swatches so armor remains
	# readable on Forward+, mobile, and software compatibility renderers alike.
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if emission.a > 0.0 or emission.r > 0.0 or emission.g > 0.0 or emission.b > 0.0:
		material.emission_enabled = true
		material.emission = emission
		material.emission_energy_multiplier = 0.55
	return material


func _box(size: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size
	return mesh


func _cylinder(radius: float, height: float, sides: int) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = sides
	return mesh


func _sphere(radius: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 24
	mesh.rings = 14
	return mesh


func _torus(radius: float, tube: float) -> TorusMesh:
	var mesh := TorusMesh.new()
	mesh.inner_radius = radius - tube
	mesh.outer_radius = radius + tube
	mesh.rings = 40
	mesh.ring_segments = 12
	return mesh
