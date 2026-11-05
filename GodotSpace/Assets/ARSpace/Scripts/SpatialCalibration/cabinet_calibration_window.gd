extends PanelContainer

const Style := preload("res://Assets/ARSpace/Scripts/UI/sky_panel_style.gd")
const CabinetModel := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/calibration_cabinet.gd")
const Geometry := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_geometry.gd")
const PicoCameraModel := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/pico_camera_model.gd")
const ImageView := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_image_view.gd")
const SNAPSHOT_VERSION := 1
const CONFIG_PATH := "user://cabinet_calibration.cfg"
const MAX_SNAPSHOT_BYTES := 16 * 1024 * 1024

var controller: Node
var frame: Dictionary = {}
var base_pose := Transform3D.IDENTITY
var camera_world := Transform3D.IDENTITY
var solved := false
var _frozen := false
var _updating := false
var _tick := 0.0
var _last_display_frame := -1
var _source: OptionButton
var _view: Control
var _dimensions: Array[SpinBox] = []
var _offsets: Array[SpinBox] = []
var _angles: Array[SpinBox] = []
var _intrinsics: Array[SpinBox] = []
var _manual_intrinsics: CheckBox
var _extrinsics: OptionButton
var _status: Label
var _step: Label
var _confirm: Button
var _connection: Label
var _freeze_countdown: float = -1.0
const SNAPSHOT_DIRECTORY := "user://cabinet_snapshots"


func _ready() -> void:
	name = "CabinetCalibrationUI"
	theme = Style.make_theme(20)
	add_theme_stylebox_override("panel", Style.box(Style.BACKGROUND, 0, 10))
	_build_ui()
	_load_dimensions()
	controller.connect("state_changed", _on_state_changed)


