class_name AstronautViewSource
extends Node

## Texture-producing boundary used by the astronaut-view window. Future network
## decoders can implement the same contract without changing the window scene.

enum Status {
	IDLE,
	CONNECTING,
	LIVE,
	STALLED,
	ERROR,
}

signal texture_changed(texture: Texture2D)
signal status_changed(status: int, message: String)
signal metadata_changed(metadata: Dictionary)

var _status: int = Status.IDLE
var _status_message: String = ""
var _metadata: Dictionary = {}


func start(_source_peer_id: int) -> void:
	pass


func stop() -> void:
	_publish_texture(null)
	_publish_status(Status.IDLE, "")


func get_texture() -> Texture2D:
	return null


func get_status() -> int:
	return _status


func get_status_message() -> String:
	return _status_message


func get_metadata() -> Dictionary:
	return _metadata.duplicate(true)


func _publish_texture(texture: Texture2D) -> void:
	texture_changed.emit(texture)


func _publish_status(status: int, message: String) -> void:
	if _status == status and _status_message == message:
		return
	_status = status
	_status_message = message
	status_changed.emit(_status, _status_message)


func _publish_metadata(metadata: Dictionary) -> void:
	if _metadata == metadata:
		return
	_metadata = metadata.duplicate(true)
	metadata_changed.emit(get_metadata())
