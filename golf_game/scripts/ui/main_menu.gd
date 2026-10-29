class_name PinewaterMenu
extends Control

signal play_requested
signal settings_requested
signal quit_requested
signal builder_requested
signal holes_requested
signal match_requested
signal resume_requested
signal radar_debug_requested

var play_button: Button
var resume_button:Button


func _ready() -> void:
	AppStyle.full_rect(self)
	theme=AppStyle.theme()
	var gradient := ColorRect.new()
	add_child(gradient)
	AppStyle.full_rect(gradient)
	var material := ShaderMaterial.new()
	material.shader=preload("res://shaders/menu_gradient.gdshader")
	gradient.material=material
	gradient.mouse_filter=Control.MOUSE_FILTER_IGNORE
	var brand := VBoxContainer.new()
	add_child(brand)
	brand.position=Vector2(66,48)
	brand.add_child(AppStyle.label("Pinewater",33,AppStyle.CREAM,true))
	brand.add_child(AppStyle.label("A  G O L F I S T U E N  E S C A P E",10,AppStyle.GOLD))
	var content := VBoxContainer.new()
	add_child(content)
	content.position=Vector2(68,238)
	content.add_theme_constant_override("separation",22)
	content.add_child(AppStyle.label("LEAVE THE EVERYDAY BEHIND",11,AppStyle.GOLD))
	var title := AppStyle.label("Out here,\nthere’s only\nthe next shot.",72,AppStyle.CREAM,true)
	title.add_theme_constant_override("line_spacing",-10)
	content.add_child(title)
	content.add_child(AppStyle.label("A mountain escape. A quieter kind of golf.",17,Color("d7decc")))
	play_button=AppStyle.button("Enter the range     ↗",true)
	play_button.custom_minimum_size=Vector2(300,58)
	play_button.size_flags_horizontal=Control.SIZE_SHRINK_BEGIN
	play_button.add_theme_font_size_override("font_size",18)
	play_button.pressed.connect(func():play_requested.emit())
	content.add_child(play_button)
	var footer := HBoxContainer.new()
	add_child(footer)
	footer.anchor_top=1.0
	footer.anchor_bottom=1.0
	footer.offset_left=68
	footer.offset_top=-91
	footer.offset_bottom=-42
	footer.add_theme_constant_override("separation",12)
	var settings := AppStyle.button("Settings")
	settings.custom_minimum_size.x=135
	settings.pressed.connect(func():settings_requested.emit())
	footer.add_child(settings)
	var quit_button := AppStyle.button("Quit")
	quit_button.custom_minimum_size.x=100
	quit_button.pressed.connect(func():quit_requested.emit())
	footer.add_child(quit_button)
	_build_modes()
	var version := AppStyle.label("PINEWATER   /   0.2.0",10,Color("e1e6d5a0"))
	add_child(version)
	version.anchor_left=1
	version.anchor_right=1
	version.anchor_top=1
	version.anchor_bottom=1
	version.offset_left=-260
	version.offset_top=-43
	play_button.grab_focus()


func _build_modes() -> void:
	var panel := AppStyle.panel(self,-414,-600,-54,-90)
	panel.anchor_left=1
	panel.anchor_right=1
	panel.anchor_top=1
	panel.anchor_bottom=1
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation",13)
	panel.add_child(column)
	column.add_child(AppStyle.label("Y O U R  N E X T  E S C A P E",10,AppStyle.GOLD))
	column.add_child(AppStyle.label("The Alpine Collection",23,AppStyle.CREAM,true))
	var local:=AppStyle.button("01    Play local golf · 1–6 players    ↗",true)
	local.pressed.connect(func():match_requested.emit());column.add_child(local)
	resume_button=AppStyle.button("Resume saved round    ↗")
	resume_button.pressed.connect(func():resume_requested.emit());column.add_child(resume_button)
	var mode := AppStyle.button("02    Driving range                         ↗")
	mode.pressed.connect(func():play_requested.emit())
	column.add_child(mode)
	var holes:=AppStyle.button("03    My holes                               ↗")
	holes.pressed.connect(func():holes_requested.emit());column.add_child(holes)
	var builder:=AppStyle.button("04    Hole builder                          ↗")
	builder.pressed.connect(func():builder_requested.emit());column.add_child(builder)
	var radar:=AppStyle.button("05    Radar debug range · 3D capture    ↗")
	radar.pressed.connect(func():radar_debug_requested.emit());column.add_child(radar)
	column.add_child(AppStyle.divider())
	column.add_child(AppStyle.label("Pinewater · British Columbia\nBuild your own escape. No putting required.",13,Color("d1d9c6")))
