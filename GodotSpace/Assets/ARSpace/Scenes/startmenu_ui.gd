# start_menu_ui.gd (或者您的UI脚本)
extends Control

const GAME_SCENE_PATH = "res://Assets/ARSpace/Scenes/ARSpace.scn"

func _ready():
	NetworkHandler.network_ready.connect(_on_network_ready)

func _on_server_pressed():
	NetworkHandler.start_server()

func _on_client_pressed():
	NetworkHandler.start_client()

func _on_network_ready():
	NetworkHandler.network_ready.disconnect(_on_network_ready)
	get_tree().change_scene_to_file(GAME_SCENE_PATH)