func _build_ui() -> void:
	var margin := MarginContainer.new()
	add_child(margin)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	margin.add_child(column)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	column.add_child(header)
	var title := _label(header, "柜体标定")
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Style.ACCENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var drag_hint := _label(header, "射线指向面板 · 按住侧握键拖动")
	drag_hint.custom_minimum_size.x = 380
	Style.secondary(drag_hint)
	_button(header, "放大 / 还原", func(): controller.call("toggle_panel_zoom"))
	_button(header, "关闭", func(): controller.call("close_panel"))
	var steps := HBoxContainer.new()
	steps.add_theme_constant_override("separation", 12)
	column.add_child(steps)
	for caption in ["01  设置尺寸", "02  冻结并选取四角", "03  预览后对齐场景"]:
		var card := PanelContainer.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.add_theme_stylebox_override("panel", Style.box(Style.SURFACE, 12))
		steps.add_child(card)
		_label(card, caption)
	_connection = _label(column, "正在连接 PICO 相机…")
	_connection.custom_minimum_size.y = 26
	_connection.autowrap_mode = TextServer.AUTOWRAP_OFF
	_connection.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	Style.secondary(_connection)
	var content := HBoxContainer.new()
	content.add_theme_constant_override("separation", 20)
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(content)
	var preview := VBoxContainer.new()
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview.add_theme_constant_override("separation", 12)
	content.add_child(preview)
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 10)
	preview.add_child(toolbar)
	_source = OptionButton.new()
	_source.custom_minimum_size.y = 48
	for option in ["实时 PICO", "模拟柜体", "快照回放"]:
		_source.add_item(option)
	_source.item_selected.connect(_on_source_changed)
	toolbar.add_child(_source)
	Style.primary(_button(toolbar, "冻结 / 重新取景", _freeze))
	_button(toolbar, "3 秒后冻结", _schedule_freeze)
	_view = ImageView.new()
	_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view.connect("point_clicked", _on_point_clicked)
	preview.add_child(_view)
	_step = _label(preview, "看向柜体正面并停稳，再冻结画面、依次选择四角。")
	_step.custom_minimum_size.y = 52
	_step.add_theme_color_override("font_color", Style.ACCENT)
	var point_actions := HBoxContainer.new()
	point_actions.add_theme_constant_override("separation", 10)
	preview.add_child(point_actions)
	_button(point_actions, "撤销角点", _undo)
	_button(point_actions, "重新选点", _reset_points)
	var hint := _label(point_actions, "左上 → 右上 → 右下 → 左下")
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	Style.secondary(hint)
	var tabs := TabContainer.new()
	tabs.name = "SettingsTabs"
	tabs.custom_minimum_size.x = 382
	content.add_child(tabs)
	var settings := _settings_tab(tabs, "尺寸")
	_label(settings, "柜体尺寸（米）")
	for i in range(3):
		var spin := _spin(settings, ["宽", "高", "深"][i], 0.05, 20.0, 0.01, CabinetModel.DEFAULT_DIMENSIONS[i])
		spin.value_changed.connect(_on_dimensions_changed)
		_dimensions.append(spin)
	_button(settings, "保存尺寸为默认值", _save_dimensions)
	_button(settings, "手动设置预览起点", _place_in_front)
	Style.secondary(_label(settings, "测量柜体正面宽、高及前后深度。预览后检查位置与角度，再确认对齐。"))
	settings = _settings_tab(tabs, "微调")
	_label(settings, "沿柜体轴微调（米）")
	for i in range(3):
		var spin := _spin(settings, ["左右 X", "上下 Y", "前后 Z"][i], -10, 10, 0.01, 0)
		spin.value_changed.connect(_on_adjusted)
		_offsets.append(spin)
	for axis in ["偏航", "俯仰", "侧倾"]:
		var spin := _spin(settings, axis + "（度）", -180, 180, 0.5, 0)
		spin.value_changed.connect(_on_adjusted)
		_angles.append(spin)
	_button(settings, "重置微调", _reset_adjustments)
	settings = _settings_tab(tabs, "相机")
	_label(settings, "相机与头显的关系")
	_extrinsics = OptionButton.new()
	# Keep snapshot mode 0 for the explicitly selected approximation. Legacy modes
	# 1/2 consumed raw matrices in the wrong coordinate frame and are no longer used.
	_extrinsics.add_item("PICO 4 Ultra · 设备外参", 3)
	_extrinsics.add_item("头部近似（需现场微调）", 0)
	_extrinsics.item_selected.connect(func(_index: int): _invalidate_solution())
	settings.add_child(_extrinsics)
	_label(settings, "设备外参自动区分左右相机；确认前请从正面与侧面检查对齐。")
	_manual_intrinsics = CheckBox.new()
	_manual_intrinsics.text = "手动输入当前图像内参"
	_manual_intrinsics.toggled.connect(func(_value: bool): _invalidate_solution())
	settings.add_child(_manual_intrinsics)
	for i in range(4):
		var spin := _spin(settings, ["fx", "fy", "cx", "cy"][i], 0, 40000, 0.1, [650, 650, 480, 360][i])
		spin.value_changed.connect(func(_value: float):
			if not _updating:
				_invalidate_solution())
		_intrinsics.append(spin)
	settings = _settings_tab(tabs, "工具")
	_label(settings, "离线检查与快照")
	Style.secondary(_label(settings, "模拟和回放只用于检查，不会改变当前空间对齐。"))
	_button(settings, "保存当前快照", _choose_save)
	_button(settings, "打开最近快照", _load_latest_snapshot)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	column.add_child(actions)
	_button(actions, "清除标定", _clear)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(spacer)
	_button(actions, "计算并预览柜体", _solve)
	_confirm = _button(actions, "确认并对齐整个场景", _confirm_cabinet)
	Style.primary(_confirm)
	_confirm.disabled = true
	_status = _label(column, "请先确认柜体实测尺寸。完成预览后，可从正面与侧面检查对齐。")
	_status.custom_minimum_size.y = 52
	Style.secondary(_status)



