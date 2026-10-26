class_name AlpineRange
extends Node3D
## Environment composition and staged construction. No gameplay or UI dependencies.

signal build_progress(value: float, message: String)

const TEE := RangeSurface.LAUNCH_ORIGIN
const BUILD_STEPS := 7
var auto_build := true
var custom_layout := false
var rng := RandomNumberGenerator.new()
var landscape := AlpineLandscape.new()
var surface := RangeSurface.new(landscape)
var camera_clearance := CameraClearance.new()
var close_turf: CloseTurf
var rough_grass_material: ShaderMaterial
var environment: Environment
var sun: DirectionalLight3D
var foliage_material: ShaderMaterial
var foliage_shadow_material: ShaderMaterial
var obstruction_fader: ObstructionFader
var surfaces: Dictionary = {}


func _ready() -> void:
	rng.seed = 6843
	landscape.custom_plot=custom_layout
	obstruction_fader = ObstructionFader.new()
	add_child(obstruction_fader)
	camera_clearance.surface_height = surface.world_height
	if auto_build:
		for step in range(BUILD_STEPS):
			build_step(step)


func build_async() -> void:
	for step in range(BUILD_STEPS):
		build_step(step)
		await get_tree().process_frame
		await get_tree().process_frame


func build_step(step: int) -> void:
	match step:
		0: _lighting()
		1: _terrain()
		2: _water()
		3: _forest()
		4: _undergrowth()
		5:
			if not custom_layout: _targets()
		6:
			if not custom_layout: _tee()
	var messages := ["Finding the light", "Sculpting the Rockies", "Filling the lake",
		"Growing the forest", "A little wild around the edges", "Preparing the range", "Your escape is ready"]
	build_progress.emit(float(step+1)/BUILD_STEPS,messages[step])


func _lighting() -> void:
	var world := WorldEnvironment.new()
	environment = Environment.new()
	var sky := Sky.new()
	var sky_material := ShaderMaterial.new()
	sky_material.shader = preload("res://shaders/sky.gdshader")
	sky.sky_material = sky_material
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("bacdd0")
	environment.ambient_light_energy = .48
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.tonemap_exposure = 1.0
	environment.fog_enabled = true
	environment.fog_light_color = Color("a0b9ba")
	environment.fog_density = .00065
	environment.fog_sky_affect = .08
	environment.fog_aerial_perspective = .6
	environment.adjustment_enabled = true
	environment.adjustment_saturation = 1.05
	environment.adjustment_contrast = 1.06
	world.environment = environment
	add_child(world)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-28,-38,0)
	sun.light_color = Color("ffe3ae")
	sun.light_energy = 1.1
	sun.light_angular_distance = 1.8
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 240
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.shadow_bias = .035
	sun.directional_shadow_blend_splits = true
	add_child(sun)
	apply_quality("High")


func apply_quality(quality: String) -> void:
	if environment == null:
		return
	# Keep the playing view clear of screen-space noise and flashing bloom.
	environment.ssao_enabled = false
	environment.ssao_radius = 2.0
	environment.ssao_intensity = 1.5
	environment.ssao_light_affect = .3
	environment.glow_enabled = false
	environment.glow_intensity = .35
	environment.glow_bloom = .05
	environment.glow_hdr_threshold = 1.4
	if sun:
		sun.shadow_enabled = quality != "Low"
		sun.directional_shadow_max_distance = 240 if quality == "High" else 140
	for child in get_children():
		if child is MultiMeshInstance3D:
			var density:float={"Low":.55,"Medium":.8,"High":1.0}.get(quality,1.0)
			child.multimesh.visible_instance_count=int(child.multimesh.instance_count*density)
	if close_turf: close_turf.apply_quality(quality)


func _terrain() -> void:
	var terrain := MeshInstance3D.new()
	terrain.mesh = landscape.build_mesh()
	terrain.material_override = _turf_material()
	add_child(terrain)


func _turf_material(target := false) -> ShaderMaterial:
	var key := "turf-target" if target else "turf-field"
	if not surfaces.has(key):
		var material := ShaderMaterial.new()
		material.shader = preload("res://shaders/terrain.gdshader")
		material.set_shader_parameter("turf_color", preload("res://assets/turf/Grass004_2K-JPG_Color.jpg"))
		material.set_shader_parameter("turf_normal", preload("res://assets/turf/Grass004_2K-JPG_NormalGL.jpg"))
		material.set_shader_parameter("target_turf", target)
		material.set_shader_parameter("custom_plot", custom_layout)
		surfaces[key] = material
	return surfaces[key]


