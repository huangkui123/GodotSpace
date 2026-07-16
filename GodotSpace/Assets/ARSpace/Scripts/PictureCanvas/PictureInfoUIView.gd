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
	PanelWindowZoom.set_window_visible(self, true)
	title_label.text = name
	imagename = name
	p_info.set_image(name)


func _on_close_button_pressed():
	if self.visible:
		PanelWindowZoom.set_window_visible(self, false)
		p_info.set_image("")
		imagename = ""
		title_label.text = ""

func on_spatial_window_visibility_changed(is_visible: bool) -> void:
	if is_visible:
		return
	if p_info != null and p_info.has_method("set_image"):
		p_info.call("set_image", "")
	imagename = ""
	if title_label != null:
		title_label.set("text", "")
