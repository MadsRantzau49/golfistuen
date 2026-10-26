class_name AppStyle
extends RefCounted
## Shared typography, accessible focus treatment and interaction styling.

const BODY := preload("res://assets/Outfit.ttf")
const DISPLAY := preload("res://assets/Fraunces.ttf")
const CREAM := Color("f5efdf")
const GOLD := Color("e6c798")
const MUTED := Color("a3b4a6")
const PANEL := Color("10251feF")


static func font(weight := 450, display := false) -> FontVariation:
	var variation := FontVariation.new()
	variation.base_font = DISPLAY if display else BODY
	variation.variation_opentype = {0x77676874: weight}
	return variation


static func theme() -> Theme:
	var result := Theme.new()
	result.default_font = font()
	result.default_font_size = 16
	return result


static func label(text: String, size := 16, color := CREAM, display := false) -> Label:
	var result := Label.new()
	result.text = text
	result.add_theme_font_override("font",font(450,display))
	result.add_theme_font_size_override("font_size",size)
	result.add_theme_color_override("font_color",color)
	result.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return result


static func box(color := PANEL, radius := 14, border := Color("ffffff16"), padding := 18) -> StyleBoxFlat:
	var result := StyleBoxFlat.new()
	result.bg_color = color
	result.set_corner_radius_all(radius)
	result.set_border_width_all(1)
	result.border_color = border
	result.content_margin_left = padding
	result.content_margin_right = padding
	result.content_margin_top = padding
	result.content_margin_bottom = padding
	return result


static func button(text: String, primary := false) -> Button:
	var result := Button.new()
	result.text = text
	result.custom_minimum_size.y = 46
	result.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	result.add_theme_font_override("font",font(500))
	result.add_theme_font_size_override("font_size",15)
	for state in ["font_color","font_hover_color","font_pressed_color","font_focus_color"]:
		result.add_theme_color_override(state,Color("1c3027") if primary else CREAM)
	result.add_theme_color_override("font_disabled_color",Color("839087"))
	result.add_theme_stylebox_override("normal",box(GOLD if primary else Color("142e26c9"),9,Color("ffffff20"),12))
	result.add_theme_stylebox_override("hover",box(Color("f3dbb3") if primary else Color("2a483cdE"),9,GOLD,12))
	result.add_theme_stylebox_override("pressed",box(Color("c4a776") if primary else Color("395345"),9,GOLD,12))
	result.add_theme_stylebox_override("disabled",box(Color("18302680"),9,Color("ffffff0c"),12))
	result.add_theme_stylebox_override("focus",box(Color.TRANSPARENT,9,GOLD,12))
	result.pressed.connect(func():AudioDirector.play_ui())
	return result


static func full_rect(control: Control) -> void:
	control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


static func panel(parent: Node, left: float, top: float, right: float, bottom: float) -> PanelContainer:
	var result := PanelContainer.new()
	parent.add_child(result)
	result.offset_left=left
	result.offset_top=top
	result.offset_right=right
	result.offset_bottom=bottom
	result.add_theme_stylebox_override("panel",box())
	return result


static func divider() -> HSeparator:
	var result := HSeparator.new()
	var style := StyleBoxLine.new()
	style.color=Color("ffffff18")
	style.thickness=1
	result.add_theme_stylebox_override("separator",style)
	return result


static func shade(parent: Node, alpha := .65) -> ColorRect:
	var rect := ColorRect.new()
	parent.add_child(rect)
	full_rect(rect)
	rect.color=Color(.025,.07,.055,alpha)
	return rect
