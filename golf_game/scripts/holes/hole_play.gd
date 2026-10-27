class_name HolePlay
extends Node3D
## Simulator gameplay adapter. Domain scoring never depends on UI or renderer.
signal pause_requested
signal settings_requested
signal edit_requested
signal library_requested

var world:HoleWorld
var backdrop:AlpineRange
var store:HoleStore
var hole:HoleDefinition
var attempt:HoleRound
var simulator:HoleShotSimulator
var model:BallFlight
var source:DemoShotSource
var visual:ShotVisual
var camera:RangeCamera
var hud:RangeHUD
var interactive:=false
var in_motion:=false
var replaying:=false
var turn_delay:=0.0
var origin:=Vector3.ZERO
var aim_yaw:=0.0
var last_shot:GolfShot
var last_origin:=Vector3.ZERO
var last_yaw:=0.0
var preview_visible:=false
var preview_mesh:MeshInstance3D
var aim_mesh:MeshInstance3D
var score_label:Label
var detail_label:Label
var aim_slider:HSlider
var aim_value:Label
var completion:Control
var competitive:=false
var course_map:ShotCourseMap


func _ready()->void:
	source=DemoShotSource.new();add_child(source);source.shot_received.connect(_on_shot)
	source.input_rejected.connect(func(message:String):hud.show_message(message))
	visual=ShotVisual.new();visual.surface=world.surface;add_child(visual)
	visual.contact_updated.connect(world.update_contact)
	camera=RangeCamera.new();add_child(camera);camera.ball_subject=visual.ball
	camera.clearance=CameraClearance.new();camera.clearance.surface_height=world.surface.world_height
	camera.framing_updated.connect(world.update_visibility);camera.framing_updated.connect(backdrop.update_camera_visibility)
	hud=RangeHUD.new();hud.context_label="CUSTOM HOLE";hud.match_mode=competitive;add_child(hud)
	hud.launch_requested.connect(source.fire)
	hud.menu_requested.connect(func():pause_requested.emit());hud.settings_requested.connect(func():settings_requested.emit())
	hud.reset_requested.connect(restart)
	hud.reset_button.text="Restart hole"
	hud.reset_button.tooltip_text="Start a fresh attempt from the tee."
	hud.replay_requested.connect(replay)
	hud.preview_changed.connect(func(value:bool):preview_visible=value;_refresh_preview())
	for slider in [hud.speed_slider,hud.direction_slider,hud.elevation_slider,hud.spin_slider]:
		slider.value_changed.connect(func(_value:float):_refresh_preview())
	_build_score_ui()
	course_map=ShotCourseMap.new();course_map.position=Vector2(36,336 if competitive else 230);hud.root.add_child(course_map)
	hud.toast_label.offset_top=-157
	preview_mesh=MeshInstance3D.new();preview_mesh.material_override=RangePalette.material(Color("e3dab2"),true);add_child(preview_mesh)
	aim_mesh=MeshInstance3D.new();aim_mesh.material_override=RangePalette.material(AppStyle.GOLD,true);add_child(aim_mesh)
	hud.visible=false


func start_hole(document:HoleDefinition)->void:
	hole=document;in_motion=false;turn_delay=0;last_shot=null;replaying=false
	course_map.configure_hole(hole)
	visual.surface=world.surface;camera.clearance.surface_height=world.surface.world_height
	attempt=HoleRound.new(hole,HoleRules.create(GameSettings.values,hole.rules_overrides))
	if is_instance_valid(completion):completion.queue_free();completion=null
	hud.history.clear();hud.shot_count=0;hud._update_history();hud.reset_metrics()
	camera.menu_mode=false
	_place_lie()
	apply_preferences()


func restart()->void:
	if hole:start_hole(hole)


func set_active(value:bool)->void:
	interactive=value
	process_mode=Node.PROCESS_MODE_INHERIT if value else Node.PROCESS_MODE_DISABLED
	hud.visible=value;visual.locator.visible=value
	if value:camera.current=true
	else:visual.freeze_interpolation()


func apply_preferences()->void:
	camera.reduced_motion=bool(GameSettings.get_value("reduced_motion"))
	visual.show_trail=bool(GameSettings.get_value("show_trail"))
	if not visual.show_trail:visual.trail.visible=false
	hud.refresh_units();_refresh_score()
	if course_map:course_map.refresh_units()


func receive_shot(payload:Dictionary)->bool:
	return source.submit_payload(payload)


func _on_shot(shot:GolfShot)->void:
	if not interactive or in_motion or turn_delay>0 or attempt==null:return
	if not attempt.begin_shot(shot.shot_id):return
	last_shot=shot;last_origin=origin;last_yaw=aim_yaw
	_launch(shot,origin,aim_yaw,false)


