class_name RadarDebugRange
extends Node3D
## Instrument view: a movie of radar observations and the decisions made on them.
signal menu_requested
var auto_connect := true
var interactive := true
var client: RadarDebugClient
var live_data := RadarDebugData.new()
var data: RadarDebugData
var view: RadarDebugViewport
var ui_layer: CanvasLayer
var playing := true
var follow_live := true
var playback_rate := .5
var play_time := 0.0
var cursor := -1
var selected_report: Dictionary = {}
var selected_attempt: Dictionary = {}
var selected_point := ""
var _clip_start := 0.0
var _clip_end := INF
var _archive_request := ""
var _archive_data: RadarDebugData
var _archive_session := ""
var _archive_attempts: Array = []
var _sessions: Array = []
var _session_id := ""
var _attempt_signature := ""
var _remote_list := false
var _updating := false
var _status: Label
var _source: Label
var _frame_label: Label
var _counts: Label
var _message: Label
var _host: LineEdit
var _port: SpinBox
var _sessions_box: OptionButton
var _attempt_list: ItemList
var _hypotheses: OptionButton
var _details: RichTextLabel
var _timeline: HSlider
var _play: Button
var _loop: CheckBox
var _freeze: CheckBox
var _before: SpinBox
var _after: SpinBox
var _note: LineEdit
var _open_folder: FileDialog
var _open_clip: FileDialog
var _save_clip: FileDialog


func _ready() -> void:
	data=live_data
	client=RadarDebugClient.new();add_child(client)
	client.info_received.connect(_on_info);client.frame_received.connect(_on_frame)
	client.attempt_received.connect(_on_attempt);client.message_received.connect(_on_message)
	client.connection_changed.connect(func(text: String):_status.text=text)
	client.failed.connect(_show_message)
	_build_ui()
	var args:=OS.get_cmdline_user_args();var index:=args.find("--radar-session")
	if index>=0 and index+1<args.size():open_recording(args[index+1])
	elif auto_connect:_connect_live()


func _button(parent: Node, text: String, action: Callable, primary:=false) -> Button:
	var button:=AppStyle.button(text,primary);button.custom_minimum_size.y=34
	button.pressed.connect(action);parent.add_child(button);return button


func _check(parent: Node, text: String, enabled: bool, action: Callable) -> CheckBox:
	var check:=CheckBox.new();check.text=text;check.button_pressed=enabled;parent.add_child(check)
	check.toggled.connect(action);return check


