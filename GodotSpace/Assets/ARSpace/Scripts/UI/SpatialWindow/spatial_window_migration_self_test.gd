extends SceneTree

const ADAPTER_SCRIPT_PATH := "res://Assets/ARSpace/Scripts/UI/SpatialWindow/spatial_window_adapter.gd"
const SNAP_ZONE_SCRIPT_PATH := "res://Assets/ARSpace/Scripts/UI/SpatialWindow/spatial_window_snap_zone.gd"

const REQUIRED_WINDOWS: Dictionary = {
	"SharedSpaceOrigin/MainMenuCanvas/SpatialWindowAdapter": "main_menu",
	"SharedSpaceOrigin/GroupUI/PictureCanvas/SpatialWindowAdapter": "picture_browser",
	"SharedSpaceOrigin/GroupUI/PictureInfoCanvas/SpatialWindowAdapter": "picture_detail",
	"SharedSpaceOrigin/GroupUI/MovieCanvas/SpatialWindowAdapter": "movie_browser",
	"SharedSpaceOrigin/GroupUI/MovieInfoCanvas/SpatialWindowAdapter": "movie_detail",
	"SharedSpaceOrigin/GroupUI/WorkListInfoCanvas/SpatialWindowAdapter": "work_list",
	"SharedSpaceOrigin/GroupUI/VoiceCallWindow3D/SpatialWindowAdapter": "voice_call",
}

const MIGRATED_UI_SCRIPTS: Array[String] = [
	"res://Assets/ARSpace/Prefabs/UI/MainMenuCanvas/canvas.gd",
	"res://Assets/ARSpace/Scripts/PictureCanvas/PictureUIView.gd",
	"res://Assets/ARSpace/Scripts/PictureCanvas/PictureInfoUIView.gd",
	"res://Assets/ARSpace/Scripts/MovieCanvas/MovieUIView.gd",
	"res://Assets/ARSpace/Scripts/MovieCanvas/MovieInfoUIView.gd",
	"res://Assets/ARSpace/Scripts/WorkListCanvas/WorkListItem.gd",
	"res://Assets/ARSpace/Scripts/WorkListCanvas/WorkListInfoUIView.gd",
	"res://Assets/ARSpace/Scripts/Network/voice_chat_ui.gd",
]

var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_scene_window_adapters()
	_test_ui_entry_points()
	_test_legacy_rpc_boundary()
	_test_autoload_registration()
	_finish()


func _test_scene_window_adapters() -> void:
	var scene_source := _read_resource_text("res://Assets/ARSpace/Scenes/ARSpace.tscn")
	_expect(not scene_source.is_empty(), "ARSpace scene source must be readable.")
	_expect(ADAPTER_SCRIPT_PATH in scene_source, "ARSpace must declare the SpatialWindowAdapter resource.")
	var found_ids: Dictionary = {}
	for adapter_path in REQUIRED_WINDOWS:
		var full_path := str(adapter_path)
		var parent_path := full_path.trim_suffix("/SpatialWindowAdapter")
		var marker := "[node name=\"SpatialWindowAdapter\" type=\"Node\" parent=\"%s\"]" % parent_path
		var marker_offset := scene_source.find(marker)
		_expect(marker_offset >= 0, "ARSpace must contain migrated window adapter: %s" % adapter_path)
		if marker_offset < 0:
			continue
		var block_end := scene_source.find("\n\n[", marker_offset)
		if block_end < 0:
			block_end = scene_source.length()
		var node_block := scene_source.substr(marker_offset, block_end - marker_offset)
		_expect("script = ExtResource(" in node_block, "Migrated window must use SpatialWindowAdapter: %s" % adapter_path)
		var window_id := str(REQUIRED_WINDOWS[adapter_path])
		_expect(("window_id = \"%s\"" % window_id) in node_block, "Migrated window ID changed at %s." % adapter_path)
		_expect(not found_ids.has(window_id), "Spatial window IDs must be unique: %s" % window_id)
		found_ids[window_id] = true
		_expect("default_size_m = Vector2(" in node_block, "Migrated window dimensions must use physical metres: %s" % window_id)
	_expect("[node name=\"MainMenuCanvas\" parent=\".\"" not in scene_source, "Main menu must not remain outside SharedSpaceOrigin.")
	_expect("[node name=\"GroupUI\" type=\"Node3D\" parent=\".\"]" not in scene_source, "Migrated window group must not remain outside SharedSpaceOrigin.")
	_expect(SNAP_ZONE_SCRIPT_PATH in scene_source, "ARSpace must declare reusable spatial snap zones.")
	_expect("[node name=\"SpatialWindowSnapZones\" type=\"Node3D\" parent=\"SharedSpaceOrigin\"]" in scene_source, "Snap zones must share the calibrated origin.")
	_expect(scene_source.count("script = ExtResource(\"75_snap_zone\")") == 3, "ARSpace must expose left, center and right authoritative snap slots.")


