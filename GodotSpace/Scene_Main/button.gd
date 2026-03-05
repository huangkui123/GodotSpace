extends Button

@export var icon_on: Texture2D
@export var icon_off: Texture2D

func _ready() -> void:
	toggle_mode = true
	icon = icon_off
	toggled.connect(_on_toggled)

func _on_toggled(pressed: bool) -> void:
	icon = icon_on if pressed else icon_off
