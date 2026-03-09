# vr_annotation_display.gd
# VR端标注显示管理器 - 管理所有VR空间中的标注点
extends Node3D
class_name VRAnnotationDisplay

## 新标记创建信号
signal marker_created(marker: VRAnnotationMarker)
## 标记被选中信号
signal marker_selected(marker: VRAnnotationMarker)
## 标记被删除信号
signal marker_removed(position: Vector3)

## 标记场景（可自定义）
@export var marker_scene: PackedScene
## 默认标记颜色
@export var default_marker_color: Color = Color.RED
## 默认标记大小
@export var default_marker_size: float = 0.05
## 默认标记生命周期（0为永久）
@export var default_lifetime: float = 0.0
## 最大标记数量（0为无限）
@export var max_markers: int = 100
## 是否启用呼吸动画
@export var enable_pulse_animation: bool = true
## 网络管理器路径
@export var network_manager_path: NodePath

# 内部变量
var _markers: Array[VRAnnotationMarker] = []
var _network_manager: AnnotationNetworkManager
var _marker_container: Node3D

func _ready():
	_setup_container()
	_connect_network_manager()
	
	print("🎯 VR标注显示管理器已初始化")

## 设置标记容器
func _setup_container():
	_marker_container = Node3D.new()
	_marker_container.name = "AnnotationMarkers"
	add_child(_marker_container)

## 连接网络管理器
func _connect_network_manager():
	if network_manager_path:
		_network_manager = get_node_or_null(network_manager_path)
	
	if not _network_manager:
		# 尝试自动查找
		_network_manager = get_tree().get_first_node_in_group("annotation_network")
	
	if _network_manager:
		_network_manager.annotation_received.connect(_on_annotation_received)
		print("✅ 已连接到标注网络管理器")
	else:
		print("⚠️ 未找到标注网络管理器，仅支持本地标注")

## 处理收到的标注
func _on_annotation_received(position: Vector3, annotation_data: Dictionary):
	print("📥 收到标注数据: 位置=%s" % position)
	create_marker(position, annotation_data.get("data", {}))

## 创建标记
func create_marker(position: Vector3, data: Dictionary = {}) -> VRAnnotationMarker:
	# 检查最大数量限制
	if max_markers > 0 and _markers.size() >= max_markers:
		_remove_oldest_marker()
	
	var marker: VRAnnotationMarker
	
	if marker_scene:
		marker = marker_scene.instantiate() as VRAnnotationMarker
	else:
		marker = VRAnnotationMarker.new()
	
	_marker_container.add_child(marker)
	
	# 设置属性
	marker.marker_color = data.get("color", default_marker_color) if data.has("color") else default_marker_color
	marker.marker_size = data.get("size", default_marker_size) if data.has("size") else default_marker_size
	marker.lifetime = data.get("lifetime", default_lifetime) if data.has("lifetime") else default_lifetime
	marker.pulse_enabled = enable_pulse_animation
	
	# 初始化标记
	marker.setup(position, data)
	
	# 连接信号
	marker.marker_selected.connect(_on_marker_selected)
	marker.marker_deleted.connect(_on_marker_deleted)
	
	_markers.append(marker)
	
	marker_created.emit(marker)
	print("✅ 创建标记于: %s" % position)
	
	return marker

## 删除最旧的标记
func _remove_oldest_marker():
	if _markers.is_empty():
		return
	
	var oldest = _markers[0]
	_markers.remove_at(0)
	
	marker_removed.emit(oldest.global_position)
	oldest.queue_free()

## 处理标记选中
func _on_marker_selected(marker: VRAnnotationMarker):
	# 取消其他标记的高亮
	for m in _markers:
		if m != marker:
			m.highlight(false)
	
	marker.highlight(true)
	marker_selected.emit(marker)

## 处理标记删除
func _on_marker_deleted(marker: VRAnnotationMarker):
	_markers.erase(marker)
	marker_removed.emit(marker.global_position)

## 清除所有标记
func clear_all_markers():
	for marker in _markers:
		if is_instance_valid(marker):
			marker.queue_free()
	
	_markers.clear()
	print("🗑️ 已清除所有VR标记")

## 获取所有标记
func get_all_markers() -> Array[VRAnnotationMarker]:
	return _markers

## 获取最近的标记
func get_nearest_marker(position: Vector3) -> VRAnnotationMarker:
	if _markers.is_empty():
		return null
	
	var nearest: VRAnnotationMarker = null
	var min_distance = INF
	
	for marker in _markers:
		var dist = marker.global_position.distance_to(position)
		if dist < min_distance:
			min_distance = dist
			nearest = marker
	
	return nearest

## 获取指定范围内的标记
func get_markers_in_range(center: Vector3, radius: float) -> Array[VRAnnotationMarker]:
	var result: Array[VRAnnotationMarker] = []
	
	for marker in _markers:
		if marker.global_position.distance_to(center) <= radius:
			result.append(marker)
	
	return result

## 设置所有标记的可见性
func set_markers_visible(visible: bool):
	for marker in _markers:
		marker.visible = visible

## 设置默认属性
func set_defaults(color: Color = Color.RED, size: float = 0.05, lifetime: float = 0.0):
	default_marker_color = color
	default_marker_size = size
	default_lifetime = lifetime

## 导出标记数据
func export_markers_data() -> Array[Dictionary]:
	var data: Array[Dictionary] = []
	for marker in _markers:
		data.append(marker.get_marker_info())
	return data

## 导入标记数据
func import_markers_data(data: Array[Dictionary]):
	for item in data:
		create_marker(item.get("position", Vector3.ZERO), item)
