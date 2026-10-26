shader_type sky;

float hash(vec3 p) { p=fract(p*.3183099+vec3(.1,.2,.3)); p*=17.0; return fract(p.x*p.y*p.z*(p.x+p.y+p.z)); }
float noise(vec3 p) {
	vec3 i=floor(p),f=fract(p); f=f*f*(3.0-2.0*f);
	return mix(mix(mix(hash(i),hash(i+vec3(1,0,0)),f.x),mix(hash(i+vec3(0,1,0)),hash(i+vec3(1,1,0)),f.x),f.y),
		mix(mix(hash(i+vec3(0,0,1)),hash(i+vec3(1,0,1)),f.x),mix(hash(i+vec3(0,1,1)),hash(i+vec3(1,1,1)),f.x),f.y),f.z);
}
void sky() {
	float horizon=pow(1.0-max(EYEDIR.y,0.0),3.5);
	vec3 blue=mix(vec3(.18,.39,.58),vec3(.70,.78,.77),horizon);
	vec3 sun_direction=normalize(vec3(-.55,.32,-.6));
	float sun=pow(max(dot(EYEDIR,sun_direction),0.0),80.0);
	blue+=vec3(1.0,.74,.39)*sun*.3;
	vec3 p=EYEDIR/max(EYEDIR.y+.17,.08)*3.2+vec3(TIME*.004,0,0);
	float cloud=noise(p)*.57+noise(p*2.1)*.28+noise(p*4.2)*.15;
	cloud=smoothstep(.52,.75,cloud)*smoothstep(.01,.16,EYEDIR.y);
	vec3 cloud_color=mix(vec3(.73,.78,.79),vec3(.98,.94,.83),smoothstep(.55,.8,noise(p+vec3(-.4,.6,0))));
	COLOR=mix(blue,cloud_color,cloud*.85);
}
