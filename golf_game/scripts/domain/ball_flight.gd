class_name BallFlight
extends RefCounted
## Scene-independent golf model with injectable ground and rolling resistance.
## Used both for live shots and previews; no second flight solver to keep in sync.
## Lift is an explicit gameplay assumption, not a radar spin measurement.

const STEP := 1.0 / 120.0
const BALL_RADIUS := 0.02135 # Regulation 42.7 mm golf-ball diameter.
const GRAVITY := 9.81
const DRAG := 0.0035
const ASSUMED_LIFT := 0.0012
const STOP_SPEED := 0.22
const AIR_DENSITY := 1.225
const BALL_MASS := .04593
const AERODYNAMIC_FACTOR := .5 * AIR_DENSITY * PI * BALL_RADIUS * BALL_RADIUS / BALL_MASS

var position := Vector3(0.0, BALL_RADIUS, 0.0)
var velocity := Vector3.ZERO
var elapsed := 0.0
var apex_m := 0.0
var carry_m := 0.0
var first_landing := Vector3.ZERO
var has_landed := false
var finished := false
var phase := "READY"
var ground_height := Callable()
var ground_resistance := Callable()
var ground_bounce := Callable()
var launch_spin_rpm := 0.0
var spin_rpm := 0.0
var free_step_end := position


func launch(shot: GolfShot, yaw_radians := 0.0) -> void:
	position = Vector3(0.0, BALL_RADIUS, 0.0)
	free_step_end=position
	velocity = shot.velocity().rotated(Vector3.UP,yaw_radians)
	launch_spin_rpm = shot.spin_rpm
	spin_rpm = shot.spin_rpm
	elapsed = 0.0
	apex_m = 0.0
	carry_m = 0.0
	first_landing = Vector3.ZERO
	has_landed = false
	finished = false
	phase = "FLIGHT"


func step(dt: float = STEP) -> void:
	if finished or phase == "READY":
		return
	elapsed += dt
	free_step_end=position
	if phase == "ROLLING":
		spin_rpm *= exp(-dt * 6.0)
		if elapsed >= 40.0:
			position.y = surface_height(position) + BALL_RADIUS
			velocity = Vector3.ZERO
			finished = true
			phase = "REST"
			return
		var resistance := rolling_resistance(position)
		var normal := surface_normal(position)
		var slope_force := Vector3.DOWN * GRAVITY - normal * Vector3.DOWN.dot(normal) * GRAVITY
		slope_force.y = 0.0
		velocity.y = 0.0
		velocity += slope_force * dt
		velocity = velocity.move_toward(Vector3.ZERO, resistance * dt)
		position += velocity * dt
		free_step_end=position
		if position.y - surface_height(position) - BALL_RADIUS > .025:
			phase = "BOUNCE" # Rolling off a raised tee/edge is a short fall, not a snap.
			return
		position.y = surface_height(position) + BALL_RADIUS
		if velocity.length() < STOP_SPEED and slope_force.length() < resistance:
			velocity = Vector3.ZERO
			finished = true
			phase = "REST"
		return
	var speed := velocity.length()
	var lift := minf(ASSUMED_LIFT * speed * speed, 4.8)
	var acceleration := Vector3(0.0, -GRAVITY + lift, 0.0) - DRAG * speed * velocity
	# A vertical spin axis produces horizontal Magnus curvature only. It does
	# not introduce a backspin/topspin launch input or an extra vertical force.
	acceleration += side_spin_acceleration()
	spin_rpm *= exp(-dt * .08)
	var previous := position
	velocity += acceleration * dt
	position += velocity * dt
	free_step_end=position
	apex_m = maxf(apex_m, position.y - BALL_RADIUS)
	var normal := surface_normal(position)
	if position.y <= surface_height(position) + BALL_RADIUS and velocity.dot(normal) < 0.0:
		# Sweep to first contact so a fast ball cannot tunnel through rising terrain.
		var low := 0.0
		var high := 1.0
		for iteration in range(10):
			var middle := (low + high) * .5
			var point := previous.lerp(position, middle)
			if point.y > surface_height(point) + BALL_RADIUS: low = middle
			else: high = middle
		position = previous.lerp(position, high)
		position.y = surface_height(position) + BALL_RADIUS
		normal = surface_normal(position)
		if not has_landed:
			has_landed = true
			first_landing = position
			carry_m = Vector2(position.x, position.z).length()
		var normal_speed := velocity.dot(normal)
		var tangent := velocity - normal * normal_speed
		var response := Vector2(.28,.72)
		if ground_bounce.is_valid(): response=ground_bounce.call(position)
		velocity = tangent * response.y - normal * normal_speed * response.x
		spin_rpm *= .45
		phase = "BOUNCE"
		if absf(velocity.dot(normal)) < 1.2:
			velocity.y = 0.0
			phase = "ROLLING"
	# Defensive bound for future input adapters and gameplay tuning.
	if elapsed >= 40.0:
		finished = true
		phase = "REST"


func distance_m() -> float:
	return Vector2(position.x, position.z).length()


func side_spin_acceleration() -> Vector3:
	var speed := velocity.length()
	if absf(spin_rpm) < .01 or speed < .5: return Vector3.ZERO
	var omega := absf(spin_rpm) * TAU / 60.0
	var ratio := omega * BALL_RADIUS / speed
	var coefficient := minf(.4 * ratio, .25)
	var lateral_velocity := Vector3.DOWN.cross(velocity) * signf(spin_rpm)
	return lateral_velocity * AERODYNAMIC_FACTOR * coefficient * speed


func surface_height(point: Vector3) -> float:
	return float(ground_height.call(point)) if ground_height.is_valid() else 0.0


func rolling_resistance(point: Vector3) -> float:
	if ground_resistance.is_valid(): return float(ground_resistance.call(point))
	return 1.9 if absf(point.x) < 30.0 else 4.2


func surface_normal(point: Vector3) -> Vector3:
	if not ground_height.is_valid(): return Vector3.UP
	var step_size := .15
	var dx := surface_height(point + Vector3(step_size, 0, 0)) - surface_height(point - Vector3(step_size, 0, 0))
	var dz := surface_height(point + Vector3(0, 0, step_size)) - surface_height(point - Vector3(0, 0, step_size))
	return Vector3(-dx, step_size * 2.0, -dz).normalized()


static func preview(shot: GolfShot, height_sampler := Callable(), resistance_sampler := Callable(), yaw_radians := 0.0, bounce_sampler := Callable()) -> PackedVector3Array:
	var model := BallFlight.new()
	model.ground_height = height_sampler
	model.ground_resistance = resistance_sampler
	model.ground_bounce = bounce_sampler
	model.launch(shot,yaw_radians)
	var points := PackedVector3Array([model.position])
	for index in range(4800):
		model.step()
		if index % 12 == 0 or model.finished:
			points.append(model.position)
		if model.finished:
			break
	return points