func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 48
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _label(parent: Node, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func _spin(parent: Node, label: String, minimum: float, maximum: float,
		step: float, initial: float) -> SpinBox:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var caption := Label.new()
	caption.text = label
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(caption)
	var spin := SpinBox.new()
	var minus := _button(row, "−", func(): spin.value -= spin.step)
	minus.custom_minimum_size.x = 44
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value = initial
	spin.custom_minimum_size.x = 125
	row.add_child(spin)
	var plus := _button(row, "+", func(): spin.value += spin.step)
	plus.custom_minimum_size.x = 44
	return spin


func _settings_tab(tabs: TabContainer, caption: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = caption
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)
	var settings := VBoxContainer.new()
	settings.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	settings.add_theme_constant_override("separation", 10)
	scroll.add_child(settings)
	return settings


func dimensions() -> Vector3:
	return Vector3(_dimensions[0].value, _dimensions[1].value, _dimensions[2].value)


func _process(delta: float) -> void:
	if _freeze_countdown >= 0.0:
		_freeze_countdown -= delta
		_status.text = "请看向实物柜体，停稳头部：%.0f 秒后冻结。" % ceilf(maxf(_freeze_countdown, 0.0))
		if _freeze_countdown < 0.0:
			_freeze()
	_tick += delta
	if _tick < 0.12:
		return
	_tick = 0.0
	_connection.text = str(controller.call("get_capture_status")) if _source.selected == 0 \
		else "离线演练 · 不会改变当前空间对齐"
	_connection.tooltip_text = _connection.text
	if not is_visible_in_tree() or _frozen or _source.selected != 0:
		return
	var latest: Dictionary = controller.get("latest_frame")
	if latest.is_empty() or int(latest.frame_id) == _last_display_frame:
		return
	_last_display_frame = int(latest.frame_id)
	_display_jpeg(latest.jpeg, latest.size)


func _display_jpeg(bytes: PackedByteArray, expected_size: Vector2i) -> bool:
	if bytes.is_empty() or bytes.size() > 8 * 1024 * 1024:
		return false
	var image := Image.new()
	if image.load_jpg_from_buffer(bytes) != OK:
		return false
	if image.get_size() != expected_size:
		return false
	_view.set("texture", ImageTexture.create_from_image(image))
	_view.set("image_size", expected_size)
	_view.set("wire_points", PackedVector2Array())
	_view.queue_redraw()
	return true


func _on_source_changed(index: int) -> void:
	_freeze_countdown = -1.0
	_clear()
	frame.clear()
	_frozen = false
	_last_display_frame = -1
	_view.set("texture", null)
	_view.set("wire_points", PackedVector2Array())
	if index == 1:
		_make_demo()
	elif index == 2:
		_load_latest_snapshot()
	else:
		_extrinsics.select(_extrinsics.get_item_index(3))
		_status.text = "实时取景：请看向柜体正面，并保持静止约 1.5 秒。"
	_view.queue_redraw()


func _freeze() -> void:
	if _source.selected != 0:
		_status.text = "离线图像已经冻结，可以直接选点。"
		return
	if _frozen:
		_clear()
		frame.clear()
		_frozen = false
		return
	var snapshot: Dictionary = controller.call("freeze_frame")
	if snapshot.has("error"):
		_status.text = str(snapshot.error)
		return
	if not _display_jpeg(snapshot.jpeg, snapshot.size):
		_status.text = "图像解码或尺寸检查失败。"
		return
	frame = snapshot
	_frozen = true
	_reset_points()
	var result := Geometry.intrinsics_from_metadata(frame.metadata, frame.size)
	if result.has("k"):
		_set_intrinsics(result.k)
	_status.text = "画面已冻结。请依次选择柜体正面的左上、右上、右下、左下角。"


func _on_point_clicked(pixel: Vector2) -> void:
	if not _frozen:
		_status.text = "先冻结画面，再选择角点。"
		return
	var points: PackedVector2Array = _view.get("points")
	if points.size() >= 4:
		_status.text = "已选满四角，可计算，或撤销后修改。"
		return
	_invalidate_solution()
	points.append(pixel)
	_view.set("points", points)
	_view.queue_redraw()
	_update_step()


func _update_step() -> void:
	var count: int = (_view.get("points") as PackedVector2Array).size()
	_step.text = "四角已选齐：请点击“计算并预览柜体”。" if count == 4 \
		else "第 %d / 4 点：请选择正面%s角（深度向柜体背后延伸）。" % [count + 1, ["左上", "右上", "右下", "左下"][count]]


func _undo() -> void:
	var points: PackedVector2Array = _view.get("points")
	if not points.is_empty():
		points.resize(points.size() - 1)
		_view.set("points", points)
		_invalidate_solution()
		_view.queue_redraw()
		_update_step()


func _reset_points() -> void:
	_view.set("points", PackedVector2Array())
	_invalidate_solution()
	_view.queue_redraw()
	_update_step()


func _invalidate_solution() -> void:
	solved = false
	_confirm.disabled = true
	_view.set("fitted_points", PackedVector2Array())
	controller.call("clear_cabinet")
	_view.queue_redraw()


func _on_dimensions_changed(_value: float) -> void:
	if not _updating:
		_invalidate_solution()


func _get_intrinsics() -> Dictionary:
	var result := Geometry.intrinsics_from_metadata(frame.get("metadata", {}), frame.get("size", Vector2i.ZERO))
	# Manual parameters do not authorize an unsupported raw/stereo image mode.
	var metadata: Dictionary = frame.get("metadata", {})
	if bool(metadata.get("output_camera_raw_data", true)) or int(metadata.get("render_mode", -1)) not in [0, 1]:
		return result
	if _manual_intrinsics.button_pressed:
		var k := Vector4(_intrinsics[0].value, _intrinsics[1].value, _intrinsics[2].value, _intrinsics[3].value)
		if not Geometry.valid_intrinsics(k, frame.size):
			return {"error": "手动相机内参无效。"}
		return {"k": k}
	if _extrinsics.get_selected_id() == 3:
		var error := PicoCameraModel.intrinsics_error(metadata)
		if not error.is_empty():
			return {"error": error}
	return result


func _camera_transform() -> Dictionary:
	var head: Transform3D = frame.head_world
	if _extrinsics.get_selected_id() == 0:
		return {"transform": head}
	var result := PicoCameraModel.head_from_camera(frame.metadata)
	if result.has("error"):
		return result
	return {"transform": head * (result.transform as Transform3D)}


func _solve() -> void:
	if frame.is_empty() or not _frozen:
		_status.text = "请先冻结画面或选择模拟柜体。"
		return
	_invalidate_solution()
	var intrinsics := _get_intrinsics()
	if intrinsics.has("error"):
		_status.text = str(intrinsics.error)
		return
	var result := Geometry.solve(_view.get("points"), dimensions(), intrinsics.k, frame.size)
	if result.has("error"):
		_status.text = str(result.error)
		return
	var camera := _camera_transform()
	if camera.has("error"):
		_status.text = str(camera.error)
		return
	camera_world = camera.transform
	base_pose = camera_world * (result.transform as Transform3D)
	solved = true
	_reset_adjustments()
	_status.text = "橙色线框为实物位置，拟合误差 %.2f px（不是实际空间精度）。确认后整体对齐虚拟场景，柜子在场景内保持固定。" % float(result.rms_px)
	if bool(frame.get("offline", false)):
		_status.text += " 当前为离线演练，不会应用空间对齐。"


func _place_in_front() -> void:
	if _source.selected != 0:
		_status.text = "手动放置需要切换到实时 PICO 并戴好头显。"
		return
	var head: Dictionary = controller.call("get_head_sample")
	if head.is_empty():
		_status.text = "本地头部跟踪尚未就绪。"
		return
	var transform: Transform3D = head.transform
	var forward := -transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.01:
		_status.text = "请平视前方后再放置。"
		return
	forward = forward.normalized()
	var basis := Basis(Vector3.UP.cross(-forward), Vector3.UP, -forward)
	base_pose = Transform3D(basis, transform.origin + forward * 2.0 \
		- basis.x * dimensions().x * 0.5 - Vector3.UP * dimensions().y * 0.5)
	frame = {"head_world": transform,
		"epoch": int(controller.get("capture_epoch")), "offline": false, "manual": true}
	solved = true
	_reset_adjustments()
	_status.text = "已放在头显前方约 2 米。请戴头显观察，调整左右、上下、前后和朝向，重合后确认。"


func _reset_adjustments() -> void:
	_updating = true
	for spin in _offsets + _angles:
		spin.value = 0
	_updating = false
	_on_adjusted(0)


func _on_adjusted(_value: float) -> void:
	if _updating or not solved:
		return
	if not bool(frame.get("offline", false)) and int(frame.get("epoch", -1)) != int(controller.get("capture_epoch")):
		_invalidate_solution()
		_status.text = "取景之后连接或空间原点已变化，请重新取景。"
		return
	var offset := Vector3(_offsets[0].value, _offsets[1].value, _offsets[2].value)
	var rotation := Basis.from_euler(Vector3(deg_to_rad(_angles[1].value),
		deg_to_rad(_angles[0].value), deg_to_rad(_angles[2].value)))
	var pose := Transform3D(base_pose.basis * rotation, base_pose.origin + base_pose.basis * offset)
	var offline := bool(frame.get("offline", false))
	if not bool(controller.call("show_preview", pose, dimensions(), offline)):
		_invalidate_solution()
		_status.text = "无法预览，头显可能已断开。"
		return
	_confirm.disabled = offline
	if not bool(frame.get("manual", false)):
		var intrinsics := _get_intrinsics()
		if intrinsics.has("k"):
			var wire := PackedVector2Array()
			for point in Geometry.corners(dimensions()):
				wire.append(Geometry.project(camera_world.affine_inverse() * pose, point, intrinsics.k))
			_view.set("fitted_points", wire)
			_view.queue_redraw()


func _confirm_cabinet() -> void:
	if int(frame.get("epoch", -1)) != int(controller.get("capture_epoch")):
		_status.text = "连接或空间原点已变化，请重新标定。"
		return
	if bool(controller.call("confirm_preview")):
		_status.text = "整个虚拟场景已在本机对齐，请观察柜体与实物是否重合。"
		_confirm.disabled = true
	else:
		_status.text = "未确认：请检查本地头部跟踪；离线演练不能应用对齐。"


func _on_state_changed(value: Dictionary) -> void:
	if str(value.get("status")) in ["confirmed"]:
		solved = false
		_confirm.disabled = true
		if str(value.status) == "confirmed":
			_status.text = "整个虚拟场景已对齐。柜体、地板和其他物体的相对位置保持不变；重新定位后需重标定。"
	if str(value.get("status")) == "invalid":
		solved = false
		_confirm.disabled = true
		_status.text = str(value.get("reason", "请重新标定。"))


func _clear() -> void:
	_invalidate_solution()
	_view.set("points", PackedVector2Array())
	_view.queue_redraw()
	_status.text = "标定记录已清除。虚拟柜体保持场景原位，请重新取景；当前空间映射保留到下次标定或重新定位。"


func _set_intrinsics(k: Vector4) -> void:
	_updating = true
	for i in range(4):
		_intrinsics[i].value = k[i]
	_updating = false


func _make_demo() -> void:
	_extrinsics.select(_extrinsics.get_item_index(0))
	_updating = true
	for i in range(3):
		_dimensions[i].value = CabinetModel.DEFAULT_DIMENSIONS[i]
	_updating = false
	var k := Vector4(650, 650, 480, 360)
	var size_m := dimensions()
	var rotation := Basis(Vector3.UP, 0.22)
	var center := Vector3(size_m.x * 0.5, size_m.y * 0.5, -size_m.z * 0.5)
	var distance := maxf(size_m.x, maxf(size_m.y, size_m.z)) * 2.5
	var pose := Transform3D(rotation, Vector3(0, 0, -distance) - rotation * center)
	var wire := PackedVector2Array()
	for point in Geometry.corners(dimensions()):
		wire.append(Geometry.project(pose, point, k))
	frame = {"offline": true, "size": Vector2i(960, 720), "head_world": Transform3D.IDENTITY,
		"frame_id": 0, "timestamp_ns": "0", "jpeg": PackedByteArray(),
		"metadata": {"output_camera_raw_data": false, "render_mode": 0,
			"camera_intrinsics_width": 960, "camera_intrinsics_height": 720,
			"camera_intrinsics_fx": 650.0, "camera_intrinsics_fy": 650.0,
			"camera_intrinsics_cx": 480.0, "camera_intrinsics_cy": 360.0}}
	_view.set("image_size", Vector2i(960, 720))
	_view.set("wire_points", wire)
	_view.set("texture", null)
	_set_intrinsics(k)
	_frozen = true
	_reset_points()
	_status.text = "模拟柜体：请选择正面四角。灰色为输入图形，绿色为解算结果；不应用空间对齐。"


func _save_dimensions() -> void:
	var config := ConfigFile.new()
	config.set_value("cabinet", "dimensions_m", dimensions())
	_status.text = "尺寸已保存；不会跨重启自动恢复空间位置。" if config.save(CONFIG_PATH) == OK else "尺寸保存失败。"


func _load_dimensions() -> void:
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		return
	var value: Variant = config.get_value("cabinet", "dimensions_m")
	if not value is Vector3 or not Geometry.valid_dimensions(value):
		return
	_updating = true
	for i in range(3):
		_dimensions[i].value = value[i]
	_updating = false


func _choose_save() -> void:
	if frame.is_empty() or bool(frame.get("manual", false)):
		_status.text = "请先冻结一帧或使用模拟柜体，再保存可回放快照。"
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SNAPSHOT_DIRECTORY))
	var filename := "cabinet_%s_%d.json" % [Time.get_datetime_string_from_system().replace(":", "-"), Time.get_ticks_msec()]
	save_snapshot(SNAPSHOT_DIRECTORY.path_join(filename))


