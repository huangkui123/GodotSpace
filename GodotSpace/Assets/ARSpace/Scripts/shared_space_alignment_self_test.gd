extends SceneTree

const Alignment = preload("res://Assets/ARSpace/Scripts/shared_space_alignment.gd")

var failures: PackedStringArray = []


func _initialize() -> void:
	_expect(Alignment.HEAD_TRACKER_PATH == &"head", "Godot 4.4 head tracker name should be 'head'")
	_test_identity_alignment()
	_test_horizontal_position_and_yaw_alignment()
	if failures.is_empty():
		print("Shared-space alignment self-test passed")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_identity_alignment() -> void:
	var tracked_head := Transform3D(Basis.IDENTITY, Vector3(0.25, 1.65, -0.4))
	var anchor := Transform3D(Basis.IDENTITY, Vector3(3.0, 0.2, 7.0))
	var origin: Transform3D = Alignment.compute_origin_transform(tracked_head, anchor)
	var aligned_head := origin * tracked_head
	_expect(_near(aligned_head.origin.x, anchor.origin.x), "identity alignment should match anchor X")
	_expect(_near(aligned_head.origin.z, anchor.origin.z), "identity alignment should match anchor Z")
	_expect(_near(origin.origin.y, anchor.origin.y), "XR origin height should match anchor floor height")


func _test_horizontal_position_and_yaw_alignment() -> void:
	var tracked_yaw := deg_to_rad(32.0)
	var anchor_yaw := deg_to_rad(-75.0)
	var tracked_head := Transform3D(
		Basis(Vector3.UP, tracked_yaw),
		Vector3(-0.32, 1.72, 0.18)
	)
	var anchor := Transform3D(
		Basis(Vector3.UP, anchor_yaw),
		Vector3(-4.0, 0.0, 11.5)
	)
	var origin: Transform3D = Alignment.compute_origin_transform(tracked_head, anchor)
	var aligned_head := origin * tracked_head
	_expect(_near(aligned_head.origin.x, anchor.origin.x), "rotated alignment should match anchor X")
	_expect(_near(aligned_head.origin.z, anchor.origin.z), "rotated alignment should match anchor Z")
	var aligned_forward := -aligned_head.basis.z.normalized()
	var anchor_forward := -anchor.basis.z.normalized()
	_expect(aligned_forward.dot(anchor_forward) > 0.9999, "aligned head yaw should match anchor yaw")


func _near(a: float, b: float) -> bool:
	return absf(a - b) < 0.0001


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
