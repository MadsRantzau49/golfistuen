class_name MatchSetup
extends Control
signal start_requested(competition:LocalGolfMatch)
signal back_requested
var store:ClubhouseStore
var hole_store:HoleStore
var selected_hole:HoleDefinition
var players:Array[GolfPlayer]=[]
var course:GolfCourse
var step:=0
var selected_player:=0
var _player_area:Control
var _course_area:Control
var _roster_grid:GridContainer
var _preview:GolferPreview
var _preview_name:Label
var _title:Label
var _caption:Label
var _status:Label
var _next:Button
var _add:Button
var _playlist:VBoxContainer
var _course_name:LineEdit
var _saved_courses:OptionButton
var _course_entries:Array[Dictionary]=[]
var _format:OptionButton
var _cap:OptionButton
var _green:SpinBox
var _rescue:CheckButton
var _count:SpinBox
var _seed:SpinBox
var _cup_size:SpinBox
var _busy:=false
var _photo_dialog:FileDialog


func _ready()->void:
	AppStyle.full_rect(self);theme=AppStyle.theme();AppStyle.shade(self,.9)
	players=store.load_players();course=GolfCourse.single(selected_hole if selected_hole else HoleDefinition.demo())
	_title=AppStyle.label("Bring your people.",42,AppStyle.CREAM,true);add_child(_title);_title.position=Vector2(60,60)
	_caption=AppStyle.label("01  PLAYERS    /    02  COURSE & RULES",12,AppStyle.GOLD);add_child(_caption);_caption.position=Vector2(63,122)
	_player_area=Control.new();add_child(_player_area);AppStyle.full_rect(_player_area);_player_area.mouse_filter=Control.MOUSE_FILTER_IGNORE
	_course_area=Control.new();add_child(_course_area);AppStyle.full_rect(_course_area);_course_area.mouse_filter=Control.MOUSE_FILTER_IGNORE
	_build_players();_build_course();_build_footer();_show_step()


func _input_style()->StyleBoxFlat:return AppStyle.box(Color("253e31"),8,Color("ffffff22"),10)


func _build_players()->void:
	_roster_grid=GridContainer.new();_roster_grid.columns=2;_roster_grid.position=Vector2(60,180);_roster_grid.add_theme_constant_override("h_separation",18);_roster_grid.add_theme_constant_override("v_separation",16);_player_area.add_child(_roster_grid)
	var preview_panel:=AppStyle.panel(_player_area,-425,175,-60,700);preview_panel.anchor_left=1;preview_panel.anchor_right=1
	var column:=VBoxContainer.new();column.add_theme_constant_override("separation",12);preview_panel.add_child(column)
	column.add_child(AppStyle.label("YOUR CLUBHOUSE CHARACTER",10,AppStyle.GOLD))
	_preview_name=AppStyle.label("",25,AppStyle.CREAM,true);column.add_child(_preview_name)
	_preview=GolferPreview.new();_preview.custom_minimum_size=Vector2(320,350);column.add_child(_preview)
	var swing:=AppStyle.button("Try that swing    ↗");swing.pressed.connect(func():_preview.golfer.swing());column.add_child(swing)
	column.add_child(AppStyle.label("Square heads. Big personalities.\nPhotos stay on this computer.",12,AppStyle.MUTED))
	_add=AppStyle.button("+  Add player");_player_area.add_child(_add);_add.position=Vector2(60,690);_add.custom_minimum_size.x=190
	_add.pressed.connect(_add_player)
	var draw:=AppStyle.button("Draw first-tee honours");_player_area.add_child(draw);draw.position=Vector2(270,690);draw.custom_minimum_size.x=240
	draw.pressed.connect(func():players.shuffle();selected_player=0;_refresh_players();_status.text="First-tee honours drawn. Later tees use the previous hole's gross scores.")
	_player_area.add_child(_hint("Up to six players · click a face to preview · click a colour to swap · list order is the agreed first-tee order",Vector2(63,755)))
	_refresh_players()


func _hint(text:String,at:Vector2)->Label:
	var label:=AppStyle.label(text,12,AppStyle.MUTED);label.position=at;return label


