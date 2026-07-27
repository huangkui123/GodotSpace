class_name RealtimeReconstructionPanelUI
extends Control

signal exit_requested
signal start_requested
signal import_requested
signal cancel_requested
signal confirm_requested
signal retry_requested
signal stop_requested
signal reregister_requested
signal export_requested
signal new_session_requested
signal clear_requested
signal recenter_requested
signal point_cloud_visibility_requested(is_visible: bool)
signal manual_adjustment_requested(kind: StringName, amount: float)
signal map_selected(map_id: String)

enum ViewState {
	PREPARE,
	PREFLIGHT,
	COLLECTING,
	SOLVING,
	PREVIEW,
	LIVE,
	STOPPED,
	IMPORTING,
	ERROR,
}

const ROLE_SKY: String = "sky"
const ROLE_GROUND_VR: String = "ground_vr"
const READY_COLOR := Color(0.32, 0.92, 0.62, 1.0)
const WAITING_COLOR := Color(1.0, 0.72, 0.28, 1.0)
const ERROR_COLOR := Color(1.0, 0.38, 0.38, 1.0)

@onready var state_label: Label = $Margin/Layout/Header/StateLabel
@onready var role_label: Label = $Margin/Layout/Header/RoleLabel
@onready var exit_button: Button = $Margin/Layout/Header/ExitButton
@onready var recenter_button: Button = $Margin/Layout/Header/RecenterButton
@onready var helper_status: Label = $Margin/Layout/ServiceGrid/HelperStatus
@onready var lab_status: Label = $Margin/Layout/ServiceGrid/LabStatus
@onready var point_channel_status: Label = $Margin/Layout/ServiceGrid/PointChannelStatus
@onready var storage_status: Label = $Margin/Layout/ServiceGrid/StorageStatus
@onready var sky_pages: Control = $Margin/Layout/Pages/SkyPages
@onready var ground_page: Control = $Margin/Layout/Pages/GroundPage
@onready var prepare_page: Control = $Margin/Layout/Pages/SkyPages/PreparePage
@onready var prepare_description: Label = \
	$Margin/Layout/Pages/SkyPages/PreparePage/Content/Description
@onready var map_selector: OptionButton = \
	$Margin/Layout/Pages/SkyPages/PreparePage/Content/MapRow/MapSelector
@onready var collecting_page: Control = $Margin/Layout/Pages/SkyPages/CollectingPage
@onready var solving_page: Control = $Margin/Layout/Pages/SkyPages/SolvingPage
@onready var preview_page: Control = $Margin/Layout/Pages/SkyPages/PreviewPage
@onready var live_page: Control = $Margin/Layout/Pages/SkyPages/LivePage
@onready var stopped_page: Control = $Margin/Layout/Pages/SkyPages/StoppedPage
@onready var error_page: Control = $Margin/Layout/Pages/SkyPages/ErrorPage
@onready var collecting_progress: ProgressBar = \
	$Margin/Layout/Pages/SkyPages/CollectingPage/Content/Progress
@onready var collecting_message: Label = \
	$Margin/Layout/Pages/SkyPages/CollectingPage/Content/Instruction
@onready var solving_message: Label = \
	$Margin/Layout/Pages/SkyPages/SolvingPage/Content/Message
@onready var preview_metrics: Label = \
	$Margin/Layout/Pages/SkyPages/PreviewPage/Content/Metrics
@onready var fine_toggle: CheckButton = \
	$Margin/Layout/Pages/SkyPages/PreviewPage/Content/ModeRow/FineToggle
@onready var advanced_toggle: CheckButton = \
	$Margin/Layout/Pages/SkyPages/PreviewPage/Content/ModeRow/AdvancedToggle
@onready var advanced_rotation_row: Control = \
	$Margin/Layout/Pages/SkyPages/PreviewPage/Content/AdvancedRotationRow
@onready var live_stats: Label = $Margin/Layout/Pages/SkyPages/LivePage/Content/Stats
@onready var sky_point_cloud_toggle: CheckButton = \
	$Margin/Layout/Pages/SkyPages/LivePage/Content/PointCloudToggle
@onready var ground_status: Label = \
	$Margin/Layout/Pages/GroundPage/Content/Status
@onready var ground_stats: Label = \
	$Margin/Layout/Pages/GroundPage/Content/Stats
@onready var ground_point_cloud_toggle: CheckButton = \
	$Margin/Layout/Pages/GroundPage/Content/PointCloudToggle
