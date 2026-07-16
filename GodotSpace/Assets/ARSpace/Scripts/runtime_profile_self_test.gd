extends SceneTree

const RuntimeProfile = preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")

var failures: PackedStringArray = []


func _initialize() -> void:
	_run_cases()
	if failures.is_empty():
		print("Runtime profile self-test passed")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_cases() -> void:
	var pc = RuntimeProfile.from_args([], [], false)
	_expect(pc.is_valid(), "default PC profile should be valid")
	_expect(pc.is_server() and pc.is_ground(), "default PC profile should be Ground Server")
	_expect(pc.uses_desktop_ui() and not pc.uses_xr(), "default PC profile should use desktop presentation")

	var ground_vr = RuntimeProfile.from_args(
		["--xr-mode", "on", "--", "--ground-vr", "--voice-role=server"],
		["--ground-vr", "--voice-role=server"],
		false
	)
	_expect(ground_vr.is_valid(), "Ground VR profile should be valid")
	_expect(ground_vr.is_server() and ground_vr.is_ground(), "Ground VR should be Ground Server")
	_expect(ground_vr.uses_xr() and not ground_vr.uses_passthrough(), "Ground VR should use opaque XR")
	_expect(ground_vr.can_annotate(), "Ground VR should be allowed to annotate")

	var sky = RuntimeProfile.from_args(
		["--xr-mode=on", "--", "--xr-client", "--voice-role=client"],
		["--xr-client", "--voice-role=client"],
		false
	)
	_expect(sky.is_valid(), "Sky XR profile should be valid")
	_expect(sky.is_client() and sky.is_sky(), "Sky XR should be Sky Client")
	_expect(sky.uses_xr() and sky.uses_passthrough(), "Sky XR should request passthrough")
	_expect(not sky.can_annotate(), "Sky XR should be display-only")

	var test_client = RuntimeProfile.from_args(
		["--", "--testmode", "--voice-role=client"],
		["--testmode", "--voice-role=client"],
		false
	)
	_expect(test_client.is_valid() and test_client.is_client(), "test client should keep its network role")
	_expect(test_client.is_test_mode() and not test_client.uses_xr(), "test client should avoid XR")
	_expect(test_client.uses_desktop_ui(), "test client should keep desktop-capable UI")

	var test_server = RuntimeProfile.from_args(
		["--", "--testmode", "--voice-role=server"],
		["--testmode", "--voice-role=server"],
		false
	)
	_expect(test_server.is_valid() and test_server.is_server(), "test server should keep its network role")
	_expect(test_server.is_test_mode() and test_server.can_annotate(), "test Ground Server should keep annotation authority")

	var conflicting = RuntimeProfile.from_args(
		["--xr-mode", "on", "--", "--ground-vr", "--xr-client"],
		["--ground-vr", "--xr-client"],
		false
	)
	_expect(not conflicting.is_valid(), "conflicting Ground VR and Sky flags should be rejected")

	var conflicting_client_role = RuntimeProfile.from_args(
		["--xr-mode", "on", "--", "--ground-vr", "--voice-role=client"],
		["--ground-vr", "--voice-role=client"],
		false
	)
	_expect(not conflicting_client_role.is_valid(), "Ground VR with a client voice role should be rejected")

	var conflicting_server_role = RuntimeProfile.from_args(
		["--xr-mode", "on", "--", "--xr-client", "--voice-role=server"],
		["--xr-client", "--voice-role=server"],
		false
	)
	_expect(not conflicting_server_role.is_valid(), "Sky XR with a server voice role should be rejected")

	var conflicting_test_mode = RuntimeProfile.from_args(
		["--xr-mode", "on", "--", "--ground-vr", "--testmode", "--voice-role=server"],
		["--ground-vr", "--testmode", "--voice-role=server"],
		false
	)
	_expect(not conflicting_test_mode.is_valid(), "Ground VR with test mode should be rejected")

	var conflicting_sky_test_mode = RuntimeProfile.from_args(
		["--", "--xr-client", "--testmode", "--voice-role=client"],
		["--xr-client", "--testmode", "--voice-role=client"],
		false
	)
	_expect(not conflicting_sky_test_mode.is_valid(), "Sky XR with test mode should be rejected")

	var conflicting_engine_xr_test_mode = RuntimeProfile.from_args(
		["--xr-mode", "on", "--", "--testmode", "--voice-role=client"],
		["--testmode", "--voice-role=client"],
		false
	)
	_expect(not conflicting_engine_xr_test_mode.is_valid(), "engine XR mode with test presentation should be rejected")

	var xr_disabled_ground = RuntimeProfile.from_args(
		["--xr-mode", "off", "--", "--ground-vr", "--voice-role=server"],
		["--ground-vr", "--voice-role=server"],
		false
	)
	_expect(not xr_disabled_ground.is_valid(), "Ground VR with --xr-mode off should be rejected")

	var xr_disabled_sky = RuntimeProfile.from_args(
		["--xr-mode=off", "--", "--voice-role=client"],
		["--voice-role=client"],
		false
	)
	_expect(not xr_disabled_sky.is_valid(), "Sky XR with --xr-mode off should be rejected")

	var engine_xr_capability_only = RuntimeProfile.from_args(
		["--xr-mode", "on"],
		[],
		false
	)
	_expect(engine_xr_capability_only.is_valid(), "--xr-mode on alone should be valid")
	_expect(engine_xr_capability_only.is_server() and not engine_xr_capability_only.uses_xr(), "engine XR capability alone should keep the default PC Ground mode")
	_expect(not engine_xr_capability_only.selection_locked, "engine XR capability alone should leave the menu selectable")

	var engine_xr_disabled_only = RuntimeProfile.from_args(
		["--xr-mode", "off"],
		[],
		false
	)
	_expect(engine_xr_disabled_only.is_valid() and engine_xr_disabled_only.is_server(), "--xr-mode off alone should keep PC Ground valid")
	_expect(engine_xr_disabled_only.selection_locked, "--xr-mode off should prevent selecting an XR presentation in the menu")

	var implicit_xr_server = RuntimeProfile.from_args(
		["--xr-mode", "on", "--", "--voice-role=server"],
		["--voice-role=server"],
		false
	)
	_expect(not implicit_xr_server.is_valid(), "an XR Server launch without --ground-vr should be rejected")

	var invalid_voice_role = RuntimeProfile.from_args(
		["--", "--voice-role=operator"],
		["--voice-role=operator"],
		false
	)
	_expect(not invalid_voice_role.is_valid(), "an unsupported voice role should be rejected")

	var invalid_xr_mode = RuntimeProfile.from_args(
		["--xr-mode", "maybe"],
		[],
		false
	)
	_expect(not invalid_xr_mode.is_valid(), "an unsupported XR mode should be rejected")

	var android_server = RuntimeProfile.from_args(
		["--", "--ground-vr", "--voice-role=server"],
		["--ground-vr", "--voice-role=server"],
		true
	)
	_expect(not android_server.is_valid(), "Android Ground Server should be rejected")

	var android_default = RuntimeProfile.from_args([], [], true)
	_expect(android_default.is_valid(), "default Android profile should be valid")
	_expect(android_default.is_client() and android_default.is_sky(), "default Android profile should be Sky Client")
	_expect(android_default.uses_xr() and android_default.uses_passthrough(), "default Android profile should use passthrough XR")

	RuntimeProfile.clear_session_override()
	var menu_ground_vr = RuntimeProfile.select_session_mode(RuntimeProfile.Preset.VR_GROUND_SERVER, false)
	_expect(RuntimeProfile.current() == menu_ground_vr, "menu selection should persist for the session")
	_expect(menu_ground_vr.uses_xr() and menu_ground_vr.is_server(), "menu Ground VR preset should use XR Server")
	_expect(not menu_ground_vr.selection_locked, "menu-selected modes should remain changeable after returning to StartMenu")
	var rejected_android_menu = RuntimeProfile.select_session_mode(RuntimeProfile.Preset.VR_GROUND_SERVER, true)
	_expect(not rejected_android_menu.is_valid(), "Android menu must reject Ground VR Server")
	RuntimeProfile.clear_session_override()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
