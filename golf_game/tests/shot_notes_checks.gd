extends SceneTree
## Actual control protocol + Space pairs + form persistence; no radar hardware.
var failures:=0
var server:=TCPServer.new()
var remote:StreamPeerTCP
var incoming:=PackedByteArray()
var messages:Array[Dictionary]=[]


func _initialize()->void:
	_run.call_deferred()
	create_timer(60).timeout.connect(func():printerr("FAIL: shot notes checks timed out");quit(1))


func check(value:bool,message:String)->void:
	if not value:failures+=1;printerr("FAIL: "+message)


func _frames(count:=6)->void:
	for _frame in range(count):await process_frame


func _send(message:Dictionary)->void:remote.put_data((JSON.stringify(message)+"\n").to_utf8_buffer())


func _read()->void:
	remote.poll()
	var count:=remote.get_available_bytes()
	if count>0:incoming.append_array(remote.get_data(count)[1])
	var end:=incoming.find(10)
	while end>=0:
		var value:Variant=JSON.parse_string(incoming.slice(0,end).get_string_from_utf8());incoming=incoming.slice(end+1)
		if value is Dictionary:messages.append(value)
		end=incoming.find(10)


func _wait(kind:String)->Dictionary:
	for _frame in range(240):
		_read()
		for message in messages:
			if message.get("type")==kind:return message
		await process_frame
	check(false,"Client sends "+kind);return {}


func _space(panel:Node,echo:=false)->void:
	var event:=InputEventKey.new();event.physical_keycode=KEY_SPACE;event.pressed=true;event.echo=echo;panel._input(event)


