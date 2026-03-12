extends Camera3D

@export_range(0, 10, 0.01) var sensitivity: float = 3
@export_range(0, 1000, 0.1) var default_velocity: float = 5
@export_range(0, 10, 0.01) var speed_scale: float = 1.17
@export_range(1, 100, 0.1) var boost_speed_multiplier: float = 3.0
@export var max_speed: float = 1000
@export var min_speed: float = 0.2

@onready var _velocity = default_velocity

enum Mode { FREE, ORBIT }
var _mode: Mode = Mode.FREE

var _orbit_target: Node3D = null
var _orbit_distance: float = 50.0
var _orbit_yaw: float = 0.0
var _orbit_pitch: float = 0.3
const ORBIT_MIN_DIST = 0.2
const ORBIT_MAX_DIST = 5000.0
const ORBIT_ZOOM_SCALE = 1.15

var _transitioning: bool = false
var _transition_time: float = 0.0
const TRANSITION_DURATION: float = 0.8
var _trans_from_pos: Vector3
var _trans_from_basis: Basis

var _mouse_over_ui: bool = false

func focus_on(target: Node3D) -> void:
	_orbit_target = target
	_mode = Mode.ORBIT

	var radius = 1.0
	if target is OrbitalObject3D:
		radius = target.radius
	elif target.get_parent() is OrbitalObject3D:
		radius = target.get_parent().radius

	_orbit_distance = radius * 3.0

	var to_target = global_position - target.global_position
	_orbit_yaw = atan2(to_target.x, to_target.z)
	_orbit_pitch = atan2(to_target.y, Vector2(to_target.x, to_target.z).length())
	_orbit_pitch = clamp(_orbit_pitch, -1.4, 1.4)

	_trans_from_pos = global_position
	_trans_from_basis = global_transform.basis
	_transitioning = true
	_transition_time = 0.0

func _calc_orbit_position() -> Vector3:
	if not _orbit_target:
		return global_position
	var offset = Vector3(
		sin(_orbit_yaw) * cos(_orbit_pitch),
		sin(_orbit_pitch),
		cos(_orbit_yaw) * cos(_orbit_pitch)
	) * _orbit_distance
	return _orbit_target.global_position + offset

func _calc_orbit_basis() -> Basis:
	var target_pos = _calc_orbit_position()
	var dir = (_orbit_target.global_position - target_pos).normalized()
	var right = dir.cross(Vector3.UP).normalized()
	if right.length() < 0.01:
		right = Vector3.RIGHT
	var up = right.cross(dir).normalized()
	return Basis(right, up, -dir)

func _get_zoom_step() -> float:
	# 距离越近步长越小，实现平滑减速
	# 用距离的比例而非固定系数
	var base = ORBIT_ZOOM_SCALE
	var t = clamp(_orbit_distance / 2.0, 0.0, 1.0)  # 距离小于10时开始减速
	# 线性插值：近处用更小的步长系数
	var scale = lerp(1.01, base, t)
	return scale

func _input(event: InputEvent) -> void:
	if not current:
		return

	if event is InputEventMouseButton:
		if get_viewport().is_input_handled():
			return

	if event is InputEventMouseMotion:
		if get_viewport().is_input_handled():
			_mouse_over_ui = true
			return
		else:
			_mouse_over_ui = false

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			_mode = Mode.FREE
			_orbit_target = null
			_transitioning = false
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		return

	if _mode == Mode.FREE:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			if event is InputEventMouseMotion:
				rotation.y -= event.relative.x / 1000 * sensitivity
				rotation.x -= event.relative.y / 1000 * sensitivity
				rotation.x = clamp(rotation.x, PI / -2, PI / 2)
		if event is InputEventMouseButton:
			match event.button_index:
				MOUSE_BUTTON_WHEEL_UP:
					_velocity = clamp(_velocity * speed_scale, min_speed, max_speed)
				MOUSE_BUTTON_WHEEL_DOWN:
					_velocity = clamp(_velocity / speed_scale, min_speed, max_speed)
		return

	if _mode == Mode.ORBIT:
		if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			if not _mouse_over_ui:
				_orbit_yaw -= event.relative.x / 1000 * sensitivity * 2.0
				_orbit_pitch += event.relative.y / 1000 * sensitivity * 2.0
				_orbit_pitch = clamp(_orbit_pitch, -1.4, 1.4)

		if event is InputEventMouseButton:
			var zoom = _get_zoom_step()
			match event.button_index:
				MOUSE_BUTTON_WHEEL_UP:
					_orbit_distance = clamp(_orbit_distance / zoom, ORBIT_MIN_DIST, ORBIT_MAX_DIST)
				MOUSE_BUTTON_WHEEL_DOWN:
					_orbit_distance = clamp(_orbit_distance * zoom, ORBIT_MIN_DIST, ORBIT_MAX_DIST)

func _process(delta: float) -> void:
	if not current:
		return

	if _transitioning:
		_transition_time += delta
		var t = clamp(_transition_time / TRANSITION_DURATION, 0.0, 1.0)
		t = ease(t, -2.0)
		var target_pos = _calc_orbit_position()
		var target_basis = _calc_orbit_basis()
		global_position = _trans_from_pos.lerp(target_pos, t)
		global_transform.basis = _trans_from_basis.slerp(target_basis, t)
		if _transition_time >= TRANSITION_DURATION:
			_transitioning = false
		return

	if _mode == Mode.FREE:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			return
		var direction = Vector3(
			float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
			float(Input.is_physical_key_pressed(KEY_E)) - float(Input.is_physical_key_pressed(KEY_Q)),
			float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W))
		).normalized()
		if Input.is_physical_key_pressed(KEY_SHIFT):
			translate(direction * _velocity * delta * boost_speed_multiplier)
		else:
			translate(direction * _velocity * delta)

	elif _mode == Mode.ORBIT and _orbit_target and is_instance_valid(_orbit_target):
		global_position = _calc_orbit_position()
		global_transform.basis = _calc_orbit_basis()
