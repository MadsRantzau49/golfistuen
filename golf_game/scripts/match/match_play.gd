class_name MatchPlay
extends HolePlay
## Rendering/shot adapter. LocalGolfMatch alone owns competitive turn and score state.
signal menu_requested
signal setup_requested
var match_state:LocalGolfMatch
var clubhouse:ClubhouseStore
var scoreboard:ScoreboardBar
var golfer:GolferCharacter
var other_balls:Array[MeshInstance3D]=[]
var _windup:GolfShot
var _swing_remaining:=0.0
var _replays:Dictionary={}
var _pending:Dictionary={}


func _ready()->void:
	competitive=true;super._ready()
	hud.reset_button.text="Give up hole…";hud.reset_button.tooltip_text="Pick up at the announced maximum, or record a DNF in ordinary stroke play."
	hud.relief_requested.connect(_open_relief)
	golfer=GolferCharacter.new();add_child(golfer)
	scoreboard=ScoreboardBar.new();hud.root.add_child(scoreboard)
	scoreboard.anchor_right=1;scoreboard.offset_left=24;scoreboard.offset_right=-24;scoreboard.offset_top=22;scoreboard.offset_bottom=134
	scoreboard.scorecard_requested.connect(_show_completion)
	var score_panel:Control=score_label.get_parent().get_parent()
	score_panel.anchor_right=0;score_panel.offset_left=36;score_panel.offset_right=730;score_panel.offset_top=151;score_panel.offset_bottom=211
	var aim_panel:Control=aim_slider.get_parent().get_parent()
	aim_panel.offset_top=238;aim_panel.offset_bottom=303
	aim_slider.custom_minimum_size.x=200
	var score_button:=AppStyle.button("Scorecard");score_button.pressed.connect(_show_completion);aim_slider.get_parent().add_child(score_button)


func start_match(competition:LocalGolfMatch,saved:Dictionary={})->void:
	_close_modal();match_state=competition;_replays=saved.get("replays",{}).duplicate(true);_pending=saved.get("active_shot",{}).duplicate(true)
	in_motion=false;_windup=null;turn_delay=0;last_shot=null;replaying=false
	_load_hole()
	if match_state.state!=LocalGolfMatch.State.PLAYING:_show_completion();return
	if attempt.state==HoleRound.State.IN_FLIGHT:
		if _pending.is_empty():
			# A missing transport payload must never produce a duplicate counted shot.
			hud.show_message("Saved shot payload is missing; this stroke is replayed from its original lie.")
			attempt.strokes-=1;attempt.state=HoleRound.State.READY;_save()
		else:
			var shot:=GolfShot.from_payload(_pending.shot)
			var point:Array=_pending.origin
			_launch(shot,Vector3(point[0],point[1],point[2]),float(_pending.yaw),false)
			return
	_save()


func _load_hole()->void:
	hole=match_state.current_hole();world.set_document(hole);world.sync_now();world.set_editing(false)
	course_map.configure_hole(hole)
	visual.surface=world.surface;camera.clearance.surface_height=world.surface.world_height;camera.menu_mode=false
	hud.history.clear();hud.shot_count=0;hud._update_history();hud.reset_metrics()
	scoreboard.bind_match(match_state,clubhouse)
	for ball in other_balls:ball.queue_free()
	other_balls.clear()
	for player in match_state.players:
		var ball:=MeshInstance3D.new();var mesh:=SphereMesh.new();mesh.radius=.065;mesh.height=.13;mesh.radial_segments=12;mesh.rings=6
		ball.mesh=mesh;ball.material_override=RangePalette.material(player.color());add_child(ball);other_balls.append(ball)
	_sync_turn();apply_preferences()


func _sync_turn()->void:
	attempt=match_state.current_round()
	var player:=match_state.current_player()
	golfer.apply_player(player,clubhouse.portrait(player))
	course_map.player_color=player.color();course_map.other_balls.clear()
	for index in range(match_state.players.size()):
		if index!=match_state.active_index and match_state.attempts[index].strokes>0 and match_state.attempts[index].state!=HoleRound.State.COMPLETE:
			course_map.other_balls.append({"point":match_state.attempts[index].lie,"color":match_state.players[index].color(),"number":index+1})
	last_shot=null
	if _replays.has(player.id):
		var data:Dictionary=_replays[player.id]
		last_shot=GolfShot.from_payload(data.shot);last_origin=Vector3(data.origin[0],data.origin[1],data.origin[2]);last_yaw=float(data.yaw)
	_place_lie()
	for index in range(other_balls.size()):
		var point:=match_state.attempts[index].lie
		other_balls[index].position=Vector3(point.x,world.surface.world_height(Vector3(point.x,0,point.y))+.07,point.y)
		other_balls[index].visible=index!=match_state.active_index and match_state.attempts[index].state!=HoleRound.State.COMPLETE and match_state.attempts[index].strokes>0
	if match_state.state==LocalGolfMatch.State.PLAYING:hud.show_message("%s · your shot"%player.name)