func _run()->void:
	root.size=Vector2i(1440,900)
	var cache:="user://shot-notes-check.json";var exported:="user://shot-notes-export-check.json"
	DirAccess.remove_absolute(cache)
	var panel:Node=load("res://scripts/shot_notes.gd").new();panel.auto_connect=false;panel.cache_path=cache;root.add_child(panel)
	await _frames()
	check(not ResourceLoader.exists("res://scripts/radar_debug_range.gd"),"The 3D debug range is removed")
	check(panel.find_children("*","Camera3D",true,false).is_empty(),"Shot notes is a form without a 3D viewer")
	root.size=Vector2i(1100,720);await _frames()
	check(panel._notes.get_global_rect().end.y<=root.get_visible_rect().size.y+1,"Description form fits the minimum-window canvas")
	root.size=Vector2i(1440,900);await _frames()
	check(server.listen(0,"127.0.0.1")==OK,"Test notes service starts")
	panel.client.connect_to("127.0.0.1",server.get_local_port())
	for _frame in range(240):
		if server.is_connection_available():remote=server.take_connection();break
		await process_frame
	check(remote!=null,"Shot form connects to radar service")
	if remote==null:quit(1);return
	await _wait("notes_subscribe")
	_send({"type":"notes_info","protocol":1,"session_id":"123-1","recording_directory":"/logs/123-1","captures":[],"next_offset":null,"active_capture_id":null})
	await _frames()
	var focus:Control=root.gui_get_focus_owner()
	if focus:focus.release_focus()
	_space(panel)
	var key:String=panel.recording_key
	check(not key.is_empty(),"First Space starts a named shot window")
	_space(panel,true)
	check(panel.recording_key==key and panel.ending_key.is_empty(),"Held Space/key repeats do not end capture")
	_space(panel)
	check(panel.recording_key.is_empty() and panel.ending_key==key,"Second Space ends capture without waiting for its start acknowledgement")
	var start:Dictionary=await _wait("capture_start");var end:Dictionary=await _wait("capture_end")
	check(start.capture_id==end.capture_id,"Both timestamps refer to the same shot")
	var record:={"schema_version":1,"session_id":"123-1","capture_id":start.capture_id,"state":"recording",
		"started":{"elapsed_s":1.0,"unix_time_ms":10000,"event_sequence":1,"raw_bytes_received":100,"last_frame_number":10},"ended":null,
		"annotation":{"speed":null,"elevation":null,"direction":null,"notes":null},"annotation_revision":0,
		"frame_count":0,"point_count":0,"confirmed_balls":0,"rejected_attempts":0,"capture_file":"/logs/123-1/captures/shot.json"}
	_send({"type":"capture_started","request_id":start.request_id,"capture":record})
	await _frames(2)
	check(panel._detector_guess.text.contains("no ball registered"),"A capture starts without an invented detector estimate")
	record.detector_guess={"speed_mps":12.5,"elevation_deg":8.0,"direction_deg":-6.0,"observations":4,"algorithm":"backward_outgoing_club_reach_v2"}
	record.confirmed_balls=1;record.detector_last_result="ball_detected"
	_send({"type":"capture_progress","capture":record});await _frames(2)
	check(panel._detector_guess.text.contains("12.5 m/s") and panel._detector_guess.text.contains("6.0° left"),"Registered speed, elevation and direction appear during a timed capture")
	check(panel.client.annotation_for(key).speed==null,"Detector estimates do not fill in the operator's independent labels")
	record.detector_last_result="no_ball_detected";_send({"type":"capture_progress","capture":record});await _frames(2)
	check(panel._detector_guess.text.contains("12.5 m/s") and panel._detector_guess.text.contains("retained"),"Later rejected motion does not erase a registered shot estimate")
	var complete:=record.duplicate(true);complete.state="complete";complete.duration_s=1.0;complete.frame_count=7;complete.point_count=20;complete.first_frame=11;complete.last_frame=17
	complete.ended={"elapsed_s":2.0,"unix_time_ms":11000,"event_sequence":10,"raw_bytes_received":500,"last_frame_number":17}
	_send({"type":"capture_ended","request_id":end.request_id,"capture":complete});await _frames()
	check(panel.ending_key.is_empty() and panel.client.records[key].state=="complete","Capture end keeps the recorded prediction and timing")
	check(panel._notes.text.is_empty() and panel.selected_summary().annotation.notes==null,"Other notes default to None")
	check(panel.CHOICES.speed.size()==4 and panel.CHOICES.elevation.size()==7 and panel.CHOICES.direction.size()==5,"All requested qualitative presets are present")
	for field in ["speed","elevation","direction"]:
		for choice in panel.CHOICES[field]:
			var button:Button=panel._presets[field][choice[0]];button.set_pressed_no_signal(true);button.pressed.emit()
			check(panel.client.annotation_for(key).get(field)==choice[0],"Clickable preset: "+choice[0])
	var straight:Button=panel._presets.direction.straight;straight.set_pressed_no_signal(true);straight.pressed.emit()
	panel._notes.text="Travelled about 4 m, reached about 2 m, straight ahead.";panel._notes.text_changed.emit();panel._flush_current()
	var save:Dictionary=await _wait("capture_annotate")
	check(save.annotation.speed=="full_speed" and save.annotation.elevation=="instant_ceiling" and save.annotation.direction=="straight","Form submits estimates without requiring numeric speed/angles")
	check(not save.annotation.has("spin") and save.annotation.notes.contains("4 m"),"Description includes optional free text and no spin field")
	complete.annotation=save.annotation;complete.annotation_revision=1
	_send({"type":"capture_saved","request_id":save.request_id,"capture":complete});await _frames()
	check(not panel.client.drafts.has(key),"Save acknowledgement clears only the acknowledged draft")
	panel._notes.grab_focus();_space(panel);await _frames(2)
	check(panel.client.records.size()==1 and panel.recording_key.is_empty(),"Space in the notes field does not start another shot")
	panel.export_selected(exported)
	var saved:Variant=JSON.parse_string(FileAccess.get_file_as_string(exported))
	check(saved is Dictionary and saved.annotation.notes==save.annotation.notes and saved.ended.elapsed_s==2.0,"Export ties the description to its saved timing window")
	check(saved.detector_guess.speed_mps==12.5,"Saved notes retain the actual detector estimate")
	panel.client.disconnect_from();panel._notes.text="Offline edit preserved";panel._notes.text_changed.emit();panel._flush_current()
	panel.client._handle_message({"type":"capture_progress","capture":complete})
	check(panel.client.annotation_for(key).notes=="Offline edit preserved","Detector progress cannot overwrite an unsaved operator description")
	var recovered:Node=load("res://scripts/input/shot_notes_client.gd").new();recovered.cache_path=cache;root.add_child(recovered)
	check(recovered.drafts.has(key) and recovered.annotation_for(key).notes=="Offline edit preserved","Disconnected edits survive local-cache reload")
	recovered.queue_free();panel.set_interactive(false);check(panel.client.peer==null and not panel.ui_layer.visible,"Leaving shot notes disconnects the capture client")
	panel.queue_free();server.stop();await _frames()
	DirAccess.remove_absolute(cache);DirAccess.remove_absolute(cache+".tmp");DirAccess.remove_absolute(exported)
	var settings:Node=root.get_node("GameSettings");var original:Variant=settings.get_value("shot_mode");settings.set_value("shot_mode","Debug",false)
	var app:Node=load("res://scenes/application.tscn").instantiate();app.shot_notes_auto_connect=false;root.add_child(app)
	for _frame in range(3000):
		if app.state==app.State.MENU:break
		await process_frame
	app.open_shot_notes()
	check(app.state==app.State.SHOT_NOTES and not app.range_scene.interactive,"Main menu opens the timed shot-description form")
	check(not app.State.has("RADAR_DEBUG"),"Application no longer exposes the removed viewer mode")
	app.enter_range();check(not app.shot_notes.ui_layer.visible and app.state==app.State.PLAYING,"Returning to golf hides shot notes")
	app.queue_free();await _frames();settings.set_value("shot_mode",original,false)
	if failures==0:print("PASS: timed Space pair, key repeat/text focus, qualitative presets, None notes, saved descriptions, offline drafts, export and menu navigation")
	quit(1 if failures else 0)
