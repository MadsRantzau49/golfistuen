class_name RadarDebugViewport
extends SubViewportContainer
## Display-only mapping: radar (X,Y,Z) -> Godot (X,Z,-Y). No invented object meshes.
signal point_selected(point: Dictionary, frame_number: int, timestamp: float, role: String)
var viewport: SubViewport
var camera: Camera3D
var focus := Vector3(0,.7,-2)
var distance := 8.0
var yaw := .35
var pitch := .4
var orthographic := false
var color_mode := 0
var show_filtered := true
var show_all_hypotheses := false
var full_trajectories := false
var trail_s := .3
var dot_radius := .025
var data: RadarDebugData
var cursor := -1
var fit_start_index := -1
var fit_end_index := -1
var report: Dictionary = {}
var track: Dictionary = {}
var display_note := ""
var _world: Node3D
var _cloud: MultiMeshInstance3D
var _markers: MultiMeshInstance3D
var _traces: MeshInstance3D
var _sphere: SphereMesh
var _point_material: StandardMaterial3D
var _line_material: StandardMaterial3D
var _handles: Array[Dictionary] = []
var _ball: Dictionary = {}
var _parent: Dictionary = {}
var _candidate: Dictionary = {}
const BALL := Color("8df3a5")
const PARENT := Color("d399ff")
const CANDIDATE := Color("ffb76b")
const MODEL := Color("ffe89c")


func _ready() -> void:
	stretch=true;mouse_filter=Control.MOUSE_FILTER_STOP;focus_mode=Control.FOCUS_ALL
	viewport=SubViewport.new();viewport.own_world_3d=true;viewport.handle_input_locally=false
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS;add_child(viewport)
	_world=Node3D.new();viewport.add_child(_world)
	var environment:=WorldEnvironment.new();var settings:=Environment.new()
	settings.background_mode=Environment.BG_COLOR;settings.background_color=Color("091c25")
	settings.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR;settings.ambient_light_color=Color.WHITE
	settings.ambient_light_energy=.8;environment.environment=settings;_world.add_child(environment)
	camera=Camera3D.new();camera.near=.01;camera.far=1000;camera.fov=55;_world.add_child(camera);camera.current=true
	_sphere=SphereMesh.new();_sphere.radius=1;_sphere.height=2;_sphere.radial_segments=8;_sphere.rings=4
	_point_material=StandardMaterial3D.new();_point_material.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	_point_material.vertex_color_use_as_albedo=true;_point_material.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA
	_line_material=_point_material.duplicate();_line_material.no_depth_test=true
	_cloud=_multimesh();_markers=_multimesh();_traces=MeshInstance3D.new();_world.add_child(_traces)
	_build_grid();update_pose()
	gui_input.connect(_on_gui_input)


func _multimesh() -> MultiMeshInstance3D:
	var instance:=MultiMeshInstance3D.new();instance.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mesh:=MultiMesh.new();mesh.transform_format=MultiMesh.TRANSFORM_3D;mesh.use_colors=true;mesh.mesh=_sphere
	instance.multimesh=mesh;instance.material_override=_point_material;_world.add_child(instance);return instance


