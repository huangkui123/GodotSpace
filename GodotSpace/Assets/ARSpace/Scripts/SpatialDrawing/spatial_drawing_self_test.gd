extends SceneTree

const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const ManagerScript := preload("res://Assets/ARSpace/Scripts/SpatialDrawing/spatial_drawing_manager.gd")
const RendererScript := preload("res://Assets/ARSpace/Scripts/SpatialDrawing/spatial_stroke_renderer.gd")
const InteractionScript := preload("res://Assets/ARSpace/Scripts/SpatialDrawing/spatial_drawing_interaction.gd")
const SimplifierScript := preload("res://Assets/ARSpace/Scripts/SpatialDrawing/spatial_stroke_simplifier.gd")
const PanelScene := preload("res://Assets/ARSpace/Scenes/SpatialDrawing/SpatialDrawingPanel.tscn")
const TipScene := preload("res://Assets/ARSpace/Scenes/SpatialDrawing/SpatialDrawingTip.tscn")

var _failures: Array[String] = []


class MockLocalWindowDrag extends Node:
	var active: bool = false

	func is_local_drag_active() -> bool:
		return active


class MockPointer extends Node:
	var target: Node
	var last_target: Node


class MockPickup extends Node:
	var picked_up_object: Node3D


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_runtime_permissions()
	_test_sampling_and_simplification()
	_test_mesh_geometry()
	_test_production_visual_components()
	_test_unity_panel_contract()
	await _test_local_workflow()
	RuntimeProfile.clear_session_override()
	if _failures.is_empty():
		print("SPATIAL_DRAWING_SELF_TEST PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("SPATIAL_DRAWING_SELF_TEST: %s" % failure)
	quit(1)


func _test_runtime_permissions() -> void:
	var pc_ground = RuntimeProfile.from_args([], [])
	_check(not pc_ground.can_draw(), "desktop PC Ground must be receive-only for drawing")
	var pc_test = RuntimeProfile.from_args(["--testmode", "--voice-role=server"], ["--testmode", "--voice-role=server"])
	_check(not pc_test.can_draw(), "testmode PC Ground Server must remain receive-only")
	var ground_vr = RuntimeProfile.from_args(
		["--xr-mode", "on", "--ground-vr", "--voice-role=server"],
		["--ground-vr", "--voice-role=server"]
	)
	_check(ground_vr.can_draw(), "Ground VR Server should draw")
	var ground_vr_client = RuntimeProfile.from_args(
		["--xr-mode", "on", "--ground-vr-client", "--voice-role=client"],
		["--ground-vr-client", "--voice-role=client"]
	)
	_check(ground_vr_client.can_draw(), "Ground VR Client should draw")
	var sky_xr = RuntimeProfile.from_args(
		["--xr-mode", "on", "--xr-client", "--voice-role=client"],
		["--xr-client", "--voice-role=client"]
	)
	_check(sky_xr.can_draw(), "Sky XR Client should draw")
	var sky_test = RuntimeProfile.from_args(
		["--testmode", "--voice-role=client"],
		["--testmode", "--voice-role=client"]
	)
	_check(sky_test.can_draw(), "Sky test Client should draw")


func _test_sampling_and_simplification() -> void:
	var points := PackedVector3Array([Vector3.ZERO])
	_check(
		not SimplifierScript.should_sample(points, Vector3(0.001, 0, 0), 20, 0, 0.005, 90),
		"sub-threshold movement before the max interval should not sample"
	)
	_check(
		SimplifierScript.should_sample(points, Vector3(0.001, 0, 0), 100, 0, 0.005, 90),
		"slow movement should sample after the max interval"
	)
	_check(
		SimplifierScript.should_sample(points, Vector3(0.006, 0, 0), 20, 0, 0.005, 90),
		"movement beyond the minimum distance should sample"
	)
	var noisy := PackedVector3Array()
	for index in range(200):
		noisy.append(Vector3(float(index) * 0.01, sin(float(index) * 0.1) * 0.0002, 0.0))
	var simplified: PackedVector3Array = SimplifierScript.simplify(noisy, 0.001, 2048)
	_check(simplified.size() == 2, "nearly straight stroke should simplify to its endpoints")
	_check(simplified[0] == noisy[0], "simplification must preserve the first point")
	_check(simplified[simplified.size() - 1] == noisy[noisy.size() - 1], "simplification must preserve the final point")
	var long_points := PackedVector3Array()
	for index in range(3000):
		long_points.append(Vector3(float(index) * 0.001, sin(float(index) * 0.03) * 0.05, 0.0))
	var bounded: PackedVector3Array = SimplifierScript.simplify(long_points, 0.0, 2048)
	_check(bounded.size() == 2048, "simplification must cap the final point count")
	_check(bounded[0] == long_points[0] and bounded[2047] == long_points[2999], "point cap must preserve endpoints")


func _test_mesh_geometry() -> void:
	var cases: Array[PackedVector3Array] = [
		PackedVector3Array([Vector3.ZERO, Vector3.RIGHT]),
		PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.ZERO]),
		PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3(1, 1, 0), Vector3(1, 1, 1)]),
	]
	for points in cases:
		var mesh: ArrayMesh = RendererScript.build_tube_mesh(points, 0.01, Color.CYAN, 8)
		_check(mesh.get_surface_count() == 1, "valid stroke should produce one mesh surface")
		if mesh.get_surface_count() == 0:
			continue
		var arrays := mesh.surface_get_arrays(0)
		var vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var normals := arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array
		var indices := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
		for vertex in vertices:
			_check(SimplifierScript.is_finite_vector(vertex), "mesh vertices must be finite")
		for normal in normals:
			_check(SimplifierScript.is_finite_vector(normal), "mesh normals must be finite")
			_check(normal.length_squared() > 0.9, "mesh normals must remain normalized")
		for index in range(0, indices.size(), 3):
			var a := vertices[indices[index]]
			var b := vertices[indices[index + 1]]
			var c := vertices[indices[index + 2]]
			_check((b - a).cross(c - a).length_squared() > 0.000000000001, "mesh triangles must not degenerate")
		var aabb := mesh.get_aabb()
		_check(
			SimplifierScript.is_finite_vector(aabb.position) and SimplifierScript.is_finite_vector(aabb.size),
			"mesh AABB must be finite"
		)


