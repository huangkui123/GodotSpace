extends Node

const IP_ADDRESS: String = "127.0.0.1"
# const IP_ADDRESS: String = "172.25.80.1"
const PORT: int = 42069

signal network_ready
## 收到远程标注信号
signal remote_annotation_received(position: Vector3, data: Dictionary)

var peer: ENetMultiplayerPeer
# 预加载标记场景
@export var marker_scene = preload("res://Assets/ARSpace/Prefabs/Marker.prefab.scn")
# 预加载VR标注标记
var vr_annotation_marker_scene: PackedScene

func _ready():
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.peer_connected.connect(_on_peer_connected)
	
	# 尝试加载VR标注标记场景
	_load_annotation_marker_scene()

func _load_annotation_marker_scene():
	# 尝试动态创建VR标注标记
	pass

func _on_peer_connected(peer_id: int):
	print("🔗 玩家 %d 已连接" % peer_id)

func start_server():
	peer = ENetMultiplayerPeer.new()
	peer.create_server(PORT)
	multiplayer.multiplayer_peer = peer
	print("服务器已启动...")
	network_ready.emit()


func start_client():
	peer = ENetMultiplayerPeer.new()
	peer.create_client(IP_ADDRESS, PORT)
	multiplayer.multiplayer_peer = peer
	print("客户端正在连接到 ", IP_ADDRESS)
	
func _on_connected_to_server():
	print("已成功连接到服务器！")
	network_ready.emit()

# 处理玩家断开连接
func _on_peer_disconnected(peer_id: int):
	print("玩家 %d 已断开连接" % peer_id)

# 接收服务器发送的标记创建请求
@rpc("authority", "call_local", "reliable")
func create_marker_at_position(position: Vector3):
	print("客户端接收到创建标记请求，位置:", position)
	
	# 在客户端创建标记
	if marker_scene:
		var marker = marker_scene.instantiate()
		# 将标记添加到主场景
		var main_scene = get_tree().current_scene
		if main_scene:
			main_scene.add_child(marker)
			marker.setup(position)
			print("客户端成功创建标记")
		else:
			print("错误：无法获取主场景")
	else:
		print("错误：标记场景未加载")

# 接收服务器发送的模型高亮请求
@rpc("authority", "call_local", "reliable")
func highlight_model_part(node_path: String, is_highlight: bool):
	print("客户端接收到模型高亮请求，路径:", node_path, " 高亮状态:", is_highlight)
	
	# 获取Tree节点
	var tree_list = get_tree().get_first_node_in_group("tree_list")
	if not tree_list:
		print("错误：无法找到TreeList节点")
		return
	
	# 根据节点路径找到对应的3D模型部件
	var target_node = get_tree().get_root().get_node_or_null(node_path)
	if not target_node:
		print("错误：无法找到目标节点:", node_path)
		return
	
	# 找到对应的MeshInstance3D
	var mesh_instance = tree_list.find_mesh_instance_child(target_node)
	if not mesh_instance:
		print("错误：节点没有MeshInstance3D子节点")
		return
	
	# 应用高亮状态
	if is_highlight:
		tree_list.highlight_part(mesh_instance)
		tree_list.highlighted_parts[mesh_instance] = null  # 在客户端不需要TreeItem引用
		print("客户端成功高亮模型部件")
	else:
		tree_list.clear_highlight(mesh_instance)
		tree_list.highlighted_parts.erase(mesh_instance)
		print("客户端成功取消高亮模型部件")
	
	# 如果客户端也有TreeList UI，同步更新TreeItem颜色
	tree_list.update_tree_item_color(target_node, is_highlight)

# ==================== 远程协作标注系统 RPC ====================

## 发送远程标注到VR端
## 由地面端（服务器）调用，发送到所有VR端（客户端）
func send_remote_annotation(position: Vector3, data: Dictionary = {}):
	if multiplayer.is_server():
		var peers = multiplayer.get_peers()
		for peer_id in peers:
			rpc_id(peer_id, "_receive_remote_annotation", position, data)
			print("📤 发送远程标注到VR端 [%d]: %s" % [peer_id, position])
	else:
		print("⚠️ 只有服务器（地面端）可以发送远程标注")

## 接收远程标注（VR端）
@rpc("authority", "call_local", "reliable")
func _receive_remote_annotation(position: Vector3, data: Dictionary):
	print("📥 VR端收到远程标注: %s, 数据: %s" % [position, data])
	
	# 发送信号，让其他组件处理
	remote_annotation_received.emit(position, data)
	
	# 创建VR标注标记
	_create_vr_annotation_marker(position, data)

