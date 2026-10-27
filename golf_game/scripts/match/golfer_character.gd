class_name GolferCharacter
extends Node3D
## Original toy-like golfer rig, square portrait head and a contact-timed swing.
var player:GolfPlayer
var portrait:Texture2D
var _torso:Node3D
var _head:MeshInstance3D
var _face:MeshInstance3D
var _arms:Node3D
var _colored:Array[MeshInstance3D]=[]
var _swing:Tween
var _swinging:=false
var _clock:=0.0


func _ready()->void:
	for x in [-.12,.12]:
		var leg:=CapsuleMesh.new();leg.radius=.09;leg.height=.5;leg.radial_segments=12;leg.rings=5
		_mesh(leg,Vector3(x,.35,0),Color("d6d6c2"))
		_box(Vector3(x,.075,.05),Vector3(.18,.15,.28),Color("233b32"))
	_torso=Node3D.new();_torso.position=Vector3(0,.85,0);add_child(_torso)
	var shirt:=CapsuleMesh.new();shirt.radius=.23;shirt.height=.57;shirt.radial_segments=16;shirt.rings=8
	_colored.append(_mesh(shirt,Vector3.ZERO,Color("4fc5ad"),_torso))
	_box(Vector3(0,.58,0),Vector3(.38,.055,.24),Color("314d3c"))
	var head_mesh:=BoxMesh.new();head_mesh.size=Vector3(.39,.39,.37)
	_head=_mesh(head_mesh,Vector3(0,1.34,0),Color.WHITE)
	var face_mesh:=QuadMesh.new();face_mesh.size=Vector2(.39,.39)
	_face=_mesh(face_mesh,Vector3(0,0,.186),Color.WHITE,_head)
	_colored.append(_box(Vector3(0,1.56,0),Vector3(.43,.09,.41),Color("4fc5ad")))
	_colored.append(_box(Vector3(0,1.51,.12),Vector3(.46,.035,.32),Color("4fc5ad")))
	_arms=Node3D.new();_arms.position=Vector3(.14,1.04,0);add_child(_arms)
	for z in [-.12,.12]:
		_segment(Vector3(-.22,0,z),Vector3(.16,-.25,.02),.055,Color("e0b58a"),_arms)
	var hand:=SphereMesh.new();hand.radius=.065;hand.height=.13
	_mesh(hand,Vector3(.16,-.25,.02),Color("f1e5ce"),_arms)
	_segment(Vector3(.16,-.25,.02),Vector3(.72,-1.00,.02),.014,Color("a8b9b0"),_arms)
	_box(Vector3(.73,-1.00,.02),Vector3(.17,.065,.10),Color("c3cdbd"),_arms)
	if player:apply_player(player,portrait)


func _mesh(mesh:Mesh,point:Vector3,color:Color,parent:Node=self)->MeshInstance3D:
	var instance:=MeshInstance3D.new();instance.mesh=mesh;instance.position=point
	var material:=RangePalette.material(color);material.roughness=.78
	instance.material_override=material;parent.add_child(instance);return instance


func _box(point:Vector3,size:Vector3,color:Color,parent:Node=self)->MeshInstance3D:
	var mesh:=BoxMesh.new();mesh.size=size;return _mesh(mesh,point,color,parent)


func _segment(start:Vector3,finish:Vector3,radius:float,color:Color,parent:Node)->void:
	var mesh:=CylinderMesh.new();mesh.top_radius=radius;mesh.bottom_radius=radius;mesh.height=start.distance_to(finish);mesh.radial_segments=10
	var instance:=_mesh(mesh,(start+finish)*.5,color,parent)
	instance.quaternion=Quaternion(Vector3.UP,(finish-start).normalized())


func apply_player(profile:GolfPlayer,texture:Texture2D)->void:
	player=profile;portrait=texture
	if not is_instance_valid(_head):return
	for instance in _colored:instance.material_override.albedo_color=profile.color()
	var material:=StandardMaterial3D.new();material.albedo_texture=texture;material.roughness=.9
	_face.material_override=material
	_head.material_override=RangePalette.material(texture.get_image().get_pixel(0,0))
	pose_address()


func pose_address()->void:
	if _swing:_swing.kill()
	_swinging=false
	if _arms:_arms.rotation=Vector3.ZERO
	if _torso:_torso.rotation=Vector3.ZERO
	if _head:_head.rotation=Vector3.ZERO


func swing()->void:
	pose_address();_swinging=true
	_swing=create_tween()
	_swing.tween_property(_arms,"rotation:z",-2.1,.25).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_swing.parallel().tween_property(_torso,"rotation:y",-.25,.25)
	_swing.tween_property(_arms,"rotation:z",0.0,.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_swing.parallel().tween_property(_torso,"rotation:y",.12,.18)
	_swing.tween_property(_arms,"rotation:z",1.75,.24).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_swing.parallel().tween_property(_torso,"rotation:y",.4,.24)
	_swing.tween_interval(.3)
	_swing.tween_property(_arms,"rotation:z",0.0,.45)
	_swing.parallel().tween_property(_torso,"rotation:y",0.0,.45)
	_swing.tween_callback(func():_swinging=false)


func _process(delta:float)->void:
	_clock+=delta
	if _torso:_torso.scale.y=1.0+sin(_clock*1.8)*.006
	if _head and not _swinging:_head.rotation.z=sin(_clock*.7)*.012