func _load_latest_snapshot() -> void:
	var files := DirAccess.get_files_at(SNAPSHOT_DIRECTORY)
	files.sort()
	files.reverse()
	for filename in files:
		if filename.begins_with("cabinet_") and filename.ends_with(".json"):
			load_snapshot(SNAPSHOT_DIRECTORY.path_join(filename))
			return
	_status.text = "尚无本机快照，请先冻结并保存，或选择模拟柜体。"


func _schedule_freeze() -> void:
	if _source.selected != 0:
		_status.text = "请先切换到实时 PICO。"
		return
	_frozen = false
	frame.clear()
	_reset_points()
	_freeze_countdown = 3.0


func save_snapshot(path: String) -> void:
	if frame.is_empty() or bool(frame.get("manual", false)):
		return
	var points: Array = []
	for point in _view.get("points"):
		points.append([point.x, point.y])
	var wire: Array = []
	for point in _view.get("wire_points"):
		wire.append([point.x, point.y])
	var jpeg: PackedByteArray = frame.get("jpeg", PackedByteArray())
	var document := {"schema_version": SNAPSHOT_VERSION, "dimensions_m": [dimensions().x, dimensions().y, dimensions().z],
		"size": [frame.size.x, frame.size.y], "metadata": frame.metadata,
		"head_world": Geometry.encode_transform(frame.head_world), "points": points,
		"frame_id": frame.get("frame_id", -1), "timestamp_ns": frame.get("timestamp_ns", "0"),
		"jpeg_base64": "" if jpeg.is_empty() else Marshalls.raw_to_base64(jpeg), "wire_points": wire,
		"extrinsics_mode": _extrinsics.get_selected_id(), "manual_intrinsics": _manual_intrinsics.button_pressed,
		"intrinsics": [_intrinsics[0].value, _intrinsics[1].value, _intrinsics[2].value, _intrinsics[3].value],
		"result": controller.get("state")}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_status.text = "快照保存失败：%s" % error_string(FileAccess.get_open_error())
		return
	file.store_string(JSON.stringify(document, "\t"))
	_status.text = "快照已保存：%s" % path


