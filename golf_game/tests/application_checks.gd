extends SceneTree
## Checks production navigation and persistence against the actual application.
var failures:=0


func _initialize()->void:
	_run.call_deferred()
	create_timer(60).timeout.connect(func():
		printerr("FAIL: application checks timed out")
		quit(1)
	)


func check(condition:bool,message:String)->void:
	if not condition:
		failures+=1
		printerr("FAIL: "+message)


func _run()->void:
	_check_preferences()
	var packed:=load("res://scenes/application.tscn") as PackedScene
	if packed==null:
		quit(1)
		return
	var app:=packed.instantiate()
	root.add_child(app)
	while app.state==app.State.LOADING:
		await process_frame
	check(app.state==app.State.MENU,"Startup finishes at the main menu")
	check(app.menu.visible and not app.range_scene.hud.visible,"Menu owns input before play")
	app.menu.play_requested.emit()
	check(app.state==app.State.PLAYING and app.range_scene.interactive,"Play enters driving range")
	app.range_scene.hud.select_preset("7 Iron")
	app.range_scene.hud.direction_slider.value=3.0
	app.range_scene.hud.spin_slider.value=900.0
	app.range_scene.hud.request_launch()
	check(app.range_scene.active,"Practice UI launches through the event interface")
	check(app.range_scene.course_map.range_mode and app.range_scene.course_map.visible,"Practice includes a range-target distance guide")
	check(app.range_scene.last_shot.spin_rpm==900.0,"Side-spin control reaches the actual launch payload")
	app.pause_game()
	var elapsed:float=app.range_scene.model.elapsed
	app.range_scene._physics_process(1.0)
	check(app.range_scene.model.elapsed==elapsed,"Pause freezes the current shot")
	app.open_settings()
	check(app.state==app.State.SETTINGS and app.settings_panel!=null,"Settings open from pause")
	app.close_settings()
	check(app.state==app.State.PAUSED,"Closing settings restores paused state")
	app.enter_range()
	check(app.range_scene.active,"Resume preserves the shot")
	for frame in range(4800):
		app.range_scene._physics_process(BallFlight.STEP)
		if not app.range_scene.active:break
	check(app.range_scene.hud.shot_count==1,"Resumed shot finishes exactly once")
	var resting_point:Vector3=AlpineRange.TEE+app.range_scene.model.position
	check(app.range_scene.course_map.ball.distance_to(Vector2(resting_point.x,resting_point.z))<.001 and app.range_scene.course_map.trail.size()>1,"Range map tracks the real shot to its resting position")
	var preferences:Node=root.get_node("GameSettings")
	var old_quality:Variant=preferences.get_value("quality")
	preferences.set_value("quality","Low",false)
	check(abs(root.scaling_3d_scale-.7)<.0001,"Low quality reduces the actual 3D render resolution")
	preferences.set_value("quality",old_quality,false)
	var old_units:Variant=preferences.get_value("units")
	preferences.set_value("units","Yards",false)
	check(app.range_scene.hud.carry_label.text=="%.0f"%preferences.distance(app.range_scene.model.carry_m),"Unit preference updates displayed metrics")
	check(app.range_scene.course_map._distance.text.contains("yd"),"Range target labels use the selected units")
	preferences.set_value("units",old_units,false)
	var old_trail:Variant=preferences.get_value("show_trail")
	preferences.set_value("show_trail",false,false)
	check(not app.range_scene.visual.trail.visible,"Trail setting takes effect even with a stationary ball")
	preferences.set_value("show_trail",old_trail,false)
	app.open_settings()
	app.close_settings()
	check(app.state==app.State.PLAYING,"Settings opened from play return to play")
	app.show_menu()
	check(not app.range_scene.interactive and app.menu.visible,"Main menu disables gameplay input")
	app.enter_range()
	check(app.range_scene.hud.shot_count==1,"Returning to the range preserves the session")
	app.queue_free()
	await process_frame
	if failures==0:print("PASS: loading, main menu, practice controls, pause/resume, settings navigation, graphics/units/trail application, session preservation, preference validation and disk persistence")
	quit(1 if failures else 0)


func _check_preferences()->void:
	var service:Node=load("res://scripts/app/game_settings.gd").new()
	check(not service.set_value("quality","Ultra",false),"Invalid quality is rejected")
	check(not service.set_value("master_volume",NAN,false),"Nonfinite volume is rejected")
	check(not service.set_value("fullscreen","true",false),"Wrong setting types are rejected")
	check(service.set_value("units","Yards",false),"Supported units are accepted")
	check(abs(service.distance(100)-109.36133)<.001,"Yard conversion is correct")
	service.set_value("effects_volume",.35,false)
	var path:="user://preferences-check-%d.cfg"%Time.get_ticks_msec()
	check(service.save_preferences(path),"Preferences save successfully")
	var loaded:Node=load("res://scripts/app/game_settings.gd").new()
	loaded.load_preferences(path)
	check(loaded.get_value("units")=="Yards" and abs(float(loaded.get_value("effects_volume"))-.35)<.00001,"Preferences survive reloading from disk")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	service.free()
	loaded.free()
