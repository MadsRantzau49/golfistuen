class_name ShotRegressionPanel
extends PanelContainer
## Guided remote regression workflow: the radar computer owns recordings and jobs.
signal open_capture_requested(session_id: String, capture_id: String)
var client: ShotNotesClient
var _busy:=false
var _last_job:=""
var _started:=0
var _profile:Dictionary={"schema_version":1,"where":{},"criteria":{}}
var _inventory:Dictionary={}
var _filters:Dictionary={}
var _range_inputs:Array[Dictionary]=[]
var _tolerance_inputs:Array[Dictionary]=[]
var _cases:Array=[]
var _current_report:Dictionary={}
var _baseline_id:=""
var _loading_baseline:=false
var _criteria_ready:=false
var _waiting_for_notes:=false
var _status:Label
var _collection:Label
var _filter_grid:GridContainer
var _criteria_box:VBoxContainer
var _criteria_rows:VBoxContainer
var _coverage:Label
var _name:LineEdit
var _saved_profiles:OptionButton
var _baseline:OptionButton
var _results:VBoxContainer
var _summary:Label
var _comparison:Label
var _clusters:Label
var _case_list:ItemList
var _detail:RichTextLabel
var _prepare_button:Button
var _run_button:Button
var _save_button:Button
var _refresh_button:Button
var _more_button:Button
var _more_groups:Button
var _open_button:Button


func _label(parent:Node,text:String,size:=15,color:=AppStyle.CREAM)->Label:
	var label:=AppStyle.label(text,size,color);label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;parent.add_child(label);return label


func _button(parent:Node,text:String,action:Callable,primary:=false)->Button:
	var button:=AppStyle.button(text,primary);button.custom_minimum_size.y=38;parent.add_child(button);button.pressed.connect(action);return button


func _ready()->void:
	add_theme_stylebox_override("panel",AppStyle.box())
	var scroll:=ScrollContainer.new();scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED;add_child(scroll)
	var column:=VBoxContainer.new();column.size_flags_horizontal=Control.SIZE_EXPAND_FILL;column.add_theme_constant_override("separation",12);scroll.add_child(column)
	_label(column,"Test your ball detector",28)
	_label(column,"1 Choose matching recordings → 2 Define what passes → 3 Run and compare. Tests run on your radar computer; no command line is needed.",16,AppStyle.GOLD)
	_status=_label(column,"Connect to the radar service to load your recordings.",15,AppStyle.GOLD)
	_label(column,"1 · Choose recordings",22)
	_collection=_label(column,"",14,AppStyle.MUTED)
	_refresh_button=_button(column,"Refresh recordings and saved tests",open)
	_label(column,"Reuse saved criteria (optional)",14,AppStyle.GOLD)
	_saved_profiles=OptionButton.new();_saved_profiles.fit_to_longest_item=false;_saved_profiles.clip_text=true;_saved_profiles.size_flags_horizontal=Control.SIZE_EXPAND_FILL;column.add_child(_saved_profiles);_saved_profiles.item_selected.connect(_select_profile)
	_filter_grid=GridContainer.new();_filter_grid.columns=2;_filter_grid.size_flags_horizontal=Control.SIZE_EXPAND_FILL;_filter_grid.add_theme_constant_override("h_separation",16);column.add_child(_filter_grid)
	_label(column,"Any includes every value and unrecorded conditions. Actual CFG files are identified automatically. Each condition combination gets its own results.",13,AppStyle.MUTED)
	_prepare_button=_button(column,"Next · Choose pass criteria →",prepare,true)
	_criteria_box=VBoxContainer.new();_criteria_box.add_theme_constant_override("separation",10);column.add_child(_criteria_box);_criteria_box.hide()
	_label(_criteria_box,"2 · Define what passes",22)
	_coverage=_label(_criteria_box,"",15,AppStyle.GOLD)
	_label(_criteria_box,"Enter your accepted minimum/maximum for each abstract label. Exact measurements use an allowed ± difference instead. Nothing is assumed. Left is negative, right is positive.",14,AppStyle.MUTED)
	_criteria_rows=VBoxContainer.new();_criteria_rows.add_theme_constant_override("separation",8);_criteria_box.add_child(_criteria_rows)
	_label(_criteria_box,"Test / criteria name",14,AppStyle.GOLD)
	_name=LineEdit.new();_name.text="Detection check";_name.max_length=120;_criteria_box.add_child(_name)
	_save_button=_button(_criteria_box,"Save these criteria for next time",save_profile)
	_label(_criteria_box,"3 · Run and compare",22)
	_label(_criteria_box,"Compare with a saved result (optional)",14,AppStyle.GOLD)
	_baseline=OptionButton.new();_baseline.fit_to_longest_item=false;_baseline.clip_text=true;_criteria_box.add_child(_baseline);_baseline.item_selected.connect(_select_baseline)
	_label(_criteria_box,"Choosing a previous result restores its conditions and criteria for a fair comparison. Tests use the running radar detector and its tuning. After changing the algorithm, rebuild/restart that service and test again.",13,AppStyle.MUTED)
	_run_button=_button(_criteria_box,"Run tests on matching recordings",run_tests,true)
	_results=VBoxContainer.new();_results.add_theme_constant_override("separation",10);column.add_child(_results);_results.hide()
	_label(_results,"Results",24)
	_summary=_label(_results,"",18)
	_comparison=_label(_results,"",15,AppStyle.GOLD)
	_clusters=_label(_results,"",14,AppStyle.MUTED)
	_more_groups=_button(_results,"Show more condition groups",func():_load_page(true));_more_groups.hide()
	_case_list=ItemList.new();_case_list.custom_minimum_size.y=180;_results.add_child(_case_list);_case_list.item_selected.connect(_select_case)
	_more_button=_button(_results,"Show more shots",func():_load_page(false));_more_button.hide()
	_detail=RichTextLabel.new();_detail.custom_minimum_size.y=180;_detail.selection_enabled=true;_results.add_child(_detail)
	_open_button=_button(_results,"Open this shot in Shot notes",_open_case);_open_button.disabled=true


