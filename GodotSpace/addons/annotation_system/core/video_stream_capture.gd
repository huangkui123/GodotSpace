# video_stream_capture.gd
# VR视频流捕获系统 - 捕获VR端XRCamera的视角并转换为视频流
extends Node
class_name VideoStreamCapture

## 视频流更新信号
signal frame_updated(texture: ImageTexture)
## 视频流参数更新信号
signal camera_params_updated(fov: float, aspect: float, near: float, far: float)

## 捕获分辨率
@export var capture_width: int = 1280
@export var capture_height: int = 720
## 捕获帧率
@export var capture_fps: float = 30.0
## 目标相机节点路径
@export var target_camera_path: NodePath

# 内部变量
var _viewport: SubViewport
var _camera: Camera3D
var _target_camera: Camera3D
var _capture_timer: float = 0.0
var _frame_interval: float
var _current_texture: ImageTexture
var _is_capturing: bool = false

# 相机参数（用于2D到3D转换）
var camera_fov: float = 75.0
var camera_aspect: float = 16.0 / 9.0
var camera_near: float = 0.05
var camera_far: float = 1000.0
var camera_transform: Transform3D = Transform3D.IDENTITY

func _ready():
	_frame_interval = 1.0 / capture_fps
	_setup_capture_viewport()
	print("📹 视频流捕获系统已初始化 - 分辨率: %dx%d @ %d FPS" % [capture_width, capture_height, int(capture_fps)])

## 设置捕获视口
func _setup_capture_viewport():
	# 创建SubViewport用于捕获
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(capture_width, capture_height)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.transparent_bg = false
	_viewport.msaa_3d = Viewport.MSAA_2X
	add_child(_viewport)
	
	# 创建捕获用相机
	_camera = Camera3D.new()
	_camera.fov = camera_fov
	_camera.near = camera_near
	_camera.far = camera_far
	_viewport.add_child(_camera)
	
	# 创建纹理
	_current_texture = ImageTexture.new()

## 开始捕获
func start_capture(target_camera: Camera3D = null):
	if target_camera:
		_target_camera = target_camera
	elif target_camera_path:
		_target_camera = get_node_or_null(target_camera_path)
	
	if not _target_camera:
		# 尝试自动查找XRCamera3D
		_target_camera = _find_xr_camera()
	
	if _target_camera:
		_is_capturing = true
		_update_camera_params()
		print("✅ 开始捕获视频流 - 目标相机: %s" % _target_camera.name)
	else:
		push_error("❌ 未找到目标相机，无法开始捕获")

## 停止捕获
func stop_capture():
	_is_capturing = false
	print("⏹️ 已停止视频流捕获")

## 查找XR相机
func _find_xr_camera() -> Camera3D:
	var xr_camera = get_tree().get_first_node_in_group("xr_camera")
	if xr_camera:
		return xr_camera
	
	# 递归查找XRCamera3D
	return _find_camera_recursive(get_tree().root, "XRCamera3D")

func _find_camera_recursive(node: Node, type_name: String) -> Camera3D:
	if node.get_class() == type_name or node.name == type_name:
		return node as Camera3D
	
	for child in node.get_children():
		var found = _find_camera_recursive(child, type_name)
		if found:
			return found
	
	return null

## 更新相机参数
func _update_camera_params():
	if _target_camera:
		camera_fov = _target_camera.fov
		camera_near = _target_camera.near
		camera_far = _target_camera.far
		camera_aspect = float(capture_width) / float(capture_height)
		
		_camera.fov = camera_fov
		_camera.near = camera_near
		_camera.far = camera_far
		
		camera_params_updated.emit(camera_fov, camera_aspect, camera_near, camera_far)

func _process(delta: float):
	if not _is_capturing or not _target_camera:
		return
	
	_capture_timer += delta
	
	if _capture_timer >= _frame_interval:
		_capture_timer = 0.0
		_capture_frame()

## 捕获一帧
func _capture_frame():
	# 同步相机位置和朝向
	_camera.global_transform = _target_camera.global_transform
	camera_transform = _target_camera.global_transform
	
	# 获取视口纹理
	var viewport_texture = _viewport.get_texture()
	if viewport_texture:
		var image = viewport_texture.get_image()
		if image:
			_current_texture.set_image(image)
			frame_updated.emit(_current_texture)

## 获取当前帧纹理
func get_current_frame() -> ImageTexture:
	return _current_texture

## 获取当前相机变换
func get_camera_transform() -> Transform3D:
	return camera_transform

## 获取相机参数
func get_camera_params() -> Dictionary:
	return {
		"fov": camera_fov,
		"aspect": camera_aspect,
		"near": camera_near,
		"far": camera_far,
		"transform": camera_transform
	}

## 将2D屏幕坐标转换为3D射线方向
func screen_to_ray(screen_pos: Vector2) -> Dictionary:
	# 归一化屏幕坐标到 [-1, 1]
	var ndc_x = (screen_pos.x / capture_width) * 2.0 - 1.0
	var ndc_y = 1.0 - (screen_pos.y / capture_height) * 2.0  # Y轴翻转
	
	# 计算视场角对应的tan值
	var fov_rad = deg_to_rad(camera_fov)
	var tan_half_fov = tan(fov_rad / 2.0)
	
	# 计算射线方向（相机空间）
	var ray_dir_cam = Vector3(
		ndc_x * tan_half_fov * camera_aspect,
		ndc_y * tan_half_fov,
		-1.0
	).normalized()
	
	# 转换到世界空间
	var ray_dir_world = camera_transform.basis * ray_dir_cam
	var ray_origin = camera_transform.origin
	
	return {
		"origin": ray_origin,
		"direction": ray_dir_world.normalized()
	}

## 设置捕获分辨率
func set_resolution(width: int, height: int):
	capture_width = width
	capture_height = height
	if _viewport:
		_viewport.size = Vector2i(width, height)
	camera_aspect = float(width) / float(height)
	print("📹 视频流分辨率已更新: %dx%d" % [width, height])

## 设置捕获帧率
func set_fps(fps: float):
	capture_fps = fps
	_frame_interval = 1.0 / fps
	print("📹 视频流帧率已更新: %d FPS" % int(fps))