func _build_ui() -> void:
	ui_layer=CanvasLayer.new();ui_layer.layer=25;add_child(ui_layer)
	var root:=PanelContainer.new();root.theme=AppStyle.theme();ui_layer.add_child(root);AppStyle.full_rect(root)
	root.add_theme_stylebox_override("panel",AppStyle.box(Color("0b1b23"),0,Color.TRANSPARENT,14))
	var column:=VBoxContainer.new();column.add_theme_constant_override("separation",9);root.add_child(column)
	var header:=HBoxContainer.new();column.add_child(header)
	var title:=AppStyle.label("Radar debug range",27,AppStyle.CREAM,true);title.size_flags_horizontal=Control.SIZE_EXPAND_FILL;header.add_child(title)
	_button(header,"← Main menu",func():menu_requested.emit())
	_source=AppStyle.label("Raw radar points · metres · not a camera image",13,AppStyle.MUTED);column.add_child(_source)
	_status=AppStyle.label("Open a recording or connect to the radar service.",13,AppStyle.GOLD);column.add_child(_status)
	var body:=HBoxContainer.new();body.size_flags_vertical=Control.SIZE_EXPAND_FILL;body.add_theme_constant_override("separation",10);column.add_child(body)
	var left_panel:=PanelContainer.new();left_panel.custom_minimum_size.x=240;left_panel.add_theme_stylebox_override("panel",AppStyle.box(Color("102832"),10,Color("ffffff16"),12));body.add_child(left_panel)
	var left_scroll:=ScrollContainer.new();left_scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED;left_panel.add_child(left_scroll)
	var left:=VBoxContainer.new();left.size_flags_horizontal=Control.SIZE_EXPAND_FILL;left.size_flags_vertical=Control.SIZE_EXPAND_FILL;left.add_theme_constant_override("separation",8);left_scroll.add_child(left)
	left.add_child(AppStyle.label("CAPTURE & RECORDINGS",11,AppStyle.GOLD))
	_host=LineEdit.new();_host.text=str(GameSettings.get_value("radar_host"));_host.placeholder_text="Radar host";left.add_child(_host)
	var connection_row:=HBoxContainer.new();left.add_child(connection_row)
	_port=SpinBox.new();_port.min_value=1;_port.max_value=65535;_port.step=1;_port.value=int(GameSettings.get_value("radar_port"));_port.custom_minimum_size.x=100;connection_row.add_child(_port)
	_button(connection_row,"Connect",_connect_live,true)
	var files:=HBoxContainer.new();left.add_child(files)
	_button(files,"Open folder",func():_open_folder.popup_centered_ratio(.7))
	_button(files,"Open clip",func():_open_clip.popup_centered_ratio(.7))
	var sessions_row:=HBoxContainer.new();left.add_child(sessions_row)
	_sessions_box=OptionButton.new();_sessions_box.size_flags_horizontal=Control.SIZE_EXPAND_FILL;_sessions_box.add_item("Live capture");_sessions_box.clip_text=true;sessions_row.add_child(_sessions_box)
	_sessions_box.item_selected.connect(_select_session)
	_button(sessions_row,"↻",_refresh_sessions)
	var context:=HBoxContainer.new();left.add_child(context)
	context.add_child(AppStyle.label("Before / after",12,AppStyle.MUTED))
	_before=_seconds(context,.5);_after=_seconds(context,.5)
	_before.value_changed.connect(func(_v: float):_reload_selection());_after.value_changed.connect(func(_v: float):_reload_selection())
	_button(left,"Clip around current frame",_clip_around_cursor)
	_freeze=_check(left,"Replay each new attempt",true,func(_value: bool):pass)
	left.add_child(AppStyle.label("ATTEMPTS · includes unconfirmed hits",12,AppStyle.CREAM))
	_attempt_list=ItemList.new();_attempt_list.size_flags_vertical=Control.SIZE_EXPAND_FILL;_attempt_list.custom_minimum_size.y=100
	_attempt_list.add_theme_font_size_override("font_size",13);left.add_child(_attempt_list);_attempt_list.item_selected.connect(_select_attempt)
	_note=LineEdit.new();_note.placeholder_text="Optional debugging note";_note.max_length=512;left.add_child(_note)
	var marks:=HBoxContainer.new();left.add_child(marks)
	_button(marks,"Mark live hit",func():_mark("ball_hit"))
	_button(marks,"Dry swing",func():_mark("dry_swing"))
	_button(left,"Export selected clip…",func():_save_clip.popup_centered_ratio(.6))
	var center:=VBoxContainer.new();center.size_flags_horizontal=Control.SIZE_EXPAND_FILL;body.add_child(center)
	var camera_row:=HBoxContainer.new();center.add_child(camera_row)
	for name in ["Orbit","Top","Side","Front"]:_button(camera_row,name,func():view.preset(name))
	_button(camera_row,"Fit",func():view.fit_view())
	_check(camera_row,"Ortho",false,func(value: bool):view.orthographic=value;view.update_pose())
	view=RadarDebugViewport.new();view.size_flags_vertical=Control.SIZE_EXPAND_FILL;view.size_flags_horizontal=Control.SIZE_EXPAND_FILL;view.custom_minimum_size=Vector2(320,220);center.add_child(view)
	view.point_selected.connect(_on_point_selected)
	center.add_child(AppStyle.label("Right drag · orbit     Middle drag · pan     Wheel · zoom     Click · inspect a point",11,AppStyle.MUTED))
	_frame_label=AppStyle.label("No radar frames yet",13,AppStyle.CREAM);center.add_child(_frame_label)
	_counts=AppStyle.label("Green: selected ball  ·  Purple: club evidence  ·  Orange: inspected candidate  ·  Gold: fitted model",11,AppStyle.MUTED)
	_counts.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;center.add_child(_counts)
	var right_panel:=PanelContainer.new();right_panel.custom_minimum_size.x=280;right_panel.add_theme_stylebox_override("panel",AppStyle.box(Color("102832"),10,Color("ffffff16"),12));body.add_child(right_panel)
	var right_scroll:=ScrollContainer.new();right_scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED;right_panel.add_child(right_scroll)
	var right:=VBoxContainer.new();right.size_flags_horizontal=Control.SIZE_EXPAND_FILL;right.size_flags_vertical=Control.SIZE_EXPAND_FILL;right.add_theme_constant_override("separation",8);right_scroll.add_child(right)
	right.add_child(AppStyle.label("WHAT THE DETECTOR CONSIDERED",11,AppStyle.GOLD))
	_hypotheses=OptionButton.new();_hypotheses.clip_text=true;_hypotheses.custom_minimum_size.x=250;right.add_child(_hypotheses);_hypotheses.item_selected.connect(_select_hypothesis)
	var mode:=OptionButton.new();for text in ["Color: Doppler speed","Color: point eligibility","Color: SNR"]:mode.add_item(text)
	right.add_child(mode);mode.item_selected.connect(func(index: int):view.color_mode=index;_redraw())
	_check(right,"Include background / rejected points",true,func(value: bool):view.show_filtered=value;_redraw())
	_check(right,"All considered trajectories",false,func(value: bool):view.show_all_hypotheses=value;_redraw())
	_check(right,"Show whole-attempt trajectories",false,func(value: bool):view.full_trajectories=value;_redraw())
	var trail_row:=HBoxContainer.new();right.add_child(trail_row);trail_row.add_child(AppStyle.label("Point persistence (s)",12,AppStyle.MUTED))
	var trail:=_seconds(trail_row,.3);trail.max_value=2;trail.value_changed.connect(func(value: float):view.trail_s=value;_redraw())
	var size_row:=HBoxContainer.new();right.add_child(size_row);size_row.add_child(AppStyle.label("Marker radius (m)",12,AppStyle.MUTED))
	var dots:=SpinBox.new();dots.min_value=.005;dots.max_value=.15;dots.step=.005;dots.value=.025;size_row.add_child(dots)
	dots.value_changed.connect(func(value: float):view.dot_radius=value;_redraw())
	_details=RichTextLabel.new();_details.bbcode_enabled=false;_details.selection_enabled=true;_details.size_flags_vertical=Control.SIZE_EXPAND_FILL
	_details.custom_minimum_size=Vector2(250,150);_details.add_theme_font_size_override("normal_font_size",13);right.add_child(_details)
	_button(right,"Copy diagnostic summary",_copy_summary)
	_timeline=HSlider.new();_timeline.step=1;_timeline.min_value=0;_timeline.max_value=1;column.add_child(_timeline)
	_timeline.value_changed.connect(_scrub)
	var controls:=HBoxContainer.new();column.add_child(controls)
	_button(controls,"◀ Frame",func():step_frame(-1))
	_play=_button(controls,"Pause",_toggle_play)
	_button(controls,"Frame ▶",func():step_frame(1))
	var rate:=OptionButton.new();controls.add_child(rate)
	for value in [.1,.25,.5,1.0,2.0]:rate.add_item(str(value)+"×")
	rate.select(2);rate.item_selected.connect(func(index: int):playback_rate=[.1,.25,.5,1.0,2.0][index])
	_loop=_check(controls,"Loop",true,func(_value: bool):pass)
	_button(controls,"● Follow live",_follow,true)
	_button(controls,"All loaded frames",_whole_recording)
	_message=AppStyle.label("All unclassified returns can include the club, people and reflections. They are not automatically labelled objects.",11,AppStyle.MUTED)
	_message.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;_message.size_flags_horizontal=Control.SIZE_EXPAND_FILL;controls.add_child(_message)
	_open_folder=FileDialog.new();_open_folder.access=FileDialog.ACCESS_FILESYSTEM;_open_folder.file_mode=FileDialog.FILE_MODE_OPEN_DIR;_open_folder.title="Open radar recording folder"
	ui_layer.add_child(_open_folder);_open_folder.dir_selected.connect(open_recording)
	_open_clip=FileDialog.new();_open_clip.access=FileDialog.ACCESS_FILESYSTEM;_open_clip.file_mode=FileDialog.FILE_MODE_OPEN_FILE;_open_clip.filters=PackedStringArray(["*.json ; Pinewater radar clip"])
	ui_layer.add_child(_open_clip);_open_clip.file_selected.connect(open_clip)
	_save_clip=FileDialog.new();_save_clip.access=FileDialog.ACCESS_FILESYSTEM;_save_clip.file_mode=FileDialog.FILE_MODE_SAVE_FILE;_save_clip.filters=PackedStringArray(["*.json ; Pinewater radar clip"]);_save_clip.current_file="radar-clip.json"
	ui_layer.add_child(_save_clip);_save_clip.file_selected.connect(save_clip)
	_update_details()


