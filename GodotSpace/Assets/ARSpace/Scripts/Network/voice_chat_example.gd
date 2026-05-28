extends Node3D

func _ready() -> void:
	print("Voice chat test scene ready. Use V, the UI button, or the VR primary/A button to toggle voice.")

func _on_server_button_pressed() -> void:
	NetworkHandler.start_server()
	print("Server started")

func _on_client_button_pressed() -> void:
	NetworkHandler.start_client()
	print("Connecting to server")
