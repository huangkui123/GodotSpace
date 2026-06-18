extends Node

const DEBUG_LOGS := false

const TARGET_SCENE_PATH := "res://Assets/ARSpace/Scenes/ARSpace.tscn"
const PANEL_NODE_NAME := "CalibrationSection"

var calibration_panel: Control
var last_scene: Node


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)


func _process(_delta: float) -> void:
	var current_scene := get_tree().current_scene
	if current_scene != last_scene:
		last_scene = current_scene
		_refresh_panel_mount()
	elif calibration_panel != null and not _should_mount_panel(current_scene):
		_remove_panel()


func _refresh_panel_mount() -> void:
	var current_scene := get_tree().current_scene
	if _should_mount_panel(current_scene):
		_ensure_panel(current_scene)
	else:
		_remove_panel()


func _should_mount_panel(scene: Node) -> bool:
	if scene == null:
		return false
	if not multiplayer.is_server():
		return false
	if scene.scene_file_path != TARGET_SCENE_PATH:
		return false
	return true


func _ensure_panel(scene: Node) -> void:
	if calibration_panel != null and is_instance_valid(calibration_panel):
		return

	calibration_panel = scene.find_child(PANEL_NODE_NAME, true, false) as Control
	if calibration_panel == null:
		push_error("SpatialCalibration: %s was not found in %s" % [PANEL_NODE_NAME, TARGET_SCENE_PATH])
		return
	calibration_panel.visible = true
	if DEBUG_LOGS: print("SpatialCalibration: server panel mounted")


func _remove_panel() -> void:
	if calibration_panel == null:
		return
	if is_instance_valid(calibration_panel):
		calibration_panel.visible = false
	calibration_panel = null