func _test_production_visual_components() -> void:
	var tip := TipScene.instantiate() as Node3D
	_check(tip != null, "production drawing tool should instantiate as Node3D")
	if tip != null:
		root.add_child(tip)
		var tool_model := tip.get_node_or_null("ToolModel") as Node3D
		var indicator := tip.get_node_or_null("TipIndicator") as MeshInstance3D
		var sphere := indicator.mesh as SphereMesh if indicator != null else null
		_check(
			tool_model != null \
				and tool_model.find_child("Marker", true, false) is MeshInstance3D,
			"production drawing tool should contain the imported Marker.dae mesh"
		)
		_check(
			tool_model != null \
				and tool_model.scale.is_equal_approx(Vector3(0.2, 0.2, 0.2)) \
				and is_equal_approx(tool_model.rotation.x, -PI * 0.5),
			"production Marker model should use the measured hand-tool scale and orientation"
		)
		_check(
			indicator != null \
				and sphere != null \
				and is_equal_approx(sphere.radius, 0.006) \
				and is_equal_approx(sphere.height, 0.012),
			"production drawing tool should retain its metric nozzle indicator"
		)
		_check(
			indicator != null \
				and indicator.material_override is StandardMaterial3D,
			"production drawing nozzle should carry its runtime emissive material"
		)
		var selected_color := Color(0.04, 0.08, 1.0, 1.0)
		tip.call("set_tool_color", selected_color)
		var body_mesh := tool_model.find_child(
			"Marker",
			true,
			false
		) as MeshInstance3D if tool_model != null else null
		var body_material := body_mesh.material_override as StandardMaterial3D \
			if body_mesh != null \
			else null
		var tip_material := indicator.material_override as StandardMaterial3D \
			if indicator != null \
			else null
		_check(
			body_material != null \
				and body_material.albedo_color.is_equal_approx(selected_color),
			"production Marker body should follow the selected drawing color"
		)
		_check(
			tip_material != null \
				and tip_material.emission.is_equal_approx(selected_color),
			"production nozzle should follow the selected drawing color"
		)
		tip.free()


