extends VBoxContainer

@export_category("Button References")
@export var life_tab: Button
@export var work_tab: Button

@export_category("View References")
@export var life_view: Control
@export var work_view: Control

func _ready():
	if life_tab:
		life_tab.toggle_mode = true
	if work_tab:
		work_tab.toggle_mode = true

	if life_tab:
		life_tab.pressed.connect(_on_life_tab_pressed)
	if work_tab:
		work_tab.pressed.connect(_on_work_tab_pressed)

	if life_tab and work_tab:
		_on_life_tab_pressed()

func _set_environment_visible(show: bool) -> void:
	var global_node := get_node_or_null("/root/Global")
	var spacebox_controller = global_node.get("spacebox_controller") if global_node != null else null
	if spacebox_controller != null and spacebox_controller.has_method("set_environment_visible"):
		spacebox_controller.call("set_environment_visible", show)

func _on_life_tab_pressed() -> void:
	if life_view:
		life_view.visible = true
	if work_view:
		work_view.visible = false

	if life_tab:
		life_tab.button_pressed = true
	if work_tab:
		work_tab.button_pressed = false

	_set_environment_visible(true)

func _on_work_tab_pressed() -> void:
	if life_view:
		life_view.visible = false
	if work_view:
		work_view.visible = true

	if life_tab:
		life_tab.button_pressed = false
	if work_tab:
		work_tab.button_pressed = true

	_set_environment_visible(false)
