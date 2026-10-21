extends SceneTree

const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const Preferences := preload("res://Assets/ARSpace/Scripts/XR/sky_view_preferences.gd")

class TestScene extends Node3D:
	var calibration_parent: Node
	func open_panel(parent_panel: Node) -> void:
		calibration_parent = parent_panel
	var opacity := Preferences.DEFAULT_OPACITY
	func get_sky_opacity() -> Vector3:
		return opacity
	func set_sky_opacity(value: Vector3) -> bool:
		if not Preferences.valid_opacity(value):
			return false
		opacity = value
		return true

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# Load after autoloads exist: this scene's work-list scripts use Global.
	var main_menu := load("res://Assets/ARSpace/Prefabs/UI/MainMenuCanvas/MainMenuCanvasAR2D.tscn") as PackedScene
	RuntimeProfile.select_session_mode(RuntimeProfile.Preset.SKY_XR_CLIENT)
	var host := TestScene.new()
	host.add_to_group("cabinet_calibration")
	root.add_child(host)
	current_scene = host
	var window := Window.new()
	window.size = Vector2i(620, 460)
	host.add_child(window)
	var menu := main_menu.instantiate()
	window.add_child(menu)
	menu.get_node("Canvas/LifeTabView").hide()
	menu.get_node("Canvas/WorkTabView").show()
	if DisplayServer.get_name() != "headless":
		window.position = Vector2i(-32000, -32000)
		window.show()
	await process_frame
	var entry := menu.get_node_or_null("Canvas/WorkTabView/GridContainer/SkyDisplaySettingsButton") as Button
	_expect(entry != null, "Sky main menu contains display entry")
	var cabinet_entry := menu.get_node("Canvas/WorkTabView/GridContainer/CabinetCalibrationButton") as Button
	cabinet_entry.pressed.emit()
	_expect(host.calibration_parent == menu.get_node("Canvas"), "cabinet entry supplies the main menu for adjacent placement")
	if entry != null:
		await process_frame
		if OS.get_cmdline_user_args().has("--capture-ui"):
			await RenderingServer.frame_post_draw
			window.get_texture().get_image().save_png(OS.get_environment("TEMP").path_join("sky-work-tools-ui.png"))
		entry.pressed.emit()
		var panel := menu.get_node("Canvas/WorkTabView/SkyDisplaySettings") as PanelContainer
		await process_frame
		_expect(panel.size.x <= 446 and panel.size.y <= 348, "settings fit inside existing work area")
		_expect(entry.get_global_rect().position.y > 97, "entry remains below title controls")
		_expect(panel.is_visible_in_tree(), "headset button opens settings inside its existing panel")
		panel.call("_set_opacity", Vector3.ONE)
		_expect(host.opacity == Vector3.ONE, "local preset changes display")
		panel.call("_step_opacity", 0, -5)
		await create_timer(0.2).timeout
		_expect(is_equal_approx(host.opacity.x, 0.95), "controller-friendly +/- adjusts opacity")
		if OS.get_cmdline_user_args().has("--capture-ui"):
			await process_frame
			await RenderingServer.frame_post_draw
			window.get_texture().get_image().save_png(OS.get_environment("TEMP").path_join("sky-display-settings-ui.png"))
		panel.hide()
		_expect(entry.is_visible_in_tree(), "return exposes work cards")
	window.queue_free()
	await process_frame

	var preferences_path := OS.get_environment("TEMP").path_join("sky-display-self-test.cfg")
	_expect(Preferences.save_values(host.opacity, preferences_path) == OK, "settings save to local config")
	var loaded := Preferences.load_values(preferences_path)
	_expect(loaded.opacity == host.opacity, "opacity reloads")
	_expect(Preferences.save_values(Vector3(NAN, 0, 0), preferences_path) == ERR_INVALID_PARAMETER, "invalid save rejected")
	_expect(Preferences.load_values(preferences_path) == loaded, "failed save preserves existing preferences")
	DirAccess.remove_absolute(preferences_path)

	RuntimeProfile.select_session_mode(RuntimeProfile.Preset.PC_GROUND_SERVER)
	var desktop_menu := main_menu.instantiate()
	host.add_child(desktop_menu)
	_expect(desktop_menu.get_node_or_null("Canvas/WorkTabView/GridContainer/SkyDisplaySettingsButton") == null, "PC menu does not expose headset-only controls")
	desktop_menu.queue_free()
	host.queue_free()
	await process_frame
	RuntimeProfile.clear_session_override()
	if failures.is_empty():
		print("Sky display settings self-test passed (headset menu, local opacity, persistence, role isolation).")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
