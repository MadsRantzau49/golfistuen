class_name RangeHUD
extends CanvasLayer
## In-game overlay: the landscape stays central; practice tools sit at the edge.

signal launch_requested(speed: float, direction: float, elevation: float, spin_rpm: float)
signal reset_requested
signal replay_requested
signal preview_changed(enabled: bool)
signal menu_requested
signal settings_requested

const THUMB := preload("res://assets/slider_thumb.svg")
var root: Control
var speed_slider: HSlider
var direction_slider: HSlider
var elevation_slider: HSlider
var spin_slider: HSlider
var launch_button: Button
var replay_button: Button
var reset_button: Button
var camera_label: Label
var status_label: Label
var distance_label: Label
var carry_label: Label
var apex_label: Label
var time_label: Label
var history_box: VBoxContainer
var toast_label: Label
var unit_labels: Array[Label]=[]
var preset_buttons: Dictionary={}
var is_busy := false
var toast_seconds := 0.0
var shot_count := 0
var history: Array[Dictionary]=[]
var last_model: BallFlight
var context_label := "ALPINE RANGE"


func _ready() -> void:
	root=Control.new()
	add_child(root)
	AppStyle.full_rect(root)
	root.mouse_filter=Control.MOUSE_FILTER_IGNORE
	root.theme=AppStyle.theme()
	_header()
	_studio()
	_metrics()
	select_preset("Driver")


func _process(delta: float) -> void:
	if toast_seconds > 0:
		toast_seconds-=delta
		toast_label.modulate.a=clampf(toast_seconds,0,1)


func _header() -> void:
	var brand:=VBoxContainer.new()
	root.add_child(brand)
	brand.position=Vector2(42,30)
	brand.add_child(AppStyle.label("Pinewater",30,AppStyle.CREAM,true))
	brand.add_child(AppStyle.label(context_label+"   /   BRITISH COLUMBIA",9,AppStyle.GOLD))
	var buttons:=HBoxContainer.new()
	root.add_child(buttons)
	buttons.anchor_left=1
	buttons.anchor_right=1
	buttons.offset_left=-300
	buttons.offset_right=-36
	buttons.offset_top=30
	buttons.add_theme_constant_override("separation",10)
	var settings:=AppStyle.button("Settings")
	settings.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	settings.pressed.connect(func():settings_requested.emit())
	buttons.add_child(settings)
	var menu:=AppStyle.button("Pause   ≡")
	menu.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	menu.pressed.connect(func():menu_requested.emit())
	buttons.add_child(menu)
	toast_label=AppStyle.label("",17)
	root.add_child(toast_label)
	toast_label.anchor_top=1
	toast_label.anchor_bottom=1
	toast_label.offset_left=44
	toast_label.offset_top=-184
	toast_label.add_theme_color_override("font_shadow_color",Color("0b2317"))
	toast_label.add_theme_constant_override("shadow_offset_y",2)
	toast_label.modulate.a=0


func _studio() -> void:
	var panel:=AppStyle.panel(root,-328,190,-36,0)
	panel.anchor_left=1
	panel.anchor_right=1
	var column:=VBoxContainer.new()
	column.add_theme_constant_override("separation",8)
	panel.add_child(column)
	var heading:=HBoxContainer.new()
	column.add_child(heading)
	var label:=AppStyle.label("PRACTICE, AT YOUR OWN PACE",9,AppStyle.GOLD)
	label.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	heading.add_child(label)
	heading.add_child(AppStyle.label("↗",17,AppStyle.GOLD))
	column.add_child(AppStyle.label("The next shot",26,AppStyle.CREAM,true))
	var presets:=HBoxContainer.new()
	presets.add_theme_constant_override("separation",6)
	column.add_child(presets)
	for preset_name in DemoShotSource.PRESETS:
		var button:=AppStyle.button(preset_name)
		button.custom_minimum_size.y=36
		button.size_flags_horizontal=Control.SIZE_EXPAND_FILL
		button.add_theme_font_size_override("font_size",12)
		button.pressed.connect(select_preset.bind(preset_name))
		preset_buttons[preset_name]=button
		presets.add_child(button)
	speed_slider=_slider(column,"Ball speed",5,85,.5,"m/s")
	direction_slider=_slider(column,"Direction",-25,25,.5,"direction")
	elevation_slider=_slider(column,"Elevation",0,65,.5,"angle")
	spin_slider=_slider(column,"Side spin",-4000,4000,50,"spin")
	spin_slider.tooltip_text="Vertical-axis side spin only. Negative bends left; positive bends right."
	launch_button=AppStyle.button("Launch shot     ↗",true)
	launch_button.custom_minimum_size.y=48
	launch_button.pressed.connect(request_launch)
	column.add_child(launch_button)
	var shortcut:=AppStyle.label("SPACE TO LAUNCH  ·  SIMULATED INPUT",9,AppStyle.MUTED)
	shortcut.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(shortcut)
	var actions:=HBoxContainer.new()
	actions.add_theme_constant_override("separation",8)
	column.add_child(actions)
	replay_button=AppStyle.button("↺  Replay")
	replay_button.custom_minimum_size.y=36
	replay_button.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	replay_button.disabled=true
	replay_button.pressed.connect(func():replay_requested.emit())
	actions.add_child(replay_button)
	reset_button=AppStyle.button("Reset tee")
	reset_button.custom_minimum_size.y=36
	reset_button.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	reset_button.pressed.connect(func():reset_requested.emit())
	actions.add_child(reset_button)
	var guide:=CheckButton.new()
	guide.text="Flight guide"
	guide.add_theme_color_override("font_color",AppStyle.MUTED)
	guide.add_theme_font_size_override("font_size",12)
	guide.toggled.connect(func(enabled:bool):preview_changed.emit(enabled))
	column.add_child(guide)
	column.add_child(AppStyle.divider())
	history_box=VBoxContainer.new()
	history_box.custom_minimum_size.y=54
	history_box.add_theme_constant_override("separation",4)
	column.add_child(history_box)
	_update_history()


