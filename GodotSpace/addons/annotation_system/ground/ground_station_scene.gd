# ground_station_scene.gd
# 地面端完整场景 - 包含视频显示和标注UI
extends Node3D

## 视频捕获组件
var video_capture: VideoStreamCapture
## 深度估计组件
var depth_estimator: MonocularDepthEstimator
## 标注UI
var annotation_ui: Control
## 视频显示
var video_display: TextureRect
## 信息标签
var info_label: Label
## 深度滑块
var depth_slider: HSlider
## 深度值标签
var depth_value_label: Label

## 标注数据
var annotations: Array = []
var selected_annotation: int = -1
var manual_depth: float = 5.0
var use_manual_depth: bool = true

## 目标相机（VR端的XRCamera或本地模拟相机）
var target_camera: Camera3D

func _ready():
	print("🖥️ 地面端场景启动...")
	
	# 初始化组件
	_setup_video_capture()
	_setup_depth_estimator()
	_create_ui()
	
	# 延迟启动视频捕获
	await get_tree().create_timer(0.5).timeout
	_start_capture()

## 设置视频捕获
func _setup_video_capture():
	video_capture = VideoStreamCapture.new()
	video_capture.name = "VideoCapture"
	video_capture.capture_width = 1280
	video_capture.capture_height = 720
	video_capture.capture_fps = 30.0
	add_child(video_capture)
	
	video_capture.frame_updated.connect(_on_frame_updated)

## 设置深度估计器
func _setup_depth_estimator():
	depth_estimator = MonocularDepthEstimator.new()
	depth_estimator.name = "DepthEstimator"
	depth_estimator.estimation_method = MonocularDepthEstimator.DepthMethod.COMBINED
	add_child(depth_estimator)

## 创建UI
func _create_ui():
	# 创建CanvasLayer确保UI始终在最上层
	var canvas_layer = CanvasLayer.new()
	canvas_layer.name = "UILayer"
	add_child(canvas_layer)
	
	# 主容器
	annotation_ui = Control.new()
	annotation_ui.name = "AnnotationUI"
	annotation_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas_layer.add_child(annotation_ui)
	
	# 背景
	var bg = ColorRect.new()
	bg.name = "Background"
	bg.color = Color(0.12, 0.12, 0.18, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	annotation_ui.add_child(bg)
	
	# 主水平布局
	var main_hbox = HBoxContainer.new()
	main_hbox.name = "MainLayout"
	main_hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_hbox.anchor_left = 0.01
	main_hbox.anchor_top = 0.02
	main_hbox.anchor_right = 0.99
	main_hbox.anchor_bottom = 0.98
	annotation_ui.add_child(main_hbox)
	
	# 左侧：视频显示区域
	var video_panel = _create_video_panel()
	main_hbox.add_child(video_panel)
	
	# 右侧：控制面板
	var control_panel = _create_control_panel()
	main_hbox.add_child(control_panel)

## 创建视频显示面板
func _create_video_panel() -> Control:
	var panel = PanelContainer.new()
	panel.name = "VideoPanel"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = 3.0
	
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)
	
	var vbox = VBoxContainer.new()
	margin.add_child(vbox)
	
	# 标题
	var title = Label.new()
	title.text = "📹 VR端视频流 (点击添加标注)"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(title)
	
	# 视频显示容器
	var video_container = Control.new()
	video_container.name = "VideoContainer"
	video_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	video_container.clip_contents = true
	vbox.add_child(video_container)
	
	# 视频TextureRect
	video_display = TextureRect.new()
	video_display.name = "VideoDisplay"
	video_display.set_anchors_preset(Control.PRESET_FULL_RECT)
	video_display.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	video_display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	video_container.add_child(video_display)
	
	# 标注绘制层
	var annotation_layer = Control.new()
	annotation_layer.name = "AnnotationLayer"
	annotation_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	annotation_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	annotation_layer.gui_input.connect(_on_video_input)
	video_container.add_child(annotation_layer)
	
	# 连接绘制
	annotation_layer.draw.connect(_draw_annotations.bind(annotation_layer))
	
	return panel

