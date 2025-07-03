extends Control

class_name WorkListItem

@export var item_data: WorkListData

@onready var banner_img: TextureRect = $Mask/Image
@onready var title_label: Label = $Title
@onready var num_label: Label = $Num
@onready var info_label: Label = $Info

func _ready():
	self.pressed.connect(click_btn)

func click_btn():
	print(self.name, ": click_btn")

	if item_data.id > 1:
		print(self.name, ": 该实验流程暂未开放")
		# if InfoToastManager and MainMenuUIView:
		# 	InfoToastManager.show_info_toast_window(InfoState.FAIL, "该实验流程暂未开放", MainMenuUIView.instance)
		return

	print(self.name, ": Step = 1")

	var work_info = Global.work_list_info_canvas
	if work_info:
		work_info.visible = true
		work_info.on_refresh_data_change_view(item_data.info_data_result)

	print(self.name, ": Index = ", item_data.id)

func close_guide():
	print(self.name, ": Step = 1")

	var work_info = Global.work_list_info_canvas
	if work_info:
		work_info.visible = false

func refresh_info(data: WorkListData):
	self.visible = true
	
	self.item_data = data

	var file_name: String = data.icon_path
	var file_path = get_media_path("Images", file_name)

	if file_path != "":
		var image_texture = load_texture_from_file(file_path)
		if image_texture:
			banner_img.texture = image_texture
		else:
			print("Error loading texture from file:", file_path)

	if title_label:
		title_label.text = data.title
	if num_label:
		num_label.text = data.step_count_text
	if info_label:
		info_label.text = data.brief_description

func get_media_path(root_directory_name: String, file_name: String):
	var base_path: String
	
	base_path = "res://Assets/StreamingAssets/%s/" % root_directory_name
	
	var full_path: String = base_path + file_name
	
	print("get_media_path -> FilePath:", full_path)

	if FileAccess.file_exists(full_path):
		return full_path
	else:
		return ""

func load_texture_from_file(path: String):
	var file := FileAccess.open(path, FileAccess.READ)
	if file:
		var bytes = file.get_buffer(file.get_length())
		var image = Image.new()
		var success = image.load_png_from_buffer(bytes)
		if success == OK:
			var texture := ImageTexture.create_from_image(image)
			return texture
	return null
