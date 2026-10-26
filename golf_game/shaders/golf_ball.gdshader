shader_type spatial;
void fragment() {
	vec2 cells=UV*vec2(28.0,12.0);
	cells.x+=mod(floor(cells.y),2.0)*.5;
	vec2 grid=fract(cells)-.5;
	float detail=1.0-smoothstep(.15,.65,max(fwidth(cells.x),fwidth(cells.y)));
	float dimple=(1.0-smoothstep(.20,.36,length(grid)))*detail;
	ALBEDO=vec3(.86,.89,.85)*(1.0-dimple*.045);
	float marking=1.0-smoothstep(.006,.011+fwidth(UV.y),abs(UV.y-.5));
	ALBEDO=mix(ALBEDO,vec3(.06,.14,.12),marking*.7);
	NORMAL_MAP=normalize(vec3(grid*dimple*.18,1.0))*.5+.5;
	ROUGHNESS=.27;
	SPECULAR=.5;
}
