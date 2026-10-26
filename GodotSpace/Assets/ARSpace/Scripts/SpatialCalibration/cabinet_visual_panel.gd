extends PanelContainer

const Style := preload("res://Assets/ARSpace/Scripts/UI/sky_panel_style.gd")
const Geometry := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_geometry.gd")
const VisualGeometry := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_visual_geometry.gd")
const CameraModel := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/pico_camera_model.gd")
const Job := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_visual_job.gd")
const CabinetModel := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/calibration_cabinet.gd")
const CAPTURE_DURATION_MS := 12000
const CAPTURE_INTERVAL_MS := 750
const MAX_FRAMES := 16
const MAX_JPEG_BYTES := 24 * 1024 * 1024 - 4096 # Leave room for per-frame base64 padding.

var controller: Node
var _job: Node
var _source: OptionButton
var _scale: OptionButton
var _kind: OptionButton
var _dimension_row: HBoxContainer
var _scale_caption: Label
var _dimensions: Array[SpinBox] = []
var _dimension_buttons: Array[Button] = []
var _image: TextureRect
var _status: Label
var _connection: Label
var _model_info: Label
var _start: Button
var _apply: Button
var _busy := false
var _collecting := false
var _deadline: int = 0
var _next_capture: int = 0
var _capture_start: int = 0
var _jpeg_bytes := 0
var _skipped := 0
var _capture_hint := ""
var _epoch: int = -1
var _request_id := ""
var _frames: Array[Dictionary] = []
var _captures: Array[Dictionary] = []
var _last_display: int = -1
var _display_tick := 0.0
var _result: Dictionary = {}
var _hold_rejected_image := false


func _ready() -> void:
	name = "CabinetVisualUI"
	theme = Style.make_theme(20)
	add_theme_stylebox_override("panel", Style.box(Style.BACKGROUND, 0, 16))
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	var title := _label(header, "柜体自动视觉标定")
	title.autowrap_mode = TextServer.AUTOWRAP_OFF
	title.add_theme_font_size_override("font_size", 30)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button(header, "放大 / 还原", func(): controller.call("toggle_panel_zoom"))
	_button(header, "关闭", func(): controller.call("close_panel"))
	_label(column, "选择柜体 → 自动视觉识别 → 检查预览并应用；无需手动选角点")
	var options := HBoxContainer.new()
	options.add_theme_constant_override("separation", 16)
	column.add_child(options)
	_kind = OptionButton.new()
	_kind.name = "CalibrationModelKind"
	_kind.custom_minimum_size.y = 48
	_kind.add_item("真实 CAD 模型")
	_kind.add_item("自定义长方体柜体")
	_kind.item_selected.connect(func(_index: int): _options_changed())
	options.add_child(_kind)
	_source = OptionButton.new()
	_source.add_item("实时 PICO")
	_source.add_item("合成演练（无实物）")
	_source.custom_minimum_size.y = 48
	_source.item_selected.connect(func(_index: int): _reset())
	options.add_child(_source)
	_scale_caption = _label(options, "CAD 比例")
	_scale_caption.autowrap_mode = TextServer.AUTOWRAP_OFF
	_scale = OptionButton.new()
	_scale.add_item("1:1 原尺寸")
	_scale.add_item("1:3 打印缩比")
	_scale.item_selected.connect(func(_index: int): _reset())
	options.add_child(_scale)
	_dimension_row = HBoxContainer.new()
	_dimension_row.add_theme_constant_override("separation", 18)
	column.add_child(_dimension_row)
	for i in range(3):
		var cell := HBoxContainer.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_dimension_row.add_child(cell)
		var caption := _label(cell, ["宽 cm", "高 cm", "深 cm"][i])
		caption.autowrap_mode = TextServer.AUTOWRAP_OFF
		var spin := SpinBox.new()
		spin.name = ["WidthCm", "HeightCm", "DepthCm"][i]
		spin.min_value = 5
		spin.max_value = 2000
		spin.step = 1
		spin.value = CabinetModel.DEFAULT_DIMENSIONS[i] * 100
		spin.custom_minimum_size = Vector2(120, 48)
		_dimension_buttons.append(_button(cell, "−", func(): spin.value -= 1))
		cell.add_child(spin)
		_dimension_buttons.append(_button(cell, "+", func(): spin.value += 1))
		spin.value_changed.connect(func(_value: float): _options_changed())
		_dimensions.append(spin)
	_model_info = _label(column, "模型：Merge_of_储存版-白色哑光_w2.magics 装配体 · 默认 1:1")
	_connection = _label(column, "正在检查相机连接…")
	_connection.autowrap_mode = TextServer.AUTOWRAP_OFF
	_connection.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_image = TextureRect.new()
	_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_image.custom_minimum_size = Vector2(600, 280)
	_image.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# No input handlers/point collection in the CAD workflow.
	_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_image)
	_status = _label(column, "多视角扫描 12 秒：缓慢横移并看向柜体，让不同角度共同参与识别。")
	_status.custom_minimum_size.y = 70
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 16)
	column.add_child(actions)
	_start = _button(actions, "开始自动识别", _begin)
	Style.primary(_start)
	_button(actions, "取消 / 清除预览", _reset)
	_apply = _button(actions, "应用对齐", _confirm)
	_apply.disabled = true
	Style.primary(_apply)
	_label(column, "缓慢横移，尽量露出正面和侧面；多视角标定仍需现场检查贴合。")
	_job = Job.new()
	_job.connect("completed", _on_completed)
	add_child(_job)
	controller.connect("state_changed", _on_state_changed)
	_options_changed()


