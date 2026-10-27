class_name ShotCourseMap
extends PanelContainer
## North-up yardage book. Uses the actual painted course, never a second camera.
const COLORS:=[Color("354e37"),Color("709656"),Color("a7c880"),Color("4c8c9c"),Color("d5bd83"),Color("724d45")]
var document:HoleDefinition
var lie:=Vector2.ZERO
var ball:=Vector2.ZERO
var aim_yaw:=0.0
var live:=false
var player_color:=AppStyle.GOLD
var other_balls:Array[Dictionary]=[]
var trail:PackedVector2Array=[]
var range_mode:=false
var view_bounds:=HoleDefinition.BOUNDS
var measured_point:Variant=null
var _hover:Variant=null
var _texture:ImageTexture
var _green:PackedVector2Array=[]
var _canvas:Control
var _distance:Label
var _edges:Label
var _measure:Label
var _toggle:Button
var _expanded:=true
var _font:Font


func _ready()->void:
	custom_minimum_size.x=300;mouse_filter=Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel",AppStyle.box(Color("10251ff5"),14,Color("b4c29d45"),12))
	_font=AppStyle.font()
	var column:=VBoxContainer.new();column.add_theme_constant_override("separation",6);add_child(column)
	var heading:=HBoxContainer.new();column.add_child(heading)
	var title:=AppStyle.label("COURSE GUIDE",10,AppStyle.GOLD);title.size_flags_horizontal=Control.SIZE_EXPAND_FILL;heading.add_child(title)
	_toggle=Button.new();_toggle.text="−";_toggle.custom_minimum_size=Vector2(26,22);_toggle.tooltip_text="Collapse / expand the course guide"
	_toggle.add_theme_stylebox_override("normal",AppStyle.box(Color("233d30"),5,Color("ffffff20"),2));heading.add_child(_toggle)
	_toggle.pressed.connect(func():
		_expanded=not _expanded;_canvas.visible=_expanded;_edges.visible=_expanded;_measure.visible=_expanded;_toggle.text="−" if _expanded else "+";reset_size()
	)
	_distance=AppStyle.label("",25,AppStyle.CREAM,true);_distance.clip_text=true;column.add_child(_distance)
	_canvas=Control.new();_canvas.custom_minimum_size=Vector2(0,260);_canvas.clip_contents=true
	_canvas.mouse_default_cursor_shape=Control.CURSOR_CROSS;column.add_child(_canvas)
	_canvas.draw.connect(_draw_map);_canvas.gui_input.connect(_map_input)
	_canvas.mouse_exited.connect(func():_hover=null;_refresh_labels();_canvas.queue_redraw())
	_canvas.resized.connect(func():_canvas.queue_redraw())
	_edges=AppStyle.label("",12,AppStyle.CREAM);_edges.clip_text=true;_edges.tooltip_text="Front/back estimates use the cup's connected green on the 2 m surface grid.";column.add_child(_edges)
	_measure=AppStyle.label("Click map to measure · right-click clears",11,AppStyle.MUTED);_measure.clip_text=true;column.add_child(_measure)
	tooltip_text="Horizontal plan distances, using your metres/yards setting. Rings start at the shot lie. Click to keep a measurement; this does not change your aim. North is up."


func configure_hole(hole:HoleDefinition)->void:
	range_mode=false;document=hole;_build_texture();_find_green();_fit_course()
	set_lie(hole.tee,0)


func configure_range(surface:RangeSurface)->void:
	# Sample the same fairway, target and shoreline predicates as the 3D range.
	var layout:=HoleDefinition.new();layout.tee=Vector2(AlpineRange.TEE.x,AlpineRange.TEE.z)
	layout.cup=layout.tee+Vector2(0,-300)
	for index in range(HoleDefinition.CELL_COUNT):
		var point:=layout.grid_point(index%HoleDefinition.COLUMNS,index/HoleDefinition.COLUMNS)
		var world:=Vector3(point.x,0,point.y)
		layout.heights[index]=surface.landscape.rendered_height(point.x,point.y)
		layout.surfaces[index]=HoleDefinition.Surface.WATER if layout.heights[index]<-.6 else (HoleDefinition.Surface.GREEN if surface.is_target(world) else (HoleDefinition.Surface.FAIRWAY if surface.is_fairway(world) else HoleDefinition.Surface.ROUGH))
	document=layout;range_mode=true;_green.clear();_build_texture()
	view_bounds=Rect2(-105,-325,210,355);set_lie(layout.tee,0)


func _build_texture()->void:
	var image:=Image.create(HoleDefinition.COLUMNS,HoleDefinition.ROWS,false,Image.FORMAT_RGBA8)
	for index in range(HoleDefinition.CELL_COUNT):
		var color:Color=COLORS[document.surfaces[index]]
		var height:=document.heights[index]
		if document.surfaces[index]!=HoleDefinition.Surface.WATER:
			var slope:=height-document.heights[maxi(0,index-HoleDefinition.COLUMNS)]
			color=color.lightened(clampf(height*.004-slope*.07,0,.16)).darkened(clampf(slope*.07-height*.004,0,.17))
		image.set_pixel(index%HoleDefinition.COLUMNS,index/HoleDefinition.COLUMNS,color)
	_texture=ImageTexture.create_from_image(image)


