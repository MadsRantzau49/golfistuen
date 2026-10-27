class_name JsonData
extends RefCounted

static func read(path:String,limit:=64_000_000)->Variant:
	if not FileAccess.file_exists(path) and FileAccess.file_exists(path+".bak"):path+=".bak"
	var file:=FileAccess.open(path,FileAccess.READ)
	if file==null or file.get_length()>limit:return null
	return JSON.parse_string(file.get_as_text())


static func write(path:String,data:Dictionary)->bool:
	var absolute:=ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var temporary:=absolute+".tmp";var backup:=absolute+".bak"
	var file:=FileAccess.open(temporary,FileAccess.WRITE)
	if file==null:return false
	file.store_string(JSON.stringify(data));file.flush();file.close()
	if FileAccess.file_exists(absolute):
		if FileAccess.file_exists(backup):DirAccess.remove_absolute(backup)
		if DirAccess.rename_absolute(absolute,backup)!=OK:return false
	if DirAccess.rename_absolute(temporary,absolute)!=OK:
		if FileAccess.file_exists(backup):DirAccess.rename_absolute(backup,absolute)
		return false
	return true
