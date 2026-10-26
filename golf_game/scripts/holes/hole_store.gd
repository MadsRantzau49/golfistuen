class_name HoleStore
extends RefCounted
## User data only. Versioned JSON documents never require access to installation.
const MAX_FILE_BYTES := 3_000_000
var directory: String
var last_error := ""


func _init(root := "user://holes") -> void:
	directory=root
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var dir:=DirAccess.open(directory)
	if dir:
		for filename in dir.get_files():
			if filename.ends_with(".json.bak"):
				var target:=directory.path_join(filename.trim_suffix(".bak"))
				if not FileAccess.file_exists(target):DirAccess.rename_absolute(directory.path_join(filename),target)


func save(hole: HoleDefinition) -> bool:
	if not HoleDefinition.valid_id(hole.id): last_error="Invalid hole ID"; return false
	if hole.title.strip_edges().is_empty():last_error="Give the hole a name before saving.";return false
	return _write(directory.path_join(hole.id+".json"),hole.to_dict())


func save_draft(hole: HoleDefinition) -> bool:
	var data:=hole.to_dict()
	if str(data.title).strip_edges().is_empty():data.title="Untitled escape"
	return _write(directory.path_join("_draft.json"),data)


func load_draft() -> HoleDefinition:
	return load_file(directory.path_join("_draft.json"))


func load_hole(id: String) -> HoleDefinition:
	if not HoleDefinition.valid_id(id): last_error="Invalid hole ID"; return null
	return load_file(directory.path_join(id+".json"))


func load_file(path: String) -> HoleDefinition:
	last_error=""
	if not FileAccess.file_exists(path) and FileAccess.file_exists(path+".bak"): path+=".bak"
	var file:=FileAccess.open(path,FileAccess.READ)
	if file==null: last_error="Could not open the hole file."; return null
	if file.get_length()>MAX_FILE_BYTES: last_error="Hole file is too large."; return null
	var data:Variant=JSON.parse_string(file.get_as_text())
	if not data is Dictionary: last_error="Hole file is not valid JSON."; return null
	var hole:=HoleDefinition.from_dict(data)
	if hole==null: last_error="Invalid or unsupported hole document."
	return hole


func list_holes() -> Array[Dictionary]:
	var result: Array[Dictionary]=[]
	var dir:=DirAccess.open(directory)
	if dir==null: return result
	for filename in dir.get_files():
		if not filename.ends_with(".json") or filename.begins_with("_"): continue
		var hole:=load_file(directory.path_join(filename))
		if hole!=null:
			result.append({"id":hole.id,"title":hole.title,"par":hole.par,"length":hole.tee.distance_to(hole.cup),"playable":hole.play_errors().is_empty()})
	result.sort_custom(func(a:Dictionary,b:Dictionary)->bool:return a.title.naturalnocasecmp_to(b.title)<0)
	return result


func export_hole(hole: HoleDefinition, path: String) -> bool:
	if hole.title.strip_edges().is_empty():last_error="Give the hole a name before exporting.";return false
	return _write(path,hole.to_dict())


func record_result(result: Dictionary) -> bool:
	var record:=result.duplicate(true)
	record["attempt_id"]="attempt-%x-%x"%[int(Time.get_unix_time_from_system()),randi()]
	record["recorded_at"]=Time.get_datetime_string_from_system(true)
	if not _write(directory.path_join("_last_result.json"),record):return false
	var path:=directory.path_join("_results.jsonl")
	var file:=FileAccess.open(path,FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if file==null:last_error="The score is calculated, but score history could not be saved.";return false
	file.seek_end();file.store_line(JSON.stringify(record));file.flush();file.close()
	return true


func _write(path: String, data: Dictionary) -> bool:
	last_error=""
	var absolute:=ProjectSettings.globalize_path(path)
	var temp:=absolute+".tmp"
	var backup:=absolute+".bak"
	var file:=FileAccess.open(temp,FileAccess.WRITE)
	if file==null: last_error="Could not write the hole file. Check the destination folder."; return false
	file.store_string(JSON.stringify(data)); file.flush(); file.close()
	if FileAccess.file_exists(absolute):
		if FileAccess.file_exists(backup): DirAccess.remove_absolute(backup)
		if DirAccess.rename_absolute(absolute,backup)!=OK:
			last_error="Could not replace the previous hole file."; return false
	if DirAccess.rename_absolute(temp,absolute)!=OK:
		if FileAccess.file_exists(backup): DirAccess.rename_absolute(backup,absolute)
		last_error="Could not finish saving the hole file."; return false
	return true
