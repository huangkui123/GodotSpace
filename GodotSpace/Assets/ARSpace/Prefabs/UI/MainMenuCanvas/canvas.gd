extends Control

@onready var work_list_view: Control = $WorkTabView/WorkListView

func _ready():
	Global.main_menu_canvas = self
	work_list_view.visible = false

func _on_photo_pressed():
	Global.picture_canvas.visible = true

func _on_movie_pressed():
	Global.movie_canvas.visible = true

func _on_work_list_pressed():
	work_list_view.visible = true
	# Global.work_list_view.refresh_work_list()

func _on_back_button_pressed():
	work_list_view.visible = false

func _on_close_button_pressed():
	self.visible = false
