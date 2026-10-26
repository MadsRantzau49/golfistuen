class_name BallLocator
extends Control
## A restrained distance cue only when the real sphere is smaller than a few
## pixels. Close views show the shaded, rolling ball itself without an overlay.

var subject: Node3D
var radius := .02135
var enabled := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	if not enabled or not is_instance_valid(subject): return
	var camera := get_viewport().get_camera_3d()
	if camera == null or camera.is_position_behind(subject.global_position): return
	var point := camera.unproject_position(subject.global_position)
	var edge := camera.unproject_position(subject.global_position + camera.global_basis.x * radius)
	if point.distance_to(edge) >= 3.0: return
	draw_circle(point, 2.8, Color(.04, .09, .06, .7))
	draw_circle(point, 1.6, Color("fff8df"))
	draw_arc(point, 5.0, 0, TAU, 24, Color(1, .97, .84, .5), 1.0, true)