func _slider(parent: VBoxContainer,title: String,minimum:float,maximum:float,step:float,unit:String)->HSlider:
	var column:=VBoxContainer.new()
	column.add_theme_constant_override("separation",1)
	parent.add_child(column)
	var row:=HBoxContainer.new()
	column.add_child(row)
	var label:=AppStyle.label(title,12,AppStyle.MUTED)
	label.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var value:=AppStyle.label("",13)
	row.add_child(value)
	var slider:=HSlider.new()
	slider.min_value=minimum
	slider.max_value=maximum
	slider.step=step
	slider.custom_minimum_size.y=23
	slider.mouse_default_cursor_shape=Control.CURSOR_POINTING_HAND
	var track:=AppStyle.box(Color("42604b"),3,Color.TRANSPARENT,0)
	track.content_margin_top=2
	track.content_margin_bottom=2
	slider.add_theme_stylebox_override("slider",track)
	var fill:=track.duplicate() as StyleBoxFlat
	fill.bg_color=AppStyle.GOLD
	slider.add_theme_stylebox_override("grabber_area",fill)
	slider.add_theme_stylebox_override("grabber_area_highlight",fill)
	for state in ["grabber","grabber_highlight","grabber_disabled"]:
		slider.add_theme_icon_override(state,THUMB)
	slider.value_changed.connect(func(number:float):
		if unit=="direction":
			value.text="Straight" if is_zero_approx(number) else "%.1f° %s"%[abs(number),"R" if number>0 else "L"]
		elif unit=="angle":value.text="%.1f°"%number
		elif unit=="spin":value.text="0 rpm · straight" if is_zero_approx(number) else "%d rpm %s"%[absi(int(number)),"R" if number>0 else "L"]
		else:value.text="%.1f m/s"%number
	)
	column.add_child(slider)
	return slider


func _metrics()->void:
	var panel:=AppStyle.panel(root,36,-132,-354,-38)
	panel.anchor_top=1
	panel.anchor_bottom=1
	panel.anchor_right=1
	var row:=HBoxContainer.new()
	row.add_theme_constant_override("separation",20)
	panel.add_child(row)
	var status:=VBoxContainer.new()
	status.custom_minimum_size.x=145
	status.alignment=BoxContainer.ALIGNMENT_CENTER
	row.add_child(status)
	status.add_child(AppStyle.label("YOUR MOMENT",9,AppStyle.GOLD))
	status_label=AppStyle.label("●  Ready to play",14)
	status.add_child(status_label)
	distance_label=_metric(row,"TOTAL","0",true)
	carry_label=_metric(row,"CARRY","—",true)
	apex_label=_metric(row,"APEX","—",true)
	time_label=_metric(row,"TIME","—",false)
	var controls:=PanelContainer.new()
	controls.add_theme_stylebox_override("panel",AppStyle.box())
	root.add_child(controls)
	controls.anchor_left=1
	controls.anchor_right=1
	controls.anchor_top=1
	controls.anchor_bottom=1
	controls.offset_left=-328
	controls.offset_right=-36
	controls.offset_top=-111
	controls.offset_bottom=-61
	camera_label=AppStyle.label("FOLLOW BALL  ·  TARGET-LINE VIEW",11,AppStyle.GOLD)
	camera_label.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	camera_label.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	controls.add_child(camera_label)
	var hint:=AppStyle.label("SPACE  LAUNCH       1 / 2 / 3  CLUBS       ESC  PAUSE",9,Color("e9e8d9ad"))
	root.add_child(hint)
	hint.anchor_top=1
	hint.anchor_bottom=1
	hint.offset_left=45
	hint.offset_top=-25