func _seconds(parent: Node, initial: float) -> SpinBox:
	var value:=SpinBox.new();value.min_value=0;value.max_value=10;value.step=.1;value.value=initial;value.custom_minimum_size.x=65;parent.add_child(value);return value


func set_interactive(enabled: bool, _menu_mode:=false) -> void:
	interactive=enabled
	if ui_layer:ui_layer.visible=enabled
	if view and view.viewport:view.viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS if enabled else SubViewport.UPDATE_DISABLED
	if not enabled and client:client.disconnect_from()
	elif enabled and auto_connect and client and client.peer==null and data==live_data:_connect_live()


func _connect_live() -> void:
	GameSettings.set_value("radar_host",_host.text.strip_edges());GameSettings.set_value("radar_port",int(_port.value))
	client.connect_to(_host.text,int(_port.value))


func _on_info(message: Dictionary) -> void:
	var id:=str(message.get("session_id",""))
	if not _session_id.is_empty() and _session_id!=id:
		var was_live:=data==live_data;live_data=RadarDebugData.new()
		if was_live:data=live_data;cursor=-1;selected_report={};selected_attempt={}
	_session_id=id;live_data.configuration=message.get("configuration",{});live_data.label="Live · "+id
	_status.text="Live capture connected · every raw return is recorded on the radar computer."
	_refresh_sessions()


