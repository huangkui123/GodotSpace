# vr_annotation_marker.gd
# VR端3D标注标记 - 在VR空间中显示标注点
extends Node3D
class_name VRAnnotationMarker

## 标记被选中信号
signal marker_selected(marker: VRAnnotationMarker)
## 标记被删除信号
signal marker_deleted(marker: VRAnnotationMarker)

## 标记颜色
@export var marker_color: Color = Color.RED: set = set_marker_color
## 标记大小
@export var marker_size: float = 0.05: set = set_marker_size
## 是否显示标签
@export var show_label: bool = true: set = set_show_label
## 标签文本
@export var label_text: String = "": set = set_label_text
## 标记生命周期（0表示永久）
@export var lifetime: float = 0.0

## 呼吸动画参数
@export var pulse_enabled: bool = true
@export var pulse_min_scale: float = 0.8
@export var pulse_max_scale: float = 1.2
@export var pulse_duration: float = 1.0

# 内部组件
var _mesh_instance: MeshInstance3D
var _label_3d: Label3D
var _area_3d: Area3D
var _tween: Tween
var _material: StandardMaterial3D

# 元数据
var annotation_data: Dictionary = {}
var creation_time: float = 0.0

func _ready():
	_setup_marker()
	creation_time = Time.get_unix_time_from_system()
	
	if lifetime > 0:
		_start_lifetime_timer()
	
	if pulse_enabled:
		_start_pulse_animation()

## 设置标记
func _setup_marker():
	# 创建网格
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "MarkerMesh"
	
	var sphere = SphereMesh.new()
	sphere.radius = marker_size
	sphere.height = marker_size * 2
	sphere.radial_segments = 16
	sphere.rings = 8
	_mesh_instance.mesh = sphere
	
	# 创建材质
	_material = StandardMaterial3D.new()
	_material.albedo_color = marker_color
	_material.emission_enabled = true
	_material.emission = marker_color
	_material.emission_energy_multiplier = 0.5
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.albedo_color.a = 0.8
	_mesh_instance.material_override = _material
	
	add_child(_mesh_instance)
	
	# 创建3D标签
	_label_3d = Label3D.new()
	_label_3d.name = "MarkerLabel"
	_label_3d.text = label_text
	_label_3d.font_size = 24
	_label_3d.pixel_size = 0.002
	_label_3d.position = Vector3(0, marker_size * 2 + 0.02, 0)
	_label_3d.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label_3d.visible = show_label and not label_text.is_empty()
	add_child(_label_3d)
	
	# 创建交互区域
	_area_3d = Area3D.new()
	_area_3d.name = "InteractionArea"
	
	var collision_shape = CollisionShape3D.new()
	var sphere_shape = SphereShape3D.new()
	sphere_shape.radius = marker_size * 2
	collision_shape.shape = sphere_shape
	_area_3d.add_child(collision_shape)
	
	# 设置碰撞层（用于VR指针交互）
	_area_3d.collision_layer = 0b0000_0000_0001_0000_0000_0000_0000_0000  # Layer 21
	_area_3d.collision_mask = 0
	
	add_child(_area_3d)
	
	# 连接信号
	_area_3d.input_event.connect(_on_input_event)

## 设置标记位置
func setup(pos: Vector3, data: Dictionary = {}):
	global_position = pos
	annotation_data = data
	
	# 从数据中提取属性
	if data.has("label"):
		set_label_text(data.label)
	
	if data.has("color"):
		var c = data.color
		if c is Dictionary:
			set_marker_color(Color(c.get("r", 1), c.get("g", 0), c.get("b", 0), c.get("a", 1)))
		elif c is Color:
			set_marker_color(c)

## 设置标记颜色
func set_marker_color(color: Color):
	marker_color = color
	if _material:
		_material.albedo_color = color
		_material.albedo_color.a = 0.8
		_material.emission = color

## 设置标记大小
func set_marker_size(size: float):
	marker_size = size
	if _mesh_instance and _mesh_instance.mesh is SphereMesh:
		var sphere = _mesh_instance.mesh as SphereMesh
		sphere.radius = size
		sphere.height = size * 2
	
	if _area_3d:
		var collision = _area_3d.get_node_or_null("CollisionShape3D")
		if collision and collision.shape is SphereShape3D:
			collision.shape.radius = size * 2
	
	if _label_3d:
		_label_3d.position.y = size * 2 + 0.02

## 设置标签可见性
func set_show_label(visible: bool):
	show_label = visible
	if _label_3d:
		_label_3d.visible = visible and not label_text.is_empty()

## 设置标签文本
func set_label_text(text: String):
	label_text = text
	if _label_3d:
		_label_3d.text = text
		_label_3d.visible = show_label and not text.is_empty()

## 开始呼吸动画
func _start_pulse_animation():
	if _tween:
		_tween.kill()
	
	_tween = create_tween()
	_tween.set_loops()
	_tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	
	_tween.tween_property(
		_mesh_instance, "scale",
		Vector3.ONE * pulse_max_scale,
		pulse_duration / 2.0
	).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
	
	_tween.tween_property(
		_mesh_instance, "scale",
		Vector3.ONE * pulse_min_scale,
		pulse_duration / 2.0
	).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)

## 停止呼吸动画
func stop_pulse_animation():
	if _tween:
		_tween.kill()
		_tween = null
	
	if _mesh_instance:
		_mesh_instance.scale = Vector3.ONE

## 开始生命周期计时器
func _start_lifetime_timer():
	var timer = get_tree().create_timer(lifetime)
	timer.timeout.connect(_on_lifetime_end)

func _on_lifetime_end():
	_play_fade_out_animation()

## 播放淡出动画
func _play_fade_out_animation():
	if _tween:
		_tween.kill()
	
	_tween = create_tween()
	_tween.tween_property(_material, "albedo_color:a", 0.0, 0.5)
	_tween.parallel().tween_property(_mesh_instance, "scale", Vector3.ZERO, 0.5)
	_tween.tween_callback(queue_free)

## 处理输入事件
func _on_input_event(_camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape_idx: int):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			marker_selected.emit(self)
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			marker_deleted.emit(self)
			_play_fade_out_animation()

## 高亮标记
func highlight(enabled: bool = true):
	if _material:
		if enabled:
			_material.emission_energy_multiplier = 1.5
			marker_size *= 1.2
		else:
			_material.emission_energy_multiplier = 0.5
			marker_size /= 1.2

## 获取标记信息
func get_marker_info() -> Dictionary:
	return {
		"position": global_position,
		"color": marker_color,
		"size": marker_size,
		"label": label_text,
		"creation_time": creation_time,
		"data": annotation_data
	}

func _exit_tree():
	if _tween:
		_tween.kill()
