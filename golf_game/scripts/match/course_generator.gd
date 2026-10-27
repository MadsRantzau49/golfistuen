class_name CourseGenerator
extends RefCounted
## Deterministic original layouts. Geometry remains compatible with Hole Studio.
const NAMES := ["Pinewater","Larch Bend","Silver Creek","The Lookout","Cedar Run","Bluebird","Golden Meadow","North Ridge","Quiet Pines","Wildflower","Glacier View","Evening Light"]


static func hole(seed_value:int,index:int,cup_diameter:=.3)->HoleDefinition:
	var rng:=RandomNumberGenerator.new();rng.seed=seed_value+index*104729
	var document:=HoleDefinition.new();document.seed=seed_value+index
	document.id="generated-%x-%02d"%[seed_value,index+1]
	document.title="%02d · %s"%[index+1,NAMES[index%NAMES.size()]]
	document.par=3 if index%3==0 else (5 if index%3==2 else 4)
	var length:=rng.randf_range(115,165) if document.par==3 else (rng.randf_range(345,410) if document.par==5 else rng.randf_range(245,315))
	var cup:=Vector2(rng.randf_range(-25,25),20-length)
	var bend:=rng.randf_range(-18,18)
	for distance in range(0,ceili(length)+1,6):
		var t:=minf(float(distance)/length,1)
		var point:=Vector2(lerpf(0,cup.x,t)+sin(t*PI)*bend,20-distance)
		document.apply_brush(point,rng.randf_range(16,20),"fairway")
	for hill in range(3):
		var side:float=-1 if hill%2==0 else 1
		var point:=Vector2(side*rng.randf_range(30,65),rng.randf_range(cup.y+30,-25))
		document.apply_brush(point,rng.randf_range(20,35),"lower" if hill==2 else "raise",rng.randf_range(1.5,4),1)
	if document.par>3:
		document.apply_brush(Vector2(-35 if bend>=0 else 35,20-length*.48),rng.randf_range(10,16),"water")
	for bunker in range(2):
		var side:float=-1 if bunker==0 else 1
		var point:=cup+Vector2(side*24,rng.randf_range(-6,14))
		document.apply_brush(point,8,"sand");document.apply_brush(point,8,"lower",.6,1)
	document.apply_brush(cup,19,"flatten",20,1,0)
	document.apply_brush(cup,16,"green");document.place_cup(cup)
	document.set_cup_diameter(cup_diameter)
	for z in range(-230,-60,12):document.apply_brush(Vector2(106,z),9,"oob")
	for tree in range(14):
		var side:float=-1 if tree%2==0 else 1
		document.add_tree(Vector2(side*rng.randf_range(32,75),rng.randf_range(cup.y+10,8)),"aspen" if tree%4==0 else "spruce")
	document.metadata={"generator_seed":seed_value,"generator_index":index}
	return document
