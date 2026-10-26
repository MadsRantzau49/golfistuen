class_name ObstructionFader
extends Node
## Fade complete obstructing objects with continuous opacity. No screen-space
## dithering and no camera-position decisions. Shadows have independent geometry.

const MIN_OPACITY := .025
var entries: Array[Dictionary] = []
var camera_position := Vector3.ZERO
var subject_position := Vector3.ZERO
var enabled := false


func _ready() -> void:
	process_priority = 15 # Camera has already published this render frame's view.


func register_instance(node: MultiMeshInstance3D, index: int, bounds: AABB, use_color := false) -> void:
	entries.append({"node": weakref(node), "index": index, "bounds": bounds,
		"opacity": 1.0, "use_color": use_color, "material": null})


func register_mesh(node: MeshInstance3D, bounds: AABB) -> void:
	entries.append({"node": weakref(node), "index": -1, "bounds": bounds,
		"opacity": 1.0, "use_color": false, "material": null})
	if node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
		var shadow := MeshInstance3D.new()
		shadow.name = "StableShadow"
		shadow.mesh = node.mesh
		shadow.material_override = node.material_override
		shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		node.add_child(shadow)
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func unregister_subtree(parent: Node) -> void:
	var kept: Array[Dictionary]=[]
	for entry in entries:
		var node:Node=entry.node.get_ref()
		if is_instance_valid(node) and node!=parent and not parent.is_ancestor_of(node): kept.append(entry)
	entries=kept


func set_view(position: Vector3, subject: Vector3, active: bool) -> void:
	camera_position = position
	subject_position = subject
	enabled = active


func _process(delta: float) -> void:
	update_fades(delta)


func update_fades(delta: float) -> void:
	var query := AABB(camera_position.min(subject_position), (camera_position - subject_position).abs()).grow(.45)
	for entry in entries:
		var node: GeometryInstance3D = entry.node.get_ref()
		if not is_instance_valid(node): continue
		var bounds: AABB = entry.bounds
		var blocked := enabled and bounds.intersects(query) and bounds.grow(.3).intersects_segment(camera_position, subject_position) != null
		var target := MIN_OPACITY if blocked else 1.0
		var rate := 9.0 if blocked else 5.5
		var opacity := lerpf(float(entry.opacity), target, 1.0 - exp(-minf(delta, .1) * rate))
		if absf(opacity - target) < .001: opacity = target
		if is_equal_approx(opacity, float(entry.opacity)): continue
		entry.opacity = opacity
		if entry.index >= 0:
			if entry.use_color:
				node.multimesh.set_instance_color(entry.index, Color(1, 1, 1, opacity))
			else:
				node.multimesh.set_instance_custom_data(entry.index, Color(0, 0, 0, opacity))
		else:
			_fade_mesh(node, entry, opacity)


func _fade_mesh(node: MeshInstance3D, entry: Dictionary, opacity: float) -> void:
	if entry.material == null:
		if node.material_override == null: return
		entry.material = node.material_override.duplicate()
		node.material_override = entry.material
	var material: Material = entry.material
	if material is StandardMaterial3D:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS if opacity < .999 else BaseMaterial3D.TRANSPARENCY_DISABLED
		var color: Color = material.albedo_color
		color.a = opacity
		material.albedo_color = color
	elif material is ShaderMaterial:
		material.set_shader_parameter("obstruction_opacity", opacity)
