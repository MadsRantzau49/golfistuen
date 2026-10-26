class_name AlpineLandscape
extends RefCounted
## Continuous sculpted heightfield. The center is intentionally flat for practice.
## Scenery and playable ground share a single material and smooth shoreline.

var noise := FastNoiseLite.new()
var ridge := FastNoiseLite.new()
const GRID_SIZE := 240
const GRID_STEP := 6.5
const GRID_START := Vector2(-780.0, 170.0)
var sampled_heights := PackedFloat32Array()
var custom_plot := false
const PEAKS := [Vector4(-370, -870, 340, 230), Vector4(-120, -1030, 430, 240),
	Vector4(150, -930, 370, 200), Vector4(400, -1100, 460, 240),
	Vector4(-650, -640, 300, 250), Vector4(620, -590, 290, 260),
	Vector4(-260, -530, 180, 145), Vector4(310, -520, 195, 160)]


func _init() -> void:
	noise.seed = 6843
	noise.frequency = .012
	noise.fractal_octaves = 4
	ridge.seed = 1934
	ridge.frequency = .007
	ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	ridge.fractal_octaves = 3
	ridge.fractal_gain = .35


func height(x: float, z: float) -> float:
	var h := 0.0
	for peak in PEAKS:
		var d := Vector2((x-peak.x)/peak.w, (z-peak.y)/(peak.w*.78))
		h += peak.z * exp(-d.length_squared()*1.8)
	var hill_mask := smoothstep(32.0, 150.0, absf(x))
	h += (noise.get_noise_2d(x, z)*10.0+13.0)*hill_mask
	var mountain_mask := smoothstep(12.0, 100.0, h)
	h += ridge.get_noise_2d(x,z) * 23.0 * mountain_mask
	h += noise.get_noise_2d(x*2.0,z*2.0)*3.0*mountain_mask
	var lake_distance := Vector2((x+143.0)/101.0,(z+170.0)/237.0).length()
	var lake_mask := 1.0-smoothstep(.82,1.12,lake_distance)
	h = lerpf(h,-9.0,lake_mask)
	var flat := (1.0-smoothstep(30.0,44.0,absf(x)))*(1.0-smoothstep(365.0,405.0,-z))
	h = lerpf(h,0.0,flat)
	if custom_plot:
		var plot:=HoleDefinition.BOUNDS.grow(8.0)
		var distance:=maxf(maxf(plot.position.x-x,x-plot.end.x),maxf(plot.position.y-z,z-plot.end.y))
		h*=smoothstep(0.0,24.0,maxf(0.0,distance))
	return h


func build_mesh() -> ArrayMesh:
	# Near field is finely sampled; distant ridges retain their sculpted silhouette.
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var size := GRID_SIZE
	vertices.resize((size+1)*(size+1))
	normals.resize(vertices.size())
	sampled_heights.resize(vertices.size())
	for row in range(size+1):
		var z := GRID_START.y - float(row) * GRID_STEP
		for col in range(size+1):
			var x := GRID_START.x + float(col) * GRID_STEP
			var index := row*(size+1)+col
			vertices[index] = Vector3(x,height(x,z),z)
			sampled_heights[index] = vertices[index].y
			var dx := height(x-1.0,z)-height(x+1.0,z)
			var dz := height(x,z-1.0)-height(x,z+1.0)
			normals[index] = Vector3(dx,2.0,dz).normalized()
	for row in range(size):
		for col in range(size):
			var a := row*(size+1)+col
			indices.append_array(PackedInt32Array([a,a+size+1,a+1,a+1,a+size+1,a+size+2]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	return result


func rendered_height(x: float, z: float) -> float:
	# Interpolate the same two triangles as the rendered mesh, not a different
	# analytic heightfield. This matters at the fairway's sloping edges.
	if sampled_heights.is_empty(): return height(x, z)
	var column := (x - GRID_START.x) / GRID_STEP
	var row := (GRID_START.y - z) / GRID_STEP
	if column < 0 or row < 0 or column >= GRID_SIZE or row >= GRID_SIZE:
		return height(x, z)
	var cx := int(floor(column))
	var rz := int(floor(row))
	var u := column - cx
	var v := row - rz
	var a := rz * (GRID_SIZE + 1) + cx
	var ha := sampled_heights[a]
	var hb := sampled_heights[a + 1]
	var hc := sampled_heights[a + GRID_SIZE + 1]
	var hd := sampled_heights[a + GRID_SIZE + 2]
	if u + v <= 1.0:
		return ha + (hb - ha) * u + (hc - ha) * v
	return hd + (hc - hd) * (1.0 - u) + (hb - hd) * (1.0 - v)
