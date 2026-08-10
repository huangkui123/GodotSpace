class_name SpatialStrokeSimplifier
extends RefCounted

const MIN_POINT_DISTANCE_SQUARED: float = 0.00000001


static func simplify(
	points: PackedVector3Array,
	tolerance_m: float,
	max_points: int
) -> PackedVector3Array:
	var clean := filter_finite_unique(points)
	if clean.size() <= 2:
		return clean
	var safe_tolerance := maxf(tolerance_m, 0.0)
	var keep := PackedByteArray()
	keep.resize(clean.size())
	keep[0] = 1
	keep[clean.size() - 1] = 1
	var ranges: Array[Vector2i] = [Vector2i(0, clean.size() - 1)]
	var tolerance_squared := safe_tolerance * safe_tolerance
	while not ranges.is_empty():
		var range := ranges.pop_back() as Vector2i
		var start := range.x
		var finish := range.y
		if finish <= start + 1:
			continue
		var farthest_index := -1
		var farthest_distance_squared := -1.0
		for index in range(start + 1, finish):
			var distance_squared := _distance_to_segment_squared(
				clean[index],
				clean[start],
				clean[finish]
			)
			if distance_squared > farthest_distance_squared:
				farthest_distance_squared = distance_squared
				farthest_index = index
		if farthest_index > start and farthest_distance_squared > tolerance_squared:
			keep[farthest_index] = 1
			ranges.append(Vector2i(start, farthest_index))
			ranges.append(Vector2i(farthest_index, finish))

	var simplified := PackedVector3Array()
	for index in range(clean.size()):
		if keep[index] != 0:
			simplified.append(clean[index])
	return _downsample_preserving_endpoints(simplified, max_points)


static func filter_finite_unique(points: PackedVector3Array) -> PackedVector3Array:
	var clean := PackedVector3Array()
	for point in points:
		if not is_finite_vector(point):
			return PackedVector3Array()
		if clean.is_empty() or clean[clean.size() - 1].distance_squared_to(point) >= MIN_POINT_DISTANCE_SQUARED:
			clean.append(point)
	return clean


static func should_sample(
	points: PackedVector3Array,
	candidate: Vector3,
	now_msec: int,
	last_sample_msec: int,
	min_distance_m: float,
	max_interval_msec: int
) -> bool:
	if not is_finite_vector(candidate):
		return false
	if points.is_empty():
		return true
	if points[points.size() - 1].distance_to(candidate) >= maxf(min_distance_m, 0.0):
		return true
	return now_msec - last_sample_msec >= maxi(max_interval_msec, 1)


static func is_finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


static func _distance_to_segment_squared(point: Vector3, start: Vector3, finish: Vector3) -> float:
	var segment := finish - start
	var length_squared := segment.length_squared()
	if length_squared <= MIN_POINT_DISTANCE_SQUARED:
		return point.distance_squared_to(start)
	var weight := clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_squared_to(start + segment * weight)


static func _downsample_preserving_endpoints(
	points: PackedVector3Array,
	max_points: int
) -> PackedVector3Array:
	var limit := maxi(max_points, 2)
	if points.size() <= limit:
		return points
	var result := PackedVector3Array()
	result.resize(limit)
	result[0] = points[0]
	result[limit - 1] = points[points.size() - 1]
	var source_span := float(points.size() - 1)
	var target_span := float(limit - 1)
	for index in range(1, limit - 1):
		result[index] = points[roundi(source_span * float(index) / target_span)]
	return result
