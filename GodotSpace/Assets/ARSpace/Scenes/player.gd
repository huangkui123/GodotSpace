extends Node3D

@onready var xr_camera = $XROrigin3D/XRCamera3D

func _enter_tree():
	set_multiplayer_authority(name.to_int())

func _ready():
	if not multiplayer.is_server():
		xr_camera.make_current()

func _physics_process(delta: float):
	if not is_multiplayer_authority():
		return
		
