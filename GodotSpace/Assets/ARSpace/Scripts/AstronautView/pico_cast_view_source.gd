extends "res://Assets/ARSpace/Scripts/AstronautView/astronaut_view_source.gd"

## Adapter between the PICO Cast control channel and the FFmpeg
## GDExtension. The extension decodes USB HTTP/MPEG-TS or legacy RTMP; this owns the
## local VideoStreamPlayer and exposes its texture to AstronautViewWindow.

const DEFAULT_FFMPEG_STREAM_CLASS := &"FFmpegVideoStream"
const METADATA_UPDATE_INTERVAL_MSEC := 500
const CONNECT_TIMEOUT_MSEC := 8000
const OPEN_FAILURE_GRACE_MSEC := 750
const RETRY_DELAY_MSEC := 4000
const MAX_OPEN_ATTEMPTS := 4

@export var ffmpeg_stream_class: StringName = DEFAULT_FFMPEG_STREAM_CLASS

var _rtmp_url := ""
var _session_metadata: Dictionary = {}
var _control_status_message := ""
var _video_player: VideoStreamPlayer
var _is_requested := false
var _last_texture: Texture2D
var _next_metadata_update_msec := 0
var _connect_started_msec := 0
var _reported_connect_timeout := false
var _open_attempt_count := 0
var _next_retry_msec := 0
var _retry_pending := false


func _ready() -> void:
	set_process(false)


func requires_network_peer() -> bool:
	return false


func set_cast_session(rtmp_url: String, metadata: Dictionary = {}) -> void:
	var normalized_url := rtmp_url.strip_edges()
	var url_changed := normalized_url != _rtmp_url
	_rtmp_url = normalized_url
	_session_metadata = metadata.duplicate(true)
	if _rtmp_url.is_empty():
		_stop_stream(true)
		_publish_texture(null)
		_publish_metadata({})
		_publish_waiting_status()
		return
	if url_changed:
		_reset_open_attempts()
		if _is_requested:
			_open_decoder()
	elif _is_requested:
		_update_metadata(true)


func set_control_status(message: String) -> void:
	_control_status_message = message
	if _rtmp_url.is_empty() and _is_requested:
		_publish_waiting_status()


func start(_source_peer_id: int) -> void:
	_is_requested = true
	_reset_open_attempts()
	if _rtmp_url.is_empty():
		_publish_waiting_status()
		return
	_open_decoder()


func stop() -> void:
	_is_requested = false
	_stop_stream(true)
	_publish_texture(null)
	_publish_metadata({})
	_publish_status(Status.IDLE, "")


func get_texture() -> Texture2D:
	return _last_texture


func _process(_delta: float) -> void:
	if _video_player == null:
		return
	var now_msec := Time.get_ticks_msec()
	var attempt_age_msec := now_msec - _connect_started_msec
	var playback_failed := not _video_player.is_playing() \
		and attempt_age_msec >= OPEN_FAILURE_GRACE_MSEC
	if playback_failed:
		if _last_texture != null:
			_last_texture = null
			_publish_texture(null)
		_handle_open_failure(now_msec, false)
		_update_metadata()
		return
	var texture := _video_player.get_video_texture()
	if texture != _last_texture:
		_last_texture = texture
		_publish_texture(_last_texture)
	if _last_texture != null:
		_retry_pending = false
		_next_retry_msec = 0
		_publish_status(Status.LIVE, "PICO 头显实时投屏")
	else:
		var attempt_timed_out := attempt_age_msec >= CONNECT_TIMEOUT_MSEC
		if attempt_timed_out:
			_handle_open_failure(now_msec, true)
	_update_metadata()


