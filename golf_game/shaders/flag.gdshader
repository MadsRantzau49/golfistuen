shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha;
uniform float obstruction_opacity = 1.0;
void vertex() {
	VERTEX.z+=sin(UV.x*7.0-TIME*2.0)*.13*UV.x;
	VERTEX.y+=sin(UV.x*5.0-TIME*1.6)*.035*UV.x;
}
void fragment() {
	ALBEDO=vec3(.77,.43,.19);
	ROUGHNESS=.85;
	ALPHA=obstruction_opacity;
}
