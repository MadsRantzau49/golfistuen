class_name HoleWorld
extends Node3D
## Editable foreground only. AlpineRange supplies the unchanged surrounding world.
var hole: HoleDefinition
var surface: HoleSurface
var backdrop: AlpineRange
var editing := true
var terrain: MeshInstance3D
var water: MeshInstance3D
var trees_root: Node3D
var markers_root: Node3D
var fader: ObstructionFader
var close_turf: CloseTurf
var height_texture: ImageTexture
var surface_texture: ImageTexture
var oob_texture: ImageTexture
var material: ShaderMaterial
var _mesh_dirty := true
var _maps_dirty := true
var _trees_dirty := true
var _markers_dirty := true
var _elapsed := 0.0
var _spruce: Mesh
var _aspen: Mesh
var _surface_dirty:=true
var _mesh_initialized:=false
var _vertices:=PackedVector3Array()
var _normals:=PackedVector3Array()
var _indices:=PackedInt32Array()


func _ready()->void:
	fader=ObstructionFader.new(); add_child(fader)
	terrain=MeshInstance3D.new(); add_child(terrain)
	material=ShaderMaterial.new(); material.shader=preload("res://shaders/hole_ground.gdshader")
	material.set_shader_parameter("turf_color",preload("res://assets/turf/Grass004_2K-JPG_Color.jpg"))
	material.set_shader_parameter("turf_normal",preload("res://assets/turf/Grass004_2K-JPG_NormalGL.jpg"))
	terrain.material_override=material
	water=MeshInstance3D.new()
	var plane:=PlaneMesh.new(); plane.size=HoleDefinition.BOUNDS.size
	water.mesh=plane
	var water_material:=ShaderMaterial.new(); water_material.shader=preload("res://shaders/hole_water.gdshader")
	water.material_override=water_material; water.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(water)
	_spruce=NatureMeshes.new(587).spruce(true)
	_aspen=NatureMeshes.new(858).aspen()


func set_document(document:HoleDefinition)->void:
	if hole and hole.changed.is_connected(_on_changed): hole.changed.disconnect(_on_changed)
	hole=document
	_mesh_initialized=false;_surface_dirty=true
	surface=HoleSurface.new(backdrop.landscape,hole)
	hole.changed.connect(_on_changed)
	_mesh_dirty=true; _maps_dirty=true; _trees_dirty=true; _markers_dirty=true
	sync_now()
	if close_turf: close_turf.free()
	close_turf=CloseTurf.new()
	close_turf.surface=surface
	close_turf.shader_override=preload("res://shaders/hole_turf.gdshader")
	close_turf.terrain_maps={"height_field":height_texture,"surface_map":surface_texture,"oob_map":oob_texture}
	add_child(close_turf)
	close_turf.apply_quality(str(GameSettings.get_value("quality")))


func set_editing(value:bool)->void:
	editing=value
	if editing:fader.enabled=false
	material.set_shader_parameter("editor_mode",editing)
	if close_turf:
		close_turf.visible=not editing
		close_turf.set_process(not editing)


func _on_changed(kind:String)->void:
	_maps_dirty=_maps_dirty or kind in ["all","terrain","surfaces","both"]
	_surface_dirty=_surface_dirty or kind in ["all","surfaces","both"]
	_mesh_dirty=_mesh_dirty or kind in ["all","terrain","both"]
	_trees_dirty=_trees_dirty or kind in ["all","terrain","trees","both"]
	_markers_dirty=_markers_dirty or kind in ["all","terrain","markers","surfaces","both"]


func _process(delta:float)->void:
	_elapsed+=delta
	if _elapsed>=.09:
		_elapsed=0
		sync_now()


func sync_now()->void:
	if hole==null:return
	if _maps_dirty: _upload_maps()
	if _mesh_dirty: _build_mesh()
	if _trees_dirty: _build_trees()
	if _markers_dirty: _build_markers()
	material.set_shader_parameter("editor_mode",editing)
	water.position=Vector3(0,hole.water_level,-200)
	_mesh_dirty=false; _maps_dirty=false; _trees_dirty=false; _markers_dirty=false;_surface_dirty=false


