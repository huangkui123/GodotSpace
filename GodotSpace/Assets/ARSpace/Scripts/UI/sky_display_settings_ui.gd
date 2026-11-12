extends PanelContainer

const Style := preload("res://Assets/ARSpace/Scripts/UI/sky_panel_style.gd")

const Preferences := preload("res://Assets/ARSpace/Scripts/XR/sky_view_preferences.gd")
const Probe := preload("res://Assets/ARSpace/Scripts/XR/mr_passthrough_probe.gd")

var _sliders: Array[HSlider] = []
var _values: Array[Label] = []
var _status: Label
var _timer: Timer
var _scene: Node


func _ready() -> void:
	name = "SkyDisplaySettings"
	position = Vector2.ZERO
	size = Vector2(446, 348)
	z_index = 2
	theme = Style.make_theme(14)
	add_theme_stylebox_override("panel", Style.box(Style.BACKGROUND, 12))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	add_child(column)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	column.add_child(header)
	var back := _button(header, "‹", hide)
	back.tooltip_text = "返回工作页"
	back.add_theme_font_size_override("font_size", 22)
	var title := _label(header, "显示设置", true)
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Style.ACCENT)
	Style.secondary(_label(header, "天上端"))
	Style.secondary(_label(column, "调低可看清实景，调高可看清虚拟内容。"))
	for i in range(3):
		var group := VBoxContainer.new()
		group.add_theme_constant_override("separation", 0)
		column.add_child(group)
		var caption := HBoxContainer.new()
		group.add_child(caption)
		_label(caption, ["物体 / 文字", "窗口面板", "地板 / 后墙"][i], true)
		var value_label := _label(caption, "100%")
		value_label.add_theme_color_override("font_color", Style.ACCENT)
		_values.append(value_label)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		group.add_child(row)
		_button(row, "−", _step_opacity.bind(i, -5))
		var slider := HSlider.new()
		slider.max_value = 100
		slider.step = 1
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.custom_minimum_size.y = 28
		var track := Style.box(Color("354768"), 0, 3)
		track.content_margin_top = 3
		track.content_margin_bottom = 3
		slider.add_theme_stylebox_override("slider", track)
		var fill := track.duplicate() as StyleBoxFlat
		fill.bg_color = Style.ACCENT
		slider.add_theme_stylebox_override("grabber_area", fill)
		slider.add_theme_stylebox_override("grabber_area_highlight", fill)
		row.add_child(slider)
		_sliders.append(slider)
		slider.value_changed.connect(_on_opacity_changed)
		_button(row, "+", _step_opacity.bind(i, 5))
	var presets := HBoxContainer.new()
	presets.add_theme_constant_override("separation", 8)
	column.add_child(presets)
	_button(presets, "清晰模式", _set_opacity.bind(Vector3(1, 1, 0.25)), true)
	_button(presets, "恢复默认", _set_opacity.bind(Preferences.DEFAULT_OPACITY), true)
	Style.primary(_button(presets, "保存为默认", _save, true))
	var choices := HBoxContainer.new()
	choices.add_theme_constant_override("separation", 8)
	column.add_child(choices)
	choices.hide()
	var probe_button := _button(presets, "透视检查", func():
		presets.hide()
		choices.show()
		_status.text = "选择对照画面；5 秒后恢复，不修改透明度设置。", true)
	probe_button.name = "PassthroughProbeButton"
	probe_button.tooltip_text = "比较空画面、隐藏柜体组和仅显示柜体组，定位黑区来源。"
	for mode in [Probe.Mode.BLANK, Probe.Mode.HIDE_CABINET, Probe.Mode.ONLY_CABINET]:
		var choice := _button(choices, ["空画面", "隐藏柜体组", "仅柜体组"][mode], _probe_passthrough.bind(mode), true)
		choice.name = "ProbeMode%d" % mode
		choice.tooltip_text = "柜体组包含固定柜壳、拆装部件和柜上滑条；仅在检查期间改变显示。"
	_button(choices, "返回", func():
		choices.hide()
		presets.show())
	_status = _label(column, "仅本头显生效 · 主面板始终清晰")
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.size_flags_vertical = Control.SIZE_EXPAND_FILL
	Style.secondary(_status)
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = 0.12
	_timer.timeout.connect(_apply_opacity)
	add_child(_timer)
	hide()


func _button(parent: Node, text: String, action: Callable, expand: bool = false) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(30, 28)
	if expand:
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _label(parent: Node, text: String, expand: bool = false) -> Label:
	var label := Label.new()
	label.text = text
	if expand:
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(label)
	return label


func open_settings(scene: Node) -> void:
	_scene = scene
	if not is_instance_valid(_scene) or not _scene.has_method("get_sky_opacity"):
		return
	_set_slider_values(_scene.call("get_sky_opacity"))
	show()


func _set_slider_values(value: Vector3) -> void:
	for i in range(3):
		_sliders[i].set_value_no_signal(value[i] * 100.0)
	_refresh_values()


func _refresh_values() -> void:
	for i in range(3):
		_values[i].text = "%d%%" % int(_sliders[i].value)


func _step_opacity(index: int, amount: float) -> void:
	_sliders[index].value += amount


func _on_opacity_changed(_value: float) -> void:
	_refresh_values()
	if _timer.is_stopped():
		_timer.start()


func _apply_opacity() -> void:
	if is_instance_valid(_scene):
		_scene.call("set_sky_opacity", Vector3(_sliders[0].value,
			_sliders[1].value, _sliders[2].value) / 100.0)


func _set_opacity(value: Vector3) -> void:
	_timer.stop()
	_set_slider_values(value)
	_apply_opacity()


func _probe_passthrough(mode: int = Probe.Mode.BLANK) -> void:
	if is_instance_valid(_scene) and _scene.has_method("start_passthrough_probe") and bool(_scene.call("start_passthrough_probe", mode)):
		_status.text = "%s：5 秒后恢复；请观察原黑区。" % ["空画面", "隐藏柜体组", "仅柜体组"][mode]
	else:
		_status.text = "请在天上端 MR 运行时检查，勿连续点击。"


func _save() -> void:
	if not is_instance_valid(_scene):
		_status.text = "场景尚未就绪，暂不能保存。"
		return
	_timer.stop()
	_apply_opacity()
	var error := Preferences.save_values(_scene.call("get_sky_opacity"))
	_status.text = "已保存；下次进入天上端自动使用。" if error == OK else "保存失败：%s" % error_string(error)
