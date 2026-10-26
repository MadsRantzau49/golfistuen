shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform float opacity = .4;
void fragment() {
	float radius = length((UV - .5) * 2.0);
	ALBEDO = vec3(.035, .07, .035);
	ALPHA = (1.0 - smoothstep(.12, 1.0, radius)) * opacity;
}
