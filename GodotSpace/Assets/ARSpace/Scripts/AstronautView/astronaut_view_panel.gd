extends Control

const AstronautViewSourceScript = preload(
	"res://Assets/ARSpace/Scripts/AstronautView/astronaut_view_source.gd"
)
const UndistortShader := preload("res://Assets/ARSpace/Shader/cast_undistort.gdshader")
const CORRECTION_CONFIG := "user://cast_correction.cfg"

signal close_requested
signal restore_requested

@onready var source_label: Label = $Margin/VBox/Header/SourceLabel
@onready var restore_button: Button = $Margin/VBox/Header/RestoreButton
@onready var close_button: Button = $Margin/VBox/Header/CloseButton
@onready var view_texture: TextureRect = $Margin/VBox/ViewFrame/ViewTexture
@onready var status_overlay: ColorRect = $Margin/VBox/ViewFrame/StatusOverlay
@onready var status_label: Label = $Margin/VBox/ViewFrame/StatusOverlay/StatusLabel
@onready var debug_label: Label = $Margin/VBox/DebugLabel

var _status: int = AstronautViewSourceScript.Status.IDLE
var _status_message: String = "等待天上端连接"
var _metadata: Dictionary = {}
var _correction_material: ShaderMaterial
var _correction_toggle: CheckButton
var _correction_strength: HSlider
var _correction_caption: Label


func _ready() -> void:
	restore_button.pressed.connect(func(): restore_requested.emit())
	close_button.pressed.connect(func(): close_requested.emit())
	_build_correction_controls()
	_refresh_status()
	_refresh_metadata()


func set_view_texture(texture: Texture2D) -> void:
	view_texture.texture = texture
	_refresh_correction()


func set_view_status(status: int, message: String) -> void:
	_status = status
	_status_message = message
	_refresh_status()


func set_view_metadata(metadata: Dictionary) -> void:
	_metadata = metadata.duplicate(true)
	_refresh_metadata()
	_refresh_correction()


func _build_correction_controls() -> void:
	_correction_material = ShaderMaterial.new()
	_correction_material.shader = UndistortShader
	var row := HBoxContainer.new()
	row.name = "LensCorrection"
	row.add_theme_constant_override("separation", 12)
	$Margin/VBox.add_child(row)
	$Margin/VBox.move_child(row, 1)
	_correction_toggle = CheckButton.new()
	_correction_toggle.text = "反畸变"
	_correction_toggle.tooltip_text = "关闭可对照原图；调节强度直到柜体边线自然"
	row.add_child(_correction_toggle)
	_correction_strength = HSlider.new()
	_correction_strength.max_value = 0.8
	_correction_strength.step = 0.01
	_correction_strength.custom_minimum_size = Vector2(200, 44)
	_correction_strength.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_correction_strength)
	_correction_caption = Label.new()
	_correction_caption.custom_minimum_size.x = 150
	row.add_child(_correction_caption)
	var config := ConfigFile.new()
	config.load(CORRECTION_CONFIG)
	_correction_toggle.button_pressed = bool(config.get_value("lens", "enabled", true))
	var saved: Variant = config.get_value("lens", "strength", 0.25)
	_correction_strength.value = clampf(float(saved), 0.0, 0.8) if typeof(saved) in [TYPE_FLOAT, TYPE_INT] and is_finite(float(saved)) else 0.25
	_correction_toggle.toggled.connect(func(_enabled: bool):
		_refresh_correction()
		_save_correction())
	_correction_strength.value_changed.connect(func(_value: float): _refresh_correction())
	_correction_strength.drag_ended.connect(func(_changed: bool): _save_correction())
	_correction_strength.focus_exited.connect(_save_correction)
	_refresh_correction()


func _save_correction() -> void:
	var config := ConfigFile.new()
	config.set_value("lens", "enabled", _correction_toggle.button_pressed)
	config.set_value("lens", "strength", _correction_strength.value)
	var error := config.save(CORRECTION_CONFIG)
	if error != OK:
		push_warning("无法保存投屏反畸变设置：%s" % error_string(error))


func _refresh_correction() -> void:
	if _correction_material == null:
		return
	# Never apply the cast lens model to synthetic cameras or a source that
	# explicitly declares rectification. No cross-use of helper intrinsics.
	var rectified := bool(_metadata.get("rectified", false))
	var eligible: bool = _metadata.get("source_type", "") == "pico_cast" and not rectified
	_correction_toggle.disabled = not eligible
	_correction_strength.editable = eligible and _correction_toggle.button_pressed
	var enabled: bool = eligible and _correction_toggle.button_pressed
	view_texture.material = _correction_material if enabled else null
	_correction_material.set_shader_parameter("strength", _correction_strength.value)
	if view_texture.texture != null:
		var dimensions := view_texture.texture.get_size()
		_correction_material.set_shader_parameter("video_aspect", dimensions.x / maxf(dimensions.y, 1.0))
	_correction_caption.text = "强度 %d%%" % roundi(_correction_strength.value * 100.0) if enabled else ("源已校正" if rectified else "原始画面")


func get_view_texture() -> Texture2D:
	return view_texture.texture


func get_view_status() -> int:
	return _status


func get_view_status_message() -> String:
	return _status_message


func _refresh_status() -> void:
	if status_overlay == null or status_label == null:
		return
	var is_live := _status == AstronautViewSourceScript.Status.LIVE
	status_overlay.visible = not is_live
	status_label.text = _status_message if not _status_message.is_empty() else "等待 PICO 头显投屏"
	if _status == AstronautViewSourceScript.Status.ERROR:
		status_overlay.color = Color(0.28, 0.02, 0.02, 0.92)
	elif _status == AstronautViewSourceScript.Status.STALLED:
		status_overlay.color = Color(0.22, 0.13, 0.02, 0.9)
	else:
		status_overlay.color = Color(0.025, 0.035, 0.06, 0.9)


func _refresh_metadata() -> void:
	if source_label == null or debug_label == null:
		return
	source_label.text = str(_metadata.get("source_name", "PICO 头显投屏"))
	if _metadata.is_empty():
		debug_label.text = "PICO RTMP · 等待投屏会话"
		return
	var resolution: Vector2i = _metadata.get("resolution", Vector2i.ZERO) as Vector2i
	debug_label.text = "PICO RTMP · %d×%d · 音频关闭" % [resolution.x, resolution.y]