func _on_frame(frame: Dictionary, source: String, request_id: String) -> void:
	if source=="archive":
		if request_id==_archive_request and _archive_data:_archive_data.add_frame(frame)
	else:
		live_data.add_frame(frame)
		if data==live_data and follow_live:cursor=live_data.last_index();play_time=live_data.time_at(cursor);_redraw()


func _on_attempt(report: Dictionary, timestamp: float, id: int, source: String, request_id: String) -> void:
	if source=="archive":
		if request_id==_archive_request and _archive_data:_archive_data.add_attempt(report,timestamp,id)
		return
	live_data.add_attempt(report,timestamp,id)
	if data==live_data and not _remote_list:
		_update_attempts()
		if _freeze.button_pressed and not live_data.attempts.is_empty():_select_attempt(live_data.attempts.size()-1)


func _on_message(message: Dictionary) -> void:
	match str(message.get("type","")):
		"status":
			if message.get("debug")!=true:
				_status.text="This backend has no debug subscription. Restart the updated Rust live service."
			elif message.get("radar_ready")!=true:_status.text="Connected · waiting for radar frames"
			else:_status.text="Capturing raw radar · stream gaps: %d frames / %d reports · full capture saved"%[int(message.get("debug_dropped_frames",0)),int(message.get("debug_dropped_reports",0))]
		"debug_sessions":
			_sessions=message.get("sessions",[]);_sessions_box.clear();_sessions_box.add_item("Live capture")
			var selected:=0
			for session in _sessions:
				var id:=str(session.get("id",""));var seconds:=int(id.get_slice("-",0).to_int()/1000000000)
				_sessions_box.add_item(Time.get_datetime_string_from_unix_time(seconds).replace("T"," ")+ (" · current" if session.get("current")==true else ""))
				if _remote_list and id==_archive_session:selected=_sessions_box.item_count-1
			_sessions_box.select(selected)
		"debug_attempts":
			if str(message.get("session_id"))!=_archive_session:return
			_archive_attempts=message.get("attempts",[]);_remote_list=true;_update_attempts()
			_show_message("Saved recording · %d frames / %d attempts. Select an attempt to load its 3D clip."%[int(message.get("frame_count",0)),_archive_attempts.size()])
			if int(message.get("omitted_older_attempts",0))>0:_show_message("Showing the latest 1000 attempts. Open the recording folder locally to index all attempts.")
		"debug_clip_begin":
			if str(message.get("request_id"))!=_archive_request:return
			_archive_data=RadarDebugData.new();_archive_data.label="Recording · "+str(message.get("session_id",""));_archive_data.configuration=message.get("configuration",{})
			_show_message("Loading recorded clip…")
		"debug_clip_end":
			if str(message.get("request_id"))!=_archive_request or _archive_data==null:return
			if _archive_data.empty():_show_message("This attempt has no recorded frames.");return
			data=_archive_data;selected_attempt=data.attempts[0] if not data.attempts.is_empty() else {};selected_report=data.report_at(selected_attempt) if not selected_attempt.is_empty() else {}
			_start_window(data.time_at(data.first_index()),data.time_at(data.last_index()));_load_hypotheses();view.fit_view();_show_message("Recorded clip ready. Live capture continues in the background.")
		"debug_error":_show_message(str(message.get("message","Unknown archive error")))
		"debug_marked":_show_message("Operator label saved in the radar recording: "+str(message.get("label","")).replace("_"," "))


