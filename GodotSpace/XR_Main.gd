extends Node3D

var xr_interface: XRInterface

@onready var spectator_camera = $SpectatorCamera
@export var subUI: Camera3D

var is_test_mode: bool = false

# 标注覆盖层
var annotation_overlay: CanvasLayer

func _ready():
	var args = OS.get_cmdline_args()

	if "--testmode" in args:
		print("Starting in test mode (no XR)")
		is_test_mode = true

	if multiplayer.is_server() or is_test_mode:
		if xr_interface and xr_interface.is_initialized():
			xr_interface.uninitialize()
			
		spectator_camera.make_current()
		
		# 服务器端（地面端）加载标注覆盖层
		_setup_annotation_overlay()
	else:
		spectator_camera.current = false
		if xr_interface and xr_interface.is_initialized():
			print("OpenXR initialized successfully")
			# Turn off v-sync!
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
			# Change our main viewport to output to the HMD
			get_viewport().use_xr = true
		else:
			print("OpenXR not initialized, please check if your headset is connected")

## 设置地面端标注覆盖层
func _setup_annotation_overlay():
	var overlay_script = load("res://addons/annotation_system/ground/ground_annotation_overlay.gd")
	if overlay_script:
		annotation_overlay = CanvasLayer.new()
		annotation_overlay.name = "AnnotationOverlay"
		annotation_overlay.set_script(overlay_script)
		add_child(annotation_overlay)
		print("✅ 地面端标注覆盖层已加载")
	else:
		print("⚠️ 标注覆盖层脚本未找到")

func _process(delta: float):
	if multiplayer.is_server() or is_test_mode:
		var xr_camera = find_child("XRCamera3D", true, false)
		if xr_camera:
			subUI.transform = xr_camera.global_transform
