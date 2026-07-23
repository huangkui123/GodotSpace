extends SceneTree

const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const REQUIRED_RESOURCES := [
	"res://Assets/ARSpace/Scenes/ARSpace.tscn",
	"res://Assets/ARSpace/Scenes/Player.tscn",
	"res://Assets/ARSpace/Scenes/StartMenu.tscn",
	"res://Assets/ARSpace/Scenes/VirtualAnnotationMarker.tscn",
	"res://Assets/ARSpace/Scenes/VirtualAnnotationSystem.tscn",
	"res://Assets/ARSpace/Scenes/Tests/CollaborationMultiprocessPeer.tscn",
	"res://Assets/ARSpace/Scripts/shared_space_alignment.gd",
	"res://Assets/ARSpace/Scripts/Network/collaboration_multiprocess_peer.gd",
	"res://Assets/ARSpace/Scripts/Network/network_startup_recovery_self_test.gd",
	"res://Assets/ARSpace/Scripts/VirtualAnnotation/virtual_annotation_manager.gd",
	"res://Assets/ARSpace/Scripts/VirtualAnnotation/virtual_annotation_surface_builder.gd",
	"res://Assets/ARSpace/Scripts/VirtualAnnotation/virtual_annotation_interaction_controller.gd",
]

var _failures: PackedStringArray = []


func _initialize() -> void:
	_test_resources_load()
	_test_runtime_contract()
	_test_scene_contract()
	_test_input_and_layer_contract()
	_test_voice_secret_hygiene()

	if _failures.is_empty():
		print("COLLABORATION_FEATURE_SELF_TEST PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("COLLABORATION_FEATURE_SELF_TEST: %s" % failure)
	quit(1)


func _test_resources_load() -> void:
	for path in REQUIRED_RESOURCES:
		_expect(ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) != null, "failed to load %s" % path)


func _test_runtime_contract() -> void:
	var pc_ground = RuntimeProfile.from_args([], ["--voice-role=server"], false)
	var vr_ground = RuntimeProfile.from_args(
		["--xr-mode", "on", "--ground-vr", "--voice-role=server"],
		["--ground-vr", "--voice-role=server"],
		false
	)
	var sky_xr = RuntimeProfile.from_args(
		["--xr-mode", "on", "--xr-client", "--voice-role=client"],
		["--xr-client", "--voice-role=client"],
		false
	)
	var vr_ground_client = RuntimeProfile.from_args(
		["--xr-mode", "on", "--ground-vr-client", "--voice-role=client"],
		["--ground-vr-client", "--voice-role=client"],
		false
	)
	_expect(pc_ground.is_server() and pc_ground.is_ground() and pc_ground.can_annotate(), "PC Ground profile contract failed")
	_expect(vr_ground.is_server() and vr_ground.uses_xr() and not vr_ground.uses_passthrough(), "VR Ground profile contract failed")
	_expect(vr_ground_client.is_client() and vr_ground_client.is_ground(), "VR Ground Client role contract failed")
	_expect(vr_ground_client.uses_xr() and not vr_ground_client.uses_passthrough() and vr_ground_client.can_annotate(), "VR Ground Client capability contract failed")
	_expect(sky_xr.is_client() and sky_xr.is_sky() and sky_xr.uses_passthrough(), "Sky XR profile contract failed")
	_expect(not sky_xr.can_annotate(), "Sky XR must remain view-only")