func _refresh_players()->void:
	for child in _roster_grid.get_children():_roster_grid.remove_child(child);child.queue_free()
	for index in range(players.size()):
		var player:=players[index]
		var panel:=PanelContainer.new();panel.custom_minimum_size=Vector2(385,150);panel.add_theme_stylebox_override("panel",AppStyle.box(Color("163126"),12,player.color().darkened(.3),14));_roster_grid.add_child(panel)
		var column:=VBoxContainer.new();column.add_theme_constant_override("separation",8);panel.add_child(column)
		var row:=HBoxContainer.new();row.add_theme_constant_override("separation",10);column.add_child(row)
		var face:=TextureButton.new();face.texture_normal=store.portrait(player);face.ignore_texture_size=true;face.stretch_mode=TextureButton.STRETCH_KEEP_ASPECT_CENTERED;face.custom_minimum_size=Vector2(64,64)
		face.pressed.connect(func():selected_player=index;_show_player());row.add_child(face)
		var info:=VBoxContainer.new();info.size_flags_horizontal=Control.SIZE_EXPAND_FILL;row.add_child(info)
		info.add_child(AppStyle.label("PLAYER %d"%(index+1),10,player.color()))
		var name:=LineEdit.new();name.text=player.name;name.max_length=24;name.add_theme_stylebox_override("normal",_input_style());name.add_theme_color_override("font_color",AppStyle.CREAM);name.custom_minimum_size.y=36
		name.text_changed.connect(func(value:String):player.name=value;_show_player());info.add_child(name)
		var actions:=HBoxContainer.new();actions.add_theme_constant_override("separation",8);column.add_child(actions)
		for label in [GolfPlayer.COLOR_NAMES[player.color_index],"Photo","Default head","Remove"]:
			var button:=AppStyle.button(label);button.custom_minimum_size.y=32;button.add_theme_font_size_override("font_size",11)
			button.disabled=label=="Remove" and players.size()==1
			button.pressed.connect(func():
				if label=="Photo":_choose_photo(index)
				elif label=="Default head":player.photo_file="";selected_player=index;_refresh_players()
				elif label=="Remove":players.remove_at(index);selected_player=clampi(selected_player,0,players.size()-1);_refresh_players()
				else:_swap_color(index)
			)
			actions.add_child(button)
	_add.disabled=players.size()>=GolfPlayer.MAX_PLAYERS if is_instance_valid(_add) else false
	_show_player()


func _show_player()->void:
	if players.is_empty() or not is_instance_valid(_preview):return
	selected_player=clampi(selected_player,0,players.size()-1)
	_preview_name.text=players[selected_player].name
	_preview.show_player(players[selected_player],store.portrait(players[selected_player]))


func _add_player()->void:
	if players.size()>=GolfPlayer.MAX_PLAYERS:return
	var used:Array=[]
	for player in players:used.append(player.color_index)
	var color:=0
	while color in used:color+=1
	players.append(GolfPlayer.new("Player %d"%(players.size()+1),color));selected_player=players.size()-1;_refresh_players()


func _swap_color(index:int)->void:
	var old:=players[index].color_index;var next:=(old+1)%GolfPlayer.COLORS.size()
	for other in players:
		if other!=players[index] and other.color_index==next:other.color_index=old;break
	players[index].color_index=next;selected_player=index;_refresh_players()


func _choose_photo(index:int)->void:
	if is_instance_valid(_photo_dialog):_photo_dialog.queue_free()
	_photo_dialog=FileDialog.new();_photo_dialog.access=FileDialog.ACCESS_FILESYSTEM;_photo_dialog.file_mode=FileDialog.FILE_MODE_OPEN_FILE
	_photo_dialog.filters=PackedStringArray(["*.png,*.jpg,*.jpeg,*.webp ; Player photo"]);_photo_dialog.size=Vector2i(850,550);add_child(_photo_dialog)
	_photo_dialog.file_selected.connect(func(path:String):
		if store.import_photo(players[index],path):selected_player=index;_refresh_players();_status.text="Portrait cropped to a square and saved locally."
		else:_status.text=store.last_error
	)
	_photo_dialog.popup_centered()


