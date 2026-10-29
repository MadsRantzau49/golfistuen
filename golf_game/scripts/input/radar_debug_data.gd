class_name RadarDebugData
extends RefCounted
## Raw observations stay in radar XYZ metres. Indexed files load points on demand.
const MAX_FRAMES := 9000
const MAX_POINTS := 120000
const MAX_ATTEMPTS := 64
const MAX_TRACE_SAMPLES := 120000
const MAX_INDEX := 1000000
const MAX_JSON_BYTES := 32 * 1024 * 1024
var frames: Array[Dictionary] = []
var attempts: Array[Dictionary] = []
var configuration: Dictionary = {}
var label := "Live capture"
var operator_note := ""
var base_index := 0
var discarded_frames := 0
var warning := ""
var loading := false
var indexed := false
var error := ""
var _point_count := 0
var _trace_count := 0
var _paths: Array[String] = []
var _file: FileAccess
var _file_index := 0
var _cache: Dictionary = {}
var _cache_order: Array[int] = []
var _cache_points := 0
var _report_cache: Dictionary = {}
var _report_key := ""


func first_index() -> int:return base_index
func last_index() -> int:return base_index + frames.size() - 1
func empty() -> bool:return frames.is_empty()
func time_at(index: int) -> float:return float(frames[clampi(index-base_index,0,frames.size()-1)].time_s) if not empty() else 0.0


func add_frame(value: Dictionary) -> void:
	if indexed:return
	var diagnostics: Variant=value.get("diagnostics")
	if not diagnostics is Dictionary or not diagnostics.get("points") is Array:return
	var timestamp: float=float(value.get("time_s",0.0))
	if not is_finite(timestamp):return
	if not empty() and timestamp<time_at(last_index()):timestamp=time_at(last_index())
	value.time_s=timestamp
	frames.append(value);_point_count+=diagnostics.points.size()
	while frames.size()>MAX_FRAMES or (_point_count>MAX_POINTS and frames.size()>1):
		_point_count-=frames[0].diagnostics.points.size();frames.pop_front();base_index+=1;discarded_frames+=1


func add_attempt(report: Dictionary, end_time: float, id: Variant, summary: Dictionary={}) -> void:
	var start_time:=end_time
	var number:=int(report.get("start_frame",-1))
	for index in range(frames.size()-1,-1,-1):
		var entry: Dictionary=frames[index]
		var frame_number: int=int(entry.get("number",entry.get("diagnostics",{}).get("frame_number",-2)))
		if frame_number==number:start_time=float(entry.time_s);break
	var samples:=trace_samples(report)
	if samples>MAX_TRACE_SAMPLES:warning="Report exceeds viewer memory budget. Open the saved session for its full diagnostics.";return
	var attempt: Dictionary=summary.duplicate()
	attempt.merge({"id":id,"start_time_s":start_time,"end_time_s":end_time,"outcome":report.get("outcome","unknown"),"report":report,"trace_samples":samples},true)
	attempts.append(attempt);_trace_count+=samples
	while attempts.size()>MAX_ATTEMPTS or (_trace_count>MAX_TRACE_SAMPLES and attempts.size()>1):
		_trace_count-=int(attempts[0].get("trace_samples",0));attempts.pop_front()


static func trace_samples(report: Dictionary) -> int:
	var selected: Variant=report.get("selected_observations")
	var count: int=selected.size() if selected is Array else 0
	for track in report.get("tracks",[]):
		if track is Dictionary:
			count+=track.get("observations",[]).size()
			if track.get("club_evidence") is Dictionary:count+=track.club_evidence.get("parent_samples",[]).size()
	return count


func frame_at(index: int) -> Dictionary:
	if index<base_index or index>last_index():return {}
	var entry: Dictionary=frames[index-base_index]
	if not indexed:return entry
	if _cache.has(index):return _cache[index]
	var event:=_read_event(entry._file,int(entry._offset))
	var data: Dictionary=event.get("data",{})
	if not data.get("diagnostics") is Dictionary:return {}
	data.time_s=entry.time_s
	_cache[index]=data;_cache_order.append(index);_cache_points+=data.diagnostics.get("points",[]).size()
	while _cache_order.size()>128 or (_cache_points>MAX_POINTS and _cache_order.size()>1):
		var expired: int=_cache_order.pop_front();_cache_points-=_cache[expired].diagnostics.get("points",[]).size();_cache.erase(expired)
	return data


func report_at(attempt: Dictionary) -> Dictionary:
	if attempt.has("report"):return attempt.report
	var key: String=str(attempt.get("_file",""))+":"+str(attempt.get("_offset",0))
	if key!=_report_key:
		_report_key=key;_report_cache=_read_event(attempt.get("_file",""),int(attempt.get("_offset",0))).get("data",{}).get("report",{})
	return _report_cache


func index_at_time(time_s: float) -> int:
	if empty():return -1
	var low:=0;var high:=frames.size()-1
	while low<high:
		var middle: int=(low+high+1)/2
		if float(frames[middle].time_s)<=time_s:low=middle
		else:high=middle-1
	return low+base_index


