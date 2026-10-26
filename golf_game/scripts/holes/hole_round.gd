class_name HoleRound
extends RefCounted
## Gross-stroke accounting. No putting phase exists: a stopped green ball receives
## the configured additional strokes. Penalties use stroke-and-distance drops.

enum State { READY, IN_FLIGHT, COMPLETE }
var hole: HoleDefinition
var rules: HoleRules
var state := State.READY
var strokes := 0
var penalties := 0
var awarded_putts := 0
var lie := Vector2.ZERO
var last_safe_lie := Vector2.ZERO
var last_outcome := "Ready"
var finish_reason := ""
var accepted_ids: Dictionary = {}
var shot_log: Array[Dictionary] = []


func _init(definition: HoleDefinition, configuration: HoleRules) -> void:
	hole=definition; rules=configuration; lie=hole.tee; last_safe_lie=lie


func begin_shot(id: String) -> bool:
	if state!=State.READY or accepted_ids.has(id): return false
	accepted_ids[id]=true
	strokes+=1
	state=State.IN_FLIGHT
	return true


func resolve_rest(point: Vector2) -> Dictionary:
	if state!=State.IN_FLIGHT: return {}
	var kind := hole.surface_at(point)
	var entry := {"shot":strokes,"from":[lie.x,lie.y],"to":[point.x,point.y],"surface":kind,"penalty":0,"awarded_putts":0}
	if kind in [HoleDefinition.Surface.WATER,HoleDefinition.Surface.OOB]:
		var penalty: int=rules.options.water_penalty if kind==HoleDefinition.Surface.WATER else rules.options.oob_penalty
		penalty=mini(penalty,maxi(0,int(rules.options.max_strokes)-strokes-penalties))
		penalties+=penalty; entry.penalty=penalty; lie=last_safe_lie
		last_outcome="Water · +%d penalty · replay from previous lie"%penalty if kind==HoleDefinition.Surface.WATER else "Out of bounds · +%d penalty · replay from previous lie"%penalty
		state=State.READY
	elif kind==HoleDefinition.Surface.GREEN:
		lie=point
		var holed := point.distance_to(hole.cup)<=.12
		awarded_putts=0 if holed else mini(int(rules.options.green_putts),maxi(0,int(rules.options.max_strokes)-strokes-penalties))
		entry.awarded_putts=awarded_putts
		last_outcome="Holed!" if holed else "Green reached · +%d automatic strokes"%awarded_putts
		finish_reason="holed" if holed else "green_auto"
		state=State.COMPLETE
	else:
		lie=point; last_safe_lie=point; state=State.READY
		last_outcome="Next shot · %s"%HoleDefinition.SURFACE_NAMES[kind]
	shot_log.append(entry)
	if gross_score()>=int(rules.options.max_strokes) and state!=State.COMPLETE:
		state=State.COMPLETE; last_outcome="Stroke limit reached";finish_reason="stroke_limit"
	return entry


func gross_score() -> int:
	return strokes+penalties+awarded_putts


func result() -> Dictionary:
	return {"schema_version":1,"hole_id":hole.id,"hole_name":hole.title,"par":hole.par,
		"strokes":strokes,"penalty_strokes":penalties,"automatic_putts":awarded_putts,
		"gross_score":gross_score(),"relative_to_par":gross_score()-hole.par,
		"complete":state==State.COMPLETE,"finish_reason":finish_reason,"rules":rules.to_dict(),"shots":shot_log.duplicate(true),"hole_metadata":hole.metadata.duplicate(true)}
