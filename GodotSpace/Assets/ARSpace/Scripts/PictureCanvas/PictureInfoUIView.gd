extends Control

class_name PictureInfoUIView

const PanelWindowZoom = preload("res://Assets/ARSpace/Scripts/UI/panel_window_zoom.gd")
const DEBUG_LOGS := false

var imagename: String = ""
@export var title_label: Node = null
@export var p_info: Node = null

func _ready():
	if DEBUG_LOGS: print("PictureInfoUIView _ready")
	self.visible = false
	Global.picture_info_canvas = self
	PanelWindowZoom.bind_max_button(self)

func set_image_name(name: String):
	if DEBUG_LOGS: print("set_image_name: " + name)
	self.visible = true
	title_label.text = name
	imagename = name
	p_info.set_image(name)


func _on_close_button_pressed():
	if self.visible:
		self.visible = false
		p_info.set_image("")
		imagename = ""
		title_label.text = ""