@onready var error_message: Label = \
	$Margin/Layout/Pages/SkyPages/ErrorPage/Content/Message

var _view_state: int = ViewState.PREPARE
var _local_role: String = ROLE_SKY


func _ready() -> void:
	exit_button.pressed.connect(exit_requested.emit)
	recenter_button.pressed.connect(recenter_requested.emit)
	$Margin/Layout/Pages/SkyPages/PreparePage/Content/Actions/StartButton.pressed.connect(
		start_requested.emit
	)
	$Margin/Layout/Pages/SkyPages/PreparePage/Content/Actions/ImportButton.pressed.connect(
		import_requested.emit
	)
	map_selector.item_selected.connect(_on_map_item_selected)
	$Margin/Layout/Pages/SkyPages/CollectingPage/Content/CancelButton.pressed.connect(
		cancel_requested.emit
	)
	$Margin/Layout/Pages/SkyPages/PreviewPage/Content/Actions/ConfirmButton.pressed.connect(
		confirm_requested.emit
	)
	$Margin/Layout/Pages/SkyPages/PreviewPage/Content/Actions/RetryButton.pressed.connect(
		retry_requested.emit
	)
	$Margin/Layout/Pages/SkyPages/LivePage/Content/Actions/StopButton.pressed.connect(
		stop_requested.emit
	)
	$Margin/Layout/Pages/SkyPages/LivePage/Content/Actions/ReregisterButton.pressed.connect(
		reregister_requested.emit
	)
	$Margin/Layout/Pages/SkyPages/LivePage/Content/Actions/ExportButton.pressed.connect(
		export_requested.emit
	)
	$Margin/Layout/Pages/SkyPages/StoppedPage/Content/Actions/ExportButton.pressed.connect(
		export_requested.emit
	)
	$Margin/Layout/Pages/SkyPages/StoppedPage/Content/Actions/NewButton.pressed.connect(
		new_session_requested.emit
	)
	$Margin/Layout/Pages/SkyPages/StoppedPage/Content/Actions/ClearButton.pressed.connect(
		clear_requested.emit
	)
	$Margin/Layout/Pages/SkyPages/ErrorPage/Content/RetryButton.pressed.connect(
		retry_requested.emit
	)
	fine_toggle.toggled.connect(_on_fine_toggled)
	advanced_toggle.toggled.connect(_on_advanced_toggled)
	sky_point_cloud_toggle.toggled.connect(point_cloud_visibility_requested.emit)
	ground_point_cloud_toggle.toggled.connect(point_cloud_visibility_requested.emit)
	_bind_manual_adjustment_buttons()
	advanced_rotation_row.visible = false
	_refresh_pages()


func configure_role(role: String) -> void:
	_local_role = role
	role_label.text = "天上端" if role == ROLE_SKY else "地面端"
	sky_pages.visible = role == ROLE_SKY
	ground_page.visible = role == ROLE_GROUND_VR
	_refresh_pages()


func set_view_state(view_state: int, message: String = "") -> void:
	if view_state < ViewState.PREPARE or view_state > ViewState.ERROR:
		return
	_view_state = view_state
	if view_state == ViewState.PREPARE:
		prepare_description.text = message if not message.is_empty() else (
			"请先在 PICO 本机启动 Spatial Anchor Helper。\n"
			+ "服务全部就绪后，开始按钮会自动启用。"
		)
	elif view_state == ViewState.PREFLIGHT:
		prepare_description.text = message if not message.is_empty() \
			else "正在检查 PICO Helper、Lab、点云通道和地图存储。"
	elif view_state == ViewState.IMPORTING:
		prepare_description.text = message if not message.is_empty() \
			else "正在从 PC Server 重建地图库读取地图。"
	elif view_state == ViewState.ERROR and not message.is_empty():
		error_message.text = message
	elif view_state == ViewState.SOLVING and not message.is_empty():
		solving_message.text = message
	_refresh_pages()


func set_service_status(service_name: StringName, is_ready: bool, detail: String = "") -> void:
	var target: Label
	match service_name:
		&"helper":
			target = helper_status
		&"lab":
			target = lab_status
		&"point_channel":
			target = point_channel_status
		&"storage":
			target = storage_status
		_:
			return
	var state_text := "已就绪" if is_ready else "等待中"
	target.text = "%s%s" % [state_text, (" · " + detail) if not detail.is_empty() else ""]
	target.modulate = READY_COLOR if is_ready else WAITING_COLOR


