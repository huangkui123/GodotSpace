extends RefCounted

## Explicitly requested captures only. Preserve the original JPEG and metadata;
## never substitute the PC observer camera for the physical capture camera.
const MAX_JPEG_BYTES := 8 * 1024 * 1024


static func write_capture(
	directory: String,
	frame_id: int,
	timestamp_ns: int,
	frame_size: Vector2i,
	metadata: Dictionary,
	jpeg: PackedByteArray,
) -> Dictionary:
	if frame_id < 0 or timestamp_ns < 0 or frame_size.x <= 0 or frame_size.y <= 0 \
			or jpeg.is_empty() or jpeg.size() > MAX_JPEG_BYTES:
		return {"error": "没有可保存的有效 PICO 图像帧"}
	var image := Image.new()
	if image.load_jpg_from_buffer(jpeg) != OK \
			or image.get_size() != frame_size:
		return {"error": "JPEG 尺寸与帧协议不一致"}
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var folder := directory.path_join("%s_%d_%d" % [stamp, frame_id, Time.get_ticks_usec()])
	if DirAccess.make_dir_recursive_absolute(folder) != OK:
		return {"error": "无法创建采集目录"}
	var image_file := FileAccess.open(folder.path_join("image.jpg"), FileAccess.WRITE)
	if image_file == null:
		return {"error": "无法写入采集图像"}
	image_file.store_buffer(jpeg)
	image_file.close()
	var capture := {
		"schema_version": 1,
		"frame_id": frame_id,
		"timestamp_ns": str(timestamp_ns),
		"width": frame_size.x,
		"height": frame_size.y,
		"metadata": metadata.duplicate(true),
		"camera_calibration_verified": false,
		"note": "Original capture metadata; intrinsics, distortion, extrinsics and timing need validation.",
	}
	var metadata_file := FileAccess.open(folder.path_join("capture.json"), FileAccess.WRITE)
	if metadata_file == null:
		return {"error": "无法写入采集 metadata"}
	metadata_file.store_string(JSON.stringify(capture, "\t"))
	metadata_file.close()
	return {"path": ProjectSettings.globalize_path(folder)}
