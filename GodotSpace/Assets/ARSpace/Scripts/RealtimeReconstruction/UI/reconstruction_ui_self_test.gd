extends SceneTree

const PANEL_SCENE_PATH := \
	"res://Assets/ARSpace/Scenes/RealtimeReconstruction/RealtimeReconstructionPanel.tscn"
const PANEL_SURFACE_SCENE_PATH := \
	"res://Assets/ARSpace/Scenes/RealtimeReconstruction/RealtimeReconstructionPanelSurface.tscn"
const WORKSPACE_SCENE_PATH := \
	"res://Assets/ARSpace/Scenes/RealtimeReconstruction/RealtimeReconstructionWorkspace.tscn"
const MAIN_MENU_SCENE_PATH := \
	"res://Assets/ARSpace/Prefabs/UI/MainMenuCanvas/MainMenuCanvasAR2D.tscn"
const PanelUI := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/UI/reconstruction_panel_ui.gd"
)
const WorkspaceController := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/UI/reconstruction_workspace_controller.gd"
)

var _failures: PackedStringArray = []


class FakeSessionController:
	extends Node

	signal snapshot_changed(snapshot: Dictionary)
	signal operation_rejected(action: StringName, message: String)

	var snapshot: Dictionary = {
		"state_name": "idle",
		"state": 0,
		"state_revision": 0,
		"map_version": 0,
		"has_published_map": false,
		"error_message": "",
	}
	var calls: Dictionary = {}
	var last_import_map_id: String = ""
	var last_export_name: String = ""

	func get_snapshot() -> Dictionary:
		return snapshot.duplicate(true)

	func request_start(_options: Dictionary = {}) -> bool:
		_record(&"start")
		return true

	func request_stop() -> bool:
		_record(&"stop")
		return true

	func request_retry() -> bool:
		_record(&"retry")
		return true

	func request_confirm() -> bool:
		_record(&"confirm")
		return true

	func request_reset() -> bool:
		_record(&"reset")
		return true

	func request_import(map_id: String) -> bool:
		last_import_map_id = map_id
		_record(&"import")
		return true

	func request_export(suggested_name: String) -> bool:
		last_export_name = suggested_name
		_record(&"export")
		return true

	func count(method_name: StringName) -> int:
		return int(calls.get(method_name, 0))

	func publish_state(state_name: String, state: int, error_message: String = "") -> void:
		snapshot["state_name"] = state_name
		snapshot["state"] = state
		snapshot["state_revision"] = int(snapshot["state_revision"]) + 1
		snapshot["error_message"] = error_message
		if state_name in ["live", "stopped"]:
			snapshot["has_published_map"] = true
		snapshot_changed.emit(get_snapshot())

	func reject(action: StringName, message: String) -> void:
		operation_rejected.emit(action, message)

	func _record(method_name: StringName) -> void:
		calls[method_name] = int(calls.get(method_name, 0)) + 1


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var panel_scene := ResourceLoader.load(PANEL_SCENE_PATH) as PackedScene
	var surface_scene := ResourceLoader.load(PANEL_SURFACE_SCENE_PATH) as PackedScene
	var workspace_scene := ResourceLoader.load(WORKSPACE_SCENE_PATH) as PackedScene
	var main_menu_scene := ResourceLoader.load(MAIN_MENU_SCENE_PATH) as PackedScene
	_expect(panel_scene != null, "reconstruction panel scene must load")
	_expect(surface_scene != null, "reconstruction panel surface must load")
	_expect(workspace_scene != null, "reconstruction workspace scene must load")
	_expect(main_menu_scene != null, "main menu scene must load after adding the entry")
	if panel_scene == null or workspace_scene == null or main_menu_scene == null:
		_finish()
		return

	var panel := panel_scene.instantiate()
	root.add_child(panel)
	_expect(panel != null and panel.get_script() == PanelUI, "panel root must use panel UI script")
	if panel != null:
		_expect(panel.has_signal("manual_adjustment_requested"), "panel must expose manual adjustment")
		_expect(panel.has_signal("exit_requested"), "panel must expose exit")
		panel.configure_role("sky")
		panel.set_view_state(PanelUI.ViewState.PREVIEW)
		_expect(
			panel.get_node("Margin/Layout/Pages/SkyPages/PreviewPage").visible,
			"sky PREVIEW must display manual registration controls"
		)
		panel.configure_role("ground_vr")
		_expect(
			panel.get_node("Margin/Layout/Pages/GroundPage").visible,
			"ground role must display the read-only page"
		)
		panel.set_service_status(&"helper", true, "12 FPS")
		_expect(
			"12 FPS" in str(panel.get_node("Margin/Layout/ServiceGrid/HelperStatus").text),
			"service status detail must be visible"
		)
		panel.configure_role("sky")
		panel.set_view_state(PanelUI.ViewState.PREFLIGHT)
		_expect(
			str(panel.get_node("Margin/Layout/Header/StateLabel").text) == "预检",
			"PREFLIGHT must have a distinct user-facing state"
		)

	var fake_session := FakeSessionController.new()
	fake_session.name = "FakeReconstructionSession"
	fake_session.add_to_group("reconstruction_session_controller")
	root.add_child(fake_session)
	var workspace := workspace_scene.instantiate()
	root.add_child(workspace)
	await process_frame
	_expect(
		workspace.get_script() == WorkspaceController,
		"workspace root must use the reconstruction workspace controller"
	)
	_expect(
		workspace.get_node_or_null("ReconstructionRoot/PointCloudChunks") != null,
		"workspace must own the point-cloud chunk root"
	)
	_expect(
		workspace.get_node_or_null("GroundSpawnAnchor") is Marker3D,
		"workspace must expose the independent ground spawn anchor"
	)
	_expect(
		workspace.get_node_or_null("LocalPanelHost/PanelSurface") != null,
		"workspace must own one local 3D panel surface"
	)
	var workspace_panel := workspace.get("_panel_ui") as Node
	_expect(workspace_panel != null, "workspace must bind its local panel")
	_expect(
		workspace.get("_session_controller") == fake_session,
		"workspace must bind the authoritative reconstruction session"
	)
	workspace.set_start_prerequisites_ready(true)
	workspace.call("_on_start_requested")
	_expect(
		fake_session.count(&"start") == 1,
		"start UI action must call request_start"
	)
	workspace.set_selected_import_map_id("")
	workspace.call("_on_import_requested")
	_expect(
		fake_session.count(&"import") == 0,
		"import UI action must not invent a server map id"
	)
	workspace.set_selected_import_map_id("saved_room")
	workspace.call("_on_import_requested")
	_expect(
		fake_session.count(&"import") == 1 \
			and fake_session.last_import_map_id == "saved_room",
		"import UI action must pass the selected map id to request_import"
	)
	workspace.call("_on_confirm_requested")
	workspace.call("_on_retry_requested")
	workspace.call("_on_stop_requested")
	workspace.call("_on_reregister_requested")
	workspace.call("_on_export_requested")
	workspace.call("_on_cancel_requested")
	workspace.call("_on_clear_requested")
	workspace.call("_on_new_session_requested")
	_expect(fake_session.count(&"confirm") == 1, "confirm UI action must call request_confirm")
	_expect(
		fake_session.count(&"retry") == 2,
		"retry and re-register UI actions must call request_retry"
	)
	_expect(fake_session.count(&"stop") == 1, "stop UI action must call request_stop")
	_expect(
		fake_session.count(&"export") == 1 \
			and not fake_session.last_export_name.is_empty(),
		"export UI action must provide a default name to request_export"
	)
	_expect(
		fake_session.count(&"reset") == 2,
		"cancel and clear UI actions must call request_reset"
	)
	_expect(
		fake_session.count(&"start") == 2,
		"new-session UI action must call request_start"
	)

	fake_session.publish_state("preflight", 1)
	_expect(
		int(workspace_panel.get("_view_state")) == PanelUI.ViewState.PREFLIGHT,
		"session snapshots must map PREFLIGHT to the panel"
	)
	fake_session.publish_state("live", 5)
	_expect(
		int(workspace_panel.get("_view_state")) == PanelUI.ViewState.LIVE,
		"session snapshots must map LIVE to the panel"
	)
	fake_session.reject(&"confirm", "测试拒绝")
	_expect(
		int(workspace_panel.get("_view_state")) == PanelUI.ViewState.ERROR,
		"session rejection signals must surface in the panel"
	)

	workspace.set("_workspace_active", true)
	workspace.set("_local_role", "sky")
	var stop_count_before_exit := fake_session.count(&"stop")
	workspace.call("_on_exit_requested")
	_expect(
		not workspace.is_workspace_active(),
		"exit must return only the local user to ARSpace"
	)
	_expect(
		fake_session.count(&"stop") == stop_count_before_exit,
		"exiting the workspace must not stop the shared reconstruction session"
	)

	var menu := main_menu_scene.instantiate()
	root.add_child(menu)
	_expect(
		menu.get_node_or_null("Canvas/WorkTabView/GridContainer/RealtimeReconstruction") is Button,
		"work-mode grid must contain the realtime reconstruction entry"
	)

	menu.queue_free()
	workspace.queue_free()
	fake_session.queue_free()
	panel.queue_free()
	await process_frame
	_finish()


func _finish() -> void:
	if _failures.is_empty():
		print("REALTIME_RECONSTRUCTION_UI_SELF_TEST PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("REALTIME_RECONSTRUCTION_UI_SELF_TEST: %s" % failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
