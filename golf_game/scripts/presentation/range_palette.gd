class_name RangePalette
extends RefCounted
## Shared art direction. World and interface colors live together intentionally.

const INK := Color("173e36")
const MUTED := Color("738077")
const PAPER := Color("f5f3e9")
const LIME := Color("dbedab")
const FAIRWAY := Color("4b733e")
const FAIRWAY_ALT := Color("527b44")
const ROUGH := Color("365e43")
const PINE := Color("163b31")
const PINE_LIGHT := Color("2b503b")
const WATER := Color("76aaa9")


static func material(color: Color, unshaded := false) -> StandardMaterial3D:
	var result := StandardMaterial3D.new()
	result.albedo_color = color
	result.roughness = 0.95
	if unshaded:
		result.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return result
