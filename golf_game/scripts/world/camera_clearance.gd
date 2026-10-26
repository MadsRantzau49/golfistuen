class_name CameraClearance
extends RefCounted
## Spatially indexed camera-only occluders, including MultiMesh vegetation.
## Explicit proxies keep camera planning independent of ball physics and rendering.

const CELL_SIZE := 32.0
var boxes: Array[AABB] = []
var fadeable := PackedByteArray()
var cells: Dictionary = {}
var surface_height := Callable()


func add_box(box: AABB, foliage := false) -> void:
	var index := boxes.size()
	boxes.append(box)
	fadeable.append(1 if foliage else 0)
	var first := _cell(box.position)
	var last := _cell(box.end)
	for x in range(first.x, last.x + 1):
		for z in range(first.y, last.y + 1):
			var key := Vector2i(x, z)
			if not cells.has(key): cells[key] = []
			cells[key].append(index)


func _cell(point: Vector3) -> Vector2i:
	return Vector2i(floori(point.x / CELL_SIZE), floori(point.z / CELL_SIZE))


func ground(point: Vector3) -> float:
	return float(surface_height.call(point)) if surface_height.is_valid() else 0.0


func clear_segment(start: Vector3, finish: Vector3, padding := .4, skip_subject := true) -> bool:
	var end := finish
	var length := start.distance_to(end)
	if skip_subject and length > .8:
		end = finish.move_toward(start, .65)
	var low := _cell(start.min(end) - Vector3.ONE * padding)
	var high := _cell(start.max(end) + Vector3.ONE * padding)
	var visited: Dictionary = {}
	for x in range(low.x, high.x + 1):
		for z in range(low.y, high.y + 1):
			for index in cells.get(Vector2i(x, z), []):
				if visited.has(index): continue
				visited[index] = true
				if boxes[index].grow(padding).intersects_segment(start, end) != null:
					# Canopies use the matching lens-to-ball shader cutaway. Treating
					# their coarse volumes as walls caused huge camera jumps in dense
					# forest. Trunks, rocks and furnished props remain hard occluders.
					if fadeable[index]: continue
					return false
	if surface_height.is_valid():
		var samples := clampi(ceili(length / 2.0), 3, 96)
		for index in range(samples + 1):
			var t := float(index) / samples
			var point := start.lerp(end, t)
			var clearance := lerpf(padding, .035, t)
			if point.y < ground(point) + clearance:
				return false
	return true


func safe_pose(preferred: Vector3, subject: Vector3, previous: Vector3) -> Vector3:
	var start := preferred
	start.y = maxf(start.y, ground(start) + 1.0)
	if clear_segment(start, subject, .65): return start
	var offset := start - subject
	var best := Vector3(subject.x, maxf(subject.y + 24.0, ground(subject) + 24.0), subject.z + 2.0)
	var best_cost := INF
	# Orbit before climbing. Keeping a rolling camera below the boughs usually
	# provides a nicer view than suddenly lifting it above an entire tree.
	for yaw in [0.0, -.35, .35, -.7, .7, -1.2, 1.2, -1.8, 1.8, PI]:
		for lift in [0.0, 1.3 - offset.y, 2.5, 7.0, 16.0]:
			var candidate: Vector3 = subject + offset.rotated(Vector3.UP, yaw) + Vector3.UP * lift
			candidate.y = maxf(candidate.y, ground(candidate) + 1.0)
			if not clear_segment(candidate, subject, .65): continue
			var cost := candidate.distance_squared_to(start) + candidate.distance_squared_to(previous) * .25
			if cost < best_cost:
				best = candidate
				best_cost = cost
	return best
