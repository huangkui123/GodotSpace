# addons/orbital_plugin/a_pqw_gizmo_plugin.gd
@tool
extends EditorNode3DGizmoPlugin
class_name PQWGizmoPlugin

const AXIS_LENGTH: float = 25.0

func _init() -> void:
	# Materiales normales (con profundidad desactivada para que se vean siempre)
	create_material("p_axis", Color(1.0, 0.3, 0.3))
	create_material("q_axis", Color(0.3, 1.0, 0.3))
	create_material("w_axis", Color(0.4, 0.6, 1.0))
	
	# Hacemos que se vean siempre por encima de todo
	var p_mat = get_material("p_axis")
	p_mat.no_depth_test = true
	var q_mat = get_material("q_axis")
	q_mat.no_depth_test = true
	var w_mat = get_material("w_axis")
	w_mat.no_depth_test = true

func _has_gizmo(for_node_3d: Node3D) -> bool:
	return for_node_3d is OrbitalObject3D

func _get_gizmo_name() -> String:
	return "PQW Orbital Frame"

func _create_gizmo(for_node_3d: Node3D) -> EditorNode3DGizmo:
	if for_node_3d is OrbitalObject3D:
		var gizmo = PQWGizmo.new()
		gizmo.node = for_node_3d as OrbitalObject3D
		gizmo.plugin = self
		return gizmo
	return null


class PQWGizmo extends EditorNode3DGizmo:
	var node: OrbitalObject3D
	var plugin: EditorNode3DGizmoPlugin

	func _redraw() -> void:
		clear()
		if not node: return

		var len = AXIS_LENGTH

		# Líneas gordas y siempre visibles
		add_lines([Vector3.ZERO, node.basis.x * len], plugin.get_material("p_axis", self), false)
		add_lines([Vector3.ZERO, node.basis.y * len], plugin.get_material("q_axis", self), false)
		add_lines([Vector3.ZERO, node.basis.z * len], plugin.get_material("w_axis", self), false)
		
		# Flechitas simples y efectivas (sin errores)
		_add_arrow(node.basis.x * len, node.basis.x, Color(1.0, 0.3, 0.3))
		_add_arrow(node.basis.y * len, node.basis.y, Color(0.3, 1.0, 0.3))
		_add_arrow(node.basis.z * len, node.basis.z, Color(0.4, 0.6, 1.0))

		add_collision_segments([
			Vector3.ZERO, node.basis.x * len,
			Vector3.ZERO, node.basis.y * len,
			Vector3.ZERO, node.basis.z * len
		])

	func _add_arrow(pos: Vector3, dir: Vector3, color: Color):
		var size = AXIS_LENGTH * 0.12
		var n = dir.normalized()
		var perp = Vector3(-n.y, n.x, 0)  # siempre perpendicular
		if perp.length() < 0.1:
			perp = Vector3(0, -n.z, n.y)
		perp = perp.normalized() * size

		var tip = pos - n * size
		add_lines([pos, tip + perp], plugin.get_material("p_axis" if color.r > 0.5 else "q_axis" if color.g > 0.5 else "w_axis", self), false)
		add_lines([pos, tip - perp], plugin.get_material("p_axis" if color.r > 0.5 else "q_axis" if color.g > 0.5 else "w_axis", self), false)
		
