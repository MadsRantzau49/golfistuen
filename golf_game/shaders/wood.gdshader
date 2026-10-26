shader_type spatial;
render_mode depth_prepass_alpha;
uniform vec4 base_color : source_color = vec4(.5, .4, .25, 1.0);
uniform float obstruction_opacity = 1.0;
varying vec3 local;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1,0)), f.x), mix(hash(i + vec2(0,1)), hash(i + vec2(1,1)), f.x), f.y);
}
void vertex() { local = VERTEX; }
void fragment() {
	float bend = noise(local.xz * vec2(3.0, .4));
	float grain = noise(vec2(local.x * 230.0 + bend * 8.0, local.z * 1.8));
	float fine = noise(local.xz * vec2(700.0, 16.0));
	ALBEDO = base_color.rgb * (.79 + grain * .28 + fine * .06);
	ROUGHNESS = .62 + grain * .2;
	SPECULAR = .23;
	ALPHA = obstruction_opacity;
}
