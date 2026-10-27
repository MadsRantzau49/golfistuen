extends Node3D
## Composition root: wires input, domain model, scenery, and presentation.
## Call receive_shot(payload) from a future transport adapter or use ShotSource.

signal ready_for_play
signal loading_progress(value: float, message: String)
signal return_to_menu_requested
signal settings_requested

@export var staged_loading := false
var interactive := true
var world: AlpineRange

var source: DemoShotSource
var model: BallFlight
var visual: ShotVisual
var camera: RangeCamera
var hud: RangeHUD
var last_shot: GolfShot
var active := false
var replaying := false
var preview_visible := false
var preview_mesh: MeshInstance3D
var aim_mesh: MeshInstance3D
var course_map:ShotCourseMap


func _ready() -> void:
	world=AlpineRange.new()
	world.auto_build=not staged_loading
	world.build_progress.connect(func(value: float,message: String):loading_progress.emit(value,message))
	add_child(world)
	visual = ShotVisual.new()
	visual.position = AlpineRange.TEE
	visual.surface = world.surface
	add_child(visual)
	visual.contact_updated.connect(world.update_ball_contact)
	camera = RangeCamera.new()
	add_child(camera)
	camera.ball_subject = visual.ball
	camera.clearance = world.camera_clearance
	camera.framing_updated.connect(world.update_camera_visibility)
	source = DemoShotSource.new()
	add_child(source)
	source.shot_received.connect(_on_shot)
	source.input_rejected.connect(_on_input_rejected)
	hud = RangeHUD.new()
	add_child(hud)
	course_map=ShotCourseMap.new();course_map.position=Vector2(36,140);hud.root.add_child(course_map)
	hud.launch_requested.connect(source.fire)
	hud.reset_requested.connect(reset_tee)
	hud.replay_requested.connect(replay_last)
	hud.preview_changed.connect(_set_preview)
	hud.menu_requested.connect(func():return_to_menu_requested.emit())
	hud.settings_requested.connect(func():settings_requested.emit())
	for slider in [hud.speed_slider, hud.direction_slider, hud.elevation_slider, hud.spin_slider]:
		slider.value_changed.connect(func(_value: float): _refresh_preview())
	preview_mesh = MeshInstance3D.new()
	preview_mesh.position = AlpineRange.TEE
	preview_mesh.material_override = RangePalette.material(Color("eaf1c6"), true)
	preview_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(preview_mesh)
	_build_aim_line()
	hud.visible=interactive
	apply_preferences()
	_handle_automation()
	if staged_loading:
		_finish_loading.call_deferred()
	else:
		course_map.configure_range(world.surface)
		ready_for_play.emit.call_deferred()


func _finish_loading() -> void:
	await world.build_async()
	course_map.configure_range(world.surface)
	ready_for_play.emit()


func set_interactive(enabled: bool, menu_camera := false) -> void:
	interactive=enabled
	hud.visible=enabled
	camera.menu_mode=menu_camera
	visual.tracking_enabled = enabled and last_shot != null
	visual.locator.visible=enabled
	if not enabled: visual.freeze_interpolation()


func apply_preferences() -> void:
	if camera:
		camera.reduced_motion=bool(GameSettings.get_value("reduced_motion"))
	if visual:
		visual.show_trail=bool(GameSettings.get_value("show_trail"))
		if not visual.show_trail: visual.trail.visible=false
	if hud:
		hud.refresh_units()
	if course_map:course_map.refresh_units()


func receive_shot(payload: Dictionary) -> bool:
	# Parsing and duplicate/busy handling are shared by demo and future network input.
	return source.submit_payload(payload)


func _on_shot(shot: GolfShot) -> void:
	if active:
		hud.show_message("A ball is still in motion. Wait, or reset the tee.")
		return
	last_shot = shot
	_start_shot(shot, false)


func _start_shot(shot: GolfShot, is_replay: bool) -> void:
	model = BallFlight.new()
	model.ground_height = world.surface.local_height
	model.ground_resistance = world.surface.resistance
	model.launch(shot)
	active = true
	visual.tracking_enabled = interactive
	replaying = is_replay
	camera.begin_shot(AlpineRange.TEE + model.position, model.velocity)
	visual.reset()
	aim_mesh.visible=false
	hud.set_busy(true)
	AudioDirector.play_strike()
	preview_mesh.visible = false
	course_map.begin_shot(Vector2(AlpineRange.TEE.x,AlpineRange.TEE.z),0)
	var spin_label := "no side spin" if is_zero_approx(shot.spin_rpm) else "%.0f rpm %s" % [absf(shot.spin_rpm), "R" if shot.spin_rpm > 0 else "L"]
	hud.show_message("%s · %.1f m/s · %.1f° · %s" % ["Replay" if is_replay else "Shot detected", shot.speed_mps, shot.elevation_deg, spin_label])


