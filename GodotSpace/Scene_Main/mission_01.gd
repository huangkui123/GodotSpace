extends Node3D

@export_group("Nodes")
@export var package: Node3D
@export var satellite: Node3D         # 中可维节点 (ZhongKeWei)
@export var satellite_control: Node   # 拖入挂载了 SatelliteControl 脚本的节点
@export var trigger_button: Button
@export var mission_camera: Camera3D

@export_group("Settings")
@export var fly_speed: float = 10.0
@export var offset_distance: Vector3 = Vector3(5, 0, 0)

var _is_running: bool = false
var _sat_initial_pos: Vector3
var _pkg_initial_pos: Vector3
var _pkg_initial_parent: Node
var _tween: Tween

func _ready():
	# 初始化：记录位置和父级
	if package:
		_pkg_initial_pos = package.global_position
		_pkg_initial_parent = package.get_parent()
		package.hide()
	if satellite:
		_sat_initial_pos = satellite.global_position
	
	if trigger_button:
		trigger_button.pressed.connect(_on_button_pressed)

func start_mission():
	if not package or not satellite: return
	
	# --- 核心修复：手动触发相机对焦逻辑 ---
	# 模拟点击卫星的效果，直接调用相机身上的 focus_on 方法
	if mission_camera and mission_camera.has_method("focus_on"):
		mission_camera.focus_on(satellite)
	
	# 如果你的 SatelliteControl 脚本里有需要同步的状态（比如 _hovered_planet）
	# 虽然 focus_on 已经执行了，但为了保险，我们可以确保它不会被其他 hover 逻辑干扰
	if satellite_control:
		# 强制让控制脚本知道现在正在关注中可维（可选）
		satellite_control.set("_hovered_planet", satellite)

	# --- 任务逻辑开始 ---
	_is_running = true
	package.show()
	
	# 1. 卫星瞬间移动到包裹旁边
	var target_pos = package.global_position
	satellite.global_position = target_pos + offset_distance
	
	_tween = create_tween().set_parallel(false)
	
	# 2. 卫星平滑移动向包裹 (碰到包裹)
	var dist_to_pkg = satellite.global_position.distance_to(target_pos)
	_tween.tween_property(satellite, "global_position", target_pos, dist_to_pkg / fly_speed)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	
	# 3. 挂载逻辑
	_tween.tween_callback(func():
		var current_transform = package.global_transform
		_pkg_initial_parent.remove_child(package)
		satellite.add_child(package)
		package.global_transform = current_transform
	)
	
	# 4. 曲线返回初始位置
	var mid_point = (_sat_initial_pos + target_pos) / 2 + Vector3(0, 10, 5) # 弧线顶点
	var dist_1 = target_pos.distance_to(mid_point)
	var dist_2 = mid_point.distance_to(_sat_initial_pos)
	
	_tween.tween_property(satellite, "global_position", mid_point, dist_1 / fly_speed)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween.tween_property(satellite, "global_position", _sat_initial_pos, dist_2 / fly_speed)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)

	# 5. 任务结束
	_tween.finished.connect(_on_mission_finished)

func _on_mission_finished():
	_is_running = false
	reset_package_state()

func stop_mission():
	if _tween:
		_tween.kill()
	_is_running = false
	reset_package_state()
	# 卫星回位
	satellite.global_position = _sat_initial_pos

func reset_package_state():
	if package and package.get_parent() == satellite:
		satellite.remove_child(package)
		_pkg_initial_parent.add_child(package)
		package.global_position = _pkg_initial_pos
		package.hide()

func _on_button_pressed():
	if _is_running:
		stop_mission()
	else:
		start_mission()
