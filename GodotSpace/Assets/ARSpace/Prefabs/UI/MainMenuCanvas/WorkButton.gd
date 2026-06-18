# WorkTabView.gd
extends Control

@export var trigger_button: Button

func _ready():
	if trigger_button:
		trigger_button.pressed.connect(_on_trigger_button_pressed)

func _on_trigger_button_pressed():
	var global_node := get_node_or_null("/root/Global")
	var spacebox_controller = global_node.get("spacebox_controller") if global_node != null else null
	if spacebox_controller != null and spacebox_controller.has_method("play_dashiyangui_animation"):
		spacebox_controller.call("play_dashiyangui_animation")