func setup(value:ShotNotesClient)->void:
	client=value;client.regression_received.connect(_on_message)
	client.connection_changed.connect(func(_text:String):
		if not client.connected:_set_busy(false);_status.text="Disconnected. Reconnect above, then refresh. Saved tests and results stay on the radar computer."
	)


func _send(kind:String,values:Dictionary={})->void:
	if client==null or not client.connected:_status.text="Connect to the radar service above first.";return
	if not client.drafts.is_empty():client.sync_drafts();_status.text="Shot descriptions are still syncing. Wait for them to save, then try again.";return
	_started=Time.get_ticks_msec();_set_busy(true);_status.text="Working on the radar computer…"
	client.regression_request(kind,values)


func open()->void:
	if client!=null and client.connected and not client.drafts.is_empty():
		_waiting_for_notes=true;client.sync_drafts();_status.text="Saving shot descriptions before loading tests…";return
	if client!=null and client.regression_running:
		_started=Time.get_ticks_msec();_set_busy(true);client.regression_request("regression_poll");return
	_send("regression_inventory")


func _set_busy(value:bool)->void:
	_busy=value
	for button in [_refresh_button,_prepare_button,_save_button,_run_button,_more_button,_more_groups]:
		if button:button.disabled=value
	_saved_profiles.disabled=value;_baseline.disabled=value;_name.editable=not value
	for input in _filters.values():input.disabled=value
	for item in _range_inputs:item.low.editable=not value;item.high.editable=not value
	for item in _tolerance_inputs:item.input.editable=not value


func _process(_delta:float)->void:
	if _waiting_for_notes and is_visible_in_tree() and client!=null and client.connected and client.drafts.is_empty():
		_waiting_for_notes=false;open()
	if _busy:_status.text="Working on the radar computer · %.0f s · you can leave this screen and return later."%((Time.get_ticks_msec()-_started)/1000.0)


