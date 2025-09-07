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
	if Global.spacebox_controller:
		Global.spacebox_controller.set_worklist1_visible(true)
	else:
		printerr("❌ 找不到 spacebox_controller，无法显示 WorkList1")

func _on_back_button_pressed():
	work_list_view.visible = false
	if Global.spacebox_controller:
		Global.spacebox_controller.set_worklist1_visible(false)
	

func _on_close_button_pressed():
	self.visible = false
	
