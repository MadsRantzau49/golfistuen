shader_type spatial;
render_mode cull_disabled, diffuse_burley;

varying vec3 world;
uniform vec3 ball_position = vec3(0.0);
uniform bool ball_grounded = false;
void vertex() {
	world=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;
	float bend=sin(TIME*1.1+world.x*.5+world.z*.3)*.12;
	VERTEX.x+=bend*VERTEX.y*VERTEX.y;
	if (ball_grounded) {
		float contact = 1.0 - smoothstep(.12, .55, distance(world.xz, ball_position.xz));
		VERTEX.y *= 1.0 - contact * .97;
	}
}
void fragment() {
	ALBEDO=pow(COLOR.rgb,vec3(2.2));
	ROUGHNESS=.95;
	SPECULAR=.12;
	BACKLIGHT=pow(COLOR.rgb,vec3(2.2))*.25;
}
