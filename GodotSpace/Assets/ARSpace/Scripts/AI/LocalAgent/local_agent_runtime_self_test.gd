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
	var connected := true
	var connection_calls := 0
	func _connect_gateway() -> bool:
		connection_calls += 1
		return connected
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
	runtime.succeed = true
	assert(await runtime.ensure_asr())
	assert(runtime.calls.back() == "asr") # ASR works with model startup disabled.
	var count := runtime.calls.size()
	assert(await runtime.ensure_asr("ws://example.invalid:8765/ws/asr"))
	assert(runtime.calls.size() == count) # Never replace a custom endpoint.
	assert(await runtime.ensure_asr())
	assert(runtime.calls.size() == count + 1) # Explicit clicks recheck stopped WSL.
	var agent := root.get_node("LocalAgentClient")
	assert(not await runtime.ensure_gateway()) # Clients/menu cannot start inference.
	assert(runtime.calls.size() == count + 1)
	agent._server_role_selected = true
	runtime.succeed = false
	assert(not await runtime.ensure_gateway())
	assert(runtime.connection_calls == 0) # Never connect before backend health passes.
	runtime.succeed = true
	runtime.connected = false
	assert(not await runtime.ensure_gateway()) # HTTP readiness is not a WS handshake.
	runtime.connected = true
	assert(await runtime.ensure_gateway())
	assert(runtime.calls.back() == "server")
	assert(runtime.enabled and bool(ProjectSettings.get_setting("arspace/local_agent/enabled")))
	ProjectSettings.set_setting("arspace/local_agent/enabled", false)
	agent._server_role_selected = false
	assert(runtime.default_compute({"compute": {"remote": {}}}, "") == "remote")
	assert(runtime.default_compute({"compute": {"remote": {}}}, "local") == "local")
	assert(runtime.default_compute({"compute": {"external": {}}}, "") == "external")
	assert(runtime.default_compute({"compute": {"local": {}, "external": {}}}, "external") == "external")
	assert(runtime.default_compute({"compute": {"external": {}}}, "remote") == "remote") # never silently override saved host
	assert(await runtime.prepare_launch({"preset": "local_sky", "assistant": true}))
	assert(runtime.calls.back() == "server_voice")
	assert(await runtime.ensure_services(profile))
	assert(runtime._managed_role == "server_voice") # Keep monitoring co-hosted speech.
	assert(await runtime.prepare_launch({"preset": "join_sky", "assistant": true}))
	assert(runtime.calls.back() == "client") # Joining never starts local inference.
	count = runtime.calls.size()
	runtime._next_health_check = 0
	runtime.succeed = false
	runtime._poll_services(1)
	runtime._poll_services(2)
	assert(runtime.calls.size() == count + 1) # No duplicate while check is in flight.
	await process_frame
	await process_frame
	assert(runtime.state == "failed")
	runtime.succeed = true
	runtime._poll_services(1 + runtime.HEALTH_CHECK_INTERVAL_MSEC)
	await process_frame
	await process_frame
	assert(runtime.state == "ready" and runtime.calls.size() == count + 2)
	assert(await runtime.prepare_launch({"assistant": false}))
	runtime._poll_services(1000000)
	assert(runtime.calls.size() == count + 2) # Explicit disable stops monitoring.
	runtime.queue_free()
	print("Local Agent runtime self-test passed.")
	quit(0)
