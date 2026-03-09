# annotation_network_manager.gd
# 标注网络管理器 - 处理地面端和VR端之间的标注数据同步
extends Node
class_name AnnotationNetworkManager

## 收到标注数据信号
signal annotation_received(position: Vector3, annotation_data: Dictionary)
## 标注同步完成信号
signal sync_completed(success: bool)
## 连接状态变化信号
signal connection_status_changed(is_connected: bool, peer_id: int)

## 是否为VR端（客户端）
@export var is_vr_side: bool = false
## 自动同步间隔（秒），0表示不自动同步
@export var auto_sync_interval: float = 0.0

# 待发送的标注队列
var _pending_annotations: Array[Dictionary] = []
# 已确认的标注
var _confirmed_annotations: Array[Dictionary] = []
# 同步计时器
var _sync_timer: float = 0.0
# 是否已连接
var _is_connected: bool = false
# 连接的对端ID列表
var _connected_peers: Array[int] = []

func _ready():
	# 连接多人游戏信号
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	
	# 检测模式
	_detect_side()
	
	print("🌐 标注网络管理器已初始化 - 模式: %s" % ("VR端" if is_vr_side else "地面端"))

## 检测是VR端还是地面端
func _detect_side():
	# 服务器端为地面端，客户端为VR端
	await get_tree().process_frame
	is_vr_side = not multiplayer.is_server()

func _process(delta: float):
	if auto_sync_interval > 0 and _pending_annotations.size() > 0:
		_sync_timer += delta
		if _sync_timer >= auto_sync_interval:
			_sync_timer = 0.0
			flush_pending_annotations()

## 发送标注到VR端
func send_annotation(position: Vector3, data: Dictionary = {}):
	var annotation_data = {
		"position": position,
		"timestamp": Time.get_unix_time_from_system(),
		"data": data
	}
	
	if multiplayer.is_server():
		# 地面端（服务器）发送给所有VR端（客户端）
		for peer_id in _connected_peers:
			rpc_id(peer_id, "_receive_annotation", annotation_data)
			print("📤 发送标注到VR端 [%d]: %s" % [peer_id, position])
	else:
		# 如果意外在客户端调用，添加到待发送队列
		_pending_annotations.append(annotation_data)

## 批量发送标注
func send_annotations_batch(annotations: Array):
	for ann in annotations:
		if ann is Dictionary:
			send_annotation(ann.get("position", Vector3.ZERO), ann.get("data", {}))
		elif ann is Vector3:
			send_annotation(ann)

## 刷新待发送队列
func flush_pending_annotations():
	if _pending_annotations.is_empty():
		return
	
	for annotation in _pending_annotations:
		if multiplayer.is_server():
			for peer_id in _connected_peers:
				rpc_id(peer_id, "_receive_annotation", annotation)
		else:
			rpc_id(1, "_request_annotation_relay", annotation)
	
	_pending_annotations.clear()
	print("📤 已刷新 %d 个待发送标注" % _pending_annotations.size())

## 接收标注（VR端）
@rpc("authority", "call_local", "reliable")
func _receive_annotation(annotation_data: Dictionary):
	var position = annotation_data.get("position", Vector3.ZERO)
	var data = annotation_data.get("data", {})
	
	_confirmed_annotations.append(annotation_data)
	
	annotation_received.emit(position, annotation_data)
	print("📥 VR端收到标注: %s" % position)

## 请求中继标注（用于客户端到客户端的通信）
@rpc("any_peer", "call_local", "reliable")
func _request_annotation_relay(annotation_data: Dictionary):
	if multiplayer.is_server():
		# 服务器中继给所有其他客户端
		var sender_id = multiplayer.get_remote_sender_id()
		for peer_id in _connected_peers:
			if peer_id != sender_id:
				rpc_id(peer_id, "_receive_annotation", annotation_data)

## 同步所有标注
func sync_all_annotations():
	if multiplayer.is_server():
		for annotation in _confirmed_annotations:
			for peer_id in _connected_peers:
				rpc_id(peer_id, "_receive_annotation", annotation)
		sync_completed.emit(true)
		print("🔄 已同步 %d 个标注到所有VR端" % _confirmed_annotations.size())

## 清除所有标注
func clear_all_annotations():
	_pending_annotations.clear()
	_confirmed_annotations.clear()
	
	if multiplayer.is_server():
		for peer_id in _connected_peers:
			rpc_id(peer_id, "_clear_annotations_remote")
	
	print("🗑️ 已清除所有标注")

## 远程清除标注
@rpc("authority", "call_local", "reliable")
func _clear_annotations_remote():
	_confirmed_annotations.clear()
	print("🗑️ VR端收到清除标注命令")

## 获取已确认的标注列表
func get_confirmed_annotations() -> Array[Dictionary]:
	return _confirmed_annotations

## 获取连接状态
func is_network_connected() -> bool:
	return _is_connected

## 获取连接的对端数量
func get_connected_peer_count() -> int:
	return _connected_peers.size()

# 网络事件处理
func _on_peer_connected(peer_id: int):
	_connected_peers.append(peer_id)
	_is_connected = true
	connection_status_changed.emit(true, peer_id)
	print("✅ 对端连接: %d, 当前连接数: %d" % [peer_id, _connected_peers.size()])
	
	# 同步现有标注给新连接的对端
	if multiplayer.is_server():
		for annotation in _confirmed_annotations:
			rpc_id(peer_id, "_receive_annotation", annotation)

func _on_peer_disconnected(peer_id: int):
	_connected_peers.erase(peer_id)
	_is_connected = _connected_peers.size() > 0
	connection_status_changed.emit(_is_connected, peer_id)
	print("❌ 对端断开: %d, 当前连接数: %d" % [peer_id, _connected_peers.size()])

func _on_connected_to_server():
	_is_connected = true
	connection_status_changed.emit(true, 1)
	print("✅ 已连接到服务器")

func _on_server_disconnected():
	_is_connected = false
	_connected_peers.clear()
	connection_status_changed.emit(false, 0)
	print("❌ 与服务器断开连接")

## 发送带有额外元数据的标注
func send_annotation_with_metadata(position: Vector3, label: String = "", color: Color = Color.RED, metadata: Dictionary = {}):
	var data = {
		"label": label,
		"color": {
			"r": color.r,
			"g": color.g,
			"b": color.b,
			"a": color.a
		},
		"metadata": metadata
	}
	send_annotation(position, data)

## 请求VR端相机信息
func request_vr_camera_info():
	if multiplayer.is_server():
		for peer_id in _connected_peers:
			rpc_id(peer_id, "_request_camera_info_remote")

@rpc("authority", "call_local", "reliable")
func _request_camera_info_remote():
	# VR端响应相机信息请求
	var camera = _find_xr_camera()
	if camera:
		var info = {
			"transform": camera.global_transform,
			"fov": camera.fov,
			"near": camera.near,
			"far": camera.far
		}
		rpc_id(1, "_receive_camera_info", info)

@rpc("any_peer", "call_local", "reliable")
func _receive_camera_info(info: Dictionary):
	print("📷 收到VR端相机信息: FOV=%s, Transform=%s" % [info.get("fov"), info.get("transform")])

func _find_xr_camera() -> Camera3D:
	return get_tree().get_first_node_in_group("xr_camera")