func _build_grid() -> void:
	var vertices: Array[Vector3]=[];var colors: Array[Color]=[]
	for index in range(-10,11):
		vertices.append_array([Vector3(index,0,-10),Vector3(index,0,10),Vector3(-10,0,index),Vector3(10,0,index)])
		for _part in range(4):colors.append(Color("36525c") if index==0 else Color("203b45"))
	vertices.append_array([Vector3.ZERO,Vector3(2,0,0),Vector3.ZERO,Vector3(0,0,-2),Vector3.ZERO,Vector3(0,2,0)])
	colors.append_array([Color("ff8585"),Color("ff8585"),Color("75dbed"),Color("75dbed"),PARENT,PARENT])
	var grid:=MeshInstance3D.new();grid.mesh=_line_mesh(vertices,colors);_world.add_child(grid)
	for entry in [["+X",Vector3(2.15,0,0),Color("ff8585")],["+Y · downrange",Vector3(0,0,-2.3),Color("75dbed")],["+Z · height",Vector3(0,2.15,0),PARENT],["RADAR · 0,0,0",Vector3(0,.15,.2),MODEL]]:
		var text:=Label3D.new();text.text=entry[0];text.position=entry[1];text.modulate=entry[2];text.font=AppStyle.BODY
		text.font_size=34;text.pixel_size=.002;text.billboard=BaseMaterial3D.BILLBOARD_ENABLED;text.no_depth_test=true;_world.add_child(text)
	var origin:=MeshInstance3D.new();var box:=BoxMesh.new();box.size=Vector3(.14,.1,.1);origin.mesh=box
	var material:=StandardMaterial3D.new();material.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED;material.albedo_color=MODEL
	origin.material_override=material;_world.add_child(origin)


func update_pose() -> void:
	if camera==null:return
	camera.projection=Camera3D.PROJECTION_ORTHOGONAL if orthographic else Camera3D.PROJECTION_PERSPECTIVE
	camera.size=distance
	camera.position=focus+Vector3(sin(yaw)*cos(pitch),sin(pitch),cos(yaw)*cos(pitch))*distance
	camera.look_at(focus,Vector3.UP)


func preset(name: String) -> void:
	match name:
		"Top":yaw=0;pitch=PI/2-.001
		"Side":yaw=PI/2;pitch=.02
		"Front":yaw=0;pitch=.02
		_:yaw=.35;pitch=.4
	update_pose()


func fit_view() -> void:
	if data==null or data.empty():focus=Vector3(0,.7,-2);distance=8;update_pose();return
	var bounds:=AABB(Vector3.ZERO,Vector3(.1,.1,.1))
	var first:=maxi(data.first_index(),cursor-50);var last:=mini(data.last_index(),cursor+50)
	if fit_start_index>=data.first_index() and fit_end_index>=fit_start_index and fit_end_index-fit_start_index<=3000:
		first=fit_start_index;last=mini(data.last_index(),fit_end_index)
	for index in range(first,last+1):
		for point in data.frame_at(index).get("diagnostics",{}).get("points",[]):
			if valid_point(point):bounds=bounds.expand(RadarDebugData.sample_position(point))
	for sample in track.get("observations",[]):bounds=bounds.expand(RadarDebugData.sample_position(sample))
	focus=bounds.get_center();distance=maxf(2,bounds.size.length()*1.3);update_pose()


func set_report(value: Dictionary, hypothesis: Dictionary={}) -> void:
	report=value;track=hypothesis;_ball.clear();_parent.clear();_candidate.clear()
	var selected: Array=report.get("selected_observations") if report.get("selected_observations") is Array else []
	if selected.is_empty():
		for candidate in report.get("tracks",[]):
			if candidate.get("track_id")==report.get("selected_hypothesis_id") and report.get("selected_hypothesis_id")!=null:selected=candidate.get("observations",[]);break
	for sample in selected:_ball[RadarDebugData.point_key(int(sample.get("frame_number",0)),sample)]=true
	for sample in track.get("observations",[]):_candidate[RadarDebugData.point_key(int(sample.get("frame_number",0)),sample)]=true
	var evidence: Variant=track.get("club_evidence",report.get("selected_club_evidence"))
	if evidence is Dictionary:
		for sample in evidence.get("parent_samples",[]):_parent[RadarDebugData.point_key(int(sample.get("frame_number",0)),sample)]=true
	refresh()


static func valid_point(point: Variant) -> bool:
	if not point is Dictionary:return false
	for axis in ["x","y","z"]:
		if not point.get(axis) is float and not point.get(axis) is int:return false
		if not is_finite(float(point[axis])):return false
	return true


