shader_type spatial;
uniform sampler2D surface_map : filter_linear, repeat_disable;
varying vec3 world;
void vertex() { world=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz; }
void fragment() {
	vec2 uv=((world.xz-vec2(-120.0,-440.0))/2.0+.5)/vec2(121.0,241.0);
	if(texture(surface_map,uv).a<.5) discard;
	float wave=sin(world.x*1.7+TIME*.6)+sin(world.z*2.2-TIME*.45);
	ALBEDO=vec3(.018,.10,.085);
	NORMAL_MAP=normalize(vec3(wave*.035,cos(world.x*.8+TIME*.3)*.04,1.0))*.5+.5;
	ROUGHNESS=.3;
	METALLIC=.35;
	SPECULAR=.45;
}