func _find_green()->void:
	_green.clear()
	var first:=document.cell_index(document.cup)
	if document.surfaces[first]!=HoleDefinition.Surface.GREEN:return
	var queue:Array[int]=[first];var seen:Dictionary={first:true};var cursor:=0
	while cursor<queue.size():
		var index:=queue[cursor];cursor+=1
		_green.append(document.grid_point(index%HoleDefinition.COLUMNS,index/HoleDefinition.COLUMNS))
		for next in [index-1,index+1,index-HoleDefinition.COLUMNS,index+HoleDefinition.COLUMNS]:
			if next<0 or next>=HoleDefinition.CELL_COUNT or seen.has(next) or absi(next%HoleDefinition.COLUMNS-index%HoleDefinition.COLUMNS)>1:continue
			if document.surfaces[next]==HoleDefinition.Surface.GREEN:seen[next]=true;queue.append(next)


func _fit_course()->void:
	var bounds:=Rect2(document.tee,Vector2.ZERO).expand(document.cup)
	for index in range(HoleDefinition.CELL_COUNT):
		if document.surfaces[index] in [HoleDefinition.Surface.FAIRWAY,HoleDefinition.Surface.GREEN,HoleDefinition.Surface.WATER,HoleDefinition.Surface.SAND]:
			bounds=bounds.expand(document.grid_point(index%HoleDefinition.COLUMNS,index/HoleDefinition.COLUMNS))
	view_bounds=bounds.grow(24)
	view_bounds.size.x=maxf(view_bounds.size.x,100);view_bounds.size.y=maxf(view_bounds.size.y,100)


func set_lie(point:Vector2,yaw:float)->void:
	lie=point;ball=point;aim_yaw=yaw;live=false;trail.clear();measured_point=null;_hover=null
	if document and not view_bounds.has_point(point):view_bounds=view_bounds.expand(point).grow(8)
	refresh_units()


func begin_shot(point:Vector2,yaw:float)->void:
	lie=point;ball=point;aim_yaw=yaw;live=true;trail=PackedVector2Array([point]);refresh_units()


func set_ball(point:Vector2,moving:bool)->void:
	if point.distance_squared_to(ball)<.01 and moving==live:return
	ball=point;live=moving
	if trail.size()>0 and point.distance_squared_to(trail[-1])>1:
		if trail.size()<256:trail.append(point)
		else:trail[255]=point
	refresh_units()


func refresh_units()->void:
	if _canvas:_refresh_labels();_canvas.queue_redraw()


func green_distances(point:Vector2)->Vector2:
	var front:=INF;var back:=0.0
	for sample in _green:
		var distance:=point.distance_to(sample);front=minf(front,distance);back=maxf(back,distance)
	return Vector2(front,back) if not _green.is_empty() else Vector2.ZERO


func _refresh_labels()->void:
	if document==null:return
	var unit:=GameSettings.distance_suffix()
	if range_mode:
		_distance.text="%d–%d %s · range"%[roundi(GameSettings.distance(50)),roundi(GameSettings.distance(300)),unit]
		_edges.text="%d %s from tee%s"%[roundi(GameSettings.distance(lie.distance_to(ball))),unit," · LIVE" if live else ""]
	else:
		_distance.text="%.0f %s to pin%s"%[GameSettings.distance(ball.distance_to(document.cup)),unit," · LIVE" if live else ""]
		var edges:=green_distances(ball)
		_edges.text="Front %.0f  ·  Back %.0f %s"%[GameSettings.distance(edges.x),GameSettings.distance(edges.y),unit]
	var selected:Variant=measured_point if measured_point!=null else _hover
	var font_size:=13 if selected!=null else 11
	if _measure.get_theme_font_size("font_size")!=font_size:_measure.add_theme_font_size_override("font_size",font_size)
	_measure.text="Click map to measure · right-click clears"
	if selected!=null:
		_measure.text="%.0f %s out%s"%[GameSettings.distance(lie.distance_to(selected)),unit," · %.0f %s to pin"%[GameSettings.distance(document.cup.distance_to(selected)),unit] if not range_mode else " from tee"]


func _scale()->float:
	return minf((_canvas.size.x-24)/view_bounds.size.x,(_canvas.size.y-32)/view_bounds.size.y)


func to_map(point:Vector2)->Vector2:
	return (point-view_bounds.get_center())*_scale()+_canvas.size*.5


func to_world(point:Vector2)->Vector2:
	return (point-_canvas.size*.5)/_scale()+view_bounds.get_center()


func _chip(point:Vector2,text:String,color:=AppStyle.CREAM)->void:
	var width:=_font.get_string_size(text,HORIZONTAL_ALIGNMENT_LEFT,-1,11).x
	point.x=clampf(point.x,4,maxf(4,_canvas.size.x-width-8));point.y=clampf(point.y,14,_canvas.size.y-5)
	_canvas.draw_style_box(AppStyle.box(Color("10251fe8"),4,Color.TRANSPARENT,0),Rect2(point+Vector2(-4,-12),Vector2(width+8,17)))
	_canvas.draw_string(_font,point,text,HORIZONTAL_ALIGNMENT_LEFT,-1,11,color)


