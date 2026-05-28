# start_menu_ui.gd (或者您的UI脚本)
extends Control

const GAME_SCENE_PATH = "res://Assets/ARSpace/Scenes/ARSpace.scn"
const XR_CLIENT_ARG = "--xr-client"

func _ready():
	NetworkHandler.network_ready.connect(_on_network_ready)
	if OS.get_cmdline_args().has(XR_CLIENT_ARG):
		NetworkHandler.start_client()

func _on_server_pressed():
	NetworkHandler.start_server()

func _on_client_pressed():
	if not OS.get_cmdline_args().has(XR_CLIENT_ARG):
		_restart_as_xr_client()
		return

	NetworkHandler.start_client()

func _restart_as_xr_client() -> void:
	var executable_path := OS.get_executable_path()
	var arguments := PackedStringArray()

	if OS.has_feature("editor"):
		arguments.append("--path")
		arguments.append(ProjectSettings.globalize_path("res://"))

	arguments.append("--xr-mode")
	arguments.append("on")
	arguments.append(XR_CLIENT_ARG)

	for arg in OS.get_cmdline_args():
		if arg.begins_with("--server-ip="):
			arguments.append(arg)

	var process_id := OS.create_process(executable_path, arguments)
	if process_id == -1:
		push_error("Failed to restart client with OpenXR enabled")
		return

	get_tree().quit()

func _on_network_ready():
	NetworkHandler.network_ready.disconnect(_on_network_ready)
	get_tree().change_scene_to_file(GAME_SCENE_PATH)