func _test_unity_panel_contract() -> void:
	var panel := PanelScene.instantiate() as Control
	_check(panel != null, "Unity-style drawing panel should instantiate as Control")
	if panel == null:
		return
	_check(
		panel.size.is_equal_approx(Vector2(760.0, 340.0)),
		"drawing panel should retain the compact 760x340 aspect"
	)
	var mode_label := panel.get_node_or_null(
		"Margin/Layout/Header/ModeRow/ModeLabel"
	) as Label
	_check(
		mode_label != null and mode_label.text == "开始空间绘制",
		"drawing toggle should use the requested Unity label"
	)
	for color_name in ["Red", "Green", "Blue", "Magenta", "Orange"]:
		_check(
			panel.get_node_or_null(
				"Margin/Layout/ToolRow/%s/ColorButton" % color_name
			) is Button,
			"drawing toolbar should expose the Unity color button: %s" % color_name
		)
	_check(
		panel.get_node_or_null("Margin/Layout/ToolRow/Clear/ClearButton") is Button,
		"drawing toolbar should expose the visible all-clear action"
	)
	_check(
		panel.get_node_or_null("Margin/Layout/ToolRow/Sync/SyncButton") is Button,
		"drawing toolbar should expose the visible sync action"
	)
	_check(
		panel.get_node_or_null("ConfirmOverlay") is Control,
		"drawing panel should retain a compact exit confirmation layer"
	)
	var confirm_prompt := panel.get_node_or_null(
		"ConfirmOverlay/Center/Content/Prompt"
	) as Label
	_check(
		confirm_prompt != null and confirm_prompt.text == "是否同步标记？",
		"exit confirmation should retain the Unity marker wording"
	)
	for removed_control in [
		"StatusLabel",
		"CountLabel",
		"ColorOption",
		"WidthSlider",
		"TipSlider",
		"HelpLabel",
	]:
		_check(
			panel.find_child(removed_control, true, false) == null,
			"compact drawing panel should not expose legacy control: %s" % removed_control
		)
	panel.free()


