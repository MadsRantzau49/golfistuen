extends SceneTree
var failures:=0


func _initialize()->void:
	_run.call_deferred();create_timer(120).timeout.connect(func():printerr("FAIL: local golf integration timed out");quit(1))


func check(value:bool,message:String)->void:
	if not value:failures+=1;printerr("FAIL: "+message)


func _settle(controller:Node3D)->void:
	controller._process(.44)
	for frame in range(5000):
		controller._physics_process(BallFlight.STEP)
		if not controller.in_motion:break
	controller._process(1.1)


func _run()->void:
	root.get_node("GameSettings").set_value("shot_mode","Debug",false)
	var packed:=load("res://scenes/application.tscn") as PackedScene
	var app:Node=packed.instantiate();var directory:="user://match-app-%d"%Time.get_ticks_msec()
	app.workspace_save_root=directory.path_join("holes");root.add_child(app)
	app.clubhouse=ClubhouseStore.new(directory.path_join("clubhouse"))
	while app.state==app.State.LOADING:await process_frame
	app.menu.match_requested.emit()
	check(app.state==app.State.MATCH_SETUP and app.match_setup!=null,"Menu opens player/course setup")
	while app.match_setup.players.size()<6:app.match_setup._add_player()
	app.match_setup._add_player()
	check(app.match_setup.players.size()==6 and app.match_setup._add.disabled,"Player setup enforces the six-player limit")
	app.match_setup._advance();check(app.match_setup.step==1,"Player names/colours persist before course selection")
	app.match_setup._count.value=2;await app.match_setup._generate()
	check(app.match_setup.course.holes.size()==2 and app.match_setup.course.holes.all(func(hole:HoleDefinition)->bool:return hole.play_errors().is_empty()),"Setup generates the selected playable hole count")
	app.match_setup._save_course();check(app.clubhouse.list_courses().size()==1,"Favourite course saves through the setup UI")
	var course:=GolfCourse.new();course.holes.assign([HoleDefinition.demo(),HoleDefinition.demo()])
	var competition:=LocalGolfMatch.new(app.match_setup.players,course)
	await app.start_match(competition)
	var controller:Node3D=app.workspace.competition
	check(app.state==app.State.PLAYING and app.workspace.match_active and not app.workspace.play.interactive,"Competition owns the active workspace")
	check(controller.scoreboard._cards.size()==6 and controller.golfer.player==competition.current_player(),"Six-score HUD and current player's character are bound")
	await process_frame
	var guide:Control=controller.course_map
	check(guide.visible and guide.document==competition.current_hole() and guide.lie==competition.current_round().lie,"Course guide uses the active player's actual layout and lie")
	var green_edges:Vector2=guide.green_distances(guide.lie)
	check(green_edges.x<guide.lie.distance_to(competition.current_hole().cup) and green_edges.y>guide.lie.distance_to(competition.current_hole().cup),"Green front/back distances bracket the pin")
	var waypoint:Vector2=guide.lie.lerp(competition.current_hole().cup,.5)
	check(guide.to_world(guide.to_map(waypoint)).distance_to(waypoint)<.001,"Map measurement preserves world distances despite aspect-fit scaling")
	var click:=InputEventMouseButton.new();click.button_index=MOUSE_BUTTON_LEFT;click.pressed=true
	click.position=guide._canvas.get_global_transform_with_canvas()*guide.to_map(waypoint);click.global_position=click.position
	root.push_input(click,true)
	click.pressed=false;root.push_input(click,true)
	check(guide.measured_point!=null and guide.measured_point.distance_to(waypoint)<.01 and competition.current_round().strokes==0,"Actual map clicks pin a lay-up measurement without taking a shot")
	var preferences:Node=root.get_node("GameSettings");var old_units:Variant=preferences.get_value("units")
	preferences.set_value("units","Yards",false)
	check(guide._distance.text.begins_with("%.0f yd"%preferences.distance(guide.ball.distance_to(competition.current_hole().cup))) and guide._measure.text.contains("yd"),"Pin and lay-up measurements use the selected yards preference")
	preferences.set_value("units",old_units,false)
	controller.source.fire(30,0,20,0)
	check(controller._windup!=null and competition.current_round().strokes==1,"Swing reserves exactly one competitive stroke before contact")
	check(not controller.receive_shot({"speed":40}),"A second backend submission is rejected while the swing is busy")
	var saved:Dictionary=app.clubhouse.load_active()
	check(not saved.is_empty() and saved.match.current_round().state==HoleRound.State.IN_FLIGHT,"Shot-start accounting and payload are durable before contact")
	await app.start_match(saved.match,saved.pending)
	competition=controller.match_state
	check(controller.in_motion and competition.current_round().strokes==1,"Cold resume re-simulates the pending shot without counting it again")
	app.pause_game();var elapsed:float=controller.model.elapsed;controller._physics_process(.5)
	check(controller.model.elapsed==elapsed,"Application pause freezes a competitive flight")
	app._resume_active();controller._show_completion();controller._physics_process(.5)
	check(controller.model.elapsed==elapsed,"Opening scorecard freezes the live flight")
	controller._close_modal()
	for frame in range(120):controller._physics_process(BallFlight.STEP);controller._process(BallFlight.STEP)
	var flight_point:Vector3=controller.origin+controller.model.position
	check(guide.live and guide.ball.distance_to(Vector2(flight_point.x,flight_point.z))<.01 and guide.trail.size()>1,"Live course guide follows the actual in-flight ball and records its path")
	_settle(controller)
	check(competition.active_index==1 and competition.attempts[0].strokes==1 and competition.attempts[1].strokes==0,"Settled flight hands off to the next initial tee player")
	check(guide.lie==competition.current_round().lie and guide.other_balls.size()==1 and guide.measured_point==null,"Player handoff refreshes map lie/other balls and clears the previous measurement")
	for index in range(1,6):controller.source.fire(0,0,0,0);_settle(controller)
	check(competition.attempts.all(func(attempt:HoleRound)->bool:return attempt.strokes==1),"All six players retain independent first strokes")
	var active:int=competition.active_index;var strokes:int=competition.current_round().strokes
	controller.replay();_settle(controller)
	check(competition.active_index==active and competition.current_round().strokes==strokes,"Replay cannot alter competitive score or turn order")
	controller._open_relief()
	check(controller.completion!=null and controller.completion._confirm.disabled==false,"Relief dialog offers the prior stroke position")
	var previous:=competition.current_round().previous_stroke_lie
	controller.completion.apply_requested.emit("stroke_distance",previous)
	check(competition.active_index==active and competition.current_round().penalties==1 and competition.current_round().lie==previous,"Confirmed relief applies one penalty and retains the player's turn")
	controller.restart();check(competition.current_round().state==HoleRound.State.READY,"Give-up opens confirmation before altering score")
	controller._close_modal()
	for index in range(6):
		controller.restart()
		var buttons:Array=controller.completion.find_children("*","Button",true,false)
		buttons[0].pressed.emit()
	controller._save()
	check(competition.state==LocalGolfMatch.State.HOLE_COMPLETE and controller.completion!=null,"Every pickup completes the hole and presents the scorecard")
	controller.completion.next_requested.emit()
	check(competition.hole_index==1 and controller.hole==competition.course.holes[1],"Next hole updates the rendered layout and match state")
	check(competition.attempts.all(func(attempt:HoleRound)->bool:return attempt.strokes==0),"Next hole resets individual lies/strokes while preserving the scorecard")
	for index in range(6):competition.give_up()
	controller._after_action();controller._save()
	check(competition.state==LocalGolfMatch.State.COMPLETE and competition.leaders().size()==6,"Equal completed totals share the win")
	check(not app.clubhouse.has_active() and FileAccess.file_exists(app.clubhouse.directory.path_join("last_round.json")),"Finished rounds archive the scorecard and clear resume")
	await app.open_builder()
	check(app.workspace.world.hole==app.workspace.editor.hole and not controller.interactive,"Returning to builder restores its own document and deactivates competition")
	app.show_menu();app.queue_free();await process_frame
	_cleanup(directory)
	if failures==0:print("PASS: six-player setup, courses, yardage map/measurement/units, swing contact, disk resume, pause/scorecard, tee handoff, replay, relief, pickup, hole transitions and shared results")
	quit(1 if failures else 0)


func _cleanup(path:String)->void:
	var directory:=DirAccess.open(path)
	if directory==null:return
	for child in directory.get_directories():_cleanup(path.path_join(child))
	for file in directory.get_files():DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
