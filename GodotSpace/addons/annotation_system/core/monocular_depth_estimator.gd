# monocular_depth_estimator.gd
# 单目深度估计模块 - 基于纯视频信息的深度估计
# 注意：这是一个基础版本，使用启发式方法进行深度估计
# 实际使用中可以替换为深度学习模型（如MiDaS、DPT等）
extends Node
class_name MonocularDepthEstimator

## 深度估计完成信号
signal depth_estimated(screen_pos: Vector2, depth: float)
## 深度图更新信号
signal depth_map_updated(depth_texture: ImageTexture)

## 深度估计方法
enum DepthMethod {
	MANUAL,           # 手动设置
	GRADIENT_BASED,   # 基于梯度的估计
	SIZE_BASED,       # 基于物体大小的估计
	PERSPECTIVE_BASED,# 基于透视的估计
	COMBINED          # 组合方法
}

## 当前使用的深度估计方法
@export var estimation_method: DepthMethod = DepthMethod.COMBINED

## 默认深度值（米）
@export var default_depth: float = 5.0
## 最小深度
@export var min_depth: float = 0.5
## 最大深度
@export var max_depth: float = 50.0

## 透视深度参数（基于屏幕Y坐标）
@export var perspective_near_y: float = 0.3  # 近处对应的归一化Y坐标
@export var perspective_far_y: float = 0.8   # 远处对应的归一化Y坐标
@export var perspective_near_depth: float = 2.0
@export var perspective_far_depth: float = 20.0

## 梯度检测参数
@export var gradient_threshold: float = 30.0
@export var edge_depth_multiplier: float = 0.8

# 内部变量
var _current_frame: Image
var _depth_map: Image
var _depth_texture: ImageTexture
var _sobel_x: Array = [[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]]
var _sobel_y: Array = [[-1, -2, -1], [0, 0, 0], [1, 2, 1]]

# 历史帧用于运动检测
var _previous_frame: Image
var _motion_vectors: Dictionary = {}

func _ready():
	_depth_texture = ImageTexture.new()
	print("🔍 单目深度估计模块已初始化 - 方法: %s" % DepthMethod.keys()[estimation_method])

## 设置当前帧
func set_current_frame(frame: Image):
	_previous_frame = _current_frame
	_current_frame = frame.duplicate()
	
	# 可选：生成深度图
	# _generate_depth_map()

## 估计指定屏幕位置的深度
func estimate_depth(screen_pos: Vector2, normalized_pos: Vector2) -> float:
	match estimation_method:
		DepthMethod.MANUAL:
			return default_depth
		DepthMethod.GRADIENT_BASED:
			return _estimate_gradient_based(screen_pos)
		DepthMethod.SIZE_BASED:
			return _estimate_size_based(screen_pos)
		DepthMethod.PERSPECTIVE_BASED:
			return _estimate_perspective_based(normalized_pos)
		DepthMethod.COMBINED:
			return _estimate_combined(screen_pos, normalized_pos)
		_:
			return default_depth

## 基于透视的深度估计
## 假设场景中地平线在画面中部，下方物体更近，上方物体更远
func _estimate_perspective_based(normalized_pos: Vector2) -> float:
	# 使用Y坐标进行线性插值
	# normalized_pos.y: 0 = 顶部, 1 = 底部
	
	# 计算深度
	var t = 0.0
	if normalized_pos.y < perspective_near_y:
		# 画面上部（天空/远处）
		t = 1.0
	elif normalized_pos.y > perspective_far_y:
		# 画面下部（地面/近处）
		t = 0.0
	else:
		# 中间区域 - 线性插值
		t = 1.0 - (normalized_pos.y - perspective_near_y) / (perspective_far_y - perspective_near_y)
	
	var depth = lerp(perspective_near_depth, perspective_far_depth, t)
	return clamp(depth, min_depth, max_depth)

## 基于梯度的深度估计
## 边缘区域通常表示物体边界，可能距离较近
func _estimate_gradient_based(screen_pos: Vector2) -> float:
	if not _current_frame:
		return default_depth
	
	var gradient_magnitude = _calculate_gradient_at(screen_pos)
	
	# 高梯度（边缘）区域可能更近
	if gradient_magnitude > gradient_threshold:
		return default_depth * edge_depth_multiplier
	
	return default_depth

## 计算指定位置的梯度
func _calculate_gradient_at(pos: Vector2) -> float:
	if not _current_frame:
		return 0.0
	
	var x = int(pos.x)
	var y = int(pos.y)
	
	# 边界检查
	if x < 1 or x >= _current_frame.get_width() - 1:
		return 0.0
	if y < 1 or y >= _current_frame.get_height() - 1:
		return 0.0
	
	# 应用Sobel算子
	var gx = 0.0
	var gy = 0.0
	
	for i in range(-1, 2):
		for j in range(-1, 2):
			var pixel = _current_frame.get_pixel(x + j, y + i)
			var gray = pixel.r * 0.299 + pixel.g * 0.587 + pixel.b * 0.114
			gx += gray * _sobel_x[i + 1][j + 1]
			gy += gray * _sobel_y[i + 1][j + 1]
	
	return sqrt(gx * gx + gy * gy) * 255.0

