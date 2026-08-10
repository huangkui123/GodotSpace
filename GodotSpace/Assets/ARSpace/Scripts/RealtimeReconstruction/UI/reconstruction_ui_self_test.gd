extends SceneTree

const PANEL_SCENE_PATH := \
	"res://Assets/ARSpace/Scenes/RealtimeReconstruction/RealtimeReconstructionPanel.tscn"
const PANEL_SURFACE_SCENE_PATH := \
	"res://Assets/ARSpace/Scenes/RealtimeReconstruction/RealtimeReconstructionPanelSurface.tscn"
const PANEL_INPUT_BODY_SCRIPT_PATH := \
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/UI/reconstruction_panel_input_body.gd"
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
const PanelInputBody := preload(PANEL_INPUT_BODY_SCRIPT_PATH)

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
	if panel_scene == null \
			or surface_scene == null \
			or workspace_scene == null \
			or main_menu_scene == null:
		_finish()
		return

	var detached_surface := surface_scene.instantiate()
	root.add_child(detached_surface)
	await process_frame
	var detached_input_body := detached_surface.get_node("StaticBody3D")
	root.remove_child(detached_surface)
	detached_surface.call("_on_pointer_event", null)
	detached_input_body.call("_on_pointer_event", null)
	detached_surface.free()

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
	var test_to_camera := Vector3(0.6, 0.0, 0.8).normalized()
	var panel_facing_basis := WorkspaceController.make_panel_facing_basis(
		test_to_camera
	)
	_expect(
		panel_facing_basis.z.dot(test_to_camera) > 0.9999,
		"reconstruction panel local +Z front must face the XR camera initially"
	)
	_expect(
		panel_facing_basis.determinant() > 0.9999,
		"reconstruction panel facing basis must not mirror its viewport texture"
	)
	var panel_input_body := workspace.get_node_or_null(
		"LocalPanelHost/PanelSurface/StaticBody3D"
	)
	_expect(
		panel_input_body != null and panel_input_body.get_script() == PanelInputBody,
		"reconstruction panel must suppress duplicate XR touch input"
	)
	var workspace_panel := workspace.get("_panel_ui") as Node
	_expect(workspace_panel != null, "workspace must bind its local panel")
	workspace.set("_local_role", "sky")
	if workspace_panel != null:
		workspace_panel.configure_role("sky")
	if workspace_panel != null and panel_input_body != null:
		var test_map_entries: Array[Dictionary] = [
			{
				"file_name": "room_a.gsmap",
				"manifest": {
					"display_name": "Room A",
					"point_count": 1000,
				},
			},
			{
				"file_name": "room_b.gsmap",
				"manifest": {
					"display_name": "Room B",
					"point_count": 2000,
				},
			},
		]
		workspace_panel.call("set_map_library", test_map_entries)
		await process_frame
		var map_selector := workspace_panel.get_node(
			"Margin/Layout/Pages/SkyPages/PreparePage/Content/MapRow/MapChooser/MapSelector"
		) as Button
		var map_list_panel := workspace_panel.get_node(
			"Margin/Layout/Pages/SkyPages/PreparePage/Content/MapRow/MapChooser/MapListPanel"
		) as PanelContainer
		var map_items := workspace_panel.get_node(
			"Margin/Layout/Pages/SkyPages/PreparePage/Content/MapRow/MapChooser/MapListPanel/MapListMargin/MapScroll/MapItems"
		) as VBoxContainer
		var selector_center := map_selector.get_global_rect().get_center()
		panel_input_body.call("_report_touch_down", 0, selector_center)
		panel_input_body.call("_report_mouse_down", selector_center)
		panel_input_body.call("_report_touch_up", 0, selector_center)
		panel_input_body.call("_report_mouse_up", selector_center)
		await process_frame
		_expect(
			map_list_panel.visible,
			"one XR click must leave the embedded server map list open"
		)
		for refresh_index in range(6):
			workspace_panel.call("set_map_library", test_map_entries)
			workspace.set_start_prerequisites_ready(true)
			workspace_panel.call(
				"set_service_status",
				&"helper",
				true,
				"refresh %d" % refresh_index,
			)
			await create_timer(0.2).timeout
			_expect(
				map_list_panel.visible,
				"periodic status refresh %d must not close the embedded map list" \
					% refresh_index
			)
		var first_map_button := map_items.get_child(0) as Button
		first_map_button.pressed.emit()
		_expect(
			not map_list_panel.visible \
				and str(workspace.get("_selected_import_map_id")) == "room_a.gsmap",
			"choosing an embedded map item must select it and close the list"
		)
	_expect(
		workspace.get("_session_controller") == fake_session,
		"workspace must bind the authoritative reconstruction session"
	)
	workspace.set_start_prerequisites_ready(true)
	var start_button := workspace_panel.get_node(
		"Margin/Layout/Pages/SkyPages/PreparePage/Content/Actions/StartButton"
	) as Button
	_expect(not start_button.disabled, "ready Sky workspace must enable the start button")
	start_button.pressed.emit()
	_expect(
		fake_session.count(&"start") == 1,
		"start button signal must call request_start"
	)
	_expect(
		int(workspace_panel.get("_view_state")) == PanelUI.ViewState.PREFLIGHT,
		"start must immediately show request progress before the Server snapshot arrives"
	)
	fake_session.publish_state("preflight", 1)
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
	fake_session.publish_state("stopped", 6)
	workspace.call("_on_new_session_requested")
	_expect(fake_session.count(&"confirm") == 1, "confirm UI action must call request_confirm")
	_expect(
		fake_session.count(&"retry") == 2,
		"retry and re-register UI actions must call request_retry"
	)
	_expect(fake_session.count(&"stop") == 1, "stop UI action must call request_stop")
	_expect(
		fake_session.count(&"export") == 1 \
			and fake_session.last_export_name.ends_with("_实时重建") \
			and not fake_session.last_export_name.begins_with("实时重建_"),
		"export UI action must use the realtime-reconstruction label as a suffix"
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
		"non-start rejection signals must surface in the error page"
	)
	fake_session.publish_state("idle", 0)
	workspace.set_start_prerequisites_ready(true)
	workspace.call("_on_start_requested")
	fake_session.reject(&"start", "测试开始拒绝")
	workspace.set_start_prerequisites_ready(true)
	_expect(
		int(workspace_panel.get("_view_state")) == PanelUI.ViewState.PREPARE,
		"start rejection must remain visible on the prepare page"
	)
	_expect(
		"测试开始拒绝" in str(workspace_panel.get_node(
			"Margin/Layout/Pages/SkyPages/PreparePage/Content/Description"
		).text),
		"idle snapshots must not erase the start rejection feedback"
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
