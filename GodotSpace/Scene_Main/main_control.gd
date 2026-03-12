extends Node3D

@export var camera: Camera3D
@export var orbital_planets: Array[OrbitalObject3D]
@export var node_planets: Array[Node3D]
@export var time_slider: HSlider
@export var pause_button: Button

var _hovered_planet: Node3D = null
var _paused: bool = false
var _last_time_scale: float = 1.0

const TIME_SCALE_MIN = 0.00001
const TIME_SCALE_MAX = 0.5

func _slider_to_time_scale(slider_val: float) -> float:
	return TIME_SCALE_MIN * pow(TIME_SCALE_MAX / TIME_SCALE_MIN, slider_val)

func _ready() -> void:
	if pause_button:
		pause_button.pressed.connect(_on_pause_pressed)

func _on_pause_pressed() -> void:
	_paused = !_paused
	if _paused:
		_last_time_scale = OrbitalManager.time_scale
		OrbitalManager.time_scale = 0.0
		pause_button.text = "继续"
	else:
		OrbitalManager.time_scale = _last_time_scale
		pause_button.text = "暂停"

func _process(_delta: float) -> void:
	if time_slider and not _paused:
		OrbitalManager.time_scale = _slider_to_time_scale(time_slider.value)
	_update_hover()

func _get_label(node: Node3D) -> Label3D:
	for child in node.get_children():
		if child is Label3D:
			return child
	return null

func _update_hover() -> void:
	var found: Node3D = null

	for planet in orbital_planets:
		if not is_instance_valid(planet):
			continue
		var label = _get_label(planet)
		if label and label.is_mouse_over():
			found = planet
			break

	if not found:
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
