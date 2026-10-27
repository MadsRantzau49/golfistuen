class_name LocalGolfMatch
extends RefCounted
## Competitive state, independent of animation, transport, UI and physics.
enum State { PLAYING, HOLE_COMPLETE, COMPLETE }
const DEFAULT_CONFIG:Dictionary={"format":"maximum_score","cap_policy":"double_par","fixed_cap":12,"green_putts":2,"fairway_rescue":true}
var id:=""
var players:Array[GolfPlayer]=[]
var course:GolfCourse
var config:Dictionary=DEFAULT_CONFIG.duplicate()
var hole_index:=0
var active_index:=0
var state:=State.PLAYING
var tee_order:Array[int]=[]
var attempts:Array[HoleRound]=[]
var scorecards:Dictionary={}
var dnf_players:Dictionary={}


func _init(roster:Array[GolfPlayer],layout:GolfCourse,settings:Dictionary={})->void:
	id="round-%x-%x"%[Time.get_ticks_usec(),randi()]
	players.assign(roster.slice(0,GolfPlayer.MAX_PLAYERS));course=layout
	if players.is_empty():players.append(GolfPlayer.new("Player 1",0))
	for key in DEFAULT_CONFIG:config[key]=settings.get(key,DEFAULT_CONFIG[key])
	if config.format not in ["maximum_score","stroke_play"]:config.format="maximum_score"
	if config.cap_policy not in ["double_par","par_plus_five","fixed"]:config.cap_policy="double_par"
	config.fixed_cap=clampi(int(config.fixed_cap),3,30);config.green_putts=clampi(int(config.green_putts),0,3)
	config.fairway_rescue=bool(config.fairway_rescue)
	for index in range(players.size()):tee_order.append(index);scorecards[players[index].id]=[]
	_start_hole()


func current_hole()->HoleDefinition:return course.holes[hole_index]
func current_round()->HoleRound:return attempts[active_index]
func current_player()->GolfPlayer:return players[active_index]


func _start_hole()->void:
	attempts.clear();state=State.PLAYING
	var hole:=current_hole()
	var cap:=0
	if config.format=="maximum_score":
		cap=hole.par*2 if config.cap_policy=="double_par" else (hole.par+5 if config.cap_policy=="par_plus_five" else int(config.fixed_cap))
	var rules:=HoleRules.create({"green_putts":int(config.green_putts),"max_strokes":cap,"water_penalty":1,"oob_penalty":1})
	for player in players:attempts.append(HoleRound.new(hole,rules))
	active_index=tee_order[0]


func begin_shot(shot:GolfShot)->bool:
	return state==State.PLAYING and current_round().begin_shot(shot.shot_id)


func resolve_shot(point:Vector2)->Dictionary:
	if state!=State.PLAYING:return {}
	var result:=current_round().resolve_rest(point)
	_update_progress()
	return result


func give_up()->bool:
	if state!=State.PLAYING or not current_round().give_up(config.format=="maximum_score"):return false
	_update_progress();return true


func relief(mode:String,point:Vector2)->Dictionary:
	if state!=State.PLAYING:return {"ok":false,"error":"This hole is complete."}
	var result:=current_round().take_relief(mode,point,bool(config.fairway_rescue))
	if result.ok:
		# Rule 6.4d: voluntary relief is ordered from the original lie; taking it
		# does not surrender the already-selected player's turn.
		if current_round().state==HoleRound.State.COMPLETE:_update_progress()
	return result


func _update_progress()->void:
	for index in range(players.size()):
		var attempt:=attempts[index]
		var card:Array=scorecards[players[index].id]
		if attempt.state==HoleRound.State.COMPLETE and card.size()==hole_index:
			card.append(attempt.result())
			if attempt.finish_reason=="dnf":dnf_players[players[index].id]=true
	var next:=_next_player()
	if next<0:state=State.COMPLETE if hole_index==course.holes.size()-1 else State.HOLE_COMPLETE
	else:active_index=next


func _next_player()->int:
	# Everyone's first tee stroke precedes anyone's second stroke, including an
	# OOB re-tee (Rule 6.4c). Honour ties preserve the previous tee order.
	for index in tee_order:
		if attempts[index].state==HoleRound.State.READY and attempts[index].strokes==0:return index
	var chosen:=-1;var farthest:=-1.0
	for index in tee_order:
		if attempts[index].state!=HoleRound.State.READY:continue
		var distance:=attempts[index].lie.distance_to(current_hole().cup)
		if distance>farthest+.01:chosen=index;farthest=distance
	return chosen


