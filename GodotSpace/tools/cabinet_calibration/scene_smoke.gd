extends SceneTree

## Opens the real StartMenu, starts a local PC server, and verifies the new
## capture control in ARSpace. Run only when ports 42069/8787/8791 are available.
func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(30.0).timeout.connect(func() -> void:
		push_error("Cabinet scene smoke timed out")
		quit(1)
	)
	var menu_scene := load("res://Assets/ARSpace/Scenes/StartMenu.tscn") as PackedScene
	var menu := menu_scene.instantiate()
	root.add_child(menu)
	current_scene = menu
	menu.get_node("UI").call("_on_start_pressed")
	for index in range(12):
		await process_frame
	if current_scene == null or not current_scene.scene_file_path.ends_with("/ARSpace.tscn"):
		push_error("StartMenu did not enter ARSpace")
		quit(1)
		return
	var panel := current_scene.find_child("CalibrationSection", true, false)
	if panel == null:
		push_error("CalibrationSection missing")
		quit(1)
		return
	var capture_button := panel.find_child("CabinetVisualCaptureButton", true, false) as Button
	var capture_status := panel.find_child("CabinetVisualCaptureStatus", true, false) as Label
	if capture_button == null or capture_status == null:
		push_error("Cabinet capture controls missing")
		quit(1)
		return
	capture_button.pressed.emit()
	if not capture_status.text.contains("没有可保存"):
		push_error("Empty capture should explain that no PICO frame is available")
		quit(1)
		return
	print("Cabinet StartMenu -> ARSpace capture UI smoke passed")
	current_scene.queue_free()
	current_scene = null
	await process_frame
	quit(0)
