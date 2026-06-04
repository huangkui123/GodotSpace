extends Control
class_name MovieInfoItem

const DEBUG_LOGS := false

# @onready var banner_video: TextureRect = $BannerVideo
@onready var texture_button: TextureButton = $PlayPauseButton
@export var banner_video: VideoStreamPlayer

var icons: Array[Texture2D] = [
	preload("res://Assets/Icons/play.png"), # PLAY
	preload("res://Assets/Icons/pause.png"), # PLAY
]
var is_playing: bool = true

func set_video(name: String):
	var file_path = get_media_path("Videos", name)

	if file_path != "":
		var stream = ClassDB.instantiate("FFmpegVideoStream")
		if stream:
			if DEBUG_LOGS: print("✅ 成功创建 FFmpegVideoStream 实例")
			stream.set_file(file_path)
			is_playing = true
			banner_video.stream = stream
			banner_video.volume_db = -80  # 静音视频
			banner_video.play()
			texture_button.texture_normal = icons[1] # 设置为暂停图标
			# await get_tree().create_timer(0.5).timeout
			# banner_video.paused = true
		else:
			push_error("❌ 无法创建 FFmpegVideoStream，说明插件没有正确加载")

func destory():
	if banner_video:
		banner_video.stream = null
		is_playing = false
		if DEBUG_LOGS: print("Video stream stopped and cleared.")

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

	return ""

func _on_texture_button_pressed():
	if is_playing:
		# 停止视频播放
		texture_button.texture_normal = icons[0] # 设置为播放图标
		is_playing = false
		banner_video.paused = true
		if DEBUG_LOGS: print("Video paused")
	else:
		# 开始视频播放
		texture_button.texture_normal = icons[1] # 设置为暂停图标
		is_playing = true
		banner_video.paused = false
		if DEBUG_LOGS: print("Video playing")
