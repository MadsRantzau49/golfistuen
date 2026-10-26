shader_type spatial;
render_mode diffuse_burley;
uniform bool custom_plot = false;

varying vec3 world;

void vertex() {
	world=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;
	VERTEX.y+=sin(world.x*.12+TIME*.35)*cos(world.z*.1+TIME*.22)*.045;
}
void fragment() {
	if (custom_plot && world.x>=-120.0 && world.x<=120.0 && world.z>=-440.0 && world.z<=40.0) discard;
	float a=sin(world.x*1.8+world.z*.8+TIME*.7);
	float b=sin(world.z*2.3-world.x*.4+TIME*.55);
	vec3 surface=normalize(vec3(a*.05,b*.05,1.0));
	NORMAL_MAP=surface*.5+.5;
	NORMAL_MAP_DEPTH=.6;
	float fresnel=pow(1.0-clamp(dot(NORMAL,VIEW),0.0,1.0),3.0);
	vec3 shallow=vec3(.055,.25,.23);
	ALBEDO=pow(mix(shallow,vec3(.28,.46,.48),fresnel*.65),vec3(2.2));
	EMISSION=vec3(0.0);
	ROUGHNESS=.28;
	METALLIC=.5;
	SPECULAR=.5;
}
