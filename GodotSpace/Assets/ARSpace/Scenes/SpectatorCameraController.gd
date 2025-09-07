# SpectatorCameraController.gd
extends Camera3D

# 使用 @export 可以在 Inspector 面板中方便地调整这些值
@export var mouse_sensitivity: float = 0.15
@export var move_speed: float = 1.0
@export var sprint_speed_multiplier: float = 2.5

# 用于存储摄像机的俯仰角度
var pitch_degrees: float = 0.0

func _ready():
	# 游戏开始时，捕获鼠标光标，使其隐藏并锁定在窗口中央
	# 这样转动鼠标时就不会移出窗口
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _unhandled_input(event: InputEvent):
	# 处理鼠标移动事件，用来旋转视角
	if event is InputEventMouseMotion:
		# 按 Esc 键可以释放鼠标光标
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
		
	# 鼠标左键点击时，重新捕获鼠标
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.is_pressed():
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

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
