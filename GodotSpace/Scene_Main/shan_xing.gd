extends Node3D

@export var origin: Node3D
@export var target: Node3D
@export var spread_angle: float = 8.0
@export var fill_color: Color = Color(1.0, 0.8, 0.0, 0.15)
@export var edge_color: Color = Color(1.0, 0.8, 0.0, 1.0)
@export var segments: int = 20

var _fill_instance: MeshInstance3D
var _edge_instance: MeshInstance3D

func _ready() -> void:
	# 填充面
	_fill_instance = MeshInstance3D.new()
	add_child(_fill_instance)
	var fill_mat = StandardMaterial3D.new()
	fill_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fill_mat.albedo_color = fill_color
	fill_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_fill_instance.material_override = fill_mat

	# 边线
	_edge_instance = MeshInstance3D.new()
	add_child(_edge_instance)
	var edge_mat = StandardMaterial3D.new()
	edge_mat.albedo_color = edge_color
	edge_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_edge_instance.material_override = edge_mat

func _process(_delta: float) -> void:
	if not origin or not target:
		return
	_update()

func _update() -> void:
	var from = origin.global_position
	var to = target.global_position
	print("from:", from, " to:", to, " dist:", from.distance_to(to))
	var dir = (to - from).normalized()
	var dist = from.distance_to(to)

	var up = Vector3.UP
	if abs(dir.dot(up)) > 0.99:
		up = Vector3.RIGHT
	var side = dir.cross(up).normalized()

	var half_rad = deg_to_rad(spread_angle / 2.0)

	# 计算两条边线的端点
	var left_dir = dir.rotated(side, -half_rad)
	var right_dir = dir.rotated(side, half_rad)
	var left_end = from + left_dir * dist
	var right_end = from + right_dir * dist

	# ---- 填充面 ----
	var fill_st = SurfaceTool.new()
	fill_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var prev_point = Vector3.ZERO
	for i in range(segments + 1):
		var t = float(i) / float(segments)
		var angle = lerp(-half_rad, half_rad, t)
		var rotated_dir = dir.rotated(side, angle)
		var point = from + rotated_dir * dist
		if i > 0:
			fill_st.add_vertex(from)
			fill_st.add_vertex(prev_point)
			fill_st.add_vertex(point)
		prev_point = point
	_fill_instance.mesh = fill_st.commit()

	# ---- 两条边线 ----
	var edge_st = SurfaceTool.new()
	edge_st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var edge_width = dist * 0.008  # 线宽，按距离比例

	# 左边线（from -> left_end 的细长矩形）
	_add_edge_quad(edge_st, from, left_end, side, edge_width)
	# 右边线（from -> right_end 的细长矩形）
	_add_edge_quad(edge_st, from, right_end, side, edge_width)

	_edge_instance.mesh = edge_st.commit()

func _add_edge_quad(st: SurfaceTool, a: Vector3, b: Vector3, side: Vector3, width: float) -> void:
	var half_w = width / 2.0
	var v0 = a - side * half_w
	var v1 = a + side * half_w
	var v2 = b + side * half_w
	var v3 = b - side * half_w
	st.add_vertex(v0)
	st.add_vertex(v1)
	st.add_vertex(v2)
	st.add_vertex(v0)
	st.add_vertex(v2)
	st.add_vertex(v3)
