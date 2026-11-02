class_name ShotNotesClient
extends Node
## Small control messages only; raw radar data stays in the always-on recording.
signal info_received(message: Dictionary)
signal record_changed(key: String)
signal status_received(message: Dictionary)
signal connection_changed(message: String)
signal failed(message: String)
signal operation_failed(message: Dictionary)
signal record_removed(key: String)
signal regression_received(message: Dictionary)
var cache_path := "user://shot-notes.json"
var peer: StreamPeerTCP
var connected := false
var session_id := ""
var recording_directory := ""
var capabilities:Dictionary={}
var local_backup_ok := true
var records: Dictionary = {}
var drafts: Dictionary = {}
var generations: Dictionary = {}
var next_offset: Variant = null
var _buffer := PackedByteArray()
var _token := "trial-%d-%d-%d"%[int(Time.get_unix_time_from_system()*1000),Time.get_ticks_usec(),randi()]
var _sequence := 0
var _started := 0
var _last_heard := 0
var _last_heartbeat := 0
var _pending_saves: Dictionary = {}
var _saving_keys: Dictionary = {}
var _cache_blocked := false
var _deleted: Dictionary = {}
var _deleting: Dictionary = {}
var regression_running := false
var _regression_waiting := false
var _last_regression_poll := 0

func _ready() -> void:
	if not FileAccess.file_exists(cache_path):return
	var value: Variant=JSON.parse_string(FileAccess.get_file_as_string(cache_path))
	if value is Dictionary and value.get("version")==1 and value.get("records") is Dictionary and value.get("drafts") is Dictionary and value.get("generations") is Dictionary:
		records=value.get("records",{});drafts=value.get("drafts",{});generations=value.get("generations",{})
		_deleted=value.get("deleted",{})
	else:_cache_blocked=true;local_backup_ok=false;failed.emit("Could not load the local notes backup. It has been preserved; use Export to keep new drafts.")


static func key_for(record: Dictionary) -> String:return str(record.get("session_id",""))+"/"+str(record.get("capture_id",""))


func connect_to(host: String, port: int) -> void:
	disconnect_from();session_id="";recording_directory="";next_offset=null;capabilities={}
	peer=StreamPeerTCP.new();_started=Time.get_ticks_msec();_last_heard=_started
	var error:=peer.connect_to_host(host.strip_edges(),port)
	if error!=OK:_fail("Cannot connect to radar service: %s"%error);return
	connection_changed.emit("Connecting…")


func disconnect_from() -> void:
	for record in records.values():
		if record.get("state") in ["starting","recording"]:record["_connection_lost"]=true
	if peer:peer.disconnect_from_host()
	peer=null;connected=false;_buffer.clear();_pending_saves.clear();_saving_keys.clear();_deleting.clear()
	regression_running=false;_regression_waiting=false
	_save_cache()


func request(kind: String, values: Dictionary={}) -> String:
	_sequence+=1
	var id:="%s-req-%d"%[_token,_sequence]
	var payload:=values.duplicate();payload.type=kind;payload.request_id=id
	_send(payload);return id


func start_capture() -> String:
	if not connected or session_id.is_empty():return ""
	_sequence+=1
	var id:="%s-%d"%[_token,_sequence]
	var now:=int(Time.get_unix_time_from_system()*1000)
	# Use the newest capture, not the history row currently being inspected.
	var keys:=sorted_keys()
	var annotation: Dictionary=annotation_for(keys[0]).duplicate(true) if not keys.is_empty() else {"speed":null,"elevation":null,"direction":null,"notes":null,"outcome":null,"context":{}}
	annotation.notes=null
	annotation.measurements={}
	var record:={"capture_id":id,"session_id":session_id,"state":"starting","started":{"unix_time_ms":now},
		"annotation":annotation,"annotation_revision":0}
	var key:=key_for(record);records[key]=record;_save_cache();record_changed.emit(key)
	request("capture_start",{"capture_id":id,"client_time_ms":now,"annotation":annotation})
	return key


func end_capture(key: String) -> void:
	if not records.has(key) or not connected:return
	request("capture_end",{"capture_id":records[key].capture_id,"client_time_ms":int(Time.get_unix_time_from_system()*1000)})


