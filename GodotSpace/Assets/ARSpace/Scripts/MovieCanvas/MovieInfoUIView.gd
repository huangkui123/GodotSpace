extends Control

class_name MovieInfoUIView

const PanelWindowZoom = preload("res://Assets/ARSpace/Scripts/UI/panel_window_zoom.gd")
const DEBUG_LOGS := false

var videoname: String = ""
@export var title_label: Node = null
@export var p_info: Node = null

func _ready():
	if DEBUG_LOGS: print("MovieInfoUIView _ready")
	Global.movie_info_canvas = self
	PanelWindowZoom.bind_max_button(self)

	self.visible = false
	videoname = ""

func set_video_name(name: String):
	PanelWindowZoom.set_window_visible(self, true, Global.movie_canvas)
	title_label.text = name
	videoname = name
	p_info.set_video(name)

func _on_close_button_pressed():
	if self.visible:
		self.visible = false
		p_info.destory()
		# p_info.set_video("")
		# videoname = ""
		# title_label.text = ""
