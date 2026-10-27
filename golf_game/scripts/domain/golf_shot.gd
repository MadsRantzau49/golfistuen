class_name GolfShot
extends RefCounted
## Backend-owned launch data. The frontend does not validate physical ranges.
## Angles are relative to the target line.
## Positive direction is right; positive elevation is up. All distances are metres.
## spin_rpm is signed vertical-axis SIDE spin: negative left, positive right.

var shot_id: String
var speed_mps: float
var direction_deg: float
var elevation_deg: float
var spin_rpm := 0.0


static func from_payload(payload: Dictionary) -> GolfShot:
	var shot := GolfShot.new()
	var id: Variant = payload.get("shot_id", payload.get("id"))
	shot.shot_id = str(id) if id != null else ""
	if shot.shot_id.is_empty(): shot.shot_id = "local-%d-%x" % [Time.get_ticks_usec(), randi()]
	shot.speed_mps = _value(payload, ["speed_mps", "speed", "velocity"])
	shot.direction_deg = _value(payload, ["direction_deg", "direction"])
	shot.elevation_deg = _value(payload, ["elevation_deg", "elevation", "elavation"])
	shot.spin_rpm = _value(payload, ["spin_rpm", "spin"])
	return shot


static func _value(payload: Dictionary, names: Array) -> float:
	for name in names:
		if payload.has(name) and payload[name] != null:
			return float(payload[name])
	return 0.0


func velocity() -> Vector3:
	var azimuth := deg_to_rad(direction_deg)
	var elevation := deg_to_rad(elevation_deg)
	var horizontal := speed_mps * cos(elevation)
	return Vector3(horizontal * sin(azimuth), speed_mps * sin(elevation), -horizontal * cos(azimuth))


func to_payload() -> Dictionary:
	return {"shot_id": shot_id, "speed_mps": speed_mps,
		"direction_deg": direction_deg, "elevation_deg": elevation_deg, "spin_rpm": spin_rpm}
