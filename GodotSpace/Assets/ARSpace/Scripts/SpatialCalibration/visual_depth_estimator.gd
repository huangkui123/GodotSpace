class_name VisualDepthEstimator
extends RefCounted

const RENDER_MODE_STEREO_3D := 2
const RENDER_MODE_INTERLACE := 3
const PATCH_RADIUS := 4
const MIN_DISPARITY_PX := 2
const MAX_DISPARITY_PX := 160
const TEMPORAL_SEARCH_RADIUS_PX := 48
const MIN_TEXTURE_VARIANCE := 0.00035
const MIN_MATCH_CONFIDENCE := 0.08
const MIN_BASELINE_METERS := 0.005
const MAX_BASELINE_METERS := 0.25


static func estimate_initial_depth(
	image: Image,
	image_position: Vector2,
	metadata: Dictionary,
	min_depth_m: float,
	max_depth_m: float,
) -> Dictionary:
	if image == null or image.is_empty():
		return _unavailable("no_image")

	var fx: float = float(metadata.get("camera_intrinsics_fx", 0.0))
	if fx <= 0.000001:
		return _unavailable("missing_fx")

	var baseline_m: float = _estimate_stereo_baseline(metadata)
	if baseline_m <= 0.0:
		return _unavailable("missing_stereo_baseline")

	var render_mode: int = int(metadata.get("render_mode", -1))
	var stereo_match: Dictionary = {}
	if render_mode == RENDER_MODE_STEREO_3D:
		stereo_match = _estimate_side_by_side_disparity(image, image_position, metadata)
	elif render_mode == RENDER_MODE_INTERLACE:
		stereo_match = _estimate_interlaced_disparity(image, image_position, metadata)
	else:
		return _unavailable("requires_stereo_render_mode")

	if not bool(stereo_match.get("available", false)):
		return stereo_match

	var disparity_px: float = float(stereo_match.get("disparity_px", 0.0))
	if disparity_px < float(MIN_DISPARITY_PX):
		return _unavailable("invalid_disparity")

	var depth_m: float = fx * baseline_m / disparity_px
	if depth_m < min_depth_m or depth_m > max_depth_m:
		return _unavailable("estimated_depth_out_of_range")

	return {
		"available": true,
		"depth_m": depth_m,
		"source": "visual_stereo_initial",
		"confidence": float(stereo_match.get("confidence", 0.0)),
		"disparity_px": disparity_px,
		"baseline_m": baseline_m,
		"layout": str(stereo_match.get("layout", "stereo")),
	}


static func find_temporal_match(
	current_image: Image,
	previous_image: Image,
	current_position: Vector2,
) -> Dictionary:
	if current_image == null or previous_image == null:
		return _unavailable("missing_temporal_image")
	if current_image.is_empty() or previous_image.is_empty():
		return _unavailable("missing_temporal_image")
	if current_image.get_width() != previous_image.get_width() or current_image.get_height() != previous_image.get_height():
		return _unavailable("temporal_image_size_mismatch")

	var width: int = current_image.get_width()
	var height: int = current_image.get_height()
	var reference_x: int = int(round(current_position.x))
	var reference_y: int = int(round(current_position.y))
	if reference_x < PATCH_RADIUS or reference_x >= width - PATCH_RADIUS:
		return _unavailable("click_near_image_edge")
	if reference_y < PATCH_RADIUS or reference_y >= height - PATCH_RADIUS:
		return _unavailable("click_near_image_edge")

	var texture_variance: float = _patch_variance(current_image, reference_x, reference_y, PATCH_RADIUS)
	if texture_variance < MIN_TEXTURE_VARIANCE:
		return _unavailable("low_texture")

	var candidates: Array = []
	for target_y in range(
		max(PATCH_RADIUS, reference_y - TEMPORAL_SEARCH_RADIUS_PX),
		min(height - PATCH_RADIUS, reference_y + TEMPORAL_SEARCH_RADIUS_PX) + 1,
	):
		for target_x in range(
			max(PATCH_RADIUS, reference_x - TEMPORAL_SEARCH_RADIUS_PX),
			min(width - PATCH_RADIUS, reference_x + TEMPORAL_SEARCH_RADIUS_PX) + 1,
		):
			var displacement: float = Vector2(target_x - reference_x, target_y - reference_y).length()
			if displacement < 1.0:
				continue
			var score: float = _patch_sad(
				current_image,
				reference_x,
				reference_y,
				previous_image,
				target_x,
				target_y,
				PATCH_RADIUS,
			)
			candidates.append({
				"position": Vector2(float(target_x), float(target_y)),
				"score": score,
				"displacement_px": displacement,
			})

	if candidates.is_empty():
		return _unavailable("no_temporal_match_candidates")

	candidates.sort_custom(func(a, b): return float(a["score"]) < float(b["score"]))
	var best: Dictionary = candidates[0]
	var best_position: Vector2 = best["position"] as Vector2
	var second_score: float = -1.0
	for candidate in candidates:
		if (candidate["position"] as Vector2).distance_to(best_position) >= 3.0:
			second_score = float(candidate["score"])
			break
	if second_score < 0.0 and candidates.size() > 1:
		second_score = float(candidates[1]["score"])
	if second_score <= 0.0:
		return _unavailable("ambiguous_temporal_match")

	var best_score: float = float(best["score"])
	var confidence: float = clamp((second_score - best_score) / max(second_score, 0.000001), 0.0, 1.0)
	if confidence < MIN_MATCH_CONFIDENCE:
		return _unavailable("ambiguous_temporal_match")

	return {
		"available": true,
		"source": "visual_motion_initial",
		"position": best_position,
		"confidence": confidence,
		"displacement_px": float(best["displacement_px"]),
		"texture_variance": texture_variance,
	}


