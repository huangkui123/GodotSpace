extends Control

@onready var work_list_view: Control = $WorkTabView/WorkListView
@onready var llm_assistant_view: LLMAssistantUIView = $WorkTabView/LLMAssistantView

func _ready():
	Global.main_menu_canvas = self
	work_list_view.visible = false
	llm_assistant_view.visible = false

func _on_photo_pressed():
	Global.picture_canvas.visible = true

func _on_movie_pressed():
	Global.movie_canvas.visible = true

func _on_work_list_pressed():
	_hide_llm_assistant_view()
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
	_hide_llm_assistant_view()
	self.visible = false

func _on_llm_assistant_pressed() -> void:
	work_list_view.visible = false
	if Global.spacebox_controller:
		Global.spacebox_controller.set_worklist1_visible(false)

	llm_assistant_view.visible = true
	llm_assistant_view.start_demo()

func _on_llm_back_button_pressed() -> void:
	_hide_llm_assistant_view()

func _hide_llm_assistant_view() -> void:
	if llm_assistant_view:
		llm_assistant_view.stop_demo()
		llm_assistant_view.visible = false
	
