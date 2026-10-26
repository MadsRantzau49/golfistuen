shader_type canvas_item;
void fragment() {
	float top=pow(1.0-UV.y,12.0)*.4;
	float bottom=pow(UV.y,10.0)*.15;
	float edges=pow(abs(UV.x-.5)*2.0,5.0)*.07;
	COLOR=vec4(.02,.06,.04,top+bottom+edges);
}
