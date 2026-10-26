class_name HoleLibrary
extends Control
signal create_requested
signal play_requested(id:String)
signal edit_requested(id:String)
signal back_requested
var store:HoleStore


func _ready()->void:
	AppStyle.full_rect(self);theme=AppStyle.theme();AppStyle.shade(self,.82)
	var title:=AppStyle.label("Your next great hole.",44,AppStyle.CREAM,true);add_child(title);title.position=Vector2(68,96)
	var caption:=AppStyle.label("Build an alpine escape, then play it with simulator-friendly scoring.",17,AppStyle.MUTED);add_child(caption);caption.position=Vector2(70,158)
	var new_button:=AppStyle.button("Build a new hole    ↗",true);add_child(new_button)
	new_button.anchor_left=1;new_button.anchor_right=1;new_button.offset_left=-355;new_button.offset_right=-68;new_button.offset_top=110
	new_button.pressed.connect(func():create_requested.emit())
	var scroll:=ScrollContainer.new();add_child(scroll)
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left=68;scroll.offset_right=-68;scroll.offset_top=223;scroll.offset_bottom=-120
	var list:=VBoxContainer.new();list.size_flags_horizontal=Control.SIZE_EXPAND_FILL;list.add_theme_constant_override("separation",14);scroll.add_child(list)
	_card(list,{"id":"@demo","title":"Pinewater Meadow","par":4,"length":301.0,"playable":true},true)
	var designs:=store.list_holes()
	if designs.is_empty():list.add_child(AppStyle.label("Your saved designs will appear here. Start with rough, or edit a copy of the sample.",14,AppStyle.MUTED))
	for entry in designs:_card(list,entry,false)
	var back:=AppStyle.button("←  Main menu");add_child(back);back.anchor_top=1;back.anchor_bottom=1;back.offset_left=68;back.offset_top=-88;back.offset_bottom=-38
	back.pressed.connect(func():back_requested.emit())
	var note:=AppStyle.label("NO PUTTING · A BALL AT REST ON THE GREEN FINISHES WITH YOUR CONFIGURED AUTOMATIC STROKES",10,AppStyle.GOLD)
	add_child(note);note.anchor_top=1;note.anchor_bottom=1;note.offset_left=280;note.offset_top=-70


func _card(parent:VBoxContainer,entry:Dictionary,builtin:bool)->void:
	var panel:=PanelContainer.new();panel.custom_minimum_size.y=112;panel.add_theme_stylebox_override("panel",AppStyle.box());parent.add_child(panel)
	var row:=HBoxContainer.new();row.add_theme_constant_override("separation",20);panel.add_child(row)
	var info:=VBoxContainer.new();info.size_flags_horizontal=Control.SIZE_EXPAND_FILL;row.add_child(info)
	info.add_child(AppStyle.label("THE ALPINE COLLECTION" if builtin else "YOUR DESIGN",9,AppStyle.GOLD))
	var name_label:=AppStyle.label(entry.title,25,AppStyle.CREAM,true);name_label.clip_text=true;info.add_child(name_label)
	info.add_child(AppStyle.label("Par %d  ·  %.0f %s  ·  %s"%[entry.par,GameSettings.distance(entry.length),GameSettings.distance_suffix(),"Ready to play" if entry.playable else "Finish the cup / green in the editor"],13,AppStyle.MUTED))
	var edit:=AppStyle.button("Edit a copy" if builtin else "Edit");edit.custom_minimum_size.x=120;edit.pressed.connect(func():edit_requested.emit(entry.id));row.add_child(edit)
	var play:=AppStyle.button("Play hole    ↗",true);play.custom_minimum_size.x=150;play.disabled=not entry.playable
	play.pressed.connect(func():play_requested.emit(entry.id));row.add_child(play)