func _draw_map()->void:
	_canvas.draw_style_box(AppStyle.box(Color("263d2c"),8,Color("ffffff16"),0),Rect2(Vector2.ZERO,_canvas.size))
	if document==null or _texture==null:return
	_canvas.draw_texture_rect(_texture,Rect2(to_map(HoleDefinition.BOUNDS.position),HoleDefinition.BOUNDS.size*_scale()),false)
	for tree in document.trees:
		var point:=to_map(Vector2(tree.x,tree.z))
		_canvas.draw_circle(point,maxf(2.5,float(tree.height)*.17*_scale()),Color("203c2b"))
		_canvas.draw_circle(point,1,Color("bdba87"))
	var start:=to_map(lie)
	var unit:=GameSettings.distance_suffix()
	var reach:=GameSettings.distance(view_bounds.size.y)
	var step:=100.0 if reach>330 else (50.0 if reach>150 else 25.0)
	for index in range(1,6):
		var distance:=step*index/GameSettings.distance(1)
		var radius:=distance*_scale()
		_canvas.draw_arc(start,radius,0,TAU,100,Color("edf1c45a"),1,true)
		var label_point:=start+Vector2(-radius*.32,-radius*.947)
		if label_point.y>15 and label_point.y<_canvas.size.y-10:_chip(label_point,"%d %s"%[roundi(step*index),unit],Color("dfe8c9"))
	var heading:=Vector2(sin(deg_to_rad(aim_yaw)),-cos(deg_to_rad(aim_yaw)))
	_canvas.draw_dashed_line(start,to_map(lie+heading*view_bounds.size.y),Color("e6c7989a"),1,5,true)
	if trail.size()>1:
		var points:=PackedVector2Array()
		for point in trail:points.append(to_map(point))
		_canvas.draw_polyline(points,Color("f6e2a8"),2,true)
	for other in other_balls:
		var point:=to_map(other.point)
		_canvas.draw_circle(point,6,Color("122b22"));_canvas.draw_circle(point,4,other.color)
		_chip(point+Vector2(9,4),str(other.number),other.color)
	var tee:=to_map(document.tee)
	_canvas.draw_arc(tee,4,0,TAU,20,AppStyle.CREAM,1.5,true)
	if range_mode:
		for distance in [50,100,150,200,250,300]:
			var point:=to_map(document.tee+Vector2(0,-distance))
			_canvas.draw_circle(point,2,AppStyle.CREAM);_chip(point+Vector2(13,4),"%d %s"%[roundi(GameSettings.distance(distance)),unit])
	else:
		var cup:=to_map(document.cup)
		_canvas.draw_circle(cup,3,AppStyle.CREAM);_canvas.draw_line(cup,cup+Vector2(0,-17),AppStyle.CREAM,1.5,true)
		_canvas.draw_colored_polygon(PackedVector2Array([cup+Vector2(0,-17),cup+Vector2(12,-13),cup+Vector2(0,-9)]),AppStyle.GOLD)
		_chip(cup+Vector2(17,-7),"PIN",AppStyle.GOLD)
	var selected:Variant=measured_point if measured_point!=null else _hover
	if selected!=null:
		var point:=to_map(selected)
		_canvas.draw_dashed_line(start,point,AppStyle.CREAM,1.5,4,true)
		if not range_mode:_canvas.draw_dashed_line(point,to_map(document.cup),Color("f5efdf99"),1,4,true)
		_canvas.draw_arc(point,6,0,TAU,24,AppStyle.GOLD,1.5,true)
		_canvas.draw_line(point-Vector2(9,0),point+Vector2(9,0),AppStyle.GOLD,1,true)
		_canvas.draw_line(point-Vector2(0,9),point+Vector2(0,9),AppStyle.GOLD,1,true)
		_chip(point+Vector2(12,20),"%.0f %s"%[GameSettings.distance(lie.distance_to(selected)),unit],AppStyle.GOLD)
	var current:=to_map(ball)
	# Off-map shots stay readable at the edge without zooming/jumping the map.
	current=current.clamp(Vector2(8,8),_canvas.size-Vector2(8,8))
	_canvas.draw_circle(current,7,Color("10251f"));_canvas.draw_circle(current,5,player_color);_canvas.draw_circle(current,2.5,Color.WHITE)
	_chip(Vector2(8,17),"N ↑",AppStyle.MUTED)
	_chip(Vector2(8,_canvas.size.y-7),"Rings from lie",AppStyle.MUTED)


func _map_input(event:InputEvent)->void:
	if document==null:return
	if event is InputEventMouseMotion:
		_hover=to_world(event.position);_refresh_labels();_canvas.queue_redraw()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index==MOUSE_BUTTON_LEFT:measured_point=to_world(event.position)
		elif event.button_index==MOUSE_BUTTON_RIGHT:measured_point=null;_hover=null
		else:return
		_refresh_labels();_canvas.queue_redraw();_canvas.accept_event()