func _water() -> void:
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(202,465)
	mesh.subdivide_width = 30
	mesh.subdivide_depth = 50
	var water := MeshInstance3D.new()
	water.mesh = mesh
	water.position = Vector3(-143,-1.65,-170)
	var material := ShaderMaterial.new()
	material.shader = preload("res://shaders/lake.gdshader")
	material.set_shader_parameter("custom_plot", custom_layout)
	water.material_override = material
	add_child(water)


func _batch(mesh: Mesh, transforms: Array[Transform3D], material: Material, shadows := true) -> void:
	if transforms.is_empty():
		return
	var batch := MultiMeshInstance3D.new()
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	var foliage := material == foliage_material
	var fadeable := foliage or shadows
	multimesh.use_custom_data = foliage
	multimesh.use_colors = fadeable and not foliage
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for index in range(transforms.size()):
		multimesh.set_instance_transform(index,transforms[index])
		if foliage: multimesh.set_instance_custom_data(index, Color(0, 0, 0, 1))
		elif fadeable: multimesh.set_instance_color(index, Color.WHITE)
		if shadows and material != foliage_material:
			camera_clearance.add_box(transforms[index] * mesh.get_aabb())
	batch.multimesh = multimesh
	batch.material_override = material
	if fadeable and not foliage and material is StandardMaterial3D:
		var transparent := material.duplicate() as StandardMaterial3D
		transparent.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
		batch.material_override = transparent
	batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(batch)
	if fadeable:
		for index in range(transforms.size()):
			obstruction_fader.register_instance(batch, index, transforms[index] * mesh.get_aabb(), not foliage)
	if shadows:
		var shadow := MultiMeshInstance3D.new()
		shadow.multimesh = multimesh
		shadow.material_override = foliage_shadow_material if foliage else material
		shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		add_child(shadow)


func _forest() -> void:
	foliage_material = ShaderMaterial.new()
	foliage_material.shader = preload("res://shaders/foliage.gdshader")
	foliage_shadow_material = ShaderMaterial.new()
	foliage_shadow_material.shader = preload("res://shaders/foliage_shadow.gdshader")
	for variant in range(3):
		var builder := NatureMeshes.new(6843+variant)
		var transforms: Array[Transform3D] = []
		for index in range(230):
			var x := rng.randf_range(-440,440)
			var z := rng.randf_range(-650,55)
			if custom_layout and HoleDefinition.BOUNDS.grow(8).has_point(Vector2(x,z)): continue
			if absf(x) < 37 or landscape.height(x,z) < -.5 or landscape.height(x,z) > 125:
				continue
			var height := rng.randf_range(9,21)
			var basis := Basis(Vector3.UP,rng.randf()*TAU).scaled(Vector3(height*.9,height,height*.9))
			transforms.append(Transform3D(basis,Vector3(x,landscape.height(x,z)-.15,z)))
			_register_tree(transforms[-1], false)
		_batch(builder.spruce(),transforms,foliage_material)
	# Hero trees frame the tee and the lake with a richer, readable silhouette.
	var hero: Array[Transform3D] = []
	for point in [Vector3(-18,0,24),Vector3(-28,0,12),Vector3(25,0,18),
		Vector3(35,0,8),Vector3(-37,0,-32),Vector3(45,0,-60)]:
		if custom_layout and HoleDefinition.BOUNDS.grow(8).has_point(Vector2(point.x,point.z)): continue
		point.y=landscape.height(point.x,point.z)
		var h := rng.randf_range(13,18)
		hero.append(Transform3D(Basis(Vector3.UP,rng.randf()*TAU).scaled(Vector3(h,h,h)),point))
		_register_tree(hero[-1], false)
	_batch(NatureMeshes.new(54).spruce(true),hero,foliage_material)
	var aspens: Array[Transform3D] = []
	for index in range(45):
		var x := rng.randf_range(39,85)
		var z := rng.randf_range(-220,30)
		if custom_layout and HoleDefinition.BOUNDS.grow(8).has_point(Vector2(x,z)): continue
		var h := rng.randf_range(7,13)
		aspens.append(Transform3D(Basis(Vector3.UP,rng.randf()*TAU).scaled(Vector3(h,h,h)),
			Vector3(x,landscape.height(x,z),z)))
		_register_tree(aspens[-1], true)
	_batch(NatureMeshes.new(12).aspen(),aspens,foliage_material)


