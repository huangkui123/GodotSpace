extends Node3D

var xr_interface: XRInterface

@onready var spectator_camera = $SpectatorCamera
@export var subUI: Camera3D

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
		if xr_interface and xr_interface.is_initialized():
			print("OpenXR initialized successfully")
			# Turn off v-sync!
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
			# Change our main viewport to output to the HMD
			get_viewport().use_xr = true
		else:
			print("OpenXR not initialized, please check if your headset is connected")

func _process(delta: float):
	if multiplayer.is_server() or is_test_mode:
		var xr_camera = find_child("XRCamera3D", true, false)
		if xr_camera:
			subUI.transform = xr_camera.global_transform