func _test_ui_entry_points() -> void:
	for path in MIGRATED_UI_SCRIPTS:
		var source := _read_resource_text(path)
		_expect(not source.is_empty(), "Migrated UI script must be readable: %s" % path)
		_expect("PanelWindowZoom" in source, "Migrated UI must route through the shared window facade: %s" % path)
	var facade := _read_resource_text("res://Assets/ARSpace/Scripts/UI/panel_window_zoom.gd")
	_expect("request_toggle_maximized" in facade and "request_visibility" in facade, "PanelWindowZoom must delegate mode and visibility to SpatialWindowAdapter.")
	_expect("META_ORIGINAL_SCALE" not in facade and "* zoom_factor" not in facade, "The legacy fixed-scale maximize implementation must stay removed.")


func _test_legacy_rpc_boundary() -> void:
	var renderer := _read_resource_text("res://addons/godot-xr-tools/objects/viewport_2d_in_3d.gd")
	var body := _read_resource_text("res://addons/godot-xr-tools/objects/viewport_2d_in_3d_body.gd")
	_expect("func _uses_application_window_registry" in renderer, "XR Tools viewport bridge must identify application-managed windows.")
	_expect(renderer.count("if _uses_application_window_registry():") >= 5, "Application-managed windows must bypass every legacy transform RPC direction.")
	_expect("func _uses_application_window_registry" in body, "XR Tools viewport body must identify application-managed windows.")
	_expect(body.count("if _uses_application_window_registry():") >= 2, "Application-managed pointer input must stay local and bypass synthetic pointer RPCs.")
	var adapter := _read_resource_text(ADAPTER_SCRIPT_PATH)
	_expect("_on_window_pointer_event" in adapter and "begin_far_ray_drag" in adapter and "begin_near_title_drag" in adapter, "Migrated windows must bridge real pointer events into shared near/far interaction semantics.")
	_expect("project_ray_origin" in adapter and "direct_space_state.intersect_ray" in adapter, "Desktop mouse rays must enter the same migrated window interaction bridge.")


func _test_autoload_registration() -> void:
	var project_source := _read_resource_text("res://project.godot")
	_expect("SpatialWindowRegistryService=\"*res://Assets/ARSpace/Scripts/UI/SpatialWindow/spatial_window_registry.gd\"" in project_source, "SpatialWindowRegistryService must be a project autoload.")
	_expect("SpatialWindowInteractorService=\"*res://Assets/ARSpace/Scripts/UI/SpatialWindow/spatial_window_interactor.gd\"" in project_source, "SpatialWindowInteractorService must be a project autoload.")


func _read_resource_text(resource_path: String) -> String:
	var file := FileAccess.open(resource_path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
		push_error(message)


func _finish() -> void:
	if _failures.is_empty():
		print("Spatial window migration self-test passed.")
		quit(0)
		return
	print("Spatial window migration self-test failed with %d error(s)." % _failures.size())
	quit(1)