func set_collecting_progress(progress: float, instruction: String = "") -> void:
	collecting_progress.value = clampf(progress, 0.0, 100.0)
	if not instruction.is_empty():
		collecting_message.text = instruction


func set_preview_metrics(position_error_cm: float, rotation_error_deg: float, scale: float) -> void:
	preview_metrics.text = "位置 RMS %.1f cm　旋转 RMS %.1f°　尺度 %.3f" % [
		position_error_cm,
		rotation_error_deg,
		scale,
	]


func set_live_stats(
	input_fps: float,
	update_hz: float,
	latency_ms: float,
	point_count: int,
	elapsed_seconds: float
) -> void:
	var stats := "输入 %.1f FPS　点云 %.1f Hz　延迟 %.0f ms\n点数 %s　运行 %s" % [
		input_fps,
		update_hz,
		latency_ms,
		_format_count(point_count),
		_format_duration(elapsed_seconds),
	]
	live_stats.text = stats
	ground_stats.text = stats


func set_ground_status(message: String) -> void:
	ground_status.text = message


func set_start_enabled(is_enabled: bool, reason: String = "") -> void:
	var start_button := \
		$Margin/Layout/Pages/SkyPages/PreparePage/Content/Actions/StartButton as Button
	start_button.disabled = not is_enabled
	start_button.tooltip_text = reason


func set_imported_session(is_imported: bool) -> void:
	var preview_retry := \
		$Margin/Layout/Pages/SkyPages/PreviewPage/Content/Actions/RetryButton as Button
	var live_reregister := \
		$Margin/Layout/Pages/SkyPages/LivePage/Content/Actions/ReregisterButton as Button
	for button in [preview_retry, live_reregister]:
		button.disabled = is_imported
		button.tooltip_text = (
			"导入地图没有对应的 LingBot 在线会话；请清空后开始新的重建。"
			if is_imported
			else ""
		)


func set_stop_draining(is_draining: bool) -> void:
	var export_button := \
		$Margin/Layout/Pages/SkyPages/StoppedPage/Content/Actions/ExportButton as Button
	export_button.disabled = is_draining
	export_button.tooltip_text = (
		"正在等待已提交到 GPU 的尾部点块，最多约 5 秒。"
		if is_draining
		else ""
	)


func set_point_cloud_visible(is_visible: bool) -> void:
	sky_point_cloud_toggle.set_pressed_no_signal(is_visible)
	ground_point_cloud_toggle.set_pressed_no_signal(is_visible)


func set_map_library(entries: Array[Dictionary]) -> void:
	var previous_selection := ""
	if map_selector.item_count > 0 \
			and map_selector.selected >= 0 \
			and not map_selector.disabled:
		previous_selection = str(
			map_selector.get_item_metadata(map_selector.selected)
		)
	map_selector.clear()
	var previous_index := -1
	for entry in entries:
		var file_name := str(entry.get("file_name", "")).strip_edges()
		if file_name.is_empty():
			continue
		var manifest := entry.get("manifest", {}) as Dictionary
		var display_name := str(manifest.get("display_name", file_name))
		var point_count := int(manifest.get("point_count", 0))
		map_selector.add_item("%s · %s 点" % [display_name, _format_count(point_count)])
		map_selector.set_item_metadata(map_selector.item_count - 1, file_name)
		if file_name == previous_selection:
			previous_index = map_selector.item_count - 1
	if map_selector.item_count == 0:
		map_selector.add_item("服务器地图库为空")
		map_selector.disabled = true
		map_selected.emit("")
		return
	map_selector.disabled = false
	map_selector.select(
		previous_index if previous_index >= 0 else map_selector.item_count - 1
	)
	_on_map_item_selected(map_selector.selected)


func show_error(message: String) -> void:
	error_message.text = message
	error_message.modulate = ERROR_COLOR
	set_view_state(ViewState.ERROR)


func _on_map_item_selected(index: int) -> void:
	if index < 0 or index >= map_selector.item_count or map_selector.disabled:
		map_selected.emit("")
		return
	map_selected.emit(str(map_selector.get_item_metadata(index)))


