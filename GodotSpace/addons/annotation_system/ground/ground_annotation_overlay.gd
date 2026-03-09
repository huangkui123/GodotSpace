# ground_annotation_overlay.gd
# 地面端标注覆盖层 - 集成到现有项目中
# 自动附加到服务器端的SpectatorCamera上
extends CanvasLayer

## 标注UI组件
var annotation_panel: Control
var video_overlay: Control
var info_label: Label
var depth_slider: HSlider
var depth_value_label: Label

## 标注数据
var annotations: Array = []
var selected_annotation: int = -1
var manual_depth: float = 5.0
var use_manual_depth: bool = true

## 引用
var spectator_camera: Camera3D
var network_handler: Node

func _ready():
	# 只在服务器端运行
	if not multiplayer.is_server():
		queue_free()
		return
	
	print("🖥️ 地面端标注覆盖层启动...")
	
	# 获取引用
	spectator_camera = get_viewport().get_camera_3d()
	
	# 等待一帧确保自动加载节点已就绪
	await get_tree().process_frame
	network_handler = get_node_or_null("/root/NetworkHandler")
	if network_handler:
		print("✅ NetworkHandler 已找到")
	else:
		print("⚠️ NetworkHandler 未找到")
	
	# 创建UI
	_create_ui()

## 创建UI
func _create_ui():
	# 主控制容器
	annotation_panel = Control.new()
	annotation_panel.name = "AnnotationPanel"
	annotation_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(annotation_panel)
	
	# 标注绘制层（全屏透明，用于绘制标注点）
	video_overlay = Control.new()
	video_overlay.name = "VideoOverlay"
	video_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	video_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	video_overlay.gui_input.connect(_on_overlay_input)
	video_overlay.draw.connect(_draw_annotations)
	annotation_panel.add_child(video_overlay)
	
	# 右侧控制面板
	var side_panel = _create_side_panel()
	annotation_panel.add_child(side_panel)
	
	# 底部提示
	var hint_label = Label.new()
	hint_label.text = "💡 左键点击添加标注 | 右键点击删除 | 按住鼠标右键拖动旋转视角"
	hint_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hint_label.offset_top = -30
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	annotation_panel.add_child(hint_label)

## 创建侧边面板
func _create_side_panel() -> Control:
	var panel = PanelContainer.new()
	panel.name = "SidePanel"
	panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = -250
	panel.offset_top = 10
	panel.offset_bottom = -40
	
	# 添加半透明背景
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.15, 0.9)
	style.corner_radius_top_left = 8
	style.corner_radius_bottom_left = 8
	panel.add_theme_stylebox_override("panel", style)
	
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
	title.text = "🎯 远程标注"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)
	
	vbox.add_child(HSeparator.new())
	
	# 状态信息
	var info_title = Label.new()
	info_title.text = "📊 状态"
	vbox.add_child(info_title)
	
	info_label = Label.new()
	info_label.text = "标注数: 0\n选中: 无"
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(info_label)
	
	vbox.add_child(HSeparator.new())
	
	# 深度设置
	var depth_title = Label.new()
	depth_title.text = "📏 深度设置"
	vbox.add_child(depth_title)
	
	var manual_check = CheckBox.new()
	manual_check.text = "使用手动深度"
	manual_check.button_pressed = use_manual_depth
	manual_check.toggled.connect(func(pressed): use_manual_depth = pressed)
	vbox.add_child(manual_check)
	
	depth_slider = HSlider.new()
	depth_slider.min_value = 0.5
	depth_slider.max_value = 30.0
	depth_slider.value = manual_depth
	depth_slider.step = 0.1
	depth_slider.value_changed.connect(_on_depth_changed)
	vbox.add_child(depth_slider)
	
	depth_value_label = Label.new()
	depth_value_label.text = "深度: %.1f 米" % manual_depth
	depth_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(depth_value_label)
	
	vbox.add_child(HSeparator.new())
	
	# 操作按钮
	var btn_title = Label.new()
	btn_title.text = "🔧 操作"
	vbox.add_child(btn_title)
	
	var send_btn = Button.new()
	send_btn.text = "📤 发送选中标注"
	send_btn.pressed.connect(_on_send_selected)
	vbox.add_child(send_btn)
	
	var send_all_btn = Button.new()
	send_all_btn.text = "📤 发送所有标注"
	send_all_btn.pressed.connect(_on_send_all)
	vbox.add_child(send_all_btn)
	
	var delete_btn = Button.new()
	delete_btn.text = "🗑️ 删除选中"
	delete_btn.pressed.connect(_on_delete_selected)
	vbox.add_child(delete_btn)
	
	var clear_btn = Button.new()
	clear_btn.text = "🗑️ 清除全部"
	clear_btn.pressed.connect(_on_clear_all)
	vbox.add_child(clear_btn)
	
	return panel

## 处理覆盖层输入
func _on_overlay_input(event: InputEvent):
	if event is InputEventMouseButton:
		# 检查是否在侧边面板区域
		var viewport_size = get_viewport().get_visible_rect().size
		if event.position.x > viewport_size.x - 250:
			return  # 在面板区域，不处理
		
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			# 检查是否点击了现有标注
			var clicked = _get_annotation_at(event.position)
			if clicked >= 0:
				selected_annotation = clicked
				_update_info()
				video_overlay.queue_redraw()
			else:
				# 添加新标注
				_add_annotation(event.position)
		
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			# 删除标注
			var clicked = _get_annotation_at(event.position)
			if clicked >= 0:
				annotations.remove_at(clicked)
				if selected_annotation == clicked:
					selected_annotation = -1
				elif selected_annotation > clicked:
					selected_annotation -= 1
				_update_info()
				video_overlay.queue_redraw()