func _build_course()->void:
	var saved_row:=HBoxContainer.new();saved_row.position=Vector2(620,166);saved_row.add_theme_constant_override("separation",10);_course_area.add_child(saved_row)
	_saved_courses=OptionButton.new();_saved_courses.custom_minimum_size=Vector2(270,40);saved_row.add_child(_saved_courses)
	_saved_courses.item_selected.connect(func(index:int):
		if index>0:
			var loaded:=store.load_course(_course_entries[index-1].id)
			if loaded:course=loaded;_course_name.text=course.title;_refresh_playlist()
	)
	_course_name=LineEdit.new();_course_name.text=course.title;_course_name.max_length=80;_course_name.custom_minimum_size=Vector2(285,40);_course_name.add_theme_stylebox_override("normal",_input_style());_course_name.add_theme_color_override("font_color",AppStyle.CREAM);saved_row.add_child(_course_name)
	var save:=AppStyle.button("Save course");save.pressed.connect(_save_course);saved_row.add_child(save)
	_refresh_saved_courses()
	var available_panel:=AppStyle.panel(_course_area,60,222,590,590)
	var available_column:=VBoxContainer.new();available_column.add_theme_constant_override("separation",12);available_panel.add_child(available_column)
	available_column.add_child(AppStyle.label("YOUR PLAYABLE HOLES",11,AppStyle.GOLD))
	var available_scroll:=ScrollContainer.new();available_scroll.size_flags_vertical=Control.SIZE_EXPAND_FILL;available_column.add_child(available_scroll)
	var available:=VBoxContainer.new();available.size_flags_horizontal=Control.SIZE_EXPAND_FILL;available.add_theme_constant_override("separation",8);available_scroll.add_child(available)
	var entries:Array[Dictionary]=[{"id":"@demo","title":"Pinewater Meadow","par":4,"playable":true}]
	entries.append_array(hole_store.list_holes())
	for entry in entries:
		var row:=HBoxContainer.new();available.add_child(row)
		var label:=AppStyle.label("%s · Par %d"%[entry.title,entry.par],14);label.custom_minimum_size.x=365;label.clip_text=true;row.add_child(label)
		var add:=AppStyle.button("Add +");add.custom_minimum_size.y=35;add.disabled=not entry.playable
		add.pressed.connect(func():
			if course.holes.size()>=GolfCourse.MAX_HOLES:_status.text="A course supports up to 36 holes.";return
			var document:=HoleDefinition.demo() if entry.id=="@demo" else hole_store.load_hole(entry.id)
			if document:course.holes.append(document);_refresh_playlist()
		);row.add_child(add)
	var selected_panel:=AppStyle.panel(_course_area,620,222,-60,590);selected_panel.anchor_right=1
	var selected_column:=VBoxContainer.new();selected_column.add_theme_constant_override("separation",12);selected_panel.add_child(selected_column)
	selected_column.add_child(AppStyle.label("COURSE ORDER · FAVOURITES CAN REPEAT",11,AppStyle.GOLD))
	var scroll:=ScrollContainer.new();scroll.size_flags_vertical=Control.SIZE_EXPAND_FILL;selected_column.add_child(scroll)
	_playlist=VBoxContainer.new();_playlist.size_flags_horizontal=Control.SIZE_EXPAND_FILL;_playlist.add_theme_constant_override("separation",7);scroll.add_child(_playlist)
	var generator:=AppStyle.panel(_course_area,60,610,-60,683);generator.anchor_right=1
	var generator_row:=HBoxContainer.new();generator_row.add_theme_constant_override("separation",14);generator.add_child(generator_row)
	generator_row.add_child(AppStyle.label("GENERATE AN ALPINE COURSE",11,AppStyle.GOLD))
	_count=_spin(generator_row,1,36,9," holes");_seed=_spin(generator_row,1,999999,7421," seed")
	_cup_size=_spin(generator_row,10.8,300,30," cm cup");_cup_size.step=.1;_cup_size.value=30
	var generate:=AppStyle.button("Generate course    ↗",true);generate.pressed.connect(_generate);generator_row.add_child(generate)
	var rules_panel:=AppStyle.panel(_course_area,60,702,-60,795);rules_panel.anchor_right=1
	var rules_row:=HBoxContainer.new();rules_row.add_theme_constant_override("separation",15);rules_panel.add_child(rules_row)
	_format=OptionButton.new();_format.add_item("Maximum Score · pickups allowed");_format.add_item("Ordinary stroke play · pickup = DNF");_format.custom_minimum_size=Vector2(315,40);rules_row.add_child(_format)
	_cap=OptionButton.new()
	for value in ["Cap: double par","Cap: par + 5","Cap: 12 strokes"]:_cap.add_item(value)
	_cap.custom_minimum_size=Vector2(170,40);rules_row.add_child(_cap)
	rules_row.add_child(AppStyle.label("Green +",12,AppStyle.MUTED));_green=_spin(rules_row,0,3,int(GameSettings.get_value("green_putts"))," strokes")
	_rescue=CheckButton.new();_rescue.text="Fairway rescue +2\nSimulator house rule";_rescue.button_pressed=true;_rescue.add_theme_color_override("font_color",AppStyle.MUTED);_rescue.add_theme_font_size_override("font_size",12);rules_row.add_child(_rescue)
	_format.item_selected.connect(func(index:int):_cap.disabled=index==1)
	_refresh_playlist()


func _spin(parent:Node,minimum:float,maximum:float,value:float,suffix:String)->SpinBox:
	var spin:=SpinBox.new();spin.min_value=minimum;spin.max_value=maximum;spin.step=1;spin.value=value;spin.suffix=suffix;spin.custom_minimum_size=Vector2(120,38);parent.add_child(spin);return spin


func _refresh_saved_courses()->void:
	_saved_courses.clear();_saved_courses.add_item("Choose a saved course…")
	_course_entries=store.list_courses()
	for entry in _course_entries:_saved_courses.add_item("%s · %d holes"%[entry.title,entry.holes])


