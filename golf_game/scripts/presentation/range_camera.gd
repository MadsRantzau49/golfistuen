class_name RangeCamera
extends Camera3D
## Subject-relative camera rig. Smooth the offset, not the moving subject: world-
## space camera lag and independently lagging aim are what used to lose the ball.

signal framing_updated(position: Vector3, subject: Vector3, protect: bool)

enum View { TEE, FOLLOW, OVERVIEW }
const TEE_POSITION := Vector3(8.5, 4.8, 25)
const TEE_TARGET := Vector3(-6, 20, -200)
var view := View.TEE
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
var _last_view := -1
var _offset := Vector3(3, 4, 13)
var _landing_blend := 0.0
var _tracking := false
var _previous_menu := false
var launch_origin := RangeSurface.LAUNCH_ORIGIN
var tee_position := TEE_POSITION
var tee_target := TEE_TARGET
var overview_position := Vector3(110,135,75)
var overview_target := Vector3(-12,0,-125)


func set_launch_anchor(origin:Vector3,direction:Vector3,snap:=true)->void:
	launch_origin=origin
	heading=Vector3(direction.x,0,direction.z).normalized()
	if heading.length_squared()<.1:heading=Vector3.FORWARD
	var right:=heading.cross(Vector3.UP).normalized()
	tee_position=origin-heading*16+right*5+Vector3.UP*5
	tee_target=origin+heading*120+Vector3.UP*10
	shot_active=false;_tracking=false;landed=false;_landing_blend=0
	ball_position=origin+Vector3.UP*BallFlight.BALL_RADIUS
	if snap:global_position=tee_position;look_at(tee_target)


func _ready() -> void:
	process_priority = 10 # Ball render interpolation runs first.
	current = true
	fov = 57.0
	near = .035
	far = 2400.0
	global_position = TEE_POSITION
	look_at(TEE_TARGET)
	initialized = true


func begin_shot(position: Vector3, velocity: Vector3) -> void:
	ball_position = position
	ball_velocity = velocity
	heading = Vector3(velocity.x, 0, velocity.z).normalized()
	if heading.length_squared() < .1: heading = Vector3.FORWARD
	shot_active = true
	landed = false
	_landing_blend = 0.0
	_tracking = false
	# A fresh shot starts at the tee; never fly back through 200 m of scenery.
	if global_position.distance_to(position) > 50:
		global_position = tee_position
		look_at(tee_target)


func reset_tracking() -> void:
	shot_active = false
	landed = false
	_tracking = false
	_landing_blend = 0.0
	ball_position = launch_origin
	heading = Vector3.FORWARD
	if global_position.distance_to(ball_position) > 40:
		global_position = tee_position
		look_at(tee_target)


func cycle_view() -> void:
	view = (view + 1) % 3 as View


func view_name() -> String:
	return ["TEE VIEW", "FOLLOW BALL", "BIRD’S EYE"][view]


func _process(delta: float) -> void:
	update_camera(delta)


func update_camera(delta: float) -> void:
	if not initialized: return
	var dt := minf(delta, .1)
	clock += dt
	if is_instance_valid(ball_subject): ball_position = ball_subject.global_position
	if menu_mode:
		var position := Vector3(5, 8, 35)
		if not reduced_motion:
			position.x += sin(clock * .04) * 3.0
			position.y += sin(clock * .07) * .25
		global_position = global_position.lerp(position, 1.0 - exp(-dt * 2.4))
		look_at(Vector3(-30, 27, -210))
		_previous_menu = true
		framing_updated.emit(global_position, ball_position, false)
		return
	var changed := _last_view != view or _previous_menu
	_last_view = view
	_previous_menu = false
	if view == View.FOLLOW:
		_follow(dt, changed)
	elif view == View.OVERVIEW:
		var position := overview_position
		var target := overview_target
		if shot_active: target = target.lerp(ball_position, .7)
		_move_static(position, target, dt, changed)
		_keep_subject_framed()
	else:
		var target := tee_target
		if shot_active:
			var distance := ball_position.distance_to(launch_origin)
			target = target.lerp(ball_position, smoothstep(8.0, 35.0, distance))
		_move_static(tee_position, target, dt, changed)
		_keep_subject_framed()
	framing_updated.emit(global_position, ball_position, true)


func _follow(dt: float, changed: bool) -> void:
	var right := heading.cross(Vector3.UP).normalized()
	var grounded_target := 1.0 if landed else 0.0
	_landing_blend = lerpf(_landing_blend, grounded_target, 1.0 - exp(-dt * 1.8))
	var distance := lerpf(11.5, 3.8, _landing_blend)
	var height := lerpf(4.4, 1.35, _landing_blend)
	var side := lerpf(1.7, .8, _landing_blend)
	if reduced_motion:
		distance = 14.0
		height = 7.0
		side = 1.3
	var desired_offset := -heading * distance + right * side + Vector3.UP * height
	if not _tracking or changed:
		_offset = global_position - ball_position
		if _offset.length() > 28.0 or _offset.length() < 2.5:
			_offset = desired_offset
		_tracking = true
	_offset = _offset.lerp(desired_offset, 1.0 - exp(-dt * 3.0))
	var desired := ball_position + _offset
	# Objects never orbit, lift or snap this rig. The visibility controller fades
	# them instead; only the actual ground can impose a minimum lens height.
	var result := _above_ground(desired)
	global_position = result
	fov = lerpf(fov, lerpf(53.0, 47.0, _landing_blend), 1.0 - exp(-dt * 3.0))
	# An exact subject-relative aim avoids a second, lagging rotation spring.
	var framing := right * result.distance_to(ball_position) * .06
	look_at(ball_position + framing - Vector3.UP * distance * .025)


func _above_ground(preferred: Vector3) -> Vector3:
	var result := preferred
	var floor_y := clearance.ground(preferred) if clearance else 0.0
	result.y = maxf(result.y, floor_y + 1.0)
	return result


func _move_static(position: Vector3, target: Vector3, dt: float, changed: bool) -> void:
	var preferred := _above_ground(position)
	if changed and global_position.distance_to(preferred) > 40:
		global_position = preferred # Intentional view change, not a long tree-clipping dolly.
	else:
		global_position = global_position.lerp(preferred, 1.0 - exp(-dt * 3.0))
	fov = lerpf(fov, 57.0 if view == View.TEE else 65.0, 1.0 - exp(-dt * 3.0))
	look_at(target)


func _keep_subject_framed() -> void:
	if not shot_active: return
	var viewport_size := get_viewport().get_visible_rect().size
	var point := unproject_position(ball_position)
	var safe := Rect2(viewport_size * Vector2(.1, .14), viewport_size * Vector2(.60, .62))
	if is_position_behind(ball_position) or not safe.has_point(point):
		var distance := global_position.distance_to(ball_position)
		look_at(ball_position + global_basis.x * distance * .06)
