extends Node
## Original synthesized ambience and restrained UI/shot cues; no remote assets.

var ambience: AudioStreamPlayer
var effects: AudioStreamPlayer
var click: AudioStreamWAV
var strike: AudioStreamWAV
var landing: AudioStreamWAV


func _ready() -> void:
	for bus in ["Ambience","Effects"]:
		if AudioServer.get_bus_index(bus) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count-1,bus)
	ambience=AudioStreamPlayer.new()
	ambience.bus="Ambience"
	add_child(ambience)
	effects=AudioStreamPlayer.new()
	effects.bus="Effects"
	add_child(effects)
	click=_tone(.055,620,.11)
	strike=_tone(.16,170,.7)
	landing=_tone(.12,95,.35)
	GameSettings.changed.connect(_settings_changed)
	_update_volumes()
	if DisplayServer.get_name() != "headless":
		_start_ambience.call_deferred()


func _tone(duration: float, frequency: float, amplitude: float) -> AudioStreamWAV:
	var count:=int(duration*22050)
	var data:=PackedByteArray()
	data.resize(count*2)
	for index in range(count):
		var t:=float(index)/22050
		var envelope:=exp(-t*35)*minf(t*600,1)
		var sample:float=(sin(TAU*frequency*t*(1.0-t))+sin(TAU*frequency*2.1*t)*.15)*envelope*amplitude
		data.encode_s16(index*2,int(clampf(sample,-1,1)*32767))
	var stream:=AudioStreamWAV.new()
	stream.format=AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate=22050
	stream.data=data
	return stream


func _start_ambience()->void:
	var rate:=22050
	var duration:=16
	var count:=rate*duration
	var data:=PackedByteArray()
	data.resize(count*2)
	var rng:=RandomNumberGenerator.new()
	rng.seed=6843
	var low:=0.0
	var slow:=0.0
	for index in range(count):
		var t:=float(index)/rate
		low=lerpf(low,rng.randf_range(-1,1),.025)
		slow=lerpf(slow,low,.01)
		var wind:float=(low*.15+slow*.3)*(.65+.35*sin(TAU*t/duration))
		var bird:=0.0
		for start in [2.0,2.24,6.4,6.65,11.2,11.5]:
			var local:float=t-start
			if local>0 and local<.15:
				bird+=sin(TAU*(2100*local+1700*local*local))*sin(PI*local/.15)*.018
		var fade:float=minf(1,minf(t*2,(duration-t)*2))
		data.encode_s16(index*2,int(clampf((wind+bird)*fade,-1,1)*32767))
	var stream:=AudioStreamWAV.new()
	stream.format=AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate=rate
	stream.data=data
	stream.loop_mode=AudioStreamWAV.LOOP_FORWARD
	stream.loop_end=count
	ambience.stream=stream
	ambience.play()


func play_ui()->void:
	if DisplayServer.get_name()=="headless":return
	effects.stream=click
	effects.play()


func play_strike()->void:
	if DisplayServer.get_name()=="headless":return
	effects.stream=strike
	effects.play()


func play_landing()->void:
	if DisplayServer.get_name()=="headless":return
	effects.stream=landing
	effects.play()


func _settings_changed(key:String,_value:Variant)->void:
	if key.ends_with("volume"):_update_volumes()


func _update_volumes()->void:
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Ambience"),linear_to_db(maxf(.0001,float(GameSettings.get_value("ambience_volume")))))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Effects"),linear_to_db(maxf(.0001,float(GameSettings.get_value("effects_volume")))))


func stop_audio()->void:
	if ambience:
		ambience.stop()
		ambience.stream=null
	if effects:
		effects.stop()
		effects.stream=null
	click=null
	strike=null
	landing=null


func shutdown()->void:
	stop_audio()
	# Let the audio thread release its playback references before engine teardown.
	await get_tree().create_timer(.12).timeout


func _exit_tree()->void:
	stop_audio()
