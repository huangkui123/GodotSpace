class_name SpatialWindowState
extends RefCounted

const SharedSpaceContract = preload("res://Assets/ARSpace/Scripts/SpatialCalibration/shared_space_contract.gd")

const CONTRACT_VERSION: int = 1
const MAX_WINDOWS: int = 16
const MAX_ID_BYTES: int = 64
const MAX_CONTENT_KEY_BYTES: int = 256
const MAX_SNAPSHOT_BYTES: int = 512 * 1024
const MAX_SHARED_DISTANCE_M: float = SharedSpaceContract.MAX_SHARED_DISTANCE_METERS
const MIN_WINDOW_SIZE_M: float = 0.2
const MAX_WINDOW_SIZE_M: float = 3.0
const MAX_FOCUS_ORDER: int = 2147483647
const MAX_REVISION: int = 2147483647

const MODE_NORMAL := "normal"
const MODE_MAXIMIZED := "maximized"
const MODE_SNAPPED := "snapped"
const MODE_CLOSED := "closed"
const VALID_MODES: Array[String] = [
	MODE_NORMAL,
	MODE_MAXIMIZED,
	MODE_SNAPPED,
	MODE_CLOSED,
]

const POLICY_UNIQUE := "unique"
const POLICY_MULTIPLE := "multiple"
const VALID_INSTANCE_POLICIES: Array[String] = [
	POLICY_UNIQUE,
	POLICY_MULTIPLE,
]

const ROLE_PC_GROUND := "pc_ground"
const ROLE_GROUND_VR := "ground_vr"
const ROLE_ASTRONAUT := "astronaut"


