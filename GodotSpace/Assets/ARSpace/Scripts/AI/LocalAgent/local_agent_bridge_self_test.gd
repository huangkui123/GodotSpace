extends SceneTree

const ClientScript := preload("res://Assets/ARSpace/Scripts/AI/LocalAgent/local_agent_client.gd")
const RegistryScript := preload("res://Assets/ARSpace/Scripts/AI/LocalAgent/local_agent_tool_registry.gd")
const OpenAlbumAdapterScript := preload("res://Assets/ARSpace/Scripts/AI/LocalAgent/open_album_tool_adapter.gd")

class FakeAlbum:
	extends Node
	var call_count := 0
	var visible := false

	func open_album(page: int, refresh: bool) -> Dictionary:
		call_count += 1
		visible = true
		return {
			"ok": true,
			"data": {"visible": visible, "page": page, "refreshed": refresh},
			"error": null,
		}

class ContextAdapter:
	extends RefCounted
	var last_context: Dictionary = {}

	func execute(arguments: Dictionary, context: Dictionary) -> Dictionary:
		last_context = context.duplicate(true)
		return {"ok": true, "data": arguments.duplicate(true), "error": null}

class DeferredAdapter:
	extends RefCounted

	func execute(_arguments: Dictionary, _context: Dictionary) -> Dictionary:
		return {"__deferred__": true}