func advance_hole()->bool:
	if state!=State.HOLE_COMPLETE:return false
	var order:=tee_order.duplicate()
	order.sort_custom(func(a:int,b:int)->bool:
		var av:float=INF if attempts[a].finish_reason=="dnf" else float(attempts[a].gross_score())
		var bv:float=INF if attempts[b].finish_reason=="dnf" else float(attempts[b].gross_score())
		if av==bv:return tee_order.find(a)<tee_order.find(b)
		return av<bv
	)
	tee_order.assign(order);hole_index+=1;_start_hole();return true


func total(index:int)->int:
	var sum:=0
	for result in scorecards[players[index].id]:sum+=int(result.gross_score)
	return sum


func relative_to_par(index:int)->int:
	var sum:=0
	for result in scorecards[players[index].id]:sum+=int(result.gross_score)-int(result.par)
	return sum


func leaders()->Array[int]:
	var eligible:Array[int]=[]
	for index in range(players.size()):
		if not dnf_players.has(players[index].id):eligible.append(index)
	if eligible.is_empty():return []
	var best:=100000000
	for index in eligible:best=mini(best,total(index))
	var result:Array[int]=[]
	for index in eligible:
		if total(index)==best:result.append(index)
	return result


func snapshot(include_course:=true)->Dictionary:
	var roster:Array=[];var rounds:Array=[]
	for player in players:roster.append(player.to_dict())
	for attempt in attempts:rounds.append(attempt.snapshot())
	var data:={"schema_version":1,"id":id,"players":roster,"config":config.duplicate(),
		"hole_index":hole_index,"active_index":active_index,"state":state,"tee_order":tee_order.duplicate(),
		"attempts":rounds,"scorecards":scorecards.duplicate(true),"dnf_players":dnf_players.duplicate()}
	if include_course:data["course"]=course.to_dict()
	return data


static func restore(data:Dictionary)->LocalGolfMatch:
	if data.get("schema_version")!=1 or not data.get("players") is Array or data.players.is_empty() or data.players.size()>GolfPlayer.MAX_PLAYERS:return null
	if not data.get("course") is Dictionary or not data.get("config") is Dictionary:return null
	var layout:=GolfCourse.from_dict(data.course)
	if layout==null:return null
	var roster:Array[GolfPlayer]=[];var ids:Dictionary={}
	for raw in data.players:
		if not raw is Dictionary:return null
		var player:=GolfPlayer.from_dict(raw)
		if player==null or ids.has(player.id):return null
		roster.append(player);ids[player.id]=true
	for key in ["hole_index","active_index","state"]:
		if not HoleDefinition._number(data.get(key)) or data[key]!=int(data[key]):return null
	if data.hole_index<0 or data.hole_index>=layout.holes.size() or data.active_index<0 or data.active_index>=roster.size() or data.state<0 or data.state>State.COMPLETE:return null
	var match_state:=LocalGolfMatch.new(roster,layout,data.config)
	match_state.id=str(data.get("id",match_state.id));match_state.hole_index=int(data.hole_index);match_state.active_index=int(data.active_index);match_state.state=int(data.state)
	if not data.get("tee_order") is Array or data.tee_order.size()!=roster.size() or not data.get("attempts") is Array or data.attempts.size()!=roster.size():return null
	match_state.tee_order.clear();var order:Dictionary={}
	for raw in data.tee_order:
		if not HoleDefinition._number(raw) or raw!=int(raw) or raw<0 or raw>=roster.size() or order.has(int(raw)):return null
		order[int(raw)]=true;match_state.tee_order.append(int(raw))
	match_state.attempts.clear()
	for raw in data.attempts:
		if not raw is Dictionary:return null
		var attempt:=HoleRound.restore(match_state.current_hole(),raw)
		if attempt==null:return null
		match_state.attempts.append(attempt)
	if not data.get("scorecards") is Dictionary or not data.get("dnf_players",{}) is Dictionary:return null
	match_state.scorecards=data.scorecards.duplicate(true);match_state.dnf_players=data.get("dnf_players",{}).duplicate()
	for player in roster:
		var card:Variant=match_state.scorecards.get(player.id)
		if not card is Array or card.size()>layout.holes.size():return null
		for result in card:
			if not result is Dictionary or not HoleDefinition._number(result.get("gross_score")) or not HoleDefinition._number(result.get("par")):return null
	return match_state