func _launch(shot:GolfShot,launch_origin:Vector3,yaw:float,is_replay:bool)->void:
	origin=launch_origin;replaying=is_replay
	simulator=HoleShotSimulator.new(shot,world.surface,origin,-deg_to_rad(yaw));model=simulator.model
	var aim:=Vector3(sin(deg_to_rad(yaw)),0,-cos(deg_to_rad(yaw)))
	camera.set_launch_anchor(origin,aim,is_replay)
	visual.position=origin;visual.reset();visual.tracking_enabled=true
	in_motion=true
	camera.begin_shot(origin+model.position,model.velocity)
	hud.set_busy(true);aim_slider.editable=false;aim_mesh.visible=false;preview_mesh.visible=false
	AudioDirector.play_strike();_refresh_score()
	course_map.begin_shot(Vector2(origin.x,origin.z),yaw)


func replay()->void:
	if last_shot==null or in_motion or turn_delay>0 or attempt.state==HoleRound.State.COMPLETE:return
	_launch(last_shot,last_origin,last_yaw,true)


func _physics_process(delta:float)->void:
	if not interactive or not in_motion:return
	var landed:=model.has_landed
	simulator.step(delta)
	if model.has_landed and not landed:AudioDirector.play_landing()
	visual.update_ball(model.position,not model.has_landed,model.velocity,model.elapsed)
	camera.ball_velocity=model.velocity;camera.landed=model.has_landed
	hud.update_flight(model)
	if model.finished:_finish_shot()


func _finish_shot()->void:
	in_motion=false;visual.freeze_interpolation();hud.record_result(model,replaying)
	if not replaying:
		var point:=origin+model.position
		attempt.resolve_rest(Vector2(point.x,point.z))
		hud.show_message(attempt.last_outcome)
		if attempt.state==HoleRound.State.COMPLETE:
			if not store.record_result(attempt.result()):hud.show_message(store.last_error)
			_show_completion()
		else:turn_delay=1.0
	else:turn_delay=.6
	_refresh_score()


func _process(delta:float)->void:
	if in_motion:_refresh_score()
	if turn_delay>0:
		turn_delay-=delta
		if turn_delay<=0:_place_lie()


func _place_lie()->void:
	origin=Vector3(attempt.lie.x,0,attempt.lie.y);origin.y=world.surface.world_height(origin)
	visual.position=origin;visual.reset();visual.tracking_enabled=true
	var offset:=hole.cup-attempt.lie
	aim_yaw=rad_to_deg(atan2(offset.x,-offset.y));aim_slider.set_value_no_signal(aim_yaw)
	course_map.set_lie(attempt.lie,aim_yaw)
	_update_aim(true)
	hud.set_busy(attempt.state==HoleRound.State.COMPLETE)
	if attempt.state==HoleRound.State.COMPLETE:hud.launch_button.text="Hole complete"
	aim_slider.editable=attempt.state==HoleRound.State.READY
	_refresh_score();_refresh_preview()


func _update_aim(snap:=false)->void:
	var heading:=Vector3(sin(deg_to_rad(aim_yaw)),0,-cos(deg_to_rad(aim_yaw)))
	camera.set_launch_anchor(origin,heading,snap)
	aim_value.text="%.1f°"%aim_yaw
	var mesh:=ImmediateMesh.new();mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var right:=heading.cross(Vector3.UP)
	var tip:=origin+heading*10
	for segment in [[origin+heading,tip],[tip,origin+heading*8+right*.65],[tip,origin+heading*8-right*.65]]:
		for value in segment:
			var point:Vector3=value;point.y=world.surface.world_height(point)+.035;mesh.surface_add_vertex(point)
	mesh.surface_end();aim_mesh.mesh=mesh;aim_mesh.visible=attempt.state==HoleRound.State.READY
	_refresh_preview()
	if course_map:course_map.aim_yaw=aim_yaw;course_map.refresh_units()


func _refresh_preview()->void:
	if preview_mesh==null or attempt==null:return
	preview_mesh.visible=preview_visible and attempt.state==HoleRound.State.READY and not in_motion and turn_delay<=0
	if not preview_mesh.visible:return
	var shot:=GolfShot.from_payload({"shot_id":"preview","speed_mps":hud.speed_slider.value,"direction_deg":hud.direction_slider.value,
		"elevation_deg":hud.elevation_slider.value,"spin_rpm":hud.spin_slider.value})
	var points:=HoleShotSimulator.preview(shot,world.surface,origin,-deg_to_rad(aim_yaw))
	var mesh:=ImmediateMesh.new();mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for index in range(1,points.size(),2):mesh.surface_add_vertex(points[index-1]);mesh.surface_add_vertex(points[index])
	mesh.surface_end();preview_mesh.mesh=mesh;preview_mesh.position=origin


