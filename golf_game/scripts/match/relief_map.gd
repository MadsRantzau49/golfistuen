class_name ReliefMap
extends Control
signal point_selected(point:Vector2)
var hole:HoleDefinition
var original:=Vector2.ZERO
var candidate:=Vector2.ZERO
var center:=Vector2.ZERO
var span:=30.0
var mode:="lateral"
var valid:=false
var texture:ImageTexture


func _ready()->void:
	clip_contents=true;mouse_default_cursor_shape=Control.CURSOR_CROSS
	var image:=Image.create(HoleDefinition.COLUMNS,HoleDefinition.ROWS,false,Image.FORMAT_RGBA8)
	var palette:=[Color("365035"),Color("6b8d47"),Color("9bbe68"),Color("477f8b"),Color("c2ae78"),Color("7a4641")]
	for index in range(HoleDefinition.CELL_COUNT):image.set_pixel(index%HoleDefinition.COLUMNS,index/HoleDefinition.COLUMNS,palette[hole.surfaces[index]])
	texture=ImageTexture.create_from_image(image)
	center=original


func to_screen(point:Vector2)->Vector2:return (point-center)*(size.x/span)+size*.5
func to_world(point:Vector2)->Vector2:return (point-size*.5)/(size.x/span)+center


func _draw()->void:
	draw_rect(Rect2(Vector2.ZERO,size),Color("11271f"))
	if texture:draw_texture_rect(texture,Rect2(to_screen(HoleDefinition.BOUNDS.position),HoleDefinition.BOUNDS.size*(size.x/span)),false)
	for tree in hole.trees:
		var point:=to_screen(Vector2(tree.x,tree.z))
		draw_circle(point,maxf(3,1.3*size.x/span),Color("233e2a"))
		draw_circle(point,maxf(1,.3*size.x/span),Color("beaa7b"))
	var cup:=to_screen(hole.cup)
	draw_circle(cup,4,Color("faf1d9"));draw_line(cup,cup+Vector2(0,-16),Color("faf1d9"),2,true)
	var start:=to_screen(original)
	if mode=="lateral":draw_arc(start,GolfRelief.CLUB_LENGTH*2*size.x/span,0,TAU,64,Color("e6c798"),1.5,true)
	if mode in ["back_line","bunker_outside"]:
		var away:Vector2=(original-hole.cup).normalized()
		draw_line(start,to_screen(original+away*1000),Color("e6c798"),2,true)
	draw_circle(start,5,Color("fff5dc"));draw_arc(start,8,0,TAU,24,Color("20372a"),2,true)
	var drop:=to_screen(candidate)
	draw_circle(drop,6,Color("86d8a9") if valid else Color("f19b80"));draw_arc(drop,10,0,TAU,24,Color.WHITE,1.5,true)


func _gui_input(event:InputEvent)->void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index==MOUSE_BUTTON_LEFT:point_selected.emit(to_world(event.position));accept_event()
		elif event.button_index==MOUSE_BUTTON_WHEEL_UP:span=clampf(span*.8,8,800);queue_redraw();accept_event()
		elif event.button_index==MOUSE_BUTTON_WHEEL_DOWN:span=clampf(span/ .8,8,800);queue_redraw();accept_event()
	elif event is InputEventMouseMotion and event.button_mask&MOUSE_BUTTON_MASK_RIGHT:
		center-=event.relative/(size.x/span);queue_redraw();accept_event()
