class_name GolfShot
extends RefCounted
## The complete game-facing radar contract. Angles are relative to the target line.
## Positive direction is right; positive elevation is up. All distances are metres.
## spin_rpm is signed vertical-axis SIDE spin: negative left, positive right.

const MAX_SIDE_SPIN_RPM := 12000.0

var shot_id: String
var speed_mps: float
var direction_deg: float
var elevation_deg: float
var spin_rpm := 0.0


static func from_payload(payload: Dictionary) -> GolfShot:
	if not payload.get("shot_id") is String or payload.shot_id.is_empty():
		return null
	for key in ["speed_mps", "direction_deg", "elevation_deg"]:
		var value: Variant = payload.get(key)
		if not (value is float or value is int) or not is_finite(float(value)):
			return null
	if not (payload.speed_mps >= 0.5 and payload.speed_mps <= 100.0):
		return null
	if abs(payload.direction_deg) > 85.0 or payload.elevation_deg < 0.0 or payload.elevation_deg > 85.0:
		return null
	var spin: Variant = payload.get("spin_rpm", 0.0)
	if not (spin is float or spin is int) or not is_finite(float(spin)):
		return null
	if absf(float(spin)) > MAX_SIDE_SPIN_RPM:
		return null
	var shot := GolfShot.new()
	shot.shot_id = payload.shot_id
	shot.speed_mps = float(payload.speed_mps)
	shot.direction_deg = float(payload.direction_deg)
	shot.elevation_deg = float(payload.elevation_deg)
	shot.spin_rpm = float(spin)
	return shot


func velocity() -> Vector3:
	var azimuth := deg_to_rad(direction_deg)
	var elevation := deg_to_rad(elevation_deg)
	var horizontal := speed_mps * cos(elevation)
	return Vector3(horizontal * sin(azimuth), speed_mps * sin(elevation), -horizontal * cos(azimuth))


func to_payload() -> Dictionary:
	return {"shot_id": shot_id, "speed_mps": speed_mps,
		"direction_deg": direction_deg, "elevation_deg": elevation_deg, "spin_rpm": spin_rpm}