func _button(parent: Node, caption: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.custom_minimum_size = Vector2(48, 48)
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _label(parent: Node, caption: String) -> Label:
	var label := Label.new()
	label.text = caption
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func physical_scale() -> float:
	return 1.0 if _kind.selected == 1 or _scale.selected == 0 else 1.0 / 3.0


func model_kind() -> String:
	return "cad" if _kind.selected == 0 else "cuboid"


func dimensions_m() -> Vector3:
	return Vector3(_dimensions[0].value, _dimensions[1].value, _dimensions[2].value) / 100.0


func _options_changed() -> void:
	_reset()
	var custom := model_kind() == "cuboid"
	_dimension_row.visible = custom
	_scale.visible = not custom
	_scale_caption.visible = not custom
	controller.call("configure_visual_model", model_kind(), dimensions_m())
	_status.text = "从正面缓慢移动到斜侧面，让不同视角共同识别柜体。" if custom \
		else "缓慢移动观察真实 CAD 柜体，让不同视角匹配模型细节。"


func _begin() -> void:
	_reset()
	_busy = true
	_start.disabled = true
	_source.disabled = true
	_scale.disabled = true
	_kind.disabled = true
	for spin in _dimensions:
		spin.editable = false
	for button in _dimension_buttons:
		button.disabled = true
	_epoch = int(controller.get("capture_epoch"))
	_request_id = "%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	if _source.selected == 1:
		var head: Dictionary = controller.call("get_head_sample")
		_captures.append({"capture_id": "demo", "camera_world": head.get("transform", Transform3D.IDENTITY)})
		_launch()
	else:
		_collecting = true
		_capture_start = Time.get_ticks_msec() + 3000
		_next_capture = _capture_start
		_deadline = _capture_start + CAPTURE_DURATION_MS
		_status.text = "%s：3 秒后开始扫描 12 秒。请缓慢横移，保持柜体在画面中。" % _kind.get_item_text(_kind.selected)


func _process(delta: float) -> void:
	if _busy and _source.selected == 0 and _epoch != int(controller.get("capture_epoch")):
		_fail("相机连接或跟踪空间发生变化，旧识别已取消，请重新识别。")
		return
	if _collecting:
		var now := Time.get_ticks_msec()
		if now >= _deadline:
			_finish_capture()
		elif now >= _next_capture:
			_capture()
		if _collecting and now >= _capture_start:
			_status.text = "多视角扫描：剩余 %.1f 秒 · 已采集 %d 个视角 · 跳过 %d 次\n%s" % [
				maxf(0, (_deadline - now) / 1000.0), _captures.size(), _skipped, _capture_hint]
	_display_tick += delta
	if _display_tick < 0.15:
		return
	_display_tick = 0.0
	_connection.text = str(controller.call("get_capture_status")) if _source.selected == 0 else "合成图像 · 离线演练（不会应用现场对齐）"
	if _hold_rejected_image:
		_connection.text = "本次识别末帧 · 点击开始后恢复实时取景"
		return
	if _source.selected != 0 or not _result.is_empty() or (_busy and not _collecting):
		return
	var latest: Dictionary = controller.get("latest_frame")
	if not latest.is_empty() and int(latest.frame_id) != _last_display:
		_last_display = int(latest.frame_id)
		_display(latest.jpeg)


func _capture() -> void:
	_next_capture = Time.get_ticks_msec() + CAPTURE_INTERVAL_MS
	if _frames.size() >= MAX_FRAMES:
		return
	var frame: Dictionary = controller.call("capture_moving_frame")
	if frame.has("error"):
		_skipped += 1
		_capture_hint = str(frame.error)
		return
	var identifier := str(frame.timestamp_ns)
	for previous in _captures:
		if previous.capture_id == identifier:
			_skipped += 1
			_capture_hint = "等待新的相机帧；重复画面不会计入融合。"
			return
	if _jpeg_bytes + (frame.jpeg as PackedByteArray).size() > MAX_JPEG_BYTES:
		_skipped += 1
		_capture_hint = "已达到图像缓存上限，将使用已采集的帧。"
		return
	var extrinsics := CameraModel.head_from_camera(frame.metadata)
	var intrinsics := Geometry.intrinsics_from_metadata(frame.metadata, frame.size)
	var intrinsics_error := CameraModel.intrinsics_error(frame.metadata)
	if extrinsics.has("error") or intrinsics.has("error") or not intrinsics_error.is_empty():
		var message := str(extrinsics.get("error", intrinsics_error))
		if message.is_empty():
			message = "当前画面缺少有效且匹配分辨率的单眼相机内参，请检查 Helper 配置。"
		_fail(message)
		return
	var k: Vector4 = intrinsics.k
	var camera_world: Transform3D = (frame.head_world as Transform3D) * (extrinsics.transform as Transform3D)
	for captured in _captures:
		var previous: Transform3D = captured.camera_world
		if camera_world.origin.distance_to(previous.origin) < 0.04:
			_skipped += 1
			_capture_hint = "视点变化不足，请缓慢向侧面移动；原地转头或静止重复拍摄不计入。"
			return
	var camera_up := VisualGeometry.OPENCV_TO_GODOT.basis * camera_world.basis.inverse() * Vector3.UP
	var request_frame := {"capture_id": identifier, "jpeg_base64": Marshalls.raw_to_base64(frame.jpeg),
		"width": frame.size.x, "height": frame.size.y, "rectified": true,
		"world_from_camera": VisualGeometry.to_row_major(camera_world * VisualGeometry.OPENCV_TO_GODOT),
		"camera_up": [camera_up.x, camera_up.y, camera_up.z],
		"K": [[k.x, 0, k.z], [0, k.y, k.w], [0, 0, 1]]}
	var camera_history: Array[Transform3D] = []
	if frame.has("head_history"):
		var encoded_history: Array = []
		for head_pose: Transform3D in frame.head_history:
			var camera_pose := head_pose * (extrinsics.transform as Transform3D)
			camera_history.append(camera_pose)
			encoded_history.append(VisualGeometry.to_row_major(camera_pose * VisualGeometry.OPENCV_TO_GODOT))
		request_frame["camera_history"] = encoded_history
	_frames.append(request_frame)
	_jpeg_bytes += (frame.jpeg as PackedByteArray).size()
	_captures.append({"capture_id": identifier, "camera_world": camera_world,
		"captured_msec": Time.get_ticks_msec(), "camera_history": camera_history})
	_capture_hint = "继续缓慢横移，尽量露出另一侧柜面；柜体本身保持不动。"


func _finish_capture() -> void:
	_collecting = false
	if _captures.size() < 3:
		_fail("12 秒内仅采到 %d 个视角，至少需要 3 个。%s" % [_captures.size(), _capture_hint])
		return
	_launch()


func _launch() -> void:
	_status.text = "%s：已采集 %d 个视角，正在检查画面与头姿的对应关系并联合识别…" % [_kind.get_item_text(_kind.selected), _captures.size()]
	var size_m := dimensions_m()
	var error: String = _job.call("start", {"schema_version": 1, "request_id": _request_id,
		"pose_timing": "interpolated_arrival_estimate",
		"model_kind": model_kind(), "dimensions_m": [size_m.x, size_m.y, size_m.z],
		"mode": "live" if _source.selected == 0 else "demo", "multiview": _source.selected == 0,
		"physical_scale": physical_scale(), "frames": _frames})
	_frames.clear()
	if not error.is_empty():
		_fail(error)


func _on_completed(result: Dictionary) -> void:
	if not _busy:
		return
	if _source.selected == 0 and _epoch != int(controller.get("capture_epoch")):
		_fail("识别期间跟踪空间已变化，请重新识别。")
		return
	if result.get("status") == "error":
		_fail("识别失败：" + str(result.get("error", "未知错误")))
		return
	if str(result.get("request_id", "")) != _request_id \
			or result.get("mode") != ("live" if _source.selected == 0 else "demo"):
		_fail("结果与当前识别请求不匹配。")
		return
	_display(Marshalls.base64_to_raw(str(result.get("overlay_jpeg_base64", ""))))
	var solved := VisualGeometry.validate_batch(result, _captures, physical_scale(), model_kind(), dimensions_m())
	if solved.has("error"):
		# Keep the processed image visible on rejection so the user can inspect
		# the actual framing. It never authorizes application.
		var rejected_image := _image.texture
		_fail(str(solved.error))
		_image.texture = rejected_image
		_hold_rejected_image = true
		return
	var representative: Dictionary = result.frames[solved.representative_index]
	_display(Marshalls.base64_to_raw(str(representative.get("overlay_jpeg_base64", ""))))
	var accepted: bool
	if model_kind() == "cuboid":
		accepted = controller.call("show_cuboid_visual_preview", solved.pose, dimensions_m(), bool(solved.offline), _epoch)
	else:
		accepted = controller.call("show_visual_preview", solved.pose, physical_scale(), result.get("model_points", []),
			bool(solved.offline), _epoch)
	if not accepted:
		_fail("无法创建柜体预览；请检查本地跟踪和当前柜体模型。")
		return
	_result = result
	_set_idle()
	_apply.disabled = bool(solved.offline)
	var extents: Array = result.get("model_extents_m", [])
	if extents.size() == 3:
		_model_info.text = "识别模型（宽 / 高 / 深）：%.1f / %.1f / %.1f cm" % [extents[0] * 100, extents[1] * 100, extents[2] * 100]
	_status.text = "识别成功：绿色图像点为模型投影，空间中显示柜体预览。"
	_status.text += "\n合成演练不可应用现场对齐。" if solved.offline else \
		"\n%d / %d 个视角共同支持该位置。请从多个方向检查贴合后再应用。" % [
			solved.support_count, _captures.size()]


func _confirm() -> void:
	if _result.is_empty() or _source.selected != 0 or _epoch != int(controller.get("capture_epoch")):
		_fail("当前结果不能应用，请重新识别。")
		return
	if controller.call("confirm_preview"):
		_apply.disabled = true
		_status.text = "已按视觉识别结果对齐整个场景。请移动观察柜体是否贴合；系统重新定位后需重新识别。"
	else:
		_fail("对齐未应用，请检查本地跟踪或重新识别。")


func _display(jpeg: PackedByteArray) -> void:
	if jpeg.is_empty() or jpeg.size() > 8 * 1024 * 1024:
		return
	var image := Image.new()
	if image.load_jpg_from_buffer(jpeg) == OK:
		_image.texture = ImageTexture.create_from_image(image)


func _set_idle() -> void:
	_busy = false
	_collecting = false
	_start.disabled = false
	_source.disabled = false
	_scale.disabled = false
	_kind.disabled = false
	for spin in _dimensions:
		spin.editable = true
	for button in _dimension_buttons:
		button.disabled = false


func _reset() -> void:
	if _job != null:
		_job.call("cancel")
	_set_idle()
	_start.text = "开始合成演练" if _source.selected == 1 else "开始多视角扫描"
	_frames.clear()
	_captures.clear()
	_jpeg_bytes = 0
	_skipped = 0
	_capture_hint = ""
	_result.clear()
	_hold_rejected_image = false
	_apply.disabled = true
	_image.texture = null
	controller.call("clear_cabinet")
	_status.text = "已清除识别预览。可重新开始；已应用的空间映射保持不变。"
	_model_info.text = "自定义长方体 · 尺寸单位 cm · 朝向采用面向相机的宽面" if model_kind() == "cuboid" \
		else "模型：Merge_of_储存版-白色哑光_w2.magics · 当前比例 %s" % ("1:1" if _scale.selected == 0 else "1:3")


func _fail(message: String) -> void:
	_reset()
	_status.text = message


func suspend() -> void:
	if _busy:
		_fail("识别已取消。重新打开后可再次开始。")


func _on_state_changed(value: Dictionary) -> void:
	if value.get("status") == "invalid":
		_apply.disabled = true
		_status.text = str(value.get("reason", "标定已失效，请重新识别。"))
