extends Tree

# 找到主场景里根目录下SpaceBox/dashiyangui
@onready var parts_root: Node3D = get_tree().get_root().get_node("RootNode3D/SpaceBox/SpaceBox/dashiyangui")
var outline_material: ShaderMaterial = preload("res://Assets/ARSpace/Shader/outline.tres")
var original_materials := {}

func find_mesh_instance_child(node: Node):
	for child in node.get_children():
		if child is MeshInstance3D:
			return child
	return null

func _ready():
	# 将自己添加到tree_list组，方便网络代码查找
	add_to_group("tree_list")
	
	clear()
	hide_root = true  # 隐藏最顶层root
	var root = create_item()  # Tree 根（内部用）
	add_node_recursive(parts_root, root)

	if not multiplayer.is_server():
		get_parent().get_parent().visible = false

func add_node_recursive(node: Node, parent_item: TreeItem):
	if node is MeshInstance3D:
		return
	var item = create_item(parent_item)
	item.set_text(0, node.name)
	item.set_metadata(0, node)   # 保存引用，方便点击时取出来
	item.collapsed = true
	
	# 如果节点有MeshInstance3D子节点，用不同颜色显示（表示可点击）
	if find_mesh_instance_child(node) != null:
		item.set_custom_color(0, Color(0.5, 0.8, 1.0))  # 淡蓝色表示可点击
	
	for child in node.get_children():
		if child is Node3D:
			add_node_recursive(child, item)


var highlighted_parts := {}  # 保存已高亮的部件 {MeshInstance3D: TreeItem}

func _on_Tree_item_selected():
	var selected: TreeItem = get_selected()
	if selected:
		print("Selected node: ", selected.get_text(0))
		var node = selected.get_metadata(0)
		if node and find_mesh_instance_child(node) != null:
			var mesh_instance = find_mesh_instance_child(node)
			
			# 切换高亮状态
			var is_highlight = false
			if mesh_instance in highlighted_parts:
				# 当前已高亮，取消高亮
				clear_highlight(mesh_instance)
				highlighted_parts.erase(mesh_instance)
				# 恢复普通颜色
				selected.set_custom_color(0, Color(0.5, 0.8, 1.0))
				is_highlight = false
			else:
				# 当前未高亮，添加高亮
				highlight_part(mesh_instance)
				highlighted_parts[mesh_instance] = selected
				# 设置为高亮颜色
				selected.set_custom_color(0, Color(1.0, 0.8, 0.2))  # 橙色表示已选中
				is_highlight = true
			
			# 发送网络消息同步高亮状态
			sync_highlight_to_network(node, is_highlight)

func highlight_part(part: MeshInstance3D):
	# 保存原材质
	original_materials[part] = []
	for i in range(part.mesh.get_surface_count()):
		original_materials[part].append(part.get_surface_override_material(i))
		# 叠加描边材质
		part.set_surface_override_material(i, outline_material)

func clear_highlight(part: MeshInstance3D):
	if part in original_materials:
		for i in range(len(original_materials[part])):
			part.set_surface_override_material(i, original_materials[part][i])
		# 清理保存的原材质数据
		original_materials.erase(part)

# 清除所有高亮
func clear_all_highlights():
	for part in highlighted_parts.keys():
		clear_highlight(part)
		# 恢复TreeItem颜色
		if highlighted_parts[part]:
			highlighted_parts[part].set_custom_color(0, Color(0.5, 0.8, 1.0))
	highlighted_parts.clear()

# 获取当前所有高亮的部件
func get_highlighted_parts():
	return highlighted_parts.keys()

# 同步高亮状态到网络
func sync_highlight_to_network(node: Node3D, is_highlight: bool):
	# 只有服务器才发送高亮同步消息
	if not multiplayer.is_server():
		return
	
	var network_handler = get_node("/root/NetworkHandler")
	if not network_handler:
		print("错误：未找到NetworkHandler节点")
		return
	
	# 获取节点的完整路径
	var node_path = node.get_path()
	print("服务器同步高亮状态，节点路径:", node_path, " 高亮:", is_highlight)
	
	# 检查网络状态
	print("服务器网络状态:", multiplayer.multiplayer_peer.get_connection_status())
	
	# 获取所有连接的客户端
	var peer_ids = multiplayer.get_peers()
	print("连接的客户端ID:", peer_ids)
	
	# 发送给所有客户端
	for peer_id in peer_ids:
		print("发送高亮同步给客户端:", peer_id)
		network_handler.rpc_id(peer_id, "highlight_model_part", str(node_path), is_highlight)

# 更新TreeItem的颜色状态（用于客户端同步）
func update_tree_item_color(target_node: Node3D, is_highlight: bool):
	# 查找对应的TreeItem
	var tree_item = find_tree_item_by_node(target_node)
	if tree_item:
		if is_highlight:
			tree_item.set_custom_color(0, Color(1.0, 0.8, 0.2))  # 橙色表示已选中
		else:
			tree_item.set_custom_color(0, Color(0.5, 0.8, 1.0))  # 恢复普通颜色

# 根据节点查找对应的TreeItem
func find_tree_item_by_node(target_node: Node3D):
	var root = get_root()
	if root:
		return find_tree_item_recursive(root, target_node)
	return null

# 递归查找TreeItem
func find_tree_item_recursive(item: TreeItem, target_node: Node3D):
	# 检查当前项
	var metadata = item.get_metadata(0)
	if metadata == target_node:
		return item
	
	# 检查子项
	var child = item.get_first_child()
	while child:
		var result = find_tree_item_recursive(child, target_node)
		if result:
			return result
		child = child.get_next()
	
	return null
