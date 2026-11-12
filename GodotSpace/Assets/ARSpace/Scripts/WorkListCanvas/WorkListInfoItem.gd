extends Control

class_name WorkListInfoItem

const DEBUG_LOGS := false

@export var item_data: WorkListInfoData

@onready var banner_img: TextureRect = $Mask/Image
@onready var banner_video: VideoStreamPlayer = $Mask/Video
@onready var title_label: Label = $TitleInfo
@onready var info_label: Label = $WorkInfo
@onready var media_hint: Label = get_node_or_null("Mask/MediaHint")

func _ready() -> void:
	visibility_changed.connect(_on_visibility_changed)

func refresh_info(data: WorkListInfoData) -> void:
	# Always discard previous media, including when the new asset is missing.
	_clear_media()
	self.item_data = data
	if data == null:
		return
	if not visible:
		visible = true
	if title_label:
		title_label.text = data.title
	if info_label:
		info_label.text = data.info

	match data.type:
		0: # Text / communication only
			_show_media_hint("本步骤需天地通话确认\n请按下方说明操作")
		2: # Video
			var file_path := get_media_path("Videos", data.path.get_file())
			if file_path.is_empty() or banner_video == null or not ClassDB.class_exists("FFmpegVideoStream"):
				_show_media_hint("本步骤视频暂不可用\n请参考操作说明")
				return
			var stream = ClassDB.instantiate("FFmpegVideoStream")
			# FFmpeg expects a filesystem path; res:// is not an FFmpeg protocol.
			stream.set_file(ProjectSettings.globalize_path(file_path))
			banner_video.stream = stream
			banner_video.visible = true
			banner_video.volume_db = -80
			banner_video.play()
		3: # Scene animation; no unrelated placeholder video.
			_show_media_hint("请观看实验柜上的三维操作演示\n可点击「重播动画」重新观看")
		_: # Image (including legacy default type)
			var file_path := get_media_path("Images", data.path.get_file())
			var texture: Texture2D = load_texture_from_file(file_path) if not file_path.is_empty() else null
			if texture != null and banner_img != null:
				banner_img.texture = texture
				banner_img.visible = true
			else:
				_show_media_hint("本步骤图片暂不可用\n请参考操作说明和柜体指引")

func _clear_media() -> void:
	if banner_img:
		banner_img.texture = null
		banner_img.hide()
	if banner_video:
		banner_video.stop()
		banner_video.stream = null
		banner_video.hide()
	if media_hint:
		media_hint.hide()
		media_hint.text = ""

func _show_media_hint(message: String) -> void:
	if media_hint:
		media_hint.text = message
		media_hint.show()

func _on_visibility_changed() -> void:
	if banner_video and not is_visible_in_tree():
		banner_video.stop()

func get_media_path(root_directory_name: String, file_name: String) -> String:
	var base_path: String
	
	base_path = "res://Assets/StreamingAssets/%s/" % root_directory_name
	
	var full_path: String = base_path + file_name
	
	if DEBUG_LOGS: print("get_media_path -> FilePath:", full_path)

	if FileAccess.file_exists(full_path):
		return full_path
	else:
		return ""

func load_texture_from_file(path: String) -> Texture2D:
	var file := FileAccess.open(path, FileAccess.READ)
	if file:
		var bytes = file.get_buffer(file.get_length())
		var image = Image.new()
		var success = image.load_png_from_buffer(bytes)
		if success == OK:
			var texture := ImageTexture.create_from_image(image)
			return texture
	return null
