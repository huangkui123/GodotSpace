extends RefCounted

## Shared styling for the Sky tools, using the main menu's blue/violet palette.
const BACKGROUND := Color("111d40")
const SURFACE := Color("1c2c55")
const BORDER := Color("354b7a")
const TEXT := Color("e0e8ff")
const MUTED := Color("9baed7")
const ACCENT := Color("73cfff")


static func box(color: Color, padding: int = 12, radius: int = 6) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(padding)
	return style


static func make_theme(font_size: int = 20) -> Theme:
	var result := Theme.new()
	result.default_font_size = font_size
	result.set_color("font_color", "Label", TEXT)
	result.set_color("font_color", "LineEdit", TEXT)
	for type in ["Button", "OptionButton"]:
		for state in ["normal", "hover", "pressed", "disabled", "focus"]:
			var color: Color = {"normal": SURFACE, "hover": Color("2c4376"),
				"pressed": Color("395889"), "disabled": Color("182440"), "focus": Color(0, 0, 0, 0)}[state]
			var style := box(color, 10)
			style.content_margin_top = 6
			style.content_margin_bottom = 6
			style.border_color = ACCENT if state == "focus" else BORDER
			style.set_border_width_all(2 if state == "focus" else 1)
			result.set_stylebox(state, type, style)
		result.set_color("font_color", type, TEXT)
		result.set_color("font_hover_color", type, Color.WHITE)
		result.set_color("font_pressed_color", type, Color.WHITE)
		result.set_color("font_disabled_color", type, Color("617395"))
	result.set_stylebox("normal", "LineEdit", box(BACKGROUND, 8))
	result.set_stylebox("panel", "TabContainer", box(SURFACE, 16))
	result.set_stylebox("tab_selected", "TabContainer", box(Color("304b7e"), 13))
	result.set_stylebox("tab_unselected", "TabContainer", box(BACKGROUND, 13))
	result.set_color("font_selected_color", "TabContainer", ACCENT)
	result.set_color("font_unselected_color", "TabContainer", MUTED)
	result.set_stylebox("panel", "PopupMenu", box(BACKGROUND, 10))
	result.set_stylebox("hover", "PopupMenu", box(SURFACE, 6))
	return result


static func primary(button: Button) -> void:
	button.add_theme_stylebox_override("normal", box(Color("275785"), 12))
	button.add_theme_stylebox_override("hover", box(Color("3676a6"), 12))
	button.add_theme_stylebox_override("pressed", box(Color("234566"), 12))
	button.add_theme_color_override("font_color", Color("e7f7ff"))


static func secondary(label: Label) -> void:
	label.add_theme_color_override("font_color", MUTED)


class ToolIcon extends Control:
	var cabinet := false
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		var color := Color("a7caff")
		if cabinet:
			var points := PackedVector2Array([Vector2(25, 24), Vector2(65, 24),
				Vector2(65, 77), Vector2(25, 77), Vector2(25, 24)])
			draw_polyline(points, color, 3, true)
			draw_polyline(PackedVector2Array([Vector2(25, 24), Vector2(43, 12),
				Vector2(83, 12), Vector2(83, 65), Vector2(65, 77)]), color, 3, true)
			draw_line(Vector2(65, 24), Vector2(83, 12), color, 3, true)
			draw_line(Vector2(45, 24), Vector2(45, 77), color, 2, true)
		else:
			for i in range(3):
				var y := 24.0 + i * 23
				var x: float = [38.0, 68.0, 48.0][i]
				draw_line(Vector2(18, y), Vector2(86, y), color, 3, true)
				draw_circle(Vector2(x, y), 7, Color("334875"))
				draw_arc(Vector2(x, y), 7, 0, TAU, 24, color, 3, true)
