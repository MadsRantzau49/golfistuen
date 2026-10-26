extends SceneTree
## Deterministic visual review of a real follow sequence. Pass --rolling, --wide,
## --tee-close, or --flight; otherwise captures the final resting-ball view.


func _initialize() -> void:
	_run.call_deferred()
	create_timer(60).timeout.connect(func(): quit(1))


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var packed := load("res://scenes/driving_range.tscn") as PackedScene
	var scene := packed.instantiate()
	root.add_child(scene)
	scene.set_physics_process(false)
	scene.camera.set_process(false)
	scene.visual.set_process(false)
	scene.cycle_camera()
	scene.hud.select_preset("7 Iron")
	var spin := -1800.0 if args.has("--spin-left") else (1800.0 if args.has("--spin-right") else 0.0)
	var direction := 25.0 if args.has("--wide") else 0.0
	scene.hud.direction_slider.value = direction
	scene.hud.spin_slider.value = spin
	if not args.has("--tee-close"):
		scene.source.fire(42.0, direction, 30.0, spin)
		for frame in range(2400):
			for step in range(2): scene._physics_process(BallFlight.STEP)
			scene.visual.present(1.0, 1.0 / 60.0)
			scene.camera.update_camera(1.0 / 60.0)
			scene.visual.trail.render_pending_frame(1.0 / 60.0)
			if args.has("--flight") and frame >= 125: break
			if args.has("--rolling") and scene.model.phase == "ROLLING" and scene.model.velocity.length() < 6: break
			if not scene.active: break
	for frame in range(100):
		scene.visual.present(1.0, 1.0 / 60.0)
		scene.camera.update_camera(1.0 / 60.0)
		scene.visual.trail.render_pending_frame(1.0 / 60.0)
	scene.world.close_turf._process(0)
	await create_timer(1.5).timeout
	await RenderingServer.frame_post_draw
	var path := args[0] if not args.is_empty() else "user://follow.png"
	var result := root.get_texture().get_image().save_png(path)
	print("Follow screenshot: ", path)
	print("Ball foot: ", scene.visual.ball.global_position.y - scene.visual.rendered_radius,
		" / surface: ", scene.world.surface.world_height(scene.visual.ball.global_position))
	await root.get_node("AudioDirector").shutdown()
	quit(result)
