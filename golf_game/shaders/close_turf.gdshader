shader_type spatial;
render_mode cull_disabled, diffuse_burley;

uniform sampler2D height_field : filter_nearest, repeat_disable;
uniform float fairway_height = .018;
uniform float rough_height = .065;
uniform float mat_height = .005;
uniform float density = 1.0;
uniform float detail_visibility = 0.0;
uniform vec3 ball_position = vec3(0.0);
uniform float ball_radius = .03;
uniform bool ball_grounded = false;
varying float tint;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float ground_height(vec2 world) {
	vec2 grid = vec2((world.x + 780.0) / 6.5, (170.0 - world.y) / 6.5);
	ivec2 cell = ivec2(clamp(floor(grid), vec2(0.0), vec2(239.0)));
	vec2 f = fract(grid);
	float a = texelFetch(height_field, cell, 0).r;
	float b = texelFetch(height_field, cell + ivec2(1, 0), 0).r;
	float c = texelFetch(height_field, cell + ivec2(0, 1), 0).r;
	float d = texelFetch(height_field, cell + ivec2(1, 1), 0).r;
	return f.x + f.y <= 1.0 ? a + (b-a)*f.x + (c-a)*f.y : d + (c-d)*(1.0-f.x) + (b-d)*(1.0-f.y);
}

void vertex() {
	vec3 root = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float spacing = INSTANCE_CUSTOM.b;
	vec2 cell_id = round(root.xz / spacing);
	tint = hash(cell_id);
	float angle = tint * 6.283185;
	mat2 rotation = mat2(vec2(cos(angle), -sin(angle)), vec2(sin(angle), cos(angle)));
	VERTEX.xz = rotation * VERTEX.xz;
	vec2 jitter = vec2(tint, hash(cell_id.yx + 53.0)) * spacing * .7;
	VERTEX.xz += jitter;
	vec2 world = root.xz + jitter;
	float base = ground_height(world);
	bool mat = abs(world.x) <= 2.25 && abs(world.y - 8.0) <= 1.6;
	bool deck = abs(world.x) <= 6.0 && world.y >= 6.5 && world.y <= 17.5;
	float center = sin(world.y * .012) * 2.5;
	float width = 27.0 + sin(world.y * .009) * 3.0;
	bool fairway = abs(world.x-center) <= width && world.y < 19.0 && world.y > -355.0;
	bool target = false;
	for (int i=1; i<=6; i++) {
		if (distance(world, vec2(0.0, 8.0-float(i)*50.0)) < 6.8) target = true;
	}
	float canopy = fairway || target ? fairway_height : rough_height;
	if (mat) { base = max(base, .115); canopy = mat_height; }
	else if (deck) canopy = 0.0;
	else if (target) base = max(base, .0525);
	float active = (base < -.6 || tint > density) ? 0.0 : 1.0;
	float edge = length(INSTANCE_CUSTOM.rg);
	active *= 1.0-smoothstep(INSTANCE_CUSTOM.a-1.0, INSTANCE_CUSTOM.a, edge);
	active *= 1.0-smoothstep(18.0, 28.0, distance(CAMERA_POSITION_WORLD.xz, world));
	float height = VERTEX.y / fairway_height * canopy * active * detail_visibility;
	float breeze = sin(TIME*1.3+world.x*2.4+world.y*1.7)*.0012;
	VERTEX.x += breeze * UV.y * UV.y;
	if (ball_grounded) {
		float compression=1.0-smoothstep(ball_radius*.6, ball_radius*2.5, distance(world, ball_position.xz));
		height *= 1.0-compression*.65;
	}
	VERTEX.y = height + base - root.y;
}

void fragment() {
	vec3 leaf = mix(vec3(.23,.35,.14), vec3(.32,.44,.19), UV.y*.7+tint*.2);
	ALBEDO=pow(leaf,vec3(2.2));
	// Fine two-sided leaves transmit light; back faces must not turn into black
	// pepper-like triangles against a sunlit, closely mown surface.
	vec3 up = normalize((VIEW_MATRIX * vec4(0.0,1.0,0.0,0.0)).xyz);
	NORMAL = normalize(mix(NORMAL, up, .8));
	ROUGHNESS=.9;
	SPECULAR=.15;
	BACKLIGHT=ALBEDO*.18;
}
