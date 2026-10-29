extends SceneTree
## Real debug TCP chunks -> point cloud, failed-attempt playback and file round trips.
var failures:=0
var server:=TCPServer.new()
var remote:StreamPeerTCP


func _initialize()->void:
	_run.call_deferred()
	create_timer(60).timeout.connect(func():printerr("FAIL: radar debug checks timed out");quit(1))


func check(value:bool,message:String)->void:
	if not value:failures+=1;printerr("FAIL: "+message)


func _frames(count:=6)->void:
	for _frame in range(count):await process_frame


func _send(message:Dictionary)->void:
	remote.put_data((JSON.stringify(message)+"\n").to_utf8_buffer())


func _run()->void:
	root.size=Vector2i(1440,900)
	var viewer:Node=load("res://scripts/radar_debug_range.gd").new();viewer.auto_connect=false;root.add_child(viewer)
	await _frames()
	root.size=Vector2i(1100,720);await _frames()
	check(viewer._timeline.get_global_rect().end.y<=root.get_visible_rect().size.y+1,"Timeline fits minimum-window canvas (%.1f <= %.1f)"%[viewer._timeline.get_global_rect().end.y,root.get_visible_rect().size.y])
	check(viewer.view.size.x>=319 and viewer.view.size.y>=219,"3D viewport remains usable with scrollable inspectors")
	root.size=Vector2i(1440,900);await _frames()
	check(server.listen(0,"127.0.0.1")==OK,"Debug test listener starts")
	viewer.client.connect_to("127.0.0.1",server.get_local_port())
	for _frame in range(240):
		if server.is_connection_available():remote=server.take_connection();break
		await process_frame
	check(remote!=null,"Debug range connects to the service")
	if remote==null:quit(1);return
	await _frames()
	remote.poll()
	var subscription: String=remote.get_data(remote.get_available_bytes())[1].get_string_from_utf8()
	check(subscription.contains("debug_subscribe") and not subscription.contains('"type":"ready"'),"Debug subscribes independently of gameplay turn arming")
	_send({"type":"debug_info","protocol":1,"session_id":"123-1","configuration":{"sensor":{"frame_period_s":.02,"max_unambiguous_radial_speed_mps":30}}})
	var raw:=[{"x":-1.0,"y":2.0,"z":1.2,"radial_velocity":0.0,"snr_db":20,"ball_rejection":"background"},
		{"x":.1,"y":1.5,"z":.2,"radial_velocity":15.0,"snr_db":12,"ball_rejection":null},
		{"x":-.3,"y":1.3,"z":.1,"radial_velocity":8.0,"snr_db":25,"ball_rejection":null}]
	_send({"type":"debug_frame","source":"live","time_s":1.0,"part":0,"parts":2,"diagnostics":{"frame_number":10,"points":raw.slice(0,2)}})
	await _frames()
	check(viewer.live_data.frames.is_empty(),"Partial frame chunks do not appear as complete observations")
	var rest:PackedByteArray=(JSON.stringify({"type":"debug_frame","source":"live","time_s":1.0,"part":1,"parts":2,"diagnostics":{"frame_number":10,"points":raw.slice(2)}})+"\n").to_utf8_buffer()
	remote.put_data(rest.slice(0,11));await _frames(2)
	check(viewer.live_data.frames.is_empty(),"Fragmented NDJSON waits for the complete line")
	remote.put_data(rest.slice(11));await _frames()
	check(viewer.live_data.frames.size()==1,"Chunks reassemble exactly one radar frame")
	check(viewer.live_data.frame_at(0).diagnostics.points.size()==3,"Raw background/person/club points are retained")
	check(viewer.view._handles.size()==3,"All raw returns are visible by default")
	var mapped:Vector3=load("res://scripts/input/radar_debug_data.gd").sample_position(raw[0])
	check(mapped.is_equal_approx(Vector3(-1,1.2,-2)),"Radar XYZ maps consistently to the 3D scene")
	_send({"type":"debug_frame","source":"live","time_s":1.02,"part":0,"parts":1,"diagnostics":{"frame_number":11,"points":raw}})
	var observations:=[{"id":1,"frame_number":10,"position":[.1,1.5,.2],"radial_velocity":15},
		{"id":2,"frame_number":11,"position":[.1,1.8,.25],"radial_velocity":15}]
	var report:={"start_frame":10,"outcome":"no_ball_detected","frames_evaluated":2,"points_evaluated":6,"ball_candidates":4,
		"point_rejections":{"background":2},"selected_fit":null,"selected_hypothesis_id":null,"selected_observations":null}
	var track:={"track_id":7,"observations":observations,"rejection_reason":"insufficient_independent_observations", "fit":null,"club_evidence":null}
	_send({"type":"debug_attempt_begin","source":"live","attempt_id":1,"time_s":1.04,"track_count":1,"report":report})
	_send({"type":"debug_track","source":"live","attempt_id":1,"index":0,"track":track})
	_send({"type":"debug_attempt_end","source":"live","attempt_id":1})
	await _frames(10)
	check(viewer.live_data.attempts.size()==1,"Failed attempts reach the debug range")
	check(viewer.selected_report.get("outcome")=="no_ball_detected","Unconfirmed hits are selectable and replayable")
	viewer._hypotheses.select(1);viewer._select_hypothesis(1)
	check(viewer._details.text.contains("insufficient independent observations"),"Inspector explains the actual rejected hypothesis")
	viewer._scrub(1);viewer.step_frame(-1)
	check(viewer.cursor==0 and not viewer.playing,"Frame stepping freezes the movie at the chosen observation")
	viewer.view._pick(viewer.view.camera.unproject_position(mapped))
	check(viewer._details.text.contains("background") and viewer._details.text.contains("1.2"),"Point inspector includes raw coordinates, Doppler and point-gate reason")
	var path:="user://radar-debug-check.json"
	viewer._note.text="real hit fixture note"
	viewer.save_clip(path)
	var portable:RefCounted=load("res://scripts/input/radar_debug_data.gd").new();check(portable.open_clip(path),"Portable raw clips load without radar hardware")
	check(portable.frames.size()==2 and portable.frame_at(0).diagnostics.points.size()==3,"Clip round trip preserves every raw point")
	check(portable.operator_note=="real hit fixture note","Portable clips retain operator debugging notes")
	var folder:="user://radar-debug-check-session"
	DirAccess.make_dir_recursive_absolute(folder)
	var file:=FileAccess.open(folder.path_join("session.json"),FileAccess.WRITE);file.store_string("{}");file.close()
	file=FileAccess.open(folder.path_join("events-000001.jsonl"),FileAccess.WRITE)
	for index in range(2):file.store_line(JSON.stringify({"type":"frame","elapsed_s":1.0+index*.02,"data":{"diagnostics":{"frame_number":10+index,"points":raw}}}))
	var full:=report.duplicate();full.tracks=[track]
	file.store_line(JSON.stringify({"type":"swing_completed","elapsed_s":1.04,"swing_id":1,"data":{"report":full}}));file.close()
	viewer.open_recording(folder)
	for _frame in range(240):
		if not viewer.data.loading:break
		await process_frame
	check(viewer.data.indexed and viewer.data.frames.size()==2,"Recording folders are indexed without retaining all point arrays")
	check(viewer.data.report_at(viewer.data.attempts[0]).tracks[0].track_id==7,"Indexed attempts retain exact saved decisions")
	check(viewer.data.frame_at(0).diagnostics.points.size()==3,"Indexed raw frames load on demand")
	var real_path:=OS.get_environment("RADAR_DEBUG_TEST_SESSION")
	if not real_path.is_empty():
		viewer.open_recording(real_path)
		for _frame in range(3000):
			if not viewer.data.loading:break
			await process_frame
		check(viewer.data.error.is_empty() and viewer.data.frames.size()>0,"Actual captured session loads in the 3D debug range")
		for index in [0,maxi(0,viewer.data.attempts.size()-1)]:
			if viewer.data.attempts.is_empty():break
			viewer._select_attempt(index);viewer._scrub(viewer.data.index_at_time(viewer.data.attempts[index].end_time_s))
			if viewer.selected_report.get("tracks",[]).size()>0:viewer._select_hypothesis(1)
		check(viewer.view.data==viewer.data,"Real raw data and saved hypotheses drive the viewport")
	viewer.set_interactive(false)
	check(viewer.client.peer==null and not viewer.ui_layer.visible,"Leaving debug disconnects capture and hides its viewport")
	viewer.queue_free();server.stop();await _frames()
	DirAccess.remove_absolute(path);DirAccess.remove_absolute(folder.path_join("session.json"));DirAccess.remove_absolute(folder.path_join("events-000001.jsonl"));DirAccess.remove_absolute(folder)
	var settings:Node=root.get_node("GameSettings");var original_mode:Variant=settings.get_value("shot_mode");settings.set_value("shot_mode","Debug",false)
	var app:Node=load("res://scenes/application.tscn").instantiate();app.radar_debug_auto_connect=false;root.add_child(app)
	for _frame in range(3000):
		if app.state==app.State.MENU:break
		await process_frame
	app.open_radar_debug();app.radar_debug.client.disconnect_from()
	check(app.state==app.State.RADAR_DEBUG and not app.range_scene.interactive,"Main menu opens an independent radar debug mode")
	check(app.radar_debug.view.viewport.own_world_3d,"Radar coordinates are isolated from the golf world's camera/environment")
	app.enter_range()
	check(app.state==app.State.PLAYING and not app.radar_debug.ui_layer.visible,"Returning to golf disables the diagnostic UI")
	app.queue_free();await _frames()
	settings.set_value("shot_mode",original_mode,false)
	if failures==0:print("PASS: 3D radar raw points, chunked TCP, failed-attempt replay, inspector, scrubbing, clip export/import, indexed recordings and application navigation")
	quit(1 if failures else 0)