func _refresh_sessions() -> void:
	if client.connected:client.request("debug_sessions")
	else:_show_message("Connect to browse recordings on the radar computer, or open a local folder.")


func _select_session(index: int) -> void:
	_archive_request="";_archive_data=null
	if index==0:_follow();return
	_archive_session=str(_sessions[index-1].get("id",""));_remote_list=true;_archive_attempts=[];_update_attempts()
	client.request("debug_attempts",{"session_id":_archive_session});_show_message("Indexing saved recording…")


func _update_attempts() -> void:
	_attempt_list.clear()
	var values: Array=_archive_attempts if _remote_list else data.attempts
	for attempt in values:
		var outcome:=str(attempt.get("outcome","unknown"));var label:="BALL" if outcome=="ball_detected" else ("INTERRUPTED" if outcome=="aborted" else "UNCONFIRMED")
		var report: Dictionary=attempt.get("report",{})
		if report.has("operator_label"):label="MARK · "+str(report.operator_label).replace("_"," ")
		if outcome=="operator_mark":label="MARK · "+str(attempt.get("operator_label",report.get("operator_label","operator"))).replace("_"," ")
		_attempt_list.add_item("#%s   %s   %.2fs"%[str(attempt.get("id","?")),label,float(attempt.get("start_time_s",0))])
		_attempt_list.set_item_custom_fg_color(_attempt_list.item_count-1,RadarDebugViewport.BALL if outcome=="ball_detected" else AppStyle.MUTED)
	_attempt_signature="%d/%d/%s"%[values.size(),data.base_index,str(_remote_list)]


func _select_attempt(index: int) -> void:
	if _remote_list:
		if index<0 or index>=_archive_attempts.size():return
		_archive_request=client.request("debug_clip",{"session_id":_archive_session,"attempt_id":_archive_attempts[index].id,"before_s":_before.value,"after_s":_after.value})
		_archive_data=null;_show_message("Loading raw frames and detection hypotheses…");return
	if index<0 or index>=data.attempts.size():return
	selected_attempt=data.attempts[index];selected_report=data.report_at(selected_attempt);selected_point=""
	if float(selected_attempt.end_time_s)<data.time_at(data.first_index()):_show_message("This attempt has expired from the live buffer. Select its saved session to reload it.");return
	_start_window(float(selected_attempt.start_time_s)-_before.value,float(selected_attempt.end_time_s)+_after.value)
	_load_hypotheses();_attempt_list.select(index)


func _reload_selection() -> void:
	var selected:=_attempt_list.get_selected_items()
	if not selected.is_empty():_select_attempt(selected[0])


func _start_window(start: float, end: float) -> void:
	_clip_start=maxf(start,data.time_at(data.first_index()));_clip_end=end
	follow_live=false;playing=true;play_time=_clip_start;cursor=data.index_at_time(play_time)
	_play.text="Pause";_redraw()


func _load_hypotheses() -> void:
	_hypotheses.clear();_hypotheses.add_item("Selected ball / detector result")
	for track in selected_report.get("tracks",[]):
		_hypotheses.add_item("#%s · %d pts · %s"%[str(track.get("track_id","?")),track.get("observations",[]).size(),str(track.get("rejection_reason","candidate"))])
	var popup:=_hypotheses.get_popup();popup.max_size.y=420
	_hypotheses.select(0);_select_hypothesis(0)


