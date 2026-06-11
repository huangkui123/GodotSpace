extends Node3D

@export_group("Nodes")
@export var rock_node: Node3D          # 碎陨石节点 (RockNode)
@export var defender_sat: Node3D       # 防御二号卫星
@export var trigger_button: Button     # 任务二 UI 按钮
@export var mission_camera: Camera3D   # 场景相机

@export_group("Rock Movement")
@export var move_range_z: float = 5.0
@export var move_range_y: float = 2.0
@export var move_speed: float = 2.0

@export_group("Mission Physics")
@export var fly_speed: float = 15.0    # 飞行速度
@export var arrive_distance: float = 0.5 # 判定“抓到”碎石的距离阈值

enum MissionState { IDLE, APPROACHING, RETURNING }

var _state = MissionState.IDLE
var _rock_initial_pos: Vector3
var _defender_initial_pos: Vector3
var _time_passed: float = 0.0

func _ready():
	if rock_node:
		_rock_initial_pos = rock_node.position
		rock_node.hide()
	if defender_sat:
		_defender_initial_pos = defender_sat.global_position
	
	if trigger_button:
		trigger_button.pressed.connect(_on_button_pressed)

func _process(delta: float):
	# 1. 碎石始终保持正弦波摆动（只要任务开启）
	if rock_node and rock_node.visible:
		_time_passed += delta * move_speed
		var offset = Vector3(0, sin(_time_passed) * move_range_y, cos(_time_passed) * move_range_z)
		rock_node.position = _rock_initial_pos + offset

	# 2. 根据任务状态执行逻辑
	match _state:
		MissionState.APPROACHING:
			_handle_approaching(delta)
		MissionState.RETURNING:
			_handle_returning(delta)

# 核心逻辑：动态追踪碎石
func _handle_approaching(delta: float):
	var target_pos = rock_node.global_position
	var current_pos = defender_sat.global_position
	
	# 计算方向并移动
	var direction = (target_pos - current_pos).normalized()
	defender_sat.global_position += direction * fly_speed * delta
	
	# 简单的朝向平滑转向（可选，增加真实感）
	if direction.length() > 0.1:
		var look_target = defender_sat.global_position + direction
		defender_sat.look_at(look_target, Vector3.UP)

	# 检查是否到达碎石位置
	if current_pos.distance_to(target_pos) < arrive_distance:
		_on_rock_intercepted()

# 核心逻辑：平滑返回初始点
func _handle_returning(delta: float):
	var target_pos = _defender_initial_pos
	var current_pos = defender_sat.global_position
	
	var direction = (target_pos - current_pos).normalized()
	defender_sat.global_position += direction * fly_speed * delta
	
	# 转向回家的方向
	if direction.length() > 0.1:
		var look_target = defender_sat.global_position + direction
		defender_sat.look_at(look_target, Vector3.UP)

	# 检查是否回到家
	if current_pos.distance_to(target_pos) < 0.1:
		defender_sat.global_position = _defender_initial_pos # 精确回位
		_state = MissionState.IDLE
		print("任务完成：已归航")

func _on_rock_intercepted():
	# 触发清理
	rock_node.hide()
	# 这里可以加个定时器或者等待一秒再返回
	_state = MissionState.RETURNING

func start_mission():
	if not rock_node or not defender_sat: return
	
	# 1. 聚焦相机
	if mission_camera and mission_camera.has_method("focus_on"):
		mission_camera.focus_on(defender_sat)
	
	# 2. 状态切换
	rock_node.show()
	_state = MissionState.APPROACHING

func stop_mission():
	_state = MissionState.IDLE
	if rock_node:
		rock_node.hide()
		rock_node.position = _rock_initial_pos
	if defender_sat:
		defender_sat.global_position = _defender_initial_pos

func _on_button_pressed():
	if _state != MissionState.IDLE:
		stop_mission()
	else:
		start_mission()
