# SpectatorCameraController.gd
extends Camera3D

# 使用 @export 可以在 Inspector 面板中方便地调整这些值
@export var mouse_sensitivity: float = 0.15
@export var move_speed: float = 1.0
@export var sprint_speed_multiplier: float = 2.5

# 用于存储摄像机的俯仰角度
var pitch_degrees: float = 0.0
# 鼠标点击射线长度
@export var ray_length = 1000.0
@export var marker_scene = preload("res://Assets/ARSpace/Prefabs/Marker.prefab.scn")

func _ready():
	# 游戏开始时，让鼠标可见并可以在屏幕上自由移动
	# 只有按住右键时才控制摄像机视角
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _unhandled_input(event: InputEvent):
	# 处理鼠标按钮事件
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.is_pressed():
			# 按下右键时，捕获鼠标进行视角控制
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		else:
			# 释放右键时，恢复鼠标显示
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	
	# 处理鼠标移动事件，只有在按住右键时才旋转视角
	if event is InputEventMouseMotion:
		# 只有在鼠标被捕获时（按住右键时）才控制视角
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			# 围绕Y轴旋转（左右看）
			self.rotate_y(deg_to_rad(-event.relative.x * mouse_sensitivity))
			
			# 计算并应用俯仰角度（上下看）
			pitch_degrees = clamp(pitch_degrees - event.relative.y * mouse_sensitivity, -89.0, 89.0)
			# 先将自己的旋转重置，避免万向节死锁问题
			self.rotation_degrees.x = 0
			# 再围绕自己的X轴旋转
			self.rotate_object_local(Vector3.RIGHT, deg_to_rad(pitch_degrees))
	
	# 按下 Escape 键释放鼠标
	if event.is_action_pressed("ui_cancel"): # "ui_cancel" 默认是 Escape 键
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.is_pressed():
		#Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		
		# 计算点击的3D位置
		var mouse_pos = get_viewport().get_mouse_position()
		var ray_origin = project_ray_origin(mouse_pos)
		var ray_direction = project_ray_normal(mouse_pos)
		var ray_end = ray_origin + ray_direction * ray_length

		var space_state = get_world_3d().direct_space_state
		var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
		var collision = space_state.intersect_ray(query)

		if collision:
			var hit_position = collision.position
			
			# 1. 在服务器端本地创建标记（红色球体）
			var marker = marker_scene.instantiate()
			get_parent().add_child(marker)  # 添加到场景树
			marker.setup(hit_position)
			
			# 2. 发送点击位置到所有客户端
			var network_handler = get_node("/root/NetworkHandler")
			if network_handler:
				print("服务器调用NetworkHandler的RPC create_marker_at_position")
				
				# 检查网络状态
				print("服务器网络状态:", multiplayer.multiplayer_peer.get_connection_status())
				
				# 获取所有连接的客户端
				var peer_ids = multiplayer.get_peers()
				print("连接的客户端ID:", peer_ids)
				
				# 尝试直接发送给所有客户端
				for peer_id in peer_ids:
					print("发送给客户端:", peer_id)
					network_handler.rpc_id(peer_id, "create_marker_at_position", hit_position)
			else:
				print("错误：未找到NetworkHandler节点")


func _process(delta: float):
	# 只有当这个相机是当前活动相机时，才处理移动逻辑
	if not is_current():
		return
		
	# 获取当前速度
	var current_speed = move_speed
	if Input.is_action_pressed("sprint"):
		current_speed *= sprint_speed_multiplier

	# 获取键盘输入方向
	# get_vector 会自动处理 WASD/左右上下，返回一个归一化的方向向量
	var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	
	# 根据相机朝向计算世界空间中的移动方向
	# -transform.basis.z 是相机正前方的向量
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	# 处理上下移动
	if Input.is_action_pressed("move_up"):
		direction += Vector3.UP
	if Input.is_action_pressed("move_down"):
		direction -= Vector3.UP

	# 应用移动
	# translate 是基于自身坐标系的移动，这里我们用 global_translate
	global_translate(direction * current_speed * delta)
