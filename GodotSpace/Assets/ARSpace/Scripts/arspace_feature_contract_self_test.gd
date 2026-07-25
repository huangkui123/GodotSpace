extends SceneTree

const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const DRAWING_SCENE_PATH := "res://Assets/ARSpace/Scenes/SpatialDrawing/SpatialDrawingSystem.tscn"
const ARSPACE_SCENE_PATH := "res://Assets/ARSpace/Scenes/ARSpace.tscn"

var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	RuntimeProfile.select_session_mode(RuntimeProfile.Preset.PC_GROUND_SERVER, false)
	var arspace := ResourceLoader.load(ARSPACE_SCENE_PATH) as PackedScene
	_check(arspace != null, "ARSpace production scene should load")
	if arspace != null:
		var state := arspace.get_state()
		_check(
			_find_scene_node(state, "SharedSpaceOrigin/SpatialDrawingSystem") >= 0,
			"SpatialDrawingSystem must be mounted directly under SharedSpaceOrigin"
		)

	var drawing_scene := ResourceLoader.load(DRAWING_SCENE_PATH) as PackedScene
	_check(drawing_scene != null, "SpatialDrawing production scene should load")
	if drawing_scene == null:
		_finish()
		return

	var host := Node3D.new()
	host.name = "ContractHost"
	root.add_child(host)
	for iteration in range(100):
		var shared_origin := Node3D.new()
		shared_origin.name = "SharedSpaceOrigin_%d" % iteration
		host.add_child(shared_origin)
		var system := drawing_scene.instantiate() as Node3D
		shared_origin.add_child(system)
		await process_frame
		var manager := system.get_node_or_null("SpatialDrawingManager")
		var renderer := system.get_node_or_null("SpatialDrawingRenderer")
		var interaction := system.get_node_or_null("SpatialDrawingInteraction")
		var panel := system.get_node_or_null("SpatialDrawingPanel3D") as Node3D
		var editor_preview := system.get_node_or_null("EditorPreview")
		_check(manager != null, "production drawing system requires SpatialDrawingManager")
		_check(renderer != null, "production drawing system requires SpatialDrawingRenderer")
		_check(interaction != null, "production drawing system requires SpatialDrawingInteraction")
		_check(panel != null, "production drawing system requires the local XR panel")
		_check(editor_preview != null, "production drawing system requires the editor-only preview host")
		if editor_preview != null:
			_check(
				editor_preview.get_child_count() == 0,
				"editor preview must not generate visual nodes during runtime"
			)
		if manager != null:
			_check(
				manager.call("get_shared_space_origin") == shared_origin,
				"manager coordinates must resolve against the mounted SharedSpaceOrigin"
			)
			_check(not bool(manager.call("can_local_draw")), "PC Ground production manager must be receive-only")
		if panel != null:
			_check(not panel.visible, "PC Ground must not display the local drawing panel")
		shared_origin.queue_free()
		await process_frame
		_check(
			get_nodes_in_group("spatial_drawing_manager").is_empty(),
			"drawing manager group should return to baseline after scene exit"
		)
		_check(
			get_nodes_in_group("spatial_drawing_interaction").is_empty(),
			"drawing interaction group should return to baseline after scene exit"
		)
	host.queue_free()
	await process_frame
	_finish()


func _find_scene_node(state: SceneState, target_path: String) -> int:
	for index in range(state.get_node_count()):
		var path_text := str(state.get_node_path(index))
		if path_text == target_path or path_text.ends_with("/" + target_path):
			return index
	return -1


func _finish() -> void:
	RuntimeProfile.clear_session_override()
	if _failures.is_empty():
		print("ARSPACE_FEATURE_CONTRACT_SELF_TEST PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("ARSPACE_FEATURE_CONTRACT_SELF_TEST: %s" % failure)
	quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
