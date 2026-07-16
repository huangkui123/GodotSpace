class_name CollaborationStateSchema
extends RefCounted

const DOMAIN_MENU := "menu"
const DOMAIN_ACTIVE_WINDOWS := "active_windows"
const DOMAIN_TASK := "task"
const DOMAIN_MEDIA := "media"
const DOMAIN_WINDOW_TRANSFORMS := "window_transforms"
const DOMAIN_STROKES := "strokes"
const DOMAIN_MODELS := "models"

const OP_SET := "set"
const OP_UPSERT := "upsert"
const OP_REMOVE := "remove"
const OP_CLEAR := "clear"

const ROLE_PC_GROUND := "pc_ground"
const ROLE_GROUND_VR := "ground_vr"
const ROLE_ASTRONAUT := "astronaut"

const MAX_ID_BYTES: int = 64
const MAX_REQUEST_BYTES: int = 64 * 1024
const MAX_SNAPSHOT_BYTES: int = 2 * 1024 * 1024
const MAX_ACTIVE_WINDOWS: int = 16
const MAX_MEDIA: int = 8
const MAX_WINDOW_TRANSFORMS: int = 16
const MAX_STROKES: int = 128
const MAX_STROKE_POINTS: int = 2048
const MAX_MODELS: int = 64
const MAX_SHARED_DISTANCE: float = 50.0
const MIN_SCALE: float = 0.02
const MAX_SCALE: float = 10.0
const PLACEABLE_MODEL_IDS: Array[String] = [
	"fern",
	"pine_l",
	"red_bush",
	"grass_patch",
	"microscope",
	"pine_m",
]


static func make_default_state() -> Dictionary:
	return {
		DOMAIN_MENU: {
			"mode": "life",
			"active_tab": "home",
			"page_id": "",
		},
		DOMAIN_ACTIVE_WINDOWS: {},
		DOMAIN_TASK: {
			"task_id": 0,
			"step": 0,
			"event_revision": 0,
			"playback": "stopped",
		},
		DOMAIN_MEDIA: {},
		DOMAIN_WINDOW_TRANSFORMS: {},
		DOMAIN_STROKES: {},
		DOMAIN_MODELS: {},
	}


static func make_default_domain_revisions() -> Dictionary:
	var revisions: Dictionary = {}
	for domain in get_domains():
		revisions[domain] = 0
	return revisions


static func get_domains() -> Array[String]:
	return [
		DOMAIN_MENU,
		DOMAIN_ACTIVE_WINDOWS,
		DOMAIN_TASK,
		DOMAIN_MEDIA,
		DOMAIN_WINDOW_TRANSFORMS,
		DOMAIN_STROKES,
		DOMAIN_MODELS,
	]


static func is_known_domain(domain: String) -> bool:
	return domain in get_domains()


static func is_collection_domain(domain: String) -> bool:
	return domain in [
		DOMAIN_ACTIVE_WINDOWS,
		DOMAIN_MEDIA,
		DOMAIN_WINDOW_TRANSFORMS,
		DOMAIN_STROKES,
		DOMAIN_MODELS,
	]


static func is_role_allowed(domain: String, role: String) -> bool:
	if not is_known_domain(domain):
		return false
	if domain in [DOMAIN_STROKES, DOMAIN_MODELS]:
		return role in [ROLE_PC_GROUND, ROLE_GROUND_VR, ROLE_ASTRONAUT]
	return role in [ROLE_PC_GROUND, ROLE_GROUND_VR]


static func is_valid_request_envelope(domain: String, operation: String, payload: Variant) -> bool:
	var envelope: Array = [domain, operation, payload]
	return _is_network_safe_variant(envelope) and _encoded_size(envelope) <= MAX_REQUEST_BYTES


static func is_network_safe_request_content(domain: String, operation: String, payload: Variant) -> bool:
	return _is_network_safe_variant([domain, operation, payload])