class SynchronousDeferredAdapter:
	extends RefCounted
	var client: Node

	func _init(target_client: Node) -> void:
		client = target_client

	func execute(_arguments: Dictionary, context: Dictionary) -> Dictionary:
		client.call("complete_deferred_tool_call", str(context.get("tool_call_id", "")), {
			"ok": true,
			"data": {"completed_synchronously": true},
			"error": null,
		})
		return {"__deferred__": true}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if OS.get_cmdline_user_args().has("--force-failure"):
		if not _check(false, "Forced self-test failure."):
			return
	var picture_scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/PictureCanvas.tscn")
	if not _check(picture_scene != null, "PictureCanvas scene did not load"):
		return
	var picture_root := picture_scene.instantiate()
	root.add_child(picture_root)
	await process_frame
	var real_adapter := OpenAlbumAdapterScript.new()
	var real_opened: Dictionary = real_adapter.execute({"page": 1, "refresh": false})
	if not _check(bool(real_opened.get("ok", false)), "production adapter did not open PictureCanvas"):
		return
	var real_canvas := picture_root.get_node_or_null("Canvas")
	if not _check(real_canvas != null and real_canvas.visible, "PictureCanvas was not made visible"):
		return
	picture_root.queue_free()
	await process_frame

	var album := FakeAlbum.new()
	root.add_child(album)
	var adapter := OpenAlbumAdapterScript.new(func() -> Node: return album)
	var registry := RegistryScript.new()
	if not _check(registry.register_tool("open_album", Callable(adapter, "execute")), "open_album registration failed"):
		return
	if not _check(not registry.register_tool("open_album", Callable(adapter, "execute")), "duplicate registration was accepted"):
		return

	var opened := registry.dispatch("open_album", {"page": 2, "refresh": false})
	if not _check(bool(opened.get("ok", false)), "open_album did not succeed"):
		return
	if not _check(int((opened.get("data", {}) as Dictionary).get("page", 0)) == 2, "page was not forwarded"):
		return
	if not _check(album.visible, "album was not made visible"):
		return

	var invalid := registry.dispatch("open_album", {"node_path": "/root/Global"})
	if not _check(_error_code(invalid) == "invalid_arguments", "unknown arguments were not rejected"):
		return
	var fractional_page := registry.dispatch("open_album", {"page": 1.5})
	if not _check(_error_code(fractional_page) == "invalid_arguments", "fractional page was accepted"):
		return
	var unknown := registry.dispatch("call_method", {"method": "queue_free"})
	if not _check(_error_code(unknown) == "unknown_tool", "unregistered method call was accepted"):
		return

	var missing_adapter := OpenAlbumAdapterScript.new(func() -> Node: return null)
	var missing := missing_adapter.execute({})
	if not _check(_error_code(missing) == "album_not_ready", "missing album did not return album_not_ready"):
		return

	var client := ClientScript.new()
	client.set_tool_registry_for_test(registry)
	var first := client.execute_tool_call_for_test("tool-1", "open_album", {"page": 1})
	var duplicate := client.execute_tool_call_for_test("tool-1", "open_album", {"page": 9})
	if not _check(first == duplicate, "duplicate tool_call_id did not replay its original result"):
		return
	var conflict := client.execute_tool_call_for_test(
		"tool-1", "different_tool", {}, "different-request"
	)
	if not _check(_error_code(conflict) == "tool_call_conflict", "conflicting duplicate tool_call_id was accepted"):
		return
	if not _check(album.call_count == 2, "duplicate tool call executed more than once"):
		return

	var context_adapter := ContextAdapter.new()
	if not _check(registry.register_tool("context_tool", Callable(context_adapter, "execute")), "context tool registration failed"):
		return
	var contextual := client.execute_tool_call_for_test(
		"tool-context", "context_tool", {"value": 7}, "request-context"
	)
	if not _check(bool(contextual.get("ok", false)), "context-aware tool failed"):
		return
	if not _check(str(context_adapter.last_context.get("request_id", "")) == "request-context", "request context was not passed to the tool"):
		return

	var deferred_adapter := DeferredAdapter.new()
	if not _check(registry.register_tool("deferred_tool", Callable(deferred_adapter, "execute")), "deferred tool registration failed"):
		return
	var deferred := client.execute_tool_call_for_test(
		"tool-deferred", "deferred_tool", {}, "request-deferred"
	)
	if not _check(bool(deferred.get("__deferred__", false)), "deferred tool was completed synchronously"):
		return
	client.complete_deferred_tool_call("tool-deferred", {
		"ok": true,
		"data": {"completed": true},
		"error": null,
	})
	var replayed_deferred := client.execute_tool_call_for_test(
		"tool-deferred", "deferred_tool", {}, "request-deferred"
	)
	if not _check(bool((replayed_deferred.get("data", {}) as Dictionary).get("completed", false)), "deferred result was not cached after completion"):
		return
	var synchronous_adapter := SynchronousDeferredAdapter.new(client)
	if not _check(registry.register_tool("synchronous_deferred_tool", Callable(synchronous_adapter, "execute")), "synchronous deferred tool registration failed"):
		return
	var synchronous_result := client.execute_tool_call_for_test(
		"tool-synchronous-deferred",
		"synchronous_deferred_tool",
		{},
		"request-synchronous-deferred"
	)
	if not _check(
		bool((synchronous_result.get("data", {}) as Dictionary).get("completed_synchronously", false)),
		"synchronous deferred completion was lost before cache registration"
	):
		return
	client.execute_tool_call_for_test(
		"tool-abandoned", "deferred_tool", {}, "request-abandoned"
	)
	client.abandon_deferred_tool_calls_for_request("request-abandoned")
	var cache_after_abandon := client.get("_tool_result_cache") as Dictionary
	if not _check(not cache_after_abandon.has("tool-abandoned"), "abandoned deferred tool remained cached"):
		return
	if not _check(not client.complete_deferred_tool_call("tool-abandoned", {
		"ok": true, "data": {"late": true}, "error": null,
	}), "late completion after abandon was retained as an early result"):
		return

	var protocol_client := ClientScript.new()
	protocol_client.set_tool_registry_for_test(registry)
	protocol_client.call("_handle_envelope", _tool_call_envelope("", "tool-before-hello"))
	if not _check(album.call_count == 2, "tool call executed before hello_ack"):
		return
	var debug_state: Dictionary = protocol_client.get_debug_state()
	if not _check(not str(debug_state.get("last_error", "")).is_empty(), "protocol error was not exposed"):
		return

	protocol_client.set("_hello_sent", true)
	protocol_client.call("_handle_envelope", _envelope("hello_ack", "session-test"))
	protocol_client.call("_handle_envelope", _tool_call_envelope("wrong-session", "tool-wrong-session"))
	if not _check(album.call_count == 2, "tool call from another session was executed"):
		return

	protocol_client.set("_hello_sent", true)
	protocol_client.call("_handle_envelope", _envelope("hello_ack", "session-test"))
	protocol_client.call("_handle_envelope", _tool_call_envelope("session-test", "tool-correct-session"))
	if not _check(album.call_count == 3, "valid post-handshake tool call was not executed"):
		return
	protocol_client.set("_last_pong_msec", 0)
	protocol_client.call("_handle_envelope", _envelope("pong", "session-test"))
	debug_state = protocol_client.get_debug_state()
	if not _check(int(debug_state.get("last_pong_msec", 0)) > 0, "pong did not update heartbeat state"):
		return
	protocol_client.set("_last_pong_msec", 1)
	if not _check(bool(protocol_client.call("_pong_timed_out", 25_002)), "stale pong did not trigger timeout state"):
		return

	ProjectSettings.set_setting("arspace/local_agent/enabled", false)
	protocol_client.call("_process", 0.0)
	ProjectSettings.set_setting("arspace/local_agent/enabled", true)
	debug_state = protocol_client.get_debug_state()
	if not _check(not bool(debug_state.get("connected", true)), "runtime disable kept the connection active"):
		return
	if not _check(str(debug_state.get("session_id", "")).is_empty(), "runtime disable kept handshake state"):
		return

	client.free()
	protocol_client.free()
	album.free()
	print("Local Agent bridge self test passed.")
	quit(0)


func _check(condition: bool, message: String) -> bool:
	if condition:
		return true
	push_error(message)
	quit(1)
	return false


func _error_code(result: Dictionary) -> String:
	var error_value: Variant = result.get("error", {})
	return str((error_value as Dictionary).get("code", "")) if typeof(error_value) == TYPE_DICTIONARY else ""


func _envelope(message_type: String, session_id: String) -> Dictionary:
	return {
		"protocol_version": "1.0",
		"type": message_type,
		"session_id": session_id,
		"request_id": "",
		"tool_call_id": "",
		"payload": {},
	}


func _tool_call_envelope(session_id: String, tool_call_id: String) -> Dictionary:
	var result := _envelope("tool_call", session_id)
	result["request_id"] = "request-protocol-test"
	result["tool_call_id"] = tool_call_id
	result["payload"] = {"name": "open_album", "arguments": {"page": 1}}
	return result
