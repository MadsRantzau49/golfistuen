class_name HoleSurface
extends RangeSurface
## Renderer and flight model query the same edited triangles and surface IDs.
var hole: HoleDefinition


func _init(terrain: AlpineLandscape, document: HoleDefinition)->void:
	super(terrain)
	hole=document


func kind(point: Vector3)->int:
	return hole.surface_at(Vector2(point.x,point.z))


func is_mat(_point:Vector3)->bool: return false
func is_deck(_point:Vector3)->bool: return false
func is_target(point:Vector3)->bool: return kind(point)==HoleDefinition.Surface.GREEN
func is_fairway(point:Vector3)->bool: return kind(point)==HoleDefinition.Surface.FAIRWAY


func has_grass(point:Vector3)->bool:
	return kind(point) in [HoleDefinition.Surface.ROUGH,HoleDefinition.Surface.FAIRWAY,HoleDefinition.Surface.GREEN]


func canopy_height(point:Vector3)->float:
	if inside_cup(point):return 0.0
	return _canopy_without_cup(point)


func _canopy_without_cup(point:Vector3)->float:
	var value:=kind(point)
	if value in [HoleDefinition.Surface.SAND,HoleDefinition.Surface.WATER,HoleDefinition.Surface.OOB]: return 0.0
	return lerpf(ROUGH_CANOPY,FAIRWAY_CANOPY,hole.short_grass_weight(Vector2(point.x,point.z)))


func base_height(point:Vector3)->float:
	if inside_cup(point):return cup_floor_height()
	if not hole.contains(Vector2(point.x,point.z)): return landscape.rendered_height(point.x,point.z)
	if kind(point)==HoleDefinition.Surface.WATER: return hole.water_level
	return hole.height_at(Vector2(point.x,point.z))


func world_height(point:Vector3)->float:
	return base_height(point)+canopy_height(point)


func inside_cup(point:Vector3)->bool:
	return hole.cup_placed and Vector2(point.x,point.z).distance_to(hole.cup)<hole.capture_radius()


func rim_height_at(point:Vector3)->float:
	return hole.height_at(Vector2(point.x,point.z))+_canopy_without_cup(point)


func cup_rim_height()->float:
	return rim_height_at(Vector3(hole.cup.x,0,hole.cup.y))


func cup_floor_height()->float:
	return cup_rim_height()-HoleDefinition.CUP_DEPTH


func visual_radius_limit(point:Vector3)->float:
	if not hole.cup_placed:return .25
	var distance:=Vector2(point.x,point.z).distance_to(hole.cup)
	if distance>=hole.cup_radius():return .25
	var wall_limit:=hole.cup_radius()-distance-.001
	var pole_limit:=maxf(BallFlight.BALL_RADIUS,distance-HoleDefinition.FLAGSTICK_RADIUS-.0005)
	return clampf(minf(wall_limit,pole_limit),BallFlight.BALL_RADIUS,.25)


func height_from_origin(point:Vector3, origin:Vector3)->float:
	return world_height(point+origin)-origin.y


func resistance_from_origin(point:Vector3, origin:Vector3)->float:
	match kind(point+origin):
		HoleDefinition.Surface.GREEN: return .85
		HoleDefinition.Surface.FAIRWAY: return 1.9
		HoleDefinition.Surface.SAND: return 8.0
		_: return 4.2


func bounce_from_origin(point:Vector3, origin:Vector3)->Vector2:
	match kind(point+origin):
		HoleDefinition.Surface.SAND: return Vector2(.1,.42)
		HoleDefinition.Surface.ROUGH: return Vector2(.18,.58)
		HoleDefinition.Surface.GREEN: return Vector2(.22,.68)
		_: return Vector2(.28,.72)


func sweep_trunks(start:Vector3, finish:Vector3, radius:float)->Dictionary:
	var direction:=Vector2(finish.x-start.x,finish.z-start.z)
	var a:=direction.length_squared()
	if a<.0000001: return {}
	var earliest:=2.0
	var result:Dictionary={}
	for tree in hole.trees:
		var center:=Vector2(tree.x,tree.z)
		var offset:=Vector2(start.x,start.z)-center
		var trunk_radius:float=tree.height*.022+radius
		var b:=2.0*offset.dot(direction)
		var c:=offset.length_squared()-trunk_radius*trunk_radius
		var discriminant:=b*b-4*a*c
		if discriminant<0: continue
		var t:=(-b-sqrt(discriminant))/(2*a)
		if t<0 or t>1 or t>=earliest: continue
		var point:=start.lerp(finish,t)
		var ground:=hole.height_at(center)
		if point.y<ground or point.y>ground+float(tree.height)*.8: continue
		var normal:=Vector3(point.x-center.x,0,point.z-center.y).normalized()
		if normal.length_squared()<.5: continue
		earliest=t; result={"point":point+normal*.003,"normal":normal}
	return result