func _on_message(message:Dictionary)->void:
	if message.get("type")=="regression_error":_set_busy(false);_status.text=str(message.get("message"));return
	if message.get("type")!="regression_status":return
	if message.get("state")=="running":_set_busy(true);return
	if message.get("state")!="complete":_set_busy(false);return
	var job:=str(message.get("job_id",""))
	if job==_last_job:return
	_last_job=job;_set_busy(false)
	var result:Dictionary=message.get("result",{})
	match result.get("type"):
		"regression_error":_status.text=str(result.get("message","Test failed to run. Please try again."))
		"regression_inventory":_load_inventory(result)
		"regression_prepared":_load_requirements(result)
		"regression_profile_saved":
			var saved:Dictionary=result.saved;_inventory.profiles.append(saved);_populate_saved_profiles();_status.text="Criteria saved as ‘%s’."%str(saved.name)
		"regression_result":
			var report:Dictionary=result.report
			_show_report(report)
			if _loading_baseline:
				_loading_baseline=false;_profile=report.profile.duplicate(true);_apply_filters();prepare()
			else:
				_status.text="Results saved on the radar computer. Select a shot below to see what passed or failed."
				if result.has("saved_to"):
					_inventory.reports.push_front({"id":report.id,"name":report.name,"created_at":report.created_at,"summary":report.summary});_populate_baselines()


func _load_inventory(value:Dictionary)->void:
	_inventory=value;_collection.text="%d saved shots across %d recordings."%[int(value.total),int(value.sessions)]
	_criteria_ready=false;_criteria_box.hide()
	for child in _filter_grid.get_children():_filter_grid.remove_child(child);child.queue_free()
	_filters.clear()
	for key in value.facets:
		_label(_filter_grid,"Actual radar CFG" if key=="cfg_sha256" else str(key).capitalize(),14,AppStyle.GOLD)
		var option:=OptionButton.new();option.fit_to_longest_item=false;option.clip_text=true;option.size_flags_horizontal=Control.SIZE_EXPAND_FILL;option.custom_minimum_size.x=220;option.add_item("Any");option.set_item_metadata(0,null)
		for item in value.facets[key]:
			var text:=str(item.get("label",item.value));option.add_item(text+" (%d)"%int(item.count));option.set_item_metadata(option.item_count-1,item.value)
		_filter_grid.add_child(option);_filters[key]=option;option.item_selected.connect(func(_index:int):_criteria_ready=false;_criteria_box.hide())
	_populate_saved_profiles();_populate_baselines();_apply_filters();_status.text="Choose the conditions you want to test, then click Next."
	if int(value.total)==0:_status.text="No saved shots yet. Record and label shots in Shot notes, then refresh here."


func _populate_saved_profiles()->void:
	_saved_profiles.clear();_saved_profiles.add_item("New criteria · choose conditions below");_saved_profiles.set_item_metadata(0,null)
	for item in _inventory.get("profiles",[]):_saved_profiles.add_item(str(item.name));_saved_profiles.set_item_metadata(_saved_profiles.item_count-1,item)


func _populate_baselines()->void:
	_baseline.clear();_baseline.add_item("First run · no comparison");_baseline.set_item_metadata(0,null)
	for item in _inventory.get("reports",[]):
		_baseline.add_item("%s · %s · %d pass / %d fail"%[str(item.name),str(item.created_at).left(19).replace("T"," "),int(item.summary.passed),int(item.summary.failed)])
		_baseline.set_item_metadata(_baseline.item_count-1,item.id)
		if str(item.id)==_baseline_id:_baseline.select(_baseline.item_count-1)