func _select_hypothesis(index: int) -> void:
	var track: Dictionary={}
	if index>0 and index<=selected_report.get("tracks",[]).size():track=selected_report.tracks[index-1]
	view.set_report(selected_report,track);_update_details()


func _follow() -> void:
	data=live_data;_remote_list=false;_archive_request="";selected_attempt={};selected_report={};selected_point=""
	follow_live=true;playing=true;_clip_end=INF;_play.text="Pause";_sessions_box.select(0)
	if not data.empty():cursor=data.last_index();play_time=data.time_at(cursor)
	_update_attempts();_load_hypotheses();_redraw()


func _toggle_play() -> void:
	if data.empty():return
	if follow_live:follow_live=false;_clip_start=data.time_at(data.first_index());_clip_end=data.time_at(data.last_index())
	playing=not playing;_play.text="Pause" if playing else "Play"
	_redraw()


func _whole_recording() -> void:
	if data.empty():return
	selected_report={};selected_attempt={};selected_point="";follow_live=false;playing=false;_play.text="Play"
	_attempt_list.deselect_all()
	_clip_start=data.time_at(data.first_index());_clip_end=data.time_at(data.last_index());_load_hypotheses();_redraw()


func _clip_around_cursor() -> void:
	if data.empty():return
	var timestamp:=data.time_at(cursor)
	_start_window(timestamp-_before.value,timestamp+_after.value)
	_show_message("Context window selected around this frame. Export it with a note to investigate an untriggered hit.")


func _scrub(value: float) -> void:
	if _updating or data.empty():return
	follow_live=false;playing=false;_play.text="Play";cursor=clampi(int(value),data.first_index(),data.last_index());play_time=data.time_at(cursor);_redraw()


func step_frame(direction: int) -> void:
	if data.empty():return
	_scrub(clampi(cursor+direction,maxi(data.first_index(),int(_timeline.min_value)),mini(data.last_index(),int(_timeline.max_value))))


func _process(delta: float) -> void:
	if not interactive:return
	if data.loading:
		data.step_index();_status.text="Indexing recording · %d frames / %d attempts…"%[data.frames.size(),data.attempts.size()]
		if not data.loading:
			if not data.error.is_empty():_show_message(data.error)
			elif not data.empty():
				_clip_start=data.time_at(data.first_index());_clip_end=data.time_at(data.last_index());play_time=_clip_start;cursor=data.first_index();_update_attempts()
				if not data.attempts.is_empty():_select_attempt(0)
				else:playing=false;_redraw()
				view.fit_view();_status.text="Recording indexed · %d frames / %d attempts"%[data.frames.size(),data.attempts.size()]
		return
	if data.empty():return
	if not follow_live and playing:
		play_time+=delta*playback_rate
		var end:=minf(_clip_end,data.time_at(data.last_index()))
		if play_time>end:
			if data==live_data and _clip_end>data.time_at(data.last_index()):play_time=end
			elif _loop.button_pressed:play_time=maxf(_clip_start,data.time_at(data.first_index()))
			else:play_time=end;playing=false;_play.text="Play"
		var next:=data.index_at_time(play_time)
		if next!=cursor:cursor=next;_redraw()
	elif cursor<data.first_index():
		cursor=data.first_index();play_time=data.time_at(cursor);selected_report={};selected_attempt={};_load_hypotheses();_redraw()
		_show_message("Paused live history expired from memory. Reload the complete attempt from its saved session.")
	var signature:="%d/%d/%s"%[(_archive_attempts if _remote_list else data.attempts).size(),data.base_index,str(_remote_list)]
	if signature!=_attempt_signature:_update_attempts()


