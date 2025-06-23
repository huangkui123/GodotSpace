extends Control

class_name PictureInfoUIView

var imagename: String = ""
@export var title_label: Node = null
@export var p_info: Node = null

func _ready():
	print("PictureInfoUIView _ready")
	self.visible = false
	Global.picture_info_canvas = self

func set_image_name(name: String):
	print("set_image_name: " + name)
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
