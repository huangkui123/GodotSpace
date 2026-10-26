extends SceneTree

const Profile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
var failures: Array[String] = []


func _initialize() -> void:
	if OS.get_cmdline_user_args().has("--no-cabinet-receiver"):
		node_added.connect(func(node: Node):
			if node.name == "CabinetCalibration":
				node.set("auto_start_receiver", false))
	call_deferred("_run")


func _run() -> void:
	# Exercise the real StartMenu -> ARSpace path without starting AI services.
	var result := change_scene_to_file("res://Assets/ARSpace/Scenes/StartMenu.tscn")
	if result != OK:
		push_error("Cabinet scene test: StartMenu did not load")
		quit(1)
		return
	for _i in range(20):
		await process_frame
		if current_scene != null:
			break
	if current_scene == null:
		push_error("Cabinet scene test: StartMenu initialization timed out")
		quit(1)
		return
	var ui := current_scene.get_node("UI")
	(ui.get("_agent_toggle") as CheckBox).button_pressed = false
	ui.call("_on_start_pressed")
	for _i in range(600):
		await process_frame
		if current_scene != null and current_scene.scene_file_path.ends_with("ARSpace.tscn"):
			break
	if current_scene == null or not current_scene.scene_file_path.ends_with("ARSpace.tscn"):
		push_error("Cabinet scene test: ARSpace was not reached")
		quit(1)
		return
	await process_frame
	var cabinet := current_scene.get_node_or_null("CabinetCalibration")
	var is_sky: bool = Profile.current().is_sky()
	_expect((cabinet != null) == is_sky, "cabinet runtime exists only on Sky")
	var fixed_cabinet := current_scene.get_node_or_null("SharedSpaceOrigin/CalibrationCabinet") as Node3D
	_expect(fixed_cabinet != null, "scene contains reusable solid cabinet")
	if is_sky and cabinet != null:
		_expect(cabinet.get("_cabinet") == fixed_cabinet, "calibration uses authored cabinet instead of spawning a duplicate")
	if fixed_cabinet != null:
		var body := fixed_cabinet.get_node("Body") as MeshInstance3D
		_expect(body.mesh is BoxMesh, "placeholder is a solid cuboid")
		_expect(is_zero_approx((body.global_transform * Vector3(0, -(body.mesh as BoxMesh).size.y * 0.5, 0)).y), "cabinet rests on shared-space floor")
	var button := current_scene.find_child("CabinetCalibrationButton", true, false) as Button
	_expect((button != null) == is_sky, "cabinet entry belongs only to Sky main panel")
	if is_sky and button != null and cabinet != null:
		button.pressed.emit()
		await process_frame
		var panel := cabinet.get("_panel") as Node3D
		_expect(panel != null and panel.visible, "Sky menu opens actual XR surface")
		var content := cabinet.get("_ui") as Control
		_expect(content != null and content.get_viewport() is SubViewport, "calibration content is inside VR viewport")
		_expect(content.name == "CabinetVisualUI", "actual scene entry defaults to CAD recognition")
		_expect(cabinet.call("_visual_frame") == current_scene.get_node("SpaceBox/SpaceBox/dashiyangui/dashiyangui/MeshRenderer"), "CAD aligns to real experimental cabinet anchor")
		_expect(not fixed_cabinet.visible, "CAD mode hides the custom cuboid")
		(content.get("_kind") as OptionButton).select(1)
		content.call("_options_changed")
		_expect(fixed_cabinet.visible, "custom mode displays the dimensioned cuboid")
		_expect((fixed_cabinet.get("dimensions") as Vector3).is_equal_approx(Vector3(0.45, 1.21, 0.8)), "custom scene dimensions match cm defaults")
		_expect(not (cabinet.call("_visual_target") as Node3D).visible, "custom mode hides the CAD cabinet")
		current_scene.call("set_sky_opacity", Vector3.ZERO)
		var mesh := panel.get_node("Screen") as MeshInstance3D
		_expect(not mesh.has_meta(current_scene.SKY_TRANSPARENCY_STATE_META), "calibration UI remains readable when objects are faded")
		cabinet.call("close_panel")
		await process_frame
		_expect(not panel.visible, "closing panel hides local surface")
	if OS.get_cmdline_user_args().has("--capture-cabinet"):
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OS.get_environment("TEMP").path_join("fixed-cabinet-scene.png"))
	if OS.get_cmdline_user_args().has("--hold-server"):
		print("[CabinetSceneTest] Server ready; no cabinet calibration controller or menu")
		await create_timer(50.0).timeout
	if OS.get_cmdline_user_args().has("--hold-client"):
		await create_timer(10.0).timeout
	var scene := current_scene
	current_scene = null
	# Match change_scene_to_file: detach immediately, then free deferred. A
	# process_frame signal alone can precede the queued deletion flush.
	root.remove_child(scene)
	scene.queue_free()
	await process_frame
	_expect(get_first_node_in_group("cabinet_calibration") == null, "scene exit removes runtime and preview")
	if failures.is_empty():
		print("Cabinet scene self-test passed (StartMenu -> ARSpace, role ownership, XR panel, cleanup).")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _expect(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
