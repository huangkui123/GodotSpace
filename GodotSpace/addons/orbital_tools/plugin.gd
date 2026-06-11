@tool
extends EditorPlugin

const OrbitalManager = preload("res://addons/orbital_tools/orbital_manager.gd")
const PQWGizmoPlugin = preload("res://addons/orbital_tools/gizmos/pqw_gizmo_plugin.gd")

var gizmo_plugin = PQWGizmoPlugin.new()

func _enter_tree():
	# Registrar el script como tipo personalizado con su icono
	add_custom_type(
		"OrbitalObject3D", 
		"Area3D", 
		preload("res://addons/orbital_tools/orbital_object_3d.gd"),
		preload("res://addons/orbital_tools/icons/orbital2.svg")
	)
	
	add_custom_type(
		"OrbitRender3D", 
		"MeshInstance3D", 
		preload("res://addons/orbital_tools/orbit_render_3d.gd"),
		preload("res://addons/orbital_tools/icons/orbit_render_3d.svg")
	)
	
	# Añadir el gizmo para los ejes PQW
	add_node_3d_gizmo_plugin(gizmo_plugin)
	
	# Autoload del manager (nombre que aparecerá en Project → Project Settings → Autoload)
	add_autoload_singleton("OrbitalManager", "res://addons/orbital_tools/orbital_manager.gd")

func _exit_tree():
	# Limpiar todo al desactivar el addon
	remove_custom_type("OrbitalObject3D")
	remove_custom_type("OrbitRender3D")
	remove_node_3d_gizmo_plugin(gizmo_plugin)
	remove_autoload_singleton("OrbitalManager")
