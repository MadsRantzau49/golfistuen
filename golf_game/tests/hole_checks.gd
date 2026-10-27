extends SceneTree
var failures:=0


func _initialize()->void:
	_run.call_deferred()
	create_timer(90).timeout.connect(func():printerr("FAIL: hole checks timed out");quit(1))


func check(value:bool,message:String)->void:
	if not value:failures+=1;printerr("FAIL: "+message)


func _run()->void:
	var hole:=HoleDefinition.new()
	check(hole.surfaces.count(HoleDefinition.Surface.ROUGH)==HoleDefinition.CELL_COUNT,"New design is empty rough")
	check(not hole.cup_placed and not hole.play_errors().is_empty(),"Blank design requires a green and cup")
	var history:=HoleHistory.new();history.begin(hole)
	hole.apply_brush(Vector2(0,-100),14,"fairway");history.commit(true)
	check(hole.surface_at(Vector2(0,-100))==HoleDefinition.Surface.FAIRWAY,"Brush paints the chosen surface")
	check(hole.surface_at(Vector2(30,-100))==HoleDefinition.Surface.ROUGH,"Brush preserves outside terrain")
	check(history.undo(hole) and hole.surface_at(Vector2(0,-100))==HoleDefinition.Surface.ROUGH,"Undo restores a complete stroke")
	check(history.redo(hole) and hole.surface_at(Vector2(0,-100))==HoleDefinition.Surface.FAIRWAY,"Redo reapplies the stroke")
	hole.apply_brush(Vector2(0,-100),12,"raise",5,1)
	check(hole.height_at(Vector2(0,-100))>4.9,"Sculpt raises a hill")
	hole.apply_brush(Vector2(40,-100),12,"lower",5,1)
	check(hole.height_at(Vector2(40,-100))< -4.9,"Sculpt lowers a valley")
	hole.apply_brush(Vector2(-30,-100),10,"water")
	check(hole.surface_at(Vector2(-30,-100))==HoleDefinition.Surface.WATER and hole.height_at(Vector2(-30,-100))<hole.water_level,"Water paints and carves a pond")
	hole.apply_brush(Vector2(10,-200),15,"green");hole.place_cup(Vector2(10,-200))
	check(hole.play_errors().is_empty(),"Green, cup and valid tee make a playable design")
	check(hole.add_tree(Vector2(40,-160)) and not hole.add_tree(Vector2(40,-160)),"Tree placement has useful spacing")
	var serialized:Variant=JSON.parse_string(JSON.stringify(hole.to_dict()))
	var copy:=HoleDefinition.from_dict(serialized)
	check(copy!=null and copy.heights==hole.heights and copy.surfaces==hole.surfaces and copy.trees.size()==1,"Versioned JSON preserves terrain, paint and trees")
	hole.set_cup_diameter(1.2)
	check(HoleDefinition.from_dict(hole.to_dict()).cup_diameter_m==1.2,"Chosen cup diameter is saved with the map")
	var legacy:=hole.to_dict();legacy.erase("cup_diameter_m")
	check(HoleDefinition.from_dict(legacy).cup_diameter_m==HoleDefinition.DEFAULT_CUP_DIAMETER,"Old maps receive the default cup size")
	_check_cup_capture()
	var corrupt:Dictionary=hole.to_dict();corrupt.schema_version=99
	check(HoleDefinition.from_dict(corrupt)==null,"Unknown schema is rejected")
	corrupt=hole.to_dict();corrupt.heights[0]=NAN
	check(HoleDefinition.from_dict(corrupt)==null,"Nonfinite terrain is rejected")
	corrupt=hole.to_dict();corrupt.id="../escape"
	check(HoleDefinition.from_dict(corrupt)==null,"Hole IDs cannot escape the save directory")
	_check_scoring(hole)
	_check_store(hole)
	if failures==0:print("PASS: blank rough, paint, sculpt, undo/redo, water carving, trees, schema validation, save/load and no-putting scoring")
	quit(1 if failures else 0)


