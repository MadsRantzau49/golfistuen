class_name GolfRelief
extends RefCounted
## Rule 19 validation in the virtual course. Fairway rescue is a separately
## declared simulator house rule; it never masquerades as free/standard relief.
const CLUB_LENGTH := 1.2


static func validate(hole:HoleDefinition,lie:Vector2,previous:Vector2,mode:String,point:Vector2,allow_rescue:bool)->Dictionary:
	var kind:=hole.surface_at(lie)
	if kind==HoleDefinition.Surface.WATER:return {"ok":false,"error":"Use penalty-area relief, not unplayable-ball relief."}
	if mode=="stroke_distance":return {"ok":true,"point":previous,"penalty":1,"rule":"19.2a · stroke and distance"}
	if not hole.contains(point) or hole.surface_at(point) in [HoleDefinition.Surface.WATER,HoleDefinition.Surface.OOB]:
		return {"ok":false,"error":"Choose a playable point inside the course."}
	if _blocked(hole,point):return {"ok":false,"error":"Choose a point clear of the tree trunk."}
	var old_distance:=lie.distance_to(hole.cup)
	if point.distance_to(hole.cup)+.01<old_distance:return {"ok":false,"error":"The drop cannot be nearer the cup."}
	if mode=="fairway_rescue":
		if not allow_rescue:return {"ok":false,"error":"Fairway rescue is disabled for this competition."}
		if hole.surface_at(point)!=HoleDefinition.Surface.FAIRWAY:return {"ok":false,"error":"Choose a painted fairway point."}
		return {"ok":true,"point":point,"penalty":2,"rule":"Simulator fairway rescue · house rule"}
	if mode=="lateral":
		if point.distance_to(lie)>2*CLUB_LENGTH+.01:return {"ok":false,"error":"Lateral relief must be within two virtual club-lengths (2.4 m)."}
		if kind==HoleDefinition.Surface.SAND and not _same_bunker(hole,lie,point):return {"ok":false,"error":"Lateral relief from a bunker must stay in that bunker."}
		return {"ok":true,"point":point,"penalty":1,"rule":"19.2c · lateral relief"}
	if mode in ["back_line","bunker_outside"]:
		var away:Vector2=(lie-hole.cup).normalized()
		var projection:float=(point-hole.cup).dot(away)
		var on_line:Vector2=hole.cup+away*projection
		if projection<old_distance-.01 or point.distance_to(on_line)>.35:return {"ok":false,"error":"Choose the line behind the ball, away from the cup."}
		if not hole.contains(on_line) or hole.surface_at(on_line) in [HoleDefinition.Surface.WATER,HoleDefinition.Surface.OOB]:return {"ok":false,"error":"The point on the relief line is not playable."}
		if _blocked(hole,on_line):return {"ok":false,"error":"The relief line meets a tree trunk here; choose another point."}
		if mode=="bunker_outside":
			if kind!=HoleDefinition.Surface.SAND or hole.surface_at(on_line)==HoleDefinition.Surface.SAND:return {"ok":false,"error":"This option is for a back-on-line drop outside a bunker."}
			return {"ok":true,"point":on_line,"penalty":2,"rule":"19.3b · outside-bunker back-on-line relief"}
		if kind==HoleDefinition.Surface.SAND and not _same_bunker(hole,lie,on_line):return {"ok":false,"error":"One-stroke back-on-line bunker relief must remain in the same bunker."}
		return {"ok":true,"point":on_line,"penalty":1,"rule":"19.2b · back-on-the-line relief"}
	return {"ok":false,"error":"Unknown relief option."}


static func nearest_fairway(hole:HoleDefinition,lie:Vector2)->Variant:
	var best:Variant=null;var distance:=INF
	var cup_distance:=lie.distance_to(hole.cup)
	for index in range(HoleDefinition.CELL_COUNT):
		if hole.surfaces[index]!=HoleDefinition.Surface.FAIRWAY:continue
		var point:=hole.grid_point(index%HoleDefinition.COLUMNS,index/HoleDefinition.COLUMNS)
		var candidate:=point.distance_squared_to(lie)
		if candidate<distance and point.distance_to(hole.cup)+.01>=cup_distance and not _blocked(hole,point):
			best=point;distance=candidate
	return best


static func _blocked(hole:HoleDefinition,point:Vector2)->bool:
	for tree in hole.trees:
		if point.distance_to(Vector2(tree.x,tree.z))<float(tree.height)*.022+BallFlight.BALL_RADIUS+.03:return true
	return false


static func _same_bunker(hole:HoleDefinition,start:Vector2,finish:Vector2)->bool:
	if hole.surface_at(finish)!=HoleDefinition.Surface.SAND:return false
	var target:=hole.cell_index(finish);var first:=hole.cell_index(start)
	var queue:Array[int]=[first];var visited:Dictionary={first:true};var cursor:=0
	while cursor<queue.size():
		var index:=queue[cursor];cursor+=1
		if index==target:return true
		for neighbour in [index-1,index+1,index-HoleDefinition.COLUMNS,index+HoleDefinition.COLUMNS]:
			if neighbour<0 or neighbour>=HoleDefinition.CELL_COUNT or visited.has(neighbour):continue
			if absi(neighbour%HoleDefinition.COLUMNS-index%HoleDefinition.COLUMNS)>1:continue
			if hole.surfaces[neighbour]==HoleDefinition.Surface.SAND:visited[neighbour]=true;queue.append(neighbour)
	return false
