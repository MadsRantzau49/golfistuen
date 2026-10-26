shader_type spatial;
render_mode cull_disabled;
#include "res://shaders/foliage_wind.gdshaderinc"

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX = foliage_wind(VERTEX, world, TIME);
}

void fragment() { ALBEDO = vec3(.2, .3, .15); }
