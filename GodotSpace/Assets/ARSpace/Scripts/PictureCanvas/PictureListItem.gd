# picture_list_item.gd
extends Control
class_name PictureListItem

# 数据对象
var item_data: PictureListData

# 节点绑定（请确保场景中名称一致）
@onready var banner_img: TextureRect = $BannerImg
@onready var title_label: Label = $Title

@export var picture_info_canvas: Node = null

func _ready():
	self.pressed.connect(_on_click_btn)

func _on_click_btn():
	# print(self, " ClickBtn")
	picture_info_canvas.set_image_name(item_data.banner_path.get_file())

# 刷新显示内容
func refresh_info(data: PictureListData):
	if not self.visible:
		self.visible = true

	item_data = data
	var file_name = data.banner_path.get_file()
	var file_path = get_media_path("Images", file_name)

	if file_path != "":
		var image_texture = load_texture_from_file(file_path)
		if image_texture:
			banner_img.texture = image_texture

	print("data.tile = " + data.title)
	title_label.text = data.title

# 获取图片路径
func get_media_path(root_directory_name: String, file_name: String):
	var base_path := ""

	if OS.has_feature("editor"):
		base_path = "res://Assets/StreamingAssets/%s/" % root_directory_name
	else:
		base_path = "user://../../../../%s/" % root_directory_name

	var full_path = base_path + file_name

	print("GetMediaPath -> FilePath: ", full_path)

	var dir = DirAccess.open(base_path)
	if dir and FileAccess.file_exists(full_path):
		return full_path
	
	if dir:
		print("Directory exists, but file does not: ", full_path)
	else:
		print("Directory does not exist: ", base_path)

	return ""

# 从文件加载图像为 Texture2D
func load_texture_from_file(path: String, w: int = 200, h: int = 200):
	var file := FileAccess.open(path, FileAccess.READ)
	if file:
		var bytes = file.get_buffer(file.get_length())
		var image = Image.new()
		var success = image.load_png_from_buffer(bytes)
		if success == OK:
			var texture := ImageTexture.create_from_image(image)
			return texture
	return null
