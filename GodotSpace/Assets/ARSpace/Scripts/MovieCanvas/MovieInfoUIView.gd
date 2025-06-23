extends Control

class_name MovieInfoUIView

var imagename: String = ""
@export var title_label: Node = null
@export var p_info: Node = null

func set_image_name(name: String):
	if not self.visible:
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
