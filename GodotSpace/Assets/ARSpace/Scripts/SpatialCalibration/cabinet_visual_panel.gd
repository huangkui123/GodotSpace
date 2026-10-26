extends PanelContainer

const Style := preload("res://Assets/ARSpace/Scripts/UI/sky_panel_style.gd")
const Geometry := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_geometry.gd")
const VisualGeometry := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_visual_geometry.gd")
const CameraModel := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/pico_camera_model.gd")
const Job := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_visual_job.gd")

var controller: Node
var _job: Node
var _source: OptionButton
var _scale: OptionButton
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
var _epoch: int = -1
var _request_id := ""
var _frames: Array[Dictionary] = []
var _captures: Array[Dictionary] = []
var _last_display: int = -1
var _display_tick := 0.0
var _result: Dictionary = {}


func _ready() -> void:
	name = "CabinetVisualUI"
	theme = Style.make_theme(20)
	add_theme_stylebox_override("panel", Style.box(Style.BACKGROUND, 0, 16))
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	margin.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	var title := _label(header, "柜体 CAD 自动识别")
	title.autowrap_mode = TextServer.AUTOWRAP_OFF
	title.add_theme_font_size_override("font_size", 30)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button(header, "放大 / 还原", func(): controller.call("toggle_panel_zoom"))
	_button(header, "关闭", func(): controller.call("close_panel"))
	_label(column, "看向柜体 → 自动匹配 CAD → 检查预览并应用；无需人工选点")
	var options := HBoxContainer.new()
	options.add_theme_constant_override("separation", 16)
	column.add_child(options)
	_source = OptionButton.new()
	_source.add_item("实时 PICO")
	_source.add_item("CAD 合成演练（无实物）")
	_source.item_selected.connect(func(_index: int): _reset())
	options.add_child(_source)
	var scale_caption := _label(options, "实物 / 原模型比例")
	scale_caption.autowrap_mode = TextServer.AUTOWRAP_OFF
	_scale = OptionButton.new()
	_scale.add_item("1:1 原尺寸")
	_scale.add_item("1:3 打印缩比")
	_scale.item_selected.connect(func(_index: int): _reset())
	options.add_child(_scale)
	_model_info = _label(column, "模型：Merge_of_储存版-白色哑光_w2.magics 装配体 · 默认 1:1")
	_connection = _label(column, "正在检查相机连接…")
	_connection.autowrap_mode = TextServer.AUTOWRAP_OFF
	_connection.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_image = TextureRect.new()
	_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_image.custom_minimum_size = Vector2(600, 330)
	_image.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# No input handlers/point collection in the CAD workflow.
	_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_image)
	_status = _label(column, "看清柜体整体和结构细节后点击开始。识别期间请保持头部与实物稳定。")
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
	_label(column, "当前为实验性 RGB 识别；实柜精度待验证。合成演练不会改变空间对齐。")
	_job = Job.new()
	_job.connect("completed", _on_completed)
	add_child(_job)
	controller.connect("state_changed", _on_state_changed)