func _apply_filters()->void:
	# Preserve saved filters even if their values no longer occur in the dataset.
	for key in _profile.get("where",{}):
		if not _filters.has(key):
			_label(_filter_grid,str(key).capitalize(),14,AppStyle.GOLD)
			var missing:=OptionButton.new();missing.fit_to_longest_item=false;missing.clip_text=true;missing.size_flags_horizontal=Control.SIZE_EXPAND_FILL;missing.add_item("Any");missing.set_item_metadata(0,null)
			_filter_grid.add_child(missing);_filters[key]=missing
			missing.item_selected.connect(func(_index:int):_criteria_ready=false;_criteria_box.hide())
	for key in _filters:
		var option:OptionButton=_filters[key];option.select(0)
		var desired:Variant=_profile.get("where",{}).get(key)
		var found:=desired==null
		for index in range(1,option.item_count):
			var metadata:Variant=option.get_item_metadata(index)
			if typeof(metadata)==typeof(desired) and metadata==desired:option.select(index);found=true;break
		if not found:
			option.add_item("Saved selection · "+str(desired));option.set_item_metadata(option.item_count-1,desired);option.select(option.item_count-1)


func _select_profile(index:int)->void:
	var saved:Variant=_saved_profiles.get_item_metadata(index)
	_baseline_id="";_baseline.select(0)
	if saved is Dictionary:_profile=saved.profile.duplicate(true);_name.text=str(saved.name)
	else:_profile={"schema_version":1,"where":{},"criteria":{}}
	_apply_filters();prepare()


func prepare()->void:
	var where:Dictionary={}
	for key in _filters:
		var value:Variant=_filters[key].get_selected_metadata()
		if value!=null:where[key]=value
	_profile.where=where
	_send("regression_prepare",{"profile":_profile})


func _entry(parent:Node,placeholder:String,value:Variant=null)->LineEdit:
	var input:=LineEdit.new();input.placeholder_text=placeholder;input.custom_minimum_size.x=120;input.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	if value!=null:input.text=str(value)
	parent.add_child(input);return input


func _load_requirements(value:Dictionary)->void:
	_profile=value.profile;_criteria_box.show();_criteria_ready=true
	for child in _criteria_rows.get_children():_criteria_rows.remove_child(child);child.queue_free()
	_range_inputs.clear();_tolerance_inputs.clear()
	_coverage.text="%d matching shots · %d ready to score · %d incomplete/unknown (will remain unscored)."%[int(value.total),int(value.eligible),int(value.unscored)]
	var criteria:Dictionary=_profile.get("criteria",{})
	for item in value.ranges:
		var unit:="km/h" if item.field=="speed" else "degrees"
		_label(_criteria_rows,"%s · %s · %s (%d shots)"%[str(item.field).capitalize(),str(item.label).capitalize(),unit,int(item.count)],15,AppStyle.GOLD)
		var row:=HBoxContainer.new();_criteria_rows.add_child(row)
		var bounds:Variant=criteria.get("ranges",{}).get(item.field,{}).get(item.label)
		var scale:=3.6 if item.field=="speed" else 1.0
		var low:=_entry(row,"Minimum",float(bounds[0])*scale if bounds is Array else null)
		var high:=_entry(row,"Maximum",float(bounds[1])*scale if bounds is Array else null)
		_range_inputs.append({"field":item.field,"label":item.label,"low":low,"high":high,"original":bounds,"scale":scale,"low_text":low.text,"high_text":high.text})
	for item in value.tolerances:
		_label(_criteria_rows,"Exact %s · allowed ± difference (%d shots)"%[_metric_name(str(item.metric)),int(item.count)],15,AppStyle.GOLD)
		var input:=_entry(_criteria_rows,"Allowed difference",criteria.get("tolerances",{}).get(item.metric))
		_tolerance_inputs.append({"metric":item.metric,"input":input})
		if item.get("supported")!=true:_label(_criteria_rows,"This measurement is saved, but the running detector does not estimate it. It will remain UNSCORED.",13,AppStyle.GOLD)
	if value.ranges.is_empty() and value.tolerances.is_empty():_label(_criteria_rows,"No numeric expectations on these shots. This run will check hit/miss detection only; it will not claim speed or angle accuracy.",14,AppStyle.GOLD)
	_run_button.disabled=int(value.total)==0 or int(value.eligible)==0
	_status.text="Enter pass criteria below. You can save them and reuse them after each detector change."