func _check_scoring(hole:HoleDefinition)->void:
	var rules:=HoleRules.create()
	var attempt:=HoleRound.new(hole,rules)
	check(attempt.begin_shot("one") and not attempt.begin_shot("one"),"One event counts as one stroke")
	attempt.resolve_rest(Vector2(14,-200))
	check(attempt.state==HoleRound.State.COMPLETE and attempt.gross_score()==3 and attempt.awarded_putts==2,"Green finish adds two putts by default")
	check(not attempt.begin_shot("after"),"No putting shot can start after green completion")
	var alternate:=HoleRound.new(hole,HoleRules.create({"green_putts":1}))
	alternate.begin_shot("one");alternate.resolve_rest(Vector2(14,-200))
	check(alternate.gross_score()==2,"Automatic green strokes are configurable")
	var holed:=HoleRound.new(hole,rules);holed.begin_shot("chip");holed.resolve_rest(hole.cup)
	check(holed.gross_score()==1 and holed.awarded_putts==0,"A directly holed shot does not receive automatic putts")
	var penalty:=HoleRound.new(hole,rules);penalty.begin_shot("water");penalty.resolve_rest(Vector2(-30,-100))
	check(penalty.penalties==1 and penalty.lie==hole.tee and penalty.state==HoleRound.State.READY,"Water incurs penalty and returns to the previous safe lie")
	penalty.begin_shot("oob");penalty.resolve_rest(Vector2(200,-100))
	check(penalty.penalties==2 and penalty.lie==hole.tee,"Out of bounds uses stroke and distance")
	hole.apply_brush(Vector2(70,-90),8,"oob")
	penalty.begin_shot("painted-oob");penalty.resolve_rest(Vector2(70,-90))
	check(penalty.penalties==3 and penalty.lie==hole.tee,"Painted OOB areas enforce the same rule as the course boundary")
	var capped:=HoleRound.new(hole,HoleRules.create({"max_strokes":3,"green_putts":3}))
	capped.begin_shot("cap");capped.resolve_rest(Vector2(14,-200))
	check(capped.gross_score()==3,"Maximum gross score includes automatic green strokes")
	check(not HoleRules.valid("green_putts",true) and not HoleRules.valid("green_putts",10),"Rule settings validate numeric bounds")
	var metadata_only:=HoleRound.new(hole,rules)
	metadata_only.begin_shot("backend-id");metadata_only.resolve_rest(Vector2(0,-20))
	check(metadata_only.begin_shot("backend-id"),"Backend metadata is not a frontend shot-validity requirement")


func _check_store(hole:HoleDefinition)->void:
	var directory:="user://hole-check-%d"%Time.get_ticks_msec()
	var store:=HoleStore.new(directory)
	check(store.save(hole),"Hole saves to user data")
	var loaded:=store.load_hole(hole.id)
	check(loaded!=null and loaded.title==hole.title and loaded.heights==hole.heights,"Saved hole reloads")
	check(store.list_holes().size()==1,"Library lists saved designs")
	check(store.save_draft(hole) and store.load_draft()!=null,"Unsaved editor draft can be recovered")
	var attempt:=HoleRound.new(hole,HoleRules.create());attempt.begin_shot("history");attempt.resolve_rest(Vector2(14,-200))
	check(store.record_result(attempt.result()) and store.record_result(attempt.result()),"Completed attempts retain scoring history for future policies")
	var records:=FileAccess.get_file_as_string(directory.path_join("_results.jsonl")).strip_edges().split("\n")
	check(records.size()==2,"Recording another attempt does not overwrite score history")
	var dir:=DirAccess.open(directory)
	for filename in dir.get_files():DirAccess.remove_absolute(directory.path_join(filename))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(directory))


func _cup_approach(surface:HoleSurface,offset:float)->HoleShotSimulator:
	var shot:=GolfShot.from_payload({"speed_mps":8.0,"direction_deg":0.0,"elevation_deg":0.0})
	var origin:=Vector3(offset,.018,-39.1)
	var simulator:=HoleShotSimulator.new(shot,surface,origin,0)
	simulator.model.phase="ROLLING"
	return simulator


func _check_cup_capture()->void:
	var hole:=HoleDefinition.new();hole.apply_brush(Vector2(0,-40),20,"green");hole.place_cup(Vector2(0,-40))
	var surface:=HoleSurface.new(AlpineLandscape.new(),hole)
	hole.set_cup_diameter(.108)
	var fast:=_cup_approach(surface,0)
	fast.step(.2)
	check(fast.sinking,"A swept fast entry hits the opening even when a physics tick crosses the whole cup")
	for frame in range(60):fast.step()
	check(fast.holed and fast.model.finished,"A captured ball visibly drops into the cup before the shot finishes")
	check(absf((fast.origin+fast.model.position).y-surface.cup_floor_height()-BallFlight.BALL_RADIUS)<.0001,"Holed ball rests at the bottom of the actual cavity")
	var narrow:=_cup_approach(surface,.35);narrow.step(.2)
	check(not narrow.sinking,"A regulation opening does not capture a clearly off-centre shot")
	hole.set_cup_diameter(1.0)
	var wide:=_cup_approach(surface,.35);wide.step(.2)
	check(wide.sinking,"Enlarging the saved opening genuinely increases capture forgiveness")
	var high:=_cup_approach(surface,0);high.origin.y=1;high.model.phase="FLIGHT";high.step(.2)
	check(not high.sinking,"A ball flying above the cup is not magnetically holed")
