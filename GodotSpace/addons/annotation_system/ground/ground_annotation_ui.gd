# ground_annotation_ui.gd
# 地面端2D标注UI - 在视频流上进行点击标注
extends Control
class_name GroundAnnotationUI

## 标注点添加信号
signal annotation_added(screen_pos: Vector2, estimated_depth: float, world_pos: Vector3)
## 标注点选中信号
signal annotation_selected(index: int)
## 请求发送标注到VR端
signal send_annotation_to_vr(world_pos: Vector3)

## 视频显示节点
@export var video_display: TextureRect
## 深度估计器节点路径
@export var depth_estimator_path: NodePath
## 视频流捕获节点路径
@export var video_capture_path: NodePath

# 标注点数据结构
class AnnotationPoint:
	var screen_pos: Vector2  # 屏幕坐标
	var estimated_depth: float  # 估计深度
	var world_pos: Vector3  # 世界坐标
	var color: Color  # 显示颜色
	var timestamp: float  # 创建时间
	var label: String  # 标签
	
	func _init(pos: Vector2, depth: float, world: Vector3):
		screen_pos = pos
		estimated_depth = depth
		world_pos = world
		color = Color.RED
		timestamp = Time.get_unix_time_from_system()
		label = ""

# 内部变量
var _annotations: Array[AnnotationPoint] = []
var _depth_estimator: MonocularDepthEstimator
var _video_capture: VideoStreamCapture
var _selected_annotation: int = -1
var _is_annotating: bool = false
var _hover_annotation: int = -1

# UI组件
var _annotation_container: Control
var _info_label: Label
var _depth_slider: HSlider
var _manual_depth: float = 5.0
var _use_manual_depth: bool = false

func _ready():
	# 设置UI
	_setup_ui()
	
	# 连接深度估计器
	if depth_estimator_path:
		_depth_estimator = get_node_or_null(depth_estimator_path)
	
	# 连接视频捕获
	if video_capture_path:
		_video_capture = get_node_or_null(video_capture_path)
	
	print("🖱️ 地面端标注UI已初始化")

## 设置UI组件
func _setup_ui():
	# 创建标注容器
	_annotation_container = Control.new()
	_annotation_container.name = "AnnotationContainer"
	_annotation_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_annotation_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_annotation_container)
	
	# 创建信息面板
	var info_panel = PanelContainer.new()
	info_panel.name = "InfoPanel"
	info_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	info_panel.position = Vector2(-250, 10)
	info_panel.size = Vector2(240, 200)
	add_child(info_panel)
	
	var vbox = VBoxContainer.new()
	info_panel.add_child(vbox)
	
	# 标题
	var title = Label.new()
	title.text = "📍 标注控制"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)
	
	# 信息标签
	_info_label = Label.new()
	_info_label.name = "InfoLabel"
	_info_label.text = "点击视频画面添加标注\n当前标注数: 0"
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_info_label)
	
	# 深度控制
	var depth_label = Label.new()
	depth_label.text = "手动深度调节:"
	vbox.add_child(depth_label)
	
	_depth_slider = HSlider.new()
	_depth_slider.name = "DepthSlider"
	_depth_slider.min_value = 0.5
	_depth_slider.max_value = 50.0
	_depth_slider.value = _manual_depth
	_depth_slider.step = 0.1
	_depth_slider.value_changed.connect(_on_depth_slider_changed)
	vbox.add_child(_depth_slider)
	
	var depth_value_label = Label.new()
	depth_value_label.name = "DepthValueLabel"
	depth_value_label.text = "深度: %.1f 米" % _manual_depth
	vbox.add_child(depth_value_label)
	
	# 手动深度开关
	var manual_check = CheckBox.new()
	manual_check.name = "ManualDepthCheck"
	manual_check.text = "使用手动深度"
	manual_check.toggled.connect(_on_manual_depth_toggled)
	vbox.add_child(manual_check)
	
	# 清除按钮
	var clear_btn = Button.new()
	clear_btn.text = "清除所有标注"
	clear_btn.pressed.connect(clear_all_annotations)
	vbox.add_child(clear_btn)
	
	# 发送按钮
	var send_btn = Button.new()
	send_btn.text = "发送选中标注到VR"
	send_btn.pressed.connect(_on_send_annotation_pressed)
	vbox.add_child(send_btn)

func _on_depth_slider_changed(value: float):
	_manual_depth = value
	var label = get_node_or_null("InfoPanel/VBoxContainer/DepthValueLabel")
	if label:
		label.text = "深度: %.1f 米" % value

func _on_manual_depth_toggled(pressed: bool):
	_use_manual_depth = pressed
	print("📏 手动深度模式: %s" % ("开启" if pressed else "关闭"))

func _on_send_annotation_pressed():
	if _selected_annotation >= 0 and _selected_annotation < _annotations.size():
		var annotation = _annotations[_selected_annotation]
		send_annotation_to_vr.emit(annotation.world_pos)
		print("📤 发送标注到VR: %s" % annotation.world_pos)

## 设置视频显示节点
func set_video_display(display: TextureRect):
	video_display = display

## 设置深度估计器
func set_depth_estimator(estimator: MonocularDepthEstimator):
	_depth_estimator = estimator

## 设置视频捕获
func set_video_capture(capture: VideoStreamCapture):
	_video_capture = capture

func _gui_input(event: InputEvent):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_handle_click(event.position)
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_handle_right_click(event.position)

func _input(event: InputEvent):
	if event is InputEventMouseMotion:
		_update_hover(event.position)

