extends SceneTree

const ManagerScript := preload("res://Assets/ARSpace/Scripts/VirtualAnnotation/virtual_annotation_manager.gd")
const BuilderScript := preload("res://Assets/ARSpace/Scripts/VirtualAnnotation/virtual_annotation_surface_builder.gd")
const InteractionScript := preload("res://Assets/ARSpace/Scripts/VirtualAnnotation/virtual_annotation_interaction_controller.gd")
const MarkerScript := preload("res://Assets/ARSpace/Scripts/VirtualAnnotation/virtual_annotation_marker.gd")
const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const MAX_ANNOTATIONS: int = 128
const MAX_TEXT_LENGTH: int = 80
const ANNOTATION_SURFACE_LAYER: int = 1 << 23

var _failures: PackedStringArray = []


class MockFunctionPointer extends Node:
	var target: Node3D
	var last_target: Node3D


class HeadlessMarker extends VirtualAnnotationMarker:
	func _ready() -> void:
		pass


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var shared_origin := Node3D.new()
	shared_origin.name = "SharedSpaceOrigin"
	root.add_child(shared_origin)
	var target := Node3D.new()
	target.name = "TargetPanel"
	target.position = Vector3(2.0, 1.0, -3.0)
	shared_origin.add_child(target)

	var manager = ManagerScript.new()
	manager.name = "Manager"
	manager.shared_space_origin_path = NodePath("..")
	manager.target_root_path = NodePath("..")
	manager.marker_scene = null
	manager.warn_on_rejection = false
	shared_origin.add_child(manager)

	var draft := manager.make_draft_from_hit(
		target.to_global(Vector3(0.1, 0.2, 0.0)),
		Vector3.FORWARD,
		target
	)
	_check(not draft.is_empty(), "make_draft_from_hit should accept a shared-space target")
	_check(str(draft.get("target_path", "")) == "TargetPanel", "target path should be relative to SharedSpaceOrigin")
	RuntimeProfile.select_session_mode(RuntimeProfile.Preset.SKY_XR_CLIENT, false)
	_check(manager.create_annotation(draft) == -1, "a disconnected Sky client must remain view-only")
	RuntimeProfile.clear_session_override()
	draft["text"] = "一".repeat(100)
	var first_id := manager.create_annotation(draft)
	_check(first_id == 1, "first server annotation id should be 1")
	_check(manager.get_annotation_count() == 1, "create_annotation should retain session state")
	_check(str(manager.get_annotation(first_id).get("text", "")).length() == MAX_TEXT_LENGTH, "annotation text should be capped at 80 characters")
	_check(manager.update_annotation_text(first_id, "更新后的说明"), "server should update annotation text")
	_check(str(manager.get_annotation(first_id).get("text", "")) == "更新后的说明", "updated annotation text should be readable")
	var vr_text_interaction = InteractionScript.new()
	vr_text_interaction.name = "VRTextInteraction"
	vr_text_interaction.manager_path = NodePath("../Manager")
	vr_text_interaction.show_pc_panel = false
	shared_origin.add_child(vr_text_interaction)
	vr_text_interaction.set("_selected_annotation_id", first_id)
	vr_text_interaction.call("set_draft_text", "VR 重新录音说明")
	_check(bool(vr_text_interaction.call("confirm_draft_or_update")), "VR text buffer should update a selected annotation without a PC LineEdit")
	_check(str(manager.get_annotation(first_id).get("text", "")) == "VR 重新录音说明", "selected VR annotation should retain re-recorded text")
	vr_text_interaction.free()

	var invalid_draft := draft.duplicate(true)
	invalid_draft["shared_position"] = Vector3(NAN, 0.0, 0.0)
	_check(manager.create_annotation(invalid_draft) == -1, "non-finite positions must be rejected")
	var unsafe_record := manager.get_annotation(first_id)
	unsafe_record["target_path"] = "../Outside"
	_check(not manager.validate_annotation_record(unsafe_record), "unsafe target paths must be rejected")

	var spatial_marker := Node3D.new()
	spatial_marker.add_to_group("spatial_calibration_preview_marker")
	shared_origin.add_child(spatial_marker)
	manager.clear_annotations()
	_check(manager.get_annotation_count() == 0, "clear_annotations should clear virtual annotations")
	_check(is_instance_valid(spatial_marker) and not spatial_marker.is_queued_for_deletion(), "virtual clear must not touch spatial calibration markers")

	for index in range(MAX_ANNOTATIONS):
		var numbered := draft.duplicate(true)
		numbered["text"] = "标注 %d" % (index + 1)
		_check(manager.create_annotation(numbered) > 0, "annotation %d should fit within the session limit" % (index + 1))
	var overflow := manager.create_annotation(draft)
	_check(overflow == -1, "the 129th annotation must be rejected")

	var snapshot := manager.get_annotations()
	var snapshot_revision := manager.get_state_revision() + 1
	_check(bool(manager.call("_apply_snapshot", snapshot_revision, snapshot)), "a valid revisioned snapshot should apply")
	_check(not bool(manager.call("_apply_snapshot", snapshot_revision - 1, [])), "an older snapshot must not replace newer state")
	var restarted_server_record: Dictionary = (snapshot[0] as Dictionary).duplicate(true)
	manager.call("_reset_client_session_state")
	_check(manager.get_state_revision() == 0 and manager.get_annotation_count() == 0, "a new connection should discard the previous session revision")
	_check(bool(manager.call("_apply_snapshot", 1, [restarted_server_record])), "the first snapshot from a restarted server should be accepted")

	var surface_root := Node3D.new()
	surface_root.name = "SurfaceRoot"
	shared_origin.add_child(surface_root)
	var included_mesh := MeshInstance3D.new()
	included_mesh.name = "EquipmentPanel"
	included_mesh.mesh = BoxMesh.new()
	included_mesh.add_to_group("virtual_annotation_surface_low_poly")
	surface_root.add_child(included_mesh)
	var excluded_mesh := MeshInstance3D.new()
	excluded_mesh.name = "CanvasPreview"
	excluded_mesh.mesh = BoxMesh.new()
	surface_root.add_child(excluded_mesh)

	var builder = BuilderScript.new()
	builder.name = "SurfaceBuilder"
	builder.auto_build = false
	builder.shared_space_origin_path = NodePath("..")
	builder.target_root_path = NodePath("..")
	builder.scan_root_path = NodePath("../SurfaceRoot")
	builder.high_poly_face_threshold = 1
	shared_origin.add_child(builder)
	builder.start_build()
	var frame_budget := 20
	while not builder.is_ready_for_annotations() and frame_budget > 0:
		await process_frame
		frame_budget -= 1
	var report := builder.get_coverage_report()
	_check(builder.is_ready_for_annotations(), "surface builder should finish incrementally")
	_check(str(builder.call("_get_surface_policy", included_mesh)) == "convex", "low-poly policy should select a convex proxy on a rendered server")
	_check(int(report.get("box_proxies", 0)) == 1, "high-poly policy should build one box proxy")
	_check(int(report.get("excluded_nodes", 0)) >= 1, "UI-like mesh names should be excluded")
	_check((included_mesh.get_child(0) as StaticBody3D).collision_layer == ANNOTATION_SURFACE_LAYER, "surface proxy should use physics layer 24")
	var proxy_child_count := included_mesh.get_child_count()
	builder.start_build()
	await process_frame
	_check(included_mesh.get_child_count() == proxy_child_count, "repeated start_build should not duplicate surface proxies")
	builder.rebuild()
	frame_budget = 20
	while not builder.is_ready_for_annotations() and frame_budget > 0:
		await process_frame
		frame_budget -= 1
	_check(builder.is_ready_for_annotations() and included_mesh.get_child_count() == proxy_child_count, "rebuild should replace surface proxies exactly once")

	var interaction = InteractionScript.new()
	var pointer := MockFunctionPointer.new()
	var ui_target := Node3D.new()
	pointer.last_target = ui_target
	interaction.set("_function_pointer", pointer)
	_check(bool(interaction.call("_is_pointer_interaction_active")), "3D UI hover should take priority over annotation placement")
	pointer.last_target = null
	_check(not bool(interaction.call("_is_pointer_interaction_active")), "annotation placement should resume after leaving 3D UI")
	_check(InteractionScript.should_pointer_take_priority(1.0, 2.0), "a nearer 3D UI target should take priority")
	_check(not InteractionScript.should_pointer_take_priority(3.0, 2.0), "a model surface should occlude a farther 3D UI target")
	ui_target.free()
	pointer.free()
	interaction.free()

	var marker := HeadlessMarker.new() as Node3D
	var marker_record := {
		"id": 99,
		"revision": 1,
		"shared_position": Vector3(0.5, 0.0, 0.25),
		"shared_normal": Vector3.UP,
		"target_path": "TargetPanel",
		"target_local_position": Vector3.ZERO,
		"target_local_normal": Vector3.UP,
		"text": "marker contract",
		"creator_peer_id": 1,
		"created_at_ms": 1,
	}
	marker.call("configure", marker_record, shared_origin, false, shared_origin)
	shared_origin.add_child(marker)
	marker.call("_apply_anchor_transform")
	_check(marker.global_position.is_equal_approx(target.global_position + Vector3.UP * 0.01), "marker should follow its target with a 1 cm normal offset")
	_check(MarkerScript.MARKER_COLLISION_LAYER == (1 << 24), "published marker should use selection layer 25")
	target.position.x += 0.5
	marker.call("_apply_anchor_transform")
	_check(marker.global_position.is_equal_approx(target.global_position + Vector3.UP * 0.01), "marker should follow target transforms")
	target.queue_free()
	await process_frame
	await process_frame
	marker.call("_apply_anchor_transform")
	_check(marker.global_position.is_equal_approx(shared_origin.to_global(Vector3(0.5, 0.01, 0.25))), "marker should fall back to shared-space coordinates after target deletion")
	marker.free()

	included_mesh.mesh = null
	excluded_mesh.mesh = null
	shared_origin.queue_free()
	await process_frame
	RuntimeProfile.clear_session_override()

	if _failures.is_empty():
		print("Virtual annotation self test passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
