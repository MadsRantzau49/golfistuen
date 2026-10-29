class_name ShotNotesPanel
extends Node3D
## Space brackets a real attempt; the form records the operator's own estimates.
signal menu_requested
const CHOICES := {
	"speed":[["low","Low"],["medium","Medium"],["high","High"],["full_speed","Full speed"]],
	"elevation":[["rolling","Rolling"],["very_low_jumping","Very low jumping"],["low","Low"],["medium","Medium"],["good_swing","Good swing"],["too_high","Too high"],["instant_ceiling","Instant ceiling"]],
	"direction":[["full_left","Full left"],["left","Left"],["straight","Straight"],["right","Right"],["full_right","Full right"]]
}
var auto_connect := true
var cache_path := "user://shot-notes.json"
var interactive := true
var client: ShotNotesClient
var ui_layer: CanvasLayer
var selected_key := ""
var recording_key := ""
var ending_key := ""
var _local_started := 0
var _local_ended := 0
var _save_at := -1
var _updating := false
var _keys: Array = []
var _presets: Dictionary = {}
var _host: LineEdit
var _port: SpinBox
var _status: Label
var _state: Label
var _clock: Label
var _detector_guess: Label
var _capture_button: Button
var _history: ItemList
var _notes: TextEdit
var _summary: Label
var _timing: Label
var _saved: Label
var _message: Label
var _older: Button
var _export: FileDialog


func _ready() -> void:
	_build_ui()
	client=ShotNotesClient.new();client.cache_path=cache_path
	client.info_received.connect(_on_info);client.record_changed.connect(_on_record)
	client.connection_changed.connect(_on_connection);client.status_received.connect(_on_status)
	client.failed.connect(_show_message);client.operation_failed.connect(_on_error)
	add_child(client);_refresh_history();_load_form()
	if auto_connect:_connect()


func _button(parent: Node, text: String, action: Callable, primary:=false) -> Button:
	var button:=AppStyle.button(text,primary);button.custom_minimum_size.y=38;parent.add_child(button);button.pressed.connect(action);return button


