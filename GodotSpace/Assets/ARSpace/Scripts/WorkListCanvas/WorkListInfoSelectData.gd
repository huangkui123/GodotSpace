extends Resource

class_name WorkListInfoSelectData

@export var n_index: int
@export var n_step: int
@export var is_sound: String
@export var is_video: String

func _init(_n_index: int = 1, _n_step: int = 1, _is_sound: String = "", _is_video: String = ""):
	n_index = _n_index
	n_step = _n_step
	is_sound = _is_sound
	is_video = _is_video