class_name PinewaterSettingsPanel
extends Control

signal closed
var controls: Dictionary={}
var close_button: Button
var initial_tab:=0


func _ready() -> void:
	AppStyle.full_rect(self)
	theme=AppStyle.theme()
	AppStyle.shade(self,.75)
	var center := CenterContainer.new()
	add_child(center)
	AppStyle.full_rect(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size=Vector2(760,600)
	panel.add_theme_stylebox_override("panel",AppStyle.box(Color("12291ffb"),20,Color("ffffff20"),32))
	center.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation",19)
	panel.add_child(column)
	column.add_child(AppStyle.label("MAKE YOURSELF AT HOME",10,AppStyle.GOLD))
	column.add_child(AppStyle.label("A little more you.",36,AppStyle.CREAM,true))
	column.add_child(AppStyle.label("Preferences are saved automatically on this computer.",14,AppStyle.MUTED))
	column.add_child(AppStyle.divider())
	var tabs:=TabContainer.new();tabs.custom_minimum_size.y=455
	tabs.add_theme_color_override("font_selected_color",AppStyle.GOLD)
	tabs.add_theme_color_override("font_unselected_color",AppStyle.MUTED)
	tabs.add_theme_stylebox_override("panel",AppStyle.box(Color.TRANSPARENT,0,Color.TRANSPARENT,0))
	column.add_child(tabs)
	var columns := HBoxContainer.new();columns.name="Experience"
	columns.add_theme_constant_override("separation",40)
	tabs.add_child(columns)
	var display := VBoxContainer.new()
	display.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	display.add_theme_constant_override("separation",14)
	columns.add_child(display)
	display.add_child(AppStyle.label("DISPLAY & COMFORT",11,AppStyle.GOLD))
	_toggle(display,"Fullscreen","fullscreen")
	_choice(display,"Graphics quality","quality",["Low","Medium","High"])
	_choice(display,"Distance units","units",["Metres","Yards"])
	_toggle(display,"Reduced camera motion","reduced_motion")
	_toggle(display,"Follow the ball automatically","auto_follow")
	_toggle(display,"Show ball trail","show_trail")
	var audio := VBoxContainer.new()
	audio.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	audio.add_theme_constant_override("separation",14)
	columns.add_child(audio)
	audio.add_child(AppStyle.label("SOUND",11,AppStyle.GOLD))
	_volume(audio,"Master volume","master_volume")
	_volume(audio,"Nature ambience","ambience_volume")
	_volume(audio,"Shot & interface sounds","effects_volume")
	audio.add_child(AppStyle.label("CONTROLS\n\nSpace   Launch a practice shot\n1 / 2 / 3   Driver / iron / wedge\nC   Change camera\nR   Reset tee\nP   Replay\nEscape   Pause / back\nF11   Fullscreen",13,AppStyle.MUTED))
	var rules:=VBoxContainer.new();rules.name="Simulator rules";rules.add_theme_constant_override("separation",18);tabs.add_child(rules)
	rules.add_child(AppStyle.label("NO PUTTING REQUIRED",11,AppStyle.GOLD))
	var explanation:=AppStyle.label("When the ball stops on a green, the hole finishes with these additional strokes. A directly holed shot adds none. Rules are fixed for an attempt; restart the hole to apply changes.",15,AppStyle.MUTED)
	explanation.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;explanation.custom_minimum_size.x=650;rules.add_child(explanation)
	_integer(rules,"Automatic strokes on green","green_putts",0,3)
	_integer(rules,"Water penalty · stroke and distance","water_penalty",0,3)
	_integer(rules,"Out-of-bounds penalty · stroke and distance","oob_penalty",0,3)
	_integer(rules,"Maximum gross strokes per hole","max_strokes",3,30)
	rules.add_child(AppStyle.label("Gross scoring is independent of the hole geometry and ready for future handicap/net-scoring policies.",13,AppStyle.MUTED))
	tabs.current_tab=clampi(initial_tab,0,1)
	column.add_child(AppStyle.divider())
	close_button=AppStyle.button("Back to the fresh air    ↗",true)
	close_button.pressed.connect(func():closed.emit())
	column.add_child(close_button)
	close_button.grab_focus()


func _row(parent: VBoxContainer, title: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.custom_minimum_size.y=30
	parent.add_child(row)
	var label := AppStyle.label(title,13)
	label.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	row.add_child(label)
	return row


func _integer(parent:VBoxContainer,title:String,key:String,minimum:int,maximum:int)->void:
	var row:=_row(parent,title)
	var spin:=SpinBox.new();spin.min_value=minimum;spin.max_value=maximum;spin.step=1
	spin.value=int(GameSettings.get_value(key));spin.custom_minimum_size=Vector2(130,36)
	spin.value_changed.connect(func(value:float):GameSettings.set_value(key,int(value)))
	row.add_child(spin);controls[key]=spin


func _toggle(parent: VBoxContainer, title: String, key: String) -> void:
	var row := _row(parent,title)
	var toggle := CheckButton.new()
	toggle.button_pressed=bool(GameSettings.get_value(key))
	toggle.toggled.connect(func(value: bool):GameSettings.set_value(key,value))
	row.add_child(toggle)
	controls[key]=toggle


func _choice(parent: VBoxContainer, title: String, key: String, choices: Array) -> void:
	parent.add_child(AppStyle.label(title,13))
	var option := OptionButton.new()
	option.custom_minimum_size.y=38
	for choice in choices:
		option.add_item(choice)
	option.selected=choices.find(GameSettings.get_value(key))
	option.add_theme_stylebox_override("normal",AppStyle.box(Color("263d30"),7,Color("ffffff20"),10))
	option.add_theme_stylebox_override("hover",AppStyle.box(Color("304c3c"),7,AppStyle.GOLD,10))
	option.add_theme_color_override("font_color",AppStyle.CREAM)
	option.item_selected.connect(func(index: int):GameSettings.set_value(key,choices[index]))
	parent.add_child(option)
	controls[key]=option


func _volume(parent: VBoxContainer, title: String, key: String) -> void:
	var row := _row(parent,title)
	var value := AppStyle.label("%d%%" % (float(GameSettings.get_value(key))*100),12,AppStyle.GOLD)
	row.add_child(value)
	var slider := HSlider.new()
	slider.min_value=0
	slider.max_value=1
	slider.step=.01
	slider.value=float(GameSettings.get_value(key))
	slider.custom_minimum_size=Vector2(280,24)
	slider.value_changed.connect(func(volume: float):
		value.text="%d%%" % (volume*100)
		GameSettings.set_value(key,volume)
	)
	parent.add_child(slider)
	controls[key]=slider


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		closed.emit()
		get_viewport().set_input_as_handled()
