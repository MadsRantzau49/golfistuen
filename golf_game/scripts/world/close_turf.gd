class_name CloseTurf
extends Node3D
## World-anchored, camera-local grass geometry. Three small moving detail patches
## replace the old magnified noise without filling the entire range with blades.

var surface: RangeSurface
var material: ShaderMaterial
var shader_override: Shader
var terrain_maps: Dictionary={}
var patches: Array[MultiMeshInstance3D] = []
var ball_position := Vector3.ZERO
var ball_radius := .03
var ball_grounded := false
var _detail_visibility := [0.0, 0.0, 0.0]


func _ready() -> void:
	process_priority = 20
	material = ShaderMaterial.new()
	material.shader = shader_override if shader_override else preload("res://shaders/close_turf.gdshader")
	if terrain_maps.is_empty():
		var image := Image.create_from_data(AlpineLandscape.GRID_SIZE + 1, AlpineLandscape.GRID_SIZE + 1,
			false, Image.FORMAT_RF, surface.landscape.sampled_heights.to_byte_array())
		material.set_shader_parameter("height_field", ImageTexture.create_from_image(image))
	else:
		for key in terrain_maps: material.set_shader_parameter(key,terrain_maps[key])
	material.set_shader_parameter("fairway_height", RangeSurface.FAIRWAY_CANOPY)
	material.set_shader_parameter("rough_height", RangeSurface.ROUGH_CANOPY)
	material.set_shader_parameter("mat_height", RangeSurface.MAT_CANOPY)
	for index in range(3):
		var instance := MultiMeshInstance3D.new()
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.use_custom_data = true
		multi.mesh = _blade_mesh([7, 5, 3][index])
		multi.instance_count = [12000, 6500, 4500][index]
		multi.visible_instance_count = 0
		instance.multimesh = multi
		instance.material_override = material.duplicate()
		instance.extra_cull_margin = 100.0 # Ground height is applied on the GPU.
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(instance)
		patches.append(instance)
	_build_patch(0, .07, 4.0, 0.0)
	_build_patch(1, .22, 10.0, 3.5)
	_build_patch(2, .55, 21.0, 9.5)


func apply_quality(quality: String) -> void:
	var density: float = {"Low": .4, "Medium": .7, "High": 1.0}.get(quality, 1.0)
	for patch in patches:
		patch.material_override.set_shader_parameter("density", density)


func _process(delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null or surface == null: return
	var forward := -camera.global_basis.z
	var reach := clampf(camera.global_position.y / maxf(-forward.y, .15), 2.0, 24.0)
	var focus := camera.global_position + forward * reach
	focus.y = 0
	update_focus(focus)
	var altitude := camera.global_position.y - surface.world_height(camera.global_position)
	for index in range(patches.size()):
		var patch := patches[index]
		# Millimetre blades cannot be resolved from an aerial camera. Reserve the
		# densest mesh for the close rollout view rather than shading it off-screen.
		var threshold: float = [3.2, 6.5, 12.0][index]
		var target := 1.0 - smoothstep(threshold * .8, threshold + .8, altitude)
		_detail_visibility[index] = lerpf(_detail_visibility[index], target, 1.0 - exp(-maxf(delta, 0.0) * 5.0))
		patch.visible = _detail_visibility[index] > .025
		patch.material_override.set_shader_parameter("detail_visibility", _detail_visibility[index])
		patch.material_override.set_shader_parameter("ball_position", ball_position)
		patch.material_override.set_shader_parameter("ball_radius", ball_radius)
		patch.material_override.set_shader_parameter("ball_grounded", ball_grounded)


func update_focus(focus: Vector3) -> void:
	# A uniform/transform update only. No thousands-of-instances CPU rebuilds while
	# following a shot. World-coordinate jitter keeps overlapping blades stationary.
	for index in range(patches.size()):
		var spacing: float = [.07, .22, .55][index]
		var center := focus
		var camera := get_viewport().get_camera_3d()
		if index == 0 and camera:
			var forward := -camera.global_basis.z
			center = camera.global_position + Vector3(forward.x, 0, forward.z).normalized() * 2.6
		patches[index].position = Vector3(roundf(center.x / spacing) * spacing, 0,
			roundf(center.z / spacing) * spacing)


func _build_patch(index: int, spacing: float, radius: float, inner: float) -> void:
	var multi := patches[index].multimesh
	var extent := ceili(radius / spacing)
	var count := 0
	for z in range(-extent, extent + 1):
		for x in range(-extent, extent + 1):
			var point := Vector3(x * spacing, 0, z * spacing)
			var distance := point.length()
			if distance > radius or distance < inner: continue
			multi.set_instance_transform(count, Transform3D(Basis.IDENTITY, point))
			multi.set_instance_custom_data(count, Color(point.x, point.z, spacing, radius))
			count += 1
			if count == multi.instance_count: break
		if count == multi.instance_count: break
	multi.visible_instance_count = count


func _blade_mesh(blade_count: int) -> ArrayMesh:
	var builder := SurfaceTool.new()
	builder.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5483 + blade_count
	for blade in range(blade_count):
		var angle := rng.randf() * TAU
		var side := Vector3(cos(angle), 0, sin(angle)) * rng.randf_range(.0009, .0018)
		var base := Vector3(rng.randf_range(-.065, .065), 0, rng.randf_range(-.065, .065))
		var height := rng.randf_range(.012, RangeSurface.FAIRWAY_CANOPY)
		var bend := Vector3(sin(angle), 0, -cos(angle)) * height * .2
		var middle := base + Vector3.UP * height * .55 + bend * .3
		var tip := base + Vector3.UP * height + bend
		var vertices := [base - side, middle - side * .65, base + side,
			base + side, middle - side * .65, middle + side * .65,
			middle - side * .65, tip, middle + side * .65]
		for point in vertices:
			var h: float = (point.y - base.y) / height
			builder.set_uv(Vector2(.5, h))
			builder.set_normal(Vector3.UP.lerp(Vector3(sin(angle), .4, cos(angle)).normalized(), h * .35))
			builder.add_vertex(point)
	builder.index()
	return builder.commit()
