# OrbitRender.gd → Hijo del atractor, hermano del orbiter
@tool
extends MeshInstance3D

## The OrbitalObject3D to draw its orbit; it is important that the node is a sibling of this node.
@export var orbiter: OrbitalObject3D : set = set_orbiter
## Number of segments for tracing the line
@export var segments: int = 256
@export var orbit_color: Color = Color(0.3, 0.7, 1.0, 0.7)
@export var show_orbit: bool = true : set = set_show_orbit

func set_orbiter(v):
	orbiter = v
	name = orbiter.name + "Orbit"

func set_show_orbit(v):
	show_orbit = v
	if show_orbit:
		update_orbit()
	else:
		mesh = null

func _process(_delta):
	if not orbiter: return
	if get_parent() != orbiter.get_parent():
		get_parent().remove_child(self)
		orbiter.get_parent().add_child(self)
	update_orbit()

func update_orbit():
	if not show_orbit or not orbiter or not is_inside_tree():
		mesh = null
		return

	# ¡CLAVE! Tus puntos vienen en espacio LOCAL del atractor (el padre)
	# Como este nodo es hijo del atractor → los puntos están en nuestro espacio local!
	var points = orbiter.get_trajectory(segments)
	if points.is_empty():
		mesh = null
		return
	# ImmediateMesh → la única forma 100% fiable con movimiento + jerarquía + Forward+
	if not (mesh is ImmediateMesh):
		mesh = ImmediateMesh.new()

	var imesh: ImmediateMesh = mesh as ImmediateMesh
	imesh.clear_surfaces()

	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = orbit_color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = false  # true si querés que pase por encima de planetas

	imesh.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	for i in range(points.size()-1):
		var p1 = points[i]
		var p2 = points[(i + 1) % points.size()]
		imesh.surface_set_color(orbit_color)
		imesh.surface_add_vertex(p1)
		imesh.surface_add_vertex(p2)
	imesh.surface_end()
	if orbiter.name == "Asteroiod": print("hechoossd")
	# Anti-culling para órbitas grandes o rápidas
	var max_radius = 0.0
	for p in points:
		max_radius = max(max_radius, p.length())
	extra_cull_margin = max(100.0, max_radius * 0.2)

	# Forzamos transform limpia (por si alguien movió el nodo manualmente)
	transform = Transform3D()
