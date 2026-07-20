extends Control

class_name WorkListInfoItem

const DEBUG_LOGS := false

@export var item_data: WorkListInfoData

@onready var banner_img: TextureRect = $Mask/Image
@onready var banner_video: VideoStreamPlayer = $Mask/Video
@onready var title_label: Label = $TitleInfo
@onready var info_label: Label = $WorkInfo

func _ready():
	pass

func refresh_info(data: WorkListInfoData):
	if not visible:
		visible = true
	self.item_data = data
	
	match data.type:
		1: # Image
			if banner_img:
				banner_img.visible = true
			if banner_video:
				banner_video.visible = false
				banner_video.stop()

			var file_name: String = data.path.get_file()
			var file_path: String = get_media_path("Images", file_name)

			if file_path != "":
				var image_texture = load_texture_from_file(file_path)
				if image_texture:
					banner_img.texture = image_texture
				else:
					if DEBUG_LOGS: print("Error loading texture from file:", file_path)
		2: # Video
			if banner_img:
				banner_img.visible = false
			if banner_video:
				banner_video.visible = true

			var file_name: String = data.path.get_file()
			var file_path: String = get_media_path("Videos", file_name)

			if file_path != "" and ClassDB.class_exists("FFmpegVideoStream"):
				var stream = ClassDB.instantiate("FFmpegVideoStream")
				if stream:
					stream.set_file(file_path)
					banner_video.stream = stream
					banner_video.volume_db = -80  # 静音视频
					banner_video.play()
			else:
				banner_video.stop()
				banner_video.stream = null
				banner_video.visible = false
				push_warning("Work-list video playback is unavailable on this platform: %s" % file_name)

		3: # Animation
			pass
			
		_: # Default
			if banner_img:
				banner_img.visible = true
			if banner_video:
				banner_video.visible = false
				banner_video.stop()

			var file_name: String = data.path.get_file()
			var file_path: String = get_media_path("Images", file_name)

			if file_path != "":
				var image_texture = load_texture_from_file(file_path)
				if image_texture:
					banner_img.texture = image_texture
				else:
					if DEBUG_LOGS: print("Error loading texture from file:", file_path)
	
	if title_label:
		title_label.text = data.title
	if info_label:
		info_label.text = data.info

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
