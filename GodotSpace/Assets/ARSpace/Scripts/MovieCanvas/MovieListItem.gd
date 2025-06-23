extends Control
class_name MovieListItem

# 数据对象
var item_data: MovieListData

# 节点绑定（请确保场景中名称一致）
@onready var banner_video: TextureRect = $BannerVideo
@onready var title_label: Label = $Title

@export var movie_info_canvas: Node = null

func _ready():
	self.pressed.connect(_on_click_btn)

func _on_click_btn():
	# print(self, " ClickBtn")
	movie_info_canvas.set_image_name(item_data.banner_path.get_file())

# 刷新显示内容
func refresh_info(data: MovieListData):
	if not self.visible:
		self.visible = true

	item_data = data
	var file_name = data.banner_path.get_file()
	var file_path = get_media_path("Videos", file_name)

	if file_path != "":
		banner_video.stream = load(file_path)

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
