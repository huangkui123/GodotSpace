extends Control

signal point_clicked(pixel: Vector2)

var image_size := Vector2i(960, 720)
var texture: Texture2D
var points := PackedVector2Array()
var wire_points := PackedVector2Array()
var fitted_points := PackedVector2Array()


func _ready() -> void:
	custom_minimum_size = Vector2(360, 300)
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(queue_redraw)


func image_rect() -> Rect2:
	var ratio := minf(size.x / float(maxi(1, image_size.x)), size.y / float(maxi(1, image_size.y)))
	var fitted := Vector2(image_size) * ratio
	return Rect2((size - fitted) * 0.5, fitted)


func pixel_to_local(pixel: Vector2) -> Vector2:
	var rect := image_rect()
	return rect.position + pixel * rect.size / Vector2(image_size)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var rect := image_rect()
		if rect.has_point(event.position):
			point_clicked.emit((event.position - rect.position) * Vector2(image_size) / rect.size)
		accept_event()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("0b1733"))
	var rect := image_rect()
	if texture != null:
		draw_texture_rect(texture, rect, false)
	else:
		draw_rect(rect, Color("1b3157"))
	_draw_wire(wire_points, Color("a9bdca"), 3.0)
	if texture == null and wire_points.size() == 8:
		var center := Vector2.ZERO
		for i in range(4):
			var a := pixel_to_local(wire_points[i])
			var b := pixel_to_local(wire_points[(i + 1) % 4])
			center += a * 0.25
			draw_line(a, b, Color("e7f4ff"), 4.0, true)
		draw_string(ThemeDB.fallback_font, center - Vector2(20, 0), "正面", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color("e7f4ff"))
	_draw_wire(fitted_points, Color("55eda9"), 2.0)
	for i in range(points.size()):
		var p := pixel_to_local(points[i])
		draw_circle(p, 7.0, Color("ffbd49"))
		draw_string(ThemeDB.fallback_font, p + Vector2(10, -7), str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color.WHITE)
	if texture == null and wire_points.is_empty():
		draw_string(ThemeDB.fallback_font, rect.position + Vector2(20, 35), "等待 PICO 图像，或选择模拟柜体", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color.WHITE)


func _draw_wire(vertices: PackedVector2Array, color: Color, width: float) -> void:
	if vertices.size() != 8:
		return
	for edge in [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]]:
		var a := vertices[edge[0]]
		var b := vertices[edge[1]]
		if a.is_finite() and b.is_finite():
			draw_line(pixel_to_local(a), pixel_to_local(b), color, width, true)
