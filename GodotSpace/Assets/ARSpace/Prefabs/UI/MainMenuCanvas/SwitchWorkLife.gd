extends VBoxContainer

const MODE_LIFE: int = 0
const MODE_WORK: int = 1

@export_category("Button References")
@export var life_tab: Button
@export var work_tab: Button

@export_category("View References")
@export var life_view: Control
@export var work_view: Control

var _shared_state: Node
var _active_mode: int = MODE_LIFE


func _ready() -> void:
	if life_tab:
		life_tab.toggle_mode = true
	if work_tab:
		work_tab.toggle_mode = true

	if life_tab:
		life_tab.pressed.connect(_on_life_tab_pressed)
	if work_tab:
		work_tab.pressed.connect(_on_work_tab_pressed)

	_bind_shared_state()
	var initial_mode := int(_shared_state.call("get_active_mode")) \
		if _shared_state != null and _shared_state.has_method("get_active_mode") \
		else MODE_LIFE
	_apply_active_mode(initial_mode)


func _exit_tree() -> void:
	if _shared_state == null or not is_instance_valid(_shared_state):
		return
	var callback := Callable(self, "_on_shared_active_mode_changed")
	if _shared_state.has_signal("active_mode_changed") \
			and _shared_state.is_connected("active_mode_changed", callback):
		_shared_state.disconnect("active_mode_changed", callback)


func get_active_mode() -> int:
	return _active_mode


func apply_active_mode(active_mode: int) -> void:
	_apply_active_mode(active_mode)

func _set_environment_visible(show: bool) -> void:
	var global_node := get_node_or_null("/root/Global")
	var spacebox_controller = global_node.get("spacebox_controller") if global_node != null else null
	if spacebox_controller != null and spacebox_controller.has_method("set_environment_visible"):
		spacebox_controller.call("set_environment_visible", show)


func _on_life_tab_pressed() -> void:
	_request_active_mode(MODE_LIFE)


func _on_work_tab_pressed() -> void:
	_request_active_mode(MODE_WORK)


func _request_active_mode(active_mode: int) -> void:
	if _shared_state != null and _shared_state.has_method("request_active_mode"):
		if bool(_shared_state.call("request_active_mode", active_mode)):
			# Apply optimistically so the local panel remains responsive. The
			# authoritative broadcast (or rejection snapshot) reconciles both ends.
			_apply_active_mode(active_mode)
		elif _shared_state.has_method("get_active_mode"):
			_apply_active_mode(int(_shared_state.call("get_active_mode")))
		return
	_apply_active_mode(active_mode)


func _apply_active_mode(active_mode: int) -> void:
	if active_mode not in [MODE_LIFE, MODE_WORK]:
		return
	_active_mode = active_mode
	var show_life := active_mode == MODE_LIFE
	if life_view:
		life_view.visible = show_life
	if work_view:
		work_view.visible = not show_life

	if life_tab:
		life_tab.button_pressed = show_life
	if work_tab:
		work_tab.button_pressed = not show_life

	_set_environment_visible(show_life)


func _bind_shared_state() -> void:
	_shared_state = get_tree().get_first_node_in_group("shared_main_menu_state")
	if _shared_state == null or not _shared_state.has_signal("active_mode_changed"):
		return
	var callback := Callable(self, "_on_shared_active_mode_changed")
	if not _shared_state.is_connected("active_mode_changed", callback):
		_shared_state.connect("active_mode_changed", callback)


func _on_shared_active_mode_changed(active_mode: int) -> void:
	_apply_active_mode(active_mode)