func _build_ui() -> void:
	ui_layer=CanvasLayer.new();ui_layer.layer=25;add_child(ui_layer)
	var root:=PanelContainer.new();root.theme=AppStyle.theme();ui_layer.add_child(root);AppStyle.full_rect(root)
	root.add_theme_stylebox_override("panel",AppStyle.box(Color("10251f"),0,Color.TRANSPARENT,22))
	var column:=VBoxContainer.new();column.add_theme_constant_override("separation",12);root.add_child(column)
	var heading:=HBoxContainer.new();column.add_child(heading)
	var title:=AppStyle.label("Shot notes",32,AppStyle.CREAM,true);title.size_flags_horizontal=Control.SIZE_EXPAND_FILL;heading.add_child(title)
	_button(heading,"← Main menu",func():menu_requested.emit())
	column.add_child(AppStyle.label("Space to start → take your shot → Space to end → describe what happened.",17,AppStyle.GOLD))
	var connection:=HBoxContainer.new();column.add_child(connection)
	_host=LineEdit.new();_host.text=str(GameSettings.get_value("radar_host"));_host.placeholder_text="Radar computer IP";_host.custom_minimum_size.x=230;connection.add_child(_host)
	_port=SpinBox.new();_port.min_value=1;_port.max_value=65535;_port.step=1;_port.value=int(GameSettings.get_value("radar_port"));connection.add_child(_port)
	_button(connection,"Connect / reconnect",_connect)
	_status=AppStyle.label("Connect to the live radar service.",13,AppStyle.MUTED);_status.size_flags_horizontal=Control.SIZE_EXPAND_FILL;_status.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;connection.add_child(_status)
	var capture_row:=HBoxContainer.new();capture_row.add_theme_constant_override("separation",20);column.add_child(capture_row)
	_capture_button=_button(capture_row,"Start shot  [Space]",toggle_capture,true);_capture_button.custom_minimum_size=Vector2(270,54)
	_state=AppStyle.label("Ready for a timed capture",20,AppStyle.CREAM);_state.size_flags_horizontal=Control.SIZE_EXPAND_FILL;capture_row.add_child(_state)
	_clock=AppStyle.label("0.0 s",28,AppStyle.GOLD);capture_row.add_child(_clock)
	_detector_guess=AppStyle.label("Detector estimate · no ball registered yet",16,AppStyle.MUTED)
	_detector_guess.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;column.add_child(_detector_guess)
	var body:=HBoxContainer.new();body.add_theme_constant_override("separation",16);body.size_flags_vertical=Control.SIZE_EXPAND_FILL;column.add_child(body)
	var history_panel:=PanelContainer.new();history_panel.custom_minimum_size.x=245;history_panel.add_theme_stylebox_override("panel",AppStyle.box());body.add_child(history_panel)
	var left:=VBoxContainer.new();left.add_theme_constant_override("separation",10);history_panel.add_child(left)
	left.add_child(AppStyle.label("CAPTURED SHOTS",12,AppStyle.GOLD))
	_history=ItemList.new();_history.custom_minimum_size=Vector2(210,100);_history.size_flags_vertical=Control.SIZE_EXPAND_FILL;left.add_child(_history)
	_history.item_selected.connect(_select_index)
	_older=_button(left,"Load older shots",func():
		if client.connected and client.next_offset!=null:client.request("notes_list",{"offset":client.next_offset})
	)
	_button(left,"Export selected shot…",func():_export.popup_centered_ratio(.6))
	_button(left,"Copy shot summary",_copy_summary)
	var form_panel:=PanelContainer.new();form_panel.size_flags_horizontal=Control.SIZE_EXPAND_FILL;form_panel.add_theme_stylebox_override("panel",AppStyle.box());body.add_child(form_panel)
	var scroll:=ScrollContainer.new();scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED;form_panel.add_child(scroll)
	var form:=VBoxContainer.new();form.size_flags_horizontal=Control.SIZE_EXPAND_FILL;form.size_flags_vertical=Control.SIZE_EXPAND_FILL;form.add_theme_constant_override("separation",12);scroll.add_child(form)
	form.add_child(AppStyle.label("Your estimate of this shot",25,AppStyle.CREAM,true))
	for field in ["speed","elevation","direction"]:
		form.add_child(AppStyle.label(str(field).capitalize(),15,AppStyle.GOLD))
		var row:=HFlowContainer.new();row.add_theme_constant_override("h_separation",7);row.add_theme_constant_override("v_separation",6);form.add_child(row)
		var group:=ButtonGroup.new();group.allow_unpress=true;_presets[field]={}
		for choice in CHOICES[field]:
			var button:=AppStyle.button(choice[1]);button.custom_minimum_size.y=36;button.toggle_mode=true;button.button_group=group
			row.add_child(button);_presets[field][choice[0]]=button;button.pressed.connect(_preset_clicked.bind(field,choice[0],button))
	form.add_child(AppStyle.label("Other notes · optional",15,AppStyle.GOLD))
	_notes=TextEdit.new();_notes.placeholder_text="None. Optional: travelled about 4 m, reached about 2 m high, straight ahead…"
	_notes.custom_minimum_size=Vector2(0,100);_notes.size_flags_vertical=Control.SIZE_EXPAND_FILL;_notes.wrap_mode=TextEdit.LINE_WRAPPING_BOUNDARY;form.add_child(_notes)
	_notes.text_changed.connect(_notes_changed)
	_summary=AppStyle.label("",13,AppStyle.CREAM);_summary.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;form.add_child(_summary)
	_timing=AppStyle.label("",12,AppStyle.MUTED);_timing.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;form.add_child(_timing)
	var save_row:=HBoxContainer.new();form.add_child(save_row)
	_button(save_row,"Save description",_flush_current,true)
	_saved=AppStyle.label("",13,AppStyle.MUTED);_saved.size_flags_horizontal=Control.SIZE_EXPAND_FILL;_saved.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;save_row.add_child(_saved)
	_message=AppStyle.label("Space starts/stops capture when you are outside a text field. Space inside notes types a normal space.",12,AppStyle.MUTED)
	_message.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;column.add_child(_message)
	_export=FileDialog.new();_export.access=FileDialog.ACCESS_FILESYSTEM;_export.file_mode=FileDialog.FILE_MODE_SAVE_FILE;_export.filters=PackedStringArray(["*.json ; Shot notes"]);_export.current_file="shot-notes.json"
	ui_layer.add_child(_export);_export.file_selected.connect(export_selected)


