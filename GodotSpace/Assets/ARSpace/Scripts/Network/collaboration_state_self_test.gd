extends SceneTree

const Schema = preload("res://Assets/ARSpace/Scripts/Network/collaboration_state_schema.gd")
const CollaborationStateScript = preload("res://Assets/ARSpace/Scripts/Network/collaboration_state.gd")

class MockPeerAuthority:
	extends Node

	var roles: Dictionary = {
		1: Schema.ROLE_PC_GROUND,
		2: Schema.ROLE_ASTRONAUT,
	}

	func get_peer_role(peer_id: int) -> String:
		return str(roles.get(peer_id, ""))


var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var authority := MockPeerAuthority.new()
	authority.name = "CollaborationTestAuthority"
	root.add_child(authority)
	var state = CollaborationStateScript.new()
	state.name = "CollaborationStateUnderTest"
	state.peer_authority_path = NodePath("../CollaborationTestAuthority")
	root.add_child(state)

	_test_schema_validation()
	_test_authoritative_state(state)

	state.queue_free()
	authority.queue_free()
	await process_frame
	_finish()


func _test_schema_validation() -> void:
	_expect(Schema.get_domains() == [
		"menu",
		"active_windows",
		"task",
		"media",
		"window_transforms",
		"strokes",
		"models",
	], "The schema must expose every canonical Phase 1 domain in contract order.")
	_expect(bool(Schema.normalize_change(
		Schema.DOMAIN_TASK,
		Schema.OP_SET,
		{"task_id": 0, "step": 0, "event_revision": 0, "playback": "stopped"}
	).get("ok", false)), "Task id zero must represent the inactive task.")
	_expect(not bool(Schema.normalize_change(
		Schema.DOMAIN_TASK,
		Schema.OP_SET,
		{"task_id": 6, "step": 0, "event_revision": 0, "playback": "stopped"}
	).get("ok", false)), "Out-of-range task ids must be rejected.")
	_expect(not bool(Schema.normalize_change(
		Schema.DOMAIN_MODELS,
		Schema.OP_UPSERT,
		{"model_id": "res://unsafe_scene.tscn", "shared_transform": Transform3D.IDENTITY}
	).get("ok", false)), "Models must use the controlled model whitelist rather than resource paths.")
	_expect(bool(Schema.normalize_change(
		Schema.DOMAIN_MODELS,
		Schema.OP_UPSERT,
		{"model_id": "microscope", "shared_transform": Transform3D.IDENTITY}
	).get("ok", false)), "Whitelisted placeable model ids must be accepted.")
	_expect(not bool(Schema.normalize_change(
		Schema.DOMAIN_WINDOW_TRANSFORMS,
		Schema.OP_UPSERT,
		_make_window_transform("too_far", Transform3D(Basis.IDENTITY, Vector3(51.0, 0.0, 0.0)))
	).get("ok", false)), "Shared-space transforms beyond 50 metres must be rejected.")
	var oversized_menu := {
		"mode": "life",
		"active_tab": "home",
		"page_id": "x".repeat(Schema.MAX_REQUEST_BYTES),
	}
	_expect(not bool(Schema.normalize_change(
		Schema.DOMAIN_MENU,
		Schema.OP_SET,
		oversized_menu
	).get("ok", false)), "Requests over 64 KiB must be rejected.")
	_expect(not Schema.is_valid_request_envelope("x".repeat(Schema.MAX_REQUEST_BYTES), Schema.OP_SET, {}), "The 64 KiB limit must cover the full request envelope, not only payload.")
	_expect(not Schema.is_role_allowed(Schema.DOMAIN_MENU, Schema.ROLE_ASTRONAUT), "Astronaut must not mutate ground-only domains.")
	_expect(Schema.is_role_allowed(Schema.DOMAIN_STROKES, Schema.ROLE_ASTRONAUT), "Astronaut may create shared strokes.")
	_expect(Schema.is_role_allowed(Schema.DOMAIN_MODELS, Schema.ROLE_ASTRONAUT), "Astronaut may place whitelisted models.")

	var mismatched_snapshot := Schema.make_default_state()
	mismatched_snapshot[Schema.DOMAIN_WINDOW_TRANSFORMS]["orphan"] = _make_window_transform("orphan", Transform3D.IDENTITY)
	_expect(not bool(Schema.normalize_snapshot(mismatched_snapshot).get("ok", false)), "Snapshots must reject a transform without the matching active window.")
	mismatched_snapshot = Schema.make_default_state()
	mismatched_snapshot[Schema.DOMAIN_ACTIVE_WINDOWS]["orphan"] = _make_active_window("orphan")
	_expect(not bool(Schema.normalize_snapshot(mismatched_snapshot).get("ok", false)), "Snapshots must reject an active window without the matching transform.")


