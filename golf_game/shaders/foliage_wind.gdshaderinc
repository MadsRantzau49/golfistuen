vec3 foliage_wind(vec3 vertex, vec3 world, float time) {
	float wind = sin(time*.75+world.x*.09+world.z*.06)+sin(time*1.2+world.z*.17)*.35;
	vertex.x += wind*pow(max(vertex.y,0.0),1.8)*.012;
	vertex.z += sin(time*.6+world.x*.15)*pow(max(vertex.y,0.0),1.5)*.006;
	return vertex;
}
