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
	clear()
	hide_root = true  # 隐藏最顶层root
	var root = create_item()  # Tree 根（内部用）
	add_node_recursive(parts_root, root)

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
			if mesh_instance in highlighted_parts:
				# 当前已高亮，取消高亮
				clear_highlight(mesh_instance)
				highlighted_parts.erase(mesh_instance)
				# 恢复普通颜色
				selected.set_custom_color(0, Color(0.5, 0.8, 1.0))
			else:
				# 当前未高亮，添加高亮
				highlight_part(mesh_instance)
				highlighted_parts[mesh_instance] = selected
				# 设置为高亮颜色
				selected.set_custom_color(0, Color(1.0, 0.8, 0.2))  # 橙色表示已选中

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
func get_highlighted_parts() -> Array[MeshInstance3D]:
	return highlighted_parts.keys()
