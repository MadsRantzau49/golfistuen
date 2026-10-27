shader_type spatial;
render_mode cull_disabled, diffuse_burley;
uniform sampler2D height_field : filter_nearest, repeat_disable;
uniform sampler2D surface_map : filter_linear, repeat_disable;
uniform sampler2D oob_map : filter_linear, repeat_disable;
uniform float fairway_height=.018;
uniform float rough_height=.065;
uniform float mat_height=.005;
uniform float density=1.0;
uniform float detail_visibility=0.0;
uniform vec3 ball_position=vec3(0.0);
uniform float ball_radius=.03;
uniform bool ball_grounded=false;
uniform vec2 cup_position=vec2(0.0);
uniform float cup_radius=.15;
uniform bool cup_placed=false;
varying float tint;
varying vec2 blade_world;
float hash(vec2 p) { return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453); }
float height_at(vec2 point) {
	vec2 grid=(point-vec2(-120.0,-440.0))/2.0;
	ivec2 cell=ivec2(clamp(floor(grid),vec2(0.0),vec2(119.0,239.0)));
	vec2 f=fract(grid);
	float a=texelFetch(height_field,cell,0).r;
	float b=texelFetch(height_field,cell+ivec2(1,0),0).r;
	float c=texelFetch(height_field,cell+ivec2(0,1),0).r;
	float d=texelFetch(height_field,cell+ivec2(1,1),0).r;
	return f.x+f.y<=1.0?a+(b-a)*f.x+(c-a)*f.y:d+(c-d)*(1.0-f.x)+(b-d)*(1.0-f.y);
}
void vertex() {
	vec3 root=(MODEL_MATRIX*vec4(0.0,0.0,0.0,1.0)).xyz;
	vec2 cell_id=round(root.xz/INSTANCE_CUSTOM.b);
	tint=hash(cell_id);
	float angle=tint*6.283185;
	VERTEX.xz=mat2(vec2(cos(angle),-sin(angle)),vec2(sin(angle),cos(angle)))*VERTEX.xz;
	vec2 jitter=vec2(tint,hash(cell_id.yx+53.0))*INSTANCE_CUSTOM.b*.7;
	VERTEX.xz+=jitter;
	vec2 point=root.xz+jitter;
	vec2 uv=((point-vec2(-120.0,-440.0))/2.0+.5)/vec2(121.0,241.0);
	vec4 weights=texture(surface_map,uv);
	float canopy=mix(rough_height,fairway_height,clamp(weights.r+weights.g,0.0,1.0));
	float active=(tint>density || point.x< -120.0 || point.x>120.0 || point.y< -440.0 || point.y>40.0)?0.0:1.0;
	active*=1.0-smoothstep(.15,.55,weights.b+weights.a+texture(oob_map,uv).r);
	active*=1.0-smoothstep(INSTANCE_CUSTOM.a-1.0,INSTANCE_CUSTOM.a,length(INSTANCE_CUSTOM.rg));
	active*=1.0-smoothstep(18.0,28.0,distance(CAMERA_POSITION_WORLD.xz,point));
	float height=VERTEX.y/fairway_height*canopy*active*detail_visibility;
	if(ball_grounded) height*=1.0-(1.0-smoothstep(ball_radius*.6,ball_radius*2.5,distance(point,ball_position.xz)))*.65;
	VERTEX.x+=sin(TIME*1.3+point.x*2.4+point.y*1.7)*.0012*UV.y*UV.y;
	VERTEX.y=height+height_at(point)-root.y;
	blade_world=(MODEL_MATRIX*vec4(VERTEX,1.0)).xz;
}
void fragment() {
	if(cup_placed && distance(blade_world,cup_position)<cup_radius) discard;
	vec3 leaf=mix(vec3(.23,.35,.14),vec3(.32,.44,.19),UV.y*.7+tint*.2);
	ALBEDO=pow(leaf,vec3(2.2));
	vec3 up=normalize((VIEW_MATRIX*vec4(0.0,1.0,0.0,0.0)).xyz);
	NORMAL=normalize(mix(NORMAL,up,.8));
	ROUGHNESS=.9; SPECULAR=.15; BACKLIGHT=ALBEDO*.18;
}
