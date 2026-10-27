class_name HoleEditor
extends Node
## Editor intent, strokes and undo. Document/store/rendering are separate modules.
signal play_requested(hole:HoleDefinition)
signal library_requested
signal back_requested
signal rules_requested

var world:HoleWorld
var camera:HoleEditorCamera
var store:HoleStore
var hole:HoleDefinition
var hud:HoleEditorHUD
var history:=HoleHistory.new()
var active:=false
var dirty:=false
var tool:="fairway"
var _stroke:=false
var _modified:=false
var _last_point:=Vector2.ZERO
var _flatten_height:=0.0
var _cursor:MeshInstance3D
var _dialog:FileDialog
var _new_dialog:ConfirmationDialog
var _tee_label:Label
var _cup_label:Label


func _ready()->void:
	hud=HoleEditorHUD.new();add_child(hud)
	hud.tool_selected.connect(func(value:String):tool=value;hud.select_tool(tool))
	hud.save_requested.connect(save)
	hud.play_requested.connect(func():_commit_metadata();world.sync_now();play_requested.emit(hole))
	hud.new_requested.connect(_request_new)
	hud.library_requested.connect(func():save_draft();library_requested.emit())
	hud.back_requested.connect(func():save_draft();back_requested.emit())
	hud.import_requested.connect(_import_dialog)
	hud.export_requested.connect(_export_dialog)
	hud.undo_requested.connect(undo)
	hud.redo_requested.connect(redo)
	hud.frame_requested.connect(camera.frame_hole)
	hud.angle_requested.connect(func():camera.tilted=not camera.tilted;camera.update_pose())
	hud.metadata_changed.connect(_commit_metadata)
	hud.rules_requested.connect(func():rules_requested.emit())
	_cursor=MeshInstance3D.new();world.add_child(_cursor)
	var material:=RangePalette.material(AppStyle.GOLD,true);material.no_depth_test=true
	_cursor.material_override=material;_cursor.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_new_dialog=ConfirmationDialog.new();_new_dialog.title="New empty hole";_new_dialog.dialog_text="Start with an empty rough plot? Save this design first if you want it in My holes."
	_new_dialog.ok_button_text="New empty hole";_new_dialog.confirmed.connect(func():set_document(HoleDefinition.new()))
	hud.root.add_child(_new_dialog)
	hud.select_tool(tool)
	_tee_label=_marker_label("TEE")
	_cup_label=_marker_label("CUP")


func set_document(document:HoleDefinition)->void:
	_end_stroke();hole=document;world.set_document(hole);history.clear();dirty=false
	hud.name_editor.text=hole.title;hud.par_option.select(hole.par-3);_refresh()


func set_active(value:bool)->void:
	if not value:_end_stroke()
	active=value;hud.visible=value;_cursor.visible=value
	if value:camera.current=true


func _refresh()->void:
	if hole:hud.show_document(hole,dirty)


func _commit_metadata()->void:
	if hole==null:return
	var name_value:=hud.name_editor.text.strip_edges()
	var par_value:=hud.par_option.selected+3
	var diameter:=clampf(snappedf(hud.cup_size.value/100.0,.001),HoleDefinition.MIN_CUP_DIAMETER,HoleDefinition.MAX_CUP_DIAMETER)
	if name_value==hole.title and par_value==hole.par and is_equal_approx(diameter,hole.cup_diameter_m):return
	history.begin(hole);hole.title=name_value;hole.par=par_value
	if not is_equal_approx(diameter,hole.cup_diameter_m):hole.set_cup_diameter(diameter)
	history.commit(true)
	dirty=true;_refresh()


func _request_new()->void:
	if dirty:_new_dialog.popup_centered()
	else:set_document(HoleDefinition.new())


func save()->void:
	_commit_metadata()
	if hole.title.is_empty():hud.status.text="Give your hole a name before saving.";return
	if store.save(hole):dirty=false;hud.status.text="Saved to My holes. Your design is available offline."
	else:hud.status.text=store.last_error
	_refresh()


func save_draft()->void:
	_end_stroke();_commit_metadata()
	if hole:store.save_draft(hole)


func undo()->void:
	_end_stroke()
	if history.undo(hole):dirty=true;world.sync_now();_refresh()


func redo()->void:
	_end_stroke()
	if history.redo(hole):dirty=true;world.sync_now();_refresh()


func edit_once(point:Vector2,selected_tool:String,radius:float,amount:=.15)->bool:
	history.begin(hole)
	var modified:=_apply(point,selected_tool,radius,amount)
	history.commit(modified)
	if modified:dirty=true;_refresh()
	return modified


func _apply(point:Vector2,selected_tool:String,radius:float,delta:float)->bool:
	match selected_tool:
		"tee":hole.place_tee(point);return true
		"cup":hole.place_cup(point);return true
		"tree":
			var added:=hole.add_tree(point,"aspen" if hud.species_option.selected==1 else "spruce")
			if not added:hud.status.text="Trees need playable ground and 2.5 m spacing (maximum %d trees)."%HoleDefinition.MAX_TREES
			return added
		"erase_tree":return hole.erase_trees(point,radius)
		_:return hole.apply_brush(point,radius,selected_tool,hud.strength_slider.value,delta,_flatten_height)


func _mouse_point(screen_position:=Vector2(INF,INF))->Variant:
	var mouse:=screen_position if is_finite(screen_position.x) else get_viewport().get_mouse_position()
	return world.pick_ray(camera.project_ray_origin(mouse),camera.project_ray_normal(mouse))


