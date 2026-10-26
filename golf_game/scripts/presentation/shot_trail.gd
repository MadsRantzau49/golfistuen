class_name ShotTrail
extends MeshInstance3D
## A short, soft, camera-facing ribbon. Physics samples live in a bounded ring;
## the render-frame head is attached to the same interpolated ball as the camera.

const CAPACITY := 192
const TRAIL_SECONDS := .85
const FADE_SECONDS := .35
const MAX_SEGMENTS := 48
var head_position := Vector3.ZERO
var history_count := 0
var rendered_vertex_count := 0
var _positions := PackedVector3Array()
var _velocities := PackedVector3Array()
var _times := PackedFloat64Array()
var _first := 0
var _stopped := false
var _fade_elapsed := 0.0
var _last_render_time := 0.0
var _head_valid := false
var _end_time := 0.0
var _frozen_head := Vector3.ZERO
var _ribbon := ArrayMesh.new()
var _pending_head := Vector3.ZERO
var _pending_time := 0.0
var _pending_enabled := false


func _ready() -> void:
	process_priority = 12 # Ball at 0, camera at 10, then camera-facing geometry.
	_positions.resize(CAPACITY)
	_velocities.resize(CAPACITY)
	_times.resize(CAPACITY)
	mesh = _ribbon
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := ShaderMaterial.new()
	material.shader = preload("res://shaders/shot_trail.gdshader")
	material_override = material
	clear_history()


func clear_history() -> void:
	_first = 0
	history_count = 0
	rendered_vertex_count = 0
	_stopped = false
	_fade_elapsed = 0.0
	_last_render_time = 0.0
	_head_valid = false
	_pending_enabled = false
	_ribbon.clear_surfaces()
	visible = false


func append_sample(position: Vector3, velocity: Vector3, time: float) -> void:
	if _stopped: return
	if history_count > 0 and time <= _times[_index(history_count - 1)]: return
	if history_count == CAPACITY:
		_first = (_first + 1) % CAPACITY
		history_count -= 1
	var index := _index(history_count)
	_positions[index] = position
	_velocities[index] = velocity
	_times[index] = time
	history_count += 1
	while history_count > 2 and _times[_first] < time - TRAIL_SECONDS - .06:
		_first = (_first + 1) % CAPACITY
		history_count -= 1


func end_flight() -> void:
	if _stopped: return
	_stopped = true
	if history_count == 0: return
	_end_time = _last_render_time if _head_valid else _times[_index(history_count - 1)]
	_frozen_head = head_position if _head_valid else _positions[_index(history_count - 1)]


func _index(offset: int) -> int:
	return (_first + offset) % CAPACITY


func prepare_frame(head: Vector3, time: float, enabled: bool) -> void:
	_pending_head = head
	_pending_time = time
	_pending_enabled = enabled


func _process(delta: float) -> void:
	render_pending_frame(delta)


func render_pending_frame(delta: float) -> void:
	render_frame(_pending_head, _pending_time, get_viewport().get_camera_3d(), delta, _pending_enabled)


func render_frame(head: Vector3, time: float, camera: Camera3D, delta: float, enabled: bool) -> void:
	if _stopped: _fade_elapsed += maxf(delta, 0.0)
	var opacity := 1.0 - smoothstep(0.0, FADE_SECONDS, _fade_elapsed)
	visible = enabled and camera != null and history_count > 1 and opacity > .002
	if not visible:
		rendered_vertex_count = 0
		return
	if _stopped:
		time = _end_time
		head = _frozen_head
	else:
		head_position = head
		_last_render_time = time
		_head_valid = true
	var start_time := maxf(_times[_first], time - TRAIL_SECONDS)
	var span := time - start_time
	if span <= .0001:
		visible = false
		return
	var segments := clampi(ceili(span * 60.0), 2, MAX_SEGMENTS)
	var curve := PackedVector3Array()
	var cursor := 0
	for step in range(segments + 1):
		var query := lerpf(start_time, time, float(step) / segments)
		while cursor < history_count - 2 and _times[_index(cursor + 1)] < query:
			cursor += 1
		curve.append(_interpolate(cursor, query))
	# The visible head never waits for a distance threshold or another physics tick.
	var head_offset := head - curve[-1]
	for index in range(curve.size()):
		curve[index] += head_offset * pow(float(index) / segments, 3.0)
	curve[-1] = head
	_build_ribbon(curve, camera, opacity)


func _interpolate(offset: int, time: float) -> Vector3:
	var a := _index(offset)
	var b := _index(mini(offset + 1, history_count - 1))
	var duration := maxf(_times[b] - _times[a], .00001)
	var t := clampf((time - _times[a]) / duration, 0.0, 1.0)
	var t2 := t * t
	var t3 := t2 * t
	return _positions[a] * (2*t3-3*t2+1) + _velocities[a] * duration * (t3-2*t2+t) \
		+ _positions[b] * (-2*t3+3*t2) + _velocities[b] * duration * (t3-t2)


func _build_ribbon(curve: PackedVector3Array, camera: Camera3D, opacity: float) -> void:
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var uv := PackedVector2Array()
	var pixel_scale := tan(deg_to_rad(camera.fov * .5)) * 2.0 / maxf(get_viewport().get_visible_rect().size.y, 1.0)
	var inverse_basis := global_basis.inverse()
	var previous_side := camera.global_basis.x
	for index in range(curve.size()):
		var world := to_global(curve[index])
		var depth := -(camera.global_basis.z.dot(world - camera.global_position))
		if depth < .15: continue
		var before := curve[maxi(0, index - 1)]
		var after := curve[mini(curve.size() - 1, index + 1)]
		var tangent := (global_basis * (after - before)).normalized()
		var side := tangent.cross(camera.global_position - world).normalized()
		if side.length_squared() < .1: side = camera.global_basis.x
		if side.dot(previous_side) < 0: side = -side
		previous_side = side
		var progress := float(index) / (curve.size() - 1)
		var width := clampf(depth * pixel_scale * 1.1, .0001, .04) * lerpf(.15, 1.0, progress)
		var offset := inverse_basis * side * width
		var alpha := smoothstep(0.0, .35, progress) * opacity * .5
		vertices.append(curve[index] - offset)
		vertices.append(curve[index] + offset)
		colors.append(Color(.85, .94, .90, alpha))
		colors.append(Color(.85, .94, .90, alpha))
		uv.append(Vector2(0, progress))
		uv.append(Vector2(1, progress))
	_ribbon.clear_surfaces()
	rendered_vertex_count = vertices.size()
	if vertices.size() < 4:
		visible = false
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uv
	_ribbon.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLE_STRIP, arrays, [], {}, Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE)
