shader_type canvas_item;
void fragment() {
	float left=1.0-smoothstep(.05,.83,UV.x);
	float bottom=pow(UV.y,5.0)*.5;
	COLOR=vec4(.02,.065,.05,clamp(left*.82+bottom,0.0,.92));
}