func _color(point: Dictionary, key: String, age: float) -> Color:
	var color:=Color("8eacb7")
	if color_mode==1:color=Color("54d5e5") if point.get("ball_rejection")==null else Color("70818e")
	elif color_mode==2:
		var strength:=clampf(float(point.get("snr_db",0) if point.get("snr_db")!=null else 0)/40.0,0,1)
		color=Color("596981").lerp(Color("fff2af"),strength)
	else:
		var velocity:=float(point.get("radial_velocity",0) if point.get("radial_velocity")!=null else 0)
		var scale:=maxf(.01,float(data.configuration.get("sensor",{}).get("max_unambiguous_radial_speed_mps",30)))
		color=Color("718594").lerp(Color("ff9873") if velocity>0 else Color("6dbdfb"),clampf(absf(velocity)/scale,0,1))
	if _candidate.has(key):color=CANDIDATE
	if _parent.has(key):color=PARENT
	if _ball.has(key):color=BALL
	color.a=lerpf(.15,1.0,1-clampf(age/maxf(trail_s,.001),0,1))
	return color


func refresh() -> void:
	if not is_node_ready():return
	if data==null or data.empty() or cursor<data.first_index() or cursor>data.last_index():
		_handles.clear();_cloud.multimesh.instance_count=0;_markers.multimesh.instance_count=0;_traces.mesh=ImmediateMesh.new();return
	_handles.clear();display_note=""
	var current:=data.frame_at(cursor);var timestamp:=data.time_at(cursor)
	var first:=data.index_at_time(timestamp-trail_s)
	var invalid:=0
	for index in range(first,cursor+1):
		var frame:=data.frame_at(index);var number:=int(frame.get("diagnostics",{}).get("frame_number",0))
		for point in frame.get("diagnostics",{}).get("points",[]):
			if not valid_point(point):invalid+=1;continue
			if not show_filtered and point.get("ball_rejection")!=null:continue
			if _handles.size()>=RadarDebugData.MAX_POINTS:display_note="Display point budget reached; reduce trail length.";break
			var key:=RadarDebugData.point_key(number,point)
			_handles.append({"point":point,"position":RadarDebugData.sample_position(point),"frame":number,"time":float(frame.get("time_s",timestamp)),"key":key})
	_cloud.multimesh.instance_count=_handles.size()
	for index in range(_handles.size()):
		var handle: Dictionary=_handles[index]
		_cloud.multimesh.set_instance_transform(index,Transform3D(Basis.IDENTITY.scaled(Vector3.ONE*dot_radius),handle.position))
		_cloud.multimesh.set_instance_color(index,_color(handle.point,handle.key,timestamp-float(handle.time)))
	if invalid>0:display_note+=" %d non-finite points cannot be rendered."%invalid
	_draw_traces(int(current.get("diagnostics",{}).get("frame_number",0)))


