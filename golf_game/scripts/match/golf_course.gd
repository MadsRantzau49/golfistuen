class_name GolfCourse
extends RefCounted
## A saved course contains immutable hole snapshots, not fragile library links.
const MAX_HOLES := 36
var id := ""
var title := "My alpine course"
var holes: Array[HoleDefinition] = []
var metadata: Dictionary = {}


func _init()->void:id="course-%x-%x"%[Time.get_ticks_usec(),randi()]


func to_dict()->Dictionary:
	var documents:Array=[]
	for hole in holes:documents.append(hole.to_dict())
	return {"schema_version":1,"id":id,"title":title,"holes":documents,"metadata":metadata.duplicate(true)}


static func from_dict(data:Dictionary)->GolfCourse:
	if data.get("schema_version")!=1 or not data.get("id") is String or not HoleDefinition.valid_id(data.id):return null
	if not data.get("title") is String or data.title.strip_edges().is_empty() or data.title.length()>80:return null
	var raw:Variant=data.get("holes")
	if not raw is Array or raw.is_empty() or raw.size()>MAX_HOLES:return null
	var course:=GolfCourse.new();course.id=data.id;course.title=data.title.strip_edges()
	for document in raw:
		if not document is Dictionary:return null
		var hole:=HoleDefinition.from_dict(document)
		if hole==null or not hole.play_errors().is_empty():return null
		course.holes.append(hole)
	if data.get("metadata",{}) is Dictionary:course.metadata=data.get("metadata",{}).duplicate(true)
	return course


static func single(hole:HoleDefinition)->GolfCourse:
	var course:=GolfCourse.new();course.title=hole.title;course.holes.append(hole)
	return course