func delete_capture(key: String) -> void:
	if not connected or not records.has(key):failed.emit("Connect to delete a saved shot.");return
	if capabilities.get("capture_delete")!=true:failed.emit("Restart the updated radar service to enable shot deletion.");return
	if records[key].get("session_id")==session_id and records[key].get("state") in ["starting","recording"]:failed.emit("End this shot before deleting it.");return
	if regression_running:failed.emit("Wait for the regression task to finish.");return
	if _saving_keys.has(key):failed.emit("This description is still saving. Try deleting it in a moment.");return
	_deleting[key]=true
	request("capture_delete",{"session_id":records[key].session_id,"capture_id":records[key].capture_id,"annotation_revision":int(records[key].get("annotation_revision",0))})


func _forget(key: String) -> void:
	_deleted[key]=true;_deleting.erase(key);records.erase(key);drafts.erase(key);generations.erase(key);_saving_keys.erase(key)
	for id in _pending_saves.keys():
		if _pending_saves[id].key==key:_pending_saves.erase(id)
	_save_cache();record_removed.emit(key)


func regression_request(kind: String, values: Dictionary={}) -> void:
	if not connected:regression_received.emit({"type":"regression_error","message":"Connect to the radar service first."});return
	if capabilities.get("regression")!=true:regression_received.emit({"type":"regression_error","message":"Restart the updated radar service to enable the integrated regression tool."});return
	if kind!="regression_poll":_regression_waiting=true
	request(kind,values)


func set_annotation(key: String, annotation: Dictionary) -> void:
	if not records.has(key):return
	drafts[key]=annotation.duplicate(true);generations[key]=int(generations.get(key,0))+1
	_save_cache();record_changed.emit(key)


func annotation_for(key: String) -> Dictionary:
	return drafts.get(key,records.get(key,{}).get("annotation",{"speed":null,"elevation":null,"direction":null,"notes":null}))


func save_annotation(key: String) -> void:
	_save_cache()
	if not connected or not drafts.has(key) or not records.has(key) or _saving_keys.has(key) or _deleting.has(key):return
	var row: Dictionary=records[key]
	if str(row.get("state"))=="starting" and row.get("_connection_lost")!=true:return
	var id:=request("capture_annotate",{"session_id":row.session_id,"capture_id":row.capture_id,
		"annotation_revision":int(row.get("annotation_revision",0)),"annotation":drafts[key]})
	_pending_saves[id]={"key":key,"generation":int(generations.get(key,0))};_saving_keys[key]=id


func sync_drafts() -> void:
	for key in drafts.keys():save_annotation(key)


func _send(value: Dictionary) -> void:
	if peer==null or not connected:return
	if peer.put_data((JSON.stringify(value,"",true,true)+"\n").to_utf8_buffer())!=OK:_fail("Radar connection stopped. Your description remains saved locally.")


func _process(_delta: float) -> void:
	if peer==null:return
	peer.poll();var now:=Time.get_ticks_msec()
	if peer.get_status()!=StreamPeerTCP.STATUS_CONNECTED:
		if peer.get_status()!=StreamPeerTCP.STATUS_CONNECTING or now-_started>3000:_fail("Disconnected. Reconnect to save descriptions to the radar logs.")
		return
	if not connected:
		connected=true;peer.set_no_delay(true);_last_heartbeat=now-1000;connection_changed.emit("Connected · loading shot notes…")
	if now-_last_heartbeat>=1000:_send({"type":"notes_subscribe","enabled":true});_last_heartbeat=now
	if (regression_running or _regression_waiting) and now-_last_regression_poll>=750:
		request("regression_poll");_last_regression_poll=now
	if peer==null:return
	if now-_last_heard>5000:_fail("Radar service timed out. Notes remain saved locally.");return
	var available:=mini(peer.get_available_bytes(),256*1024)
	if available>0:
		var result:=peer.get_data(available)
		if result[0]!=OK:_fail("Cannot read radar service response.");return
		_buffer.append_array(result[1])
	if _buffer.size()>4*1024*1024:_fail("Shot-notes response is too large.");return
	var newline:=_buffer.find(10)
	while newline>=0:
		var message: Variant=JSON.parse_string(_buffer.slice(0,newline).get_string_from_utf8());_buffer=_buffer.slice(newline+1)
		if not message is Dictionary:_fail("Invalid shot-notes response.");return
		_last_heard=now;_handle_message(message);newline=_buffer.find(10)