## 基于物体大小的深度估计
## 这是一个简化版本，实际应用中需要物体检测
func _estimate_size_based(screen_pos: Vector2) -> float:
	# 简化实现：假设画面中心的物体是关注焦点
	# 离中心越远，可能是背景
	if not _current_frame:
		return default_depth
	
	var center = Vector2(_current_frame.get_width() / 2.0, _current_frame.get_height() / 2.0)
	var distance_from_center = screen_pos.distance_to(center)
	var max_distance = center.length()
	
	var normalized_distance = distance_from_center / max_distance
	
	# 中心物体假设更近
	var depth = lerp(perspective_near_depth, perspective_far_depth, normalized_distance * 0.5)
	return clamp(depth, min_depth, max_depth)

## 组合多种方法的深度估计
func _estimate_combined(screen_pos: Vector2, normalized_pos: Vector2) -> float:
	var depths: Array[float] = []
	var weights: Array[float] = []
	
	# 透视法（权重较高）
	depths.append(_estimate_perspective_based(normalized_pos))
	weights.append(0.5)
	
	# 梯度法
	depths.append(_estimate_gradient_based(screen_pos))
	weights.append(0.3)
	
	# 大小法
	depths.append(_estimate_size_based(screen_pos))
	weights.append(0.2)
	
	# 加权平均
	var total_depth = 0.0
	var total_weight = 0.0
	
	for i in range(depths.size()):
		total_depth += depths[i] * weights[i]
		total_weight += weights[i]
	
	var result = total_depth / total_weight if total_weight > 0 else default_depth
	
	depth_estimated.emit(screen_pos, result)
	return clamp(result, min_depth, max_depth)

## 生成整帧深度图（可选功能）
func _generate_depth_map():
	if not _current_frame:
		return
	
	var width = _current_frame.get_width()
	var height = _current_frame.get_height()
	
	# 降采样以提高性能
	var scale = 4
	var map_width = width / scale
	var map_height = height / scale
	
	_depth_map = Image.create(map_width, map_height, false, Image.FORMAT_RF)
	
	for y in range(map_height):
		for x in range(map_width):
			var screen_pos = Vector2(x * scale, y * scale)
			var normalized_pos = Vector2(float(x) / map_width, float(y) / map_height)
			var depth = _estimate_combined(screen_pos, normalized_pos)
			
			# 归一化深度值
			var normalized_depth = (depth - min_depth) / (max_depth - min_depth)
			_depth_map.set_pixel(x, y, Color(normalized_depth, 0, 0, 1))
	
	_depth_texture.set_image(_depth_map)
	depth_map_updated.emit(_depth_texture)

## 获取深度图纹理
func get_depth_map_texture() -> ImageTexture:
	return _depth_texture

## 设置深度估计方法
func set_estimation_method(method: DepthMethod):
	estimation_method = method
	print("🔍 深度估计方法已更改为: %s" % DepthMethod.keys()[method])

## 设置透视参数
func set_perspective_params(near_y: float, far_y: float, near_depth: float, far_depth: float):
	perspective_near_y = near_y
	perspective_far_y = far_y
	perspective_near_depth = near_depth
	perspective_far_depth = far_depth

## 批量估计深度
func estimate_depths_batch(positions: Array[Vector2], normalized_positions: Array[Vector2]) -> Array[float]:
	var results: Array[float] = []
	for i in range(positions.size()):
		results.append(estimate_depth(positions[i], normalized_positions[i]))
	return results

## 运动视差深度估计（需要多帧）
func estimate_depth_from_motion(screen_pos: Vector2) -> float:
	if not _current_frame or not _previous_frame:
		return default_depth
	
	# 简化的光流计算
	var motion = _calculate_motion_at(screen_pos)
	
	# 运动较大的物体通常较近（在相机运动的情况下）
	if motion.length() > 5.0:
		return perspective_near_depth
	elif motion.length() < 1.0:
		return perspective_far_depth
	else:
		var t = motion.length() / 5.0
		return lerp(perspective_far_depth, perspective_near_depth, t)

## 计算运动向量（简化版本）
func _calculate_motion_at(pos: Vector2) -> Vector2:
	if not _current_frame or not _previous_frame:
		return Vector2.ZERO
	
	# 简单的块匹配
	var block_size = 8
	var search_range = 16
	var x = int(pos.x)
	var y = int(pos.y)
	
	# 边界检查
	if x < block_size or x >= _current_frame.get_width() - block_size:
		return Vector2.ZERO
	if y < block_size or y >= _current_frame.get_height() - block_size:
		return Vector2.ZERO
	
	# 这里简化为返回零向量
	# 完整实现需要块匹配算法
	return Vector2.ZERO

## 获取估计参数信息
func get_estimation_info() -> Dictionary:
	return {
		"method": DepthMethod.keys()[estimation_method],
		"default_depth": default_depth,
		"min_depth": min_depth,
		"max_depth": max_depth,
		"perspective_near_y": perspective_near_y,
		"perspective_far_y": perspective_far_y,
		"perspective_near_depth": perspective_near_depth,
		"perspective_far_depth": perspective_far_depth
	}