static func _estimate_side_by_side_disparity(image: Image, image_position: Vector2, metadata: Dictionary) -> Dictionary:
	var image_width: int = image.get_width()
	var image_height: int = image.get_height()
	var eye_width: int = int(image_width / 2)
	if eye_width <= PATCH_RADIUS * 2 or image_height <= PATCH_RADIUS * 2:
		return _unavailable("image_too_small")

	var selected_camera_index: int = int(metadata.get("selected_camera_index", 0))
	var reference_origin_x: int = 0
	var target_origin_x: int = eye_width
	var reference_x: int = int(round(image_position.x))
	if selected_camera_index == 1:
		reference_origin_x = eye_width
		target_origin_x = 0
		reference_x = int(round(image_position.x)) - eye_width

	if reference_x < PATCH_RADIUS or reference_x >= eye_width - PATCH_RADIUS:
		return _unavailable("click_outside_selected_eye_image")

	var reference_y: int = int(round(image_position.y))
	if reference_y < PATCH_RADIUS or reference_y >= image_height - PATCH_RADIUS:
		return _unavailable("click_near_image_edge")

	var max_disparity: int = min(MAX_DISPARITY_PX, max(MIN_DISPARITY_PX + 1, int(float(eye_width) * 0.35)))
	return _find_best_horizontal_match(
		image,
		reference_origin_x + reference_x,
		reference_y,
		target_origin_x,
		eye_width,
		reference_x,
		reference_y,
		max_disparity,
		"side_by_side",
	)


static func _estimate_interlaced_disparity(image: Image, image_position: Vector2, metadata: Dictionary) -> Dictionary:
	var image_width: int = image.get_width()
	var image_height: int = image.get_height()
	if image_width <= PATCH_RADIUS * 2 or image_height <= PATCH_RADIUS * 2 + 1:
		return _unavailable("image_too_small")

	var selected_camera_index: int = int(metadata.get("selected_camera_index", 0))
	var reference_parity: int = 0 if selected_camera_index == 0 else 1
	var target_parity: int = 1 - reference_parity
	var reference_x: int = int(round(image_position.x))
	var reference_y: int = int(round(image_position.y))
	if reference_y % 2 != reference_parity:
		if reference_y + 1 < image_height and (reference_y + 1) % 2 == reference_parity:
			reference_y += 1
		else:
			reference_y -= 1
	var target_y: int = reference_y + 1 if target_parity > reference_parity else reference_y - 1

	if reference_x < PATCH_RADIUS or reference_x >= image_width - PATCH_RADIUS:
		return _unavailable("click_near_image_edge")
	if reference_y < PATCH_RADIUS or reference_y >= image_height - PATCH_RADIUS:
		return _unavailable("click_near_image_edge")
	if target_y < PATCH_RADIUS or target_y >= image_height - PATCH_RADIUS:
		return _unavailable("paired_eye_row_unavailable")

	var max_disparity: int = min(MAX_DISPARITY_PX, max(MIN_DISPARITY_PX + 1, int(float(image_width) * 0.25)))
	return _find_best_horizontal_match(
		image,
		reference_x,
		reference_y,
		0,
		image_width,
		reference_x,
		target_y,
		max_disparity,
		"interlace",
	)


