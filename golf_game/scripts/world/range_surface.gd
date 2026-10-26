class_name RangeSurface
extends RefCounted
## One surface contract for physics, visual contact, close turf and camera clearance.
## Coordinates exposed to the flight model are relative to the launch origin.

const LAUNCH_ORIGIN := Vector3(0.0, .12, 8.0)
const FAIRWAY_CANOPY := .018
const ROUGH_CANOPY := .065
const MAT_CANOPY := .005
var landscape: AlpineLandscape


func _init(terrain: AlpineLandscape) -> void:
	landscape = terrain


func is_mat(point: Vector3) -> bool:
	return absf(point.x) <= 2.25 and absf(point.z - 8.0) <= 1.6


func is_deck(point: Vector3) -> bool:
	return absf(point.x) <= 6.0 and point.z >= 6.5 and point.z <= 17.5


func is_fairway(point: Vector3) -> bool:
	var center := sin(point.z * .012) * 2.5
	var width := 27.0 + sin(point.z * .009) * 3.0
	return absf(point.x - center) <= width and point.z < 19.0 and point.z > -355.0


func is_target(point: Vector3) -> bool:
	for distance in [50, 100, 150, 200, 250, 300]:
		if Vector2(point.x, point.z - (8.0 - distance)).length_squared() < 6.8 * 6.8:
			return true
	return false


func has_grass(point: Vector3) -> bool:
	return (not is_deck(point) or is_mat(point)) and landscape.rendered_height(point.x, point.z) >= -.6


func canopy_height(point: Vector3) -> float:
	if is_mat(point): return MAT_CANOPY
	if is_deck(point): return 0.0
	return FAIRWAY_CANOPY if is_fairway(point) or is_target(point) else ROUGH_CANOPY


func base_height(point: Vector3) -> float:
	var height := landscape.rendered_height(point.x, point.z)
	if is_mat(point): return maxf(height, .115)
	if is_deck(point): return maxf(height, .0365)
	if is_target(point): return maxf(height, .0525)
	return height


func world_height(point: Vector3) -> float:
	return base_height(point) + canopy_height(point)


func local_height(point: Vector3) -> float:
	return world_height(point + LAUNCH_ORIGIN) - LAUNCH_ORIGIN.y


func resistance(point: Vector3) -> float:
	return 1.9 if is_fairway(point + LAUNCH_ORIGIN) else 4.2