## 创建VR标注标记
func _create_vr_annotation_marker(position: Vector3, data: Dictionary):
	# 尝试获取VR标注显示管理器
	var vr_display = get_tree().get_first_node_in_group("vr_annotation_display")
	if vr_display and vr_display.has_method("create_marker"):
		vr_display.create_marker(position, data)
		return
	
	# 如果没有专用的VR显示管理器，创建一个简单的标记
	var marker = _create_simple_annotation_marker(position, data)
	if marker:
		var main_scene = get_tree().current_scene
		if main_scene:
			main_scene.add_child(marker)
			# 确保全局位置正确设置
			marker.global_position = position
			print("✅ VR端创建简单标注标记: %s (场景: %s)" % [position, main_scene.name])
			print("   标记实际位置: %s" % marker.global_position)

## 创建简单标注标记（当没有VR标注系统时的后备方案）
func _create_simple_annotation_marker(position: Vector3, data: Dictionary):
	var marker = Node3D.new()
	marker.name = "RemoteAnnotationMarker"
	marker.global_position = position
	# 添加到组以便后续管理
	marker.add_to_group("remote_annotation_marker")
	
	# 创建球体网格 - 增大尺寸使其在VR中更明显
	var mesh_instance = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = 0.1  # 10厘米半径
	sphere.height = 0.2
	mesh_instance.mesh = sphere
	
	# 创建材质 - 使用更亮的发光效果
	var material = StandardMaterial3D.new()
	var color = Color.RED
	if data.has("color"):
		var c = data.color
		if c is Dictionary:
			color = Color(c.get("r", 1), c.get("g", 0), c.get("b", 0), c.get("a", 1))
		elif c is Color:
			color = c
	
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 2.0  # 增强发光
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED  # 不受光照影响，始终可见
	mesh_instance.material_override = material
	
	marker.add_child(mesh_instance)
	
	# 添加一个更大的半透明外圈，使标记更醒目
	var outer_mesh = MeshInstance3D.new()
	var outer_sphere = SphereMesh.new()
	outer_sphere.radius = 0.15
	outer_sphere.height = 0.3
	outer_mesh.mesh = outer_sphere
	
	var outer_material = StandardMaterial3D.new()
	outer_material.albedo_color = Color(color.r, color.g, color.b, 0.3)
	outer_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	outer_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	outer_mesh.material_override = outer_material
	
	marker.add_child(outer_mesh)
	
	# 添加呼吸动画
	_add_pulse_animation(marker, mesh_instance)
	
	# 注意：不设置自动销毁，标记将永久存在
	# 如果需要手动设置生命周期，可以在 data 中传入 "lifetime" 参数
	var lifetime = data.get("lifetime", 0.0)
	if lifetime > 0:
		print("⏱️ 标记将在 %.1f 秒后消失" % lifetime)
		var timer = get_tree().create_timer(lifetime)
		timer.timeout.connect(func(): 
			if is_instance_valid(marker):
				marker.queue_free()
				print("🗑️ 标记已被移除")
		)
	else:
		print("♾️ 标记将永久存在（无生命周期）")
	
	return marker

## 添加呼吸动画
func _add_pulse_animation(marker: Node3D, mesh_instance: MeshInstance3D):
	# 确保 marker 存在时才执行动画
	if not is_instance_valid(marker) or not is_instance_valid(mesh_instance):
		return
	
	var tween = create_tween()  # 使用 NetworkHandler 的 tween，而不是 marker 的
	tween.set_loops()
	tween.bind_node(marker)  # 绑定到 marker，marker 被删除时自动停止
	tween.tween_property(mesh_instance, "scale", Vector3(1.3, 1.3, 1.3), 0.6).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
	tween.tween_property(mesh_instance, "scale", Vector3(1.0, 1.0, 1.0), 0.6).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)

## 批量发送远程标注
func send_remote_annotations_batch(annotations: Array):
	for ann in annotations:
		if ann is Dictionary:
			send_remote_annotation(ann.get("position", Vector3.ZERO), ann.get("data", {}))
		elif ann is Vector3:
			send_remote_annotation(ann)

## 清除所有远程标注
func clear_all_remote_annotations():
	if multiplayer.is_server():
		var peers = multiplayer.get_peers()
		for peer_id in peers:
			rpc_id(peer_id, "_clear_remote_annotations")
			print("🗑️ 发送清除标注命令到VR端 [%d]" % peer_id)

@rpc("authority", "call_local", "reliable")
func _clear_remote_annotations():
	print("🗑️ VR端收到清除标注命令")
	
	# 清除所有远程标注标记
	var markers = get_tree().get_nodes_in_group("remote_annotation_marker")
	for marker in markers:
		marker.queue_free()
	
	# 通知VR标注显示管理器
	var vr_display = get_tree().get_first_node_in_group("vr_annotation_display")
	if vr_display and vr_display.has_method("clear_all_markers"):
		vr_display.clear_all_markers()