func _build_score_ui()->void:
	var panel:=AppStyle.panel(hud.root,365,25,-355,112);panel.anchor_right=1
	var column:=VBoxContainer.new();panel.add_child(column)
	score_label=AppStyle.label("",22,AppStyle.CREAM,true);column.add_child(score_label)
	score_label.clip_text=true
	detail_label=AppStyle.label("",12,AppStyle.MUTED);column.add_child(detail_label)
	# Keep aiming controls away from the ball's tee/rollout screen position.
	var aim_panel:=AppStyle.panel(hud.root,36,128,730,205)
	var row:=HBoxContainer.new();row.add_theme_constant_override("separation",12);aim_panel.add_child(row)
	row.add_child(AppStyle.label("AIM",10,AppStyle.GOLD))
	aim_slider=HSlider.new();aim_slider.min_value=-180;aim_slider.max_value=180;aim_slider.step=.5
	aim_slider.custom_minimum_size.x=310;aim_slider.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	aim_slider.value_changed.connect(func(value:float):aim_yaw=value;_update_aim())
	row.add_child(aim_slider);aim_value=AppStyle.label("0°",13);row.add_child(aim_value)
	var target:=AppStyle.button("Aim at cup")
	target.pressed.connect(func():
		if not in_motion and turn_delay<=0 and attempt.state==HoleRound.State.READY:
			var direction:=hole.cup-attempt.lie;aim_slider.value=rad_to_deg(atan2(direction.x,-direction.y))
	)
	row.add_child(target)
	hud.toast_label.offset_top=-300


func _refresh_score()->void:
	if attempt==null:return
	score_label.text="%s  ·  Par %d"%[hole.title,hole.par]
	var position:=attempt.lie
	if in_motion and model:
		var world_point:=origin+model.position
		position=Vector2(world_point.x,world_point.z)
	var distance:=GameSettings.distance(position.distance_to(hole.cup))
	course_map.set_ball(position,in_motion)
	var stroke:=attempt.strokes+1 if attempt.state==HoleRound.State.READY else attempt.strokes
	detail_label.text="Stroke %d  ·  %.0f %s to cup  ·  Green finish +%d  ·  Gross %d"%[stroke,distance,GameSettings.distance_suffix(),attempt.rules.options.green_putts,attempt.gross_score()]
	if attempt.state==HoleRound.State.COMPLETE:
		hud.set_busy(true);hud.launch_button.text="Hole complete"
		hud.status_label.text="●  Hole complete"
		detail_label.text="Gross %d  ·  %d real shots  ·  +%d automatic green strokes  ·  %+d to par"%[attempt.gross_score(),attempt.strokes,attempt.awarded_putts,attempt.gross_score()-hole.par]
	elif not in_motion and turn_delay<=0:hud.set_busy(false)


func _show_completion()->void:
	if is_instance_valid(completion):completion.queue_free()
	completion=Control.new();hud.root.add_child(completion);AppStyle.full_rect(completion)
	AppStyle.shade(completion,.5)
	var center:=CenterContainer.new();completion.add_child(center);AppStyle.full_rect(center)
	var panel:=PanelContainer.new();panel.custom_minimum_size.x=470;panel.add_theme_stylebox_override("panel",AppStyle.box());center.add_child(panel)
	var column:=VBoxContainer.new();column.add_theme_constant_override("separation",15);panel.add_child(column)
	column.add_child(AppStyle.label("NO PUTTER REQUIRED",10,AppStyle.GOLD))
	column.add_child(AppStyle.label("Hole complete.",37,AppStyle.CREAM,true))
	column.add_child(AppStyle.label("%d strokes"%attempt.gross_score(),44,AppStyle.GOLD,true))
	var relative:=attempt.gross_score()-hole.par
	var score_name: String={-3:"Albatross",-2:"Eagle",-1:"Birdie",0:"Par",1:"Bogey",2:"Double bogey"}.get(relative,"%+d to par"%relative)
	if attempt.finish_reason=="stroke_limit":score_name="Stroke limit reached"
	column.add_child(AppStyle.label("%s · Par %d"%[score_name,hole.par],18))
	column.add_child(AppStyle.label("%d shot%s + %d penalties + %d automatic green strokes"%[attempt.strokes,"" if attempt.strokes==1 else "s",attempt.penalties,attempt.awarded_putts],13,AppStyle.MUTED))
	for action in [["Play this hole again",restart],["Edit this hole",func():edit_requested.emit()],["My holes",func():library_requested.emit()]]:
		var button:=AppStyle.button(action[0],action[0]=="Play this hole again");button.pressed.connect(action[1]);column.add_child(button)


func _input(event:InputEvent)->void:
	if not interactive or not event is InputEventKey or not event.pressed or event.echo:return
	match event.physical_keycode:
		KEY_SPACE:hud.request_launch()
		KEY_1:hud.select_preset("Driver")
		KEY_2:hud.select_preset("7 Iron")
		KEY_3:hud.select_preset("Wedge")
		KEY_R:restart()
		KEY_P:replay()
		KEY_ESCAPE:pause_requested.emit()
		_:return
	get_viewport().set_input_as_handled()