## 创建控制面板
func _create_control_panel() -> Control:
	var panel = PanelContainer.new()
	panel.name = "ControlPanel"
	panel.custom_minimum_size = Vector2(280, 0)
	
	var scroll = ScrollContainer.new()
	panel.add_child(scroll)
	
	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)
	
	# 标题
	var title = Label.new()
	title.text = "🎯 标注控制面板"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)
	
	vbox.add_child(HSeparator.new())
	
	# 信息区域
	var info_section = _create_info_section()
	vbox.add_child(info_section)
	
	vbox.add_child(HSeparator.new())
	
	# 深度控制区域
	var depth_section = _create_depth_section()
	vbox.add_child(depth_section)
	
	vbox.add_child(HSeparator.new())
	
	# 操作按钮区域
	var button_section = _create_button_section()
	vbox.add_child(button_section)
	
	vbox.add_child(HSeparator.new())
	
	# 帮助信息
	var help_section = _create_help_section()
	vbox.add_child(help_section)
	
	return panel

## 创建信息区域
func _create_info_section() -> Control:
	var vbox = VBoxContainer.new()
	
	var section_title = Label.new()
	section_title.text = "📊 状态信息"
	section_title.add_theme_font_size_override("font_size", 14)
	vbox.add_child(section_title)
	
	info_label = Label.new()
	info_label.name = "InfoLabel"
	info_label.text = "标注数量: 0\n选中: 无"
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(info_label)
	
	return vbox

## 创建深度控制区域
func _create_depth_section() -> Control:
	var vbox = VBoxContainer.new()
	
	var section_title = Label.new()
	section_title.text = "📏 深度设置"
	section_title.add_theme_font_size_override("font_size", 14)
	vbox.add_child(section_title)
	
	# 手动深度开关
	var manual_check = CheckBox.new()
	manual_check.name = "ManualDepthCheck"
	manual_check.text = "使用手动深度"
	manual_check.button_pressed = use_manual_depth
	manual_check.toggled.connect(_on_manual_depth_toggled)
	vbox.add_child(manual_check)
	
	# 深度滑块
	var slider_label = Label.new()
	slider_label.text = "深度值 (米):"
	vbox.add_child(slider_label)
	
	depth_slider = HSlider.new()
	depth_slider.name = "DepthSlider"
	depth_slider.min_value = 0.5
	depth_slider.max_value = 30.0
	depth_slider.value = manual_depth
	depth_slider.step = 0.1
	depth_slider.value_changed.connect(_on_depth_changed)
	vbox.add_child(depth_slider)
	
	depth_value_label = Label.new()
	depth_value_label.name = "DepthValueLabel"
	depth_value_label.text = "当前深度: %.1f 米" % manual_depth
	depth_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(depth_value_label)
	
	return vbox

## 创建按钮区域
func _create_button_section() -> Control:
	var vbox = VBoxContainer.new()
	
	var section_title = Label.new()
	section_title.text = "🔧 操作"
	section_title.add_theme_font_size_override("font_size", 14)
	vbox.add_child(section_title)
	
	# 发送按钮
	var send_btn = Button.new()
	send_btn.text = "📤 发送选中标注到VR"
	send_btn.pressed.connect(_on_send_pressed)
	vbox.add_child(send_btn)
	
	# 发送全部按钮
	var send_all_btn = Button.new()
	send_all_btn.text = "📤 发送所有标注到VR"
	send_all_btn.pressed.connect(_on_send_all_pressed)
	vbox.add_child(send_all_btn)
	
	# 删除选中按钮
	var delete_btn = Button.new()
	delete_btn.text = "🗑️ 删除选中标注"
	delete_btn.pressed.connect(_on_delete_pressed)
	vbox.add_child(delete_btn)
	
	# 清除全部按钮
	var clear_btn = Button.new()
	clear_btn.text = "🗑️ 清除所有标注"
	clear_btn.pressed.connect(_on_clear_pressed)
	vbox.add_child(clear_btn)
	
	return vbox

## 创建帮助区域
func _create_help_section() -> Control:
	var vbox = VBoxContainer.new()
	
	var section_title = Label.new()
	section_title.text = "❓ 操作说明"
	section_title.add_theme_font_size_override("font_size", 14)
	vbox.add_child(section_title)
	
	var help_text = Label.new()
	help_text.text = """• 左键点击视频: 添加标注
• 左键点击标注: 选中
• 右键点击标注: 删除
• 滑块: 调整深度"""
	help_text.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(help_text)
	
	return vbox