func _update_aim(snap:=false)->void:
	super._update_aim(snap)
	if golfer:
		var heading:=Vector3(sin(deg_to_rad(aim_yaw)),0,-cos(deg_to_rad(aim_yaw)))
		golfer.position=origin-heading.cross(Vector3.UP)*.73
		golfer.position.y=world.surface.world_height(golfer.position)
		golfer.rotation.y=-deg_to_rad(aim_yaw)


func _on_shot(shot:GolfShot)->void:
	if not _can_act() or not match_state.begin_shot(shot):return
	last_shot=shot;last_origin=origin;last_yaw=aim_yaw
	_pending={"shot":shot.to_payload(),"origin":[origin.x,origin.y,origin.z],"yaw":aim_yaw}
	_replays[match_state.current_player().id]=_pending.duplicate(true)
	_save()
	if GameSettings.get_value("shot_mode")=="Real":
		golfer.swing();_launch(shot,origin,aim_yaw,false)
	else:_start_swing(shot,false)


func _start_swing(shot:GolfShot,is_replay:bool)->void:
	replaying=is_replay;in_motion=true;_windup=shot;_swing_remaining=.43
	golfer.swing();hud.set_busy(true);aim_slider.editable=false;preview_mesh.visible=false;aim_mesh.visible=false;_refresh_score()


func replay()->void:
	if not _can_act() or last_shot==null:return
	origin=last_origin;aim_yaw=last_yaw;_update_aim(true);_start_swing(last_shot,true)


func _can_act()->bool:
	return interactive and match_state!=null and match_state.state==LocalGolfMatch.State.PLAYING and not in_motion and turn_delay<=0 and not is_instance_valid(completion) and attempt.state==HoleRound.State.READY


func is_live_ready()->bool:
	return _can_act()


func receive_shot(payload:Dictionary)->bool:
	return source.submit_payload(payload) if _can_act() else false


func _physics_process(delta:float)->void:
	if _windup!=null or is_instance_valid(completion):return
	super._physics_process(delta)


func _process(delta:float)->void:
	if not interactive or is_instance_valid(completion):return
	if _windup!=null:
		_swing_remaining-=delta
		if _swing_remaining<=0:
			var shot:=_windup;_windup=null;_launch(shot,origin,aim_yaw,replaying)
		return
	if in_motion:_refresh_score()
	if turn_delay>0:
		turn_delay-=delta
		if turn_delay<=0:_sync_turn()


func _finish_shot()->void:
	in_motion=false;visual.freeze_interpolation();hud.record_result(model,replaying)
	if not replaying:
		var point:=origin+model.position
		match_state.resolve_shot(Vector2(point.x,point.z));_pending.clear();_save()
		hud.show_message(attempt.last_outcome)
		if match_state.state!=LocalGolfMatch.State.PLAYING:_show_completion()
		else:turn_delay=1.0
	else:turn_delay=.6
	_refresh_score()


func _refresh_score()->void:
	if match_state==null or attempt==null:return
	if scoreboard:scoreboard.refresh()
	score_label.text="%s · Hole %d/%d · Par %d"%[hole.title,match_state.hole_index+1,match_state.course.holes.size(),hole.par]
	var point:=attempt.lie
	if in_motion and _windup==null and model:
		var current:=origin+model.position;point=Vector2(current.x,current.z)
	var cap:=int(attempt.rules.options.max_strokes)
	course_map.set_ball(point,in_motion)
	detail_label.text="%s · Stroke %d · %.0f %s to cup · %s"%[match_state.current_player().name,attempt.strokes+(1 if attempt.state==HoleRound.State.READY else 0),GameSettings.distance(point.distance_to(hole.cup)),GameSettings.distance_suffix(),"Maximum %d"%cap if cap>0 else "Gross stroke play"]
	var busy:=in_motion or turn_delay>0 or match_state.state!=LocalGolfMatch.State.PLAYING or is_instance_valid(completion)
	hud.set_busy(busy);hud.reset_button.disabled=busy;hud.replay_button.disabled=busy or last_shot==null
	if not busy:hud.launch_button.text="Play shot    ↗";hud.status_label.text="●  %s to play"%match_state.current_player().name
	elif is_instance_valid(completion):hud.launch_button.text="Continue when ready";hud.status_label.text="●  Scorecard / options"
	elif _windup!=null:hud.launch_button.text="Taking the swing…";hud.status_label.text="●  Swinging"
	elif turn_delay>0:
		hud.status_label.text="●  Next player"
		detail_label.text="%s · %s is up next"%[attempt.last_outcome,match_state.current_player().name]


