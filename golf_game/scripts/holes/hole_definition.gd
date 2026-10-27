class_name HoleDefinition
extends RefCounted
## Versioned, renderer-independent authoring document. All positions are metres.
## Explicit surface IDs and a separate rules dictionary allow future extensions.

signal changed(kind: String)
enum Surface { ROUGH, FAIRWAY, GREEN, WATER, SAND, OOB }
const SCHEMA_VERSION := 1
const COLUMNS := 121
const ROWS := 241
const CELL_SIZE := 2.0
const BOUNDS := Rect2(-120.0, -440.0, 240.0, 480.0)
const CELL_COUNT := COLUMNS * ROWS
const MIN_HEIGHT := -8.0
const MAX_HEIGHT := 24.0
const MAX_TREES := 256
const DEFAULT_CUP_DIAMETER := .30
const MIN_CUP_DIAMETER := .108
const MAX_CUP_DIAMETER := 3.0
const CUP_DEPTH := .32
const FLAGSTICK_RADIUS := .009
const SURFACE_NAMES := ["Rough", "Fairway", "Green", "Water", "Bunker", "Out of bounds"]

var id := ""
var title := "Untitled escape"
var par := 4
var tee := Vector2(0, 20)
var cup := Vector2(0, -300)
var cup_placed := false
var cup_diameter_m := DEFAULT_CUP_DIAMETER
var water_level := -.25
var seed := 6843
var heights := PackedFloat32Array()
var surfaces := PackedByteArray()
var trees: Array[Dictionary] = []
var rules_overrides: Dictionary = {}
var metadata: Dictionary = {}
var dirty_region := Rect2i(0,0,COLUMNS,ROWS)


func _init() -> void:
	id = new_id()
	heights.resize(CELL_COUNT)
	heights.fill(0)
	surfaces.resize(CELL_COUNT)
	surfaces.fill(Surface.ROUGH)


static func new_id() -> String:
	return "hole-%x-%x" % [int(Time.get_unix_time_from_system()), randi()]


func grid_point(column: int, row: int) -> Vector2:
	return BOUNDS.position + Vector2(column, row) * CELL_SIZE


func contains(point: Vector2) -> bool:
	return point.x >= BOUNDS.position.x and point.y >= BOUNDS.position.y and point.x <= BOUNDS.end.x and point.y <= BOUNDS.end.y


func cell_index(point: Vector2) -> int:
	var p := (point - BOUNDS.position) / CELL_SIZE
	return clampi(roundi(p.y), 0, ROWS - 1) * COLUMNS + clampi(roundi(p.x), 0, COLUMNS - 1)


func surface_at(point: Vector2) -> int:
	return int(surfaces[cell_index(point)]) if contains(point) else Surface.OOB


func short_grass_weight(point:Vector2)->float:
	var grid:Vector2=(point-BOUNDS.position)/CELL_SIZE
	var x:=clampi(floori(grid.x),0,COLUMNS-2)
	var z:=clampi(floori(grid.y),0,ROWS-2)
	var u:=clampf(grid.x-x,0,1);var v:=clampf(grid.y-z,0,1)
	var result:=0.0
	for sample in [[x,z,(1-u)*(1-v)],[x+1,z,u*(1-v)],[x,z+1,(1-u)*v],[x+1,z+1,u*v]]:
		var kind:=int(surfaces[int(sample[1])*COLUMNS+int(sample[0])])
		if kind in [Surface.FAIRWAY,Surface.GREEN]:result+=float(sample[2])
	return result


func height_at(point: Vector2) -> float:
	var grid := (point - BOUNDS.position) / CELL_SIZE
	var x := clampi(floori(grid.x), 0, COLUMNS - 2)
	var z := clampi(floori(grid.y), 0, ROWS - 2)
	var u := clampf(grid.x - x, 0, 1)
	var v := clampf(grid.y - z, 0, 1)
	var a := z * COLUMNS + x
	var ha := heights[a]
	var hb := heights[a + 1]
	var hc := heights[a + COLUMNS]
	var hd := heights[a + COLUMNS + 1]
	if u + v <= 1:
		return ha + (hb - ha) * u + (hc - ha) * v
	return hd + (hc - hd) * (1-u) + (hb - hd) * (1-v)


