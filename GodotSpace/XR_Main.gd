extends Node3D

var xr_interface: XRInterface

@onready var spectator_camera = $SpectatorCamera
@export var subUI: Camera3D

## 是否启用MR透视模式（打开后可同时看到现实世界和虚拟物体）
@export var enable_passthrough: bool = true

var is_test_mode: bool = false

func _ready():
	var args = OS.get_cmdline_args()

	if "--testmode" in args:
		print("Starting in test mode (no XR)")
		is_test_mode = true

	if multiplayer.is_server() or is_test_mode:
		if xr_interface and xr_interface.is_initialized():
			xr_interface.uninitialize()

		spectator_camera.make_current()
	else:
		spectator_camera.current = false
		xr_interface = XRServer.find_interface("OpenXR")
		if xr_interface and xr_interface.is_initialized():
			print("OpenXR initialized successfully")
			# Turn off v-sync!
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
			# Change our main viewport to output to the HMD
			get_viewport().use_xr = true

			# 启用MR透视
			if enable_passthrough:
				_start_passthrough()
		else:
			print("OpenXR not initialized, please check if your headset is connected")


## 启动MR透视模式
func _start_passthrough():
	if not xr_interface:
		push_warning("MR透视: XR接口未初始化")
		return false

	# 方式1: 尝试使用 environment_blend_mode (Godot 4.3+ 推荐方式)
	# XR_ENV_BLEND_MODE_ALPHA_BLEND = 2，适用于MR透视
	var supported_blend_modes = xr_interface.get_supported_environment_blend_modes()
	print("MR透视: 支持的混合模式 = ", supported_blend_modes)

	if XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in supported_blend_modes:
		xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
		get_viewport().transparent_bg = true
		print("MR透视: 已通过 environment_blend_mode (ALPHA_BLEND) 启用")
		return true

	# 方式2: 回退到 passthrough API
	if xr_interface.is_passthrough_supported():
		if xr_interface.start_passthrough():
			get_viewport().transparent_bg = true
			print("MR透视: 已通过 passthrough API 启用")
			return true
		else:
			push_warning("MR透视: start_passthrough() 失败")
	else:
		push_warning("MR透视: 设备不支持透视功能")

	return false


## 停止MR透视模式
func _stop_passthrough():
	if not xr_interface:
		return

	# 恢复为不透明VR模式
	var supported_blend_modes = xr_interface.get_supported_environment_blend_modes()
	if XRInterface.XR_ENV_BLEND_MODE_OPAQUE in supported_blend_modes:
		xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_OPAQUE

	xr_interface.stop_passthrough()
	get_viewport().transparent_bg = false
	print("MR透视: 已关闭")

func _process(delta: float):
	if multiplayer.is_server() or is_test_mode:
		var xr_camera = find_child("XRCamera3D", true, false)
		if xr_camera:
			subUI.transform = xr_camera.global_transform
