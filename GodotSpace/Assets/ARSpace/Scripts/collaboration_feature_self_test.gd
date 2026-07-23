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
	"res://Assets/ARSpace/Scenes/SpatialWindows/WindowDockSlot3D.tscn",
	"res://Assets/ARSpace/Scripts/SpatialWindows/spatial_viewport_2d_in_3d.gd",
	"res://Assets/ARSpace/Scripts/SpatialWindows/spatial_viewport_2d_in_3d_body.gd",
	"res://Assets/ARSpace/Scripts/SpatialWindows/spatial_window_controller.gd",
	"res://Assets/ARSpace/Scripts/SpatialWindows/window_dock_manager.gd",
	"res://Assets/ARSpace/Scripts/SpatialWindows/spatial_window_state_manager.gd",
	"res://Assets/ARSpace/Scripts/UI/shared_main_menu_state.gd",
	"res://Assets/ARSpace/Scripts/UI/shared_main_menu_state_self_test.gd",
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
		"[node name=\"SpatialWindows\"",
		"[node name=\"MainMenuState\"",
		"[node name=\"WindowDockSlots\"",
		"slot_id = &\"wall_a\"",
		"slot_id = &\"wall_b\"",
		"slot_id = &\"wall_c\"",
		"slot_id = &\"wall_d\"",
		"slot_id = &\"wall_e\"",
		"slot_id = &\"wall_f\"",
		"slot_id = &\"wall_g\"",
		"slot_id = &\"wall_h\"",
		"slot_id = &\"wall_i\"",
		"slot_id = &\"wall_j\"",
		"slot_id = &\"wall_k\"",
		"slot_id = &\"wall_l\"",
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
		"SharedSpaceOrigin/SpatialWindows",
		"SharedSpaceOrigin/SpatialWindows/Manager",
		"SharedSpaceOrigin/SpatialWindows/MainMenuState",
		"SharedSpaceOrigin/WindowDockSlots",
		"SharedSpaceOrigin/WindowDockSlots/WallSlotA",
		"SharedSpaceOrigin/WindowDockSlots/WallSlotB",
		"SharedSpaceOrigin/WindowDockSlots/WallSlotC",
		"SharedSpaceOrigin/WindowDockSlots/WallSlotD",
		"SharedSpaceOrigin/WindowDockSlots/WallSlotE",
		"SharedSpaceOrigin/WindowDockSlots/WallSlotF",
		"SharedSpaceOrigin/WindowDockSlots/WallSlotG",
		"SharedSpaceOrigin/WindowDockSlots/WallSlotH",
		"SharedSpaceOrigin/WindowDockSlots/WallSlotI",
		"SharedSpaceOrigin/WindowDockSlots/WallSlotJ",
		"SharedSpaceOrigin/WindowDockSlots/WallSlotK",
		"SharedSpaceOrigin/WindowDockSlots/WallSlotL",
		"MainMenuCanvas/SpatialWindowController",
		"GroupUI/PictureCanvas/SpatialWindowController",
		"GroupUI/PictureInfoCanvas/SpatialWindowController",
		"GroupUI/MovieCanvas/SpatialWindowController",
		"GroupUI/MovieInfoCanvas/SpatialWindowController",
		"GroupUI/WorkListInfoCanvas/SpatialWindowController",
		"GroupUI/VoiceCallWindow3D/SpatialWindowController",
		"SharedSpaceAlignment",
		"MultiplayerSpawner",
		"UI/ControlPanelUI/PanelRoot/Sidebar/SidebarMargin/SidebarButtons/AnnotationButton",
		"UI/ControlPanelUI/PanelRoot/ContentPanel/ContentMargin/Sections/AnnotationSection",
	]:
		_expect(_find_scene_node(arspace_state, node_path) >= 0, "ARSpace scene-state path is missing: %s" % node_path)
	for shared_controller_path in [
		"MainMenuCanvas/SpatialWindowController",
		"GroupUI/PictureCanvas/SpatialWindowController",
		"GroupUI/PictureInfoCanvas/SpatialWindowController",
		"GroupUI/MovieCanvas/SpatialWindowController",
		"GroupUI/MovieInfoCanvas/SpatialWindowController",
		"GroupUI/WorkListInfoCanvas/SpatialWindowController",
		"GroupUI/VoiceCallWindow3D/SpatialWindowController",
	]:
		var controller_index := _find_scene_node(arspace_state, shared_controller_path)
		if controller_index >= 0:
			var scope_value = _get_scene_node_property(
				arspace_state,
				controller_index,
				&"scope"
			)
			_expect(
				scope_value == null or int(scope_value) == 1,
				"business spatial window must use SHARED scope: %s" % shared_controller_path
			)
	for window_contract in [
		["MainMenuCanvas", Vector2(620.0, 460.0), Vector2(0.877435, 0.651)],
		["GroupUI/PictureCanvas", Vector2(610.0, 460.0), Vector2(0.863283, 0.651)],
		["GroupUI/PictureInfoCanvas", Vector2(610.0, 460.0), Vector2(0.863283, 0.651)],
		["GroupUI/MovieCanvas", Vector2(610.0, 460.0), Vector2(0.863283, 0.651)],
		["GroupUI/MovieInfoCanvas", Vector2(610.0, 460.0), Vector2(0.863283, 0.651)],
		["GroupUI/WorkListInfoCanvas", Vector2(610.0, 460.0), Vector2(0.863283, 0.651)],
		["GroupUI/VoiceCallWindow3D", Vector2(571.0, 504.0), Vector2(0.737542, 0.651)],
	]:
		var window_path: String = window_contract[0]
		var screen_size: Vector2 = window_contract[1]
		var expected_size_m: Vector2 = window_contract[2]
		var window_index := _find_scene_node(arspace_state, window_path)
		var controller_index := _find_scene_node(
			arspace_state,
			"%s/SpatialWindowController" % window_path
		)
		if window_index < 0 or controller_index < 0:
			continue
		var window_transform = _get_scene_node_property(
			arspace_state,
			window_index,
			&"transform"
		)
		var configured_size = _get_scene_node_property(
			arspace_state,
			controller_index,
			&"window_size_m"
		)
		_expect(
			configured_size is Vector2 \
				and (configured_size as Vector2).is_equal_approx(expected_size_m),
			"business window size must match the Astronaut height contract: %s" % window_path
		)
		if window_transform is Transform3D:
			var initial_scale: Vector3 = (window_transform as Transform3D).basis.get_scale()
			var physical_size := Vector2(
				screen_size.x * initial_scale.x,
				screen_size.y * initial_scale.y
			)
			_expect(
				physical_size.is_equal_approx(expected_size_m),
				"business window transform and configured physical size disagree: %s" % window_path
			)
	var dock_slots_index := _find_scene_node(
		arspace_state,
		"SharedSpaceOrigin/WindowDockSlots"
	)
	if dock_slots_index >= 0:
		var production_slot_names := [
			"WallSlotA",
			"WallSlotB",
			"WallSlotC",
			"WallSlotD",
			"WallSlotE",
			"WallSlotF",
			"WallSlotG",
			"WallSlotH",
			"WallSlotI",
			"WallSlotJ",
			"WallSlotK",
			"WallSlotL",
		]
		for slot_name in production_slot_names:
			var slot_index := _find_scene_node(
				arspace_state,
				"SharedSpaceOrigin/WindowDockSlots/%s" % slot_name
			)
			if slot_index < 0:
				continue
			var target_size = _get_scene_node_property(
				arspace_state,
				slot_index,
				&"target_size_m"
			)
			_expect(
				target_size is Vector2 \
					and (target_size as Vector2).is_equal_approx(
						Vector2(1.119598, 1.064966)
					),
				"production dock slot must match the Unity Adsorb size: %s" % slot_name
			)
		var dock_slots_transform = _get_scene_node_property(
			arspace_state,
			dock_slots_index,
			&"transform"
		)
		if dock_slots_transform is Transform3D:
			for slot_pair in [
				["WallSlotA", "WallSlotD"],
				["WallSlotB", "WallSlotE"],
				["WallSlotC", "WallSlotF"],
				["WallSlotG", "WallSlotJ"],
				["WallSlotH", "WallSlotK"],
				["WallSlotI", "WallSlotL"],
			]:
				var left_index := _find_scene_node(
					arspace_state,
					"SharedSpaceOrigin/WindowDockSlots/%s" % slot_pair[0]
				)
				var right_index := _find_scene_node(
					arspace_state,
					"SharedSpaceOrigin/WindowDockSlots/%s" % slot_pair[1]
				)
				if left_index < 0 or right_index < 0:
					continue
				var left_local = _get_scene_node_property(arspace_state, left_index, &"transform")
				var right_local = _get_scene_node_property(arspace_state, right_index, &"transform")
				if left_local is Transform3D and right_local is Transform3D:
					var left_global: Transform3D = dock_slots_transform * left_local
					var right_global: Transform3D = dock_slots_transform * right_local
					_expect(
						right_global.origin.is_equal_approx(Vector3(
							-left_global.origin.x,
							left_global.origin.y,
							left_global.origin.z
						)),
						"right-wall slot must mirror its left-wall pair: %s/%s left=%s right=%s" % [
							slot_pair[0],
							slot_pair[1],
							left_global.origin,
							right_global.origin,
						]
					)
					_expect(
						left_global.basis.z.normalized().dot(
							right_global.basis.z.normalized()
						) < -0.999,
						"mirrored wall slots must face opposite directions: %s/%s" % slot_pair
					)
			for row in [
				["WallSlotA", "WallSlotB", "WallSlotC"],
				["WallSlotD", "WallSlotE", "WallSlotF"],
				["WallSlotG", "WallSlotH", "WallSlotI"],
				["WallSlotJ", "WallSlotK", "WallSlotL"],
			]:
				var row_transforms: Array[Transform3D] = []
				for slot_name in row:
					var slot_index := _find_scene_node(
						arspace_state,
						"SharedSpaceOrigin/WindowDockSlots/%s" % slot_name
					)
					var transform_value = _get_scene_node_property(
						arspace_state,
						slot_index,
						&"transform"
					) if slot_index >= 0 else null
					if transform_value is Transform3D:
						row_transforms.append(transform_value as Transform3D)
				if row_transforms.size() == 3:
					_expect(
						is_equal_approx(
							row_transforms[0].origin.distance_to(row_transforms[1].origin),
							1.2
						) and is_equal_approx(
							row_transforms[1].origin.distance_to(row_transforms[2].origin),
							1.2
						),
						"each Unity-style dock row must use 1.2 m column spacing: %s" % [row]
					)
			for vertical_pair in [
				["WallSlotA", "WallSlotG"],
				["WallSlotB", "WallSlotH"],
				["WallSlotC", "WallSlotI"],
				["WallSlotD", "WallSlotJ"],
				["WallSlotE", "WallSlotK"],
				["WallSlotF", "WallSlotL"],
			]:
				var upper_index := _find_scene_node(
					arspace_state,
					"SharedSpaceOrigin/WindowDockSlots/%s" % vertical_pair[0]
				)
				var lower_index := _find_scene_node(
					arspace_state,
					"SharedSpaceOrigin/WindowDockSlots/%s" % vertical_pair[1]
				)
				var upper_transform = _get_scene_node_property(
					arspace_state,
					upper_index,
					&"transform"
				) if upper_index >= 0 else null
				var lower_transform = _get_scene_node_property(
					arspace_state,
					lower_index,
					&"transform"
				) if lower_index >= 0 else null
				_expect(
					upper_transform is Transform3D \
						and lower_transform is Transform3D \
						and (
							(upper_transform as Transform3D).origin \
								- (lower_transform as Transform3D).origin
						).is_equal_approx(Vector3.UP),
					"Unity-style dock rows must use 1.0 m vertical spacing: %s/%s" \
						% vertical_pair
				)
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
	var spatial_viewport_source := _read_text(
		"res://Assets/ARSpace/Scripts/SpatialWindows/spatial_viewport_2d_in_3d.gd"
	)
	for blocked_rpc in [
		"func server_receive_pointer_event",
		"func server_receive_window_transform",
		"func server_receive_window_transform_reliable",
	]:
		_expect(
			spatial_viewport_source.contains(blocked_rpc),
			"spatial viewport adapter must block legacy RPC entry point: %s" % blocked_rpc
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
	_expect(
		str(ProjectSettings.get_setting("layer_names/3d_physics/layer_26", "")) == "WindowDockSlot",
		"physics layer 26 must be reserved exclusively for WindowDockSlot"
	)
	var astronaut_window_text := _read_text(
		"res://Assets/ARSpace/Scenes/AstronautView/AstronautViewWindow3D.tscn"
	)
	_expect(
		astronaut_window_text.contains("allow_window_drag = false"),
		"astronaut WindowSurface must disable the vendored drag owner"
	)
	_expect(
		astronaut_window_text.contains("window_id = &\"astronaut_view\"") \
			and astronaut_window_text.contains("scope = 0"),
		"astronaut view must be the explicit LOCAL_GROUND_VR spatial window"
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
