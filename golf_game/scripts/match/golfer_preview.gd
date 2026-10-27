class_name GolferPreview
extends SubViewportContainer
var golfer:GolferCharacter

func _ready()->void:
	stretch=true;mouse_filter=Control.MOUSE_FILTER_IGNORE
	var viewport:=SubViewport.new();viewport.size=Vector2i(320,350);viewport.transparent_bg=true;viewport.own_world_3d=true
	viewport.render_target_update_mode=SubViewport.UPDATE_WHEN_VISIBLE;viewport.msaa_3d=Viewport.MSAA_2X;add_child(viewport)
	var world:=WorldEnvironment.new();var environment:=Environment.new()
	environment.background_mode=Environment.BG_COLOR;environment.background_color=Color.TRANSPARENT
	environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR;environment.ambient_light_color=Color("e0e9dd");environment.ambient_light_energy=.7
	world.environment=environment;viewport.add_child(world)
	var light:=DirectionalLight3D.new();light.rotation_degrees=Vector3(-35,-35,0);light.light_energy=1.0;viewport.add_child(light)
	var camera:=Camera3D.new();viewport.add_child(camera);camera.position=Vector3(2.3,1.9,4);camera.look_at(Vector3(0,.85,0));camera.fov=32;camera.current=true
	golfer=GolferCharacter.new();viewport.add_child(golfer)

func show_player(player:GolfPlayer,texture:Texture2D)->void:
	if golfer:golfer.apply_player(player,texture)
