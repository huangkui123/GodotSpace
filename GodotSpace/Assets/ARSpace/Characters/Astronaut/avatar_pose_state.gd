class_name AvatarPoseState
extends RefCounted

const TRACKING_HEAD: int = 1
const TRACKING_LEFT_HAND: int = 2
const TRACKING_RIGHT_HAND: int = 4
const TRACKING_ALL: int = TRACKING_HEAD | TRACKING_LEFT_HAND | TRACKING_RIGHT_HAND

const INPUT_MODE_HEAD_GAZE: int = 0
const INPUT_MODE_LEFT_HAND: int = 1
const INPUT_MODE_RIGHT_HAND: int = 2

const GESTURE_LEFT_PRIMARY: int = 1
const GESTURE_RIGHT_PRIMARY: int = 2
const GESTURE_LEFT_TRIGGER_CLICK: int = 4
const GESTURE_RIGHT_TRIGGER_CLICK: int = 8
const GESTURE_LEFT_GRIP_CLICK: int = 16
const GESTURE_RIGHT_GRIP_CLICK: int = 32
const GESTURE_MASK: int = 63

const MAX_SERIALIZED_BYTES: int = 256

static func make_default() -> Dictionary:
	return {
		"tracking_mask": TRACKING_ALL,
		"input_mode": INPUT_MODE_RIGHT_HAND,
		"left_trigger_q": 0,
		"left_grip_q": 0,
		"right_trigger_q": 0,
		"right_grip_q": 0,
		"gesture_bits": 0,
	}

static func normalize(value: Variant, allow_legacy_empty: bool = true) -> Dictionary:
	if value == null or (value is Dictionary and value.is_empty()):
		return make_default() if allow_legacy_empty else {}
	if not (value is Dictionary):
		return {}
	var source := value as Dictionary
	if source.size() != make_default().size():
		return {}
	for key in make_default().keys():
		if not source.has(key) or not _is_integer(source[key]):
			return {}

	var tracking_mask := int(source["tracking_mask"])
	var input_mode := int(source["input_mode"])
	var gesture_bits := int(source["gesture_bits"])
	if tracking_mask < 0 or tracking_mask > TRACKING_ALL:
		return {}
	if input_mode < INPUT_MODE_HEAD_GAZE or input_mode > INPUT_MODE_RIGHT_HAND:
		return {}
	if gesture_bits < 0 or gesture_bits > GESTURE_MASK:
		return {}

	var normalized := {
		"tracking_mask": tracking_mask,
		"input_mode": input_mode,
		"gesture_bits": gesture_bits,
	}
	for key in ["left_trigger_q", "left_grip_q", "right_trigger_q", "right_grip_q"]:
		var quantized := int(source[key])
		if quantized < 0 or quantized > 255:
			return {}
		normalized[key] = quantized
	if var_to_bytes(normalized).size() > MAX_SERIALIZED_BYTES:
		return {}
	return normalized

static func from_actions(
	tracking_mask: int,
	input_mode: int,
	left_trigger: float,
	left_grip: float,
	right_trigger: float,
	right_grip: float,
	gesture_bits: int
) -> Dictionary:
	return {
		"tracking_mask": clampi(tracking_mask, 0, TRACKING_ALL),
		"input_mode": clampi(input_mode, INPUT_MODE_HEAD_GAZE, INPUT_MODE_RIGHT_HAND),
		"left_trigger_q": quantize_axis(left_trigger),
		"left_grip_q": quantize_axis(left_grip),
		"right_trigger_q": quantize_axis(right_trigger),
		"right_grip_q": quantize_axis(right_grip),
		"gesture_bits": gesture_bits & GESTURE_MASK,
	}

static func quantize_axis(value: float) -> int:
	if not is_finite(value):
		return 0
	return clampi(roundi(clampf(value, 0.0, 1.0) * 255.0), 0, 255)

static func dequantize_axis(value: Variant) -> float:
	return clampf(float(int(value)) / 255.0, 0.0, 1.0)

static func has_tracking(state: Dictionary, tracking_bit: int) -> bool:
	return (int(state.get("tracking_mask", 0)) & tracking_bit) != 0

static func _is_integer(value: Variant) -> bool:
	return value is int
