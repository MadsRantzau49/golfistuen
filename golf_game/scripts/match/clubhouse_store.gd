class_name ClubhouseStore
extends RefCounted
## Current-development data model. No legacy migration layer.
var directory:String
var last_error:=""
var _portrait_cache:Dictionary={}
var _prepared_layouts:Dictionary={}


func _init(root:="user://clubhouse")->void:
	directory=root
	for child in ["portraits","courses","layouts","rounds"]:DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory.path_join(child)))


func load_players()->Array[GolfPlayer]:
	var players:Array[GolfPlayer]=[]
	var raw:Variant=JsonData.read(directory.path_join("players.json"),1_000_000)
	if raw is Dictionary and raw.get("schema_version")==1 and raw.get("players") is Array:
		for value in raw.players:
			if not value is Dictionary:continue
			var player:=GolfPlayer.from_dict(value)
			if player!=null and players.size()<GolfPlayer.MAX_PLAYERS:players.append(player)
	if players.is_empty():players.assign([GolfPlayer.new("Player 1",0),GolfPlayer.new("Player 2",1)])
	return players


func save_players(players:Array[GolfPlayer])->bool:
	var roster:Array=[]
	for player in players:roster.append(player.to_dict())
	return JsonData.write(directory.path_join("players.json"),{"schema_version":1,"players":roster})


func portrait(player:GolfPlayer)->Texture2D:
	if player.photo_file.is_empty():return PortraitArt.default_face(player.color_index)
	if _portrait_cache.has(player.photo_file):return _portrait_cache[player.photo_file]
	var path:=directory.path_join("portraits").path_join(player.photo_file)
	var image:=Image.load_from_file(ProjectSettings.globalize_path(path))
	if image==null or image.is_empty():return PortraitArt.default_face(player.color_index)
	var texture:=ImageTexture.create_from_image(image);_portrait_cache[player.photo_file]=texture;return texture


func import_photo(player:GolfPlayer,path:String)->bool:
	last_error=""
	var file:=FileAccess.open(path,FileAccess.READ)
	if file==null or file.get_length()>16_000_000:last_error="Choose an image smaller than 16 MB.";return false
	file.close()
	var image:=Image.load_from_file(path)
	if image==null or image.is_empty():last_error="That image could not be opened.";return false
	if image.get_width()>12000 or image.get_height()>12000:last_error="Choose an image no larger than 12,000 pixels per side.";return false
	var side:=mini(image.get_width(),image.get_height())
	image=image.get_region(Rect2i((image.get_width()-side)/2,(image.get_height()-side)/2,side,side))
	image.resize(256,256,Image.INTERPOLATE_LANCZOS);image.convert(Image.FORMAT_RGBA8)
	var filename:=player.id+".png"
	var destination:=ProjectSettings.globalize_path(directory.path_join("portraits").path_join(filename))
	if image.save_png(destination)!=OK:last_error="The portrait could not be saved.";return false
	player.photo_file=filename;_portrait_cache.erase(filename)
	return true


func save_course(course:GolfCourse)->bool:
	last_error=""
	if course.holes.is_empty() or course.holes.size()>GolfCourse.MAX_HOLES:last_error="Choose 1–36 playable holes.";return false
	if not JsonData.write(directory.path_join("courses").path_join(course.id+".json"),course.to_dict()):last_error="Course could not be saved.";return false
	var entries:=list_courses()
	entries=entries.filter(func(entry:Dictionary)->bool:return entry.id!=course.id)
	entries.append({"id":course.id,"title":course.title,"holes":course.holes.size()})
	return JsonData.write(directory.path_join("courses/_catalog.json"),{"schema_version":1,"courses":entries})


func list_courses()->Array[Dictionary]:
	var entries:Array[Dictionary]=[]
	var raw:Variant=JsonData.read(directory.path_join("courses/_catalog.json"),1_000_000)
	if raw is Dictionary and raw.get("courses") is Array:
		for entry in raw.courses:
			if entry is Dictionary and entry.get("id") is String and HoleDefinition.valid_id(entry.id) and FileAccess.file_exists(directory.path_join("courses").path_join(entry.id+".json")):
				entries.append(entry.duplicate())
	return entries


func load_course(id:String)->GolfCourse:
	if not HoleDefinition.valid_id(id):return null
	var raw:Variant=JsonData.read(directory.path_join("courses").path_join(id+".json"))
	return GolfCourse.from_dict(raw) if raw is Dictionary else null


func save_active(match_state:LocalGolfMatch,pending:Dictionary={})->bool:
	last_error=""
	var layout_path:=directory.path_join("layouts").path_join(match_state.id+".json")
	if not _prepared_layouts.has(match_state.id):
		if not JsonData.write(layout_path,match_state.course.to_dict()):last_error="The round layout could not be saved.";return false
		_prepared_layouts[match_state.id]=true
	var snapshot:=match_state.snapshot(false)
	snapshot["layout_id"]=match_state.id
	var active:={"schema_version":1,"match":snapshot,"pending":pending.duplicate(true)}
	if not JsonData.write(directory.path_join("active_round.json"),active):last_error="The round could not be saved.";return false
	return true


func load_active()->Dictionary:
	var raw:Variant=JsonData.read(directory.path_join("active_round.json"))
	if not raw is Dictionary or raw.get("schema_version")!=1 or not raw.get("match") is Dictionary:return {}
	var state:Dictionary=raw.match
	var layout_id:Variant=state.get("layout_id")
	if not layout_id is String or not HoleDefinition.valid_id(layout_id):return {}
	var course_data:Variant=JsonData.read(directory.path_join("layouts").path_join(layout_id+".json"))
	if not course_data is Dictionary:return {}
	state["course"]=course_data
	var restored:=LocalGolfMatch.restore(state)
	if restored==null or restored.state==LocalGolfMatch.State.COMPLETE:return {}
	var pending:Dictionary=raw.get("pending",{}) if raw.get("pending",{}) is Dictionary else {}
	var active:Variant=pending.get("active_shot",{})
	if restored.current_round().state==HoleRound.State.IN_FLIGHT and not _shot_record(active):return {}
	var replays:Variant=pending.get("replays",{})
	if not replays is Dictionary:return {}
	for value in replays.values():
		if not _shot_record(value):return {}
	return {"match":restored,"pending":pending}


static func _shot_record(value:Variant)->bool:
	if not value is Dictionary or not value.get("shot") is Dictionary or not value.get("origin") is Array or value.origin.size()!=3:return false
	for coordinate in value.origin:
		if not HoleDefinition._number(coordinate):return false
	return HoleDefinition._number(value.get("yaw"))


func has_active()->bool:
	return FileAccess.file_exists(directory.path_join("active_round.json")) or FileAccess.file_exists(directory.path_join("active_round.json.bak"))


func finish(match_state:LocalGolfMatch)->bool:
	var snapshot:=match_state.snapshot(false);snapshot["layout_id"]=match_state.id
	snapshot["finished_at"]=Time.get_datetime_string_from_system(true)
	if not JsonData.write(directory.path_join("rounds").path_join(match_state.id+".json"),snapshot):return false
	for suffix in ["",".bak"]:
		var active:String=directory.path_join("active_round.json")+suffix
		if FileAccess.file_exists(active):DirAccess.remove_absolute(active)
	return JsonData.write(directory.path_join("last_round.json"),snapshot)