## 获取指定位置的标注
func _get_annotation_at(pos: Vector2) -> int:
	for i in range(annotations.size()):
		if annotations[i].screen_pos.distance_to(pos) < 15:
			return i
	return -1

## 添加标注
func _add_annotation(screen_pos: Vector2):
	var depth = manual_depth
	var world_pos = _screen_to_world(screen_pos, depth)
	
	var annotation = {
		"screen_pos": screen_pos,
		"depth": depth,
		"world_pos": world_pos,
		"color": Color.RED
	}
	
	annotations.append(annotation)
	selected_annotation = annotations.size() - 1
	_update_info()
	video_overlay.queue_redraw()
	
	print("➕ 添加标注 #%d - 屏幕: %s, 深度: %.1f, 世界: %s" % [
		annotations.size() - 1, screen_pos, depth, world_pos
	])

## 屏幕坐标转世界坐标
func _screen_to_world(screen_pos: Vector2, depth: float) -> Vector3:
	if not spectator_camera:
		spectator_camera = get_viewport().get_camera_3d()
	
	if not spectator_camera:
		return Vector3.ZERO
	
	var ray_origin = spectator_camera.project_ray_origin(screen_pos)
	var ray_dir = spectator_camera.project_ray_normal(screen_pos)
	
	return ray_origin + ray_dir * depth

## 绘制标注
func _draw_annotations():
	for i in range(annotations.size()):
		var ann = annotations[i]
		var pos = ann.screen_pos
		var color = ann.color
		
		if i == selected_annotation:
			color = Color.YELLOW
			video_overlay.draw_circle(pos, 14, Color(1, 1, 0, 0.3))
		
		# 绘制标注点
		video_overlay.draw_circle(pos, 10, color)
		video_overlay.draw_circle(pos, 8, Color.WHITE)
		video_overlay.draw_circle(pos, 6, color)
		
		# 绘制序号和深度
		var font = ThemeDB.fallback_font
		video_overlay.draw_string(font, pos + Vector2(15, 5), str(i), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
		video_overlay.draw_string(font, pos + Vector2(15, 20), "%.1fm" % ann.depth, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.LIGHT_BLUE)

## 更新信息
func _update_info():
	var text = "标注数: %d\n" % annotations.size()
	if selected_annotation >= 0 and selected_annotation < annotations.size():
		var ann = annotations[selected_annotation]
		text += "选中: #%d\n" % selected_annotation
		text += "深度: %.1f米\n" % ann.depth
		text += "位置: (%.1f, %.1f, %.1f)" % [ann.world_pos.x, ann.world_pos.y, ann.world_pos.z]
	else:
		text += "选中: 无"
	info_label.text = text

## 深度改变
func _on_depth_changed(value: float):
	manual_depth = value
	depth_value_label.text = "深度: %.1f 米" % value

## 发送选中标注
func _on_send_selected():
	if selected_annotation < 0 or selected_annotation >= annotations.size():
		print("⚠️ 请先选中一个标注")
		return
	
	var ann = annotations[selected_annotation]
	_send_to_vr(ann.world_pos, {"color": {"r": ann.color.r, "g": ann.color.g, "b": ann.color.b}})

## 发送所有标注
func _on_send_all():
	for ann in annotations:
		_send_to_vr(ann.world_pos, {"color": {"r": ann.color.r, "g": ann.color.g, "b": ann.color.b}})
	print("📤 已发送 %d 个标注" % annotations.size())

## 发送到VR端
func _send_to_vr(position: Vector3, data: Dictionary = {}):
	print("📤 准备发送标注到VR端: %s" % position)
	
	# 如果没有 network_handler，再尝试获取一次
	if not network_handler:
		network_handler = get_node_or_null("/root/NetworkHandler")
	
	if network_handler:
		print("📤 使用 NetworkHandler 发送...")
		if network_handler.has_method("send_remote_annotation"):
			network_handler.send_remote_annotation(position, data)
			print("✅ 已调用 send_remote_annotation")
		else:
			print("⚠️ NetworkHandler 没有 send_remote_annotation 方法")
			# 尝试直接使用 create_marker_at_position
			if network_handler.has_method("create_marker_at_position"):
				var peers = multiplayer.get_peers()
				for peer_id in peers:
					network_handler.rpc_id(peer_id, "create_marker_at_position", position)
				print("✅ 已使用旧方法 create_marker_at_position")
	else:
		print("⚠️ NetworkHandler 未找到，无法发送标注")

## 删除选中
func _on_delete_selected():
	if selected_annotation >= 0 and selected_annotation < annotations.size():
		annotations.remove_at(selected_annotation)
		selected_annotation = -1
		_update_info()
		video_overlay.queue_redraw()

## 清除全部
func _on_clear_all():
	annotations.clear()
	selected_annotation = -1
	_update_info()
	video_overlay.queue_redraw()