func _draw_traces(number: int) -> void:
	var vertices: Array[Vector3]=[];var colors: Array[Color]=[];var markers: Array[Vector3]=[];var marker_colors: Array[Color]=[]
	if show_all_hypotheses:
		for candidate in report.get("tracks",[]):_add_path(candidate.get("observations",[]),Color(CANDIDATE,.2),number,vertices,colors)
	var selected: Array=report.get("selected_observations") if report.get("selected_observations") is Array else []
	if selected.is_empty() and report.get("selected_hypothesis_id")!=null:
		for candidate in report.get("tracks",[]):
			if candidate.get("track_id")==report.selected_hypothesis_id:selected=candidate.get("observations",[]);break
	_add_path(selected,BALL,number,vertices,colors)
	_add_path(track.get("observations",[]),CANDIDATE,number,vertices,colors)
	var evidence: Variant=track.get("club_evidence",report.get("selected_club_evidence"))
	if evidence is Dictionary:_add_path(evidence.get("parent_samples",[]),PARENT,number,vertices,colors)
	for sample in selected:
		if full_trajectories or int(sample.get("frame_number",0))<=number:markers.append(RadarDebugData.sample_position(sample));marker_colors.append(BALL)
	var fit: Variant=track.get("fit",report.get("selected_fit"))
	var observations: Array=track.get("observations",selected)
	if fit is Dictionary and observations.size()>=2 and fit.get("position") is Array:
		var position:=RadarDebugData.sample_position({"position":fit.position})
		var velocity:=RadarDebugData.sample_position({"position":fit.get("velocity",[0,0,0])})
		var acceleration:=RadarDebugData.sample_position({"position":fit.get("acceleration",[0,0,0])})
		var reference:=int(fit.get("reference_frame",0));var period:=_frame_period()
		var from:=int(observations[0].get("frame_number",reference));var until:=int(observations[-1].get("frame_number",reference))
		if not full_trajectories:until=mini(until,number)
		var previous: Variant=null
		for frame in range(from,until+1):
			var t: float=(frame-reference)*period;var predicted:=position+velocity*t+acceleration*t*t/2
			if previous!=null:vertices.append_array([previous,predicted]);colors.append_array([MODEL,MODEL])
			previous=predicted
	_traces.mesh=_line_mesh(vertices,colors)
	_markers.multimesh.instance_count=markers.size()
	for index in range(markers.size()):
		_markers.multimesh.set_instance_transform(index,Transform3D(Basis.IDENTITY.scaled(Vector3.ONE*dot_radius*1.5),markers[index]))
		_markers.multimesh.set_instance_color(index,marker_colors[index])


func _frame_period() -> float:
	var config: Dictionary=data.configuration.get("settings",{}).get("detector",data.configuration)
	return float(config.get("sensor",config.get("tracking",{})).get("frame_period_s",.02))


func _add_path(samples: Array, color: Color, number: int, vertices: Array[Vector3], colors: Array[Color]) -> void:
	var previous: Variant=null
	for sample in samples:
		if not full_trajectories and int(sample.get("frame_number",0))>number:continue
		var position:=RadarDebugData.sample_position(sample)
		if previous!=null:vertices.append_array([previous,position]);colors.append_array([color,color])
		previous=position


func _line_mesh(vertices: Array[Vector3], colors: Array[Color]) -> ImmediateMesh:
	var mesh:=ImmediateMesh.new()
	if vertices.is_empty():return mesh
	mesh.surface_begin(Mesh.PRIMITIVE_LINES,_line_material)
	for index in range(vertices.size()):mesh.surface_set_color(colors[index]);mesh.surface_add_vertex(vertices[index])
	mesh.surface_end();return mesh


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if event.button_mask&MOUSE_BUTTON_MASK_RIGHT:
			yaw-=event.relative.x*.008;pitch=clampf(pitch+event.relative.y*.008,-1.5,1.5);update_pose();accept_event()
		elif event.button_mask&MOUSE_BUTTON_MASK_MIDDLE:
			focus+=(-camera.global_basis.x*event.relative.x+camera.global_basis.y*event.relative.y)*distance/maxf(size.y,1);update_pose();accept_event()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN]:
			distance=clampf(distance*(.85 if event.button_index==MOUSE_BUTTON_WHEEL_UP else 1/.85),.2,500);update_pose();accept_event()
		elif event.button_index==MOUSE_BUTTON_LEFT:_pick(event.position);accept_event()


func _pick(position: Vector2) -> void:
	var best:=144.0;var selected: Dictionary={}
	for handle in _handles:
		if camera.is_position_behind(handle.position):continue
		var screen:=camera.unproject_position(handle.position);var distance_squared:=screen.distance_squared_to(position)
		if distance_squared<=best:best=distance_squared;selected=handle
	if selected.is_empty():return
	var role:="Unclassified radar return"
	if _candidate.has(selected.key):role="Inspected candidate observation"
	if _parent.has(selected.key):role="Inferred club-evidence observation"
	if _ball.has(selected.key):role="Selected ball-track observation"
	point_selected.emit(selected.point,int(selected.frame),float(selected.time),role)