static func normalize_descriptor(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return _failure("descriptor_not_dictionary")
	var source := value as Dictionary
	var window_id := str(source.get("window_id", "")).strip_edges()
	var window_type := str(source.get("window_type", "")).strip_edges().to_lower()
	var policy := str(source.get("instance_policy", POLICY_UNIQUE)).strip_edges().to_lower()
	var content_key := str(source.get("content_key", "")).strip_edges()
	var transform_value = source.get("shared_transform", Transform3D.IDENTITY)
	var size_value = source.get("size_m", Vector2(1.0, 0.6))
	if window_id != "" and not is_safe_identifier(window_id):
		return _failure("invalid_window_id")
	if not is_safe_identifier(window_type):
		return _failure("invalid_window_type")
	if policy not in VALID_INSTANCE_POLICIES:
		return _failure("invalid_instance_policy")
	if content_key.to_utf8_buffer().size() > MAX_CONTENT_KEY_BYTES or _has_control_characters(content_key):
		return _failure("invalid_content_key")
	if not is_valid_shared_transform(transform_value):
		return _failure("invalid_shared_transform")
	if not is_valid_size(size_value):
		return _failure("invalid_window_size")
	return _success({
		"window_id": window_id,
		"window_type": window_type,
		"instance_policy": policy,
		"content_key": content_key,
		"shared_transform": transform_value,
		"size_m": size_value,
	})


static func make_record(
	descriptor: Dictionary,
	window_id: String,
	owner_peer_id: int,
	revision: int,
	focus_order: int
) -> Dictionary:
	return {
		"window_id": window_id,
		"window_type": str(descriptor.get("window_type", "")),
		"instance_policy": str(descriptor.get("instance_policy", POLICY_UNIQUE)),
		"content_key": str(descriptor.get("content_key", "")),
		"shared_transform": descriptor.get("shared_transform", Transform3D.IDENTITY),
		"size_m": descriptor.get("size_m", Vector2(1.0, 0.6)),
		"mode": MODE_NORMAL,
		"visible": true,
		"focus_order": focus_order,
		"snap_slot": "",
		"owner_peer_id": owner_peer_id,
		"lease_peer_id": 0,
		"lease_token": "",
		"lease_expires_msec": 0,
		"revision": revision,
	}


static func normalize_record(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return _failure("record_not_dictionary")
	var source := value as Dictionary
	var window_id_value = source.get("window_id", null)
	var window_type_value = source.get("window_type", null)
	var policy_value = source.get("instance_policy", null)
	var content_key_value = source.get("content_key", null)
	var transform_value = source.get("shared_transform", null)
	var size_value = source.get("size_m", null)
	var mode_value = source.get("mode", null)
	var visible_value = source.get("visible", null)
	var focus_value = source.get("focus_order", null)
	var snap_value = source.get("snap_slot", null)
	var owner_value = source.get("owner_peer_id", null)
	var lease_peer_value = source.get("lease_peer_id", null)
	var lease_token_value = source.get("lease_token", null)
	var lease_expiry_value = source.get("lease_expires_msec", null)
	var revision_value = source.get("revision", null)
	if not (window_id_value is String) or not is_safe_identifier(str(window_id_value)):
		return _failure("invalid_window_id")
	if not (window_type_value is String) or not is_safe_identifier(str(window_type_value)):
		return _failure("invalid_window_type")
	if not (policy_value is String) or str(policy_value) not in VALID_INSTANCE_POLICIES:
		return _failure("invalid_instance_policy")
	if not (content_key_value is String) \
			or str(content_key_value).to_utf8_buffer().size() > MAX_CONTENT_KEY_BYTES \
			or _has_control_characters(str(content_key_value)):
		return _failure("invalid_content_key")
	if not is_valid_shared_transform(transform_value):
		return _failure("invalid_shared_transform")
	if not is_valid_size(size_value):
		return _failure("invalid_window_size")
	if not (mode_value is String) or str(mode_value) not in VALID_MODES:
		return _failure("invalid_window_mode")
	if not (visible_value is bool):
		return _failure("invalid_visibility")
	if str(mode_value) == MODE_CLOSED and bool(visible_value):
		return _failure("closed_window_must_be_hidden")
	if not (focus_value is int) or int(focus_value) < 0 or int(focus_value) > MAX_FOCUS_ORDER:
		return _failure("invalid_focus_order")
	if not (snap_value is String) or (str(snap_value) != "" and not is_safe_identifier(str(snap_value))):
		return _failure("invalid_snap_slot")
	if str(mode_value) == MODE_SNAPPED and str(snap_value).is_empty():
		return _failure("snapped_window_requires_slot")
	if str(mode_value) != MODE_SNAPPED and not str(snap_value).is_empty():
		return _failure("snap_slot_requires_snapped_mode")
	if not (owner_value is int) or int(owner_value) < 1:
		return _failure("invalid_owner")
	if not (lease_peer_value is int) or int(lease_peer_value) < 0:
		return _failure("invalid_lease_peer")
	if not (lease_token_value is String) or not (lease_expiry_value is int):
		return _failure("invalid_lease")
	if int(lease_peer_value) == 0:
		if str(lease_token_value) != "" or int(lease_expiry_value) != 0:
			return _failure("empty_lease_has_data")
	elif not is_safe_identifier(str(lease_token_value)) or int(lease_expiry_value) <= 0:
		return _failure("active_lease_missing_data")
	if not (revision_value is int) or int(revision_value) < 1 or int(revision_value) > MAX_REVISION:
		return _failure("invalid_record_revision")
	return _success({
		"window_id": str(window_id_value),
		"window_type": str(window_type_value),
		"instance_policy": str(policy_value),
		"content_key": str(content_key_value),
		"shared_transform": transform_value,
		"size_m": size_value,
		"mode": str(mode_value),
		"visible": bool(visible_value),
		"focus_order": int(focus_value),
		"snap_slot": str(snap_value),
		"owner_peer_id": int(owner_value),
		"lease_peer_id": int(lease_peer_value),
		"lease_token": str(lease_token_value),
		"lease_expires_msec": int(lease_expiry_value),
		"revision": int(revision_value),
	})


static func normalize_snapshot(value: Variant) -> Dictionary:
	if not (value is Dictionary) or var_to_bytes(value).size() > MAX_SNAPSHOT_BYTES:
		return _failure("invalid_or_oversized_snapshot")
	var source := value as Dictionary
	if source.size() > MAX_WINDOWS:
		return _failure("window_limit_reached")
	var replacement: Dictionary = {}
	for key in source:
		if not (key is String):
			return _failure("non_string_window_key")
		var result := normalize_record(source[key])
		if not bool(result.get("ok", false)):
			return _failure("invalid_window_record")
		var record := result["value"] as Dictionary
		var window_id := str(record["window_id"])
		if str(key) != window_id or replacement.has(window_id):
			return _failure("window_id_mismatch")
		replacement[window_id] = record
	if var_to_bytes(replacement).size() > MAX_SNAPSHOT_BYTES:
		return _failure("normalized_snapshot_too_large")
	return _success(replacement)


static func make_stable_window_id(
	window_type: String,
	content_key: String,
	instance_policy: String,
	instance_sequence: int = 0
) -> String:
	var suffix := ""
	if not content_key.is_empty():
		suffix += "_" + content_key.sha256_text().substr(0, 8)
	if instance_policy == POLICY_MULTIPLE:
		suffix += "_%d" % maxi(instance_sequence, 1)
	# Preserve the content hash and authoritative multiple-instance sequence.
	# Truncating only after concatenation can erase the sequence and make the
	# Registry's collision-search loop repeat the same ID forever.
	var base_bytes := maxi(MAX_ID_BYTES - suffix.length(), 1)
	return window_type.left(base_bytes) + suffix


static func is_ground_role(role: String) -> bool:
	return role in [ROLE_PC_GROUND, ROLE_GROUND_VR]


static func is_selectable_role(role: String) -> bool:
	return role in [ROLE_PC_GROUND, ROLE_GROUND_VR, ROLE_ASTRONAUT]


static func is_safe_identifier(value: String) -> bool:
	if value.is_empty() or value != value.strip_edges() or value.to_utf8_buffer().size() > MAX_ID_BYTES:
		return false
	for character in value:
		var code := character.unicode_at(0)
		if not ((code >= 48 and code <= 57) \
				or (code >= 65 and code <= 90) \
				or (code >= 97 and code <= 122) \
				or character in ["_", "-"]):
			return false
	return true


static func is_valid_shared_transform(value: Variant) -> bool:
	if not (value is Transform3D):
		return false
	var transform := value as Transform3D
	if not SharedSpaceContract.is_valid_shared_transform(transform):
		return false
	var axes: Array[Vector3] = [transform.basis.x, transform.basis.y, transform.basis.z]
	for axis in axes:
		if not _is_finite_vector3(axis) or not is_equal_approx(axis.length(), 1.0):
			return false
	var x := axes[0].normalized()
	var y := axes[1].normalized()
	var z := axes[2].normalized()
	if absf(x.dot(y)) > 0.001 or absf(x.dot(z)) > 0.001 or absf(y.dot(z)) > 0.001:
		return false
	return transform.basis.determinant() > 0.999 and transform.basis.determinant() < 1.001


static func is_valid_size(value: Variant) -> bool:
	if not (value is Vector2):
		return false
	var size := value as Vector2
	return is_finite(size.x) and is_finite(size.y) \
		and size.x >= MIN_WINDOW_SIZE_M and size.x <= MAX_WINDOW_SIZE_M \
		and size.y >= MIN_WINDOW_SIZE_M and size.y <= MAX_WINDOW_SIZE_M


static func _is_finite_vector3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


static func _has_control_characters(value: String) -> bool:
	for character in value:
		if character.unicode_at(0) < 32:
			return true
	return false


static func _success(value: Variant) -> Dictionary:
	return {"ok": true, "value": value, "error": ""}


static func _failure(error: String) -> Dictionary:
	return {"ok": false, "value": null, "error": error}
