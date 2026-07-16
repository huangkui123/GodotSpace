extends Control

class_name WorkListItem

const DEBUG_LOGS := false
const UNCONFIGURED_SUFFIX := "（未配置）"
const PanelWindowZoom = preload("res://Assets/ARSpace/Scripts/UI/panel_window_zoom.gd")

signal unconfigured_task_selected(task_id: int, task_title: String)

@export var item_data: WorkListData

@onready var banner_img: TextureRect = $Mask/Image
@onready var title_label: Label = $Title
@onready var num_label: Label = $Num
@onready var info_label: Label = $Info

func _ready():
	self.pressed.connect(click_btn)

func click_btn():
	if DEBUG_LOGS: print(self.name, ": click_btn")

	if not item_data.is_configured:
		push_warning("任务“%s”未配置，保留入口但不会打开任务步骤。" % item_data.title)
		unconfigured_task_selected.emit(item_data.id, item_data.title)
		return

	if DEBUG_LOGS: print(self.name, ": Step = 1")

	var work_info = Global.work_list_info_canvas
	if work_info:
		PanelWindowZoom.set_window_visible(work_info, true)
		work_info.on_refresh_data_change_view(item_data.info_data_result)

	if DEBUG_LOGS: print(self.name, ": Index = ", item_data.id)

func close_guide():
	if DEBUG_LOGS: print(self.name, ": Step = 1")

	var work_info = Global.work_list_info_canvas
	if work_info:
		PanelWindowZoom.set_window_visible(work_info, false)

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
			if DEBUG_LOGS: print("Error loading texture from file:", file_path)

	if title_label:
		title_label.text = data.title if data.is_configured else "%s%s" % [data.title, UNCONFIGURED_SUFFIX]
	if num_label:
		num_label.text = data.step_count_text if data.is_configured else "未配置"
	if info_label:
		info_label.text = data.brief_description if data.is_configured else "该任务尚未配置，入口仅用于标明复刻范围。"

func get_media_path(root_directory_name: String, file_name: String):
	var base_path: String
	
	base_path = "res://Assets/StreamingAssets/%s/" % root_directory_name
	
	var full_path: String = base_path + file_name
	
	if DEBUG_LOGS: print("get_media_path -> FilePath:", full_path)

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
