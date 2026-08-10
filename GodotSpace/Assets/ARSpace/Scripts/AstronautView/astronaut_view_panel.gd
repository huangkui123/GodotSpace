extends Control

const AstronautViewSourceScript = preload(
	"res://Assets/ARSpace/Scripts/AstronautView/astronaut_view_source.gd"
)

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


func _ready() -> void:
	restore_button.pressed.connect(func(): restore_requested.emit())
	close_button.pressed.connect(func(): close_requested.emit())
	_refresh_status()
	_refresh_metadata()


func set_view_texture(texture: Texture2D) -> void:
	view_texture.texture = texture


func set_view_status(status: int, message: String) -> void:
	_status = status
	_status_message = message
	_refresh_status()


func set_view_metadata(metadata: Dictionary) -> void:
	_metadata = metadata.duplicate(true)
	_refresh_metadata()


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
