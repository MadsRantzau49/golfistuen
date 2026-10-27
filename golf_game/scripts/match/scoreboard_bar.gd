class_name ScoreboardBar
extends Control
signal scorecard_requested
var match_state:LocalGolfMatch
var store:ClubhouseStore
var _cards:Array[Dictionary]=[]


func _ready()->void:
	theme=AppStyle.theme();mouse_filter=Control.MOUSE_FILTER_IGNORE


func bind_match(competition:LocalGolfMatch,data:ClubhouseStore)->void:
	match_state=competition;store=data
	for child in get_children():remove_child(child);child.queue_free()
	_cards.clear()
	var row:=HBoxContainer.new();add_child(row);AppStyle.full_rect(row);row.add_theme_constant_override("separation",8)
	for index in range(competition.players.size()):
		var player:=competition.players[index]
		var panel:=PanelContainer.new();panel.size_flags_horizontal=Control.SIZE_EXPAND_FILL;row.add_child(panel)
		panel.mouse_default_cursor_shape=Control.CURSOR_POINTING_HAND
		panel.gui_input.connect(func(event:InputEvent):
			if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT and event.pressed:scorecard_requested.emit()
		)
		var column:=VBoxContainer.new();column.add_theme_constant_override("separation",4);panel.add_child(column)
		var name_row:=HBoxContainer.new();column.add_child(name_row)
		var image:=TextureRect.new();image.texture=store.portrait(player);image.custom_minimum_size=Vector2(31,31)
		image.expand_mode=TextureRect.EXPAND_IGNORE_SIZE;image.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_COVERED;image.mouse_filter=Control.MOUSE_FILTER_IGNORE;name_row.add_child(image)
		var name:=AppStyle.label("%d  %s"%[index+1,player.name],14,player.color());name.clip_text=true;name.size_flags_horizontal=Control.SIZE_EXPAND_FILL;name_row.add_child(name)
		var score:=AppStyle.label("0",25,AppStyle.CREAM,true);column.add_child(score)
		var status:=AppStyle.label("",11,AppStyle.MUTED);column.add_child(status)
		_cards.append({"panel":panel,"score":score,"status":status,"active":null})
	refresh()


func refresh()->void:
	if match_state==null:return
	for index in range(_cards.size()):
		var player:=match_state.players[index];var card:Dictionary=_cards[index]
		var attempt:=match_state.attempts[index]
		var active:=match_state.state==LocalGolfMatch.State.PLAYING and match_state.active_index==index
		if card.active!=active:
			card.active=active
			card.panel.add_theme_stylebox_override("panel",AppStyle.box(Color("203b2ff5") if active else Color("10251fee"),12,AppStyle.GOLD if active else player.color().darkened(.45),10))
		var counted:bool=match_state.scorecards[player.id].size()>match_state.hole_index
		var total:=match_state.total(index)+(0 if counted else attempt.gross_score())
		var dnf:=match_state.dnf_players.has(player.id)
		card.score.text="DNF" if dnf else "%d total"%total
		var relative:=match_state.relative_to_par(index)
		var par_text:="E" if relative==0 else "%+d"%relative
		var current:="PICKED UP" if attempt.finish_reason=="picked_up" else ("DONE" if attempt.state==HoleRound.State.COMPLETE else ("YOUR SHOT" if active else "WAITING"))
		card.status.text="H%d: %d  ·  %s  ·  %s"%[match_state.hole_index+1,attempt.gross_score(),par_text,current]
		card.panel.tooltip_text="%s · completed-hole score %s to par. Click for the full scorecard."%[player.name,par_text]
