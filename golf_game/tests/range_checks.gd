extends SceneTree
## Run with: godot --headless --path golf_game --script res://tests/range_checks.gd
## Explicit checks instead of assertions: a failure always exits nonzero.

var failures := 0


func _initialize() -> void:
	_run.call_deferred()
	create_timer(45).timeout.connect(func():
		printerr("FAIL: checks did not complete within 45 seconds")
		quit(1)
	)


func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: " + message)


func _run() -> void:
	_check_contract()
	_check_physics()
	_check_side_spin()
	var scene := load("res://scenes/driving_range.tscn") as PackedScene
	var range_scene := scene.instantiate()
	root.add_child(range_scene)
	var payload := {"shot_id": "integration-1", "speed_mps": 42.0,
		"direction_deg": 3.0, "elevation_deg": 30.0, "spin_rpm": 600.0}
	check(range_scene.receive_shot(payload), "Valid event parses")
	check(range_scene.active, "Shot event starts the simulation")
	var original_model: BallFlight = range_scene.model
	range_scene.receive_shot(payload)
	check(range_scene.model == original_model, "Duplicate event cannot restart a shot")
	range_scene.receive_shot({"shot_id": "busy", "speed_mps": 20.0,
		"direction_deg": 0.0, "elevation_deg": 20.0})
	check(range_scene.model == original_model, "Busy range cannot be interrupted by another event")
	_finish(range_scene)
	check(range_scene.model.finished and range_scene.model.has_landed, "Shot lands and comes to rest")
	check(range_scene.model.distance_m() >= range_scene.model.carry_m, "Total includes rollout")
	check(range_scene.hud.shot_count == 1, "Completed shot appears in history")
	check(range_scene.model.position.x > 0.0, "Positive direction travels right")
	var expected_total: float = range_scene.model.distance_m()
	var predicted := BallFlight.preview(range_scene.last_shot, range_scene.world.surface.local_height, range_scene.world.surface.resistance)
	check(predicted[-1].distance_to(range_scene.model.position) < 0.001, "Preview and executed flight agree")
	range_scene.replay_last()
	_finish(range_scene)
	check(abs(range_scene.model.distance_m() - expected_total) < 0.001, "Replay reproduces the result")
	check(range_scene.hud.shot_count == 1, "Replay does not add a new history entry")
	_check_surface_contact(range_scene)
	_check_trail(range_scene)
	range_scene.reset_tee()
	check(not range_scene.active and range_scene.model == null, "Reset returns a fresh tee")
	# A previously busy event can be retried after the range becomes ready.
	range_scene.receive_shot({"shot_id": "busy", "speed_mps": 20.0,
		"direction_deg": 0.0, "elevation_deg": 20.0})
	check(range_scene.active, "Busy input is not incorrectly marked as consumed")
	range_scene.reset_tee()
	if failures == 0:
		print("PASS: shot/spin contract, mirrored side-spin physics, launch axes, landing/rollout, preview/replay, bounded smooth trail, history and reset")
	quit(1 if failures else 0)


func _check_surface_contact(range_scene: Node) -> void:
	var surface: RangeSurface = range_scene.world.surface
	var model: BallFlight = range_scene.model
	var physical := model.position + RangeSurface.LAUNCH_ORIGIN
	check(absf(physical.y - BallFlight.BALL_RADIUS - surface.world_height(physical)) < .0001,
		"A stopped ball rests on the rendered surface, not the old tee-height plane")
	var visual: ShotVisual = range_scene.visual
	visual.present(1.0, 1.0 / 60.0)
	var bottom := visual.ball.global_position.y - visual.rendered_radius
	check(absf(bottom - surface.world_height(visual.ball.global_position)) < .0001,
		"Readability enlargement cannot push the rendered ball below the grass")
	var tilted := BallFlight.new()
	tilted.ground_height = func(point: Vector3) -> float: return .1 * point.x
	tilted.launch(GolfShot.from_payload({"shot_id":"slope", "speed_mps":15.0, "direction_deg":30.0, "elevation_deg":10.0}))
	for frame in range(2000):
		tilted.step()
		check(tilted.position.y + .00001 >= tilted.surface_height(tilted.position) + BallFlight.BALL_RADIUS,
			"Swept contact prevents the ball entering a rising surface")
		if tilted.finished: break


func _finish(range_scene: Node) -> void:
	for index in range(4800):
		range_scene._physics_process(BallFlight.STEP)
		if not range_scene.active:
			break