func _process(delta:float)->void:
	if not active or hole==null:return
	_update_marker_labels()
	if _stroke and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):_end_stroke()
	var hovering:=get_viewport().gui_get_hovered_control()
	if hovering!=null:
		_cursor.visible=false
		return
	var hit:Variant=_mouse_point()
	_cursor.visible=hit!=null
	if hit==null:return
	var point:=Vector2(hit.x,hit.z)
	_draw_cursor(point)
	if _stroke:
		var distance:=point.distance_to(_last_point)
		var steps:=clampi(ceili(distance/maxf(hud.radius_slider.value*.25,1.0)),1,32)
		for index in range(1,steps+1):
			_modified=_apply(_last_point.lerp(point,float(index)/steps),tool,hud.radius_slider.value,minf(delta,.1)/steps) or _modified
		_last_point=point


func _marker_label(text:String)->Label:
	var label:=AppStyle.label(text,11,AppStyle.GOLD)
	label.add_theme_stylebox_override("normal",AppStyle.box(Color("10251fdf"),5,Color("ffffff25"),5))
	hud.root.add_child(label)
	return label


func _update_marker_labels()->void:
	var viewport_size:=get_viewport().get_visible_rect().size
	var free_area:=Rect2(275,115,viewport_size.x-610,viewport_size.y-155)
	for entry in [[_tee_label,hole.tee,true],[_cup_label,hole.cup,hole.cup_placed]]:
		var point:=Vector3(entry[1].x,0,entry[1].y);point.y=world.surface.world_height(point)+.3
		var screen:=camera.unproject_position(point)
		entry[0].visible=entry[2] and free_area.has_point(screen)
		entry[0].position=screen+Vector2(8,-18)


func _unhandled_input(event:InputEvent)->void:
	if not active:return
	if event is InputEventMouseButton:
		if event.button_index==MOUSE_BUTTON_WHEEL_UP and event.pressed:camera.zoom(1);get_viewport().set_input_as_handled()
		elif event.button_index==MOUSE_BUTTON_WHEEL_DOWN and event.pressed:camera.zoom(-1);get_viewport().set_input_as_handled()
		elif event.button_index==MOUSE_BUTTON_LEFT:
			if event.pressed:
				var hit:Variant=_mouse_point(event.position)
				if hit==null:return
				var point:=Vector2(hit.x,hit.z)
				_flatten_height=hole.height_at(point)
				if tool in ["tee","cup","tree"]:
					edit_once(point,tool,hud.radius_slider.value)
				else:
					history.begin(hole);_stroke=true;_modified=false;_last_point=point
					_modified=_apply(point,tool,hud.radius_slider.value,1.0/30.0)
			else:_end_stroke()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and (Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE)):
		camera.pan(event.relative);get_viewport().set_input_as_handled()


func _unhandled_key_input(event:InputEvent)->void:
	if not active or not event is InputEventKey or not event.pressed or event.echo:return
	if event.ctrl_pressed:
		match event.physical_keycode:
			KEY_S:save()
			KEY_Z:redo() if event.shift_pressed else undo()
			KEY_Y:redo()
			_:return
	elif event.physical_keycode==KEY_F:camera.frame_hole()
	else:return
	get_viewport().set_input_as_handled()


func _end_stroke()->void:
	if not _stroke:return
	history.commit(_modified);_stroke=false
	if _modified:dirty=true;world.sync_now();_refresh()


func _draw_cursor(point:Vector2)->void:
	var mesh:=ImmediateMesh.new();mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	var radius:=hud.radius_slider.value
	if tool=="cup":radius=hole.cup_radius()
	elif tool=="tee":radius=1.0
	elif tool=="tree":radius=2.5
	for index in range(65):
		var angle:=TAU*index/64.0
		var p:=point+Vector2(cos(angle),sin(angle))*radius
		var world_point:=Vector3(p.x,0,p.y);world_point.y=world.surface.rim_height_at(world_point)+.035
		mesh.surface_add_vertex(world_point)
	mesh.surface_end();_cursor.mesh=mesh


func _make_file_dialog(mode:int)->FileDialog:
	if is_instance_valid(_dialog):_dialog.queue_free()
	_dialog=FileDialog.new();_dialog.access=FileDialog.ACCESS_FILESYSTEM;_dialog.file_mode=mode
	_dialog.filters=PackedStringArray(["*.json ; Pinewater hole"]);_dialog.size=Vector2i(850,550)
	hud.root.add_child(_dialog)
	return _dialog


func _import_dialog()->void:
	var dialog:=_make_file_dialog(FileDialog.FILE_MODE_OPEN_FILE)
	dialog.file_selected.connect(func(path:String):
		var imported:=store.load_file(path)
		if imported==null:hud.status.text=store.last_error;return
		imported.metadata["imported_id"]=imported.id;imported.id=HoleDefinition.new_id()
		if dirty:
			var confirm:=ConfirmationDialog.new();confirm.title="Replace current design?"
			confirm.dialog_text="Import replaces the current unsaved design. Cancel and save it first to keep it in My holes."
			confirm.ok_button_text="Import design"
			confirm.confirmed.connect(func():_accept_import(imported);confirm.queue_free())
			confirm.canceled.connect(confirm.queue_free);hud.root.add_child(confirm);confirm.popup_centered()
		else:_accept_import(imported)
	)
	dialog.popup_centered()


func _accept_import(imported:HoleDefinition)->void:
	set_document(imported);dirty=true;_refresh();hud.status.text="Imported design. Save it to add it to My holes."


func _export_dialog()->void:
	_commit_metadata()
	var dialog:=_make_file_dialog(FileDialog.FILE_MODE_SAVE_FILE);dialog.current_file=hole.id+".json"
	dialog.file_selected.connect(func(path:String):hud.status.text="Exported hole JSON." if store.export_hole(hole,path) else store.last_error)
	dialog.popup_centered()
