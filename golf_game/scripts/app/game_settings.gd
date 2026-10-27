extends Node
## User preferences are owned by the application, never by a game mode.

signal changed(key: String, value: Variant)
signal save_failed(message: String)

const PATH := "user://settings.cfg"
const DEFAULTS := {"fullscreen": false, "quality": "High", "master_volume": .8,
	"ambience_volume": .6, "effects_volume": .8, "units": "Metres",
	"reduced_motion": false, "show_trail": true,
	"green_putts":2,"water_penalty":1,"oob_penalty":1,"max_strokes":12}
var values: Dictionary = DEFAULTS.duplicate()


func _ready() -> void:
	load_preferences()
	apply_display()
	apply_audio()


func load_preferences(path := PATH) -> void:
	values = DEFAULTS.duplicate()
	var config := ConfigFile.new()
	if config.load(path) != OK:
		return
	for key in DEFAULTS:
		var value: Variant = config.get_value("preferences",key,DEFAULTS[key])
		if valid(key,value):
			values[key] = value


func valid(key: String, value: Variant) -> bool:
	if not DEFAULTS.has(key):
		return false
	if key.ends_with("volume"):
		return (value is float or value is int) and is_finite(float(value)) and value >= 0 and value <= 1
	if key == "quality":
		return value in ["Low","Medium","High"]
	if key == "units":
		return value in ["Metres","Yards"]
	if key in HoleRules.DEFAULTS:return HoleRules.valid(key,value)
	return value is bool


func get_value(key: String) -> Variant:
	return values.get(key,DEFAULTS.get(key))


func set_value(key: String, value: Variant, persist := true) -> bool:
	if not valid(key,value):
		return false
	values[key] = value
	if key == "fullscreen":
		apply_display()
	if key.ends_with("volume"):
		apply_audio()
	changed.emit(key,value)
	if persist:
		save_preferences()
	return true


func save_preferences(path := PATH) -> bool:
	var config := ConfigFile.new()
	config.set_value("application","settings_version",1)
	for key in values:
		config.set_value("preferences",key,values[key])
	var result := config.save(path)
	if result != OK:
		save_failed.emit("Your preferences could not be saved. Check the application data folder.")
	return result == OK


func apply_display() -> void:
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if values.fullscreen else DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	Engine.max_fps = 60


func apply_audio() -> void:
	AudioServer.set_bus_volume_db(0,linear_to_db(maxf(.0001,float(values.master_volume))))


func distance(value: float) -> float:
	return value*1.0936133 if values.units == "Yards" else value


func distance_suffix() -> String:
	return "yd" if values.units == "Yards" else "m"
