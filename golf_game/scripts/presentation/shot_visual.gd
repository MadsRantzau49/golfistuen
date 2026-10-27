class_name ShotVisual
extends Node3D
## Interpolated presentation. Visibility scaling never pushes the sphere into the
## surface: its center is lifted by exactly the difference in rendered radius.

signal contact_updated(position: Vector3, radius: float, grounded: bool)
var ball: MeshInstance3D
var shadow: MeshInstance3D
var trail: ShotTrail
var show_trail := true
var locator: BallLocator
var tracking_enabled := false
var surface: RangeSurface
var rendered_radius := BallFlight.BALL_RADIUS
var previous_position := Vector3(0, BallFlight.BALL_RADIUS, 0)
var current_position := previous_position
var previous_velocity := Vector3.ZERO
var current_velocity := Vector3.ZERO
var _last_presented := previous_position
var _radius_initialized := false
var previous_time := 0.0
var current_time := 0.0


func _ready() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 48
	sphere.rings = 24
	ball = MeshInstance3D.new()
	ball.mesh = sphere
	var ball_material := ShaderMaterial.new()
	ball_material.shader = preload("res://shaders/golf_ball.gdshader")
	ball.material_override = ball_material
	add_child(ball)
	var disc := PlaneMesh.new()
	disc.size = Vector2(2, 2)
	shadow = MeshInstance3D.new()
	shadow.mesh = disc
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var shadow_material := ShaderMaterial.new()
	shadow_material.shader = preload("res://shaders/contact_shadow.gdshader")
	shadow.material_override = shadow_material
	add_child(shadow)
	trail = ShotTrail.new()
	add_child(trail)
	var locator_layer := CanvasLayer.new()
	locator_layer.layer = 0
	add_child(locator_layer)
	locator = BallLocator.new()
	locator.subject = ball
	locator_layer.add_child(locator)
	reset()


func reset() -> void:
	trail.clear_history()
	previous_time = 0.0
	current_time = 0.0
	previous_position = Vector3(0, BallFlight.BALL_RADIUS, 0)
	current_position = previous_position
	previous_velocity = Vector3.ZERO
	current_velocity = Vector3.ZERO
	_last_presented = previous_position
	_radius_initialized = false
	ball.quaternion = Quaternion.IDENTITY
	present(1.0, 1.0)


func update_ball(local_position: Vector3, record := true, velocity := Vector3.ZERO, time := -1.0) -> void:
	previous_position = current_position
	previous_velocity = current_velocity
	current_position = local_position
	current_velocity = velocity
	previous_time = current_time
	current_time = time if time >= 0.0 else current_time + BallFlight.STEP
	var world := global_position + local_position
	var altitude := world.y - (surface.world_height(world) if surface else global_position.y)
	if record and altitude > .06:
		trail.append_sample(local_position, velocity, current_time)
	elif not record:
		trail.end_flight()


func _process(delta: float) -> void:
	present(Engine.get_physics_interpolation_fraction(), delta)
	locator.enabled = tracking_enabled
	locator.radius = rendered_radius
	locator.queue_redraw()


func freeze_interpolation() -> void:
	previous_position = current_position
	previous_velocity = current_velocity
	previous_time = current_time


func present(fraction: float, delta: float) -> void:
	var point := previous_position.lerp(current_position, clampf(fraction, 0, 1))
	var world_point := global_position + point
	var floor_y := surface.world_height(world_point) if surface else global_position.y
	var altitude := maxf(0, world_point.y - floor_y - BallFlight.BALL_RADIUS)
	var camera := get_viewport().get_camera_3d()
	var desired_radius := BallFlight.BALL_RADIUS
	if camera:
		var distance := camera.global_position.distance_to(world_point)
		var pixel_size := distance * tan(deg_to_rad(camera.fov * .5)) * 2.0 / maxf(get_viewport().get_visible_rect().size.y, 1.0)
		desired_radius = clampf(pixel_size * 3.5, BallFlight.BALL_RADIUS, .25)
	if not _radius_initialized:
		rendered_radius = desired_radius
		_radius_initialized = true
	else:
		rendered_radius = lerpf(rendered_radius, desired_radius, 1.0 - exp(-delta * 8.0))
	if surface:rendered_radius=minf(rendered_radius,surface.visual_radius_limit(world_point))
	var displayed := Vector3(point.x, floor_y - global_position.y + altitude + rendered_radius, point.z)
	var displacement := displayed - _last_presented
	var horizontal := Vector3(displacement.x, 0, displacement.z)
	if horizontal.length_squared() > .00000001 and altitude < .06:
		var axis := Vector3.UP.cross(horizontal).normalized()
		ball.quaternion = Quaternion(axis, horizontal.length() / rendered_radius) * ball.quaternion
	ball.position = displayed
	ball.scale = Vector3.ONE * rendered_radius
	_last_presented = displayed
	shadow.position = Vector3(point.x, floor_y - global_position.y + .0015, point.z)
	var shadow_size := rendered_radius * (1.3 + minf(altitude * .12, 1.8))
	shadow.scale = Vector3(shadow_size, 1, shadow_size)
	shadow.material_override.set_shader_parameter("opacity", .42 * exp(-altitude * .28))
	contact_updated.emit(global_position + displayed, rendered_radius, altitude < .08)
	trail.prepare_frame(displayed, lerpf(previous_time, current_time, clampf(fraction, 0, 1)), show_trail)