func _connect() -> void:
	if client==null:return
	_flush_current()
	GameSettings.set_value("radar_host",_host.text.strip_edges());GameSettings.set_value("radar_port",int(_port.value))
	client.connect_to(_host.text,int(_port.value))


func set_interactive(enabled: bool, _menu_mode:=false) -> void:
	interactive=enabled
	if ui_layer:ui_layer.visible=enabled
	if client:
		if not enabled:_flush_current();client.disconnect_from();recording_key="";ending_key=""
		elif auto_connect and client.peer==null:_connect()


func toggle_capture() -> void:
	if client==null or not client.connected or client.session_id.is_empty():_show_message("Connect to the radar service first.");return
	if not ending_key.is_empty():return
	if not recording_key.is_empty():
		_local_ended=Time.get_ticks_msec();ending_key=recording_key;recording_key=""
		client.end_capture(ending_key);_flush_current();_state.text="Ending capture…";return
	_flush_current()
	var key:=client.start_capture()
	if key.is_empty():return
	recording_key=key;selected_key=key;_local_started=Time.get_ticks_msec();_local_ended=0
	_refresh_history();_load_form();_state.text="Recording · take the shot, then press Space";_capture_button.text="End shot  [Space]"


func _preset_clicked(field: String, code: String, button: Button) -> void:
	if _updating or selected_key.is_empty():return
	var annotation:=client.annotation_for(selected_key).duplicate(true)
	annotation[field]=code if button.button_pressed else null
	client.set_annotation(selected_key,annotation);_save_at=Time.get_ticks_msec()+500


func _notes_changed() -> void:
	if _updating or selected_key.is_empty():return
	var annotation:=client.annotation_for(selected_key).duplicate(true)
	annotation.notes=_notes.text if not _notes.text.strip_edges().is_empty() else null
	client.set_annotation(selected_key,annotation);_save_at=Time.get_ticks_msec()+500


func _flush_current() -> void:
	_save_at=-1
	if client!=null and not selected_key.is_empty():client.save_annotation(selected_key)


func _refresh_history() -> void:
	if client==null:return
	_keys=client.sorted_keys();_history.clear()
	for key in _keys:
		var row: Dictionary=client.records[key]
		var stamp:=int(row.get("started",{}).get("unix_time_ms",0))/1000
		var label:=Time.get_datetime_string_from_unix_time(stamp).replace("T"," ")
		_history.add_item(label+" · "+str(row.get("state","unknown")).capitalize())
		_history.set_item_tooltip(_history.item_count-1,str(row.get("capture_id"))+"\n"+_description(client.annotation_for(key)))
		if key==selected_key:_history.select(_history.item_count-1)
	_older.disabled=not client.connected or client.next_offset==null


func _select_index(index: int) -> void:
	if index<0 or index>=_keys.size():return
	_flush_current();selected_key=_keys[index];_load_form()
	if client.connected:
		var record: Dictionary=client.records[selected_key]
		client.request("capture_get",{"session_id":record.session_id,"capture_id":record.capture_id})


func _description(annotation: Dictionary) -> String:
	var labels: Array[String]=[]
	for field in ["speed","elevation","direction"]:
		var text:="Not set"
		for choice in CHOICES[field]:
			if annotation.get(field)==choice[0]:text=choice[1];break
		labels.append(str(field).capitalize()+": "+text)
	labels.append("Notes: "+str(annotation.notes) if annotation.get("notes")!=null else "Notes: None")
	return " · ".join(labels)


