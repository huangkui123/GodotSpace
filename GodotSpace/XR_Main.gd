extends Node3D

var xr_interface: XRInterface

@onready var spectator_camera = $SpectatorCamera
@export var subUI: Camera3D

func _ready():
	if multiplayer.is_server():
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
	if multiplayer.is_server():
		var xr_camera = find_child("XRCamera3D", true, false)
		if xr_camera:
			subUI.transform = xr_camera.global_transform
