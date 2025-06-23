extends Control

func _ready():
	Global.main_menu_canvas = self

func _on_photo_pressed():
	Global.picture_canvas.visible = true
