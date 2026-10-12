extends SceneTree

class Profile extends RefCounted:
	var server := false
	var xr := false
	func is_server() -> bool:
		return server
	func uses_xr() -> bool:
		return xr

class Runtime extends "res://Assets/ARSpace/Scripts/AI/LocalAgent/local_agent_runtime.gd":
	var calls: Array[String] = []
	var succeed := true
	func _ready() -> void:
		pass
	func _start_services(role: String) -> bool:
		calls.append(role)
		await get_tree().process_frame
		_publish("ready" if succeed else "failed", "fixture")
		return succeed


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	assert(not root.get_node("LocalAgentClient")._is_enabled()) # menu OfflinePeer is not a Server
	var runtime := Runtime.new()
	root.add_child(runtime)
	var profile := Profile.new()
	assert(await runtime.ensure_services(profile))
	assert(runtime.calls == ["client"])
	assert(await runtime.ensure_services(profile, false))
	assert(runtime.calls.size() == 1)
	assert(await runtime.ensure_services(profile))
	assert(runtime.calls.size() == 2) # explicit Start rechecks a stale service
	profile.server = true
	assert(await runtime.ensure_services(profile))
	assert(runtime.calls.back() == "server")
	profile.xr = true
	assert(await runtime.ensure_services(profile))
	assert(runtime.calls.back() == "server_voice")
	runtime.succeed = false
	assert(not await runtime.ensure_services(profile))
	assert(runtime.state == "failed")
	runtime.enabled = false
	assert(await runtime.ensure_services(profile))
	runtime.queue_free()
	print("Local Agent runtime self-test passed.")
	quit(0)
