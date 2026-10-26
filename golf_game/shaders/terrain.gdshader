shader_type spatial;
render_mode diffuse_burley;

uniform sampler2D turf_color : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D turf_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool target_turf = false;
uniform bool custom_plot = false;

varying vec3 world;
varying vec3 slope_normal;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1,311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
	return mix(mix(hash(i),hash(i+vec2(1,0)),f.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),f.x),f.y);
}

void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	slope_normal = NORMAL;
}

void fragment() {
	if (custom_plot && world.x>=-120.0 && world.x<=120.0 && world.z>=-440.0 && world.z<=40.0) discard;
	float broad = noise(world.xz * 0.035);
	float fine = noise(world.xz * 2.8);
	float detail = noise(world.xz * 15.0);
	float slope = 1.0-clamp(slope_normal.y,0.0,1.0);
	vec3 meadow = mix(vec3(0.12,0.23,0.085), vec3(0.28,0.37,0.13), broad);
	vec3 rock = mix(vec3(0.22,0.27,0.28), vec3(0.40,0.43,0.40), noise(world.xz*.07 + world.y*.04));
	rock *= 0.84 + 0.22 * noise(world.xz*0.65 + world.y*0.2);
	vec3 ground = mix(meadow, rock, clamp(smoothstep(0.20,0.57,slope) + smoothstep(55.0,180.0,world.y)*0.6,0.0,1.0));
	float snowline = 176.0 + noise(world.xz*0.017)*62.0 + noise(world.xz*.07)*16.0;
	float snow = smoothstep(snowline-10.0,snowline+8.0,world.y) * (1.0-smoothstep(.5,.88,slope));
	ground = mix(ground,vec3(0.87,0.92,0.94),snow);
	// Smooth shoreline, with warm sand and small gravel at the waterline.
	float shore = (1.0-smoothstep(0.0,2.5,world.y))*smoothstep(-44.0,-55.0,world.x);
	ground=mix(ground,mix(vec3(.43,.40,.28),vec3(.62,.57,.40),fine),shore*.8);
	// A continuous mown surface, rather than stacked rectangular primitives.
	float center=sin(world.z*.012)*2.5;
	float width=27.0 + sin(world.z*.009)*3.0;
	float fairway=(1.0-smoothstep(width-1.0,width+1.5,abs(world.x-center)))
		*smoothstep(22.0,16.0,world.z)*smoothstep(-365.0,-345.0,world.z);
	if (target_turf) fairway = 1.0;
	float stripes=smoothstep(-.15,.15,sin((world.z-8.0)*.45));
	// Millimetre-scale fibres, filtered by pixel footprint: no giant blotches or
	// sparkling high-frequency noise when the follow camera approaches the turf.
	float footprint = max(length(dFdx(world.xz)), length(dFdy(world.xz)));
	float near_detail = 1.0 - smoothstep(.003, .018, footprint);
	float fibres = noise(world.xz * vec2(240.0, 75.0));
	float small_grain = noise(world.xz * 95.0);
	vec3 turf=mix(vec3(.22,.36,.16),vec3(.255,.405,.18),stripes);
	turf *= .975 + (fibres - .5) * near_detail * .08;
	ground=mix(ground,turf,fairway);
	float ground_variation = mix(.94+fine*.09+detail*.035, 1.0, fairway);
	ALBEDO=pow(ground,vec3(2.2))*ground_variation;
	// A real 1.4 m grass tile supplies fine leaf structure; distant scenery keeps
	// the existing art direction. Anisotropic mipmapping handles low camera angles.
	vec2 turf_uv = world.xz / 1.4;
	float texture_blend = (1.0-smoothstep(12.0,45.0,distance(CAMERA_POSITION_WORLD,world)))
		*max(fairway, (1.0-smoothstep(8.0,25.0,world.y))*(1.0-shore)*.7);
	vec3 capture_normal = vec3(0.0,0.0,1.0);
	// Do not pay for grazing-angle anisotropic grass samples on distant mountains.
	if (texture_blend > .01) {
		vec3 captured_grass = texture(turf_color, turf_uv).rgb;
		float captured_luma = dot(captured_grass, vec3(.2126,.7152,.0722));
		vec3 graded_grass = ALBEDO * clamp(captured_luma * 6.0, .55, 1.45);
		graded_grass = mix(graded_grass, captured_grass * .65, .28);
		ALBEDO = mix(ALBEDO, graded_grass, texture_blend);
		capture_normal = texture(turf_normal,turf_uv).xyz * 2.0 - 1.0;
	}
	ROUGHNESS=.94;
	SPECULAR=.18;
	// This heightfield has no tangent UV basis; perturb its actual world normal.
	vec3 micro_normal = normalize(slope_normal + vec3(fibres-.5, 0.0, small_grain-.5) * .055 * near_detail * fairway);
	micro_normal = normalize(micro_normal + vec3(capture_normal.x,0.0,-capture_normal.y)*texture_blend*.28);
	NORMAL = normalize((VIEW_MATRIX * vec4(micro_normal, 0.0)).xyz);
}