## 启动视频捕获
func _start_capture():
	# 查找目标相机
	target_camera = _find_camera()
	
	if target_camera:
		video_capture.start_capture(target_camera)
		print("✅ 开始捕获相机: %s" % target_camera.name)
	else:
		print("⚠️ 未找到相机，创建测试相机...")
		_create_test_camera()

## 查找相机
func _find_camera() -> Camera3D:
	# 优先查找XRCamera
	var xr_camera = get_tree().get_first_node_in_group("xr_camera")
	if xr_camera:
		return xr_camera
	
	# 查找名为XRCamera3D的节点
	var xr_cam = _find_node_recursive(get_tree().root, "XRCamera3D")
	if xr_cam:
		return xr_cam
	
	# 查找SpectatorCamera
	var spectator = _find_node_recursive(get_tree().root, "SpectatorCamera")
	if spectator:
		return spectator
	
	# 查找任意Camera3D
	return _find_node_by_class(get_tree().root, "Camera3D")

func _find_node_recursive(node: Node, name_to_find: String) -> Node:
	if node.name == name_to_find:
		return node
	for child in node.get_children():
		var found = _find_node_recursive(child, name_to_find)
		if found:
			return found
	return null

func _find_node_by_class(node: Node, type_name: String) -> Node:
	if node.get_class() == type_name:
		return node
	for child in node.get_children():
		var found = _find_node_by_class(child, type_name)
		if found:
			return found
	return null

## 创建测试相机
func _create_test_camera():
	target_camera = Camera3D.new()
	target_camera.name = "TestCamera"
	target_camera.position = Vector3(0, 2, 5)
	target_camera.look_at(Vector3.ZERO)
	add_child(target_camera)
	
	video_capture.start_capture(target_camera)
	print("✅ 已创建测试相机")

## 帧更新回调
func _on_frame_updated(texture: ImageTexture):
	if video_display:
		video_display.texture = texture
	
	# 更新深度估计器
	if depth_estimator and texture:
		var image = texture.get_image()
		if image:
			depth_estimator.set_current_frame(image)

## 视频区域输入处理
func _on_video_input(event: InputEvent):
	if event is InputEventMouseButton:
		var annotation_layer = annotation_ui.get_node("MainLayout/VideoPanel/MarginContainer/VBoxContainer/VideoContainer/AnnotationLayer")
		var video_rect = video_display.get_global_rect()
		var local_pos = event.position
		
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			# 检查是否点击了现有标注
			var clicked_index = _get_annotation_at(local_pos)
			if clicked_index >= 0:
				selected_annotation = clicked_index
				_update_info()
				annotation_layer.queue_redraw()
			else:
				# 添加新标注
				_add_annotation(local_pos)
				annotation_layer.queue_redraw()
		
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			# 删除标注
			var clicked_index = _get_annotation_at(local_pos)
			if clicked_index >= 0:
				annotations.remove_at(clicked_index)
				if selected_annotation == clicked_index:
					selected_annotation = -1
				elif selected_annotation > clicked_index:
					selected_annotation -= 1
				_update_info()
				annotation_layer.queue_redraw()

## 获取指定位置的标注索引
func _get_annotation_at(pos: Vector2) -> int:
	for i in range(annotations.size()):
		var ann = annotations[i]
		if ann.screen_pos.distance_to(pos) < 15:
			return i
	return -1

## 添加标注
func _add_annotation(screen_pos: Vector2):
	# 计算深度
	var depth = manual_depth if use_manual_depth else _estimate_depth(screen_pos)
	
	# 计算世界坐标
	var world_pos = _calculate_world_position(screen_pos, depth)
	
	var annotation = {
		"screen_pos": screen_pos,
		"depth": depth,
		"world_pos": world_pos,
		"color": Color.RED
	}
	
	annotations.append(annotation)
	selected_annotation = annotations.size() - 1
	_update_info()
	
	print("➕ 添加标注 #%d - 屏幕: %s, 深度: %.1f, 世界: %s" % [
		annotations.size() - 1, screen_pos, depth, world_pos
	])

## 估计深度
func _estimate_depth(screen_pos: Vector2) -> float:
	if depth_estimator:
		var video_size = video_display.size
		var normalized = Vector2(screen_pos.x / video_size.x, screen_pos.y / video_size.y)
		return depth_estimator.estimate_depth(screen_pos, normalized)
	return manual_depth

