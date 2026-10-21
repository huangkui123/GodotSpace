extends SceneTree

const ControlReceiverScript = preload(
	"res://Assets/ARSpace/Scripts/AstronautView/pico_cast_control_receiver.gd"
)
const PicoCastSourceScript = preload(
	"res://Assets/ARSpace/Scripts/AstronautView/pico_cast_view_source.gd"
)

var _failures: Array[String] = []


func _init() -> void:
	await process_frame
	_test_control_message_validation()
	_test_usb_control_validation()
	_test_pico_listen_flag_is_removed_for_decoder()
	_test_control_failure_is_reported()
	_test_missing_ffmpeg_decoder_is_reported()
	_test_new_session_resets_decoder_retries()
	if _failures.is_empty():
		print("PICO Cast control self-test passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_control_message_validation() -> void:
	var receiver := ControlReceiverScript.new()
	receiver.require_authentication = false
	var valid_message := JSON.stringify({
		"version": 1,
		"type": "pico_cast_session",
		"state": "live",
		"authorization": "not-retained",
		"rtmp_url": "rtmp://192.168.10.2:1935/live/pico",
		"device_name": "PICO Test",
		"audio_enabled": false,
	})
	_expect(bool(receiver.call("_accept_message", valid_message)), "Valid PICO Cast control message should be accepted.")
	_expect(str(receiver.call("get_current_rtmp_url")).begins_with("rtmp://"), "Accepted message should retain an RTMP URL.")
	var received_metadata := receiver.call("get_current_metadata") as Dictionary
	_expect(not received_metadata.has("authorization"), "Control token must not reach view-source metadata.")
	_expect(not received_metadata.has("rtmp_url"), "RTMP URL must not be duplicated in view-source metadata.")
	_expect(
		not bool(receiver.call("_accept_message", JSON.stringify({
			"version": 1,
			"type": "pico_cast_session",
			"state": "live",
			"rtmp_url": "https://not-an-rtmp-stream",
		}))),
		"Non-RTMP control URLs must be rejected."
	)
	_expect(
		bool(receiver.call("_accept_message", JSON.stringify({
			"version": 1,
			"type": "pico_cast_session",
			"state": "stopped",
		}))),
		"Authenticated stop message should be accepted."
	)
	_expect(receiver.call("get_current_rtmp_url") == "", "Stop message should clear the active RTMP session.")
	receiver.queue_free()


func _test_pico_listen_flag_is_removed_for_decoder() -> void:
	var source := PicoCastSourceScript.new()
	var normalized_url := str(source.call(
		"_normalize_decoder_url",
		"rtmp://192.168.10.2:3343/live?pico=1&listen&session=test"
	))
	_expect(
		normalized_url == "rtmp://192.168.10.2:3343/live?pico=1&session=test",
		"PICO's server-side listen flag must not reach the FFmpeg consumer."
	)
	source.queue_free()


func _test_usb_control_validation() -> void:
	var receiver := ControlReceiverScript.new()
	receiver.set("_shared_token", "a".repeat(48))
	var request := {"version": 1, "type": "pico_cast_session", "state": "live",
		"authorization": "a".repeat(48), "transport": "usb",
		"stream_url": "http://192.168.1.20:35451/" + "c".repeat(48) + "/video.ts"}
	_expect(receiver.call("_accept_message", JSON.stringify(request)), "Authenticated USB stream should be accepted.")
	var metadata: Dictionary = receiver.call("get_current_metadata")
	_expect(metadata.transport == "usb" and not metadata.has("stream_url") and not metadata.has("authorization"),
		"USB metadata must retain transport without duplicating secrets.")
	request.authorization = "wrong-token"
	_expect(not receiver.call("_accept_message", JSON.stringify(request)), "USB requires the same control authentication as RTMP.")
	request.authorization = "a".repeat(48)
	for invalid_url in ["file:///etc/passwd", "http://127.0.0.1:80/admin", "http://127.0.0.1:99999/" + "a".repeat(48) + "/video.ts"]:
		request.stream_url = invalid_url
		_expect(not receiver.call("_accept_message", JSON.stringify(request)), "Invalid USB URL must be rejected.")
	receiver.free()


func _test_control_failure_is_reported() -> void:
	var source := PicoCastSourceScript.new()
	source.call(
		"set_control_status",
		"PICO 投屏控制未启动：缺少环境变量 GODOTSPACE_PICO_CAST_CONTROL_TOKEN"
	)
	source.call("start", 0)
	_expect(
		int(source.call("get_status")) == 4,
		"Control-channel startup failures should surface as a source error."
	)
	_expect(
		str(source.call("get_status_message")).contains("GODOTSPACE_PICO_CAST_CONTROL_TOKEN"),
		"Control-channel errors should retain the actionable environment-variable name."
	)
	source.queue_free()


func _test_missing_ffmpeg_decoder_is_reported() -> void:
	var source := PicoCastSourceScript.new()
	source.ffmpeg_stream_class = &"MissingPicoCastFFmpegStream"
	root.add_child(source)
	await process_frame
	source.call("set_cast_session", "rtmp://192.168.10.2:1935/live/pico", {})
	source.call("start", 0)
	_expect(int(source.call("get_status")) == 4, "Missing FFmpeg RTMP decoder should surface an explicit error state.")
	_expect(
		str(source.call("get_status_message")).contains("MissingPicoCastFFmpegStream"),
		"Missing decoder error should name the required native class."
	)
	source.queue_free()
	await process_frame


func _test_new_session_resets_decoder_retries() -> void:
	var source := PicoCastSourceScript.new()
	source.set("_open_attempt_count", 3)
	source.set("_retry_pending", true)
	source.call(
		"set_cast_session",
		"rtmp://192.168.10.2:1935/live/new-session",
		{},
	)
	_expect(
		int(source.get("_open_attempt_count")) == 0,
		"A new PICO Cast session should reset the decoder retry budget.",
	)
	_expect(
		not bool(source.get("_retry_pending")),
		"A new PICO Cast session should clear a pending decoder retry.",
	)
	source.queue_free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
