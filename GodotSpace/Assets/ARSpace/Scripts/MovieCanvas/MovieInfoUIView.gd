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
	if not self.visible:
		PanelWindowZoom.set_window_visible(self, true)
	videoname = name
	var playback_available := bool(p_info.set_video(name))
	title_label.text = name if playback_available else "%s（当前平台不支持播放）" % name

func _on_close_button_pressed():
	if self.visible:
		PanelWindowZoom.set_window_visible(self, false)
		p_info.destory()
		# p_info.set_video("")
		# videoname = ""
		# title_label.text = ""

func on_spatial_window_visibility_changed(is_visible: bool) -> void:
	if not is_visible and p_info != null and p_info.has_method("destory"):
		p_info.call("destory")
