extends Node3D

@export var viewport2d_node_path: NodePath = "Viewport2DIn3D"

var _viewport_node: Node = null
var _xr_origin_node: Node = null
var _left_controller: XRController3D = null
var _right_controller: XRController3D = null

func _ready():
	call_deferred("_delayed_init")

func _delayed_init():
	_viewport_node = get_node_or_null(viewport2d_node_path)
	if not _viewport_node:
		printerr("❌ 未找到 Viewport2DIn3D 节点: ", viewport2d_node_path)
		return
	_xr_origin_node = _find_xr_origin(get_tree().root)
	if not _xr_origin_node:
		printerr("❌ 未找到 XROrigin3D 节点")
		return
	_left_controller = _xr_origin_node.get_node_or_null("LeftHand")
	_right_controller = _xr_origin_node.get_node_or_null("RightHand")
	if not _left_controller or not _right_controller:
		for c in _xr_origin_node.get_children():
			if c is XRController3D:
				if not _left_controller:
					_left_controller = c
				elif not _right_controller:
					_right_controller = c
	if _left_controller:
		print("✅ 找到左手控制器: ", _left_controller.name)
		_left_controller.button_pressed.connect(_on_button_pressed.bind(_left_controller))
	else:
		printerr("❌ 未找到左手控制器")
	if _right_controller:
		print("✅ 找到右手控制器: ", _right_controller.name)
		_right_controller.button_pressed.connect(_on_button_pressed.bind(_right_controller))
	else:
		printerr("❌ 未找到右手控制器")

func _find_xr_origin(root: Node) -> Node:
	for child in root.get_children():
		if child.name == "XROrigin3D":
			return child
		var found = _find_xr_origin(child)
		if found:
			return found
	return null

func _on_button_pressed(button_name: String, controller: XRController3D) -> void:
	#print("🎮 按钮按下：", button_name, " 来自控制器：", controller.name)
	if button_name == "ax_button":
		_toggle_viewport()

func _toggle_viewport():
	if _viewport_node:
		_viewport_node.visible = !_viewport_node.visible
		print("👁️ Viewport2DIn3D 当前可见状态: ", _viewport_node.visible)
	else:
		printerr("❌ Viewport节点无效")
