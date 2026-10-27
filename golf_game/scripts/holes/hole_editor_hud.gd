class_name HoleEditorHUD
extends CanvasLayer
signal tool_selected(tool:String)
signal save_requested
signal play_requested
signal new_requested
signal library_requested
signal back_requested
signal import_requested
signal export_requested
signal undo_requested
signal redo_requested
signal frame_requested
signal angle_requested
signal metadata_changed
signal rules_requested

var root:Control
var name_editor:LineEdit
var par_option:OptionButton
var cup_size:SpinBox
var species_option:OptionButton
var radius_slider:HSlider
var strength_slider:HSlider
var status:Label
var validation:Label
var save_button:Button
var play_button:Button
var rules_label:Label
var tool_buttons:Dictionary={}


func _ready()->void:
	root=Control.new(); add_child(root); AppStyle.full_rect(root)
	root.mouse_filter=Control.MOUSE_FILTER_IGNORE; root.theme=AppStyle.theme()
	_header(); _tools(); _inspector(); _footer()


func _header()->void:
	var panel:=AppStyle.panel(root,28,22,-28,104);panel.anchor_right=1
	var row:=HBoxContainer.new();row.add_theme_constant_override("separation",10);panel.add_child(row)
	var brand:=VBoxContainer.new();brand.size_flags_horizontal=Control.SIZE_EXPAND_FILL;row.add_child(brand)
	brand.add_child(AppStyle.label("Pinewater · Hole Studio",27,AppStyle.CREAM,true))
	brand.add_child(AppStyle.label("YOUR LANDSCAPE. YOUR NEXT GREAT SHOT.",9,AppStyle.GOLD))
	for action in [["New",new_requested],["My holes",library_requested],["Import",import_requested],["Export",export_requested],["Main menu",back_requested]]:
		var button:=AppStyle.button(action[0]);button.custom_minimum_size.x=84
		button.pressed.connect(func():action[1].emit());row.add_child(button)


func _tools()->void:
	var panel:=AppStyle.panel(root,28,126,264,0)
	var column:=VBoxContainer.new();column.add_theme_constant_override("separation",10);panel.add_child(column)
	for section in [["PAINT THE LAND",[["Fairway","fairway"],["Green","green"],["Rough","rough"],["Water","water"],["Sand","sand"],["OOB","oob"]]],
		["SHAPE THE LAND",[["Raise","raise"],["Lower","lower"],["Smooth","smooth"],["Flatten","flatten"]]],
		["MAKE IT A HOLE",[["Tee","tee"],["Cup","cup"],["Tree","tree"],["Erase trees","erase_tree"]]]]:
		column.add_child(AppStyle.label(section[0],10,AppStyle.GOLD))
		var grid:=GridContainer.new();grid.columns=2;grid.add_theme_constant_override("h_separation",7);grid.add_theme_constant_override("v_separation",7);column.add_child(grid)
		for item in section[1]:
			var button:=AppStyle.button(item[0]);button.custom_minimum_size=Vector2(96,37)
			button.add_theme_font_size_override("font_size",13)
			button.pressed.connect(func():tool_selected.emit(item[1]));grid.add_child(button);tool_buttons[item[1]]=button
	column.add_child(AppStyle.divider())
	var hint:=AppStyle.label("White stakes mark the playable plot. Red hatching is out of bounds.",12,AppStyle.MUTED)
	hint.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;hint.custom_minimum_size.x=196;column.add_child(hint)