func _collect_profile()->Dictionary:
	if not _criteria_ready:_status.text="Choose recordings and click Next first.";return {}
	var result:=_profile.duplicate(true)
	var criteria:Dictionary=result.get("criteria",{});criteria["ranges"]=criteria.get("ranges",{});criteria["tolerances"]=criteria.get("tolerances",{})
	for item in _range_inputs:
		if not item.low.text.is_valid_float() or not item.high.text.is_valid_float():_status.text="Enter both numbers for %s / %s."%[item.field,item.label];return {}
		var low:float=item.low.text.to_float();var high:float=item.high.text.to_float()
		if not is_finite(low) or not is_finite(high) or low>high:_status.text="Minimum must be no greater than maximum for %s / %s."%[item.field,item.label];return {}
		var bounds:Array=[low/float(item.scale),high/float(item.scale)]
		if item.original is Array and item.low.text==item.low_text and item.high.text==item.high_text:bounds=item.original
		if not criteria.ranges.has(item.field):criteria.ranges[item.field]={}
		criteria.ranges[item.field][item.label]=bounds
	for item in _tolerance_inputs:
		if not item.input.text.is_valid_float() or not is_finite(item.input.text.to_float()) or item.input.text.to_float()<0:_status.text="Enter a nonnegative allowed difference for "+str(item.metric);return {}
		var original:Variant=criteria.tolerances.get(item.metric)
		var value:float=item.input.text.to_float()
		criteria.tolerances[item.metric]=original if original!=null and item.input.text==str(original) else value
	result.criteria=criteria;return result


func save_profile()->void:
	var profile:=_collect_profile()
	if profile.is_empty():return
	_profile=profile
	_send("regression_profile_save",{"name":_name.text,"profile":profile})


func _select_baseline(index:int)->void:
	var identity:Variant=_baseline.get_item_metadata(index);_baseline_id="" if identity==null else str(identity)
	if _baseline_id.is_empty():return
	_loading_baseline=true;_send("regression_report",{"report_id":_baseline_id})


func run_tests()->void:
	var profile:=_collect_profile()
	if profile.is_empty():return
	_profile=profile;_send("regression_run",{"name":_name.text,"profile":profile,"baseline_id":_baseline_id})


func _percent(value:Variant)->String:return "not available" if value==null else "%.1f%%"%(float(value)*100.0)


func _metric_name(key:String)->String:
	return {"speed_mps":"Speed (m/s)","speed_kph":"Speed (km/h)","direction_deg":"Direction (degrees)","elevation_deg":"Elevation (degrees)","distance_m":"Travel distance (m)"}.get(key,key.capitalize())