func _load_form() -> void:
	_updating=true
	var annotation: Dictionary=client.annotation_for(selected_key) if client!=null else {}
	for field in _presets:
		for code in _presets[field]:
			var button: Button=_presets[field][code];button.disabled=selected_key.is_empty();button.set_pressed_no_signal(annotation.get(field)==code)
	_notes.editable=not selected_key.is_empty()
	var text:=str(annotation.get("notes","")) if annotation.get("notes")!=null else ""
	if _notes.text!=text:_notes.text=text
	_summary.text=_description(annotation) if not selected_key.is_empty() else "Press Space to create the first shot. Estimates and notes can be filled in afterwards."
	_updating=false;_update_saved_status()
	_update_detector_guess()
	if client==null or not client.records.has(selected_key):_timing.text="";return
	var record: Dictionary=client.records[selected_key]
	var end: Variant=record.get("ended")
	var duration: String="%.2f s"%float(record.duration_s) if record.get("duration_s")!=null else "Not ended"
	_timing.text="Window: %s · %s frames / %s points · detector: %s confirmed, %s unconfirmed attempts\n%s"%[duration,str(record.get("frame_count",0)),str(record.get("point_count",0)),str(record.get("confirmed_balls",0)),str(record.get("rejected_attempts",0)),str(record.get("capture_file","Awaiting radar acknowledgement…"))]
	if end is Dictionary:_timing.text+="\nRadar log time %.3f → %.3f s · frames %s → %s"%[float(record.started.get("elapsed_s",0)),float(end.get("elapsed_s",0)),str(record.get("first_frame")),str(record.get("last_frame"))]


func _update_detector_guess() -> void:
	var record: Dictionary=client.records.get(selected_key,{}) if client!=null else {}
	var guess: Variant=record.get("detector_guess")
	if not guess is Dictionary or not guess.get("speed_mps") is float and not guess.get("speed_mps") is int:
		_detector_guess.text="Detector estimate · no ball registered" if record.get("ended")!=null else "Detector estimate · no ball registered yet"
		_detector_guess.add_theme_color_override("font_color",AppStyle.MUTED);return
	var speed:=float(guess.get("speed_mps",0));var direction:=float(guess.get("direction_deg",0));var elevation:=float(guess.get("elevation_deg",0))
	var heading:="%.1f° %s"%[absf(direction),"left" if direction<0 else "right"]
	if is_zero_approx(direction):heading="0.0° straight"
	var caption:="Recorded detector estimate" if record.get("ended")!=null else "Detector registered"
	_detector_guess.text=caption+" · ≈ %.1f m/s (%.1f km/h) · elevation ≈ %.1f° · direction ≈ %s"%[speed,speed*3.6,elevation,heading]
	if guess.get("observations") is float or guess.get("observations") is int:
		_detector_guess.text+=" · %d observations"%int(guess.observations)
		if int(guess.observations)<=3:_detector_guess.text+=" (short track; angles approximate)"
	if record.get("detector_last_result")=="no_ball_detected":_detector_guess.text+="\nLater motion was unconfirmed; the registered estimate above is retained."
	_detector_guess.add_theme_color_override("font_color",Color("a6e2b8"))


func _update_saved_status() -> void:
	if client==null or selected_key.is_empty():_saved.text="Other notes default to None.";return
	if client.drafts.has(selected_key):
		if not client.local_backup_ok:_saved.text="Draft is in memory · save/export before leaving"
		else:_saved.text="Description saved locally · syncing…" if client.connected else "Description saved locally · reconnect to sync"
	elif client.records[selected_key].get("state")=="starting":_saved.text="Waiting for capture acknowledgement…"
	else:_saved.text="Description saved with radar logs"