func _button(parent: Node, caption: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.custom_minimum_size.y = 48
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
	return 1.0 if _scale.selected == 0 else 1.0 / 3.0


func _begin() -> void:
	_reset()
	_busy = true
	_start.disabled = true
	_source.disabled = true
	_scale.disabled = true
	_epoch = int(controller.get("capture_epoch"))
	_request_id = "%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	if _source.selected == 1:
		var head: Dictionary = controller.call("get_head_sample")
		_captures.append({"capture_id": "demo", "camera_world": head.get("transform", Transform3D.IDENTITY)})
		_launch()
	else:
		_collecting = true
		_next_capture = Time.get_ticks_msec() + 3000
		_deadline = Time.get_ticks_msec() + 15000
		_status.text = "3 秒后开始取图。请看向柜体并停稳；将自动采集三帧，无需点选。"


func _process(delta: float) -> void:
	if _busy and _source.selected == 0 and _epoch != int(controller.get("capture_epoch")):
		_fail("相机连接或跟踪空间发生变化，旧识别已取消，请重新识别。")
		return
	if _collecting:
		var now := Time.get_ticks_msec()
		if now > _deadline:
			_fail("自动取图超时。请检查相机画面、头部跟踪，并保持静止后重试。")
		elif now >= _next_capture:
			_capture()
	_display_tick += delta
	if _display_tick < 0.15:
		return
	_display_tick = 0.0
	_connection.text = str(controller.call("get_capture_status")) if _source.selected == 0 else "CAD 合成图像 · 离线演练"
	if _source.selected != 0 or not _result.is_empty() or (_busy and not _collecting):
		return
	var latest: Dictionary = controller.get("latest_frame")
	if not latest.is_empty() and int(latest.frame_id) != _last_display:
		_last_display = int(latest.frame_id)
		_display(latest.jpeg)


func _capture() -> void:
	_next_capture = Time.get_ticks_msec() + 350
	var frame: Dictionary = controller.call("freeze_frame")
	if frame.has("error"):
		_status.text = str(frame.error)
		return
	var identifier := str(frame.timestamp_ns)
	for previous in _captures:
		if previous.capture_id == identifier:
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
	_frames.append({"capture_id": identifier, "jpeg_base64": Marshalls.raw_to_base64(frame.jpeg),
		"width": frame.size.x, "height": frame.size.y, "rectified": true,
		"K": [[k.x, 0, k.z], [0, k.y, k.w], [0, 0, 1]]})
	_captures.append({"capture_id": identifier, "camera_world": (frame.head_world as Transform3D) * (extrinsics.transform as Transform3D)})
	_status.text = "已自动采集 %d / 3 帧。" % _frames.size()
	if _frames.size() == 3:
		_collecting = false
		_launch()


func _launch() -> void:
	_status.text = "正在匹配真实柜体 CAD 并估计姿态…"
	var error: String = _job.call("start", {"schema_version": 1, "request_id": _request_id,
		"mode": "live" if _source.selected == 0 else "demo", "physical_scale": physical_scale(), "frames": _frames})
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
	var solved := VisualGeometry.validate_batch(result, _captures, physical_scale())
	if solved.has("error"):
		_fail(str(solved.error))
		return
	var accepted: bool = controller.call("show_visual_preview", solved.pose, physical_scale(), result.get("model_points", []),
		bool(solved.offline), _epoch)
	if not accepted:
		_fail("无法创建 CAD 预览；请检查本地跟踪和场景中的实验柜模型。")
		return
	_result = result
	_set_idle()
	_apply.disabled = bool(solved.offline)
	var extents: Array = result.get("model_extents_m", [])
	if extents.size() == 3:
		_model_info.text = "CAD 模型尺寸（X / Y / Z）：%.3f / %.3f / %.3f 米 · 比例 %s" % [extents[0], extents[1], extents[2], "1:1" if _scale.selected == 0 else "1:3"]
	_status.text = "CAD 识别成功：绿色图像点为模型投影，空间中显示 CAD 点云预览。"
	_status.text += "\n合成演练不可应用现场对齐。" if solved.offline else "\n三帧姿态一致；从不同方向检查后可应用。实柜精度尚未验证。"


func _confirm() -> void:
	if _result.is_empty() or _source.selected != 0 or _epoch != int(controller.get("capture_epoch")):
		_fail("当前结果不能应用，请重新识别。")
		return
	if controller.call("confirm_preview"):
		_apply.disabled = true
		_status.text = "已按 CAD 识别结果对齐整个场景。请移动观察柜体是否贴合；系统重新定位后需重新识别。"
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


func _reset() -> void:
	if _job != null:
		_job.call("cancel")
	_set_idle()
	_frames.clear()
	_captures.clear()
	_result.clear()
	_apply.disabled = true
	_image.texture = null
	controller.call("clear_cabinet")
	_status.text = "已清除识别预览。可重新开始；已应用的空间映射保持不变。"
	_model_info.text = "模型：Merge_of_储存版-白色哑光_w2.magics · 当前比例 %s" % ("1:1" if _scale.selected == 0 else "1:3")


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