## 计算世界坐标
func _calculate_world_position(screen_pos: Vector2, depth: float) -> Vector3:
	if not video_capture:
		return Vector3.ZERO
	
	# 获取视频显示的实际大小
	var video_size = video_display.size
	
	# 转换到捕获分辨率
	var capture_pos = Vector2(
		screen_pos.x / video_size.x * video_capture.capture_width,
		screen_pos.y / video_size.y * video_capture.capture_height
	)
	
	var ray = video_capture.screen_to_ray(capture_pos)
	return ray.origin + ray.direction * depth

## 绘制标注
func _draw_annotations(layer: Control):
	for i in range(annotations.size()):
		var ann = annotations[i]
		var pos = ann.screen_pos
		var color = ann.color
		
		# 选中状态
		if i == selected_annotation:
			color = Color.YELLOW
			layer.draw_circle(pos, 12, Color(1, 1, 0, 0.3))
		
		# 绘制标注点
		layer.draw_circle(pos, 10, color)
		layer.draw_circle(pos, 8, Color.WHITE)
		layer.draw_circle(pos, 6, color)
		
		# 绘制序号
		var font = ThemeDB.fallback_font
		layer.draw_string(font, pos + Vector2(15, 5), str(i), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
		
		# 绘制深度
		var depth_text = "%.1fm" % ann.depth
		layer.draw_string(font, pos + Vector2(15, 20), depth_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.LIGHT_BLUE)

## 更新信息标签
func _update_info():
	var text = "标注数量: %d\n" % annotations.size()
	
	if selected_annotation >= 0 and selected_annotation < annotations.size():
		var ann = annotations[selected_annotation]
		text += "选中: #%d\n" % selected_annotation
		text += "深度: %.2f 米\n" % ann.depth
		text += "位置: (%.1f, %.1f, %.1f)" % [ann.world_pos.x, ann.world_pos.y, ann.world_pos.z]
	else:
		text += "选中: 无"
	
	info_label.text = text

## 深度值改变
func _on_depth_changed(value: float):
	manual_depth = value
	depth_value_label.text = "当前深度: %.1f 米" % value

## 手动深度开关
func _on_manual_depth_toggled(pressed: bool):
	use_manual_depth = pressed

## 发送选中标注
func _on_send_pressed():
	if selected_annotation < 0 or selected_annotation >= annotations.size():
		print("⚠️ 请先选中一个标注")
		return
	
	var ann = annotations[selected_annotation]
	_send_annotation_to_vr(ann.world_pos, {"color": ann.color})

## 发送所有标注
func _on_send_all_pressed():
	for ann in annotations:
		_send_annotation_to_vr(ann.world_pos, {"color": ann.color})
	print("📤 已发送 %d 个标注" % annotations.size())

## 发送标注到VR
func _send_annotation_to_vr(position: Vector3, data: Dictionary):
	var network_handler = get_node_or_null("/root/NetworkHandler")
	if network_handler and network_handler.has_method("send_remote_annotation"):
		network_handler.send_remote_annotation(position, data)
		print("📤 发送标注到VR: %s" % position)
	elif network_handler and network_handler.has_method("create_marker_at_position"):
		# 使用旧的方法
		var peers = multiplayer.get_peers()
		for peer_id in peers:
			network_handler.rpc_id(peer_id, "create_marker_at_position", position)
		print("📤 发送标注到VR (旧方法): %s" % position)
	else:
		print("⚠️ 未找到NetworkHandler，标注仅本地显示")

## 删除选中标注
func _on_delete_pressed():
	if selected_annotation >= 0 and selected_annotation < annotations.size():
		annotations.remove_at(selected_annotation)
		selected_annotation = -1
		_update_info()
		var annotation_layer = annotation_ui.get_node("MainLayout/VideoPanel/MarginContainer/VBoxContainer/VideoContainer/AnnotationLayer")
		annotation_layer.queue_redraw()

## 清除所有标注
func _on_clear_pressed():
	annotations.clear()
	selected_annotation = -1
	_update_info()
	var annotation_layer = annotation_ui.get_node("MainLayout/VideoPanel/MarginContainer/VBoxContainer/VideoContainer/AnnotationLayer")
	annotation_layer.queue_redraw()
