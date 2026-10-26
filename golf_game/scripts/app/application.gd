extends Node
## Application lifecycle. A game mode owns gameplay; this shell owns navigation,
## loading, preferences and transitions. The world is reused across menu and play.

signal state_changed(state_name: String)
enum State { LOADING, MENU, PLAYING, PAUSED, SETTINGS, EXITING, EDITING, HOLES }
var state := State.LOADING
var previous_state := State.MENU
var range_scene: Node3D
var ui_layer: CanvasLayer
var loading: RangeLoadingScreen
var menu: PinewaterMenu
var settings_panel: PinewaterSettingsPanel
var pause_panel: Control
var transition: ColorRect
var transition_tween: Tween
var workspace:HoleWorkspace
var library:HoleLibrary
var active_mode:Node3D
var resume_state:=State.PLAYING
var workspace_save_root:="user://holes"


func _ready() -> void:
	get_tree().auto_accept_quit=false
	var args:=OS.get_cmdline_user_args()
	if args.has("--smoke-holes") or args.has("--capture-builder") or args.has("--capture-hole"):
		workspace_save_root="user://qa-native-holes"
	ui_layer=CanvasLayer.new()
	ui_layer.layer=50
	add_child(ui_layer)
	loading=RangeLoadingScreen.new()
	ui_layer.add_child(loading)
	var fade_layer := CanvasLayer.new()
	fade_layer.layer=100
	add_child(fade_layer)
	transition=ColorRect.new()
	fade_layer.add_child(transition)
	AppStyle.full_rect(transition)
	transition.color=Color("0b1d16")
	transition.mouse_filter=Control.MOUSE_FILTER_IGNORE
	transition.modulate.a=0
	GameSettings.changed.connect(_on_setting_changed)
	GameSettings.save_failed.connect(_on_save_failed)
	_boot.call_deferred()


func _boot() -> void:
	await get_tree().process_frame
	var path := "res://scenes/driving_range.tscn"
	ResourceLoader.load_threaded_request(path)
	var progress: Array=[]
	while ResourceLoader.load_threaded_get_status(path,progress) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		loading.update_progress(float(progress[0])*.1 if not progress.is_empty() else 0,"Packing your clubs")
		await get_tree().process_frame
	if ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_LOADED:
		loading.update_progress(0,"The range could not be loaded. Please reinstall the application.")
		push_error("Could not load driving range scene")
		return
	var packed := ResourceLoader.load_threaded_get(path) as PackedScene
	range_scene=packed.instantiate()
	active_mode=range_scene
	range_scene.staged_loading=true
	range_scene.interactive=false
	range_scene.loading_progress.connect(func(value: float,message: String):loading.update_progress(.1+value*.9,message))
	range_scene.ready_for_play.connect(_world_ready,CONNECT_ONE_SHOT)
	range_scene.return_to_menu_requested.connect(pause_game)
	range_scene.settings_requested.connect(open_settings)
	add_child(range_scene)


func _world_ready() -> void:
	_apply_quality()
	await get_tree().create_timer(.35).timeout
	loading.queue_free()
	show_menu()
	if OS.get_cmdline_user_args().has("--range") or OS.get_cmdline_user_args().has("--shot"):
		enter_range()
	if OS.get_cmdline_user_args().has("--smoke-app"):
		_run_packaged_smoke.call_deferred()
	if OS.get_cmdline_user_args().has("--smoke-holes"):
		_run_hole_smoke.call_deferred()
	if OS.get_cmdline_user_args().has("--builder"):open_builder()
	if OS.get_cmdline_user_args().has("--capture-app"):
		_capture_requested.call_deferred()


func _set_state(value: State) -> void:
	state=value
	state_changed.emit(State.keys()[state])