func _upload_maps()->void:
	var height_image:=Image.create_from_data(HoleDefinition.COLUMNS,HoleDefinition.ROWS,false,Image.FORMAT_RF,hole.heights.to_byte_array())
	if height_texture:height_texture.update(height_image)
	else:height_texture=ImageTexture.create_from_image(height_image)
	if surface_texture and not _surface_dirty:return
	var colors:=PackedByteArray(); colors.resize(HoleDefinition.CELL_COUNT*4); colors.fill(0)
	var bounds:=PackedByteArray(); bounds.resize(HoleDefinition.CELL_COUNT); bounds.fill(0)
	for index in range(HoleDefinition.CELL_COUNT):
		match hole.surfaces[index]:
			HoleDefinition.Surface.FAIRWAY: colors[index*4]=255
			HoleDefinition.Surface.GREEN: colors[index*4+1]=255
			HoleDefinition.Surface.SAND: colors[index*4+2]=255
			HoleDefinition.Surface.WATER: colors[index*4+3]=255
			HoleDefinition.Surface.OOB: bounds[index]=255
	var surface_image:=Image.create_from_data(HoleDefinition.COLUMNS,HoleDefinition.ROWS,false,Image.FORMAT_RGBA8,colors)
	var oob_image:=Image.create_from_data(HoleDefinition.COLUMNS,HoleDefinition.ROWS,false,Image.FORMAT_R8,bounds)
	if surface_texture:
		surface_texture.update(surface_image); oob_texture.update(oob_image)
	else:
		surface_texture=ImageTexture.create_from_image(surface_image)
		oob_texture=ImageTexture.create_from_image(oob_image)
	material.set_shader_parameter("surface_map",surface_texture)
	material.set_shader_parameter("oob_map",oob_texture)
	water.material_override.set_shader_parameter("surface_map",surface_texture)


func _build_mesh()->void:
	if _vertices.is_empty():_vertices.resize(HoleDefinition.CELL_COUNT);_normals.resize(HoleDefinition.CELL_COUNT)
	var region:=hole.dirty_region if _mesh_initialized else Rect2i(0,0,HoleDefinition.COLUMNS,HoleDefinition.ROWS)
	for row in range(region.position.y,region.end.y):
		for col in range(region.position.x,region.end.x):
			var index:=row*HoleDefinition.COLUMNS+col
			var point:=hole.grid_point(col,row)
			_vertices[index]=Vector3(point.x,hole.heights[index],point.y)
			var dx:=hole.heights[row*HoleDefinition.COLUMNS+maxi(0,col-1)]-hole.heights[row*HoleDefinition.COLUMNS+mini(HoleDefinition.COLUMNS-1,col+1)]
			var dz:=hole.heights[maxi(0,row-1)*HoleDefinition.COLUMNS+col]-hole.heights[mini(HoleDefinition.ROWS-1,row+1)*HoleDefinition.COLUMNS+col]
			_normals[index]=Vector3(dx,HoleDefinition.CELL_SIZE*2,dz).normalized()
	if _indices.is_empty():
		for row in range(HoleDefinition.ROWS-1):
			for col in range(HoleDefinition.COLUMNS-1):
				var a:=row*HoleDefinition.COLUMNS+col
				_indices.append_array(PackedInt32Array([a,a+1,a+HoleDefinition.COLUMNS,a+1,a+HoleDefinition.COLUMNS+1,a+HoleDefinition.COLUMNS]))
	var arrays:Array=[]; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=_vertices; arrays[Mesh.ARRAY_NORMAL]=_normals; arrays[Mesh.ARRAY_INDEX]=_indices
	var mesh:=ArrayMesh.new(); mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	terrain.mesh=mesh
	_mesh_initialized=true;hole.dirty_region=Rect2i()


func _replace_root(old:Node3D,name_value:String)->Node3D:
	if is_instance_valid(old): fader.unregister_subtree(old); old.free()
	var node:=Node3D.new(); node.name=name_value; add_child(node)
	return node


func _build_trees()->void:
	trees_root=_replace_root(trees_root,"PlacedTrees")
	for species in ["spruce","aspen"]:
		var transforms:Array[Transform3D]=[]
		for tree in hole.trees:
			if tree.species!=species:continue
			var scale_value:float=tree.height
			transforms.append(Transform3D(Basis(Vector3.UP,tree.rotation).scaled(Vector3.ONE*scale_value),
				Vector3(tree.x,hole.height_at(Vector2(tree.x,tree.z))-.08,tree.z)))
		if transforms.is_empty():continue
		var mesh:Mesh=_spruce if species=="spruce" else _aspen
		var batch:=MultiMeshInstance3D.new(); var multi:=MultiMesh.new()
		multi.transform_format=MultiMesh.TRANSFORM_3D; multi.use_custom_data=true; multi.mesh=mesh; multi.instance_count=transforms.size()
		for index in range(transforms.size()):
			multi.set_instance_transform(index,transforms[index]); multi.set_instance_custom_data(index,Color(0,0,0,1))
		batch.multimesh=multi; batch.material_override=backdrop.foliage_material; batch.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		trees_root.add_child(batch)
		var shadow:=MultiMeshInstance3D.new(); shadow.multimesh=multi; shadow.material_override=backdrop.foliage_shadow_material
		shadow.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY; trees_root.add_child(shadow)
		for index in range(transforms.size()):fader.register_instance(batch,index,transforms[index]*mesh.get_aabb())