func _redraw() -> void:
	if data==null or view==null:return
	if data.empty():
		view.data=data;view.cursor=-1;view.refresh();_frame_label.text="No radar frames loaded";_source.text=data.label;return
	cursor=clampi(cursor,data.first_index(),data.last_index());view.data=data;view.cursor=cursor;view.refresh()
	var first: int=data.index_at_time(maxf(_clip_start,data.time_at(data.first_index()))) if not follow_live else data.first_index()
	var last: int=data.index_at_time(minf(_clip_end,data.time_at(data.last_index()))) if not follow_live else data.last_index()
	view.fit_start_index=first;view.fit_end_index=last
	_updating=true;_timeline.min_value=first;_timeline.max_value=maxi(first+1,last);_timeline.value=cursor;_updating=false
	var frame:=data.frame_at(cursor);var diagnostics: Dictionary=frame.get("diagnostics",{})
	_frame_label.text="Frame %s  ·  %.3f s  ·  %d raw points  ·  %s"%[str(diagnostics.get("frame_number","?")),data.time_at(cursor),diagnostics.get("points",[]).size(),"LIVE" if follow_live else ("PLAY" if playing else "PAUSED")]
	_source.text=data.label+"   |   radar X → right, Y → downrange, Z → height   |   1 m grid at radar Z=0"
	if data==live_data and data.discarded_frames>0:_source.text+=" · older frames available in saved recording"
	if not data.warning.is_empty():_show_message(data.warning)
	if not data.error.is_empty():_show_message(data.error)
	if not view.display_note.is_empty():_show_message(view.display_note)


func _on_point_selected(point: Dictionary, number: int, timestamp: float, role: String) -> void:
	var reason: String=str(point.ball_rejection).replace("_"," ") if point.get("ball_rejection")!=null else "passed motion eligibility gate"
	selected_point="POINT INSPECTOR\n%s\nFrame %d · %.3f s\nX %s m   Y %s m   Z %s m\nRadial speed %s m/s\nSNR %s dB · noise %s dB\nPoint gate: %s\n"%[role,number,timestamp,_number(point.get("x")),_number(point.get("y")),_number(point.get("z")),_number(point.get("radial_velocity")),_number(point.get("snr_db")),_number(point.get("noise_db")),reason]
	_update_details()


func _number(value: Variant) -> String:
	return "%.3f"%float(value) if (value is float or value is int) and is_finite(float(value)) else "not supplied"


func _update_details() -> void:
	if _details==null:return
	var text:=selected_point
	if selected_report.is_empty():
		_details.text=text+"\nSelect an attempt to see its decision, candidate trajectories and fit diagnostics.\n\nRaw points are measurements, not labelled golf balls or people. Mark live hits/dry swings to save operator labels for debugging."
		return
	text+="\nDETECTOR RESULT\n"+str(selected_report.get("outcome","unknown")).replace("_"," ").to_upper()+"\n"
	if selected_report.has("operator_label"):text+="Operator label: "+str(selected_report.operator_label)+"\n"+str(selected_report.get("operator_note",""))+"\n"
	text+="%s frames · %s raw points\n%s motion candidates · %d hypotheses\n"%[str(selected_report.get("frames_evaluated","?")),str(selected_report.get("points_evaluated","?")),str(selected_report.get("ball_candidates","?")),selected_report.get("tracks",[]).size()]
	for reason in selected_report.get("point_rejections",{}):text+="  %s: %s\n"%[str(reason).replace("_"," "),str(selected_report.point_rejections[reason])]
	var track: Dictionary=view.track
	if not track.is_empty():text+="\nINSPECTED HYPOTHESIS #%s\n%s observations\nReason: %s\n"%[str(track.get("track_id")),str(track.get("observations",[]).size()),str(track.get("rejection_reason","accepted candidate")).replace("_"," ")]
	var fit: Variant=track.get("fit",selected_report.get("selected_fit"))
	if fit is Dictionary:
		text+="\nFIT DIAGNOSTICS\nNormalized residual: %.3f\nAcceptance limit: %.3f\nVelocity XYZ (m/s): %s\nVelocity σ XYZ: %s\nMax XYZ error: %s m\nMax Doppler error: %s m/s\n"%[float(fit.get("reduced_chi_squared",0)),float(fit.get("chi_squared_limit",0)),str(fit.get("velocity",[])),str(fit.get("velocity_std_mps",[])),str(fit.get("max_position_residual_m","?")),str(fit.get("max_doppler_residual_mps","?"))]
	var evidence: Variant=track.get("club_evidence",selected_report.get("selected_club_evidence"))
	if evidence is Dictionary:
		text+="\nCLUB / FLIGHT SEPARATION\nSimultaneous frames: %s\nLaunch frame: %s\nRelative velocity gain: %s m/s\nRequired velocity gain: %s m/s\nDistance gain: %s m\nRequired distance gain: %s m\n"%[str(evidence.get("simultaneous_frames")),str(evidence.get("launch_frame")),str(evidence.get("relative_velocity_gain_mps")),str(evidence.get("required_velocity_gain_mps")),str(evidence.get("separation_distance_gain_m")),str(evidence.get("required_distance_gain_m"))]
	_details.text=text