static func get_max_records(domain: String) -> int:
	match domain:
		DOMAIN_ACTIVE_WINDOWS:
			return MAX_ACTIVE_WINDOWS
		DOMAIN_MEDIA:
			return MAX_MEDIA
		DOMAIN_WINDOW_TRANSFORMS:
			return MAX_WINDOW_TRANSFORMS
		DOMAIN_STROKES:
			return MAX_STROKES
		DOMAIN_MODELS:
			return MAX_MODELS
		_:
			return 1


static func normalize_change(domain: String, operation: String, payload: Variant) -> Dictionary:
	if not is_known_domain(domain):
		return _failure("unknown_domain")
	if not is_valid_request_envelope(domain, operation, payload):
		return _failure("invalid_or_oversized_payload")
	if not is_collection_domain(domain):
		if operation != OP_SET:
			return _failure("singleton_requires_set")
		return _normalize_record(domain, payload, false)
	if operation == OP_UPSERT:
		return _normalize_record(domain, payload, domain in [DOMAIN_STROKES, DOMAIN_MODELS])
	if operation == OP_REMOVE:
		var entity_id := str(payload).strip_edges() if payload is String else ""
		return _success(entity_id) if _is_safe_id(entity_id) else _failure("invalid_entity_id")
	if operation == OP_CLEAR:
		return _success({})
	return _failure("unsupported_operation")


static func normalize_snapshot(snapshot: Variant) -> Dictionary:
	if not (snapshot is Dictionary) \
			or not _is_network_safe_variant(snapshot) \
			or _encoded_size(snapshot) > MAX_SNAPSHOT_BYTES:
		return _failure("invalid_or_oversized_snapshot")
	var source := snapshot as Dictionary
	var normalized := make_default_state()
	for domain in get_domains():
		if not source.has(domain):
			return _failure("missing_domain_%s" % domain)
		if is_collection_domain(domain):
			var collection_value = source[domain]
			if not (collection_value is Dictionary):
				return _failure("invalid_collection_%s" % domain)
			var collection := collection_value as Dictionary
			if collection.size() > get_max_records(domain):
				return _failure("too_many_records_%s" % domain)
			var replacement: Dictionary = {}
			for key in collection:
				var result := _normalize_record(domain, collection[key], false)
				if not bool(result.get("ok", false)):
					return _failure("invalid_record_%s" % domain)
				var record := result["value"] as Dictionary
				var entity_id := str(record["id"])
				if str(key) != entity_id or replacement.has(entity_id):
					return _failure("mismatched_record_id_%s" % domain)
				replacement[entity_id] = record
			normalized[domain] = replacement
		else:
			var result := _normalize_record(domain, source[domain], false)
			if not bool(result.get("ok", false)):
				return _failure("invalid_record_%s" % domain)
			normalized[domain] = result["value"]
	var active_ids: Dictionary = normalized[DOMAIN_ACTIVE_WINDOWS]
	var transform_ids: Dictionary = normalized[DOMAIN_WINDOW_TRANSFORMS]
	if active_ids.size() != transform_ids.size():
		return _failure("window_domain_id_mismatch")
	for window_id in active_ids:
		if not transform_ids.has(window_id):
			return _failure("window_domain_id_mismatch")
	if _encoded_size(normalized) > MAX_SNAPSHOT_BYTES:
		return _failure("normalized_snapshot_too_large")
	return _success(normalized)