func _test_authoritative_state(state: Node) -> void:
	var offline_results: Array[Dictionary] = []
	state.request_completed.connect(func(result: Dictionary) -> void: offline_results.append(result))
	var menu_sequence: int = state.request_change(
		Schema.DOMAIN_MENU,
		Schema.OP_SET,
		{"mode": "work", "active_tab": "tasks", "page_id": "task_1"}
	)
	_expect(menu_sequence == 1, "Request sequences must start at one.")
	_expect(state.get_session_revision() == 0, "An OfflineMultiplayerPeer must never be treated as an active Server authority.")
	_expect(offline_results.size() == 1 and str(offline_results[0].get("error", "")) == "not_connected", "An offline public request must complete with not_connected.")
	var first_menu: Dictionary = state.call(
		"_process_server_request",
		1,
		10,
		Schema.DOMAIN_MENU,
		Schema.OP_SET,
		{"mode": "work", "active_tab": "tasks", "page_id": "task_1"}
	)
	_expect(bool(first_menu.get("accepted", false)), "The internal Server state machine must accept a valid ground mutation.")
	_expect(state.get_session_revision() == 1, "The first accepted state change must increment the session revision once.")
	_expect(state.get_domain_revision(Schema.DOMAIN_MENU) == 1, "The changed menu domain must increment once.")
	state.call(
		"_process_server_request",
		1,
		11,
		Schema.DOMAIN_MENU,
		Schema.OP_SET,
		{"mode": "work", "active_tab": "tasks", "page_id": "task_1"}
	)
	_expect(state.get_session_revision() == 1, "An accepted no-op must not increment revisions.")

	state.call("_process_server_request", 1, 12, Schema.DOMAIN_ACTIVE_WINDOWS, Schema.OP_UPSERT, _make_active_window("window_1"))
	var current_state: Dictionary = state.get_state()
	_expect(current_state[Schema.DOMAIN_ACTIVE_WINDOWS].has("window_1"), "Active-window upsert must create the window record.")
	_expect(current_state[Schema.DOMAIN_WINDOW_TRANSFORMS].has("window_1"), "Active-window upsert must create its safe default transform pair.")
	_expect(state.get_domain_revision(Schema.DOMAIN_ACTIVE_WINDOWS) == 1, "Active-window revision must track the paired creation.")
	_expect(state.get_domain_revision(Schema.DOMAIN_WINDOW_TRANSFORMS) == 1, "Transform revision must track the paired creation.")
	state.call("_process_server_request", 1, 13, Schema.DOMAIN_WINDOW_TRANSFORMS, Schema.OP_REMOVE, "window_1")
	current_state = state.get_state()
	_expect(not current_state[Schema.DOMAIN_ACTIVE_WINDOWS].has("window_1"), "Removing a transform must remove the matching active window.")
	_expect(not current_state[Schema.DOMAIN_WINDOW_TRANSFORMS].has("window_1"), "Removing a transform must remove that transform.")
	_expect(state.get_domain_revision(Schema.DOMAIN_ACTIVE_WINDOWS) == 2, "Cascade removal must increment the active-window revision.")
	_expect(state.get_domain_revision(Schema.DOMAIN_WINDOW_TRANSFORMS) == 2, "Cascade removal must increment the transform revision.")

	var denied: Dictionary = state.call(
		"_process_server_request",
		2,
		1,
		Schema.DOMAIN_MENU,
		Schema.OP_SET,
		{"mode": "life", "active_tab": "home", "page_id": ""}
	)
	_expect(not bool(denied.get("accepted", true)) and str(denied.get("error", "")) == "role_not_allowed", "Server role lookup must reject astronaut mutations of ground-only state.")

	var model_payload := {"model_id": "fern", "shared_transform": Transform3D.IDENTITY}
	var before_model_revision: int = state.get_session_revision()
	var first: Dictionary = state.call(
		"_process_server_request",
		2,
		2,
		Schema.DOMAIN_MODELS,
		Schema.OP_UPSERT,
		model_payload
	)
	var duplicate: Dictionary = state.call(
		"_process_server_request",
		2,
		2,
		Schema.DOMAIN_MODELS,
		Schema.OP_UPSERT,
		model_payload
	)
	_expect(bool(first.get("accepted", false)), "Astronaut model placement must be accepted for a whitelisted model.")
	_expect(first == duplicate, "An exact request retry must receive the cached result.")
	_expect(state.get_session_revision() == before_model_revision + 1, "An exact retry must not create a second model or increment revision.")
	_expect((state.get_domain_state(Schema.DOMAIN_MODELS) as Dictionary).size() == 1, "An exact retry must not duplicate the created model.")
	var conflict: Dictionary = state.call(
		"_process_server_request",
		2,
		2,
		Schema.DOMAIN_MODELS,
		Schema.OP_UPSERT,
		{"model_id": "pine_m", "shared_transform": Transform3D.IDENTITY}
	)
	_expect(str(conflict.get("error", "")) == "request_sequence_conflict", "Reusing a sequence for a different payload must be rejected.")

	var envelope: Dictionary = state.call("_make_snapshot_envelope")
	var replica = CollaborationStateScript.new()
	_expect(bool(replica.call("_apply_snapshot_envelope", envelope)), "A valid full snapshot must apply to a replica.")
	_expect(replica.get_state() == state.get_state(), "Snapshot application must reproduce every collaboration domain.")
	var invalid_envelope := envelope.duplicate(true)
	invalid_envelope["domain_revisions"][Schema.DOMAIN_MODELS] = int(invalid_envelope["session_revision"]) + 1
	_expect(not bool(replica.call("_apply_snapshot_envelope", invalid_envelope)), "A domain revision newer than the session revision must be rejected.")
	replica.free()

	_expect(not bool(state.reset_session()), "An offline node must not be allowed to reset an authoritative session.")
	state.call("_on_session_closed")
	_expect(state.get_session_revision() == 0 and state.get_state() == Schema.make_default_state(), "Session close cleanup must clear revisions and all confirmed state.")


func _make_active_window(entity_id: String) -> Dictionary:
	return {
		"id": entity_id,
		"window_type": "task_panel",
		"visible": true,
		"closed": false,
	}


func _make_window_transform(entity_id: String, transform: Transform3D) -> Dictionary:
	return {
		"id": entity_id,
		"shared_transform": transform,
		"size": Vector2(1.0, 0.6),
		"state": "normal",
		"snap_slot": "",
		"focus_order": 0,
	}


func _finish() -> void:
	if _failures.is_empty():
		print("Collaboration state self-test passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
