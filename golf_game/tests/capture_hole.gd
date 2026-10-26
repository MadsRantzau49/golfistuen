extends SceneTree
## Review the integrated editor, custom-hole play and no-putting result UI.
func _initialize()->void:
	_run.call_deferred()
	create_timer(90).timeout.connect(func():quit(1))


func _run()->void:
	var args:=OS.get_cmdline_user_args()
	var workspace:Node3D=load("res://scripts/holes/hole_workspace.gd").new()
	workspace.save_root="user://qa-hole-visuals";root.add_child(workspace)
	await workspace.ready_for_use
	var document:=HoleDefinition.new() if args.has("--blank") else HoleDefinition.demo()
	if args.has("--result"):
		document=HoleDefinition.new();document.title="Meadow Practice";document.rules_overrides={"green_putts":2}
		document.apply_brush(Vector2(0,-45),38,"green");document.place_cup(Vector2(12,-45))
	if args.has("--play") or args.has("--result"):
		workspace.open_play(document)
		if args.has("--result"):
			workspace.play.source.fire(26,0,48,0)
			for frame in range(5000):
				workspace.play._physics_process(BallFlight.STEP)
				if not workspace.play.in_motion:break
	else:
		workspace.open_editor(document)
		if args.has("--3d"):workspace.editor_camera.tilted=true;workspace.editor_camera.update_pose()
	await create_timer(2.5).timeout
	await RenderingServer.frame_post_draw
	var path:=args[0] if not args.is_empty() else "user://hole.png"
	var error:=root.get_texture().get_image().save_png(path)
	print("Hole screenshot: ",path)
	await root.get_node("AudioDirector").shutdown()
	quit(error)