func _refresh_pages() -> void:
	if not is_node_ready():
		return
	var is_sky := _local_role == ROLE_SKY
	sky_pages.visible = is_sky
	ground_page.visible = not is_sky
	for page in [
		prepare_page,
		collecting_page,
		solving_page,
		preview_page,
		live_page,
		stopped_page,
		error_page,
	]:
		page.visible = false
	if not is_sky:
		state_label.text = "共享场景"
		return
	match _view_state:
		ViewState.PREPARE, ViewState.PREFLIGHT, ViewState.IMPORTING:
			prepare_page.visible = true
		ViewState.COLLECTING:
			collecting_page.visible = true
		ViewState.SOLVING:
			solving_page.visible = true
		ViewState.PREVIEW:
			preview_page.visible = true
		ViewState.LIVE:
			live_page.visible = true
		ViewState.STOPPED:
			stopped_page.visible = true
		ViewState.ERROR:
			error_page.visible = true
	state_label.text = _state_display_name(_view_state)


func _bind_manual_adjustment_buttons() -> void:
	var content := $Margin/Layout/Pages/SkyPages/PreviewPage/Content
	_bind_adjustment_button(content.get_node("TranslationRow/XMinus"), &"translation_x", -1.0)
	_bind_adjustment_button(content.get_node("TranslationRow/XPlus"), &"translation_x", 1.0)
	_bind_adjustment_button(content.get_node("TranslationRow/YMinus"), &"translation_y", -1.0)
	_bind_adjustment_button(content.get_node("TranslationRow/YPlus"), &"translation_y", 1.0)
	_bind_adjustment_button(content.get_node("TranslationRow/ZMinus"), &"translation_z", -1.0)
	_bind_adjustment_button(content.get_node("TranslationRow/ZPlus"), &"translation_z", 1.0)
	_bind_adjustment_button(content.get_node("RotationScaleRow/YawMinus"), &"yaw_degrees", -1.0)
	_bind_adjustment_button(content.get_node("RotationScaleRow/YawPlus"), &"yaw_degrees", 1.0)
	_bind_adjustment_button(content.get_node("RotationScaleRow/ScaleMinus"), &"scale_delta", -1.0)
	_bind_adjustment_button(content.get_node("RotationScaleRow/ScalePlus"), &"scale_delta", 1.0)
	_bind_adjustment_button(content.get_node("AdvancedRotationRow/PitchMinus"), &"pitch_degrees", -1.0)
	_bind_adjustment_button(content.get_node("AdvancedRotationRow/PitchPlus"), &"pitch_degrees", 1.0)
	_bind_adjustment_button(content.get_node("AdvancedRotationRow/RollMinus"), &"roll_degrees", -1.0)
	_bind_adjustment_button(content.get_node("AdvancedRotationRow/RollPlus"), &"roll_degrees", 1.0)


func _bind_adjustment_button(button: Button, kind: StringName, direction: float) -> void:
	button.pressed.connect(func() -> void:
		manual_adjustment_requested.emit(kind, direction * _adjustment_step(kind))
	)


func _adjustment_step(kind: StringName) -> float:
	var fine := fine_toggle.button_pressed
	if kind in [&"translation_x", &"translation_y", &"translation_z"]:
		return 0.01 if fine else 0.05
	if kind == &"scale_delta":
		return 0.01 if fine else 0.05
	return 0.5 if fine else 5.0


func _on_fine_toggled(is_fine: bool) -> void:
	fine_toggle.text = "精调" if is_fine else "粗调"


func _on_advanced_toggled(is_advanced: bool) -> void:
	advanced_rotation_row.visible = is_advanced


func _state_display_name(view_state: int) -> String:
	match view_state:
		ViewState.PREPARE:
			return "准备"
		ViewState.PREFLIGHT:
			return "预检"
		ViewState.COLLECTING:
			return "初始化采集"
		ViewState.SOLVING:
			return "自动求解"
		ViewState.PREVIEW:
			return "配准预览"
		ViewState.LIVE:
			return "实时重建"
		ViewState.STOPPED:
			return "已停止"
		ViewState.IMPORTING:
			return "正在导入"
		_:
			return "错误"


func _format_count(value: int) -> String:
	if value >= 1_000_000:
		return "%.2f M" % (float(value) / 1_000_000.0)
	if value >= 1_000:
		return "%.1f K" % (float(value) / 1_000.0)
	return str(value)


func _format_duration(seconds: float) -> String:
	var total := maxi(0, int(seconds))
	return "%02d:%02d" % [total / 60, total % 60]
