extends Control

@export_file("*.tscn") var orbital_scene: String = "res://OrbitalSimulation.tscn"
@export var back_button: Button
@export var fade_overlay: ColorRect
@export var camera: Camera3D
@export var focus_target: Node3D

const FADE_DURATION = 0.5
var _switching: bool = false

func _ready() -> void:
	if back_button:
		back_button.pressed.connect(_on_back_pressed)
	if camera and focus_target:
		camera.focus_on(focus_target)
	_fade_in()

func _fade_in() -> void:
	if not fade_overlay:
		return
	fade_overlay.visible = true
	fade_overlay.modulate.a = 1.0
	var tween = create_tween()
	tween.tween_property(fade_overlay, "modulate:a", 0.0, FADE_DURATION)
	tween.tween_callback(func(): fade_overlay.visible = false)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_on_back_pressed()

func _on_back_pressed() -> void:
	if _switching:
		return
	_switching = true
	if back_button:
		back_button.disabled = true

	ResourceLoader.load_threaded_request(orbital_scene)

	if fade_overlay:
		fade_overlay.visible = true
		fade_overlay.modulate.a = 0.0
		var tween = create_tween()
		tween.tween_property(fade_overlay, "modulate:a", 1.0, FADE_DURATION)
		await tween.finished

	await _wait_for_scene_load(orbital_scene)

	await get_tree().process_frame
	await get_tree().process_frame

	var packed = ResourceLoader.load_threaded_get(orbital_scene)
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
