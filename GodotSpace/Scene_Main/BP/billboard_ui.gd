extends Node3D

@export var camera: Camera3D
@export var screen_size: float = 0.3

@onready var quad: MeshInstance3D = $MeshInstance3D
@onready var viewport: SubViewport = $SubViewport

func _ready() -> void:
	var vp_tex = ViewportTexture.new()
	vp_tex.viewport_path = viewport.get_path()
	var mat = quad.get_active_material(0)
	if mat is ShaderMaterial:
		mat.set_shader_parameter("ui_texture", vp_tex)

func _process(_delta: float) -> void:
	if not camera:
		return
	_face_camera()
	_update_scale()

func _face_camera() -> void:
	var dir = (camera.global_position - global_position).normalized()
	var right = dir.cross(Vector3.UP).normalized()
	if right.length() < 0.01:
		right = Vector3.RIGHT
	var up = right.cross(dir).normalized()
	global_transform.basis = Basis(right, up, -dir)

func _update_scale() -> void:
	var dist = global_position.distance_to(camera.global_position)
	var s = dist * screen_size
	quad.scale = Vector3(s, s * 0.5, 1.0)
