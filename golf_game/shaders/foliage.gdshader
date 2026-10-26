shader_type spatial;
render_mode diffuse_burley, cull_disabled, depth_prepass_alpha;
#include "res://shaders/foliage_wind.gdshaderinc"

varying float opacity;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX = foliage_wind(VERTEX, world, TIME);
	opacity = INSTANCE_CUSTOM.a;
}

void fragment() {
	ALBEDO = pow(COLOR.rgb, vec3(2.2));
	ROUGHNESS = .9;
	SPECULAR = .12;
	BACKLIGHT = ALBEDO * .16;
	ALPHA = opacity;
}
