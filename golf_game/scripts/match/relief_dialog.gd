class_name ReliefDialog
extends Control
signal closed
signal apply_requested(mode:String,point:Vector2)
var match_state:LocalGolfMatch
var _map:ReliefMap
var _option:OptionButton
var _description:Label
var _confirm:Button
var _modes:=["stroke_distance","lateral","back_line","bunker_outside","fairway_rescue"]


func _ready()->void:
	AppStyle.full_rect(self);theme=AppStyle.theme();AppStyle.shade(self,.72).offset_top=140
	var center:=CenterContainer.new();add_child(center);AppStyle.full_rect(center)
	center.offset_top=140;center.offset_bottom=-14
	var panel:=PanelContainer.new();panel.custom_minimum_size=Vector2(910,680);panel.add_theme_stylebox_override("panel",AppStyle.box(Color("10251ffb"),18,Color("ffffff25"),25));center.add_child(panel)
	var column:=VBoxContainer.new();column.add_theme_constant_override("separation",13);panel.add_child(column)
	column.add_child(AppStyle.label("%s · RELIEF OPTIONS"%match_state.current_player().name.to_upper(),10,AppStyle.GOLD))
	column.add_child(AppStyle.label("Find a fair lie.",35,AppStyle.CREAM,true))
	_option=OptionButton.new();_option.custom_minimum_size.y=42
	for text in ["Stroke and distance · +1 · Rule 19.2a","Lateral: two club-lengths · +1 · Rule 19.2c","Back on line · +1 · Rule 19.2b","Outside bunker, back on line · +2 · Rule 19.3b","Drop to fairway · +2 · simulator house rule"]:_option.add_item(text)
	_option.set_item_disabled(3,match_state.current_hole().surface_at(match_state.current_round().lie)!=HoleDefinition.Surface.SAND)
	_option.set_item_disabled(4,not bool(match_state.config.fairway_rescue))
	_option.item_selected.connect(_mode_changed);column.add_child(_option)
	_map=ReliefMap.new();_map.hole=match_state.current_hole();_map.original=match_state.current_round().lie;_map.candidate=_map.original
	_map.custom_minimum_size=Vector2(850,330);_map.size_flags_vertical=Control.SIZE_EXPAND_FILL;_map.point_selected.connect(_select);column.add_child(_map)
	_description=AppStyle.label("",14);_description.custom_minimum_size=Vector2(850,42);_description.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;column.add_child(_description)
	column.add_child(AppStyle.label("Click a drop point · wheel zoom · right-drag pan · white = original lie · green = valid drop · no nearer the cup",11,AppStyle.MUTED))
	var actions:=HBoxContainer.new();actions.add_theme_constant_override("separation",12);column.add_child(actions)
	_confirm=AppStyle.button("Take relief",true);_confirm.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	_confirm.pressed.connect(func():apply_requested.emit(_modes[_option.selected],_map.candidate));actions.add_child(_confirm)
	var cancel:=AppStyle.button("Keep playing");cancel.pressed.connect(func():closed.emit());actions.add_child(cancel)
	_mode_changed(0)


func _mode_changed(index:int)->void:
	_map.mode=_modes[index];_map.center=_map.original;_map.span=30
	var point:=_map.original
	if index==0:
		point=match_state.current_round().previous_stroke_lie
		_map.center=(point+_map.original)*.5;_map.span=maxf(100,point.distance_to(_map.original)*2.5)
	elif index==1:point+=Vector2(2,0)
	elif index in [2,3]:point+=(_map.original-match_state.current_hole().cup).normalized()*4
	elif index==4:
		var fairway:Variant=GolfRelief.nearest_fairway(match_state.current_hole(),_map.original)
		if fairway!=null:point=fairway
		_map.center=(point+_map.original)*.5;_map.span=maxf(80,point.distance_to(_map.original)*2.5)
	_select(point)


func _select(point:Vector2)->void:
	_map.candidate=point
	var result:=GolfRelief.validate(match_state.current_hole(),match_state.current_round().lie,match_state.current_round().previous_stroke_lie,_modes[_option.selected],point,bool(match_state.config.fairway_rescue))
	_map.valid=result.ok;_confirm.disabled=not result.ok
	if result.ok:_map.candidate=result.point
	_description.text=("%s · +%d penalty stroke%s. The selected player keeps the current turn."%[result.rule,result.penalty,"" if result.penalty==1 else "s"]) if result.ok else result.error
	_map.queue_redraw()