func _test_scene_contract() -> void:
	var scene_text := _read_text("res://Assets/ARSpace/Scenes/ARSpace.tscn")
	for fragment in [
		"[node name=\"SharedSpaceOrigin\"",
		"groups=[\"shared_space_origin\"]",
		"[node name=\"GroundVRAnchor\"",
		"[node name=\"SkyXRAnchor\"",
		"[node name=\"VirtualAnnotations\"",
		"[node name=\"SharedSpaceAlignment\"",
		"[node name=\"MultiplayerSpawner\"",
		"[node name=\"AnnotationButton\"",
		"groups=[\"virtual_annotation_panel\"]",
		"virtual_annotation_surface_precise",
		"virtual_annotation_surface_low_poly",
	]:
		_expect(scene_text.contains(fragment), "ARSpace is missing contract fragment: %s" % fragment)
	_expect(not scene_text.contains("[node name=\"StartXR\""), "ARSpace must not contain a duplicate StartXR node")
	var arspace := ResourceLoader.load("res://Assets/ARSpace/Scenes/ARSpace.tscn") as PackedScene
	var arspace_state := arspace.get_state()
	for node_path in [
		"SharedSpaceOrigin",
		"SharedSpaceOrigin/GroundVRAnchor",
		"SharedSpaceOrigin/SkyXRAnchor",
		"SharedSpaceOrigin/VirtualAnnotations",
		"SharedSpaceAlignment",
		"MultiplayerSpawner",
		"UI/ControlPanelUI/PanelRoot/Sidebar/SidebarMargin/SidebarButtons/AnnotationButton",
		"UI/ControlPanelUI/PanelRoot/ContentPanel/ContentMargin/Sections/AnnotationSection",
	]:
		_expect(_find_scene_node(arspace_state, node_path) >= 0, "ARSpace scene-state path is missing: %s" % node_path)
	var spawner_index := _find_scene_node(arspace_state, "MultiplayerSpawner")
	if spawner_index >= 0:
		var player_scene = _get_scene_node_property(arspace_state, spawner_index, &"network_player")
		_expect(player_scene is PackedScene and (player_scene as PackedScene).resource_path.ends_with("/Player.tscn"), "MultiplayerSpawner must use Player.tscn")
	var ground_anchor_index := _find_scene_node(arspace_state, "SharedSpaceOrigin/GroundVRAnchor")
	var sky_anchor_index := _find_scene_node(arspace_state, "SharedSpaceOrigin/SkyXRAnchor")
	if ground_anchor_index >= 0 and sky_anchor_index >= 0:
		var ground_anchor_transform = _get_scene_node_property(arspace_state, ground_anchor_index, &"transform")
		var sky_anchor_transform = _get_scene_node_property(arspace_state, sky_anchor_index, &"transform")
		_expect(
			ground_anchor_transform is Transform3D \
				and sky_anchor_transform is Transform3D \
				and (ground_anchor_transform as Transform3D).basis.is_equal_approx(
					(sky_anchor_transform as Transform3D).basis
				),
			"Ground VR and Sky XR anchors must use the same initial orientation"
		)

	var system_text := _read_text("res://Assets/ARSpace/Scenes/VirtualAnnotationSystem.tscn")
	for child_name in ["Manager", "SurfaceBuilder", "Interaction"]:
		_expect(system_text.contains("[node name=\"%s\"" % child_name), "annotation system is missing %s" % child_name)
	var annotation_system := ResourceLoader.load("res://Assets/ARSpace/Scenes/VirtualAnnotationSystem.tscn") as PackedScene
	var annotation_state := annotation_system.get_state()
	for child_path in ["Manager", "SurfaceBuilder", "Interaction"]:
		_expect(_find_scene_node(annotation_state, child_path) >= 0, "annotation scene-state path is missing: %s" % child_path)

	var interaction_source := _read_text(
		"res://Assets/ARSpace/Scripts/VirtualAnnotation/virtual_annotation_interaction_controller.gd"
	)
	_expect(
		interaction_source.contains("virtual_annotation_panel"),
		"annotation interaction must bind the ControlPanelUI annotation section"
	)
	_expect(
		not interaction_source.contains("CanvasLayer.new()"),
		"annotation interaction must not create an independent CanvasLayer window"
	)
	var unified_panel_source := _read_text("res://Assets/ARSpace/Scripts/UI/unified_panel_ui.gd")
	_expect(
		unified_panel_source.contains("PANEL_ANNOTATION"),
		"ControlPanelUI must expose the annotation panel"
	)
	_expect(
		unified_panel_source.contains("control is PanelContainer"),
		"ControlPanelUI panels must block pointer clicks from reaching 3D annotation rays"
	)


func _test_input_and_layer_contract() -> void:
	_expect(
		str(ProjectSettings.get_setting("layer_names/3d_physics/layer_24", "")) == "VirtualAnnotationSurface",
		"physics layer 24 must be VirtualAnnotationSurface"
	)
	_expect(
		str(ProjectSettings.get_setting("layer_names/3d_physics/layer_25", "")) == "VirtualAnnotationMarker",
		"physics layer 25 must be VirtualAnnotationMarker"
	)
	var action_map := _read_text("res://openxr_action_map.tres")
	for action_name in ["trigger", "grip", "ax_button", "by_button", "menu_button"]:
		_expect(action_map.contains("resource_name = \"%s\"" % action_name), "OpenXR action is missing: %s" % action_name)


func _test_voice_secret_hygiene() -> void:
	var voice_scene := _read_text("res://Assets/ARSpace/Scenes/voice_chat_service.tscn")
	for property_name in ["app_id", "secret_id", "secret_key"]:
		_expect(not voice_scene.contains("%s =" % property_name), "voice scene still serializes %s" % property_name)
	var transcriber_text := _read_text("res://Assets/ARSpace/Scripts/Network/tencent_asr_transcriber.gd")
	for environment_name in ["TENCENT_ASR_APP_ID", "TENCENT_ASR_SECRET_ID", "TENCENT_ASR_SECRET_KEY"]:
		_expect(transcriber_text.contains(environment_name), "transcriber is missing environment lookup: %s" % environment_name)


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_failures.append("failed to open %s" % path)
		return ""
	return file.get_as_text()


func _find_scene_node(state: SceneState, expected_path: String) -> int:
	for index in range(state.get_node_count()):
		var path_text := str(state.get_node_path(index))
		if path_text == expected_path or path_text.ends_with("/" + expected_path):
			return index
	return -1


func _get_scene_node_property(state: SceneState, node_index: int, property_name: StringName) -> Variant:
	for property_index in range(state.get_node_property_count(node_index)):
		if state.get_node_property_name(node_index, property_index) == property_name:
			return state.get_node_property_value(node_index, property_index)
	return null


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
