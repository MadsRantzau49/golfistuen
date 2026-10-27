class_name PortraitArt
extends RefCounted
## Original square-head art; shared by the roster, score strip and 3D golfer.
static var cache:Dictionary={}


static func default_face(color_index:int)->Texture2D:
	var key:="default-%d"%color_index
	if cache.has(key):return cache[key]
	var image:=Image.create(256,256,false,Image.FORMAT_RGBA8)
	var skins:=[Color("e9b98b"),Color("c59065"),Color("edc5a0"),Color("ac7652"),Color("e7b591"),Color("d6a77e")]
	image.fill(skins[color_index])
	_disk(image,Vector2(57,151),18,Color("d68d76"));_disk(image,Vector2(199,151),18,Color("d68d76"))
	for x in [78,178]:
		_disk(image,Vector2(x,111),19,Color("fff4df"));_disk(image,Vector2(x+2,112),9,Color("193b32"));_disk(image,Vector2(x+5,108),3,Color.WHITE)
	for x in range(57,101):
		var y:=78+int(sin(float(x-57)/44*PI)*-7)
		for thick in range(5):image.set_pixel(x,y+thick,Color("654b36"))
	for x in range(155,199):
		var y:=78+int(sin(float(x-155)/44*PI)*-7)
		for thick in range(5):image.set_pixel(x,y+thick,Color("654b36"))
	for x in range(89,168):
		var y:=174+int(sin(float(x-89)/79*PI)*13)
		for thick in range(5):image.set_pixel(x,y+thick,Color("654335"))
	var texture:=ImageTexture.create_from_image(image);cache[key]=texture
	return texture


static func _disk(image:Image,center:Vector2,radius:int,color:Color)->void:
	for y in range(maxi(0,int(center.y)-radius),mini(256,int(center.y)+radius+1)):
		for x in range(maxi(0,int(center.x)-radius),mini(256,int(center.x)+radius+1)):
			if Vector2(x,y).distance_squared_to(center)<=radius*radius:image.set_pixel(x,y,color)
