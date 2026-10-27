class_name ShotSource
extends Node
## Input boundary. Future WebSocket and recording adapters emit this same signal.

signal shot_received(shot: GolfShot)
signal input_rejected(reason: String)


func submit_payload(payload: Dictionary) -> bool:
	var shot := GolfShot.from_payload(payload)
	shot_received.emit(shot)
	return true
