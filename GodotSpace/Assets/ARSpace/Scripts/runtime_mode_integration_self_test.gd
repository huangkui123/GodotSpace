extends SceneTree

const RESOURCE_PATHS := [
	"res://Assets/ARSpace/Scripts/runtime_profile.gd",
	"res://Assets/ARSpace/Scripts/shared_space_alignment.gd",
	"res://Assets/ARSpace/Scenes/startmenu_ui.gd",
	"res://Assets/ARSpace/Scenes/StartMenu.tscn",
	"res://Assets/ARSpace/Scripts/Network/network_handler.gd",
	"res://Assets/ARSpace/Scripts/Network/collaboration_state.gd",
	"res://Assets/ARSpace/Scripts/Network/collaboration_state_schema.gd",
	"res://Assets/ARSpace/Scripts/SpatialCalibration/shared_space_contract.gd",
	"res://Assets/ARSpace/Scripts/SpatialCalibration/spatial_calibration_state.gd",
	"res://Assets/ARSpace/Scripts/SpatialCalibration/spatial_calibration_replica.gd",
	"res://Assets/ARSpace/Scripts/Network/voice_chat_ui.gd",
	"res://Assets/ARSpace/Scripts/UI/unified_panel_ui.gd",
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
	for expected_label in ["PC 地面端 Server", "地面 VR 端 Client", "航天端 XR Client"]:
		if not menu_source.contains(expected_label):
			failures.append("StartMenu is missing the canonical runtime label: %s" % expected_label)
	if menu_source.contains("VR 地面端 Client"):
		failures.append("StartMenu must not restore the legacy reversed Ground VR label")
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