func _refresh_playlist()->void:
	if _playlist==null:return
	for child in _playlist.get_children():_playlist.remove_child(child);child.queue_free()
	for index in range(course.holes.size()):
		var hole:=course.holes[index]
		var row:=HBoxContainer.new();row.add_theme_constant_override("separation",8);_playlist.add_child(row)
		var name:=AppStyle.label("%02d  %s · Par %d"%[index+1,hole.title,hole.par],14);name.size_flags_horizontal=Control.SIZE_EXPAND_FILL;name.clip_text=true;row.add_child(name)
		for text in ["↑","↓","×"]:
			var button:=AppStyle.button(text);button.custom_minimum_size=Vector2(38,32)
			button.disabled=(text=="↑" and index==0) or (text=="↓" and index==course.holes.size()-1)
			button.pressed.connect(func():
				if text=="×":course.holes.remove_at(index)
				else:
					var target:=index-1 if text=="↑" else index+1
					var swap:=course.holes[target];course.holes[target]=course.holes[index];course.holes[index]=swap
				_refresh_playlist()
			);row.add_child(button)
	if _next:_next.text="Start round · %d players · %d holes    ↗"%[players.size(),course.holes.size()] if step==1 else "Choose course    ↗"


func _generate()->void:
	if _busy:return
	_busy=true;_next.disabled=true
	var generated:=GolfCourse.new();generated.title="Alpine Escape · %d holes"%int(_count.value)
	generated.metadata={"seed":int(_seed.value),"generated":true}
	for index in range(int(_count.value)):
		_status.text="Shaping hole %d of %d…"%[index+1,int(_count.value)]
		generated.holes.append(CourseGenerator.hole(int(_seed.value),index,_cup_size.value/100.0))
		await get_tree().process_frame
	course=generated;_course_name.text=course.title;_refresh_playlist();_busy=false;_next.disabled=false
	_status.text="Generated %d different holes. Save this course to play it again in one click."%course.holes.size()


func _save_course()->void:
	if _busy:return
	course.title=_course_name.text.strip_edges()
	if course.title.is_empty():_status.text="Give the course a name.";return
	if store.save_course(course):_refresh_saved_courses();_status.text="Course saved with its ordered hole snapshots."
	else:_status.text=store.last_error


func _build_footer()->void:
	var back:=AppStyle.button("←  Back");add_child(back);back.anchor_top=1;back.anchor_bottom=1;back.offset_left=60;back.offset_top=-75;back.offset_bottom=-25
	back.pressed.connect(func():
		if _busy:return
		if step==1:step=0;_show_step()
		else:back_requested.emit()
	)
	_next=AppStyle.button("Choose course    ↗",true);add_child(_next);_next.anchor_left=1;_next.anchor_right=1;_next.anchor_top=1;_next.anchor_bottom=1
	_next.offset_left=-490;_next.offset_right=-60;_next.offset_top=-75;_next.offset_bottom=-25;_next.pressed.connect(_advance)
	_status=AppStyle.label("Names, colours and photos are saved locally.",12,AppStyle.MUTED);add_child(_status);_status.anchor_top=1;_status.anchor_bottom=1;_status.anchor_right=1;_status.offset_left=205;_status.offset_top=-58;_status.offset_right=-510;_status.clip_text=true


func _show_step()->void:
	_player_area.visible=step==0;_course_area.visible=step==1
	_title.text="Bring your people." if step==0 else "Choose your escape."
	_next.text="Choose course    ↗" if step==0 else "Start round · %d players · %d holes    ↗"%[players.size(),course.holes.size()]
	if step==0:_show_player()


func _advance()->void:
	if _busy:return
	for player in players:
		player.name=player.name.strip_edges()
		if player.name.is_empty():_status.text="Give every player a name.";return
	if not store.save_players(players):_status.text="The roster could not be saved.";return
	if step==0:step=1;_show_step();return
	if course.holes.is_empty():_status.text="Add a hole or generate a course first.";return
	course.title=_course_name.text.strip_edges()
	if course.title.is_empty():course.title="My alpine course"
	var snapshot:=GolfCourse.from_dict(course.to_dict())
	if snapshot==null:_status.text="This course contains an unfinished hole.";return
	var roster:Array[GolfPlayer]=[]
	for player in players:roster.append(GolfPlayer.from_dict(player.to_dict()))
	var config:={"format":"maximum_score" if _format.selected==0 else "stroke_play",
		"cap_policy":["double_par","par_plus_five","fixed"][_cap.selected],"fixed_cap":12,
		"green_putts":int(_green.value),"fairway_rescue":_rescue.button_pressed}
	start_requested.emit(LocalGolfMatch.new(roster,snapshot,config))