func show_menu() -> void:
	_close_settings()
	_clear_pause()
	_hide_library()
	_hide_workspace()
	range_scene.show();range_scene.process_mode=Node.PROCESS_MODE_INHERIT;active_mode=range_scene
	_sync_active_environment()
	range_scene.camera.current=true
	range_scene.set_interactive(false,true)
	if menu == null or not is_instance_valid(menu):
		menu=PinewaterMenu.new()
		ui_layer.add_child(menu)
		menu.play_requested.connect(enter_range)
		menu.settings_requested.connect(open_settings)
		menu.quit_requested.connect(quit_application)
		menu.builder_requested.connect(open_builder)
		menu.holes_requested.connect(show_holes)
	menu.show()
	menu.play_button.grab_focus()
	_set_state(State.MENU)
	_reveal()


func enter_range() -> void:
	if state == State.LOADING:
		return
	if menu: menu.hide()
	_clear_pause()
	_hide_library();_hide_workspace()
	range_scene.show();range_scene.process_mode=Node.PROCESS_MODE_INHERIT;active_mode=range_scene
	_sync_active_environment()
	range_scene.camera.current=true
	range_scene.set_interactive(true,false)
	_set_state(State.PLAYING)
	_reveal()


func pause_game() -> void:
	if state not in [State.PLAYING,State.EDITING]:
		return
	resume_state=state
	active_mode.set_interactive(false,false)
	pause_panel=Control.new()
	ui_layer.add_child(pause_panel)
	AppStyle.full_rect(pause_panel)
	pause_panel.theme=AppStyle.theme()
	AppStyle.shade(pause_panel,.6)
	var center := CenterContainer.new()
	pause_panel.add_child(center)
	AppStyle.full_rect(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x=400
	panel.add_theme_stylebox_override("panel",AppStyle.box())
	center.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation",14)
	panel.add_child(column)
	column.add_child(AppStyle.label("NO NEED TO RUSH",10,AppStyle.GOLD))
	column.add_child(AppStyle.label("Take a breath.",34,AppStyle.CREAM,true))
	var resume := AppStyle.button("Back to the builder    ↗" if resume_state==State.EDITING else "Back to the golf    ↗",true)
	resume.pressed.connect(_resume_active)
	column.add_child(resume)
	var settings := AppStyle.button("Settings")
	settings.pressed.connect(open_settings)
	column.add_child(settings)
	var back := AppStyle.button("Main menu")
	back.pressed.connect(show_menu)
	column.add_child(back)
	resume.grab_focus()
	_set_state(State.PAUSED)


func open_settings(tab_index:=0) -> void:
	if state in [State.LOADING,State.SETTINGS]:
		return
	previous_state=state
	if state in [State.PLAYING,State.EDITING]:
		active_mode.set_interactive(false,false)
	settings_panel=PinewaterSettingsPanel.new()
	settings_panel.initial_tab=tab_index
	ui_layer.add_child(settings_panel)
	settings_panel.closed.connect(close_settings)
	_set_state(State.SETTINGS)


func close_settings() -> void:
	_close_settings()
	_set_state(previous_state)
	if state in [State.PLAYING,State.EDITING]:
		active_mode.set_interactive(true,false)
	elif state == State.MENU and menu:
		menu.play_button.grab_focus()


func _close_settings() -> void:
	if is_instance_valid(settings_panel):
		settings_panel.queue_free()
	settings_panel=null


func _clear_pause() -> void:
	if is_instance_valid(pause_panel):
		pause_panel.queue_free()
	pause_panel=null


func _reveal() -> void:
	if transition_tween: transition_tween.kill()
	transition.modulate.a=.5
	transition_tween=create_tween()
	transition_tween.tween_property(transition,"modulate:a",0.0,.45)


func _on_setting_changed(key: String,_value: Variant) -> void:
	if key == "quality": _apply_quality()
	if range_scene:
		range_scene.apply_preferences()
	if workspace:workspace.apply_preferences()


func _apply_quality() -> void:
	if not range_scene: return
	var quality := str(GameSettings.get_value("quality"))
	range_scene.world.apply_quality(quality)
	if workspace:workspace.apply_preferences()
	get_viewport().scaling_3d_scale={"Low":.7,"Medium":.85,"High":1.0}[quality]
	get_viewport().msaa_3d=Viewport.MSAA_4X if quality == "High" else Viewport.MSAA_2X
	_sync_active_environment()


func _on_save_failed(message: String) -> void:
	if range_scene: range_scene.hud.show_message(message)


func _unhandled_key_input(event: InputEvent) -> void:
	if state==State.EXITING:return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_F11:
			GameSettings.set_value("fullscreen",not bool(GameSettings.get_value("fullscreen")))
			get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_ESCAPE:
			match state:
				State.PLAYING: pause_game()
				State.EDITING: pause_game()
				State.PAUSED: _resume_active()
				State.SETTINGS: close_settings()
				State.HOLES: show_menu()
			get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what==NOTIFICATION_WM_CLOSE_REQUEST:
		quit_application()
		return
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and state in [State.PLAYING,State.EDITING]:
		pause_game()


func _run_packaged_smoke() -> void:
	# Runs inside the release executable too; validates packaged resources and flow.
	enter_range()
	range_scene.source.fire(42,2,30)
	for index in range(4800):
		range_scene._physics_process(BallFlight.STEP)
		if not range_scene.active: break
	if range_scene.hud.shot_count != 1:
		get_tree().quit(1)
		return
	pause_game()
	open_settings()
	close_settings()
	show_menu()
	print("PACKAGED APP PASS: loading → menu → range → shot → pause → settings → menu")
	await quit_application()


func _capture_requested()->void:
	# QA entry point works in the native release, validating the real player build.
	var args:=OS.get_cmdline_user_args()
	var index:=args.find("--capture-app")
	if DisplayServer.get_name()=="headless" or index+1>=args.size():
		get_tree().quit(1)
		return
	if args.has("--capture-settings"):open_settings()
	if args.has("--capture-builder"):
		await open_builder(HoleDefinition.new() if args.has("--blank") else HoleDefinition.demo())
	if args.has("--capture-hole"):await play_hole(HoleDefinition.demo())
	if args.has("--capture-flight"):
		enter_range()
		range_scene.source.fire(58,0,19)
		for frame in range(250):range_scene._physics_process(BallFlight.STEP)
		range_scene.active=false
		range_scene.visual.freeze_interpolation()
	await get_tree().create_timer(3).timeout
	await RenderingServer.frame_post_draw
	var error:=get_viewport().get_texture().get_image().save_png(args[index+1])
	print("Native application screenshot: ",args[index+1])
	print("Render review: ",Engine.get_frames_per_second()," fps / ",Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)," draw calls")
	await quit_application(error)