func _register_tree(transform: Transform3D, aspen: bool) -> void:
	var h := transform.basis.y.length()
	var radius := h * .34
	var bottom := .4 if aspen else .14
	var canopy := AABB(transform.origin + Vector3(-radius, h * bottom, -radius),
		Vector3(radius * 2, h * (1.1 - bottom), radius * 2))
	var trunk := AABB(transform.origin + Vector3(-h * .025, 0, -h * .025),
		Vector3(h * .05, h * .45, h * .05))
	camera_clearance.add_box(canopy, true)
	camera_clearance.add_box(trunk)


func _undergrowth() -> void:
	var builder := NatureMeshes.new(5)
	var rocks: Array[Transform3D] = []
	for index in range(180):
		var x := rng.randf_range(-63,-47)
		var z := rng.randf_range(-365,40)
		if custom_layout and HoleDefinition.BOUNDS.grow(3).has_point(Vector2(x,z)): continue
		var s := rng.randf_range(.5,3.2)
		rocks.append(Transform3D(Basis(Vector3.UP,rng.randf()*TAU).scaled(Vector3(s,s*.65,s)),
			Vector3(x,landscape.height(x,z)-.15,z)))
	var rock_material := StandardMaterial3D.new()
	rock_material.vertex_color_use_as_albedo = true
	rock_material.roughness = .94
	_batch(builder.stone(),rocks,rock_material)
	var grass_transforms: Array[Transform3D] = []
	for index in range(6200):
		var x := rng.randf_range(-65,85)
		var z := rng.randf_range(-125,40)
		if custom_layout and HoleDefinition.BOUNDS.grow(3).has_point(Vector2(x,z)): continue
		if (absf(x) < 29 and z < 20) or landscape.height(x,z) < -.7:
			continue
		var s := rng.randf_range(.6,1.3)
		grass_transforms.append(Transform3D(Basis(Vector3.UP,rng.randf()*TAU).scaled(Vector3(s,s,s)),
			Vector3(x,landscape.height(x,z),z)))
	rough_grass_material = ShaderMaterial.new()
	rough_grass_material.shader = preload("res://shaders/grass.gdshader")
	_batch(builder.grass(),grass_transforms,rough_grass_material,false)
	var flowers:Array[Transform3D]=[]
	for index in range(280):
		var x:=rng.randf_range(30,47) if index%2==0 else rng.randf_range(-46,-30)
		var z:=rng.randf_range(-90,30)
		if custom_layout and HoleDefinition.BOUNDS.grow(3).has_point(Vector2(x,z)): continue
		var y:=landscape.height(x,z)
		if y<-.6:continue
		flowers.append(Transform3D(Basis(Vector3.UP,rng.randf()*TAU),Vector3(x,y,z)))
	_batch(builder.flowers(),flowers,foliage_material,false)
	if not custom_layout:
		close_turf = CloseTurf.new()
		close_turf.surface = surface
		add_child(close_turf)


func update_ball_contact(point: Vector3, radius: float, grounded: bool) -> void:
	if close_turf:
		close_turf.ball_position = point
		close_turf.ball_radius = radius
		close_turf.ball_grounded = grounded
	if rough_grass_material:
		rough_grass_material.set_shader_parameter("ball_position", point)
		rough_grass_material.set_shader_parameter("ball_grounded", grounded)


func update_camera_visibility(position: Vector3, subject: Vector3, enabled: bool) -> void:
	if obstruction_fader: obstruction_fader.set_view(position, subject, enabled)


func _material(color: Color, roughness := .8) -> StandardMaterial3D:
	var key := color.to_html()+str(roughness)
	if not surfaces.has(key):
		var material := RangePalette.material(color)
		material.roughness = roughness
		surfaces[key] = material
	return surfaces[key]