func open_directory(path: String) -> bool:
	var directory:=DirAccess.open(path)
	if directory==null:error="Cannot open recording folder: "+path;return false
	for file in directory.get_files():
		if file.begins_with("events-") and file.ends_with(".jsonl"):_paths.append(path.path_join(file))
	_paths.sort()
	if _paths.is_empty():error="This folder has no events-*.jsonl recordings.";return false
	var metadata_path:=path.path_join("session.json")
	if FileAccess.file_exists(metadata_path):
		var metadata: Variant=JSON.parse_string(FileAccess.get_file_as_string(metadata_path))
		if metadata is Dictionary:configuration=metadata
	label=path.get_file();indexed=true;loading=true;_file_index=0
	_file=FileAccess.open(_paths[0],FileAccess.READ)
	if _file==null:loading=false;error="Cannot read recording events.";return false
	return true


func step_index() -> void:
	if not loading:return
	var deadline:=Time.get_ticks_usec()+4000
	while Time.get_ticks_usec()<deadline:
		if _file.eof_reached():
			_file.close();_file_index+=1
			if _file_index>=_paths.size():loading=false;_file=null;return
			_file=FileAccess.open(_paths[_file_index],FileAccess.READ)
			if _file==null:error="Cannot read recording segment.";loading=false;return
		var offset:=_file.get_position()
		var line:=_file.get_line()
		if line.is_empty():continue
		if line.length()>MAX_JSON_BYTES:error="Recording event exceeds viewer memory budget.";loading=false;return
		var event: Variant=JSON.parse_string(line)
		if not event is Dictionary:
			if _file.eof_reached():warning="Incomplete trailing event ignored; the capture may still be running.";continue
			error="Invalid recording JSON at byte %d."%offset;loading=false;return
		if event.get("type")=="frame":
			if frames.size()>=MAX_INDEX:error="Recording exceeds the frame index budget. Open a shorter session.";loading=false;return
			var number: int=int(event.get("data",{}).get("diagnostics",{}).get("frame_number",0))
			frames.append({"time_s":float(event.get("elapsed_s",0)),"number":number,"_file":_paths[_file_index],"_offset":offset})
		elif event.get("type") in ["swing_completed","operator_mark"]:
			var report: Dictionary=event.get("data",{}).get("report",{})
			var timestamp: float=float(report.get("end_time_s",event.get("elapsed_s",0)));var start:=float(report.get("start_time_s",timestamp))
			if event.get("type")=="operator_mark":
				for index in range(frames.size()-1,-1,-1):
					if int(frames[index].number)==int(report.get("end_frame",-1)):timestamp=float(frames[index].time_s);break
			for index in range(frames.size()-1,-1,-1):
				if int(frames[index].number)==int(report.get("start_frame",-1)):start=float(frames[index].time_s);break
			attempts.append({"id":event.get("swing_id",attempts.size()),"operator_label":report.get("operator_label"),"start_time_s":start,"end_time_s":timestamp,
				"outcome":report.get("outcome","unknown"),"_file":_paths[_file_index],"_offset":offset})


func _read_event(path: String, offset: int) -> Dictionary:
	var file:=FileAccess.open(path,FileAccess.READ)
	if file==null:error="Cannot read recording: "+path;return {}
	file.seek(offset)
	var value: Variant=JSON.parse_string(file.get_line())
	return value if value is Dictionary else {}


func export_clip(start: float, end: float, report: Dictionary) -> Dictionary:
	var selected: Array[Dictionary]=[];var points:=0
	if empty():return {}
	for index in range(index_at_time(start),last_index()+1):
		if time_at(index)>end:break
		var frame:=frame_at(index)
		points+=frame.get("diagnostics",{}).get("points",[]).size()
		if selected.size()>=3000 or points>MAX_POINTS:error="Clip is too large; reduce before/after context.";return {}
		selected.append(frame)
	return {"schema":"pinewater-radar-clip","version":1,"configuration":configuration,"frames":selected,"report":report,"label":label,"operator_note":operator_note}


func open_clip(path: String) -> bool:
	var file:=FileAccess.open(path,FileAccess.READ)
	if file==null:error="Cannot open radar clip.";return false
	if file.get_length()>MAX_JSON_BYTES:error="Clip exceeds viewer memory budget.";return false
	var value: Variant=JSON.parse_string(file.get_as_text())
	if not value is Dictionary or value.get("schema")!="pinewater-radar-clip" or value.get("version")!=1 or not value.get("frames") is Array:
		error="This is not a Pinewater radar clip.";return false
	var count:=0
	for frame in value.frames:
		if not frame is Dictionary or not frame.get("diagnostics") is Dictionary or not frame.diagnostics.get("points") is Array:error="Invalid clip frame.";return false
		count+=frame.diagnostics.points.size()
	if value.frames.size()>MAX_FRAMES or count>MAX_POINTS:error="Clip exceeds viewer frame/point budget.";return false
	configuration=value.get("configuration",{});label=value.get("label",path.get_file());operator_note=str(value.get("operator_note",""))
	for frame in value.frames:add_frame(frame)
	if value.get("report") is Dictionary and not value.report.is_empty():add_attempt(value.report,time_at(last_index()),0)
	return not empty()


static func sample_position(sample: Dictionary) -> Vector3:
	var position: Variant=sample.get("position")
	if position is Array and position.size()==3:return Vector3(float(position[0]),float(position[2]),-float(position[1]))
	return Vector3(float(sample.get("x",0)),float(sample.get("z",0)),-float(sample.get("y",0)))


static func point_key(frame: int, point: Dictionary) -> String:
	var position:=sample_position(point)
	var velocity: Variant=point.get("radial_velocity")
	var speed: String="%.5f"%float(velocity) if velocity is float or velocity is int else "unknown"
	return "%d/%.5f/%.5f/%.5f/%s"%[frame,position.x,position.y,position.z,speed]