func _inspector()->void:
	var panel:=AppStyle.panel(root,-318,126,-28,0);panel.anchor_left=1;panel.anchor_right=1
	var column:=VBoxContainer.new();column.add_theme_constant_override("separation",8);panel.add_child(column)
	column.add_child(AppStyle.label("YOUR HOLE",10,AppStyle.GOLD))
	name_editor=LineEdit.new();name_editor.max_length=80;name_editor.placeholder_text="Hole name";name_editor.custom_minimum_size.y=40
	name_editor.add_theme_stylebox_override("normal",AppStyle.box(Color("263c30"),8,Color("ffffff20"),10))
	name_editor.add_theme_color_override("font_color",AppStyle.CREAM)
	name_editor.text_submitted.connect(func(_value:String):metadata_changed.emit())
	name_editor.focus_exited.connect(func():metadata_changed.emit());column.add_child(name_editor)
	var row:=HBoxContainer.new();column.add_child(row)
	var label:=AppStyle.label("Par",14);label.size_flags_horizontal=Control.SIZE_EXPAND_FILL;row.add_child(label)
	par_option=OptionButton.new()
	for value in [3,4,5,6]:par_option.add_item(str(value))
	par_option.item_selected.connect(func(_index:int):metadata_changed.emit());row.add_child(par_option)
	var size_row:=HBoxContainer.new();column.add_child(size_row)
	var size_label:=AppStyle.label("Cup diameter",13);size_label.size_flags_horizontal=Control.SIZE_EXPAND_FILL;size_row.add_child(size_label)
	cup_size=SpinBox.new();cup_size.min_value=HoleDefinition.MIN_CUP_DIAMETER*100;cup_size.max_value=HoleDefinition.MAX_CUP_DIAMETER*100
	cup_size.step=.1;cup_size.suffix="cm";cup_size.value=HoleDefinition.DEFAULT_CUP_DIAMETER*100;cup_size.custom_minimum_size=Vector2(125,36)
	cup_size.tooltip_text="Visible opening and capture diameter. Enlarge it to make simulator shots more forgiving. Saved with this hole."
	cup_size.value_changed.connect(func(_value:float):metadata_changed.emit());size_row.add_child(cup_size)
	column.add_child(AppStyle.divider())
	radius_slider=_slider(column,"Brush radius",2,40,1,"m")
	strength_slider=_slider(column,"Sculpt strength",.5,8,.5,"m/s")
	column.add_child(AppStyle.label("TREE SPECIES",10,AppStyle.GOLD))
	species_option=OptionButton.new();species_option.add_item("Alpine spruce");species_option.add_item("Autumn aspen");species_option.custom_minimum_size.y=35;column.add_child(species_option)
	column.add_child(AppStyle.divider())
	validation=AppStyle.label("",13,AppStyle.MUTED);validation.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;validation.custom_minimum_size=Vector2(250,67);column.add_child(validation)
	save_button=AppStyle.button("Save hole    ·    Ctrl+S",true);save_button.pressed.connect(func():save_requested.emit());column.add_child(save_button)
	play_button=AppStyle.button("Test this hole     ↗");play_button.pressed.connect(func():play_requested.emit());column.add_child(play_button)
	rules_label=AppStyle.label("",11,AppStyle.MUTED)
	rules_label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;rules_label.custom_minimum_size.x=250;column.add_child(rules_label)
	var rules_button:=AppStyle.button("Simulator rules")
	rules_button.pressed.connect(func():rules_requested.emit());column.add_child(rules_button)
	radius_slider.value=12;strength_slider.value=2


func _slider(parent:VBoxContainer,title:String,minimum:float,maximum:float,step:float,unit:String)->HSlider:
	var row:=HBoxContainer.new();parent.add_child(row)
	var label:=AppStyle.label(title,13);label.size_flags_horizontal=Control.SIZE_EXPAND_FILL;row.add_child(label)
	var value:=AppStyle.label("",12,AppStyle.GOLD);row.add_child(value)
	var slider:=HSlider.new();slider.min_value=minimum;slider.max_value=maximum;slider.step=step;slider.custom_minimum_size.y=24
	slider.value_changed.connect(func(number:float):value.text="%.1f %s"%[number,unit]);parent.add_child(slider)
	return slider


func _footer()->void:
	var bar:=HBoxContainer.new();root.add_child(bar);bar.anchor_top=1;bar.anchor_bottom=1
	bar.offset_left=28;bar.offset_top=-100;bar.offset_bottom=-55;bar.add_theme_constant_override("separation",8)
	for item in [["Undo · Ctrl+Z",undo_requested],["Redo · Ctrl+Y",redo_requested],["Frame · F",frame_requested],["Plan / 3D",angle_requested]]:
		var button:=AppStyle.button(item[0]);button.pressed.connect(func():item[1].emit());bar.add_child(button)
	status=AppStyle.label("Left drag: brush   ·   Right/middle drag: pan   ·   Wheel: zoom",12,AppStyle.CREAM)
	root.add_child(status);status.anchor_top=1;status.anchor_bottom=1;status.offset_left=34;status.offset_top=-36


func show_document(hole:HoleDefinition,dirty:bool)->void:
	if not name_editor.has_focus(): name_editor.text=hole.title
	par_option.select(hole.par-3)
	if not cup_size.get_line_edit().has_focus():cup_size.set_value_no_signal(hole.cup_diameter_m*100)
	var errors:=hole.play_errors()
	validation.text="Ready to play · %.0f m · %d trees"%[hole.tee.distance_to(hole.cup),hole.trees.size()] if errors.is_empty() else "\n".join(errors)
	validation.add_theme_color_override("font_color",AppStyle.MUTED if errors.is_empty() else AppStyle.GOLD)
	play_button.disabled=not errors.is_empty()
	save_button.text="Save changes *   ·   Ctrl+S" if dirty else "Save hole    ·    Ctrl+S"
	var configuration:=HoleRules.create(GameSettings.values,hole.rules_overrides)
	rules_label.text="No putting · finish on green: +%d automatic strokes. %s"%[configuration.options.green_putts,"Hole-specific override." if not hole.rules_overrides.is_empty() else "Uses simulator rules."]


func select_tool(tool:String)->void:
	for key in tool_buttons:
		tool_buttons[key].add_theme_stylebox_override("normal",AppStyle.box(Color("4a5a3c") if key==tool else Color("19352b"),8,AppStyle.GOLD if key==tool else Color("ffffff16"),10))
