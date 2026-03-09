# annotation_demo.gd
# 远程协作标注系统演示场景
extends Node3D

## 演示模式
enum DemoMode {
	AUTO,      # 自动检测
	SERVER,    # 强制服务器模式
	CLIENT     # 强制客户端模式
}

@export var demo_mode: DemoMode = DemoMode.AUTO
@export var auto_connect: bool = true

@onready var annotation_system: RemoteAnnotationSystem = $RemoteAnnotationSystem

var _demo_objects: Array[MeshInstance3D] = []

func _ready():
	print("🎮 远程协作标注系统演示启动...")
	
	# 设置演示场景
	_setup_demo_scene()
	
	# 根据演示模式初始化网络
	if auto_connect:
		_setup_network()
	
	# 等待系统就绪
	annotation_system.system_ready.connect(_on_system_ready)

## 设置演示场景
func _setup_demo_scene():
	# 创建地板
	var floor_mesh = $DemoObjects/Floor
	if floor_mesh:
		var box = BoxMesh.new()
		box.size = Vector3(20, 0.1, 20)
		floor_mesh.mesh = box
		
		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color(0.3, 0.3, 0.35)
		floor_mesh.material_override = mat
		
		# 添加碰撞
		var collision = floor_mesh.get_node_or_null("FloorCollision/CollisionShape3D")
		if collision:
			var shape = BoxShape3D.new()
			shape.size = Vector3(20, 0.1, 20)
			collision.shape = shape
	
	# 创建演示物体
	_create_demo_cube($DemoObjects/Cube1, Vector3(1, 1, 1), Color.CORAL)
	_create_demo_cube($DemoObjects/Cube2, Vector3(1.5, 1.5, 1.5), Color.DODGER_BLUE)
	_create_demo_sphere($DemoObjects/Sphere1, 0.5, Color.LIME_GREEN)
	
	# 添加更多演示物体
	_create_additional_objects()

## 创建演示立方体
func _create_demo_cube(node: MeshInstance3D, size: Vector3, color: Color):
	if not node:
		return
	
	var box = BoxMesh.new()
	box.size = size
	node.mesh = box
	
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	node.material_override = mat
	
	# 添加碰撞
	var body = StaticBody3D.new()
	var collision = CollisionShape3D.new()
	var shape = BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	node.add_child(body)
	
	_demo_objects.append(node)

## 创建演示球体
func _create_demo_sphere(node: MeshInstance3D, radius: float, color: Color):
	if not node:
		return
	
	var sphere = SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2
	node.mesh = sphere
	
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	node.material_override = mat
	
	# 添加碰撞
	var body = StaticBody3D.new()
	var collision = CollisionShape3D.new()
	var shape = SphereShape3D.new()
	shape.radius = radius
	collision.shape = shape
	body.add_child(collision)
	node.add_child(body)
	
	_demo_objects.append(node)

## 创建额外的演示物体
func _create_additional_objects():
	var demo_container = $DemoObjects
	if not demo_container:
		return
	
	# 创建一些随机物体
	var positions = [
		Vector3(-4, 0.5, -6),
		Vector3(4, 0.3, -2),
		Vector3(-1, 0.8, -8),
		Vector3(3, 0.4, -7),
	]
	
	var colors = [Color.YELLOW, Color.MAGENTA, Color.CYAN, Color.ORANGE]
	
	for i in range(positions.size()):
		var mesh = MeshInstance3D.new()
		mesh.name = "ExtraObject%d" % i
		mesh.transform.origin = positions[i]
		
		# 随机形状
		if randf() > 0.5:
			var box = BoxMesh.new()
			box.size = Vector3(0.5 + randf() * 0.5, 0.5 + randf() * 0.5, 0.5 + randf() * 0.5)
			mesh.mesh = box
		else:
			var sphere = SphereMesh.new()
			sphere.radius = 0.3 + randf() * 0.3
			sphere.height = sphere.radius * 2
			mesh.mesh = sphere
		
		var mat = StandardMaterial3D.new()
		mat.albedo_color = colors[i]
		mesh.material_override = mat
		
		demo_container.add_child(mesh)
		_demo_objects.append(mesh)

## 设置网络
func _setup_network():
	var network_handler = get_node_or_null("/root/NetworkHandler")
	
	match demo_mode:
		DemoMode.AUTO:
			# 检查命令行参数
			var args = OS.get_cmdline_args()
			if "--server" in args:
				_start_server()
			elif "--client" in args:
				_start_client()
			else:
				# 默认启动服务器
				print("💡 提示: 使用 --server 或 --client 参数选择模式")
				print("💡 默认启动为服务器模式")
				_start_server()
		
		DemoMode.SERVER:
			_start_server()
		
		DemoMode.CLIENT:
			_start_client()

func _start_server():
	var network_handler = get_node_or_null("/root/NetworkHandler")
	if network_handler:
		network_handler.start_server()
		print("🖥️ 已启动服务器（地面端）")
	else:
		print("⚠️ NetworkHandler未找到，请确保已配置网络")

func _start_client():
	var network_handler = get_node_or_null("/root/NetworkHandler")
	if network_handler:
		network_handler.start_client()
		print("🥽 已启动客户端（VR端）")
	else:
		print("⚠️ NetworkHandler未找到，请确保已配置网络")

## 系统就绪回调
func _on_system_ready():
	print("✅ 标注系统就绪!")
	print("📋 操作说明:")
	print("   - 左键点击视频画面: 添加标注点")
	print("   - 右键点击标注点: 选择/删除标注")
	print("   - 使用滑块调整深度估计")
	print("   - 点击'发送选中标注到VR'将标注同步到VR端")

func _input(event: InputEvent):
	# 按F1显示帮助
	if event.is_action_pressed("ui_help") or (event is InputEventKey and event.keycode == KEY_F1 and event.pressed):
		_show_help()
	
	# 按F5重新同步
	if event is InputEventKey and event.keycode == KEY_F5 and event.pressed:
		_resync_annotations()

func _show_help():
	print("\n📖 帮助信息:")
	print("=" * 40)
	print("地面端操作:")
	print("  - 左键点击: 在视频上添加标注")
	print("  - 右键点击标注: 选择或删除")
	print("  - 滑块: 调整深度估计值")
	print("  - 发送按钮: 同步标注到VR端")
	print("")
	print("VR端显示:")
	print("  - 标注会自动显示为3D球体标记")
	print("  - 标记具有呼吸动画效果")
	print("")
	print("快捷键:")
	print("  - F1: 显示帮助")
	print("  - F5: 重新同步所有标注")
	print("=" * 40)

func _resync_annotations():
	if annotation_system and annotation_system.network_manager:
		annotation_system.network_manager.sync_all_annotations()
		print("🔄 已触发标注同步")
