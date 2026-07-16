extends SceneTree

const RESOURCE_PATHS := [
	"res://Assets/ARSpace/Scripts/runtime_profile.gd",
	"res://Assets/ARSpace/Scripts/shared_space_alignment.gd",
	"res://Assets/ARSpace/Scenes/startmenu_ui.gd",
	"res://Assets/ARSpace/Scenes/StartMenu.tscn",
	"res://Assets/ARSpace/Scripts/Network/network_handler.gd",
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

	if failures.is_empty():
		print("Runtime mode integration self-test passed")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
