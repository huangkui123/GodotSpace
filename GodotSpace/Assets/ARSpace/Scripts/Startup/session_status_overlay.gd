extends CanvasLayer

signal retry_xr_requested
signal retry_helper_requested
signal stop_requested

var panel: PanelContainer
var details: VBoxContainer
var status_label: Label
var toggle: Button
var scroll: ScrollContainer
var _collapsed := false
var _manually_toggled := false


func _ready() -> void:
	layer = 100
	panel = PanelContainer.new()
	add_child(panel)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.055, 0.07, 0.09, 1.0)
	style.set_corner_radius_all(8)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	panel.add_child(column)
	toggle = Button.new()
	toggle.text = "协作状态 · 收起"
	toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	toggle.pressed.connect(func():
		set_collapsed(not _collapsed))
	column.add_child(toggle)
	details = VBoxContainer.new()
	details.add_theme_constant_override("separation", 10)
	column.add_child(details)
	scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	details.add_child(scroll)
	status_label = Label.new()
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	scroll.add_child(status_label)
	var actions := HFlowContainer.new()
	actions.add_theme_constant_override("h_separation", 8)
	actions.add_theme_constant_override("v_separation", 6)
	details.add_child(actions)
	for item in [["重试 XR", retry_xr_requested], ["重试采集 / 投屏", retry_helper_requested], ["结束协作", stop_requested]]:
		var button := Button.new()
		button.text = item[0]
		button.custom_minimum_size.y = 32
		var requested: Signal = item[1]
		button.pressed.connect(requested.emit)
		actions.add_child(button)
	get_viewport().size_changed.connect(_resize)
	panel.resized.connect(_position_panel)
	_resize()


func set_status(detail: String) -> void:
	status_label.text = detail
	toggle.tooltip_text = detail
	call_deferred("_resize")


func set_collapsed(value: bool) -> void:
	_manually_toggled = true
	_collapsed = value
	details.visible = not value
	toggle.text = "协作状态 · 展开" if value else "协作状态 · 收起"
	call_deferred("_resize")


func _resize() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	if not _manually_toggled:
		_collapsed = viewport_size.x < 1120
		details.visible = not _collapsed
		toggle.text = "协作状态 · 展开" if _collapsed else "协作状态 · 收起"
	var width := minf(230.0 if _collapsed else 430.0, maxf(180.0, viewport_size.x - 24.0))
	panel.custom_minimum_size.x = width
	# Reserve space for buttons; long diagnostics scroll inside the card.
	scroll.custom_minimum_size.y = minf(status_label.get_minimum_size().y, clampf(viewport_size.y - 190, 70, 260))
	panel.size = Vector2(width, 0)
	_position_panel()


func _position_panel() -> void:
	panel.position = Vector2(maxf(12, get_viewport().get_visible_rect().size.x - panel.size.x - 12), 12)
