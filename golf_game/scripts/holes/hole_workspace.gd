class_name HoleWorkspace
extends Node3D
## One foreground document shared by editor and play; backdrop/resources are reused.
signal ready_for_use
signal loading_progress(value:float,message:String)
signal pause_requested
signal settings_requested
signal library_requested
signal menu_requested
signal mode_changed(editing:bool)
signal rules_requested

var save_root:="user://holes"
var store:HoleStore
var backdrop:AlpineRange
var world:HoleWorld
var editor_camera:HoleEditorCamera
var editor:HoleEditor
var play:HolePlay
var editing:=true
var interactive:=false


func _ready()->void:
	store=HoleStore.new(save_root)
	backdrop=AlpineRange.new();backdrop.auto_build=false;backdrop.custom_layout=true
	backdrop.build_progress.connect(func(value:float,message:String):loading_progress.emit(value*.8,message))
	add_child(backdrop)
	editor_camera=HoleEditorCamera.new();add_child(editor_camera);editor_camera.current=true
	_prepare.call_deferred()


func _prepare()->void:
	await backdrop.build_async()
	loading_progress.emit(.85,"Preparing your design tools")
	world=HoleWorld.new();world.backdrop=backdrop;add_child(world)
	var document:=store.load_draft()
	if document==null:document=HoleDefinition.new()
	world.set_document(document)
	editor=HoleEditor.new();editor.world=world;editor.camera=editor_camera;editor.store=store;add_child(editor)
	editor.hole=document;editor.hud.name_editor.text=document.title;editor.hud.par_option.select(document.par-3);editor._refresh()
	editor.play_requested.connect(open_play)
	editor.library_requested.connect(func():library_requested.emit())
	editor.back_requested.connect(func():menu_requested.emit())
	editor.rules_requested.connect(func():rules_requested.emit())
	play=HolePlay.new();play.world=world;play.backdrop=backdrop;play.store=store;add_child(play)
	play.pause_requested.connect(func():pause_requested.emit())
	play.settings_requested.connect(func():settings_requested.emit())
	play.edit_requested.connect(func():open_editor(editor.hole))
	play.library_requested.connect(func():library_requested.emit())
	play.set_active(false);play.hide();play.visual.locator.hide()
	editor.set_active(false)
	apply_preferences()
	loading_progress.emit(1.0,"Your hole studio is ready")
	ready_for_use.emit()


func open_editor(document:HoleDefinition=null)->void:
	if document!=null and editor.hole!=document:editor.set_document(document)
	editing=true;world.set_editing(true)
	backdrop.environment.fog_enabled=false # Plan view should read like a clear map.
	backdrop.obstruction_fader.enabled=false
	play.set_active(false);play.hide();play.visual.locator.hide()
	editor_camera.set_process(true);editor_camera.current=true
	set_interactive(true);mode_changed.emit(true)


func open_play(document:HoleDefinition)->void:
	if not document.play_errors().is_empty():return
	if editing:editor.save_draft()
	if editor.hole!=document:editor.set_document(document)
	world.sync_now();world.set_editing(false);editing=false
	backdrop.environment.fog_enabled=true
	editor.set_active(false);editor_camera.set_process(false)
	play.show();play.set_active(true);play.start_hole(document)
	set_interactive(true);mode_changed.emit(false)


func set_interactive(value:bool,_menu_camera:=false)->void:
	interactive=value
	if editor:editor.set_active(value and editing)
	if editor_camera:editor_camera.set_process(value and editing)
	if play:
		play.set_active(value and not editing)
		if not value:play.visual.locator.hide()
	if value:
		if editing:editor_camera.current=true
		else:play.camera.current=true


func apply_preferences()->void:
	var quality:=str(GameSettings.get_value("quality"))
	backdrop.apply_quality(quality)
	if world and world.close_turf:world.close_turf.apply_quality(quality)
	if play:play.apply_preferences()
	if editor:editor._refresh()


func save_draft()->void:
	if editor and editing:editor.save_draft()


func receive_shot(payload:Dictionary)->bool:
	return play.receive_shot(payload) if not editing and interactive else false
