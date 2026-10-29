extends SceneTree
## Exercise the actual TCP adapter and gameplay with a local NDJSON radar peer.
var failures:=0
var server:=TCPServer.new()
var remote:StreamPeerTCP
var input:=PackedByteArray()
var settings:Node


func _initialize()->void:
	_run.call_deferred()
	create_timer(45).timeout.connect(func():printerr("FAIL: live radar checks timed out");quit(1))


func check(value:bool,message:String)->void:
	if not value:failures+=1;printerr("FAIL: "+message)


func _send(message:Dictionary)->void:
	remote.put_data((JSON.stringify(message)+"\n").to_utf8_buffer())


func _connect()->void:
	remote=null;input.clear()
	for frame in range(240):
		if server.is_connection_available():remote=server.take_connection();break
		await process_frame
	check(remote!=null,"Real mode connects to the configured TCP endpoint")
	if remote:_send({"type":"status","protocol":1,"radar_ready":true,"arm_id":null})


func _arm()->String:
	for frame in range(240):
		remote.poll()
		var available:=remote.get_available_bytes()
		if available>0:input.append_array(remote.get_data(available)[1])
		var newline:=input.find(10)
		while newline>=0:
			var message:Variant=JSON.parse_string(input.slice(0,newline).get_string_from_utf8())
			input=input.slice(newline+1)
			if message is Dictionary and message.get("ready")==true:
				var arm:=str(message.arm_id)
				_send({"type":"status","protocol":1,"radar_ready":true,"arm_id":arm})
				await process_frame;await process_frame
				return arm
			newline=input.find(10)
		await process_frame
	check(false,"Ready gameplay arms the live detector")
	return ""


func _shot(arm:String,id:String)->Dictionary:
	return {"type":"shot","arm_id":arm,"shot":{"shot_id":id,"speed_mps":10.0,"direction_deg":2.0,"elevation_deg":12.0,"spin_rpm":0.0}}


func _frames(count:=6)->void:
	for frame in range(count):await process_frame


