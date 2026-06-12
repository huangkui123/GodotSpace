extends Button

func _ready():
	pressed.connect(_on_button_pressed)

func _on_button_pressed():
	add_theme_color_override("icon_normal_color", Color.GREEN)
	# print("movie button pressed")