func _show_report(report:Dictionary)->void:
	var append_cases:=str(_current_report.get("id",""))==str(report.id) and int(report.get("offset",0))>0
	var append_groups:=str(_current_report.get("id",""))==str(report.id) and int(report.get("group_offset",0))>0
	_current_report=report;_results.show()
	var summary:Dictionary=report.summary
	_summary.text="%s\n%d PASS · %d FAIL · %d UNSCORED\nHits detected: %d / %d · false-positive miss windows: %d / %d · extra balls: %d\nDetection recall: %s · precision: %s · numeric-quality passes: %d · detection-only hits: %d"%[str(report.name),int(summary.passed),int(summary.failed),int(summary.unscored),int(summary.true_positive_hits),int(summary.hits),int(summary.false_positive_misses),int(summary.misses),int(summary.duplicate_balls),_percent(summary.recall),_percent(summary.precision),int(summary.numeric_quality_passes),int(summary.detection_only_cases)]
	for key in summary.metrics:
		var metric:Dictionary=summary.metrics[key]
		_summary.text+="\n%s: %d passed / %d evaluated / %d expected"%[_metric_name(key),int(metric.passed),int(metric.evaluated),int(metric.expected)]
		if metric.exact_mean_absolute_error!=null:_summary.text+=" · mean exact error %.3f"%float(metric.exact_mean_absolute_error)
	_comparison.text="No baseline selected. This saved result can be used as a baseline next time."
	if report.get("comparison_error")!=null:_comparison.text="Comparison unavailable: "+str(report.comparison_error)
	elif report.get("comparison") is Dictionary:
		_comparison.text="Compared with baseline: %d improved · %d regressed · %d changed predictions."%[int(report.comparison.improved_count),int(report.comparison.regressed_count),int(report.comparison.changed_count)]
		for metric in report.comparison.metric_delta:
			var delta:Variant=report.comparison.metric_delta[metric].get("exact_mean_absolute_error")
			if delta!=null:_comparison.text+="\n%s · mean exact error change %+.3f (negative is better)"%[_metric_name(metric),float(delta)]
	var lines:Array[String]=[]
	for group in report.groups:
		var tags:Array[String]=[]
		for key in group.context:
			var value:=str(group.context[key]) if group.context[key]!=null else "not recorded"
			tags.append(str(key)+": "+(value.left(12)+"…" if key=="cfg_sha256" and group.context[key]!=null else value))
		lines.append(" · ".join(tags)+"\n  %d pass / %d fail / %d unscored"%[int(group.summary.passed),int(group.summary.failed),int(group.summary.unscored)])
	if append_groups:_clusters.text+="\n\n"+"\n\n".join(lines)
	else:_clusters.text="CONDITION GROUPS\n"+"\n\n".join(lines)
	if not append_cases:_case_list.clear();_cases.clear();_detail.text="Select a shot for its expected and actual values.";_open_button.disabled=true
	for case in report.cases:
		_cases.append(case)
		_case_list.add_item("%s · %s · %d detected · %s"%[str(case.status).to_upper(),str(case.outcome) if case.outcome!=null else "unknown",int(case.detected_count),str(case.id)])
		_case_list.set_item_custom_fg_color(_case_list.item_count-1,Color("e68b80") if case.status=="fail" else AppStyle.GOLD if case.status=="unscored" else Color("a6e2b8"))
	_more_button.visible=report.get("next_offset")!=null;_more_groups.visible=report.get("next_group_offset")!=null


func _load_page(groups:bool)->void:
	_send("regression_report",{"report_id":_current_report.id,"offset":0 if groups else _current_report.get("next_offset",0),"group_offset":_current_report.get("next_group_offset",0) if groups else 0})


func _select_case(index:int)->void:
	if index<0 or index>=_cases.size():return
	var case:Dictionary=_cases[index];var lines:Array[String]=[str(case.id),"Result: "+str(case.status).to_upper(),"Expected outcome: "+str(case.outcome)+" · detected balls: "+str(case.detected_count)]
	for metric in case.metrics:
		var check:Dictionary=case.metrics[metric]
		var expected:="%.3f ± %.3f"%[float(check.target),float(check.tolerance)] if check.source=="measurement" and check.get("tolerance")!=null else str(check.get("range","criterion missing"))
		lines.append("%s · expected %s · actual %s · %s"%[_metric_name(metric),expected,str(check.get("actual","not available")),"UNSCORED" if check.get("pass")==null else "PASS" if check.get("pass")==true else "FAIL"])
	for problem in case.problems:lines.append(str(problem))
	for metric in case.expected_metrics:
		if not case.metrics.has(metric):lines.append(_metric_name(metric)+" was not evaluated because a single ball was not detected.")
	lines.append("Conditions: "+JSON.stringify(case.context))
	_detail.text="\n".join(lines);_open_button.disabled=false


func _open_case()->void:
	var selected:=_case_list.get_selected_items()
	if selected.is_empty():return
	var parts:=str(_cases[selected[0]].id).split("/",false,1)
	if parts.size()==2:open_capture_requested.emit(parts[0],parts[1])
