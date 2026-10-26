class_name NatureMeshes
extends RefCounted
## Sculpted reusable tree/rock/grass meshes. Vertex-colored, batched with MultiMesh.
## Spruce boughs are made of overlapping needle cushions, never stacked cones.

var rng := RandomNumberGenerator.new()
var tool: SurfaceTool


func _init(seed_value := 843) -> void:
	rng.seed = seed_value


func _begin() -> void:
	tool = SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)


func _ellipsoid(center: Vector3, scale: Vector3, color: Color, sides := 7, rings := 4) -> void:
	for row in range(rings):
		for col in range(sides):
			var points: Array[Vector3] = []
			for uv in [Vector2(col,row), Vector2(col,row+1), Vector2(col+1,row),
				Vector2(col+1,row),Vector2(col,row+1),Vector2(col+1,row+1)]:
				var a: float = uv.x/float(sides)*TAU
				var b: float = uv.y/float(rings)*PI
				points.append(Vector3(sin(b)*cos(a),cos(b),sin(b)*sin(a)))
			for normal in points:
				tool.set_color(color)
				tool.set_normal((normal/scale).normalized())
				tool.add_vertex(center+normal*scale)


func _branch(start: Vector3, end: Vector3, radius: float, color: Color) -> void:
	var axis := (end-start).normalized()
	var tangent := axis.cross(Vector3.FORWARD).normalized()
	if tangent.length_squared() < .1:
		tangent = axis.cross(Vector3.RIGHT).normalized()
	var bitangent := axis.cross(tangent).normalized()
	for index in range(6):
		var a := TAU*index/6.0
		var b := TAU*(index+1)/6.0
		var na := tangent*cos(a)+bitangent*sin(a)
		var nb := tangent*cos(b)+bitangent*sin(b)
		for vertex in [start+na*radius,end+na*radius*.4,start+nb*radius,
			start+nb*radius,end+na*radius*.4,end+nb*radius*.4]:
			tool.set_color(color)
			tool.set_normal((na+nb).normalized())
			tool.add_vertex(vertex)


func spruce(detailed:=false) -> ArrayMesh:
	_begin()
	var sides:=9 if detailed else 6
	var rings:=5 if detailed else 3
	_branch(Vector3.ZERO,Vector3(0,1,0),.018,Color("46382a"))
	for level in range(9):
		var y := .18+level*.088
		var length := (.33*(1.0-y)+.015)*rng.randf_range(.85,1.1)
		_ellipsoid(Vector3(0,y,0),Vector3(length*.48,.07,length*.48),Color("354f32"),sides,rings)
		var count := 6 if level < 6 else 5
		for branch in range(count):
			var angle := TAU*branch/count+level*1.7+rng.randf_range(-.15,.15)
			var radial := Vector3(cos(angle),0,sin(angle))
			var start := Vector3(0,y,0)
			var tip := start+radial*length+Vector3(0,-.045,0)
			_branch(start,tip,.0035,Color("514631"))
			for tuft in range(3):
				var t := .35+tuft*.29
				var center := start.lerp(tip,t)+Vector3(0,.015,0)
				var size := length*(.36-tuft*.045)
				var color := Color("294831").lerp(Color("57734a"),rng.randf()*.75)
				_ellipsoid(center,Vector3(size,size*.65,size*.8),color,sides,rings)
	_ellipsoid(Vector3(0,.97,0),Vector3(.025,.05,.025),Color("50704a"),sides,rings)
	tool.index()
	return tool.commit()


func aspen() -> ArrayMesh:
	_begin()
	_branch(Vector3.ZERO,Vector3(.015,.82,0),.017,Color("c8c3a5"))
	for index in range(15):
		var angle := index*2.4
		var y := rng.randf_range(.45,.91)
		var radial := Vector3(cos(angle),.35,sin(angle))
		var center := Vector3(0,y,0)+radial*rng.randf_range(.06,.2)
		_branch(Vector3(0,y-.15,0),center,.004,Color("9a9677"))
		var color := Color("9c992e").lerp(Color("dbb64e"),rng.randf())
		_ellipsoid(center,Vector3(.13,.16,.12),color,8,5)
	tool.index()
	return tool.commit()


func stone() -> ArrayMesh:
	_begin()
	_ellipsoid(Vector3(0,.22,0),Vector3(.6,.5,.48),Color("777c69"),9,5)
	tool.index()
	return tool.commit()


func grass() -> ArrayMesh:
	_begin()
	for index in range(7):
		var angle := rng.randf()*TAU
		var base := Vector3(rng.randf_range(-.15,.15),0,rng.randf_range(-.15,.15))
		var side := Vector3(cos(angle),0,sin(angle))*.025
		var tip := base+Vector3(rng.randf_range(-.12,.12),rng.randf_range(.3,.65),0)
		for point in [base-side,base+side,tip]:
			tool.set_color(Color("6a812b") if point.y > .1 else Color("35481d"))
			tool.set_normal(Vector3.UP)
			tool.add_vertex(point)
	return tool.commit()


func flowers()->ArrayMesh:
	_begin()
	for bloom in range(3):
		var center:=Vector3(rng.randf_range(-.16,.16),rng.randf_range(.3,.55),rng.randf_range(-.16,.16))
		_branch(Vector3(center.x,0,center.z),center,.008,Color("52623a"))
		for petal in range(5):
			var angle:=petal*TAU/5
			_ellipsoid(center+Vector3(cos(angle),.02,sin(angle))*.055,
				Vector3(.05,.017,.05),Color("e5dba4"),6,3)
		_ellipsoid(center+Vector3(0,.025,0),Vector3(.03,.025,.03),Color("b68d35"),6,3)
	tool.index()
	return tool.commit()