func quit_application(exit_code:=0)->void:
	if state==State.EXITING:return
	_set_state(State.EXITING)
	if workspace:workspace.save_draft()
	if active_mode:active_mode.set_interactive(false,false)
	await AudioDirector.shutdown()
	get_tree().quit(exit_code)


func _hide_workspace()->void:
	if workspace:
		workspace.save_draft();workspace.set_interactive(false);workspace.hide();workspace.process_mode=Node.PROCESS_MODE_DISABLED


func _hide_library()->void:
	if is_instance_valid(library):library.queue_free()
	library=null


func _resume_active()->void:
	_clear_pause()
	if active_mode==range_scene:enter_range()
	else:
		active_mode.set_interactive(true,false)
		_set_state(resume_state)
		_sync_active_environment()


func show_holes()->void:
	_close_settings();_clear_pause();_hide_workspace();_hide_library()
	if menu:menu.hide()
	range_scene.show();range_scene.process_mode=Node.PROCESS_MODE_INHERIT;range_scene.set_interactive(false,true)
	range_scene.camera.current=true;active_mode=range_scene
	_sync_active_environment()
	library=HoleLibrary.new();library.store=workspace.store if workspace else HoleStore.new()
	ui_layer.add_child(library)
	library.create_requested.connect(func():open_builder(HoleDefinition.new()))
	library.edit_requested.connect(_edit_saved_hole)
	library.play_requested.connect(_play_saved_hole)
	library.back_requested.connect(show_menu)
	_set_state(State.HOLES);_reveal()


