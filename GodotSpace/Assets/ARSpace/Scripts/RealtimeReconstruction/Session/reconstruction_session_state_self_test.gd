extends SceneTree

const SessionState := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/Session/reconstruction_session_state.gd"
)

const SERVER_PEER_ID: int = 1
const SKY_PEER_ID: int = 23
const OTHER_SKY_PEER_ID: int = 24
const GROUND_PEER_ID: int = 31
const ROLE_PC_GROUND: String = "pc_ground"
const ROLE_GROUND_VR: String = "ground_vr"
const ROLE_SKY: String = "sky"

var _failures: PackedStringArray = []
var _hook_counts: Dictionary = {}


class FakePeerAuthority:
	extends Node

	var sky_peer_id: int = SKY_PEER_ID

	func get_sky_peer_id() -> int:
		return sky_peer_id

	func get_peer_role(peer_id: int) -> String:
		if peer_id == SERVER_PEER_ID:
			return ROLE_PC_GROUND
		if peer_id == sky_peer_id:
			return ROLE_SKY
		return ROLE_GROUND_VR if peer_id == GROUND_PEER_ID else "unknown"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var state := SessionState.new()
	state.name = "ReconstructionSessionState"
	state.warn_on_rejection = false
	root.add_child(state)
	_connect_hooks(state)

	_expect(state.get_state() == state.STATE_IDLE, "session must start IDLE")
	_expect(state.get_state_revision() == 0, "initial revision must be zero")
	_expect(state.get_map_version() == 0, "initial map version must be zero")
	_expect(
		not state.apply_authoritative_action(
			state.ACTION_START,
			{},
			ROLE_GROUND_VR,
			GROUND_PEER_ID
		),
		"Ground VR must be view-only"
	)

	_expect(
		state.apply_authoritative_action(
			state.ACTION_START,
			{"label": "room_a"},
			ROLE_SKY,
			SKY_PEER_ID,
			0
		),
		"Sky must be able to start a session"
	)
	var first_session_id: String = state.get_session_id()
	_expect(not first_session_id.is_empty(), "start must allocate a session id")
	_expect(state.get_state() == state.STATE_PREFLIGHT, "start must enter PREFLIGHT")
	_expect(state.get_sky_source_peer_id() == SKY_PEER_ID, "start must bind one Sky source")
	_expect(_count(&"preflight") == 1, "start must emit the preflight hook")
	_expect(_count(&"session_changed") == 1, "start must emit the session id change")
	_expect(
		not state.apply_authoritative_action(
			state.ACTION_RETRY,
			{},
			ROLE_SKY,
			OTHER_SKY_PEER_ID
		),
		"a different Sky peer must not control the active session"
	)
	_expect(
		not state.apply_authoritative_action(
			state.ACTION_CONFIRM,
			{},
			ROLE_SKY,
			SKY_PEER_ID
		),
		"confirm must be rejected before PREVIEW"
	)
	_expect(
		not state.apply_authoritative_action(
			state.ACTION_RETRY,
			{},
			ROLE_SKY,
			SKY_PEER_ID,
			0
		),
		"stale client revisions must be rejected"
	)

	_expect(state.server_mark_preflight_ready(), "Server must advance preflight")
	_expect(state.get_state() == state.STATE_COLLECTING, "preflight must enter COLLECTING")
	_expect(_count(&"collection") == 1, "collection hook must be emitted")
	_expect(state.server_mark_collection_complete(), "Server must finish collection")
	_expect(state.get_state() == state.STATE_SOLVING, "collection must enter SOLVING")
	_expect(_count(&"solve") == 1, "solve hook must be emitted")
	_expect(
		state.server_mark_solve_complete({"position_rms_m": 0.03}),
		"Server must publish a solved preview"
	)
	_expect(state.get_state() == state.STATE_PREVIEW, "solve must enter PREVIEW")
	_expect(_count(&"preview") == 1, "preview hook must be emitted")

	var revision_before_retry: int = state.get_state_revision()
	_expect(
		state.apply_authoritative_action(
			state.ACTION_RETRY,
			{},
			ROLE_SKY,
			SKY_PEER_ID,
			revision_before_retry
		),
		"active Sky must be able to retry a preview"
	)
	_expect(state.get_state() == state.STATE_PREFLIGHT, "retry must return to PREFLIGHT")
	_expect(state.get_session_id() == first_session_id, "retry must keep the session id")
	_expect(_count(&"preflight") == 2, "retry must emit another preflight hook")

	_expect(state.server_mark_preflight_ready(), "retry preflight must advance")
	_expect(state.server_mark_collection_complete(), "retry collection must finish")
	_expect(state.server_mark_solve_complete(), "retry solve must finish")
	var revision_before_confirm: int = state.get_state_revision()
	_expect(
		state.apply_authoritative_action(
			state.ACTION_CONFIRM,
			{},
			ROLE_SKY,
			SKY_PEER_ID,
			revision_before_confirm
		),
		"Sky must be able to confirm PREVIEW"
	)
	_expect(state.get_state() == state.STATE_LIVE, "confirm must enter LIVE")
	_expect(state.get_map_version() == 1, "confirm must publish map version one")
	_expect(state.has_published_map(), "confirm must make the shared map available")
	_expect(_count(&"live") == 1, "confirm must emit the live hook")
	_expect(_count(&"map_version") == 1, "confirm must emit a map version change")
	var revision_before_update: int = state.get_state_revision()
	_expect(state.server_note_map_update(), "Server must accept a live map update")
	_expect(state.get_map_version() == 2, "map updates must advance map version")
	_expect(_count(&"map_version") == 2, "live updates must emit map version changes")
	_expect(
		state.get_state_revision() == revision_before_update + 1,
		"map updates must advance snapshot revision"
	)
	_expect(
		state.apply_authoritative_action(
			state.ACTION_RETRY,
			{},
			ROLE_SKY,
			SKY_PEER_ID,
			state.get_state_revision()
		),
		"Sky must be able to re-register a LIVE map"
	)
	_expect(
		state.get_state() == state.STATE_PREFLIGHT \
			and state.get_map_version() == 3 \
			and not state.has_published_map(),
		"re-registration must hide the map from Ground until Sky reconfirms it"
	)
	_expect(state.server_mark_preflight_ready(), "re-registration preflight must advance")
	_expect(state.server_mark_collection_complete(), "re-registration collection must finish")
	_expect(state.server_mark_solve_complete(), "re-registration solve must finish")
	_expect(
		state.apply_authoritative_action(
			state.ACTION_CONFIRM,
			{},
			ROLE_SKY,
			SKY_PEER_ID,
			state.get_state_revision()
		),
		"re-registration preview must be confirmable"
	)
	_expect(state.get_map_version() == 4, "re-registration confirm must publish a new version")

	_expect(
		not state.apply_authoritative_action(
			state.ACTION_EXPORT,
			{"suggested_name": ""},
			ROLE_SKY,
			SKY_PEER_ID
		),
		"empty export names must be rejected"
	)
	_expect(
		state.apply_authoritative_action(
			state.ACTION_EXPORT,
			{"suggested_name": "room_a"},
			ROLE_SKY,
			SKY_PEER_ID,
			state.get_state_revision()
		),
		"confirmed maps must be exportable"
	)
	_expect(_count(&"export") == 1, "export must emit the persistence hook")
	_expect(
		state.apply_authoritative_action(
			state.ACTION_STOP,
			{},
			ROLE_SKY,
			SKY_PEER_ID,
			state.get_state_revision()
		),
		"Sky must be able to stop LIVE reconstruction"
	)
	_expect(state.get_state() == state.STATE_STOPPED, "stop must retain a STOPPED map")
	_expect(_count(&"stopped") == 1, "stop must emit the stopped hook")

	_expect(
		state.apply_authoritative_action(
			state.ACTION_RESET,
			{"confirmed": true},
			ROLE_PC_GROUND,
			SERVER_PEER_ID,
			state.get_state_revision()
		),
		"PC Server must be able to reset the map"
	)
	_expect(state.get_state() == state.STATE_IDLE, "reset must return to IDLE")
	_expect(state.get_session_id().is_empty(), "reset must clear the session id")
	_expect(state.get_sky_source_peer_id() == 0, "reset must release the Sky source")
	_expect(not state.has_published_map(), "reset must revoke shared map availability")
	_expect(state.get_map_version() == 5, "reset must version the map removal")
	_expect(_count(&"reset") == 1, "reset must emit the cleanup hook")
	_expect(_count(&"map_version") == 5, "reset must emit a map version change")

	_expect(
		state.apply_authoritative_action(
			state.ACTION_IMPORT,
			{"map_id": "saved_room"},
			ROLE_SKY,
			SKY_PEER_ID,
			state.get_state_revision()
		),
		"Sky must be able to request a validated server map import"
	)
	_expect(state.get_state() == state.STATE_IMPORTING, "import must enter IMPORTING")
	_expect(_count(&"import") == 1, "import must emit the import hook")
	_expect(
		state.server_report_error("READ_FAILED", "Map could not be read"),
		"Server must expose integration errors"
	)
	_expect(state.get_state() == state.STATE_ERROR, "integration failures must enter ERROR")
	_expect(state.get_error_code() == "READ_FAILED", "error code must be retained")
	_expect(_count(&"error") == 1, "errors must emit the error hook")
	_expect(
		state.apply_authoritative_action(
			state.ACTION_RETRY,
			{},
			ROLE_SKY,
			SKY_PEER_ID,
			state.get_state_revision()
		),
		"Sky must be able to retry an import failure"
	)
	_expect(state.get_state() == state.STATE_IMPORTING, "import retry must return to IMPORTING")
	_expect(
		state.server_mark_import_ready("saved_room", {"point_count": 1200}),
		"Server must expose an imported preview"
	)
	_expect(state.get_state() == state.STATE_PREVIEW, "import completion must enter PREVIEW")
	_expect(state.is_imported_session(), "import preview must retain imported-session identity")
	_expect(
		not state.apply_authoritative_action(
			state.ACTION_RETRY,
			{},
			ROLE_SKY,
			SKY_PEER_ID,
			state.get_state_revision()
		),
		"an imported preview must not start an unrelated LingBot collection",
	)
	_expect(
		state.get_state() == state.STATE_PREVIEW,
		"rejected imported-map retry must preserve the preview",
	)

	var snapshot: Dictionary = state.get_snapshot()
	_expect(state.validate_snapshot(snapshot), "authoritative snapshot must validate")
	var malformed_snapshot := snapshot.duplicate(true)
	malformed_snapshot["state_revision"] = -1
	_expect(
		not state.validate_snapshot(malformed_snapshot),
		"negative snapshot revisions must be rejected"
	)
	malformed_snapshot = snapshot.duplicate(true)
	malformed_snapshot["state_name"] = "live"
	_expect(
		not state.validate_snapshot(malformed_snapshot),
		"snapshot state names must match their numeric state"
	)
	var oversized_payload := {"label": "x".repeat(state.MAX_IDENTIFIER_LENGTH + 1)}
	_expect(
		not state.apply_authoritative_action(
			state.ACTION_START,
			oversized_payload,
			ROLE_PC_GROUND,
			SERVER_PEER_ID
		),
		"oversized identifiers must be rejected"
	)

	_expect(
		state.apply_authoritative_action(
			state.ACTION_RESET,
			{"confirmed": true},
			ROLE_PC_GROUND,
			SERVER_PEER_ID,
			state.get_state_revision()
		),
		"PC Server must be able to clear an imported preview"
	)
	var fake_authority := FakePeerAuthority.new()
	fake_authority.name = "TestReconstructionPeerAuthority"
	root.add_child(fake_authority)
	state.peer_authority_path = fake_authority.get_path()
	_expect(
		state.apply_authoritative_action(
			state.ACTION_START,
			{},
			ROLE_PC_GROUND,
			SERVER_PEER_ID,
			state.get_state_revision()
		),
		"PC Server must be able to start for the registered Sky source"
	)
	_expect(
		state.get_sky_source_peer_id() == SKY_PEER_ID,
		"PC-started sessions must still bind the registered Sky peer"
	)

	fake_authority.queue_free()
	state.queue_free()
	await process_frame
	if _failures.is_empty():
		print("RECONSTRUCTION_SESSION_STATE_SELF_TEST PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("RECONSTRUCTION_SESSION_STATE_SELF_TEST: %s" % failure)
	quit(1)


func _connect_hooks(state: Node) -> void:
	state.session_changed.connect(func(_session_id: String) -> void:
		_increment(&"session_changed")
	)
	state.map_version_changed.connect(func(_map_version: int) -> void:
		_increment(&"map_version")
	)
	state.preflight_requested.connect(func(
		_session_id: String,
		_source_peer_id: int,
		_options: Dictionary
	) -> void: _increment(&"preflight"))
	state.collection_started.connect(func(_session_id: String) -> void:
		_increment(&"collection")
	)
	state.solve_requested.connect(func(_session_id: String) -> void:
		_increment(&"solve")
	)
	state.preview_ready.connect(func(
		_session_id: String,
		_preview_info: Dictionary
	) -> void: _increment(&"preview"))
	state.live_started.connect(func(_session_id: String, _map_version: int) -> void:
		_increment(&"live")
	)
	state.reconstruction_stopped.connect(func(
		_session_id: String,
		_map_version: int
	) -> void: _increment(&"stopped"))
	state.map_reset_requested.connect(func(
		_previous_session_id: String,
		_map_version: int
	) -> void: _increment(&"reset"))
	state.import_requested.connect(func(_session_id: String, _map_id: String) -> void:
		_increment(&"import")
	)
	state.export_requested.connect(func(
		_session_id: String,
		_suggested_name: String,
		_map_version: int
	) -> void: _increment(&"export"))
	state.error_reported.connect(func(
		_session_id: String,
		_error_code: String,
		_message: String
	) -> void: _increment(&"error"))


func _increment(hook: StringName) -> void:
	_hook_counts[hook] = int(_hook_counts.get(hook, 0)) + 1


func _count(hook: StringName) -> int:
	return int(_hook_counts.get(hook, 0))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
