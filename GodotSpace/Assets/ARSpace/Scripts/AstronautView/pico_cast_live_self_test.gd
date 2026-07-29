extends SceneTree

## Opt-in hardware smoke test. It never prints or persists the short-lived RTMP
## URL. Run with GODOTSPACE_PICO_CAST_LIVE_TEST=1 and the same control token used
## by the PICO companion app.

const ControlReceiverScript = preload(
	"res://Assets/ARSpace/Scripts/AstronautView/pico_cast_control_receiver.gd"
)
const PicoCastSourceScript = preload(
	"res://Assets/ARSpace/Scripts/AstronautView/pico_cast_view_source.gd"
)
const TEST_TIMEOUT_MSEC := 60000

var _receiver: Node
var _source: Node
var _session_received := false


func _init() -> void:
	if OS.get_environment("GODOTSPACE_PICO_CAST_LIVE_TEST") != "1":
		push_error("Set GODOTSPACE_PICO_CAST_LIVE_TEST=1 to run the PICO hardware test.")
		quit(2)
		return
	call_deferred("_run_test")


func _run_test() -> void:
	_receiver = ControlReceiverScript.new()
	_source = PicoCastSourceScript.new()
	root.add_child(_receiver)
	root.add_child(_source)
	_receiver.session_changed.connect(_on_session_changed)
	if not bool(_receiver.call("start_receiver")):
		_fail(str(_receiver.call("get_status_message")))
		return
	_source.call("start", 0)

	var deadline := Time.get_ticks_msec() + TEST_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var texture := _source.call("get_texture") as Texture2D
		if int(_source.call("get_status")) == 2 and texture != null:
			var resolution := texture.get_size()
			print(
				"PICO Cast live self-test passed: session=true, resolution=%dx%d"
				% [resolution.x, resolution.y]
			)
			_cleanup()
			quit(0)
			return

	var status_message := str(_source.call("get_status_message"))
	if not _session_received:
		status_message = "Timed out waiting for a PICO Cast control session."
	_fail(status_message)


func _on_session_changed(rtmp_url: String, metadata: Dictionary) -> void:
	if rtmp_url.is_empty():
		return
	_session_received = true
	var normalized_url := str(_source.call("_normalize_decoder_url", rtmp_url))
	var authority_start := normalized_url.find("://") + 3
	var has_path := authority_start >= 3 and normalized_url.find("/", authority_start) >= 0
	print(
		"PICO Cast descriptor received: listen_flag_removed=%s, has_path=%s"
		% [
			rtmp_url.to_lower().contains("listen")
				and not normalized_url.to_lower().contains("listen"),
			has_path,
		]
	)
	_source.call("set_cast_session", rtmp_url, metadata)


func _fail(message: String) -> void:
	push_error("PICO Cast live self-test failed: %s" % message)
	_cleanup()
	quit(1)


func _cleanup() -> void:
	if _source != null:
		_source.call("stop")
	if _receiver != null:
		_receiver.call("stop_receiver", false)
