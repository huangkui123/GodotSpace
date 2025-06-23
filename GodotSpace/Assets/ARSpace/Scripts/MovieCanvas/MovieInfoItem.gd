extends Control
class_name MovieInfoItem

# 节点绑定（请确保场景中名称一致）
@onready var banner_video: TextureRect = $BannerVideo

func set_image(name: String):
	var file_path = get_media_path("Videos", name)

	if file_path != "":
		banner_video.stream = load(file_path)

# 获取图片路径
func get_media_path(root_directory_name: String, file_name: String):
	var base_path := ""

	if OS.has_feature("editor"):
		base_path = "res://Assets/StreamingAssets/%s/" % root_directory_name
	else:
		base_path = "user://../../../../%s/" % root_directory_name

	var full_path = base_path + file_name

	# print("GetMediaPath -> FilePath: ", full_path)

	var dir = DirAccess.open(base_path)
	if dir and FileAccess.file_exists(full_path):
		return full_path
	
	# if dir:
	# 	print("Directory exists, but file does not: ", full_path)
	# else:
	# 	print("Directory does not exist: ", base_path)

	return ""
