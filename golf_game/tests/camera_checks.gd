extends SceneTree
## Follow the entire shot, not just a screenshot. Tests framing, surface contact,
## occlusion planning and camera motion at multiple render/physics rate ratios.
var failures := 0


func _initialize() -> void:
	_run.call_deferred()
	create_timer(90).timeout.connect(func():
		printerr("FAIL: camera checks timed out")
		quit(1)
	)


func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		if failures < 12: printerr("FAIL: " + message)


func _run() -> void:
	root.size = Vector2i(1440, 900)
	_check_address_alignment()
	_check_camera_independence()
	_check_transparency()
	var packed := load("res://scenes/driving_range.tscn") as PackedScene
	var scene := packed.instantiate()
	root.add_child(scene)
	check(not scene.world.environment.glow_enabled and not scene.world.environment.ssao_enabled,
		"Playing view has no flashing bloom or noisy screen-space occlusion")
	scene.set_physics_process(false)
	scene.camera.set_process(false)
	scene.camera.reduced_motion = false
	scene.visual.set_process(false)
	for sample in [{"speed":42.0,"direction":3.0,"elevation":30.0,"fps":30},
		{"speed":42.0,"direction":3.0,"elevation":30.0,"fps":120},
		{"speed":48.0,"direction":25.0,"elevation":25.0,"fps":60},
		{"speed":9.0,"direction":0.0,"elevation":0.0,"fps":60},
		{"speed":42.0,"direction":0.0,"elevation":30.0,"fps":60,"spin":1800.0}]:
		scene.reset_tee()
		scene.source.fire(sample.speed, sample.direction, sample.elevation, sample.get("spin", 0.0))
		var steps: int = 120 / int(sample.fps)
		var dt := 1.0 / float(sample.fps)
		var max_movement := 0.0
		var previous: Vector3 = scene.camera.global_position
		for frame in range(int(sample.fps) * 42):
			for step in range(steps): scene._physics_process(BallFlight.STEP)
			scene.visual.present(1.0, dt)
			scene.camera.update_camera(dt)
			var ball: Vector3 = scene.visual.ball.global_position
			var screen: Vector2 = scene.camera.unproject_position(ball) / Vector2(root.size)
			check(not scene.camera.is_position_behind(ball), "Follow camera never looks away from the ball")
			check(Rect2(.12, .12, .60, .65).has_point(screen), "Ball stays clear of the settings panel and bottom HUD")
			var bottom: float = ball.y - scene.visual.rendered_radius
			check(bottom + .0001 >= scene.world.surface.world_height(ball), "Rendered ball never sinks below the turf")
			max_movement = maxf(max_movement, previous.distance_to(scene.camera.global_position))
			previous = scene.camera.global_position
			if not scene.active:
				for settle in range(int(sample.fps) * 2):
					scene.visual.present(1.0, dt)
					scene.camera.update_camera(dt)
				break
		check(scene.model.finished, "Follow sequence includes a complete landing and rollout")
		check(max_movement < float(sample.speed) / sample.fps * 2.0 + 1.0,
			"Camera movement stays bounded throughout flight and rollout")
		check(scene.camera.global_position.distance_to(scene.visual.ball.global_position) < 8.0,
			"Rolling camera eases into a useful close view")
		print("Camera: %d fps, %.1f° direction, %.2f m maximum frame movement" % [sample.fps, sample.direction, max_movement])
	scene.queue_free()
	await process_frame
	if failures == 0:
		print("PASS: 30/60/120 Hz framing, spinning/wide shots, object-independent camera path, smooth obstruction transparency and close rollout")
	quit(1 if failures else 0)


