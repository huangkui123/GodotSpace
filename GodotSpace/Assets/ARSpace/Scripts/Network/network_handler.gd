extends Node

const IP_ADDRESS: String = "127.0.0.1"
# const IP_ADDRESS: String = "172.25.80.1"
const PORT: int = 42069

signal network_ready

var peer: ENetMultiplayerPeer
# 预加载标记场景
@export var marker_scene = preload("res://Assets/ARSpace/Prefabs/Marker.prefab.scn")

func _ready():
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

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