func load_snapshot(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > MAX_SNAPSHOT_BYTES:
		_status.text = "无法读取快照，或文件超过 16 MiB。"
		return
	var value: Variant = JSON.parse_string(file.get_as_text())
	if not _valid_snapshot(value):
		_status.text = "快照格式、尺寸或位姿无效。"
		return
	var document: Dictionary = value
	if int(document.get("extrinsics_mode", 0)) in [1, 2]:
		_status.text = "此快照使用旧版未转换外参，请重新取景标定；原始快照文件仍保留。"
		return
	var size_array: Array = document.size
	var size_value := Vector2i(size_array[0], size_array[1])
	var jpeg := PackedByteArray() if str(document.jpeg_base64).is_empty() else Marshalls.base64_to_raw(str(document.jpeg_base64))
	if not str(document.jpeg_base64).is_empty() and jpeg.is_empty():
		_status.text = "快照图像编码无效。"
		return
	if not jpeg.is_empty() and not _display_jpeg(jpeg, size_value):
		_status.text = "快照图像无效。"
		return
	_clear()
	_source.select(2)
	_updating = true
	for i in range(3):
		_dimensions[i].value = document.dimensions_m[i]
	_updating = false
	frame = {"offline": true, "size": size_value, "jpeg": jpeg,
		"head_world": Geometry.decode_transform(document.head_world), "metadata": document.metadata,
		"frame_id": document.get("frame_id", -1), "timestamp_ns": document.get("timestamp_ns", "0")}
	var points := PackedVector2Array()
	for p in document.points:
		points.append(Vector2(p[0], p[1]))
	var wire := PackedVector2Array()
	for p in document.get("wire_points", []):
		wire.append(Vector2(p[0], p[1]))
	_view.set("points", points)
	_view.set("wire_points", wire)
	_view.set("image_size", size_value)
	if jpeg.is_empty():
		_view.set("texture", null)
	var values: Array = document.intrinsics
	_set_intrinsics(Vector4(values[0], values[1], values[2], values[3]))
	_manual_intrinsics.set_pressed_no_signal(bool(document.get("manual_intrinsics", false)))
	_extrinsics.select(_extrinsics.get_item_index(int(document.get("extrinsics_mode", 0))))
	_frozen = true
	_view.queue_redraw()
	_update_step()
	_status.text = "快照已载入，可重新计算。旧空间位置仅用于离线分析，不能应用空间对齐。"


static func _valid_snapshot(value: Variant) -> bool:
	if not value is Dictionary or int(value.get("schema_version", -1)) != SNAPSHOT_VERSION:
		return false
	for key in ["dimensions_m", "size", "intrinsics", "points", "wire_points"]:
		if not value.get(key) is Array:
			return false
	if value.dimensions_m.size() != 3 or value.size.size() != 2 or value.intrinsics.size() != 4 \
			or value.points.size() > 4 or value.wire_points.size() not in [0, 8]:
		return false
	if str(value.get("jpeg_base64", "")).is_empty() and value.wire_points.size() != 8:
		return false
	for key in ["dimensions_m", "size", "intrinsics"]:
		for number in value[key]:
			if typeof(number) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(number)):
				return false
	if value.size[0] < 1 or value.size[1] < 1 or value.size[0] > 4096 or value.size[1] > 4096:
		return false
	for key in ["points", "wire_points"]:
		for point in value[key]:
			if not point is Array or point.size() != 2:
				return false
			for number in point:
				if typeof(number) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(number)):
					return false
	return Geometry.valid_dimensions(Vector3(value.dimensions_m[0], value.dimensions_m[1], value.dimensions_m[2])) \
		and Geometry.decode_transform(value.get("head_world")) != null \
		and value.get("metadata") is Dictionary and value.get("jpeg_base64") is String \
		and int(value.get("extrinsics_mode", -1)) in [0, 1, 2, 3]
