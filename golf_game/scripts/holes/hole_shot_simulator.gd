class_name HoleShotSimulator
extends RefCounted
## One custom-hole stepper for execution and preview, including sand response,
## trunk deflections, water contact and direct cup capture.
var model:=BallFlight.new()
var surface:HoleSurface
var origin:Vector3
var hazard:=false
var sinking:=false
var holed:=false
var _sink_elapsed:=0.0
var _sink_start:=Vector3.ZERO


func _init(shot:GolfShot, ground:HoleSurface, launch_origin:Vector3, yaw:float)->void:
	surface=ground;origin=launch_origin
	model.ground_height=surface.height_from_origin.bind(origin)
	model.ground_resistance=surface.resistance_from_origin.bind(origin)
	model.ground_bounce=surface.bounce_from_origin.bind(origin)
	model.launch(shot,yaw)


func step(delta:=BallFlight.STEP)->void:
	if model.finished:return
	if sinking:
		_sink_elapsed+=delta;model.elapsed+=delta
		var t:=smoothstep(0.0,.36,_sink_elapsed)
		var away:=Vector2(_sink_start.x,_sink_start.z)-surface.hole.cup
		if away.length_squared()<.000001:away=Vector2.RIGHT
		var resting_offset:=minf(surface.hole.capture_radius()-.0005,HoleDefinition.FLAGSTICK_RADIUS+BallFlight.BALL_RADIUS+.001)
		var resting_point:=surface.hole.cup+away.normalized()*resting_offset
		var bottom:=Vector3(resting_point.x,surface.cup_floor_height()+BallFlight.BALL_RADIUS,resting_point.y)
		model.position=_sink_start.lerp(bottom,t)-origin
		model.velocity=Vector3.ZERO;model.phase="HOLED"
		if _sink_elapsed>=.36:model.finished=true;holed=true
		return
	var previous:=origin+model.position
	model.step(delta)
	var point:=origin+model.position
	var hit:=surface.sweep_trunks(previous,point,BallFlight.BALL_RADIUS)
	if not hit.is_empty() and model.velocity.dot(hit.normal)<0:
		model.position=hit.point-origin
		model.velocity=(model.velocity-2*model.velocity.dot(hit.normal)*hit.normal)*.6
		model.finished=false;model.phase="BOUNCE"
		point=origin+model.position
	var swept_end:=point if not hit.is_empty() else origin+model.free_step_end
	var contact:Variant=_cup_contact(previous,swept_end)
	if contact!=null:
		_begin_sink(contact)
		return
	var kind:=surface.kind(point)
	if kind==HoleDefinition.Surface.WATER and point.y<=surface.hole.water_level+BallFlight.BALL_RADIUS+.02:
		hazard=true;model.finished=true;model.velocity=Vector3.ZERO;model.phase="REST"
	elif kind==HoleDefinition.Surface.OOB and not surface.hole.contains(Vector2(point.x,point.z)) and (not HoleDefinition.BOUNDS.grow(8).has_point(Vector2(point.x,point.z)) or point.y<.25):
		hazard=true;model.finished=true;model.velocity=Vector3.ZERO;model.phase="REST"


func _cup_gap(point:Vector3)->float:
	return point.y-surface.rim_height_at(point)-BallFlight.BALL_RADIUS


func _cup_contact(start:Vector3,finish:Vector3)->Variant:
	if not surface.hole.cup_placed:return null
	var center:=surface.hole.cup
	var radius:=surface.hole.capture_radius()
	var offset:=Vector2(start.x,start.z)-center
	var direction:=Vector2(finish.x-start.x,finish.z-start.z)
	var a:=direction.length_squared()
	var entry:=0.0;var exit:=1.0
	if a<.000000001:
		if offset.length_squared()>radius*radius:return null
	else:
		var b:=2.0*offset.dot(direction)
		var c:=offset.length_squared()-radius*radius
		var discriminant:=b*b-4*a*c
		if discriminant<0:return null
		entry=maxf(0.0,(-b-sqrt(discriminant))/(2*a))
		exit=minf(1.0,(-b+sqrt(discriminant))/(2*a))
		if exit<entry:return null
	var previous_t:=entry
	var previous:=start.lerp(finish,entry)
	var previous_gap:=_cup_gap(previous)
	# Sweep ground-level entries too: a fast ball can cross the entire opening
	# between ticks. There is no arbitrary slow-ball-only capture requirement.
	if absf(previous_gap)<=.025:return previous
	if offset.length_squared()<=radius*radius and previous_gap<0 and previous_gap> -HoleDefinition.CUP_DEPTH:
		return previous
	for index in range(1,9):
		var time:=lerpf(entry,exit,index/8.0)
		var point:=start.lerp(finish,time)
		var gap:=_cup_gap(point)
		if previous_gap>0 and gap<=0:
			var low:=previous_t;var high:=time
			for iteration in range(12):
				var middle:float=(low+high)*.5
				if _cup_gap(start.lerp(finish,middle))>0:low=middle
				else:high=middle
			return start.lerp(finish,high)
		previous_t=time;previous_gap=gap
	return null


func _begin_sink(point:Vector3)->void:
	sinking=true;_sink_elapsed=0.0;_sink_start=point
	model.position=point-origin;model.finished=false;model.velocity=Vector3.ZERO;model.phase="HOLED"
	if not model.has_landed:
		model.has_landed=true;model.first_landing=model.position
		model.carry_m=Vector2(model.position.x,model.position.z).length()


static func preview(shot:GolfShot,ground:HoleSurface,launch_origin:Vector3,yaw:float)->PackedVector3Array:
	var simulator:=HoleShotSimulator.new(shot,ground,launch_origin,yaw)
	var points:=PackedVector3Array([simulator.model.position])
	for frame in range(4800):
		simulator.step()
		if frame%12==0 or simulator.model.finished:points.append(simulator.model.position)
		if simulator.model.finished:break
	return points
