extends SceneTree

const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const RESOURCE_PATHS := [
	"res://Assets/ARSpace/Scripts/runtime_profile.gd",
	"res://Assets/ARSpace/Scripts/shared_space_alignment.gd",
	"res://Assets/ARSpace/Scenes/startmenu_ui.gd",
	"res://Assets/ARSpace/Scenes/StartMenu.tscn",
	"res://Assets/ARSpace/Scripts/Network/network_handler.gd",
	"res://Assets/ARSpace/Scripts/Network/voice_chat_ui.gd",
	"res://Assets/ARSpace/Scripts/UI/unified_panel_ui.gd",
	"res://Assets/ARSpace/Scenes/SpaceBox.gd",
	"res://XR_Main.gd",
]


func _initialize() -> void:
	var failures: PackedStringArray = []
	for path in RESOURCE_PATHS:
		var resource := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if resource == null:
			failures.append("Failed to load %s" % path)

	var xr_main_source := FileAccess.get_file_as_string("res://XR_Main.gd")
	var exit_tree_index := xr_main_source.find("func _exit_tree() -> void:")
	var exit_tree_block := xr_main_source.substr(exit_tree_index, 120) if exit_tree_index >= 0 else ""
	if not exit_tree_block.contains("_shutdown_openxr()"):
		failures.append("XR_Main must shut OpenXR down when leaving ARSpace")
	if not xr_main_source.contains("OpenXR runtime became unavailable"):
		failures.append("XR_Main must handle an OpenXR runtime loss")
	if not xr_main_source.contains("XR_RETRY_INTERVAL_MS"):
		failures.append("XR_Main must retry a delayed OpenXR runtime without a busy loop")
	if not xr_main_source.contains("XR_ENV_BLEND_MODE_ADDITIVE"):
		failures.append("Sky XR must support additive passthrough when alpha blend is unavailable")
	if not xr_main_source.contains("_configure_passthrough_background"):
		failures.append("Sky XR must configure a compositor-compatible transparent background")
	if not xr_main_source.contains("request_toggle_main_panel_ui") \
			or not xr_main_source.contains("toggle_local_visibility"):
		failures.append("XR_Main must expose the local right-A main panel toggle")
	if not xr_main_source.contains("VIRTUAL_ANNOTATION_SETTING"):
		failures.append("XR_Main must gate the disabled virtual annotation system")
	if not xr_main_source.contains("_configure_spacebox_rendering") \
			or not xr_main_source.contains("configure_for_runtime_profile"):
		failures.append("XR_Main must apply role-specific cabin rendering")
	var spacebox_source := FileAccess.get_file_as_string(
		"res://Assets/ARSpace/Scenes/SpaceBox.gd"
	)
	if not spacebox_source.contains(
		"set_surface_override_material(0, original_material)"
	):
		failures.append("Ground VR must restore the original cabin material")
	if not spacebox_source.contains("NodePath(\"SpaceBox/DownPlane\")") \
			or not spacebox_source.contains("NodePath(\"SpaceBox/BackDor\")"):
		failures.append("Sky XR must hide DownPlane and BackDor")
	_test_role_specific_cabin_transparency(failures)

	var network_source := FileAccess.get_file_as_string("res://Assets/ARSpace/Scripts/Network/network_handler.gd")
	if not network_source.contains("return _handle_start_failure("):
		failures.append("NetworkHandler startup failures must use the shared recovery path")
	if not network_source.contains("OfflineMultiplayerPeer.new()"):
		failures.append("NetworkHandler must restore an OfflineMultiplayerPeer after closing ENet")
	var menu_source := FileAccess.get_file_as_string("res://Assets/ARSpace/Scenes/startmenu_ui.gd")
	if not menu_source.contains("NetworkHandler.get_last_start_error()"):
		failures.append("StartMenu must display synchronous network startup failures")
	if not menu_source.contains("RuntimeProfile.Preset.VR_GROUND_CLIENT"):
		failures.append("StartMenu must expose the VR Ground Client mode")
	var voice_source := FileAccess.get_file_as_string("res://Assets/ARSpace/Scripts/Network/voice_chat.gd")
	if not voice_source.contains("NetworkHandler.peer == null or not multiplayer.has_multiplayer_peer()"):
		failures.append("VoiceChat must wait for a real ENet peer before publishing levels")

	if failures.is_empty():
		print("Runtime mode integration self-test passed")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_role_specific_cabin_transparency(
	failures: PackedStringArray
) -> void:
	var spacebox_script := ResourceLoader.load(
		"res://Assets/ARSpace/Scenes/SpaceBox.gd",
		"",
		ResourceLoader.CACHE_MODE_IGNORE
	) as Script
	if spacebox_script == null:
		failures.append("SpaceBox controller must load for cabin rendering test")
		return
	var spacebox := spacebox_script.new() as Node3D

	var sky_profile = RuntimeProfile.select_session_mode(
		RuntimeProfile.Preset.SKY_XR_CLIENT,
		false
	)
	var ground_profile = RuntimeProfile.select_session_mode(
		RuntimeProfile.Preset.VR_GROUND_CLIENT,
		false
	)
	if not bool(spacebox.call(
		"_should_enable_sky_mr_transparency",
		sky_profile,
		true
	)):
		failures.append("Sky XR passthrough must enable cabin transparency")
	if bool(spacebox.call(
		"_should_enable_sky_mr_transparency",
		ground_profile,
		true
	)):
		failures.append("Ground VR must keep the cabin opaque")
	if bool(spacebox.call(
		"_should_enable_sky_mr_transparency",
		sky_profile,
		false
	)):
		failures.append(
			"Sky XR must keep the cabin opaque when passthrough is disabled"
		)

	var original_material := StandardMaterial3D.new()
	original_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	original_material.albedo_color = Color(1.0, 1.0, 1.0, 0.4)
	var sky_material := spacebox.call(
		"_make_sky_mr_material",
		original_material
	) as StandardMaterial3D
	if sky_material == original_material:
		failures.append("Sky XR cabin material must be a local runtime copy")
	if sky_material.transparency != BaseMaterial3D.TRANSPARENCY_ALPHA:
		failures.append("Sky XR cabin material must enable alpha transparency")
	if not is_equal_approx(sky_material.albedo_color.a, 0.4):
		failures.append("Sky XR cabin material must preserve its authored alpha")
	if original_material.transparency \
			!= BaseMaterial3D.TRANSPARENCY_DISABLED:
		failures.append("Sky XR must not mutate Ground VR's source material")

	var shell_root := Node3D.new()
	shell_root.name = "SpaceBox"
	spacebox.add_child(shell_root)
	var down_plane := Node3D.new()
	down_plane.name = "DownPlane"
	shell_root.add_child(down_plane)
	var back_door := Node3D.new()
	back_door.name = "BackDor"
	shell_root.add_child(back_door)
	spacebox.call("_set_sky_mr_hidden_surfaces", true)
	if down_plane.visible or back_door.visible:
		failures.append("Sky XR must hide DownPlane and BackDor")
	spacebox.call("_set_sky_mr_hidden_surfaces", false)
	if not down_plane.visible or not back_door.visible:
		failures.append(
			"Ground VR must restore DownPlane and BackDor visibility"
		)

	RuntimeProfile.clear_session_override()
	spacebox.free()
