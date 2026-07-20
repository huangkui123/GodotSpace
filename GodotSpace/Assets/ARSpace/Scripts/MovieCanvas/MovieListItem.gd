extends Control
class_name MovieListItem

const DEBUG_LOGS := false
const ENABLE_VIDEO_PREVIEWS := false

# 数据对象
var item_data: MovieListData

# 节点绑定（请确保场景中名称一致）
@onready var banner_video: VideoStreamPlayer  = $BannerVideo
@onready var title_label: Label = $Title

func _ready():
	self.pressed.connect(_on_click_btn)

func _on_click_btn():
	# print(self, " ClickBtn")
	Global.movie_info_canvas.set_video_name(item_data.banner_path.get_file())

# 刷新显示内容
func refresh_info(data: MovieListData):
	if not self.visible:
		self.visible = true

	item_data = data
	var file_name = data.banner_path.get_file()
	var file_path = get_media_path("Videos", file_name)

	if file_path != "" and ENABLE_VIDEO_PREVIEWS and ClassDB.class_exists("FFmpegVideoStream"):
		var stream = ClassDB.instantiate("FFmpegVideoStream")
		if stream:
			stream.set_file(file_path)
			banner_video.stream = stream
			banner_video.volume_db = -80  # 静音视频
			banner_video.play()
			await get_tree().create_timer(0.5).timeout
			banner_video.paused = true

	if DEBUG_LOGS: print("data.tile = " + data.title)
	title_label.text = data.title

func get_media_path(root_directory_name: String, file_name: String):
	var base_path := ""

	if OS.has_feature("editor"):
		base_path = "res://Assets/StreamingAssets/%s/" % root_directory_name
	else:
		base_path = "user://../../../../%s/" % root_directory_name

	var full_path = base_path + file_name

	if DEBUG_LOGS: print("GetMediaPath -> FilePath: ", full_path)

	var dir = DirAccess.open(base_path)
	if dir and FileAccess.file_exists(full_path):
		return full_path
	
	if dir:
		if DEBUG_LOGS: print("Directory exists, but file does not: ", full_path)
	else:
		if DEBUG_LOGS: print("Directory does not exist: ", base_path)

	return ""
