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

func set_video(name: String) -> bool:
	var file_path = get_media_path("Videos", name)
	is_playing = false
	texture_button.disabled = true
	texture_button.texture_normal = icons[0]
	banner_video.stop()
	banner_video.stream = null

	if file_path == "":
		push_warning("Video file is unavailable: %s" % name)
		return false
	if not ClassDB.class_exists("FFmpegVideoStream"):
		push_warning("FFmpeg video playback is unavailable on this platform: %s" % name)
		return false

	var stream = ClassDB.instantiate("FFmpegVideoStream")
	if stream == null:
		push_warning("FFmpeg video stream could not be created: %s" % name)
		return false

	stream.set_file(file_path)
	is_playing = true
	banner_video.stream = stream
	banner_video.volume_db = -80
	banner_video.play()
	texture_button.disabled = false
	texture_button.texture_normal = icons[1]
	return true

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
	if banner_video == null or banner_video.stream == null:
		return
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
