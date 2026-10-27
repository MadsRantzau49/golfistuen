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
var shot_log: Array[Dictionary] = []
var previous_stroke_lie:=Vector2.ZERO
var pickup_adjustment:=0


func _init(definition: HoleDefinition, configuration: HoleRules) -> void:
	hole=definition; rules=configuration; lie=hole.tee; last_safe_lie=lie;previous_stroke_lie=lie


func begin_shot(_id: String = "") -> bool:
	if state!=State.READY:return false
	strokes+=1
	previous_stroke_lie=lie
	state=State.IN_FLIGHT
	return true


func resolve_rest(point: Vector2) -> Dictionary:
	if state!=State.IN_FLIGHT: return {}
	var kind := hole.surface_at(point)
	var entry := {"shot":strokes,"from":[lie.x,lie.y],"to":[point.x,point.y],"surface":kind,"penalty":0,"awarded_putts":0}
	if kind in [HoleDefinition.Surface.WATER,HoleDefinition.Surface.OOB]:
		var penalty: int=rules.options.water_penalty if kind==HoleDefinition.Surface.WATER else rules.options.oob_penalty
		penalty=mini(penalty,_remaining())
		penalties+=penalty; entry.penalty=penalty; lie=last_safe_lie
		last_outcome="Water · +%d penalty · replay from previous lie"%penalty if kind==HoleDefinition.Surface.WATER else "Out of bounds · +%d penalty · replay from previous lie"%penalty
		state=State.READY
	elif kind==HoleDefinition.Surface.GREEN:
		lie=point
		var holed := point.distance_to(hole.cup)<=hole.capture_radius()
		awarded_putts=0 if holed else mini(int(rules.options.green_putts),_remaining())
		entry.awarded_putts=awarded_putts
		last_outcome="Holed!" if holed else "Green reached · +%d automatic strokes"%awarded_putts
		finish_reason="holed" if holed else "green_auto"
		state=State.COMPLETE
	else:
		lie=point; last_safe_lie=point; state=State.READY
		last_outcome="Next shot · %s"%HoleDefinition.SURFACE_NAMES[kind]
	shot_log.append(entry)
	_check_limit()
	return entry


func gross_score() -> int:
	return strokes+penalties+awarded_putts+pickup_adjustment


func _remaining()->int:
	var cap:=int(rules.options.max_strokes)
	return maxi(0,cap-strokes-penalties) if cap>0 else 1000000


func _check_limit()->void:
	var cap:=int(rules.options.max_strokes)
	if cap>0 and gross_score()>=cap and state!=State.COMPLETE:
		state=State.COMPLETE;last_outcome="Maximum score reached";finish_reason="stroke_limit"


func give_up(maximum_score:bool)->bool:
	if state!=State.READY:return false
	if maximum_score:
		pickup_adjustment=maxi(0,int(rules.options.max_strokes)-gross_score())
		finish_reason="picked_up";last_outcome="Picked up · maximum score recorded"
	else:
		finish_reason="dnf";last_outcome="Did not finish · round unclassified"
	state=State.COMPLETE
	return true


func take_relief(mode:String,point:Vector2,allow_rescue:bool)->Dictionary:
	if state!=State.READY:return {"ok":false,"error":"Wait until the current shot is complete."}
	var outcome:=GolfRelief.validate(hole,lie,previous_stroke_lie,mode,point,allow_rescue)
	if not outcome.ok:return outcome
	var old:=lie
	var penalty:=mini(int(outcome.penalty),_remaining())
	penalties+=penalty;lie=outcome.point;last_safe_lie=lie
	shot_log.append({"action":"relief","from":[old.x,old.y],"to":[lie.x,lie.y],"penalty":penalty,"rule":outcome.rule})
	last_outcome="%s · +%d"%[outcome.rule,penalty]
	if hole.surface_at(lie)==HoleDefinition.Surface.GREEN:
		awarded_putts=mini(int(rules.options.green_putts),_remaining());state=State.COMPLETE;finish_reason="green_auto"
	_check_limit()
	return outcome


func snapshot()->Dictionary:
	return {"state":state,"strokes":strokes,"penalties":penalties,"awarded_putts":awarded_putts,
		"lie":[lie.x,lie.y],"last_safe_lie":[last_safe_lie.x,last_safe_lie.y],
		"previous_stroke_lie":[previous_stroke_lie.x,previous_stroke_lie.y],"last_outcome":last_outcome,
		"finish_reason":finish_reason,"pickup_adjustment":pickup_adjustment,"shot_log":shot_log.duplicate(true),"rules":rules.to_dict()}


static func restore(definition:HoleDefinition,data:Dictionary)->HoleRound:
	for key in ["lie","last_safe_lie","previous_stroke_lie"]:
		var value:Variant=data.get(key)
		if not value is Array or value.size()!=2 or not HoleDefinition._number(value[0]) or not HoleDefinition._number(value[1]):return null
	for key in ["state","strokes","penalties","awarded_putts","pickup_adjustment"]:
		if not HoleDefinition._number(data.get(key)) or data[key]!=int(data[key]) or data[key]<0:return null
	if data.state>State.COMPLETE or data.strokes>10000 or data.penalties>10000:return null
	if not data.get("rules") is Dictionary or not data.get("shot_log") is Array:return null
	var attempt:=HoleRound.new(definition,HoleRules.create(data.rules))
	attempt.state=int(data.state);attempt.strokes=int(data.strokes);attempt.penalties=int(data.penalties);attempt.awarded_putts=int(data.awarded_putts)
	attempt.pickup_adjustment=int(data.pickup_adjustment);attempt.lie=Vector2(data.lie[0],data.lie[1]);attempt.last_safe_lie=Vector2(data.last_safe_lie[0],data.last_safe_lie[1])
	attempt.previous_stroke_lie=Vector2(data.previous_stroke_lie[0],data.previous_stroke_lie[1]);attempt.last_outcome=str(data.get("last_outcome","Ready"));attempt.finish_reason=str(data.get("finish_reason",""))
	for entry in data.shot_log:
		if not entry is Dictionary:return null
		attempt.shot_log.append(entry.duplicate(true))
	return attempt


func result() -> Dictionary:
	return {"schema_version":1,"hole_id":hole.id,"hole_name":hole.title,"par":hole.par,"cup_diameter_m":hole.cup_diameter_m,
		"strokes":strokes,"penalty_strokes":penalties,"automatic_putts":awarded_putts,"pickup_adjustment":pickup_adjustment,
		"gross_score":gross_score(),"relative_to_par":gross_score()-hole.par,
		"complete":state==State.COMPLETE,"finish_reason":finish_reason,"rules":rules.to_dict(),"shots":shot_log.duplicate(true),"hole_metadata":hole.metadata.duplicate(true)}