func _metric(parent:HBoxContainer,title:String,initial:String,distance:bool)->Label:
	var column:=VBoxContainer.new()
	column.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	column.alignment=BoxContainer.ALIGNMENT_CENTER
	parent.add_child(column)
	column.add_child(AppStyle.label(title,9,AppStyle.GOLD))
	var row:=HBoxContainer.new()
	column.add_child(row)
	var value:=AppStyle.label(initial,31,AppStyle.CREAM,true)
	row.add_child(value)
	var suffix:=AppStyle.label(GameSettings.distance_suffix() if distance else "s",12,AppStyle.MUTED)
	suffix.vertical_alignment=VERTICAL_ALIGNMENT_CENTER
	row.add_child(suffix)
	if distance:unit_labels.append(suffix)
	return value


func select_preset(preset_name:String)->void:
	var preset:Dictionary=DemoShotSource.PRESETS[preset_name]
	speed_slider.value=preset.speed_mps
	direction_slider.value=preset.direction_deg
	elevation_slider.value=preset.elevation_deg
	spin_slider.value=preset.spin_rpm
	for slider in [speed_slider,direction_slider,elevation_slider,spin_slider]:slider.value_changed.emit(slider.value)
	for key in preset_buttons:
		preset_buttons[key].add_theme_stylebox_override("normal",AppStyle.box(Color("4a5a3c") if key==preset_name else Color("19352b"),8,AppStyle.GOLD if key==preset_name else Color("ffffff16"),10))


func request_launch()->void:
	if not is_busy:launch_requested.emit(speed_slider.value,direction_slider.value,elevation_slider.value,spin_slider.value)


func set_busy(busy:bool)->void:
	is_busy=busy
	launch_button.disabled=busy
	launch_button.text="A little flight time…" if busy else "Launch shot     ↗"
	replay_button.disabled=busy or shot_count==0
	status_label.text="●  Ball in flight" if busy else "●  Ready to play"


func update_flight(model:BallFlight)->void:
	last_model=model
	distance_label.text="%.0f"%GameSettings.distance(model.distance_m())
	carry_label.text="%.0f"%GameSettings.distance(model.carry_m) if model.has_landed else "—"
	apex_label.text="%.1f"%GameSettings.distance(model.apex_m)
	time_label.text="%.1f"%model.elapsed
	status_label.text={"FLIGHT":"●  Ball in flight","BOUNCE":"●  Nice landing","ROLLING":"●  Rolling out","REST":"●  Shot complete","HOLED":"●  Into the cup"}.get(model.phase,"●  Ready to play")


func record_result(model:BallFlight,is_replay:bool)->void:
	if not is_replay:
		shot_count+=1
		history.push_front({"number":shot_count,"carry":model.carry_m,"total":model.distance_m()})
		if history.size()>3:history.pop_back()
	_update_history()
	replay_button.disabled=false
	show_message("%.0f %s carry. There’s always one more good shot."%[GameSettings.distance(model.carry_m),GameSettings.distance_suffix()])


func _update_history()->void:
	for child in history_box.get_children():
		history_box.remove_child(child)
		child.queue_free()
	if history.is_empty():history_box.add_child(AppStyle.label("A fresh ball. A fresh start.",12,AppStyle.MUTED))
	for result in history:
		var row:=HBoxContainer.new()
		history_box.add_child(row)
		var number:=AppStyle.label("%02d"%result.number,11,AppStyle.GOLD)
		number.size_flags_horizontal=Control.SIZE_EXPAND_FILL
		row.add_child(number)
		row.add_child(AppStyle.label("%.0f carry  /  %.0f %s"%[GameSettings.distance(result.carry),GameSettings.distance(result.total),GameSettings.distance_suffix()],11,AppStyle.MUTED))


func refresh_units()->void:
	for label in unit_labels:label.text=GameSettings.distance_suffix()
	if last_model:update_flight(last_model)
	if history_box:_update_history()


func show_message(message:String)->void:
	toast_label.text=message
	toast_seconds=4
	toast_label.modulate.a=1


func reset_metrics()->void:
	last_model=null
	distance_label.text="0"
	carry_label.text="—"
	apex_label.text="—"
	time_label.text="—"
	status_label.text="●  Ready to play"
