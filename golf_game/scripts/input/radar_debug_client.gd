class_name RadarDebugClient
extends Node
## Diagnostic subscription is independent of gameplay turns and never launches golf.
signal info_received(message: Dictionary)
signal frame_received(frame: Dictionary, source: String, request_id: String)
signal attempt_received(report: Dictionary, timestamp: float, id: int, source: String, request_id: String)
signal message_received(message: Dictionary)
signal connection_changed(message: String)
signal failed(message: String)
const MAX_BUFFER := 2 * 1024 * 1024
var peer: StreamPeerTCP
var buffer := PackedByteArray()
var connected := false
var _started := 0
var _last_heard := 0
var _last_heartbeat := 0
var _sequence := 0
var _frames: Dictionary = {}
var _attempts: Dictionary = {}


func connect_to(host: String, port: int) -> void:
	disconnect_from()
	peer=StreamPeerTCP.new();_started=Time.get_ticks_msec();_last_heard=_started;_last_heartbeat=0
	var error:=peer.connect_to_host(host.strip_edges(),port)
	if error!=OK:_fail("Cannot connect to radar: %s"%error);return
	connection_changed.emit("Connecting to %s:%d…"%[host,port])


func disconnect_from() -> void:
	if peer:peer.disconnect_from_host()
	peer=null;connected=false;buffer.clear();_frames.clear();_attempts.clear()


func request(kind: String, values: Dictionary={}) -> String:
	_sequence+=1
	var id:="debug-%d-%d"%[_started,_sequence]
	var payload:=values.duplicate();payload.type=kind;payload.request_id=id
	_send(payload)
	return id


func _send(message: Dictionary) -> void:
	if not connected or peer==null:return
	if peer.put_data((JSON.stringify(message)+"\n").to_utf8_buffer())!=OK:_fail("Radar connection stopped while sending a request.")


func _process(_delta: float) -> void:
	if peer==null:return
	peer.poll()
	var now:=Time.get_ticks_msec()
	if peer.get_status()!=StreamPeerTCP.STATUS_CONNECTED:
		if peer.get_status()!=StreamPeerTCP.STATUS_CONNECTING or now-_started>3000:_fail("Radar disconnected. Reconnect to continue capture.")
		return
	if not connected:
		connected=true;peer.set_no_delay(true);connection_changed.emit("Connected · subscribing to raw radar frames…")
		_last_heartbeat=now-1000
	if now-_last_heartbeat>=1000:
		_send({"type":"debug_subscribe","enabled":true});_last_heartbeat=now
	if peer==null:return
	if now-_last_heard>5000:_fail("Radar debug stream timed out.");return
	var available:=mini(peer.get_available_bytes(),256*1024)
	if available>0 and buffer.size()<MAX_BUFFER/2:
		var result:=peer.get_data(available)
		if result[0]!=OK:_fail("Cannot read radar debug data.");return
		buffer.append_array(result[1])
	if buffer.size()>MAX_BUFFER:_fail("Radar message exceeds the viewer transport budget.");return
	var deadline:=Time.get_ticks_usec()+4000
	var newline:=buffer.find(10)
	while newline>=0 and Time.get_ticks_usec()<deadline:
		var parsed: Variant=JSON.parse_string(buffer.slice(0,newline).get_string_from_utf8())
		buffer=buffer.slice(newline+1)
		if not parsed is Dictionary:_fail("Radar sent invalid debug JSON.");return
		_last_heard=now;_handle_message(parsed)
		newline=buffer.find(10)


func _handle_message(message: Dictionary) -> void:
	var kind:=str(message.get("type",""))
	var source:=str(message.get("source","live"));var request_id:=str(message.get("request_id",""))
	if kind=="debug_info":info_received.emit(message)
	elif kind=="debug_frame":
		var diagnostics: Variant=message.get("diagnostics")
		if not diagnostics is Dictionary or not diagnostics.get("points") is Array:return
		var parts:=int(message.get("parts",1));var part:=int(message.get("part",0))
		if parts<1 or parts>2048 or part<0 or part>=parts:_fail("Invalid radar frame chunks.");return
		var key:=source+"/"+request_id
		var frame_key:=str(diagnostics.get("frame_number"))+"/"+str(message.get("time_s"))
		if part==0:
			_frames[key]={"key":frame_key,"next":0,"parts":parts,"data":{"time_s":message.get("time_s",0),"detector_state":message.get("detector_state",""),"diagnostics":diagnostics.duplicate()}}
			_frames[key].data.diagnostics.points=[]
		if not _frames.has(key) or _frames[key].key!=frame_key or _frames[key].next!=part:
			failed.emit("A debug frame was incomplete; use the saved recording for the full capture.");_frames.erase(key);return
		var pending: Dictionary=_frames[key]
		pending.data.diagnostics.points.append_array(diagnostics.points);pending.next+=1
		if pending.data.diagnostics.points.size()>RadarDebugData.MAX_POINTS:_fail("Radar frame exceeds viewer point budget.");return
		if pending.next==parts:
			frame_received.emit(pending.data,source,request_id);_frames.erase(key)
	elif kind=="debug_attempt_begin":
		var count:=int(message.get("track_count",0))
		if count<0 or count>2048:failed.emit("Attempt has too many hypotheses for the viewer.");return
		if not message.get("report") is Dictionary:failed.emit("Invalid diagnostic attempt header.");return
		var report: Dictionary=message.get("report",{});report.tracks=[]
		_attempts[source+"/"+request_id]={"report":report,"count":count,"id":int(message.get("attempt_id",0)),"time":float(message.get("time_s",0))}
	elif kind=="debug_track":
		var key:=source+"/"+request_id
		if not _attempts.has(key):return
		var pending: Dictionary=_attempts[key]
		if pending.id!=int(message.get("attempt_id",-1)) or pending.report.tracks.size()!=int(message.get("index",-1)):
			failed.emit("Incomplete diagnostic attempt transfer.");_attempts.erase(key);return
		pending.report.tracks.append(message.get("track",{}))
		if RadarDebugData.trace_samples(pending.report)>RadarDebugData.MAX_TRACE_SAMPLES:
			failed.emit("Attempt exceeds viewer trace budget. Full details remain in the recording.");_attempts.erase(key)
	elif kind=="debug_attempt_end":
		var key:=source+"/"+request_id
		if not _attempts.has(key):return
		var pending: Dictionary=_attempts[key]
		if pending.id==int(message.get("attempt_id",-1)) and pending.report.tracks.size()==pending.count:
			attempt_received.emit(pending.report,pending.time,pending.id,source,request_id)
		else:failed.emit("Attempt transfer was incomplete; reload it from the saved session.")
		_attempts.erase(key)
	else:message_received.emit(message)


func _fail(message: String) -> void:
	disconnect_from();failed.emit(message);connection_changed.emit(message)


func _exit_tree() -> void:disconnect_from()