static func normalize_domain_revisions(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return _failure("invalid_domain_revisions")
	var source := value as Dictionary
	var normalized := make_default_domain_revisions()
	for domain in get_domains():
		var revision := int(source.get(domain, -1))
		if revision < 0:
			return _failure("invalid_revision_%s" % domain)
		normalized[domain] = revision
	return _success(normalized)


static func apply_normalized_change(
	state: Dictionary,
	domain: String,
	operation: String,
	payload: Variant
) -> Dictionary:
	var replacement := state.duplicate(true)
	if not is_collection_domain(domain):
		replacement[domain] = payload
		return replacement
	var collection: Dictionary = (replacement.get(domain, {}) as Dictionary).duplicate(true)
	if operation == OP_UPSERT:
		var record := payload as Dictionary
		collection[str(record["id"])] = record
	elif operation == OP_REMOVE:
		collection.erase(str(payload))
	elif operation == OP_CLEAR:
		collection.clear()
	replacement[domain] = collection
	if domain in [DOMAIN_ACTIVE_WINDOWS, DOMAIN_WINDOW_TRANSFORMS]:
		_sync_window_domains(replacement, domain, operation, payload)
	return replacement


static func _sync_window_domains(
	state: Dictionary,
	domain: String,
	operation: String,
	payload: Variant
) -> void:
	var active_windows: Dictionary = (state[DOMAIN_ACTIVE_WINDOWS] as Dictionary).duplicate(true)
	var transforms: Dictionary = (state[DOMAIN_WINDOW_TRANSFORMS] as Dictionary).duplicate(true)
	if operation == OP_UPSERT:
		var entity_id := str((payload as Dictionary)["id"])
		if domain == DOMAIN_ACTIVE_WINDOWS and not transforms.has(entity_id):
			transforms[entity_id] = _default_window_transform(entity_id)
		elif domain == DOMAIN_WINDOW_TRANSFORMS and not active_windows.has(entity_id):
			active_windows[entity_id] = _default_active_window(entity_id)
	elif operation == OP_REMOVE:
		var entity_id := str(payload)
		active_windows.erase(entity_id)
		transforms.erase(entity_id)
	elif operation == OP_CLEAR:
		active_windows.clear()
		transforms.clear()
	state[DOMAIN_ACTIVE_WINDOWS] = active_windows
	state[DOMAIN_WINDOW_TRANSFORMS] = transforms


static func _default_active_window(entity_id: String) -> Dictionary:
	return {
		"id": entity_id,
		"window_type": "generic",
		"visible": true,
		"closed": false,
	}


static func _default_window_transform(entity_id: String) -> Dictionary:
	return {
		"id": entity_id,
		"shared_transform": Transform3D.IDENTITY,
		"size": Vector2(1.0, 0.6),
		"state": "normal",
		"snap_slot": "",
		"focus_order": 0,
	}


static func with_entity_id(record: Dictionary, entity_id: String) -> Dictionary:
	var replacement := record.duplicate(true)
	replacement["id"] = entity_id
	return replacement


static func _normalize_record(domain: String, payload: Variant, allow_missing_id: bool) -> Dictionary:
	match domain:
		DOMAIN_MENU:
			return _normalize_menu(payload)
		DOMAIN_ACTIVE_WINDOWS:
			return _normalize_active_window(payload)
		DOMAIN_TASK:
			return _normalize_task(payload)
		DOMAIN_MEDIA:
			return _normalize_media(payload)
		DOMAIN_WINDOW_TRANSFORMS:
			return _normalize_window_transform(payload)
		DOMAIN_STROKES:
			return _normalize_stroke(payload, allow_missing_id)
		DOMAIN_MODELS:
			return _normalize_model(payload, allow_missing_id)
		_:
			return _failure("unknown_domain")


static func _normalize_menu(payload: Variant) -> Dictionary:
	if not (payload is Dictionary):
		return _failure("menu_not_dictionary")
	var source := payload as Dictionary
	var mode := str(source.get("mode", "")).strip_edges().to_lower()
	var active_tab := str(source.get("active_tab", "")).strip_edges()
	var page_id := str(source.get("page_id", "")).strip_edges()
	if mode not in ["life", "work"] or not _is_safe_id(active_tab):
		return _failure("invalid_menu")
	if page_id != "" and not _is_safe_id(page_id):
		return _failure("invalid_menu_page")
	return _success({"mode": mode, "active_tab": active_tab, "page_id": page_id})


static func _normalize_active_window(payload: Variant) -> Dictionary:
	if not (payload is Dictionary):
		return _failure("active_window_not_dictionary")
	var source := payload as Dictionary
	var entity_id := str(source.get("id", "")).strip_edges()
	var window_type := str(source.get("window_type", "")).strip_edges()
	if not _is_safe_id(entity_id) or not _is_safe_id(window_type):
		return _failure("invalid_active_window_identity")
	if not (source.get("visible", true) is bool) or not (source.get("closed", false) is bool):
		return _failure("invalid_active_window_state")
	return _success({
		"id": entity_id,
		"window_type": window_type,
		"visible": bool(source.get("visible", true)),
		"closed": bool(source.get("closed", false)),
	})


static func _normalize_task(payload: Variant) -> Dictionary:
	if not (payload is Dictionary):
		return _failure("task_not_dictionary")
	var source := payload as Dictionary
	var task_id := int(source.get("task_id", 0))
	var step := int(source.get("step", -1))
	var event_revision := int(source.get("event_revision", -1))
	var playback := str(source.get("playback", "")).strip_edges().to_lower()
	if task_id < 0 or task_id > 5 or step < 0 or step > 20 or event_revision < 0:
		return _failure("invalid_task_range")
	if playback not in ["stopped", "playing", "paused", "completed"]:
		return _failure("invalid_task_playback")
	return _success({"task_id": task_id, "step": step, "event_revision": event_revision, "playback": playback})


static func _normalize_media(payload: Variant) -> Dictionary:
	if not (payload is Dictionary):
		return _failure("media_not_dictionary")
	var source := payload as Dictionary
	var entity_id := str(source.get("id", "")).strip_edges()
	var media_id := str(source.get("media_id", "")).strip_edges()
	var media_type := str(source.get("media_type", "")).strip_edges().to_lower()
	var playback := str(source.get("playback", "")).strip_edges().to_lower()
	var position_ms := int(source.get("position_ms", -1))
	if not _is_safe_id(entity_id) or not _is_safe_id(media_id):
		return _failure("invalid_media_identity")
	if media_type not in ["image", "video"] or playback not in ["stopped", "playing", "paused"]:
		return _failure("invalid_media_state")
	if position_ms < 0 or position_ms > 86400000:
		return _failure("invalid_media_position")
	return _success({"id": entity_id, "media_id": media_id, "media_type": media_type, "playback": playback, "position_ms": position_ms})


static func _normalize_window_transform(payload: Variant) -> Dictionary:
	if not (payload is Dictionary):
		return _failure("window_transform_not_dictionary")
	var source := payload as Dictionary
	var entity_id := str(source.get("id", "")).strip_edges()
	var transform = source.get("shared_transform", null)
	var size = source.get("size", null)
	var state := str(source.get("state", "normal")).strip_edges().to_lower()
	var snap_slot := str(source.get("snap_slot", "")).strip_edges()
	var focus_order := int(source.get("focus_order", -1))
	if not _is_safe_id(entity_id) or not _is_valid_transform(transform):
		return _failure("invalid_window_transform")
	if not _is_valid_vector2_range(size, 0.1, 10.0):
		return _failure("invalid_window_size")
	if state not in ["normal", "maximized", "snapped", "closed"]:
		return _failure("invalid_window_state")
	if snap_slot != "" and not _is_safe_id(snap_slot):
		return _failure("invalid_snap_slot")
	if focus_order < 0 or focus_order > 4096:
		return _failure("invalid_focus_order")
	return _success({"id": entity_id, "shared_transform": transform, "size": size, "state": state, "snap_slot": snap_slot, "focus_order": focus_order})


static func _normalize_stroke(payload: Variant, allow_missing_id: bool) -> Dictionary:
	if not (payload is Dictionary):
		return _failure("stroke_not_dictionary")
	var source := payload as Dictionary
	var entity_id := str(source.get("id", "")).strip_edges()
	var points_value = source.get("shared_points", null)
	var points = PackedVector3Array(points_value) if points_value is Array else points_value
	var color = source.get("color", null)
	var width := float(source.get("width", 0.0))
	if (entity_id == "" and not allow_missing_id) or (entity_id != "" and not _is_safe_id(entity_id)):
		return _failure("invalid_stroke_id")
	if not (points is PackedVector3Array) or points.size() < 2 or points.size() > MAX_STROKE_POINTS:
		return _failure("invalid_stroke_points")
	for point in points:
		if not _is_valid_shared_point(point):
			return _failure("invalid_stroke_point")
	if not _is_valid_color(color) or not is_finite(width) or width < 0.001 or width > 0.2:
		return _failure("invalid_stroke_style")
	if not (source.get("confirmed", true) is bool):
		return _failure("invalid_stroke_confirmation")
	return _success({"id": entity_id, "shared_points": points, "color": color, "width": width, "confirmed": bool(source.get("confirmed", true))})


static func _normalize_model(payload: Variant, allow_missing_id: bool) -> Dictionary:
	if not (payload is Dictionary):
		return _failure("model_not_dictionary")
	var source := payload as Dictionary
	var entity_id := str(source.get("id", "")).strip_edges()
	var model_id := str(source.get("model_id", "")).strip_edges()
	var transform = source.get("shared_transform", null)
	if (entity_id == "" and not allow_missing_id) or (entity_id != "" and not _is_safe_id(entity_id)):
		return _failure("invalid_model_instance_id")
	if model_id not in PLACEABLE_MODEL_IDS or not _is_valid_transform(transform):
		return _failure("invalid_model")
	return _success({"id": entity_id, "model_id": model_id, "shared_transform": transform})


static func _is_valid_transform(value: Variant) -> bool:
	if not (value is Transform3D):
		return false
	var transform := value as Transform3D
	if not _is_valid_shared_point(transform.origin):
		return false
	var axes: Array[Vector3] = [transform.basis.x, transform.basis.y, transform.basis.z]
	for axis in axes:
		if not _is_finite_vector3(axis) or axis.length() < MIN_SCALE or axis.length() > MAX_SCALE:
			return false
	var x := axes[0].normalized()
	var y := axes[1].normalized()
	var z := axes[2].normalized()
	if absf(x.dot(y)) > 0.02 or absf(x.dot(z)) > 0.02 or absf(y.dot(z)) > 0.02:
		return false
	return transform.basis.determinant() > 0.000001


static func _is_valid_shared_point(value: Variant) -> bool:
	return value is Vector3 and _is_finite_vector3(value as Vector3) and (value as Vector3).length() <= MAX_SHARED_DISTANCE


static func _is_finite_vector3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


static func _is_valid_vector2_range(value: Variant, minimum: float, maximum: float) -> bool:
	if not (value is Vector2):
		return false
	var vector := value as Vector2
	return is_finite(vector.x) and is_finite(vector.y) and vector.x >= minimum and vector.x <= maximum and vector.y >= minimum and vector.y <= maximum


static func _is_valid_color(value: Variant) -> bool:
	if not (value is Color):
		return false
	var color := value as Color
	for component in [color.r, color.g, color.b, color.a]:
		if not is_finite(component) or component < 0.0 or component > 1.0:
			return false
	return true


static func _is_safe_id(value: String) -> bool:
	if value.is_empty() or value != value.strip_edges() or value.to_utf8_buffer().size() > MAX_ID_BYTES:
		return false
	if value.contains("/") or value.contains("\\") or value.contains("..") or value.contains(":"):
		return false
	for character in value:
		if character.unicode_at(0) < 32:
			return false
	return true


static func _is_network_safe_variant(value: Variant, depth: int = 0) -> bool:
	if depth > 12:
		return false
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_VECTOR2, TYPE_VECTOR3, TYPE_COLOR, TYPE_TRANSFORM3D, TYPE_PACKED_VECTOR3_ARRAY:
			return true
		TYPE_ARRAY:
			for item in value as Array:
				if not _is_network_safe_variant(item, depth + 1):
					return false
			return true
		TYPE_DICTIONARY:
			for key in value as Dictionary:
				if not (key is String) or not _is_network_safe_variant((value as Dictionary)[key], depth + 1):
					return false
			return true
		_:
			return false


static func _encoded_size(value: Variant) -> int:
	return var_to_bytes(value).size()


static func _success(value: Variant) -> Dictionary:
	return {"ok": true, "value": value, "error": ""}


static func _failure(error: String) -> Dictionary:
	return {"ok": false, "value": null, "error": error}