func _ensure_workspace()->bool:
	if workspace:return true
	if menu:menu.hide()
	_hide_library();_set_state(State.LOADING)
	loading=RangeLoadingScreen.new();ui_layer.add_child(loading)
	workspace=HoleWorkspace.new()
	workspace.save_root=workspace_save_root
	workspace.loading_progress.connect(func(value:float,message:String):
		if is_instance_valid(loading):loading.update_progress(value,message)
	)
	workspace.pause_requested.connect(pause_game)
	workspace.settings_requested.connect(open_settings)
	workspace.rules_requested.connect(func():open_settings(1))
	workspace.library_requested.connect(show_holes)
	workspace.menu_requested.connect(show_menu)
	workspace.mode_changed.connect(func(editing:bool):
		active_mode=workspace
		_sync_active_environment()
		_set_state(State.EDITING if editing else State.PLAYING)
	)
	add_child(workspace)
	await workspace.ready_for_use
	if is_instance_valid(loading):loading.queue_free()
	loading=null
	return state!=State.EXITING


func _activate_workspace()->void:
	_close_settings();_clear_pause();_hide_library()
	if menu:menu.hide()
	range_scene.set_interactive(false,false);range_scene.hide();range_scene.process_mode=Node.PROCESS_MODE_DISABLED
	workspace.show();workspace.process_mode=Node.PROCESS_MODE_INHERIT;active_mode=workspace
	_sync_active_environment()


func _sync_active_environment()->void:
	# Hidden WorldEnvironment nodes still affect a shared World3D. Explicitly
	# select the active mode's environment rather than relying on node visibility.
	if not range_scene or not range_scene.is_inside_tree():return
	var environment:Environment=workspace.backdrop.environment if workspace and active_mode==workspace else range_scene.world.environment
	range_scene.get_world_3d().environment=environment


func open_builder(document:HoleDefinition=null)->void:
	if not await _ensure_workspace():return
	_activate_workspace()
	if document==null and not workspace.editing:document=workspace.store.load_draft()
	workspace.open_editor(document)
	_set_state(State.EDITING);_reveal()


func play_hole(document:HoleDefinition)->void:
	if document==null or not document.play_errors().is_empty():return
	if not await _ensure_workspace():return
	_activate_workspace();workspace.open_play(document)
	_set_state(State.PLAYING);_reveal()


func _edit_saved_hole(id:String)->void:
	var document:=HoleDefinition.demo() if id=="@demo" else (workspace.store if workspace else HoleStore.new()).load_hole(id)
	if document==null:return
	if id=="@demo":document.id=HoleDefinition.new_id();document.title+=" (copy)"
	open_builder(document)


func _play_saved_hole(id:String)->void:
	var document:=HoleDefinition.demo() if id=="@demo" else (workspace.store if workspace else HoleStore.new()).load_hole(id)
	play_hole(document)


func _run_hole_smoke()->void:
	var document:=HoleDefinition.new();document.id="native-editor-check";document.title="Native hole check"
	await open_builder(document)
	workspace.editor.edit_once(Vector2(0,-45),"green",38)
	workspace.editor.edit_once(Vector2(12,-45),"cup",2)
	workspace.editor.save()
	var loaded:=workspace.store.load_hole(document.id)
	if loaded==null or not loaded.play_errors().is_empty():await quit_application(1);return
	await play_hole(loaded)
	workspace.play.source.fire(26,0,48,0)
	for frame in range(5000):
		workspace.play._physics_process(BallFlight.STEP)
		if not workspace.play.in_motion:break
	if workspace.play.attempt.state!=HoleRound.State.COMPLETE:await quit_application(1);return
	print("PACKAGED HOLE PASS: empty builder → paint green/cup → save/load → playable shot → no-putting score")
	await quit_application()