func apply_brush(point: Vector2, radius: float, tool: String, strength := 2.0, delta := .05, flatten_height := 0.0) -> bool:
	if not contains(point): return false
	radius = clampf(radius, 2, 40)
	var first := ((point - Vector2.ONE * radius - BOUNDS.position) / CELL_SIZE).floor()
	var last := ((point + Vector2.ONE * radius - BOUNDS.position) / CELL_SIZE).ceil()
	var paint: Dictionary = {"rough":Surface.ROUGH, "fairway":Surface.FAIRWAY, "green":Surface.GREEN,
		"water":Surface.WATER, "sand":Surface.SAND, "oob":Surface.OOB}
	var before := heights.duplicate() if tool == "smooth" else PackedFloat32Array()
	var modified := false
	var height_changed := false
	for z in range(maxi(1, int(first.y)), mini(ROWS-2, int(last.y)) + 1):
		for x in range(maxi(1, int(first.x)), mini(COLUMNS-2, int(last.x)) + 1):
			var distance := grid_point(x,z).distance_to(point)
			if distance > radius: continue
			var index := z * COLUMNS + x
			var weight := 1.0 - smoothstep(0.0, radius, distance)
			var old_height := heights[index]
			if paint.has(tool):
				var value: int = paint[tool]
				if surfaces[index] != value:
					surfaces[index] = value
					modified = true
				if value == Surface.WATER:
					heights[index] = minf(heights[index], water_level - .8 - weight * .5)
			elif tool == "raise": heights[index] += strength * delta * weight
			elif tool == "lower": heights[index] -= strength * delta * weight
			elif tool == "flatten": heights[index] = move_toward(heights[index], flatten_height, strength * delta * weight)
			elif tool == "smooth":
				var average := 0.0
				for dz in range(-1,2):
					for dx in range(-1,2): average += before[index + dz*COLUMNS + dx]
				heights[index] = lerpf(before[index], average/9.0, clampf(strength*delta*weight,0,1))
			heights[index] = clampf(heights[index], MIN_HEIGHT, MAX_HEIGHT)
			if not is_equal_approx(old_height, heights[index]): height_changed = true
	if height_changed or modified:
		if height_changed:
			var region:=Rect2i(Vector2i(first),Vector2i(last-first)+Vector2i.ONE).grow(1).intersection(Rect2i(0,0,COLUMNS,ROWS))
			dirty_region=dirty_region.merge(region) if dirty_region.has_area() else region
		changed.emit("both" if height_changed and modified else ("terrain" if height_changed else "surfaces"))
	return height_changed or modified


func place_tee(point: Vector2) -> void:
	if contains(point):
		tee = point
		changed.emit("markers")


func place_cup(point: Vector2) -> void:
	if contains(point):
		cup = point
		cup_placed = true
		changed.emit("markers")


func cup_radius() -> float:
	return cup_diameter_m * .5


func capture_radius() -> float:
	return maxf(.001, cup_radius() - BallFlight.BALL_RADIUS)


func set_cup_diameter(value: float) -> void:
	cup_diameter_m = clampf(value, MIN_CUP_DIAMETER, MAX_CUP_DIAMETER)
	changed.emit("markers")


func add_tree(point: Vector2, species := "spruce") -> bool:
	if not contains(point) or trees.size() >= MAX_TREES or surface_at(point) in [Surface.WATER,Surface.OOB]: return false
	for tree in trees:
		if Vector2(tree.x,tree.z).distance_to(point) < 2.5: return false
	var rng := RandomNumberGenerator.new()
	rng.seed = seed + trees.size()*761 + int(point.x*17+point.y*31)
	trees.append({"x":point.x,"z":point.y,"species":species,"height":rng.randf_range(9,16),"rotation":rng.randf()*TAU})
	changed.emit("trees")
	return true


func erase_trees(point: Vector2, radius: float) -> bool:
	var kept: Array[Dictionary] = []
	for tree in trees:
		if Vector2(tree.x,tree.z).distance_to(point) > radius: kept.append(tree)
	if kept.size() == trees.size(): return false
	trees = kept
	changed.emit("trees")
	return true


func play_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if not cup_placed: errors.append("Place a cup on a painted green.")
	elif surface_at(cup) != Surface.GREEN: errors.append("The cup must be on the green.")
	if surface_at(tee) in [Surface.WATER,Surface.OOB]: errors.append("Move the tee onto a playable surface.")
	if cup_placed and tee.distance_to(cup) < 10: errors.append("Keep at least 10 m between tee and cup.")
	return errors


func snapshot() -> Dictionary:
	return {"id":id,"title":title,"par":par,"tee":tee,"cup":cup,"cup_placed":cup_placed,"cup_diameter_m":cup_diameter_m,
		"water_level":water_level,"seed":seed,"heights":heights.duplicate(),"surfaces":surfaces.duplicate(),
		"trees":trees.duplicate(true),"rules_overrides":rules_overrides.duplicate(true),"metadata":metadata.duplicate(true)}


func restore(state: Dictionary) -> void:
	id=state.id; title=state.title; par=state.par; tee=state.tee; cup=state.cup; cup_placed=state.cup_placed
	cup_diameter_m=state.get("cup_diameter_m",DEFAULT_CUP_DIAMETER)
	water_level=state.water_level; seed=state.seed; heights=state.heights.duplicate(); surfaces=state.surfaces.duplicate()
	trees.assign(state.trees.duplicate(true)); rules_overrides=state.rules_overrides.duplicate(true); metadata=state.metadata.duplicate(true)
	dirty_region=Rect2i(0,0,COLUMNS,ROWS)
	changed.emit("all")


