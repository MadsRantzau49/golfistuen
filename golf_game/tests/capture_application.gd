extends SceneTree
## Visual review of the actual player entry point, not a separate mock UI.


func _initialize()->void:
	_run.call_deferred()
	create_timer(60).timeout.connect(func():quit(1))


func _run()->void:
	var args:=OS.get_cmdline_user_args()
	var packed:=load("res://scenes/application.tscn") as PackedScene
	var app:=packed.instantiate()
	root.add_child(app)
	while app.state==app.State.LOADING:
		await process_frame
	if args.has("--settings"):app.open_settings(1 if args.has("--rules") else 0)
	if args.has("--play"):app.enter_range()
	await create_timer(3).timeout
	await RenderingServer.frame_post_draw
	var path:=args[0] if not args.is_empty() else "user://application.png"
	var result:=root.get_texture().get_image().save_png(path)
	print("Application screenshot: ",path)
	print("Visual review: ",Engine.get_frames_per_second()," fps; ",Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)," draw calls")
	await app.quit_application(result)