func restart()->void:
	if not _can_act():return
	completion=Control.new();hud.root.add_child(completion);AppStyle.full_rect(completion);AppStyle.shade(completion,.7).offset_top=140
	var center:=CenterContainer.new();completion.add_child(center);AppStyle.full_rect(center)
	center.offset_top=140;center.offset_bottom=-14
	var panel:=PanelContainer.new();panel.custom_minimum_size.x=520;panel.add_theme_stylebox_override("panel",AppStyle.box());center.add_child(panel)
	var column:=VBoxContainer.new();column.add_theme_constant_override("separation",16);panel.add_child(column)
	column.add_child(AppStyle.label("%s · PICK UP"%match_state.current_player().name.to_upper(),11,AppStyle.GOLD))
	column.add_child(AppStyle.label("Call it a hole?",35,AppStyle.CREAM,true))
	var maximum:bool=match_state.config.format=="maximum_score"
	column.add_child(AppStyle.label("Record the announced maximum of %d strokes."%attempt.rules.options.max_strokes if maximum else "Record DNF. This round will be unclassified.",16))
	var confirm:=AppStyle.button("Pick up · %d strokes"%attempt.rules.options.max_strokes if maximum else "Record DNF",true)
	confirm.pressed.connect(func():
		_close_modal()
		if match_state.give_up():_save();_after_action()
	);column.add_child(confirm)
	var cancel:=AppStyle.button("Keep playing");cancel.pressed.connect(_close_modal);column.add_child(cancel);cancel.grab_focus()
	_refresh_score()


func _open_relief()->void:
	if not _can_act():return
	var dialog:=ReliefDialog.new();dialog.match_state=match_state;completion=dialog;hud.root.add_child(dialog)
	dialog.closed.connect(_close_modal)
	dialog.apply_requested.connect(func(mode:String,point:Vector2):
		var result:=match_state.relief(mode,point)
		if result.ok:_close_modal();_save();_after_action()
		else:hud.show_message(result.error)
	);_refresh_score()


func _after_action()->void:
	if match_state.state==LocalGolfMatch.State.PLAYING:_sync_turn()
	else:_show_completion()


func _show_completion()->void:
	if match_state==null:return
	_close_modal();visual.freeze_interpolation()
	golfer.process_mode=Node.PROCESS_MODE_DISABLED
	var card:=MatchScorecard.new();card.match_state=match_state;completion=card;hud.root.add_child(card)
	card.resume_requested.connect(_close_modal)
	card.next_requested.connect(func():
		_close_modal()
		if match_state.advance_hole():_replays.clear();_load_hole();_save()
	)
	card.again_requested.connect(func():start_match(LocalGolfMatch.new(match_state.players,match_state.course,match_state.config)))
	card.setup_requested.connect(func():setup_requested.emit())
	card.menu_requested.connect(func():menu_requested.emit())
	_refresh_score()


func _close_modal()->void:
	if is_instance_valid(completion):completion.hide();completion.queue_free()
	completion=null
	if golfer:golfer.process_mode=Node.PROCESS_MODE_INHERIT
	if hud:_refresh_score()


func _save()->void:
	if match_state==null:return
	if not clubhouse.save_active(match_state,{"active_shot":_pending,"replays":_replays}):hud.show_message(clubhouse.last_error)
	elif match_state.state==LocalGolfMatch.State.COMPLETE and not clubhouse.finish(match_state):hud.show_message("The finished scorecard could not be saved.")


func _input(event:InputEvent)->void:
	if not interactive:return
	if is_instance_valid(completion):
		if event is InputEventKey and event.pressed and event.physical_keycode==KEY_ESCAPE:
			if match_state.state==LocalGolfMatch.State.PLAYING:_close_modal()
			else:pause_requested.emit()
			get_viewport().set_input_as_handled()
		return
	super._input(event)
