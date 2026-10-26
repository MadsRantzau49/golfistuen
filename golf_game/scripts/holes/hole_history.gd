class_name HoleHistory
extends RefCounted
## One undo entry per completed stroke, not per mouse-motion event.
const LIMIT := 30
var undo_states: Array[Dictionary]=[]
var redo_states: Array[Dictionary]=[]
var pending: Dictionary={}


func begin(hole: HoleDefinition)->void:
	if pending.is_empty(): pending=hole.snapshot()


func commit(modified: bool)->void:
	if modified and not pending.is_empty():
		undo_states.append(pending)
		if undo_states.size()>LIMIT: undo_states.pop_front()
		redo_states.clear()
	pending={}


func undo(hole: HoleDefinition)->bool:
	if undo_states.is_empty(): return false
	redo_states.append(hole.snapshot())
	hole.restore(undo_states.pop_back())
	return true


func redo(hole: HoleDefinition)->bool:
	if redo_states.is_empty(): return false
	undo_states.append(hole.snapshot())
	hole.restore(redo_states.pop_back())
	return true


func clear()->void:
	undo_states.clear(); redo_states.clear(); pending={}
