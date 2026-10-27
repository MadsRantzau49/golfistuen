class_name RangeCamera
extends Camera3D
## The single gameplay camera: directly behind the aiming line at address,
## smoothly following the ball after launch. Objects fade; they never steer it.

signal framing_updated(position: Vector3, subject: Vector3, protect: bool)

const ADDRESS_DISTANCE := 8.0
const ADDRESS_HEIGHT := 2.4
var ball_position := RangeSurface.LAUNCH_ORIGIN
var ball_velocity := Vector3.ZERO
var ball_subject: Node3D
var shot_active := false
var initialized := false
var menu_mode := false
var reduced_motion := false
var clock := 0.0
var clearance: CameraClearance
var heading := Vector3.FORWARD
var landed := false
var launch_origin := RangeSurface.LAUNCH_ORIGIN
var _offset := Vector3(0, ADDRESS_HEIGHT, ADDRESS_DISTANCE)
var _landing_blend := 0.0
var _shot_time := 0.0
var _previous_menu := false


func _ready() -> void:
	process_priority = 10
	current = true
	fov = 57.0
	near = .025
	far = 2400.0
	_snap_address()
	initialized = true


func view_name() -> String:
	return "FOLLOW BALL"


func set_launch_anchor(origin: Vector3, direction: Vector3, snap := true) -> void:
	launch_origin = origin
	heading = Vector3(direction.x, 0, direction.z).normalized()
	if heading.length_squared() < .1: heading = Vector3.FORWARD
	shot_active = false
	landed = false
	_landing_blend = 0
	_shot_time = 0
	ball_position = origin + Vector3.UP * BallFlight.BALL_RADIUS
	if snap: _snap_address()


func _address_position() -> Vector3:
	return _above_ground(launch_origin - heading * ADDRESS_DISTANCE + Vector3.UP * ADDRESS_HEIGHT)


func _address_target() -> Vector3:
	return launch_origin + heading * 28.0 + Vector3.UP * .6


func _snap_address() -> void:
	fov = 57.0
	global_position = _address_position()
	look_at(_address_target())
	_offset = global_position - (launch_origin + Vector3.UP * BallFlight.BALL_RADIUS)


func begin_shot(position: Vector3, velocity: Vector3) -> void:
	ball_position = position
	ball_velocity = velocity
	# Preserve the selected aim, rather than starting to the side of a detected
	# shot. Its lateral deviation is visible against the centred target line.
	_snap_address()
	_offset = global_position - position
	shot_active = true
	landed = false
	_landing_blend = 0
	_shot_time = 0


func reset_tracking() -> void:
	shot_active = false
	landed = false
	_landing_blend = 0
	_shot_time = 0
	ball_position = launch_origin + Vector3.UP * BallFlight.BALL_RADIUS
	_snap_address()


func _process(delta: float) -> void:
	update_camera(delta)


func update_camera(delta: float) -> void:
	if not initialized: return
	var dt := minf(delta, .1)
	clock += dt
	if is_instance_valid(ball_subject): ball_position = ball_subject.global_position
	if menu_mode:
		var desired := Vector3(5, 8, 35)
		if not reduced_motion:
			desired.x += sin(clock * .04) * 3.0
			desired.y += sin(clock * .07) * .25
		global_position = global_position.lerp(desired, 1.0 - exp(-dt * 2.4))
		look_at(Vector3(-30, 27, -210))
		_previous_menu = true
		framing_updated.emit(global_position, ball_position, false)
		return
	if not shot_active:
		if _previous_menu: _snap_address()
		global_position = global_position.lerp(_address_position(), 1.0 - exp(-dt * 6.0))
		look_at(_address_target())
		fov = lerpf(fov, 57.0, 1.0 - exp(-dt * 4.0))
	else:
		_shot_time += dt
		_landing_blend = lerpf(_landing_blend, 1.0 if landed else 0.0, 1.0 - exp(-dt * 1.8))
		var distance := lerpf(11.5, 3.8, _landing_blend)
		var height := lerpf(4.4, 1.35, _landing_blend)
		if reduced_motion: distance = 14.0; height = 7.0
		var desired_offset := -heading * distance + Vector3.UP * height
		_offset = _offset.lerp(desired_offset, 1.0 - exp(-dt * 3.0))
		global_position = _above_ground(ball_position + _offset)
		fov = lerpf(fov, lerpf(53.0, 47.0, _landing_blend), 1.0 - exp(-dt * 3.0))
		var focus := smoothstep(0.0, .7, _shot_time)
		var address_focus := heading * 28.0 + Vector3.UP * .6
		var following_focus := -Vector3.UP * distance * .025
		look_at(ball_position + address_focus.lerp(following_focus, focus))
	_previous_menu = false
	framing_updated.emit(global_position, ball_position, true)


func _above_ground(preferred: Vector3) -> Vector3:
	var result := preferred
	var floor_y := clearance.ground(preferred) if clearance else 0.0
	result.y = maxf(result.y, floor_y + 1.0)
	return result