func _check_camera_independence() -> void:
	var clear := RangeCamera.new()
	var obstructed := RangeCamera.new()
	root.add_child(clear)
	root.add_child(obstructed)
	clear.set_process(false)
	obstructed.set_process(false)
	clear.clearance = CameraClearance.new()
	obstructed.clearance = CameraClearance.new()
	obstructed.clearance.add_box(AABB(Vector3(-20,0,-100),Vector3(40,40,200)))
	for camera in [clear, obstructed]:
		camera.begin_shot(Vector3(0,.1,0),Vector3(0,8,-30))
	for frame in range(120):
		var position := Vector3(0,5,-float(frame)*.4)
		clear.ball_position = position
		obstructed.ball_position = position
		clear.update_camera(1.0/60.0)
		obstructed.update_camera(1.0/60.0)
		check(clear.global_position.distance_to(obstructed.global_position)<.00001,
			"Adding a tree/prop cannot change the camera position")
	clear.free()
	obstructed.free()


func _check_address_alignment()->void:
	var camera:=RangeCamera.new();root.add_child(camera);camera.set_process(false)
	for direction in [Vector3.FORWARD,Vector3.RIGHT,Vector3(.5,0,-.8).normalized()]:
		var origin:=Vector3(10,.1,-40)
		camera.set_launch_anchor(origin,direction)
		var offset:=camera.global_position-origin
		check(absf(offset.dot(direction.cross(Vector3.UP)))<.0001,"Address camera is directly behind the selected aiming line")
		check(offset.dot(direction)<0,"Address camera starts behind, not in front of, the tee")
		var ball:=camera.unproject_position(origin+Vector3.UP*BallFlight.BALL_RADIUS)
		var forward:=camera.unproject_position(origin+direction*5)
		check(absf(ball.x-forward.x)<.01,"A forward shot projects along one clear vertical target line")
		camera.begin_shot(origin+Vector3.UP*BallFlight.BALL_RADIUS,direction*30)
		check(camera.view_name()=="FOLLOW BALL","Every shot uses the follow rig")
	camera.free()


func _check_transparency() -> void:
	var fader := ObstructionFader.new()
	root.add_child(fader)
	fader.set_process(false)
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = MultiMesh.new()
	instance.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	instance.multimesh.use_custom_data = true
	instance.multimesh.mesh = SphereMesh.new()
	instance.multimesh.instance_count = 2
	for index in range(2): instance.multimesh.set_instance_custom_data(index, Color(0,0,0,1))
	root.add_child(instance)
	fader.register_instance(instance,0,AABB(Vector3(-1,0,1),Vector3(2,8,2)))
	fader.register_instance(instance,1,AABB(Vector3(10,0,1),Vector3(2,8,2)))
	fader.set_view(Vector3(0,1.5,4),Vector3(0,.05,0),true)
	var previous := 1.0
	for frame in range(90):
		fader.update_fades(1.0/60.0)
		# The headless renderer does not retain GPU instance data; check the exact
		# continuous opacity state submitted to it. GPU output is visually reviewed.
		var opacity: float = fader.entries[0].opacity
		check(opacity<=previous+.00001,"Obstruction fades continuously instead of flashing")
		previous=opacity
	check(previous<.2,"Blocking tree becomes transparent")
	check(fader.entries[1].opacity==1.0,"Unobstructed objects stay opaque")
	fader.set_view(Vector3.ZERO,Vector3.ZERO,false)
	for frame in range(120): fader.update_fades(1.0/60.0)
	check(fader.entries[0].opacity>.999,"Objects smoothly restore when the view clears")
	var shared := StandardMaterial3D.new()
	var prop := MeshInstance3D.new()
	prop.mesh=BoxMesh.new()
	prop.material_override=shared
	root.add_child(prop)
	fader.register_mesh(prop,AABB(Vector3(-1,0,1),Vector3(2,8,2)))
	fader.set_view(Vector3(0,1.5,4),Vector3(0,.05,0),true)
	for frame in range(90): fader.update_fades(1.0/60.0)
	check(prop.material_override!=shared and prop.material_override.albedo_color.a<.1,
		"Props get real per-object transparency")
	check(shared.albedo_color.a==1.0,"Fading one prop cannot change a shared neighbour material or its shadow")
	prop.free()
	instance.free()
	fader.free()
