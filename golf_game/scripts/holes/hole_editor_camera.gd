class_name HoleEditorCamera
extends Camera3D
var focus := Vector3(55,0,-200)
var target_size := 490.0
var tilted := false


func _ready()->void:
	projection=Camera3D.PROJECTION_ORTHOGONAL
	near=.1; far=2400; size=target_size
	update_pose()


func update_pose()->void:
	global_position=focus+(Vector3(0,240,180) if tilted else Vector3(0,320,0))
	look_at(focus,Vector3.UP if tilted else Vector3.FORWARD)


func frame_hole()->void:
	focus=Vector3(55,0,-200); target_size=490; size=target_size; update_pose()


func zoom(amount:float)->void:
	target_size=clampf(target_size*pow(.85,amount),30,560)


func pan(pixels:Vector2)->void:
	var scale_value:=size/maxf(get_viewport().get_visible_rect().size.y,1)
	var up:=global_basis.y; up.y=0
	if up.length_squared()>.01:up=up.normalized()
	focus+=(-global_basis.x*pixels.x+up*pixels.y)*scale_value
	focus.x=clampf(focus.x,-260,260); focus.z=clampf(focus.z,-560,140)
	update_pose()


func _process(delta:float)->void:
	size=lerpf(size,target_size,1.0-exp(-delta*10))
