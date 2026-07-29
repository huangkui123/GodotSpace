class_name PicoCastControlReceiver
extends Node

## Receives short-lived PICO Cast RTMP session descriptors from the companion
## app. This is intentionally independent from the PSA2 spatial-calibration
## frame protocol and never persists or logs the RTMP URL.

signal session_changed(rtmp_url: String, metadata: Dictionary)
signal receiver_status_changed(message: String)

const MESSAGE_TYPE := "pico_cast_session"
const PROTOCOL_VERSION := 1
const MAX_URL_LENGTH := 2048

@export_range(1, 65535, 1) var listen_port: int = 8788
@export var token_environment_name := "GODOTSPACE_PICO_CAST_CONTROL_TOKEN"
@export var require_authentication := true
@export var auto_start := false
@export_range(512, 65536, 512) var max_message_bytes: int = 8192

var _server := TCPServer.new()
var _clients: Array[Dictionary] = []
var _shared_token := ""
var _current_rtmp_url := ""
var _current_metadata: Dictionary = {}
var _last_status_message := ""


func _ready() -> void:
	if auto_start:
		start_receiver()


func start_receiver() -> bool:
	if _server.is_listening():
		return true
	_shared_token = OS.get_environment(token_environment_name).strip_edges()
	if require_authentication and _shared_token.is_empty():
		_set_status("PICO 投屏控制未启动：缺少环境变量 %s" % token_environment_name)
		return false
	var error := _server.listen(listen_port)
	if error != OK:
		_set_status("PICO 投屏控制端口 %d 监听失败：%s" % [listen_port, error_string(error)])
		return false
	_set_status("PICO 投屏控制正在监听 %d" % listen_port)
	return true


func stop_receiver(clear_session: bool = true) -> void:
	for client_state in _clients:
		var peer := client_state.get("peer") as StreamPeerTCP
		if peer != null:
			peer.disconnect_from_host()
	_clients.clear()
	if _server.is_listening():
		_server.stop()
	if clear_session:
		_clear_session("PICO 投屏控制已停止")


func _exit_tree() -> void:
	stop_receiver(false)


func _process(_delta: float) -> void:
	_accept_connections()
	_process_clients()


func get_current_rtmp_url() -> String:
	return _current_rtmp_url


func get_current_metadata() -> Dictionary:
	return _current_metadata.duplicate(true)


func get_status_message() -> String:
	return _last_status_message


func _accept_connections() -> void:
	if not _server.is_listening():
		return
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer == null:
			return
		peer.set_no_delay(true)
		_clients.append({
			"peer": peer,
			"buffer": PackedByteArray(),
		})


func _process_clients() -> void:
	for index in range(_clients.size() - 1, -1, -1):
		var client_state := _clients[index]
		var peer := client_state.get("peer") as StreamPeerTCP
		if peer == null:
			_clients.remove_at(index)
			continue
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			peer.disconnect_from_host()
			_clients.remove_at(index)
			continue

		var available := peer.get_available_bytes()
		if available <= 0:
			continue
		var buffer: PackedByteArray = client_state.get("buffer", PackedByteArray())
		if buffer.size() + available > max_message_bytes:
			_set_status("PICO 投屏控制消息过大，已断开")
			peer.disconnect_from_host()
			_clients.remove_at(index)
			continue
		var received := peer.get_data(available)
		if received.size() < 2 or int(received[0]) != OK:
			peer.disconnect_from_host()
			_clients.remove_at(index)
			continue
		buffer.append_array(received[1] as PackedByteArray)
		var consume_result := _consume_messages(buffer)
		var keep_connection := bool(consume_result[0])
		buffer = consume_result[1] as PackedByteArray
		if not keep_connection:
			peer.disconnect_from_host()
			_clients.remove_at(index)
			continue
		client_state["buffer"] = buffer
		_clients[index] = client_state


func _consume_messages(buffer: PackedByteArray) -> Array:
	while true:
		var newline_index := -1
		for index in range(buffer.size()):
			if buffer[index] == 10:
				newline_index = index
				break
		if newline_index < 0:
			return [true, buffer]
		var payload := buffer.slice(0, newline_index).get_string_from_utf8().strip_edges()
		buffer = buffer.slice(newline_index + 1)
		if payload.is_empty():
			continue
		if not _accept_message(payload):
			return [false, PackedByteArray()]
	return [true, buffer]


func _accept_message(payload: String) -> bool:
	var json := JSON.new()
	if json.parse(payload) != OK or typeof(json.data) != TYPE_DICTIONARY:
		_set_status("PICO 投屏控制消息不是合法 JSON")
		return false
	var message := json.data as Dictionary
	if int(message.get("version", -1)) != PROTOCOL_VERSION \
			or str(message.get("type", "")) != MESSAGE_TYPE:
		_set_status("PICO 投屏控制消息版本或类型无效")
		return false
	if require_authentication and str(message.get("authorization", "")) != _shared_token:
		_set_status("PICO 投屏控制鉴权失败")
		return false

	var state := str(message.get("state", ""))
	if state == "stopped":
		_clear_session("PICO 头显已停止投屏")
		return true
	if state != "live":
		_set_status("PICO 投屏控制状态无效：%s" % state)
		return false

	var rtmp_url := str(message.get("rtmp_url", "")).strip_edges()
	if rtmp_url.length() > MAX_URL_LENGTH \
			or not (rtmp_url.begins_with("rtmp://") or rtmp_url.begins_with("rtmps://")):
		_set_status("PICO 投屏 URL 无效")
		return false
	message.erase("authorization")
	message.erase("rtmp_url")
	_current_rtmp_url = rtmp_url
	_current_metadata = message.duplicate(true)
	_set_status("已收到 %s 的 PICO RTMP 投屏会话" % str(message.get("device_name", "头显")))
	session_changed.emit(_current_rtmp_url, get_current_metadata())
	return true


func _clear_session(message: String) -> void:
	if _current_rtmp_url.is_empty() and _current_metadata.is_empty():
		_set_status(message)
		return
	_current_rtmp_url = ""
	_current_metadata.clear()
	_set_status(message)
	session_changed.emit("", {})


func _set_status(message: String) -> void:
	if _last_status_message == message:
		return
	_last_status_message = message
	receiver_status_changed.emit(message)