func _physics_process(delta: float) -> void:
	if not active or not interactive:
		return
	var was_landed:=model.has_landed
	model.step(delta)
	if model.has_landed and not was_landed:AudioDirector.play_landing()
	visual.update_ball(model.position, not model.has_landed, model.velocity, model.elapsed)
	camera.ball_velocity = model.velocity
	camera.landed = model.has_landed
	hud.update_flight(model)
	var map_point:=AlpineRange.TEE+model.position
	course_map.set_ball(Vector2(map_point.x,map_point.z),not model.finished)
	if model.finished:
		active = false
		visual.freeze_interpolation()
		hud.set_busy(false)
		hud.update_flight(model)
		hud.record_result(model, replaying)


func _input(event: InputEvent) -> void:
	if not interactive:
		return
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.physical_keycode:
		KEY_SPACE:
			hud.request_launch()
		KEY_1:
			hud.select_preset("Driver")
		KEY_2:
			hud.select_preset("7 Iron")
		KEY_3:
			hud.select_preset("Wedge")
		KEY_R:
			reset_tee()
		KEY_P:
			replay_last()
		KEY_ESCAPE:
			return_to_menu_requested.emit()
		_:
			return
	get_viewport().set_input_as_handled()


func reset_tee() -> void:
	active = false
	model = null
	camera.reset_tracking()
	visual.tracking_enabled = false
	visual.reset()
	aim_mesh.visible=true
	hud.set_busy(false)
	hud.reset_metrics()
	course_map.set_lie(Vector2(AlpineRange.TEE.x,AlpineRange.TEE.z),0)
	_refresh_preview()
	hud.show_message("Fresh ball. Clear mind.")


func replay_last() -> void:
	if last_shot != null and not active:
		_start_shot(last_shot, true)


func _build_aim_line() -> void:
	aim_mesh=MeshInstance3D.new()
	aim_mesh.material_override=RangePalette.material(Color("e6d6a5"),true)
	aim_mesh.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var origin:=AlpineRange.TEE
	var tip:=origin+Vector3.FORWARD*10
	var mesh:=ImmediateMesh.new();mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for segment in [[origin+Vector3.FORWARD,tip],[tip,origin+Vector3.FORWARD*8+Vector3.RIGHT*.65],[tip,origin+Vector3.FORWARD*8-Vector3.RIGHT*.65]]:
		for value in segment:
			var point:Vector3=value;point.y=world.surface.world_height(point)+.025;mesh.surface_add_vertex(point)
	mesh.surface_end();aim_mesh.mesh=mesh;add_child(aim_mesh)


func _on_input_rejected(reason: String) -> void:
	hud.show_message(reason)


func _set_preview(enabled: bool) -> void:
	preview_visible = enabled
	_refresh_preview()


func _refresh_preview() -> void:
	if preview_mesh == null:
		return
	preview_mesh.visible = preview_visible and not active
	if not preview_mesh.visible:
		return
	var shot := GolfShot.from_payload({"shot_id": "preview", "speed_mps": hud.speed_slider.value,
		"direction_deg": hud.direction_slider.value, "elevation_deg": hud.elevation_slider.value, "spin_rpm": hud.spin_slider.value})
	var points := BallFlight.preview(shot, world.surface.local_height, world.surface.resistance)
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for index in range(1, points.size(), 2):
		mesh.surface_add_vertex(points[index - 1])
		mesh.surface_add_vertex(points[index])
	mesh.surface_end()
	preview_mesh.mesh = mesh


func _handle_automation() -> void:
	# Optional saved-shot startup; interactive and external input use the same path.
	var args := OS.get_cmdline_user_args()
	for index in range(args.size()):
		if args[index] == "--shot" and index + 1 < args.size():
			var file := FileAccess.open(args[index + 1], FileAccess.READ)
			if file == null:
				push_error("Cannot open shot file: " + args[index + 1])
				get_tree().quit(1)
				return
			var payload: Variant = JSON.parse_string(file.get_as_text())
			if not payload is Dictionary or not receive_shot(payload):
				push_error("Shot file must contain a JSON object.")
				get_tree().quit(1)
				return