func _upsert(record: Dictionary) -> String:
	var key:=key_for(record)
	if key=="/" or _deleted.has(key):return ""
	records[key]=record
	# Bound clean cached history; unacknowledged descriptions are never evicted.
	if records.size()>256:
		var keys:=sorted_keys()
		for index in range(keys.size()-1,-1,-1):
			if records.size()<=256:break
			var old: String=keys[index]
			if old!=key and not drafts.has(old) and records[old].get("state") not in ["recording","starting"]:records.erase(old)
	return key


func sorted_keys() -> Array:
	var keys:=records.keys()
	keys.sort_custom(func(a: String,b: String)->bool:return int(records[a].get("started",{}).get("unix_time_ms",0))>int(records[b].get("started",{}).get("unix_time_ms",0)))
	return keys


func _handle_message(message: Dictionary) -> void:
	var kind:=str(message.get("type",""))
	if kind=="notes_info":
		session_id=str(message.get("session_id",""));recording_directory=str(message.get("recording_directory",""));next_offset=message.get("next_offset")
		capabilities=message.get("capabilities",{})
		for record in message.get("captures",[]):
			if record is Dictionary:_upsert(record)
		for key in message.get("deleted_keys",[]):_forget(str(key))
		_save_cache();info_received.emit(message)
		if not message.has("deleted_keys") and not records.is_empty():request("notes_list",{"known_keys":records.keys()})
		else:sync_drafts()
	elif kind=="capture_deleted":_forget(str(message.get("session_id",""))+"/"+str(message.get("capture_id","")))
	elif kind=="regression_status":
		regression_running=message.get("state")=="running";_regression_waiting=regression_running
		regression_received.emit(message)
	elif kind=="capture_progress":
		if message.get("capture") is Dictionary:
			var key:=_upsert(message.capture)
			if not key.is_empty():record_changed.emit(key)
	elif kind in ["capture_started","capture_ended","capture_saved","capture_loaded"]:
		if not message.get("capture") is Dictionary:return
		var id:=str(message.get("request_id",""));var key:=key_for(message.capture)
		if kind=="capture_saved" and _pending_saves.has(id):
			var pending: Dictionary=_pending_saves[id]
			_pending_saves.erase(id);_saving_keys.erase(pending.key)
			if int(generations.get(key,0))==int(pending.generation):drafts.erase(key)
		if _upsert(message.capture).is_empty():return
		_save_cache();record_changed.emit(key)
		if drafts.has(key) and kind!="capture_loaded":save_annotation(key)
	elif kind=="notes_error":
		var id:=str(message.get("request_id",""))
		if _pending_saves.has(id):_saving_keys.erase(_pending_saves[id].key);_pending_saves.erase(id)
		if message.get("operation")=="capture_delete":_deleting.erase(str(message.get("session_id",""))+"/"+str(message.get("capture_id","")))
		if str(message.get("operation","")).begins_with("regression_"):
			_regression_waiting=false;regression_received.emit({"type":"regression_error","message":message.get("message","Regression tool unavailable")})
		operation_failed.emit(message);failed.emit(str(message.get("message","Cannot save shot notes")))
	elif kind=="status":
		regression_running=message.get("regression_running",regression_running)
		status_received.emit(message)


func _save_cache() -> void:
	if _cache_blocked:return
	var file:=FileAccess.open(cache_path+".tmp",FileAccess.WRITE)
	if file==null:local_backup_ok=false;failed.emit("Cannot save the local notes backup.");return
	file.store_string(JSON.stringify({"version":1,"records":records,"drafts":drafts,"generations":generations,"deleted":_deleted},"",true,true));file.close()
	local_backup_ok=DirAccess.rename_absolute(cache_path+".tmp",cache_path)==OK
	if not local_backup_ok:failed.emit("Cannot replace the local notes backup.")


func _fail(message: String) -> void:
	for record in records.values():
		if record.get("state") in ["starting","recording"]:record["_connection_lost"]=true
	disconnect_from();failed.emit(message);connection_changed.emit(message)


func _exit_tree() -> void:disconnect_from()
