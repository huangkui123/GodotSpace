extends Node3D

@export var time_slider: HSlider

func _process(_delta: float) -> void:
	if time_slider:
		OrbitalManager.time_scale = time_slider.value