func _run()->void:
	root.size=Vector2i(1440,900)
	settings=root.get_node("GameSettings")
	var original:Dictionary=settings.values.duplicate()
	check(server.listen(0,"127.0.0.1")==OK,"Local radar test listener starts")
	settings.set_value("radar_host","127.0.0.1",false)
	settings.set_value("radar_port",server.get_local_port(),false)
	settings.set_value("shot_mode","Real",false)
	var range_scene:Node=load("res://scenes/driving_range.tscn").instantiate();root.add_child(range_scene)
	await _connect()
	if remote==null:quit(1);return
	var arm:=await _arm()
	check(range_scene.hud.radar_status.text=="READY — SHOOT NOW","Real mode announces readiness after radar acknowledgement")
	check(not range_scene.hud.debug_controls.visible and range_scene.hud.radar_controls.visible,"Real mode shows live controls")
	range_scene.hud.request_launch()
	check(not range_scene.active,"Space/manual launch cannot create simulated shots in Real mode")
	# Real TCP fragmentation, then coalesced duplicate and stale messages.
	var bytes:PackedByteArray=(JSON.stringify(_shot(arm,"live-test-1"))+"\n").to_utf8_buffer()
	remote.put_data(bytes.slice(0,15));await _frames(2)
	check(not range_scene.active,"A partial network line cannot launch a shot")
	remote.put_data(bytes.slice(15));await _frames()
	check(range_scene.active and range_scene.last_shot.shot_id=="live-test-1","A real shot launches automatically without confirmation")
	var model:BallFlight=range_scene.model
	_send(_shot(arm,"live-test-1"));_send(_shot(arm,"busy-shot"));await _frames()
	check(range_scene.model==model,"Duplicate/busy deliveries cannot restart flight")
	for frame in range(5000):
		range_scene._physics_process(BallFlight.STEP)
		if not range_scene.active:break
	await _frames()
	input.clear();remote.get_data(remote.get_available_bytes())
	var next_arm:=await _arm()
	check(next_arm!=arm,"Next playable shot uses a fresh arm ID")
	_send(_shot(arm,"stale-shot"));await _frames()
	check(not range_scene.active,"A prior-turn event cannot fire on the new turn")
	range_scene.set_interactive(false)
	check(range_scene.radar_source.peer==null,"Pause immediately revokes the live connection")
	range_scene.set_interactive(true)
	await _connect();arm=await _arm()
	check(not arm.is_empty() and arm!=next_arm,"Resume reconnects and arms a fresh turn")
	_send({"type":"status","protocol":1,"radar_ready":false,"arm_id":null});await _frames()
	check(range_scene.hud.radar_status.text.contains("waiting for frames"),"Connected socket without radar frames is not ready")
	_send(_shot(arm,"no-frames"));await _frames()
	check(not range_scene.active,"Frame loss revokes the old arm")
	remote.disconnect_from_host();await _frames()
	check(range_scene.radar_source.arm_id.is_empty(),"Disconnect clears armed state")
	await _connect();arm=await _arm()
	check(not arm.is_empty(),"A dropped radar service connection reconnects automatically")
	settings.set_value("shot_mode","Debug",false)
	check(range_scene.hud.debug_controls.visible and not range_scene.hud.radar_controls.visible,"Debug mode restores simulation controls")
	await _frames()
	var panel:Control=range_scene.hud.debug_controls.get_parent().get_parent()
	check(panel.get_global_rect().end.y<=900-115,"Shot input controls fit above the bottom camera controls (bottom %.0f)"%panel.get_global_rect().end.y)
	range_scene.hud.request_launch();check(range_scene.active,"Debug mode still launches manually")
	range_scene.queue_free();await process_frame
	# Verify competitive launch accounting and immediate Real-mode launch too.
	settings.set_value("shot_mode","Real",false)
	var workspace:Node3D=load("res://scripts/holes/hole_workspace.gd").new();workspace.save_root="user://radar-check-holes";root.add_child(workspace)
	await workspace.ready_for_use
	var course:=GolfCourse.new();course.holes.assign([HoleDefinition.demo()])
	var players:Array[GolfPlayer]=[GolfPlayer.new("Live golfer",0)]
	var competition:=LocalGolfMatch.new(players,course)
	var clubhouse:=ClubhouseStore.new("user://radar-check-clubhouse")
	workspace.open_match(competition,clubhouse)
	await _connect();arm=await _arm()
	var controller:Node3D=workspace.competition
	controller._show_completion();await _frames()
	_send(_shot(arm,"scorecard-shot"));await _frames()
	check(competition.current_round().strokes==0,"An open scorecard cannot accept a real shot")
	controller._close_modal();input.clear();remote.get_data(remote.get_available_bytes());arm=await _arm()
	_send(_shot(arm,"competition-shot"));await _frames()
	check(controller.in_motion and controller.model!=null and controller._windup==null,"Real competitive shot launches immediately")
	check(competition.current_round().strokes==1,"Real shot counts exactly one competitive stroke")
	_send(_shot(arm,"competition-shot"));await _frames()
	check(competition.current_round().strokes==1,"Duplicate real shot cannot add a stroke")
	workspace.queue_free();await process_frame
	settings.values=original
	server.stop()
	_cleanup("user://radar-check-clubhouse");_cleanup("user://radar-check-holes")
	if failures==0:print("PASS: live TCP readiness, fragmented shots, automatic launch, duplicates/stale turns, pause/reconnect, frame loss, Debug/Real controls and competitive scoring")
	quit(1 if failures else 0)


func _cleanup(path:String)->void:
	var directory:=DirAccess.open(path)
	if directory==null:return
	for child in directory.get_directories():_cleanup(path.path_join(child))
	for file in directory.get_files():DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
