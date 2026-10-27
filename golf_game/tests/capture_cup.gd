extends SceneTree
## Close gameplay view of the real opening and the ball dropping into it.
func _initialize()->void:
	_run.call_deferred()
	create_timer(90).timeout.connect(func():quit(1))


func _run()->void:
	var args:=OS.get_cmdline_user_args()
	var workspace:Node3D=load("res://scripts/holes/hole_workspace.gd").new()
	workspace.save_root="user://qa-cup-visuals";root.add_child(workspace)
	await workspace.ready_for_use
	var hole:=HoleDefinition.new();hole.title="Cup capture review"
	hole.apply_brush(Vector2(0,-20),20,"green");hole.place_cup(Vector2(0,-20));hole.set_cup_diameter(1.0)
	workspace.open_play(hole)
	var play:Node3D=workspace.play
	play.set_physics_process(false);play.camera.set_process(false);play.visual.set_process(false)
	play.attempt.lie=Vector2(0,-18.5);play.attempt.last_safe_lie=play.attempt.lie;play._place_lie()
	play.source.fire(5,0,0,0)
	for frame in range(1000):
		play._physics_process(BallFlight.STEP)
		play.visual.present(1.0,BallFlight.STEP);play.camera.update_camera(BallFlight.STEP)
		play.visual.trail.render_pending_frame(BallFlight.STEP)
		if play.simulator.sinking and play.simulator._sink_elapsed>.15:break
	for frame in range(180):
		play.visual.present(1.0,1.0/60.0);play.camera.update_camera(1.0/60.0)
		play.visual.trail.render_pending_frame(1.0/60.0)
	await create_timer(1.5).timeout
	await RenderingServer.frame_post_draw
	var path:=args[0] if not args.is_empty() else "user://cup.png"
	var error:=root.get_texture().get_image().save_png(path)
	print("Cup screenshot: ",path)
	await root.get_node("AudioDirector").shutdown()
	quit(error)
