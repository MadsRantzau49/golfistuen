extends SceneTree
var failures:=0


func _initialize()->void:
	_run.call_deferred()
	create_timer(100).timeout.connect(func():printerr("FAIL: workspace checks timed out");quit(1))


func check(value:bool,message:String)->void:
	if not value:failures+=1;printerr("FAIL: "+message)


func _finish(play:Node)->void:
	for frame in range(5000):
		play._physics_process(BallFlight.STEP)
		if not play.in_motion:break


func _run()->void:
	root.size=Vector2i(1440,900)
	var workspace:Node3D=load("res://scripts/holes/hole_workspace.gd").new()
	workspace.save_root="user://workspace-check-%d"%Time.get_ticks_msec()
	root.add_child(workspace)
	await workspace.ready_for_use
	workspace.open_editor(HoleDefinition.new())
	var editor:Node=workspace.editor
	check(editor.active and workspace.editing,"Editor is integrated and active")
	check(workspace.backdrop.custom_layout,"Builder uses the alpine backdrop with an empty foreground")
	check(editor.hole.surfaces.count(HoleDefinition.Surface.ROUGH)==HoleDefinition.CELL_COUNT,"Editor starts with rough, not a prebuilt driving range")
	await process_frame
	var screen:Vector2=workspace.editor_camera.unproject_position(Vector3(-50,0,-70))
	var motion:=InputEventMouseMotion.new();motion.position=screen;motion.global_position=screen
	root.push_input(motion,true)
	var press:=InputEventMouseButton.new();press.button_index=MOUSE_BUTTON_LEFT;press.position=screen;press.global_position=screen;press.pressed=true
	root.push_input(press,true)
	var release:=InputEventMouseButton.new();release.button_index=MOUSE_BUTTON_LEFT;release.position=screen;release.global_position=screen;release.pressed=false
	root.push_input(release,true)
	check(editor.hole.surface_at(Vector2(-50,-70))==HoleDefinition.Surface.FAIRWAY,"Actual viewport mouse input paints the terrain")
	editor.hud.name_editor.text="Integration Meadow";editor._commit_metadata()
	editor.edit_once(Vector2(0,-80),"fairway",14)
	editor.undo();check(editor.hole.surface_at(Vector2(0,-80))==HoleDefinition.Surface.ROUGH,"Editor undo restores paint")
	editor.redo();check(editor.hole.surface_at(Vector2(0,-80))==HoleDefinition.Surface.FAIRWAY,"Editor redo restores paint")
	editor.edit_once(Vector2(30,-100),"raise",18,1)
	editor.edit_once(Vector2(-30,-100),"lower",18,1)
	editor.edit_once(Vector2(0,-45),"green",38)
	editor.edit_once(Vector2(12,-45),"cup",2)
	editor.edit_once(Vector2(44,-110),"tree",2)
	workspace.world.sync_now()
	check(editor.hud.play_button.disabled==false,"Valid design enables Test hole")
	var hit:Variant=workspace.world.pick_ray(Vector3(30,300,-100),Vector3.DOWN)
	check(hit!=null and absf(hit.y-editor.hole.height_at(Vector2(30,-100)))<.02,"Editor cursor picks the sculpted terrain")
	editor.save()
	var loaded:HoleDefinition=workspace.store.load_hole(editor.hole.id)
	check(loaded!=null and loaded.title=="Integration Meadow" and loaded.trees.size()==1,"Editor saves usable terrain and objects")
	loaded.rules_overrides={"green_putts":2}
	workspace.open_play(loaded)
	var play:Node3D=workspace.play
	check(not workspace.editing and play.interactive,"Play test switches to simulator controls")
	var tee:Vector2=play.attempt.lie
	play.source.fire(8,0,8,0)
	_finish(play)
	check(play.attempt.strokes==1 and play.attempt.state==HoleRound.State.READY,"A rough lie requires another real shot")
	play._process(2)
	check(play.attempt.lie!=tee and Vector2(play.origin.x,play.origin.z).distance_to(play.attempt.lie)<.001,"Next shot starts from the actual previous lie")
	play.replay();_finish(play);play._process(2)
	check(play.attempt.strokes==1,"Replay cannot add strokes or penalties")
	play.source.fire(26,0,48,0)
	_finish(play)
	check(play.attempt.state==HoleRound.State.COMPLETE,"A built green is playable and completes the hole without putting")
	check(play.attempt.gross_score()==play.attempt.strokes+play.attempt.penalties+play.attempt.awarded_putts,"Score components agree")
	check(is_instance_valid(play.completion),"Completed hole displays its score card")
	# Execute an actual water contact, not just a scoring-method stub.
	var water_hole:=HoleDefinition.demo();water_hole.apply_brush(Vector2(0,10),6,"water")
	workspace.open_play(water_hole)
	play.source.fire(10,0,0,0);_finish(play)
	check(play.attempt.penalties==1 and play.attempt.lie==water_hole.tee,"Water contact executes a stroke-and-distance penalty")
	workspace.open_editor(editor.hole)
	check(workspace.editor.active and not play.interactive,"Editor can be reopened after play")
	var directory:String=workspace.save_root
	workspace.queue_free()
	await process_frame
	var dir:=DirAccess.open(directory)
	if dir:
		for filename in dir.get_files():DirAccess.remove_absolute(directory.path_join(filename))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(directory))
	if failures==0:print("PASS: integrated editor, sculpted picking, undo/redo, native save/load, multi-shot lies, replay isolation, green completion, score card and water penalties")
	quit(1 if failures else 0)
