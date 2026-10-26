shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

void fragment() {
	float edge = 1.0 - smoothstep(.12, .5, abs(UV.x - .5));
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a * edge;
}