func _build_markers()->void:
	markers_root=_replace_root(markers_root,"TeeAndCup")
	var tee_position:=Vector3(hole.tee.x,0,hole.tee.y); tee_position.y=surface.world_height(tee_position)
	for x in [-1.0,1.0]:
		var sphere:=SphereMesh.new(); sphere.radius=.13; sphere.height=.26
		_object(sphere,tee_position+Vector3(x,.13,0),Color("d7c28c"))
	if hole.cup_placed:
		var center:=Vector3(hole.cup.x,0,hole.cup.y); center.y=surface.world_height(center)
		var cup_mesh:=CylinderMesh.new(); cup_mesh.top_radius=.065; cup_mesh.bottom_radius=.065; cup_mesh.height=.12
		_object(cup_mesh,center-Vector3(0,.06,0),Color("11251d"))
		var pole:=CylinderMesh.new(); pole.top_radius=.025; pole.bottom_radius=.035; pole.height=2.4
		_object(pole,center+Vector3(0,1.2,0),Color("e8dcb9"))
		var flag:=PlaneMesh.new(); flag.orientation=PlaneMesh.FACE_Z; flag.size=Vector2(1,.55); flag.subdivide_width=10
		var instance:=_object(flag,center+Vector3(.5,2.1,0),Color("ce8d48"))
		var flag_material:=ShaderMaterial.new(); flag_material.shader=preload("res://shaders/flag.gdshader"); instance.material_override=flag_material
	material.set_shader_parameter("cup_position",hole.cup)
	material.set_shader_parameter("cup_placed",hole.cup_placed)
	# White boundary stakes make the outer OOB limit visible in play as well.
	for x in [-120.0,120.0]:
		for z in range(-440,41,40): _stake(Vector3(x,0,z))
	for z in [-440.0,40.0]:
		for x in range(-80,81,40): _stake(Vector3(x,0,z))


func _stake(point:Vector3)->void:
	point.y=hole.height_at(Vector2(point.x,point.z))+.45
	var mesh:=CylinderMesh.new(); mesh.top_radius=.035; mesh.bottom_radius=.045; mesh.height=.9
	_object(mesh,point,Color("e2dfcb"))


func _object(mesh:Mesh,point:Vector3,color:Color)->MeshInstance3D:
	var instance:=MeshInstance3D.new(); instance.mesh=mesh; instance.position=point; instance.material_override=RangePalette.material(color)
	markers_root.add_child(instance)
	if mesh.get_aabb().size.y>.3:fader.register_mesh(instance,Transform3D(Basis.IDENTITY,point)*mesh.get_aabb())
	return instance


func pick_ray(origin:Vector3,direction:Vector3)->Variant:
	if direction.y>=-.03:return null
	# Clip to the plot's small height volume, then find the first surface crossing.
	# This remains reliable on steep hills in the tilted editor view.
	var minimum:=Vector3(-120,HoleDefinition.MIN_HEIGHT-.5,-440)
	var maximum:=Vector3(120,HoleDefinition.MAX_HEIGHT+.5,40)
	var entry:=0.0;var exit:=2400.0
	for axis in range(3):
		if absf(direction[axis])<.00001:
			if origin[axis]<minimum[axis] or origin[axis]>maximum[axis]:return null
		else:
			var a:float=(minimum[axis]-origin[axis])/direction[axis]
			var b:float=(maximum[axis]-origin[axis])/direction[axis]
			entry=maxf(entry,minf(a,b));exit=minf(exit,maxf(a,b))
	if exit<entry:return null
	var previous:=entry
	var distance:=entry
	while distance<=exit:
		var point:=origin+direction*distance
		if point.y<=hole.height_at(Vector2(point.x,point.z)):
			var low:=previous;var high:=distance
			for iteration in range(12):
				var middle:float=(low+high)*.5
				var sample:=origin+direction*middle
				if sample.y>hole.height_at(Vector2(sample.x,sample.z)):low=middle
				else:high=middle
			var hit:=origin+direction*high
			return Vector3(hit.x,hole.height_at(Vector2(hit.x,hit.z)),hit.z)
		if is_equal_approx(distance,exit):break
		previous=distance;distance=minf(exit,distance+.75)
	return null


func update_contact(point:Vector3,radius:float,grounded:bool)->void:
	if close_turf:
		close_turf.ball_position=point; close_turf.ball_radius=radius; close_turf.ball_grounded=grounded


func update_visibility(position:Vector3,subject:Vector3,active:bool)->void:
	fader.set_view(position,subject,active and not editing)
