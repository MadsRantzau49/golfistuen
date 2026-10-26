class_name DemoShotSource
extends ShotSource
## A backend-free event producer. Uses the exact contract a real radar will use.

const PRESETS := {
	"Driver": {"speed_mps": 58.0, "direction_deg": 0.0, "elevation_deg": 19.0, "spin_rpm": 0.0},
	"7 Iron": {"speed_mps": 42.0, "direction_deg": -2.0, "elevation_deg": 30.0, "spin_rpm": 0.0},
	"Wedge": {"speed_mps": 26.0, "direction_deg": 2.5, "elevation_deg": 48.0, "spin_rpm": 0.0},
}
var sequence := 0


func fire(speed_mps: float, direction_deg: float, elevation_deg: float, spin_rpm := 0.0) -> void:
	sequence += 1
	submit_payload({"shot_id": "demo-%d-%d" % [Time.get_ticks_msec(), sequence],
		"speed_mps": speed_mps, "direction_deg": direction_deg, "elevation_deg": elevation_deg, "spin_rpm": spin_rpm})
