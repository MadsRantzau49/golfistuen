class_name GolfPlayer
extends RefCounted
const MAX_PLAYERS := 6
const COLORS := [Color("4fc5ad"),Color("ee886b"),Color("6ba9e8"),Color("e4bd60"),Color("b48fe5"),Color("e68eb8")]
const COLOR_NAMES := ["Lagoon","Ember","Sky","Sunshine","Orchid","Blossom"]
var id := ""
var name := "Player"
var color_index := 0
var photo_file := ""


func _init(display_name:="Player",color:=0)->void:
	id="player-%x-%x"%[Time.get_ticks_usec(),randi()]
	name=display_name;color_index=clampi(color,0,COLORS.size()-1)


func color()->Color:return COLORS[color_index]


func to_dict()->Dictionary:
	return {"id":id,"name":name,"color_index":color_index,"photo_file":photo_file}


static func from_dict(data:Dictionary)->GolfPlayer:
	if not data.get("id") is String or not HoleDefinition.valid_id(data.id):return null
	if not data.get("name") is String or data.name.strip_edges().is_empty() or data.name.length()>24:return null
	if not data.get("color_index") is int and not data.get("color_index") is float:return null
	var color_value:=int(data.color_index)
	if color_value!=data.color_index or color_value<0 or color_value>=COLORS.size():return null
	var photo:Variant=data.get("photo_file","")
	if not photo is String or (not photo.is_empty() and photo!=data.id+".png"):return null
	var player:=GolfPlayer.new(data.name.strip_edges(),color_value)
	player.id=data.id;player.photo_file=photo
	return player