func _check_contract() -> void:
	var good := {"shot_id": "test", "speed_mps": 30.0,
		"direction_deg": 0.0, "elevation_deg": 20.0}
	check(GolfShot.from_payload(good).spin_rpm == 0.0, "Legacy payloads default to neutral spin")
	for field in ["speed_mps", "direction_deg", "elevation_deg", "spin_rpm"]:
		for bad_value in [NAN, INF, "30", null, true]:
			var invalid := good.duplicate()
			invalid[field] = bad_value
			check(GolfShot.from_payload(invalid) == null, "Reject malformed field " + field)
	for patch in [{"shot_id": ""}, {"shot_id": 2}, {"speed_mps": -1},
		{"speed_mps": 101}, {"direction_deg": 90}, {"elevation_deg": -2}, {"spin_rpm": 12001}]:
		var invalid := good.duplicate()
		invalid.merge(patch, true)
		check(GolfShot.from_payload(invalid) == null, "Reject invalid launch bounds")
	var shot := GolfShot.from_payload(good)
	check(abs(shot.velocity().length() - 30.0) < 0.001, "Angles preserve launch speed")
	check(is_zero_approx(shot.velocity().x) and shot.velocity().z < 0, "Straight shot follows Godot -Z")
	var spinning := good.duplicate()
	spinning.spin_rpm = -1800.0
	var parsed := GolfShot.from_payload(spinning)
	check(parsed.to_payload().spin_rpm == -1800.0, "Signed RPM survives serialization")
	check(parsed.velocity() == shot.velocity(), "Spin does not change the launch speed or angles")


func _check_side_spin() -> void:
	var results: Dictionary = {}
	for rpm in [-1800.0, 0.0, 1800.0]:
		var shot := GolfShot.from_payload({"shot_id":"spin", "speed_mps":42.0,
			"direction_deg":0.0, "elevation_deg":30.0, "spin_rpm":rpm})
		var model := BallFlight.new()
		model.launch(shot)
		check(is_zero_approx(model.side_spin_acceleration().y), "Side spin adds no backspin/topspin force")
		for frame in range(4800):
			model.step()
			if model.finished: break
		check(model.finished, "Spinning shot lands and stops")
		results[rpm] = model
	check(results[-1800.0].first_landing.x < -1.0, "Negative spin bends left")
	check(results[1800.0].first_landing.x > 1.0, "Positive spin bends right")
	check(is_zero_approx(results[0.0].first_landing.x), "Neutral spin stays straight")
	check(absf(results[-1800.0].first_landing.x + results[1800.0].first_landing.x) < .001,
		"Equal opposite spins produce mirrored lateral flight")
	check(absf(results[-1800.0].apex_m - results[1800.0].apex_m) < .001,
		"Left/right spin uses the same vertical model")


func _check_trail(scene: Node) -> void:
	scene.reset_tee()
	scene.camera.view = RangeCamera.View.FOLLOW
	scene.source.fire(42, 0, 30, 1200)
	for frame in range(180):
		scene._physics_process(BallFlight.STEP)
		scene.visual.present(.5, BallFlight.STEP)
		scene.camera.update_camera(BallFlight.STEP)
		scene.visual.trail.render_pending_frame(BallFlight.STEP)
	var visual: ShotVisual = scene.visual
	var trail: ShotTrail = visual.trail
	check(trail.history_count <= ShotTrail.CAPACITY, "Trail history stays bounded")
	check(trail.rendered_vertex_count <= (ShotTrail.MAX_SEGMENTS + 1) * 2, "Trail geometry has a fixed render-frame budget")
	check(trail.head_position.distance_to(visual.ball.position) < .00001, "Trail head uses the ball's interpolated render position")
	if trail.mesh.get_surface_count() > 0:
		var vertices: PackedVector3Array = trail.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		check(((vertices[-1] + vertices[-2]) * .5).distance_to(visual.ball.position) < .0001,
			"The actual ribbon mesh reaches the ball, not the previous physics sample")
	trail.end_flight()
	visual.present(.5, ShotTrail.FADE_SECONDS + .01)
	trail.render_pending_frame(ShotTrail.FADE_SECONDS + .01)
	check(not trail.visible, "Trail fades away after landing rather than remaining over the grass")
	scene.reset_tee()


func _check_physics() -> void:
	for preset_name in DemoShotSource.PRESETS:
		var payload: Dictionary = DemoShotSource.PRESETS[preset_name].duplicate()
		payload.shot_id = preset_name
		var shot := GolfShot.from_payload(payload)
		var model := BallFlight.new()
		model.launch(shot)
		for index in range(4800):
			model.step()
			if model.finished:
				break
		check(model.finished and model.has_landed, preset_name + " lands and stops")
		check(model.carry_m > 10.0 and model.carry_m < 350.0, preset_name + " has plausible range bounds")
		check(model.position.y + 0.000001 >= BallFlight.BALL_RADIUS, "Ball cannot tunnel below the ground")
		print("%s: %.1f m carry, %.1f m total, %.1f m apex" % [preset_name, model.carry_m, model.distance_m(), model.apex_m])
