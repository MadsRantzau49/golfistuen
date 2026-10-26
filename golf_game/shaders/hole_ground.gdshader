shader_type spatial;
render_mode diffuse_burley;
uniform sampler2D surface_map : filter_linear, repeat_disable;
uniform sampler2D oob_map : filter_linear, repeat_disable;
uniform sampler2D turf_color : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D turf_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool editor_mode = true;
uniform vec2 cup_position = vec2(0.0);
uniform bool cup_placed = false;
varying vec3 world;
varying vec3 terrain_normal;

void vertex() {
	world=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;
	terrain_normal=NORMAL;
}
void fragment() {
	vec2 uv=((world.xz-vec2(-120.0,-440.0))/2.0+.5)/vec2(121.0,241.0);
	vec4 weights=texture(surface_map,uv);
	float oob=texture(oob_map,uv).r;
	vec3 rough=vec3(.23,.32,.13);
	float stripes=smoothstep(-.3,.3,sin(world.z*.36));
	vec3 grass=mix(rough,mix(vec3(.22,.36,.16),vec3(.255,.405,.18),stripes),weights.r);
	grass=mix(grass,vec3(.27,.43,.19),weights.g);
	vec3 color=pow(grass,vec3(2.2));
	float near_detail=1.0-smoothstep(18.0,55.0,distance(CAMERA_POSITION_WORLD,world));
	vec3 bump=vec3(0.0,0.0,1.0);
	if(near_detail>.01) {
		vec3 texture_color=texture(turf_color,world.xz/1.4).rgb;
		float luma=dot(texture_color,vec3(.2126,.7152,.0722));
		vec3 detailed=mix(color*clamp(luma*6.0,.55,1.45),texture_color*.65,.25);
		color=mix(color,detailed,near_detail);
		bump=texture(turf_normal,world.xz/1.4).xyz*2.0-1.0;
	}
	float sand_grain=fract(sin(dot(floor(world.xz*70.0),vec2(12.9898,78.233)))*43758.5453);
	color=mix(color,pow(vec3(.64,.55,.36),vec3(2.2))*(.94+sand_grain*.12),weights.b);
	color=mix(color,vec3(.04,.065,.025),weights.a);
	if(editor_mode) {
		vec2 cell=abs(fract(world.xz/10.0-.5)-.5)/max(fwidth(world.xz/10.0),vec2(.0001));
		float grid=1.0-min(min(cell.x,cell.y),1.0);
		color=mix(color,vec3(.24,.31,.21),grid*.15);
		if(terrain_normal.y<.995) {
			float contour=abs(fract(world.y/2.0-.5)-.5)/max(fwidth(world.y/2.0),.0001);
			color=mix(color,vec3(.55,.49,.29),(1.0-min(contour,1.0))*.25);
		}
		float hatch=step(.55,fract((world.x+world.z)*.18));
		color=mix(color,vec3(.31,.045,.025)*(1.0+hatch*.4),oob*.7);
	}
	float boundary=(1.0-smoothstep(.0,.12,abs(oob-.5)))*.7;
	color=mix(color,vec3(.8,.77,.64),boundary);
	if(cup_placed && distance(world.xz,cup_position)<.055) discard;
	ALBEDO=color;
	ROUGHNESS=.94;
	SPECULAR=.12;
	vec3 normal=normalize(terrain_normal+vec3(bump.x,0.0,-bump.y)*near_detail*.2*(1.0-weights.b));
	NORMAL=normalize((VIEW_MATRIX*vec4(normal,0.0)).xyz);
}