func _on_record(key: String) -> void:
	_refresh_history()
	if key==ending_key and client.records[key].get("ended")!=null:
		ending_key="";_state.text="Shot captured · choose your estimates below";_capture_button.text="Start next shot  [Space]"
	if key==selected_key:_load_form()


func _on_info(message: Dictionary) -> void:
	_refresh_history()
	if selected_key.is_empty() and not _keys.is_empty():selected_key=_keys[0]
	if not recording_key.is_empty() and message.get("active_capture_id")!=client.records.get(recording_key,{}).get("capture_id"):
		recording_key="";ending_key=""
	_status.text="Connected · timings and notes save to "+client.recording_directory
	if recording_key.is_empty() and ending_key.is_empty():_state.text="Ready · press Space before your shot"
	_load_form()


func _on_connection(message: String) -> void:
	_status.text=message
	if not client.connected:
		if not recording_key.is_empty() or not ending_key.is_empty():_show_message("Connection lost during capture. Reconnect to load the saved/interrupted window and finish its notes.")
		recording_key="";ending_key=""
		_state.text="Connect to start a timed capture"
	_update_saved_status()


func _on_status(message: Dictionary) -> void:
	if message.get("notes_mode")!=true:_status.text="Restart the updated Rust live service to enable shot notes."
	elif message.get("radar_ready")!=true:_status.text="Connected · waiting for radar frames. Timed windows and notes are still saved."
	else:_status.text="Connected · timings and notes save to "+client.recording_directory


func _on_error(message: Dictionary) -> void:
	if message.get("operation")=="capture_start":recording_key="";ending_key=""
	elif message.get("operation")=="capture_end":recording_key=ending_key;ending_key=""
	_state.text="Capture status needs attention · see the message below"
	if client.connected:
		if message.get("operation")=="capture_annotate":client.request("capture_get",{"session_id":message.get("session_id"),"capture_id":message.get("capture_id")})
		elif message.get("operation")!="capture_get":client.request("notes_list")


func _process(_delta: float) -> void:
	if not interactive or client==null:return
	_capture_button.disabled=not client.connected or client.session_id.is_empty() or not ending_key.is_empty()
	if _save_at>=0 and Time.get_ticks_msec()>=_save_at:_flush_current()
	if not recording_key.is_empty():
		_capture_button.text="End shot  [Space]";_clock.text="%.1f s"%((Time.get_ticks_msec()-_local_started)/1000.0)
	elif not ending_key.is_empty():_clock.text="%.1f s"%((_local_ended-_local_started)/1000.0)
	else:
		_capture_button.text="Start next shot  [Space]" if not selected_key.is_empty() else "Start shot  [Space]"
		if client.records.has(selected_key) and client.records[selected_key].get("duration_s")!=null:_clock.text="%.1f s"%float(client.records[selected_key].duration_s)


func _input(event: InputEvent) -> void:
	if not interactive or not event is InputEventKey or not event.pressed or event.echo or event.physical_keycode!=KEY_SPACE:return
	var focus:=get_viewport().gui_get_focus_owner()
	if focus is TextEdit or focus is LineEdit:return
	toggle_capture();get_viewport().set_input_as_handled()


func selected_summary() -> Dictionary:
	if client==null or not client.records.has(selected_key):return {}
	var result: Dictionary=client.records[selected_key].duplicate(true);result.annotation=client.annotation_for(selected_key)
	result["description"]=_description(result.annotation);result["pending_sync"]=client.drafts.has(selected_key);return result


func _copy_summary() -> void:
	DisplayServer.clipboard_set(JSON.stringify(selected_summary(),"  ",true,true));_show_message("Shot description and log window copied.")


func export_selected(path: String) -> void:
	var value:=selected_summary()
	if value.is_empty():_show_message("Select a captured shot first.");return
	var file:=FileAccess.open(path,FileAccess.WRITE)
	if file==null:_show_message("Cannot save shot notes to this location.");return
	file.store_string(JSON.stringify(value,"  ",true,true));_show_message("Shot notes exported: "+path)


func _show_message(message: String) -> void:
	if _message:_message.text=message
