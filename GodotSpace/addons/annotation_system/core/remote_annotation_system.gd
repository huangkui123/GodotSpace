# remote_annotation_system.gd
# 远程协作标注系统主控制器 - 整合所有模块
extends Node
class_name RemoteAnnotationSystem

## 系统就绪信号
signal system_ready
## 标注同步完成信号
signal annotation_synced(position: Vector3)

## 系统模式
enum SystemMode {
	GROUND_STATION,  # 地面端（服务器）
	VR_CLIENT        # VR端（客户端）
}

## 当前模式
@export var system_mode: SystemMode = SystemMode.GROUND_STATION

## 视频捕获分辨率
@export var capture_resolution: Vector2i = Vector2i(1280, 720)
## 视频捕获帧率
@export var capture_fps: float = 30.0
## 自动检测模式
@export var auto_detect_mode: bool = true

# 子系统引用
var video_capture: VideoStreamCapture
var depth_estimator: MonocularDepthEstimator
var network_manager: AnnotationNetworkManager
var ground_ui: GroundAnnotationUI
var vr_display: VRAnnotationDisplay

# UI组件（地面端）
var _video_display: TextureRect
var _main_container: Control

func _ready():
	if auto_detect_mode:
		_detect_system_mode()
	
	call_deferred("_initialize_system")

## 检测系统模式
func _detect_system_mode():
	# 等待网络初始化
	await get_tree().process_frame
	
	if multiplayer.is_server():
		system_mode = SystemMode.GROUND_STATION
	else:
		system_mode = SystemMode.VR_CLIENT
	
	print("🔍 检测到系统模式: %s" % SystemMode.keys()[system_mode])

## 初始化系统
func _initialize_system():
	print("🚀 初始化远程协作标注系统...")
	
	# 初始化网络管理器
	_setup_network_manager()
	
	match system_mode:
		SystemMode.GROUND_STATION:
			_initialize_ground_station()
		SystemMode.VR_CLIENT:
			_initialize_vr_client()
	
	system_ready.emit()
	print("✅ 远程协作标注系统初始化完成 - 模式: %s" % SystemMode.keys()[system_mode])

## 设置网络管理器
func _setup_network_manager():
	network_manager = AnnotationNetworkManager.new()
	network_manager.name = "AnnotationNetworkManager"
	network_manager.is_vr_side = (system_mode == SystemMode.VR_CLIENT)
	network_manager.add_to_group("annotation_network")
	add_child(network_manager)

## 初始化地面端
func _initialize_ground_station():
	print("📡 初始化地面端...")
	
	# 创建视频捕获系统
	video_capture = VideoStreamCapture.new()
	video_capture.name = "VideoStreamCapture"
	video_capture.capture_width = capture_resolution.x
	video_capture.capture_height = capture_resolution.y
	video_capture.capture_fps = capture_fps
	add_child(video_capture)
	
	# 创建深度估计器
	depth_estimator = MonocularDepthEstimator.new()
	depth_estimator.name = "DepthEstimator"
	add_child(depth_estimator)
	
	# 创建UI
	_create_ground_station_ui()
	
	# 连接信号
	video_capture.frame_updated.connect(_on_frame_updated)
	ground_ui.send_annotation_to_vr.connect(_on_send_annotation)
	
	# 延迟启动视频捕获
	await get_tree().create_timer(1.0).timeout
	_start_video_capture()

