extends SceneTree
## Visual review helper. Requires a graphical display, not --headless.


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var scene := load("res://scenes/driving_range.tscn") as PackedScene
	var range_scene := scene.instantiate()
	root.add_child(range_scene)
	await create_timer(2.0).timeout
	if args.has("--flight"):
		range_scene.source.fire(58, 0, 19)
		for frame in range(260):
			range_scene._physics_process(BallFlight.STEP)
		range_scene.active = false
	if args.has("--result"):
		range_scene.source.fire(42, -2, 30)
		for frame in range(4800):
			range_scene._physics_process(BallFlight.STEP)
			if not range_scene.active:
				break
	if args.has("--history"):
		for preset_name in DemoShotSource.PRESETS:
			var preset: Dictionary = DemoShotSource.PRESETS[preset_name]
			range_scene.source.fire(preset.speed_mps, preset.direction_deg, preset.elevation_deg)
			for frame in range(4800):
				range_scene._physics_process(BallFlight.STEP)
				if not range_scene.active:
					break
	if args.has("--preview"):
		range_scene._set_preview(true)
	await create_timer(0.5).timeout
	await RenderingServer.frame_post_draw
	var path := args[0] if not args.is_empty() else "user://range.png"
	var error := root.get_texture().get_image().save_png(path)
	print("Screenshot: ", path, " (", error, ")")
	quit(error)
