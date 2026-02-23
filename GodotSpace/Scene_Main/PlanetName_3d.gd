extends Label3D

@export var camera: Camera3D
@export var hide_distance: float = 20.0
@export var click_radius: float = 25.0  # 屏幕像素范围内算点击

func _ready() -> void:
	no_depth_test = true
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	fixed_size = true

func _process(_delta: float) -> void:
	if not camera:
		return
	var dist = global_position.distance_to(camera.global_position)
	visible = dist > hide_distance

func is_mouse_over() -> bool:
	if not camera or not visible:
		return false
	# 如果星球在摄像机背后就跳过
	if camera.is_position_behind(global_position):
		return false
	var screen_pos = camera.unproject_position(global_position)
	var mouse_pos = get_viewport().get_mouse_position()
	return screen_pos.distance_to(mouse_pos) < click_radius