func _object(mesh: Mesh, at: Vector3, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = at
	instance.material_override = material
	add_child(instance)
	var bounds := Transform3D(Basis.IDENTITY, at) * mesh.get_aabb()
	if bounds.end.y > surface.world_height(at) + .15 and bounds.size.length() > .2:
		obstruction_fader.register_mesh(instance, bounds)
	if mesh.get_aabb().size.y > .3:
		camera_clearance.add_box(Transform3D(Basis.IDENTITY, at) * mesh.get_aabb())
	return instance


func _box(at: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = size
	return _object(box,at,_material(color))


func _targets() -> void:
	for distance in [50,100,150,200,250,300]:
		var center := Vector3(0,.04,8-distance)
		var disk := CylinderMesh.new()
		disk.top_radius = 6.8
		disk.bottom_radius = 6.8
		disk.height = .025
		disk.radial_segments = 64
		_object(disk,center,_turf_material(true))
		var ring := TorusMesh.new()
		ring.inner_radius = 6.5
		ring.outer_radius = 6.58
		ring.rings = 64
		ring.ring_segments = 6
		# Painted turf marking, not a raised rope that a rolling ball clips through.
		var marking := _object(ring, Vector3(center.x, .0525 + RangeSurface.FAIRWAY_CANOPY + .001, center.z), _material(Color("e3d5a1")))
		marking.scale.y = .04
		var pole := CylinderMesh.new()
		pole.top_radius = .035
		pole.bottom_radius = .055
		pole.height = 2.8
		_object(pole,center+Vector3(0,1.4,0),_material(Color("dfd6b9"),.35))
		var flag := PlaneMesh.new()
		flag.size = Vector2(1.25,.65)
		flag.orientation = PlaneMesh.FACE_Z
		flag.subdivide_width = 10
		var flag_material := ShaderMaterial.new()
		flag_material.shader = preload("res://shaders/flag.gdshader")
		_object(flag,center+Vector3(.6,2.4,0),flag_material)
		if distance in [50,100,200,300]:
			var label := Label3D.new()
			label.text = str(distance)
			label.font = preload("res://assets/Outfit.ttf")
			label.font_size = 64
			label.pixel_size = .023
			label.position = center+Vector3(8,1.3,0)
			label.modulate = Color("fff2cf")
			label.outline_modulate = Color("263e25")
			label.outline_size = 8
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			add_child(label)


func _tee() -> void:
	# Warm timber decking, inset turf, brass markers and a furnished resting area.
	_box(Vector3(0,-.18,12),Vector3(12,.35,11),Color("473e2e"))
	for plank in range(30):
		var color := Color("857050").lerp(Color("b49a6d"),rng.randf()*.55)
		var board := _box(Vector3(-5.8+plank*.4,.014,12),Vector3(.385,.045,11),color)
		board.material_override = _wood_material(color)
	var mat := _box(Vector3(0,.065,8),Vector3(4.5,.1,3.2),Color("34532b"))
	mat.material_override = _turf_material(true)
	for x in [-2.6,2.6]:
		var marker := SphereMesh.new()
		marker.radius = .17
		marker.height = .34
		_object(marker,Vector3(x,.17,7.1),_material(Color("c0a46a"),.25))
	# Teak bench: shaped legs, slatted seat and back.
	for x in [4.2,6.8]:
		_box(Vector3(x,.45,15),Vector3(.12,.9,.12),Color("252d25"))
		_box(Vector3(x,.45,16),Vector3(.12,.9,.12),Color("252d25"))
	for slat in range(4):
		var seat := _box(Vector3(5.5,.92,15.1+slat*.25),Vector3(3.0,.09,.21),Color("a28a61"))
		seat.material_override = _wood_material(Color("a28a61"))
		var back := _box(Vector3(5.5,1.1+slat*.18,16.0),Vector3(3.0,.13,.08),Color("a28a61"))
		back.material_override = _wood_material(Color("a28a61"))
	# Range basket and a few white golf balls.
	var basket := CylinderMesh.new()
	basket.top_radius = .38
	basket.bottom_radius = .25
	basket.height = .45
	basket.radial_segments = 24
	_object(basket,Vector3(2.5,.24,9.7),_material(Color("5d6548")))
	var ball := SphereMesh.new()
	ball.radius = .075
	ball.height = .15
	for index in range(16):
		_object(ball,Vector3(2.5+rng.randf_range(-.24,.24),.49+rng.randf_range(0,.08),
			9.7+rng.randf_range(-.24,.24)),_material(Color("e8e5cf")))
	# A curved gravel path leads out of frame to the clubhouse.
	for index in range(24):
		var path_mesh := CylinderMesh.new()
		path_mesh.top_radius = 2.5
		path_mesh.bottom_radius = 2.5
		path_mesh.height = .03
		path_mesh.radial_segments = 32
		var z := 15.0+index*1.4
		var x := -9.0-index*.38
		_object(path_mesh,Vector3(x,landscape.height(x,z)+.025,z),_material(Color("8c896c")))


func _wood_material(color: Color) -> ShaderMaterial:
	var key := "wood-" + color.to_html()
	if not surfaces.has(key):
		var material := ShaderMaterial.new()
		material.shader = preload("res://shaders/wood.gdshader")
		material.set_shader_parameter("base_color", color)
		surfaces[key] = material
	return surfaces[key]