## 处理左键点击 - 添加标注
func _handle_click(click_pos: Vector2):
	if not video_display:
		return
	
	# 检查点击是否在视频显示区域内
	var video_rect = video_display.get_global_rect()
	if not video_rect.has_point(click_pos):
		return
	
	# 转换为视频坐标
	var local_pos = click_pos - video_rect.position
	var video_size = video_display.size
	var normalized_pos = Vector2(local_pos.x / video_size.x, local_pos.y / video_size.y)
	
	# 获取捕获分辨率下的坐标
	var capture_pos = Vector2.ZERO
	if _video_capture:
		capture_pos = Vector2(
			normalized_pos.x * _video_capture.capture_width,
			normalized_pos.y * _video_capture.capture_height
		)
	else:
		capture_pos = local_pos
	
	# 估计深度
	var estimated_depth = _estimate_depth(capture_pos, normalized_pos)
	
	# 计算世界坐标
	var world_pos = _calculate_world_position(capture_pos, estimated_depth)
	
	# 创建标注点
	var annotation = AnnotationPoint.new(local_pos, estimated_depth, world_pos)
	_annotations.append(annotation)
	_selected_annotation = _annotations.size() - 1
	
	# 更新UI
	_update_info_label()
	_redraw_annotations()
	
	# 发送信号
	annotation_added.emit(local_pos, estimated_depth, world_pos)
	
	print("➕ 添加标注点 - 屏幕: %s, 深度: %.2f, 世界: %s" % [local_pos, estimated_depth, world_pos])

## 处理右键点击 - 选择或删除标注
func _handle_right_click(click_pos: Vector2):
	# 检查是否点击了已有标注
	for i in range(_annotations.size()):
		var annotation = _annotations[i]
		if video_display:
			var video_rect = video_display.get_global_rect()
			var annotation_global = video_rect.position + annotation.screen_pos
			if annotation_global.distance_to(click_pos) < 15:
				if _selected_annotation == i:
					# 双击删除
					_annotations.remove_at(i)
					_selected_annotation = -1
					_redraw_annotations()
					_update_info_label()
					print("🗑️ 删除标注点 #%d" % i)
				else:
					# 选中
					_selected_annotation = i
					_redraw_annotations()
					annotation_selected.emit(i)
					print("✅ 选中标注点 #%d" % i)
				return

## 估计深度（基于单目视觉）
func _estimate_depth(screen_pos: Vector2, normalized_pos: Vector2) -> float:
	if _use_manual_depth:
		return _manual_depth
	
	if _depth_estimator:
		return _depth_estimator.estimate_depth(screen_pos, normalized_pos)
	
	# 默认深度（当没有深度估计器时）
	return _manual_depth

## 计算世界坐标
func _calculate_world_position(screen_pos: Vector2, depth: float) -> Vector3:
	if not _video_capture:
		return Vector3.ZERO
	
	# 使用视频捕获模块的射线计算
	var ray = _video_capture.screen_to_ray(screen_pos)
	var world_pos = ray.origin + ray.direction * depth
	
	return world_pos

## 更新鼠标悬停状态
func _update_hover(mouse_pos: Vector2):
	_hover_annotation = -1
	
	for i in range(_annotations.size()):
		var annotation = _annotations[i]
		if video_display:
			var video_rect = video_display.get_global_rect()
			var annotation_global = video_rect.position + annotation.screen_pos
			if annotation_global.distance_to(mouse_pos) < 15:
				_hover_annotation = i
				break
	
	queue_redraw()

## 更新信息标签
func _update_info_label():
	var text = "点击视频画面添加标注\n"
	text += "当前标注数: %d\n" % _annotations.size()
	
	if _selected_annotation >= 0 and _selected_annotation < _annotations.size():
		var ann = _annotations[_selected_annotation]
		text += "\n选中标注 #%d:\n" % _selected_annotation
		text += "  深度: %.2f 米\n" % ann.estimated_depth
		text += "  位置: (%.2f, %.2f, %.2f)" % [ann.world_pos.x, ann.world_pos.y, ann.world_pos.z]
	
	_info_label.text = text

## 重绘标注点
func _redraw_annotations():
	queue_redraw()

func _draw():
	if not video_display:
		return
	
	var video_rect = video_display.get_rect()
	
	for i in range(_annotations.size()):
		var annotation = _annotations[i]
		var pos = annotation.screen_pos
		
		# 确定颜色
		var color = annotation.color
		if i == _selected_annotation:
			color = Color.YELLOW
		elif i == _hover_annotation:
			color = Color.ORANGE
		
		# 绘制标注点
		draw_circle(pos, 8, color)
		draw_circle(pos, 6, Color.WHITE)
		draw_circle(pos, 4, color)
		
		# 绘制序号
		var font = ThemeDB.fallback_font
		var font_size = ThemeDB.fallback_font_size
		draw_string(font, pos + Vector2(12, 5), str(i), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)
		
		# 绘制深度信息
		var depth_text = "%.1fm" % annotation.estimated_depth
		draw_string(font, pos + Vector2(12, 20), depth_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size - 2, Color.LIGHT_BLUE)

## 清除所有标注
func clear_all_annotations():
	_annotations.clear()
	_selected_annotation = -1
	_hover_annotation = -1
	_update_info_label()
	_redraw_annotations()
	print("🗑️ 已清除所有标注")

## 获取所有标注
func get_annotations() -> Array[AnnotationPoint]:
	return _annotations

## 获取选中的标注
func get_selected_annotation() -> AnnotationPoint:
	if _selected_annotation >= 0 and _selected_annotation < _annotations.size():
		return _annotations[_selected_annotation]
	return null

## 设置标注颜色
func set_annotation_color(index: int, color: Color):
	if index >= 0 and index < _annotations.size():
		_annotations[index].color = color
		_redraw_annotations()

## 设置标注标签
func set_annotation_label(index: int, label: String):
	if index >= 0 and index < _annotations.size():
		_annotations[index].label = label
