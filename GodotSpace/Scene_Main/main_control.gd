extends Node3D

@export var camera: Camera3D
@export var orbital_planets: Array[OrbitalObject3D]
@export var node_planets: Array[Node3D]
@export var time_slider: HSlider
@export var pause_button: Button
@export var fade_overlay: ColorRect
@export_file("*.tscn") var satellite_showcase_scene: String = "res://SatelliteShowcase.tscn"

var _hovered_planet: Node3D = null
var _paused: bool = false
var _last_time_scale: float = 1.0
var _switching: bool = false

const TIME_SCALE_MIN = 0.00001
const TIME_SCALE_MAX = 0.5
const FADE_DURATION = 0.5

func _slider_to_time_scale(slider_val: float) -> float:
	return TIME_SCALE_MIN * pow(TIME_SCALE_MAX / TIME_SCALE_MIN, slider_val)

func _ready() -> void:
	if pause_button:
		pause_button.pressed.connect(_on_pause_pressed)
	_auto_focus_earth()
	_fade_in()

func _auto_focus_earth() -> void:
	for planet in orbital_planets:
		if is_instance_valid(planet) and planet.name == "Earth":
			camera.focus_on(planet)
			break

func _fade_in() -> void:
	if not fade_overlay:
		return
	fade_overlay.visible = true
	fade_overlay.modulate.a = 1.0
	var tween = create_tween()
	tween.tween_property(fade_overlay, "modulate:a", 0.0, FADE_DURATION)
	tween.tween_callback(func(): fade_overlay.visible = false)

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
		if _hovered_planet and not _switching:
			if _hovered_planet in node_planets:
				camera.focus_on(_hovered_planet)
				_switching = true
				await get_tree().create_timer(0.8).timeout
				_fade_out_and_switch(satellite_showcase_scene)
			else:
				camera.focus_on(_hovered_planet)

func _fade_out_and_switch(target_scene: String) -> void:
	if not fade_overlay:
		get_tree().change_scene_to_file(target_scene)
		return

	ResourceLoader.load_threaded_request(target_scene)

	fade_overlay.visible = true
	fade_overlay.modulate.a = 0.0
	var tween = create_tween()
	tween.tween_property(fade_overlay, "modulate:a", 1.0, FADE_DURATION)
	await tween.finished

	# 等场景加载完
	await _wait_for_scene_load(target_scene)
	
	# 多等两帧避免闪烁
	await get_tree().process_frame
	await get_tree().process_frame

	var packed = ResourceLoader.load_threaded_get(target_scene)
	get_tree().change_scene_to_packed(packed)

func _wait_for_scene_load(target_scene: String) -> void:
	while true:
		var status = ResourceLoader.load_threaded_get_status(target_scene)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			break
		elif status == ResourceLoader.THREAD_LOAD_FAILED:
			push_error("场景加载失败: " + target_scene)
			break
		await get_tree().process_frame
