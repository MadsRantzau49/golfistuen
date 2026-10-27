extends SceneTree
var failures:=0

func _initialize()->void:
	_run.call_deferred();create_timer(120).timeout.connect(func():printerr("FAIL: match checks timed out");quit(1))

func check(value:bool,message:String)->void:
	if not value:failures+=1;printerr("FAIL: "+message)

func _hole()->HoleDefinition:
	var hole:=HoleDefinition.new();hole.title="Rules meadow";hole.apply_brush(Vector2(0,-100),12,"green");hole.place_cup(Vector2(0,-100));return hole

func _shot()->GolfShot:return GolfShot.from_payload({"speed":30,"direction":0,"elevation":20,"spin":0})

func _run()->void:
	var hole:=_hole();var course:=GolfCourse.new();course.holes.assign([hole,hole])
	var players:Array[GolfPlayer]=[GolfPlayer.new("Ada",0),GolfPlayer.new("Ben",1),GolfPlayer.new("Cleo",2)]
	var competition:=LocalGolfMatch.new(players,course)
	for point in [Vector2(0,-20),Vector2(0,-10),Vector2(0,-50)]:competition.begin_shot(_shot());competition.resolve_shot(point)
	check(competition.active_index==1,"After all tee shots, farthest from cup plays next")
	competition.begin_shot(_shot());competition.resolve_shot(Vector2(0,-70))
	check(competition.active_index==0,"Turn order is not round robin")
	competition.begin_shot(_shot());competition.resolve_shot(Vector2(3,-100))
	check(competition.active_index==2,"Completed players leave the turn order")
	competition.begin_shot(_shot());competition.resolve_shot(Vector2(3,-100))
	competition.begin_shot(_shot());competition.resolve_shot(Vector2(3,-100))
	check(competition.state==LocalGolfMatch.State.HOLE_COMPLETE,"Every player completes a hole before advancing")
	competition.advance_hole()
	check(competition.tee_order==[0,2,1],"Lowest previous gross has honours; tied scores retain previous tee order")
	competition.begin_shot(_shot())
	var restored:=LocalGolfMatch.restore(JSON.parse_string(JSON.stringify(competition.snapshot())))
	check(restored!=null and restored.hole_index==1 and restored.current_round().state==HoleRound.State.IN_FLIGHT,"Round snapshot preserves course, honour order and in-flight accounting")
	var pair:Array[GolfPlayer]=[players[0],players[1]]
	var ob:=LocalGolfMatch.new(pair,GolfCourse.single(hole))
	ob.begin_shot(_shot());ob.resolve_shot(Vector2(200,-100))
	check(ob.active_index==1 and ob.attempts[0].gross_score()==2,"OOB adds stroke and distance but others tee off before a re-tee")
	ob.begin_shot(_shot());ob.resolve_shot(Vector2(0,-40))
	check(ob.active_index==0,"OOB player returns from previous stroke position")
	var pickup:=LocalGolfMatch.new(pair,GolfCourse.single(hole))
	pickup.give_up();check(pickup.attempts[0].gross_score()==8 and pickup.attempts[0].finish_reason=="picked_up","Rule 21.2 pickup records the announced maximum score")
	pickup.begin_shot(_shot());pickup.resolve_shot(hole.cup)
	check(pickup.state==LocalGolfMatch.State.COMPLETE and pickup.leaders()==[1],"Completed gross totals determine the winner")
	var strict:=LocalGolfMatch.new(pair,GolfCourse.single(hole),{"format":"stroke_play"})
	strict.give_up();strict.begin_shot(_shot());strict.resolve_shot(hole.cup)
	check(strict.dnf_players.has(players[0].id) and strict.leaders()==[1],"Failure to finish in ordinary stroke play cannot win as a low score")
	_check_relief(hole)
	_check_store(players,course)
	var generated:=CourseGenerator.hole(741,0,.6)
	var same:=CourseGenerator.hole(741,0,.6)
	check(generated.play_errors().is_empty() and generated.surfaces==same.surfaces and generated.heights==same.heights,"Course generation is deterministic and produces playable layouts")
	if failures==0:print("PASS: honours, away-player order, tee priority after OOB, gross scoring, pickup/DNF, relief, courses, portraits and round persistence")
	quit(1 if failures else 0)

func _check_relief(hole:HoleDefinition)->void:
	var lie:=Vector2(0,-40);var previous:=hole.tee
	check(GolfRelief.validate(hole,lie,previous,"lateral",Vector2(2,-40),false).ok,"Rule 19 lateral relief allows two club-lengths, no nearer")
	check(not GolfRelief.validate(hole,lie,previous,"lateral",Vector2(0,-41),false).ok,"Lateral relief cannot advance toward the cup")
	check(not GolfRelief.validate(hole,lie,previous,"lateral",Vector2(3,-40),false).ok,"Lateral relief cannot exceed two club-lengths")
	check(GolfRelief.validate(hole,lie,previous,"back_line",Vector2(0,-35),false).ok,"Back-on-line relief lies behind the original ball")
	hole.surfaces[hole.cell_index(lie)]=HoleDefinition.Surface.SAND
	check(not GolfRelief.validate(hole,lie,previous,"lateral",Vector2(1.5,-40),false).ok,"One-stroke bunker relief cannot leave the bunker")
	var outside:=GolfRelief.validate(hole,lie,previous,"bunker_outside",Vector2(0,-35),false)
	check(outside.ok and outside.penalty==2,"Outside-bunker back-on-line option costs two strokes")
	hole.apply_brush(Vector2(10,-25),4,"fairway")
	check(not GolfRelief.validate(hole,lie,previous,"fairway_rescue",Vector2(10,-25),false).ok,"Strict configuration disables arbitrary fairway rescue")
	var rescue:=GolfRelief.validate(hole,lie,previous,"fairway_rescue",Vector2(10,-25),true)
	check(rescue.ok and rescue.penalty==2 and rescue.rule.begins_with("Simulator"),"Fairway rescue is explicit, penalised and labelled as a house rule")
	hole.add_tree(Vector2(10,-25))
	check(not GolfRelief.validate(hole,lie,previous,"fairway_rescue",Vector2(10,-25),true).ok,"A relief drop cannot be placed inside a trunk")

func _check_store(players:Array[GolfPlayer],course:GolfCourse)->void:
	var directory:="user://match-check-%d"%Time.get_ticks_msec()
	var store:=ClubhouseStore.new(directory)
	check(store.save_players(players) and store.load_players().size()==3,"Local roster persists")
	check(store.save_course(course) and store.load_course(course.id).holes.size()==2,"Saved favourites are an ordered multi-hole course")
	var image:=Image.create(64,100,false,Image.FORMAT_RGBA8);image.fill(Color("e6c798"))
	var path:=ProjectSettings.globalize_path(directory.path_join("photo.png"));image.save_png(path)
	check(store.import_photo(players[0],path),"Local player photo imports")
	var portrait:=Image.load_from_file(ProjectSettings.globalize_path(directory.path_join("portraits").path_join(players[0].photo_file)))
	check(portrait!=null and portrait.get_size()==Vector2i(256,256),"Player head is a bounded square portrait")
	var competition:=LocalGolfMatch.new(players,course)
	check(store.save_active(competition,{"elapsed":.5}) and not store.load_active().is_empty(),"Round resume stores layout once and lightweight live state separately")
	_cleanup(directory)

func _cleanup(path:String)->void:
	var directory:=DirAccess.open(path)
	if directory==null:return
	for child in directory.get_directories():_cleanup(path.path_join(child))
	for file in directory.get_files():DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
