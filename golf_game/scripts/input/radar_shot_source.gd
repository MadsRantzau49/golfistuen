class_name RadarShotSource
extends Node
## One active gameplay adapter connects to Rust's NDJSON TCP service.
## An arm ID scopes each shot to the current ready turn; stale shots never queue.

var target: Node
var hud: RangeHUD
var peer: StreamPeerTCP
var buffer := PackedByteArray()
var retry_at := 0
var last_status := 0
var last_send := 0
var connected_at := 0
var radar_ready := false
var arm_id := ""
var acknowledged_arm := ""
var endpoint := ""
var sequence := 0
var session := str(Time.get_ticks_usec())
var seen: Dictionary = {}


func _ready() -> void:
	GameSettings.changed.connect(func(key:String,_value:Variant):
		if key in ["shot_mode","radar_host","radar_port"]:_disconnect();retry_at=0
	)


func _process(_delta: float) -> void:
	var enabled: bool = GameSettings.get_value("shot_mode")=="Real" and target.interactive and hud.visible
	if not enabled:
		_disconnect()
		return
	var address := "%s:%s"%[GameSettings.get_value("radar_host"),GameSettings.get_value("radar_port")]
	if endpoint != address:
		_disconnect();endpoint=address;retry_at=0
	var now := Time.get_ticks_msec()
	if peer == null:
		hud.set_radar_status("Connecting to radar…",false)
		if now < retry_at:return
		peer=StreamPeerTCP.new();connected_at=now
		var error := peer.connect_to_host(str(GameSettings.get_value("radar_host")),int(GameSettings.get_value("radar_port")))
		if error != OK:_retry(now)
		return
	peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		if peer.get_status()!=StreamPeerTCP.STATUS_CONNECTING or now-connected_at>3000:_retry(now)
		return
	if (last_status>0 and now-last_status>2000) or (last_status==0 and now-connected_at>3000):
		_retry(now);return
	# Revoke locally before reading queued packets after pause/busy/turn changes.
	if not target.is_live_ready():arm_id="";acknowledged_arm=""
	var available := peer.get_available_bytes()
	if available>0:
		var result := peer.get_data(available)
		if result[0]!=OK:_retry(now);return
		buffer.append_array(result[1])
		if buffer.size()>65536:_retry(now);return
		var newline := buffer.find(10)
		while newline>=0:
			var line := buffer.slice(0,newline).get_string_from_utf8()
			buffer=buffer.slice(newline+1)
			_handle_message(JSON.parse_string(line),now)
			newline=buffer.find(10)
	var ready: bool = radar_ready and target.is_live_ready()
	if ready and arm_id.is_empty():
		sequence+=1;arm_id="%s-%d"%[session,sequence]
	if not ready:arm_id="";acknowledged_arm=""
	if now-last_send>=250 or (arm_id!=acknowledged_arm and now-last_send>=50):
		var message := JSON.stringify({"type":"ready","ready":ready,"arm_id":arm_id})+"\n"
		if peer.put_data(message.to_utf8_buffer())!=OK:_retry(now);return
		last_send=now
	if not radar_ready:hud.set_radar_status("Radar connected · waiting for frames",false)
	elif not target.is_live_ready():hud.set_radar_status("Wait · ball / turn not ready",false)
	elif arm_id!=acknowledged_arm:hud.set_radar_status("Preparing radar…",false)
	else:hud.set_radar_status("READY — SHOOT NOW",true)


func _handle_message(message: Variant, now: int) -> void:
	if not message is Dictionary:return
	if message.get("type")=="status":
		last_status=now
		radar_ready=message.get("radar_ready")==true and message.get("protocol")==1
		acknowledged_arm=str(message.get("arm_id",""))
		if not radar_ready:arm_id="";acknowledged_arm=""
	elif message.get("type")=="shot":
		var payload: Variant = message.get("shot")
		if arm_id.is_empty() or message.get("arm_id")!=arm_id or not target.is_live_ready():return
		if not payload is Dictionary:return
		var id := str(payload.get("shot_id",""))
		if id.is_empty() or seen.has(id):return
		seen[id]=true
		if seen.size()>256:seen.erase(seen.keys()[0])
		arm_id="";acknowledged_arm=""
		if target.receive_shot(payload):hud.show_message("Real shot registered — playing your shot!")


func _retry(now: int) -> void:
	_disconnect();retry_at=now+1000
	hud.set_radar_status("Radar disconnected · reconnecting…",false)


func _disconnect() -> void:
	if peer:peer.disconnect_from_host()
	peer=null;buffer.clear();arm_id="";acknowledged_arm="";radar_ready=false;last_status=0;last_send=0


func _exit_tree() -> void:
	_disconnect()