static func _find_best_horizontal_match(
	image: Image,
	reference_global_x: int,
	reference_y: int,
	target_origin_x: int,
	target_width: int,
	reference_local_x: int,
	target_y: int,
	max_disparity: int,
	layout: String,
) -> Dictionary:
	var texture_variance: float = _patch_variance(image, reference_global_x, reference_y, PATCH_RADIUS)
	if texture_variance < MIN_TEXTURE_VARIANCE:
		return _unavailable("low_texture")

	var candidates: Array = []
	for target_local_x in range(
		max(PATCH_RADIUS, reference_local_x - max_disparity),
		min(target_width - PATCH_RADIUS, reference_local_x + max_disparity) + 1,
	):
		var disparity: int = abs(reference_local_x - target_local_x)
		if disparity < MIN_DISPARITY_PX:
			continue
		var score: float = _patch_sad(
			image,
			reference_global_x,
			reference_y,
			image,
			target_origin_x + target_local_x,
			target_y,
			PATCH_RADIUS,
		)
		candidates.append({
			"disparity_px": float(disparity),
			"score": score,
		})

	if candidates.is_empty():
		return _unavailable("no_match_candidates")

	candidates.sort_custom(func(a, b): return float(a["score"]) < float(b["score"]))
	var best: Dictionary = candidates[0]
	var second_score: float = -1.0
	for candidate in candidates:
		if abs(float(candidate["disparity_px"]) - float(best["disparity_px"])) >= 3.0:
			second_score = float(candidate["score"])
			break
	if second_score < 0.0 and candidates.size() > 1:
		second_score = float(candidates[1]["score"])
	if second_score <= 0.0:
		return _unavailable("ambiguous_match")

	var best_score: float = float(best["score"])
	var confidence: float = clamp((second_score - best_score) / max(second_score, 0.000001), 0.0, 1.0)
	if confidence < MIN_MATCH_CONFIDENCE:
		return _unavailable("ambiguous_match")

	return {
		"available": true,
		"layout": layout,
		"disparity_px": float(best["disparity_px"]),
		"confidence": confidence,
		"texture_variance": texture_variance,
	}


static func _patch_sad(
	left_image: Image,
	left_x: int,
	left_y: int,
	right_image: Image,
	right_x: int,
	right_y: int,
	radius: int,
) -> float:
	var score: float = 0.0
	var count: int = 0
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var left_luma: float = _luminance(left_image.get_pixel(left_x + dx, left_y + dy))
			var right_luma: float = _luminance(right_image.get_pixel(right_x + dx, right_y + dy))
			score += abs(left_luma - right_luma)
			count += 1
	return score / float(max(1, count))


static func _patch_variance(image: Image, center_x: int, center_y: int, radius: int) -> float:
	var values: Array[float] = []
	var sum: float = 0.0
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var value: float = _luminance(image.get_pixel(center_x + dx, center_y + dy))
			values.append(value)
			sum += value

	if values.is_empty():
		return 0.0
	var mean: float = sum / float(values.size())
	var variance: float = 0.0
	for value in values:
		variance += pow(value - mean, 2.0)
	return variance / float(values.size())


static func _estimate_stereo_baseline(metadata: Dictionary) -> float:
	var primary_matrix: Array = metadata.get("camera_extrinsics_primary", [])
	var secondary_matrix: Array = metadata.get("camera_extrinsics_secondary", [])
	if not (primary_matrix is Array and secondary_matrix is Array):
		return 0.0
	if primary_matrix.size() != 16 or secondary_matrix.size() != 16:
		return 0.0

	var row_major_baseline: float = Vector3(
		float(primary_matrix[3]),
		float(primary_matrix[7]),
		float(primary_matrix[11]),
	).distance_to(Vector3(
		float(secondary_matrix[3]),
		float(secondary_matrix[7]),
		float(secondary_matrix[11]),
	))
	var column_major_baseline: float = Vector3(
		float(primary_matrix[12]),
		float(primary_matrix[13]),
		float(primary_matrix[14]),
	).distance_to(Vector3(
		float(secondary_matrix[12]),
		float(secondary_matrix[13]),
		float(secondary_matrix[14]),
	))

	if _is_plausible_baseline(row_major_baseline):
		return row_major_baseline
	if _is_plausible_baseline(column_major_baseline):
		return column_major_baseline
	return 0.0


static func _is_plausible_baseline(value: float) -> bool:
	return value >= MIN_BASELINE_METERS and value <= MAX_BASELINE_METERS


static func _luminance(color: Color) -> float:
	return color.r * 0.299 + color.g * 0.587 + color.b * 0.114


static func _unavailable(status: String) -> Dictionary:
	return {
		"available": false,
		"source": "manual",
		"status": status,
	}