func _open_decoder() -> void:
	_stop_stream(false)
	if not ClassDB.class_exists(ffmpeg_stream_class):
		_publish_status(
			Status.ERROR,
			"缺少 FFmpeg 视频解码扩展 %s" % ffmpeg_stream_class,
		)
		return
	var stream := ClassDB.instantiate(ffmpeg_stream_class) as VideoStream
	if stream == null:
		_publish_status(Status.ERROR, "PICO 视频解码扩展不是 VideoStream")
		return
	_open_attempt_count += 1
	stream.file = _normalize_decoder_url(_rtmp_url)
	_video_player = VideoStreamPlayer.new()
	_video_player.name = "PicoCastRTMPPlayer"
	_video_player.stream = stream
	_video_player.volume_db = -80.0
	add_child(_video_player)
	_video_player.play()
	_connect_started_msec = Time.get_ticks_msec()
	_reported_connect_timeout = false
	_next_retry_msec = 0
	_retry_pending = false
	_next_metadata_update_msec = 0
	set_process(true)
	_publish_status(
		Status.CONNECTING,
		"正在连接 PICO 投屏（第 %d/%d 次）" % [
			_open_attempt_count,
			MAX_OPEN_ATTEMPTS,
		],
	)
	_update_metadata(true)


func _stop_stream(reset_attempts: bool = false) -> void:
	set_process(false)
	if _video_player != null and is_instance_valid(_video_player):
		_video_player.stop()
		_video_player.queue_free()
	_video_player = null
	_last_texture = null
	_connect_started_msec = 0
	_reported_connect_timeout = false
	_next_retry_msec = 0
	_retry_pending = false
	if reset_attempts:
		_reset_open_attempts()


func _handle_open_failure(now_msec: int, timed_out: bool) -> void:
	if _retry_pending:
		if now_msec >= _next_retry_msec:
			_open_decoder()
		return
	if _open_attempt_count >= MAX_OPEN_ATTEMPTS:
		set_process(false)
		_publish_status(
			Status.ERROR,
			"FFmpeg 连续 %d 次无法建立 PICO 投屏，请查看 Godot 日志" \
				% MAX_OPEN_ATTEMPTS,
		)
		return
	_reported_connect_timeout = timed_out
	_retry_pending = true
	_next_retry_msec = now_msec + RETRY_DELAY_MSEC
	_publish_status(
		Status.STALLED,
		"PICO 投屏第 %d 次连接失败，4 秒后重试" % _open_attempt_count,
	)


func _reset_open_attempts() -> void:
	_open_attempt_count = 0
	_next_retry_msec = 0
	_retry_pending = false
	_reported_connect_timeout = false


func _update_metadata(force: bool = false) -> void:
	var now_msec := Time.get_ticks_msec()
	if not force and now_msec < _next_metadata_update_msec:
		return
	_next_metadata_update_msec = now_msec + METADATA_UPDATE_INTERVAL_MSEC
	var resolution := Vector2i.ZERO
	if _last_texture != null:
		resolution = _last_texture.get_size()
	_publish_metadata({
		"source_type": "pico_cast",
		"source_name": "PICO 投屏 · %s" % str(_session_metadata.get("device_name", "头显")),
		"resolution": resolution,
		"aspect_ratio": float(resolution.x) / float(maxi(resolution.y, 1)),
		"audio_enabled": false,
		"timestamp_msec": now_msec,
		"transport": str(_session_metadata.get("transport", "rtmp")),
		"rectified": _session_metadata.get("rectified", false) == true,
	})


func _publish_waiting_status() -> void:
	var message := _control_status_message
	if message.is_empty():
		message = "等待 PICO 头显投屏"
	var status := Status.CONNECTING
	for error_marker in ["未启动", "失败", "无效", "过大"]:
		if message.contains(error_marker):
			status = Status.ERROR
			break
	_publish_status(status, message)


func _normalize_decoder_url(rtmp_url: String) -> String:
	var query_index := rtmp_url.find("?")
	if query_index < 0:
		return rtmp_url
	var base_url := rtmp_url.substr(0, query_index)
	var query := rtmp_url.substr(query_index + 1)
	var retained_parameters := PackedStringArray()
	for parameter in query.split("&", false):
		var key := parameter.get_slice("=", 0).strip_edges().to_lower()
		if key == "listen":
			continue
		retained_parameters.append(parameter)
	if retained_parameters.is_empty():
		return base_url
	return "%s?%s" % [base_url, "&".join(retained_parameters)]
