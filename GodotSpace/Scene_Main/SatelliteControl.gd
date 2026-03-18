extends Node3D

@export var camera: Camera3D
@export var node_planets: Array[Node3D]
@export var spin_rate: float = 1.0  # 旋转速度 rad/s

var _hovered_planet: Node3D = null

func _process(delta: float) -> void:
	_update_hover()
	for planet in node_planets:
		if is_instance_valid(planet):
			planet.rotate_y(spin_rate * delta)

func _get_label(node: Node3D) -> Label3D:
	for child in node.get_children():
		if child is Label3D:
			return child
	return null

func _update_hover() -> void:
	var found: Node3D = null
	for planet in node_planets:
		if not is_instance_valid(planet):
			continue
		var label = _get_label(planet)
		if label and label.is_mouse_over():
			found = planet
			break

	_hovered_planet = found
	if found:
		DisplayServer.cursor_set_shape(DisplayServer.CURSOR_POINTING_HAND)
	else:
		DisplayServer.cursor_set_shape(DisplayServer.CURSOR_ARROW)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _hovered_planet:
			camera.focus_on(_hovered_planet)
