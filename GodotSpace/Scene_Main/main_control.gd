extends Node3D

@export var camera: Camera3D
@export var planets: Array[OrbitalObject3D]
@export var time_slider: HSlider
@export var pause_button: Button

var _hovered_planet: OrbitalObject3D = null
var _paused: bool = false
var _last_time_scale: float = 1.0

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
		if time_slider:
			time_slider.value = _last_time_scale
		pause_button.text = "暂停"

func _process(_delta: float) -> void:
	if time_slider and not _paused:
		OrbitalManager.time_scale = time_slider.value
	_update_hover()

func _update_hover() -> void:
	var found: OrbitalObject3D = null
	for planet in planets:
		var label = planet.get_node_or_null("Label3D")
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
