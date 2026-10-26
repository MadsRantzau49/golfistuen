class_name HoleShotSimulator
extends RefCounted
## One custom-hole stepper for execution and preview, including sand response,
## trunk deflections, water contact and direct cup capture.
var model:=BallFlight.new()
var surface:HoleSurface
var origin:Vector3
var hazard:=false


func _init(shot:GolfShot, ground:HoleSurface, launch_origin:Vector3, yaw:float)->void:
	surface=ground;origin=launch_origin
	model.ground_height=surface.height_from_origin.bind(origin)
	model.ground_resistance=surface.resistance_from_origin.bind(origin)
	model.ground_bounce=surface.bounce_from_origin.bind(origin)
	model.launch(shot,yaw)


func step(delta:=BallFlight.STEP)->void:
	if model.finished:return
	var previous:=origin+model.position
	model.step(delta)
	var point:=origin+model.position
	var hit:=surface.sweep_trunks(previous,point,BallFlight.BALL_RADIUS)
	if not hit.is_empty() and model.velocity.dot(hit.normal)<0:
		model.position=hit.point-origin
		model.velocity=(model.velocity-2*model.velocity.dot(hit.normal)*hit.normal)*.6
		model.finished=false;model.phase="BOUNCE"
		point=origin+model.position
	var kind:=surface.kind(point)
	if kind==HoleDefinition.Surface.WATER and point.y<=surface.hole.water_level+BallFlight.BALL_RADIUS+.02:
		hazard=true;model.finished=true;model.velocity=Vector3.ZERO;model.phase="REST"
	elif kind==HoleDefinition.Surface.OOB and not surface.hole.contains(Vector2(point.x,point.z)) and (not HoleDefinition.BOUNDS.grow(8).has_point(Vector2(point.x,point.z)) or point.y<.25):
		hazard=true;model.finished=true;model.velocity=Vector3.ZERO;model.phase="REST"
	elif kind==HoleDefinition.Surface.GREEN and Vector2(point.x,point.z).distance_to(surface.hole.cup)<.12 and model.velocity.length()<2.5 and point.y<=surface.world_height(point)+BallFlight.BALL_RADIUS+.04:
		var cup:=Vector3(surface.hole.cup.x,0,surface.hole.cup.y);cup.y=surface.world_height(cup)+BallFlight.BALL_RADIUS
		model.position=cup-origin;model.finished=true;model.velocity=Vector3.ZERO;model.phase="REST"


static func preview(shot:GolfShot,ground:HoleSurface,launch_origin:Vector3,yaw:float)->PackedVector3Array:
	var simulator:=HoleShotSimulator.new(shot,ground,launch_origin,yaw)
	var points:=PackedVector3Array([simulator.model.position])
	for frame in range(4800):
		simulator.step()
		if frame%12==0 or simulator.model.finished:points.append(simulator.model.position)
		if simulator.model.finished:break
	return points
