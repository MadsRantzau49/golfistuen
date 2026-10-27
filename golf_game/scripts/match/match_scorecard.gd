class_name MatchScorecard
extends Control
signal resume_requested
signal next_requested
signal again_requested
signal setup_requested
signal menu_requested
var match_state:LocalGolfMatch


func _ready()->void:
	AppStyle.full_rect(self);theme=AppStyle.theme();AppStyle.shade(self,.72).offset_top=140
	var center:=CenterContainer.new();add_child(center);AppStyle.full_rect(center)
	center.offset_top=140;center.offset_bottom=-14
	var panel:=PanelContainer.new();panel.custom_minimum_size=Vector2(1050,650);panel.add_theme_stylebox_override("panel",AppStyle.box(Color("10251ffb"),18,Color("ffffff25"),26));center.add_child(panel)
	var column:=VBoxContainer.new();column.add_theme_constant_override("separation",14);panel.add_child(column)
	column.add_child(AppStyle.label("PINEWATER · LOCAL CLUBHOUSE",10,AppStyle.GOLD))
	var finished:=match_state.state==LocalGolfMatch.State.COMPLETE
	var title:="Round complete." if finished else ("Hole %d complete."%(match_state.hole_index+1) if match_state.state==LocalGolfMatch.State.HOLE_COMPLETE else "Your scorecard.")
	column.add_child(AppStyle.label(title,37,AppStyle.CREAM,true))
	column.add_child(AppStyle.label(match_state.course.title,17,AppStyle.MUTED))
	if finished:
		var names:PackedStringArray=[]
		for index in match_state.leaders():names.append(match_state.players[index].name)
		column.add_child(AppStyle.label(("Shared win · " if names.size()>1 else "Winner · ")+" / ".join(names) if not names.is_empty() else "No classified finishers",23,AppStyle.GOLD,true))
	var scroll:=ScrollContainer.new();scroll.custom_minimum_size=Vector2(990,330);scroll.size_flags_vertical=Control.SIZE_EXPAND_FILL;column.add_child(scroll)
	var table:=GridContainer.new();table.columns=match_state.players.size()+2;table.add_theme_constant_override("h_separation",12);table.add_theme_constant_override("v_separation",10);scroll.add_child(table)
	_cell(table,"HOLE",AppStyle.GOLD,65);_cell(table,"PAR",AppStyle.GOLD,50)
	for player in match_state.players:_cell(table,player.name,player.color(),130)
	for hole_index in range(match_state.course.holes.size()):
		_cell(table,str(hole_index+1),AppStyle.MUTED,65);_cell(table,str(match_state.course.holes[hole_index].par),AppStyle.MUTED,50)
		for index in range(match_state.players.size()):
			var player:=match_state.players[index];var scores:Array=match_state.scorecards[player.id]
			var text:="—"
			if hole_index<scores.size():
				text="DNF" if scores[hole_index].finish_reason=="dnf" else str(scores[hole_index].gross_score)+(" P" if scores[hole_index].finish_reason=="picked_up" else "")
			elif hole_index==match_state.hole_index and match_state.attempts[index].strokes>0:text="%d*"%match_state.attempts[index].gross_score()
			_cell(table,text,AppStyle.CREAM,130)
	_cell(table,"TOTAL",AppStyle.GOLD,65);_cell(table,"",AppStyle.GOLD,50)
	for index in range(match_state.players.size()):
		var player:=match_state.players[index]
		_cell(table,"DNF" if match_state.dnf_players.has(player.id) else "%d (%+d)"%[match_state.total(index),match_state.relative_to_par(index)],player.color(),130)
	column.add_child(AppStyle.label("P = picked up at maximum score · * = current-hole provisional strokes · equal totals share the win",11,AppStyle.MUTED))
	column.add_child(AppStyle.label("Honours then farthest away · %s · no putting, green +%d%s"%["Maximum Score" if match_state.config.format=="maximum_score" else "Ordinary stroke play",match_state.config.green_putts," · fairway rescue +2 (house rule)" if match_state.config.fairway_rescue else ""],12,AppStyle.MUTED))
	var actions:=HBoxContainer.new();actions.add_theme_constant_override("separation",12);column.add_child(actions)
	var main:=AppStyle.button("Play again" if finished else ("Next hole    ↗" if match_state.state==LocalGolfMatch.State.HOLE_COMPLETE else "Back to play"),true)
	main.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	main.pressed.connect(func():
		if finished:again_requested.emit()
		elif match_state.state==LocalGolfMatch.State.HOLE_COMPLETE:next_requested.emit()
		else:resume_requested.emit()
	)
	actions.add_child(main)
	for item in [["Players / course",setup_requested],["Main menu",menu_requested]]:
		var button:=AppStyle.button(item[0]);button.pressed.connect(func():item[1].emit());actions.add_child(button)
	main.grab_focus()


func _cell(parent:GridContainer,text:String,color:Color,width:float)->void:
	var label:=AppStyle.label(text,14,color);label.custom_minimum_size.x=width;label.clip_text=true;label.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER;parent.add_child(label)