## 创建地面端UI
func _create_ground_station_ui():
	# 主容器
	_main_container = Control.new()
	_main_container.name = "GroundStationUI"
	_main_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_main_container)
	
	# 背景
	var bg = ColorRect.new()
	bg.name = "Background"
	bg.color = Color(0.1, 0.1, 0.15, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_main_container.add_child(bg)
	
	# 标题栏
	var title_bar = PanelContainer.new()
	title_bar.name = "TitleBar"
	title_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title_bar.custom_minimum_size = Vector2(0, 50)
	_main_container.add_child(title_bar)
	
	var title_label = Label.new()
	title_label.text = "🎯 VR远程协作标注系统 - 地面端"
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title_bar.add_child(title_label)
	
	# 视频显示区域
	var video_container = PanelContainer.new()
	video_container.name = "VideoContainer"
	video_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	video_container.offset_top = 60
	video_container.offset_bottom = -10
	video_container.offset_left = 10
	video_container.offset_right = -260
	_main_container.add_child(video_container)
	
	_video_display = TextureRect.new()
	_video_display.name = "VideoDisplay"
	_video_display.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_video_display.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	video_container.add_child(_video_display)
	
	# 标注UI层（覆盖在视频上）
	ground_ui = GroundAnnotationUI.new()
	ground_ui.name = "AnnotationUI"
	ground_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ground_ui.video_display = _video_display
	video_container.add_child(ground_ui)
	
	# 设置深度估计器和视频捕获引用
	ground_ui.set_depth_estimator(depth_estimator)
	ground_ui.set_video_capture(video_capture)
	
	# 状态面板
	_create_status_panel()

## 创建状态面板
func _create_status_panel():
	var status_panel = PanelContainer.new()
	status_panel.name = "StatusPanel"
	status_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	status_panel.position = Vector2(-250, -100)
	status_panel.size = Vector2(240, 90)
	_main_container.add_child(status_panel)
	
	var vbox = VBoxContainer.new()
	status_panel.add_child(vbox)
	
	var status_label = Label.new()
	status_label.name = "StatusLabel"
	status_label.text = "📡 状态: 等待连接..."
	vbox.add_child(status_label)
	
	var fps_label = Label.new()
	fps_label.name = "FPSLabel"
	fps_label.text = "📹 帧率: -- FPS"
	vbox.add_child(fps_label)
	
	var connection_label = Label.new()
	connection_label.name = "ConnectionLabel"
	connection_label.text = "🔗 连接: 无VR端连接"
	vbox.add_child(connection_label)
	
	# 连接网络状态更新
	network_manager.connection_status_changed.connect(func(connected, peer_id):
		connection_label.text = "🔗 连接: %s (ID: %d)" % ["已连接" if connected else "已断开", peer_id]
	)

## 启动视频捕获
func _start_video_capture():
	# 查找XR相机
	var xr_camera = _find_xr_camera()
	if xr_camera:
		video_capture.start_capture(xr_camera)
		print("✅ 视频捕获已启动，目标相机: %s" % xr_camera.name)
	else:
		# 尝试查找任何Camera3D
		var any_camera = _find_any_camera()
		if any_camera:
			video_capture.start_capture(any_camera)
			print("⚠️ 未找到XR相机，使用普通相机: %s" % any_camera.name)
		else:
			print("❌ 未找到任何可用相机")

## 初始化VR端
func _initialize_vr_client():
	print("🥽 初始化VR端...")
	
	# 创建VR标注显示管理器
	vr_display = VRAnnotationDisplay.new()
	vr_display.name = "VRAnnotationDisplay"
	add_child(vr_display)
	
	# 连接网络管理器
	network_manager.annotation_received.connect(_on_vr_annotation_received)
	
	# 将XR相机添加到组以便查找
	var xr_camera = _find_xr_camera()
	if xr_camera:
		xr_camera.add_to_group("xr_camera")

## 处理帧更新
func _on_frame_updated(texture: ImageTexture):
	if _video_display:
		_video_display.texture = texture
	
	# 更新深度估计器的当前帧
	if depth_estimator and texture:
		var image = texture.get_image()
		if image:
			depth_estimator.set_current_frame(image)

## 处理发送标注
func _on_send_annotation(world_pos: Vector3):
	if network_manager:
		network_manager.send_annotation(world_pos)
		annotation_synced.emit(world_pos)
		print("📤 已发送标注到VR端: %s" % world_pos)

## VR端收到标注
func _on_vr_annotation_received(position: Vector3, data: Dictionary):
	if vr_display:
		vr_display.create_marker(position, data.get("data", {}))
		print("✅ VR端已创建标记: %s" % position)

## 查找XR相机
func _find_xr_camera() -> Camera3D:
	# 先从组中查找
	var xr_camera = get_tree().get_first_node_in_group("xr_camera")
	if xr_camera:
		return xr_camera
	
	# 递归查找
	return _find_node_by_class(get_tree().root, "XRCamera3D")

## 查找任意相机
func _find_any_camera() -> Camera3D:
	return _find_node_by_class(get_tree().root, "Camera3D")

## 按类名查找节点
func _find_node_by_class(node: Node, class_name_str: String) -> Node:
	if node.get_class() == class_name_str or node.name == class_name_str:
		return node
	
	for child in node.get_children():
		var found = _find_node_by_class(child, class_name_str)
		if found:
			return found
	
	return null

## 手动发送标注
func send_annotation_manual(position: Vector3, data: Dictionary = {}):
	if network_manager:
		network_manager.send_annotation(position, data)

## 清除所有标注
func clear_all_annotations():
	if ground_ui:
		ground_ui.clear_all_annotations()
	if vr_display:
		vr_display.clear_all_markers()
	if network_manager:
		network_manager.clear_all_annotations()

## 获取系统状态
func get_system_status() -> Dictionary:
	return {
		"mode": SystemMode.keys()[system_mode],
		"video_capturing": video_capture != null and video_capture._is_capturing if video_capture else false,
		"network_connected": network_manager.is_network_connected() if network_manager else false,
		"annotation_count": ground_ui.get_annotations().size() if ground_ui else 0,
		"marker_count": vr_display.get_all_markers().size() if vr_display else 0
	}