func _copy_summary() -> void:
	DisplayServer.clipboard_set(JSON.stringify({"configuration":data.configuration,"frame":data.frame_at(cursor) if not data.empty() else {},"result":selected_report.get("outcome"),"hypothesis":view.track,"selected_fit":selected_report.get("selected_fit"),"operator_note":_note.text},"  "))
	_show_message("Diagnostic summary copied.")


func _mark(label: String) -> void:
	if live_data.empty():_show_message("No live frames to mark. Connect to the radar first.");return
	data=live_data;_remote_list=false;_archive_request=""
	var end:=data.time_at(data.last_index());var start:=maxf(data.time_at(data.first_index()),end-3.0)
	var first:=data.frame_at(data.index_at_time(start));var last:=data.frame_at(data.last_index())
	var report: Dictionary={"outcome":"operator_mark","operator_label":label,"operator_note":_note.text,"start_frame":first.diagnostics.frame_number,
		"end_frame":last.diagnostics.frame_number,"start_time_s":start,"end_time_s":end,"tracks":[]}
	data.add_attempt(report,end,"mark-%d"%Time.get_ticks_msec())
	selected_report=report;selected_attempt=data.attempts[-1];_update_attempts();_start_window(start,end);_load_hypotheses()
	if client.connected:client.request("debug_mark",{"report":report,"session_id":_session_id})
	_show_message("Marked %s. The last 3 seconds are ready to replay/export."%label.replace("_"," "))


func open_recording(path: String) -> void:
	var recording:=RadarDebugData.new()
	if not recording.open_directory(path):_show_message(recording.error);return
	data=recording;_remote_list=false;_archive_request="";selected_report={};selected_attempt={};selected_point="";follow_live=false;playing=false;cursor=-1
	_update_attempts();_load_hypotheses();_redraw()


func open_clip(path: String) -> void:
	var clip:=RadarDebugData.new()
	if not clip.open_clip(path):_show_message(clip.error);return
	data=clip;_remote_list=false;_archive_request="";selected_report={};selected_attempt={};selected_point="";_note.text=clip.operator_note
	_update_attempts()
	if not data.attempts.is_empty():_select_attempt(0)
	else:_start_window(data.time_at(data.first_index()),data.time_at(data.last_index()));_load_hypotheses()
	view.fit_view()


func save_clip(path: String) -> void:
	if data.empty():_show_message("There are no radar frames to export.");return
	var start: float=_clip_start if not follow_live else maxf(data.time_at(data.first_index()),data.time_at(cursor)-3)
	var end: float=minf(_clip_end,data.time_at(data.last_index())) if not follow_live else data.time_at(cursor)
	var value:=data.export_clip(start,end,selected_report)
	if value.is_empty():_show_message(data.error);return
	value.operator_note=_note.text
	var file:=FileAccess.open(path,FileAccess.WRITE)
	if file==null:_show_message("Cannot save radar clip to this location.");return
	file.store_string(JSON.stringify(value));_show_message("Radar clip saved: "+path)


func _show_message(text: String) -> void:
	if _message:_message.text=text


func _unhandled_key_input(event: InputEvent) -> void:
	if not interactive or not event is InputEventKey or not event.pressed or event.echo:return
	if get_viewport().gui_get_focus_owner() is LineEdit:return
	match event.physical_keycode:
		KEY_SPACE:_toggle_play()
		KEY_LEFT:step_frame(-1)
		KEY_RIGHT:step_frame(1)
		KEY_F:view.fit_view()
		KEY_L:_follow()
		KEY_M:_mark("ball_hit")
		_:return
	get_viewport().set_input_as_handled()