func _test_local_workflow() -> void:
	RuntimeProfile.select_session_mode(RuntimeProfile.Preset.SKY_XR_CLIENT, false)
	var root_node := Node3D.new()
	root_node.name = "DrawingTestRoot"
	root.add_child(root_node)
	var shared_origin := Node3D.new()
	shared_origin.name = "SharedSpaceOrigin"
	root_node.add_child(shared_origin)
	var system := Node3D.new()
	system.name = "SpatialDrawingSystem"
	shared_origin.add_child(system)
	var panel := PanelScene.instantiate() as Control
	root_node.add_child(panel)
	var renderer = RendererScript.new()
	renderer.name = "SpatialDrawingRenderer"
	system.add_child(renderer)
	var manager = ManagerScript.new()
	manager.name = "SpatialDrawingManager"
	manager.shared_space_origin_path = NodePath("../..")
	manager.renderer_path = NodePath("../SpatialDrawingRenderer")
	manager.peer_authority_path = NodePath()
	manager.warn_on_rejection = false
	system.add_child(manager)
	var interaction = InteractionScript.new()
	interaction.name = "SpatialDrawingInteraction"
	interaction.manager_path = NodePath("../SpatialDrawingManager")
	interaction.renderer_path = NodePath("../SpatialDrawingRenderer")
	system.add_child(interaction)
	await process_frame

	_check(manager.can_local_draw(), "immersive local profile should enter drawing")
	_check(interaction.set_drawing_mode(true), "drawing mode should enable")
	var mode_button := panel.get_node(
		"Margin/Layout/Header/ModeRow/ModeButton"
	) as Button
	var toggle_knob := panel.get_node(
		"Margin/Layout/Header/ModeRow/ModeButton/Track/Knob"
	) as Control
	_check(
		mode_button.button_pressed and is_equal_approx(toggle_knob.position.x, 61.0),
		"real panel toggle should reflect the active drawing mode"
	)
	var magenta_button := panel.get_node(
		"Margin/Layout/ToolRow/Magenta/ColorButton"
	) as Button
	magenta_button.pressed.emit()
	_check(
		interaction.get_current_color().is_equal_approx(
			Color(1.0, 0.02, 0.92, 1.0)
		),
		"real magenta button should select the matching Unity palette color"
	)
	_check(interaction.begin_stroke_at_shared_position(Vector3.ZERO), "trigger press should begin a stroke")
	_check(
		not interaction.append_stroke_point(Vector3(0.001, 0, 0), Time.get_ticks_msec()),
		"short movement before interval should not append"
	)
	_check(
		interaction.append_stroke_point(Vector3(0.02, 0, 0), Time.get_ticks_msec() + 1),
		"valid movement should append"
	)
	_check(interaction.finish_stroke(), "trigger release should finish a valid stroke")
	_check(interaction.get_draft_count() == 1, "finished strokes should remain local drafts")
	_check(renderer.get_local_draft_mesh_count() == 1, "local draft should render independently")
	_check(interaction.sync_pending_drafts() == 1, "explicit sync should publish the draft")
	await process_frame
	_check(manager.get_stroke_count() == 1, "Server authority should contain the published stroke")
	_check(interaction.get_draft_count() == 0, "confirmed draft should leave the local queue")
	_check(renderer.get_published_mesh_count() == 1, "published stroke should have a stable mesh")

	interaction.begin_stroke_at_shared_position(Vector3(0, 0.1, 0))
	interaction.append_stroke_point(Vector3(0.1, 0.1, 0), Time.get_ticks_msec() + 100)
	interaction.finish_stroke()
	_check(interaction.undo_last_local_draft(), "undo should remove the newest unsynced draft")
	_check(interaction.get_draft_count() == 0, "undo should not delete published strokes")
	_check(manager.get_stroke_count() == 1, "undo should leave the authoritative set unchanged")

	interaction.begin_stroke_at_shared_position(Vector3(0, 0.2, 0))
	interaction.append_stroke_point(Vector3(0.1, 0.2, 0), Time.get_ticks_msec() + 100)
	interaction.finish_stroke()
	_check(not interaction.request_exit(), "exit with drafts should request confirmation")
	_check(interaction.resolve_exit(false), "discard exit should resolve the prompt")
	_check(interaction.get_draft_count() == 0, "discard exit should clear only local drafts")
	_check(manager.get_stroke_count() == 1, "discard exit must not alter published strokes")
	_check(
		not mode_button.button_pressed and is_equal_approx(toggle_knob.position.x, 9.0),
		"real panel toggle should return to its inactive position after exit"
	)

	var annotation_sentinel := Node.new()
	annotation_sentinel.name = "VirtualAnnotationSentinel"
	shared_origin.add_child(annotation_sentinel)
	var calibration_sentinel := Node.new()
	calibration_sentinel.name = "SpatialCalibrationSentinel"
	shared_origin.add_child(calibration_sentinel)
	interaction.set_drawing_mode(true)
	interaction.begin_stroke_at_shared_position(Vector3(0, 0.3, 0))
	interaction.append_stroke_point(Vector3(0.1, 0.3, 0), Time.get_ticks_msec() + 100)
	interaction.finish_stroke()
	_check(
		interaction.clear_all_drawing(),
		"visible all-clear action should remove local and synchronized drawing"
	)
	_check(interaction.get_draft_count() == 0, "all-clear should remove local drafts")
	_check(manager.get_stroke_count() == 0, "synchronized clear should clear published drawing")
	_check(
		is_instance_valid(annotation_sentinel) and is_instance_valid(calibration_sentinel),
		"drawing clear must not touch annotation or calibration nodes"
	)

	var drag := MockLocalWindowDrag.new()
	drag.add_to_group("spatial_window_controller")
	root_node.add_child(drag)
	drag.active = true
	_check(interaction.is_input_blocked(), "local window drag should block drawing")
	drag.active = false
	var pointer := MockPointer.new()
	var pointer_target := Node3D.new()
	root_node.add_child(pointer_target)
	pointer.target = pointer_target
	root_node.add_child(pointer)
	interaction.set("_function_pointer", pointer)
	_check(interaction.is_input_blocked(), "3D UI pointer target should block drawing")
	pointer.target = null
	var pickup := MockPickup.new()
	var picked := Node3D.new()
	root_node.add_child(picked)
	pickup.picked_up_object = picked
	root_node.add_child(pickup)
	interaction.set("_pickup_node", pickup)
	_check(interaction.is_input_blocked(), "held pickup object should block drawing")

	RuntimeProfile.select_session_mode(RuntimeProfile.Preset.PC_GROUND_SERVER, false)
	_check(not manager.can_local_draw(), "PC Ground Server must not enter drawing mode")
	root_node.queue_free()
	await process_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
