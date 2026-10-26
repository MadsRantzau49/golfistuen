extends SceneTree
var failures:=0


func _initialize()->void:
	_run.call_deferred()
	create_timer(100).timeout.connect(func():printerr("FAIL: hole application checks timed out");quit(1))


func check(value:bool,message:String)->void:
	if not value:failures+=1;printerr("FAIL: "+message)


func _run()->void:
	var packed:=load("res://scenes/application.tscn") as PackedScene
	var app:=packed.instantiate()
	var directory:="user://app-hole-check-%d"%Time.get_ticks_msec()
	app.workspace_save_root=directory;root.add_child(app)
	while app.state==app.State.LOADING:await process_frame
	app.show_holes()
	check(app.state==app.State.HOLES and app.library!=null,"Main menu opens the hole library")
	await app.open_builder(HoleDefinition.new())
	check(app.state==app.State.EDITING and app.workspace.editor.active,"Main menu opens the integrated builder")
	check(not app.range_scene.visible and app.active_mode==app.workspace,"Only the active world is presented")
	check(app.range_scene.get_world_3d().environment==app.workspace.backdrop.environment and not app.workspace.backdrop.environment.fog_enabled,
		"Editor selects its clear-map environment rather than the hidden range atmosphere")
	app.pause_game();app.open_settings(1)
	check(app.state==app.State.SETTINGS and app.settings_panel.controls.has("green_putts"),"Simulator scoring settings are integrated")
	app.close_settings();app._resume_active()
	check(app.state==app.State.EDITING and app.workspace.editor.active,"Settings and pause restore editing")
	app.workspace.editor.edit_once(Vector2(0,-40),"green",20)
	app.workspace.editor.edit_once(Vector2(0,-40),"cup",2)
	app.workspace.editor.hud.play_button.pressed.emit()
	check(app.state==app.State.PLAYING and app.workspace.play.interactive,"Test hole enters playable custom-hole mode")
	app.workspace.play.source.fire(15,0,25,0)
	app.pause_game()
	var elapsed:float=app.workspace.play.model.elapsed
	app.workspace.play._physics_process(1)
	check(app.workspace.play.model.elapsed==elapsed,"Pausing a custom hole freezes the shot")
	app._resume_active()
	check(app.state==app.State.PLAYING and app.workspace.play.in_motion,"Resume preserves the in-flight shot")
	app.show_holes()
	check(app.state==app.State.HOLES and not app.workspace.visible,"Library can be opened after a round")
	app.show_menu()
	check(app.state==app.State.MENU and app.range_scene.visible,"Main menu returns to the original range backdrop")
	check(app.range_scene.get_world_3d().environment==app.range_scene.world.environment,"Returning to menu restores the range environment")
	app.queue_free();await process_frame
	var dir:=DirAccess.open(directory)
	if dir:
		for filename in dir.get_files():DirAccess.remove_absolute(directory.path_join(filename))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(directory))
	if failures==0:print("PASS: menu/library/builder routing, active-world isolation, scoring settings, custom-hole pause/resume and main-menu return")
	quit(1 if failures else 0)
