class_name HoleRules
extends RefCounted
## Rules are a per-attempt snapshot, separate from terrain, presentation and input.
## Extensions can later supply handicap/net scoring without changing hole files.

const DEFAULTS := {"green_putts":2,"water_penalty":1,"oob_penalty":1,"max_strokes":12}
var options: Dictionary = DEFAULTS.duplicate()


static func create(settings: Dictionary = {}, overrides: Dictionary = {}) -> HoleRules:
	var rules := HoleRules.new()
	for source in [settings,overrides]:
		for key in DEFAULTS:
			var value: Variant=source.get(key, rules.options[key])
			if valid(key,value): rules.options[key]=int(value)
	return rules


static func valid(key: String, value: Variant) -> bool:
	if not (value is int or value is float) or not is_finite(float(value)) or value!=int(value): return false
	if key in ["green_putts","water_penalty","oob_penalty"]: return value>=0 and value<=3
	if key=="max_strokes": return value>=3 and value<=30
	return false


func to_dict() -> Dictionary:
	return options.duplicate()
