class_name RangeLoadingScreen
extends Control

var progress: ProgressBar
var message: Label
var percentage: Label


func _ready() -> void:
	AppStyle.full_rect(self)
	theme=AppStyle.theme()
	AppStyle.shade(self,1.0)
	var center := CenterContainer.new()
	add_child(center)
	AppStyle.full_rect(center)
	var column := VBoxContainer.new()
	column.custom_minimum_size.x=400
	column.add_theme_constant_override("separation",20)
	center.add_child(column)
	var logo := TextureRect.new()
	logo.texture=preload("res://assets/icon.svg")
	logo.custom_minimum_size=Vector2(64,64)
	logo.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	column.add_child(logo)
	var brand := AppStyle.label("P I N E W A T E R",12,AppStyle.GOLD)
	brand.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(brand)
	var title := AppStyle.label("A little closer\nto somewhere else.",42,AppStyle.CREAM,true)
	title.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)
	progress=ProgressBar.new()
	progress.custom_minimum_size=Vector2(380,3)
	progress.show_percentage=false
	progress.add_theme_stylebox_override("background",AppStyle.box(Color("243a2f"),2,Color.TRANSPARENT,0))
	progress.add_theme_stylebox_override("fill",AppStyle.box(AppStyle.GOLD,2,Color.TRANSPARENT,0))
	column.add_child(progress)
	message=AppStyle.label("Opening your escape",14,AppStyle.MUTED)
	message.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(message)
	percentage=AppStyle.label("0%",11,AppStyle.GOLD)
	percentage.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(percentage)


func update_progress(value: float, text: String) -> void:
	progress.value=clampf(value,0,1)*100
	percentage.text="%d%%" % progress.value
	message.text=text