func to_dict() -> Dictionary:
	return {"schema_version":SCHEMA_VERSION,"id":id,"title":title,"par":par,"seed":seed,
		"grid":{"columns":COLUMNS,"rows":ROWS,"spacing_m":CELL_SIZE},
		"tee":[tee.x,tee.y],"cup":[cup.x,cup.y],"cup_placed":cup_placed,"cup_diameter_m":cup_diameter_m,"water_level":water_level,
		"heights":Array(heights),"surfaces":Array(surfaces),"trees":trees.duplicate(true),
		"rules_overrides":rules_overrides.duplicate(true),"metadata":metadata.duplicate(true)}


static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func from_dict(data: Dictionary) -> HoleDefinition:
	if data.get("schema_version") != SCHEMA_VERSION: return null
	if not data.get("id") is String or not valid_id(data.id): return null
	if not data.get("title") is String or data.title.strip_edges().is_empty() or data.title.length()>80: return null
	if not _number(data.get("par")) or data.par != int(data.par) or data.par<3 or data.par>6: return null
	var grid: Variant=data.get("grid")
	if not grid is Dictionary or grid.get("columns")!=COLUMNS or grid.get("rows")!=ROWS or grid.get("spacing_m")!=CELL_SIZE: return null
	for key in ["tee","cup"]:
		var point: Variant=data.get(key)
		if not point is Array or point.size()!=2 or not _number(point[0]) or not _number(point[1]): return null
		if not BOUNDS.grow(.001).has_point(Vector2(point[0],point[1])): return null
	if not data.get("cup_placed") is bool: return null
	var diameter: Variant = data.get("cup_diameter_m",DEFAULT_CUP_DIAMETER)
	if not _number(diameter) or diameter<MIN_CUP_DIAMETER or diameter>MAX_CUP_DIAMETER:return null
	if not _number(data.get("water_level")) or data.water_level < -4 or data.water_level>4: return null
	if not _number(data.get("seed",6843)) or absf(float(data.get("seed",6843)))>2147483647: return null
	for key in ["heights","surfaces"]:
		var values: Variant=data.get(key)
		if not values is Array or values.size()!=CELL_COUNT: return null
		for value in values:
			if not _number(value): return null
			if key=="heights" and (value<MIN_HEIGHT or value>MAX_HEIGHT): return null
			if key=="surfaces" and (value!=int(value) or value<0 or value>Surface.OOB): return null
	var raw_trees: Variant=data.get("trees",[])
	if not raw_trees is Array or raw_trees.size()>MAX_TREES: return null
	for tree in raw_trees:
		if not tree is Dictionary: return null
		for key in ["x","z","height","rotation"]:
			if not _number(tree.get(key)): return null
		if not BOUNDS.grow(.001).has_point(Vector2(tree.x,tree.z)) or tree.height<3 or tree.height>24: return null
		if absf(float(tree.rotation))>TAU*10:return null
		if tree.get("species") not in ["spruce","aspen"]: return null
	if not data.get("rules_overrides",{}) is Dictionary or not data.get("metadata",{}) is Dictionary: return null
	var hole := HoleDefinition.new()
	hole.id=data.id; hole.title=data.title.strip_edges(); hole.par=int(data.par); hole.seed=int(data.get("seed",6843))
	hole.tee=Vector2(data.tee[0],data.tee[1]); hole.cup=Vector2(data.cup[0],data.cup[1]); hole.cup_placed=data.cup_placed
	hole.cup_diameter_m=float(diameter)
	hole.water_level=float(data.water_level); hole.heights=PackedFloat32Array(data.heights); hole.surfaces=PackedByteArray(data.surfaces)
	hole.trees.assign(raw_trees.duplicate(true)); hole.rules_overrides=data.get("rules_overrides",{}).duplicate(true)
	hole.metadata=data.get("metadata",{}).duplicate(true)
	return hole


static func valid_id(value: String) -> bool:
	if value.is_empty() or value.length()>80 or value.begins_with("_"): return false
	for character in value:
		if not (character>="a" and character<="z") and not (character>="A" and character<="Z") and not (character>="0" and character<="9") and character not in ["-","_"]: return false
	return true


static func demo() -> HoleDefinition:
	var hole := HoleDefinition.new()
	hole.id="pinewater-meadow"; hole.title="Pinewater Meadow"; hole.par=4
	for distance in range(0,300,8):
		var center := Vector2(sin(distance*.012)*14,20-distance)
		hole.apply_brush(center,17,"fairway")
	hole.apply_brush(Vector2(12,-280),20,"green")
	hole.place_cup(Vector2(12,-280))
	hole.apply_brush(Vector2(-22,-110),13,"water")
	hole.apply_brush(Vector2(34,-258),9,"sand")
	hole.apply_brush(Vector2(-32,-210),26,"raise",5,1)
	for z in range(-230,-79,12):hole.apply_brush(Vector2(105,z),10,"oob")
	for point in [Vector2(35,-70),Vector2(38,-90),Vector2(-40,-160),Vector2(-38,-180),Vector2(43,-215)]: hole.add_tree(point)
	return hole
