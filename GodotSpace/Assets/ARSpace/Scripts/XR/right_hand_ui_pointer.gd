class_name ARSpaceRightHandUIPointer
extends XRToolsFunctionPointer

## ARSpace right-hand pointer visual.
##
## The interaction and event dispatch remain owned by XRToolsFunctionPointer.
## This subclass only specializes the beam and hit indicator so the project can
## keep the vendored XR Tools pointer behavior while matching the Unity client.

const MIN_BEAM_LENGTH: float = 0.001
const MIN_RADIUS: float = 0.0001
const NORMAL_COLOR: Color = Color(1.0, 0.055, 0.025, 1.0)
const WINDOW_HIT_COLOR: Color = Color(0.0, 0.70, 1.0, 1.0)
const RING_RENDER_PRIORITY: int = 127
const OPENXR_SESSION_STATE_FOCUSED: int = 5

@export_group("ARSpace Visual")

## Beam radius beside the controller.
@export_range(0.0001, 0.05, 0.0001) var near_radius: float = 0.006

## Beam radius at its visible endpoint.
@export_range(0.0001, 0.05, 0.0001) var far_radius: float = 0.0001

## Beam opacity beside the controller.
@export_range(0.0, 1.0, 0.01) var near_alpha: float = 0.58

## Beam opacity at its visible endpoint.
@export_range(0.0, 1.0, 0.01) var far_alpha: float = 0.0

## Fixed distance where the beam reaches its transparent tip.
## Interaction raycasts still use the independent `distance` property.
@export_range(0.1, 5.0, 0.05) var visual_taper_distance: float = 1.0

## Number of sides used by the circular cone mesh.
@export_range(6, 48, 1) var radial_segments: int = 20

## Portion of target_radius occupied by the ring hole.
@export_range(0.1, 0.95, 0.01) var ring_inner_radius_ratio: float = 0.70

## Offset from the panel surface to avoid z-fighting.
@export_range(0.0, 0.01, 0.0001) var ring_surface_offset: float = 0.0015

@export_group("Aim Stabilization")

## Smooth the actual ray direction while leaving the controller origin live.
## This keeps interaction events and visuals on the same stabilized ray.
@export var aim_smoothing_enabled: bool = true

## Exponential follow rate in 1/seconds. Higher values reduce latency.
@export_range(1.0, 60.0, 0.5) var aim_follow_speed: float = 30.0

## Angular motion below this threshold is treated as tracking noise.
@export_range(0.0, 2.0, 0.01) var aim_deadzone_degrees: float = 0.15

## Large intentional turns bypass smoothing so the pointer never trails far behind.
@export_range(2.0, 90.0, 0.5) var aim_snap_angle_degrees: float = 15.0

@export_group("Controller Readiness")

## Keep the pointer hidden until the physical right controller is tracked.
@export var wait_for_tracked_controller: bool = true

## Consecutive physics frames of valid tracking required before activation.
## This also gives Viewport2DIn3D collision bodies one physics tick to register.
@export_range(0, 8, 1) var tracking_ready_physics_frames: int = 2

var _aim_initialized: bool = false
var _smoothed_aim_direction: Vector3 = Vector3.FORWARD
var _current_beam_length: float = 1.0
var _interaction_requested: bool = true
var _runtime_interaction_ready: bool = false
var _tracking_ready_frame_count: int = 0
var _tracked_controller: XRController3D


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	_interaction_requested = enabled
	if _uses_tracking_readiness_gate():
		enabled = false
		visible = false
	super._ready()
	_tracked_controller = XRHelpers.get_xr_controller(self)
	_connect_controller_readiness_signals()
	_install_cone_beam()
	_install_target_ring()
	_ensure_visual_materials()
	_update_pointer()
	if not _uses_tracking_readiness_gate():
		_apply_runtime_interaction_ready(_interaction_requested)


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or not is_inside_tree():
		return

	_update_stabilized_raycast(delta)
	super._process(delta)
	_apply_beam_transform()


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or not is_inside_tree():
		return
	if not _interaction_requested:
		_tracking_ready_frame_count = 0
		_apply_runtime_interaction_ready(false)
		return
	if not _uses_tracking_readiness_gate():
		_apply_runtime_interaction_ready(true)
		return
	if not _is_runtime_input_ready():
		_tracking_ready_frame_count = 0
		_apply_runtime_interaction_ready(false)
		return

	_tracking_ready_frame_count += 1
	if _tracking_ready_frame_count >= tracking_ready_physics_frames:
		_apply_runtime_interaction_ready(true)


func set_interaction_requested(requested: bool) -> void:
	_interaction_requested = requested
	_tracking_ready_frame_count = 0
	if not requested:
		_apply_runtime_interaction_ready(false)
	elif not _uses_tracking_readiness_gate():
		_apply_runtime_interaction_ready(true)
	else:
		_apply_runtime_interaction_ready(false)


func is_runtime_interaction_ready() -> bool:
	return _runtime_interaction_ready


func _uses_tracking_readiness_gate() -> bool:
	return wait_for_tracked_controller and not _is_test_mode()


func _is_test_mode() -> bool:
	return OS.get_cmdline_args().has("--testmode") \
		or OS.get_cmdline_user_args().has("--testmode")


func _is_runtime_input_ready() -> bool:
	if not is_controller_tracking_ready(_tracked_controller):
		return false
	var xr_interface := XRServer.find_interface("OpenXR")
	if xr_interface == null or not xr_interface.is_initialized():
		return false
	if xr_interface.has_method("get_session_state"):
		return int(xr_interface.call("get_session_state")) \
			== OPENXR_SESSION_STATE_FOCUSED
	return true


func _connect_controller_readiness_signals() -> void:
	if _tracked_controller == null:
		return
	var tracking_callback := Callable(self, "_on_controller_tracking_changed")
	if not _tracked_controller.tracking_changed.is_connected(tracking_callback):
		_tracked_controller.tracking_changed.connect(tracking_callback)
	var profile_callback := Callable(self, "_on_controller_profile_changed")
	if not _tracked_controller.profile_changed.is_connected(profile_callback):
		_tracked_controller.profile_changed.connect(profile_callback)


func _on_controller_tracking_changed(_tracking: bool) -> void:
	_tracking_ready_frame_count = 0
	_apply_runtime_interaction_ready(false)


func _on_controller_profile_changed(_role: String) -> void:
	# Input actions can be rebound when the OpenXR interaction profile arrives.
	# Briefly close the gate so pose, raycast and buttons reopen together.
	_tracking_ready_frame_count = 0
	_apply_runtime_interaction_ready(false)


func _apply_runtime_interaction_ready(controller_ready: bool) -> void:
	var interaction_ready := _interaction_requested and (
		controller_ready or not _uses_tracking_readiness_gate()
	)
	if _runtime_interaction_ready == interaction_ready \
			and enabled == interaction_ready \
			and visible == interaction_ready:
		return

	_runtime_interaction_ready = interaction_ready
	if not interaction_ready:
		if target != null and is_instance_valid(target):
			XRToolsPointerEvent.released(self, target, last_collided_at)
		if last_target != null and is_instance_valid(last_target):
			XRToolsPointerEvent.exited(self, last_target, last_collided_at)
		target = null
		last_target = null
		last_collided_at = Vector3.ZERO
		super.set_enabled(false)
		visible = false
		return

	_aim_initialized = false
	_update_stabilized_raycast(0.0)
	var ray := get_node_or_null("RayCast") as RayCast3D
	if ray != null:
		ray.force_raycast_update()
	super.set_enabled(true)
	visible = true


static func is_controller_tracking_ready(controller: XRController3D) -> bool:
	return controller != null \
		and controller.get_is_active() \
		and controller.get_has_tracking_data()


func _install_cone_beam() -> void:
	var laser := get_node_or_null("Laser") as MeshInstance3D
	if laser == null:
		return
	laser.mesh = build_cone_beam_mesh(
		near_radius,
		far_radius,
		near_alpha,
		far_alpha,
		radial_segments
	)
	laser.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_set_beam_length(minf(distance, visual_taper_distance))


func _install_target_ring() -> void:
	var target_node := get_node_or_null("Target") as MeshInstance3D
	if target_node == null:
		return
	var ring := TorusMesh.new()
	ring.rings = 32
	ring.ring_segments = 8
	target_node.mesh = ring
	target_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	target_node.extra_cull_margin = 0.05
	_update_target_radius()


func _ensure_visual_materials() -> void:
	if laser_material == null:
		laser_material = make_beam_material(NORMAL_COLOR)
	if laser_hit_material == null:
		laser_hit_material = make_beam_material(WINDOW_HIT_COLOR)
	if target_material == null:
		target_material = make_ring_material(WINDOW_HIT_COLOR)


func _update_target_radius() -> void:
	var target_node := get_node_or_null("Target") as MeshInstance3D
	if target_node == null:
		return
	if target_node.mesh is TorusMesh:
		var ring := target_node.mesh as TorusMesh
		ring.inner_radius = maxf(
			target_radius * ring_inner_radius_ratio,
			MIN_RADIUS
		)
		ring.outer_radius = maxf(target_radius, ring.inner_radius + MIN_RADIUS)
	else:
		super._update_target_radius()


func _update_target_material() -> void:
	var target_node := get_node_or_null("Target") as MeshInstance3D
	if target_node != null and target_material != null:
		target_node.set_surface_override_material(0, target_material)


func _visible_hit(at: Vector3) -> void:
	var window_hit := _is_current_window_hit()
	_update_laser_active_material(window_hit)
	_update_target_ring(at, window_hit)

	var laser := get_node_or_null("Laser") as MeshInstance3D
	if laser == null:
		return
	var visible_length := distance
	if laser_length == LaserLength.COLLIDE:
		visible_length = _collision_length(at)
	visible_length = minf(visible_length, visual_taper_distance)
	_set_beam_length(visible_length)
	laser.visible = enabled and show_laser != LaserShow.HIDE


func _visible_move(at: Vector3) -> void:
	# Re-evaluate the target on every move. This also handles crossing directly
	# from a pointable 3D object to a UI window without an intermediate miss.
	_visible_hit(at)


func _visible_miss() -> void:
	var target_node := get_node_or_null("Target") as MeshInstance3D
	if target_node != null:
		target_node.visible = false
	_update_laser_active_material(false)
	_set_beam_length(minf(distance, visual_taper_distance))

	var laser := get_node_or_null("Laser") as MeshInstance3D
	if laser != null:
		laser.visible = enabled and show_laser == LaserShow.SHOW


func _update_laser_active_material(window_hit: bool) -> void:
	var laser := get_node_or_null("Laser") as MeshInstance3D
	if laser == null:
		return
	var material := (
		laser_hit_material
		if window_hit and laser_hit_material != null
		else laser_material
	)
	if material != null:
		laser.set_surface_override_material(0, material)


func _update_target_ring(at: Vector3, window_hit: bool) -> void:
	var target_node := get_node_or_null("Target") as MeshInstance3D
	if target_node == null:
		return
	target_node.visible = enabled and show_target and window_hit
	if not target_node.visible:
		return

	var ray := get_node_or_null("RayCast") as RayCast3D
	var collision_normal := Vector3.BACK
	var ray_direction := Vector3.FORWARD
	if ray != null and ray.is_colliding():
		collision_normal = ray.get_collision_normal()
		ray_direction = at - ray.global_position
	var surface_normal := resolve_window_surface_normal(
		_current_visual_target(),
		collision_normal,
		ray_direction
	)

	target_node.global_transform = Transform3D(
		_basis_from_up(surface_normal),
		at + surface_normal * ring_surface_offset
	)


func _set_beam_length(beam_length: float) -> void:
	_current_beam_length = clampf(
		beam_length,
		MIN_BEAM_LENGTH,
		maxf(visual_taper_distance, MIN_BEAM_LENGTH)
	)
	_apply_beam_transform()


func _update_stabilized_raycast(delta: float) -> void:
	var ray := get_node_or_null("RayCast") as RayCast3D
	if ray == null:
		return

	var pointer_basis := global_basis.orthonormalized()
	var desired_direction := -pointer_basis.z
	if not desired_direction.is_finite() \
			or desired_direction.length_squared() < 0.000001:
		desired_direction = Vector3.FORWARD
	else:
		desired_direction = desired_direction.normalized()

	if not _aim_initialized or not aim_smoothing_enabled:
		_smoothed_aim_direction = desired_direction
		_aim_initialized = true
	else:
		_smoothed_aim_direction = stabilize_aim_direction(
			_smoothed_aim_direction,
			desired_direction,
			delta,
			aim_follow_speed,
			aim_deadzone_degrees,
			aim_snap_angle_degrees
		)

	var safe_world_scale := maxf(XRServer.world_scale, 0.0001)
	var ray_origin := global_transform * Vector3(
		0.0,
		y_offset * safe_world_scale,
		0.0
	)
	ray.global_transform = Transform3D(
		_basis_from_forward(_smoothed_aim_direction, pointer_basis.y),
		ray_origin
	)
	if enabled:
		# RayCast3D otherwise keeps the last physics-frame result. Refreshing this
		# one pointer after its smoothed pose is applied avoids visible stepping
		# between the render and physics update rates.
		ray.force_raycast_update()


func _apply_beam_transform() -> void:
	var laser := get_node_or_null("Laser") as MeshInstance3D
	if laser == null:
		return
	var ray := get_node_or_null("RayCast") as RayCast3D
	if ray == null:
		var safe_world_scale := maxf(XRServer.world_scale, 0.0001)
		laser.position = Vector3(0.0, y_offset * safe_world_scale, 0.0)
		laser.scale = Vector3(
			safe_world_scale,
			safe_world_scale,
			_current_beam_length
		)
		return

	var beam_basis := ray.global_basis.orthonormalized()
	var beam_radius_scale := maxf(XRServer.world_scale, 0.0001)
	beam_basis.x *= beam_radius_scale
	beam_basis.y *= beam_radius_scale
	beam_basis.z *= _current_beam_length
	laser.global_transform = Transform3D(beam_basis, ray.global_position)


func _collision_length(at: Vector3) -> float:
	var ray := get_node_or_null("RayCast") as RayCast3D
	var origin := ray.global_position if ray != null else global_position
	return maxf(origin.distance_to(at), MIN_BEAM_LENGTH)


func _is_current_window_hit() -> bool:
	return is_interactable_window_target(_current_visual_target())


func _current_visual_target() -> Node:
	var candidate: Node = null
	if target != null and is_instance_valid(target):
		candidate = target
	else:
		var ray := get_node_or_null("RayCast") as RayCast3D
		if ray != null and ray.is_colliding():
			candidate = ray.get_collider() as Node
	return candidate


static func is_interactable_window_target(candidate: Node) -> bool:
	return _find_window_surface_node(candidate) != null


static func resolve_window_surface_normal(
	candidate: Node,
	collision_normal: Vector3,
	ray_direction: Vector3
) -> Vector3:
	# A Viewport2Din3D uses a thin BoxShape. Near its edges the physics hit can
	# report a side-face normal, which turns the ring edge-on and makes it seem
	# to disappear. Use the UI body's local Z axis as the stable panel normal.
	var surface_normal := collision_normal
	var window_surface := _find_window_surface_node(candidate)
	if window_surface != null:
		var panel_normal := window_surface.global_basis.z
		if panel_normal.is_finite() and panel_normal.length_squared() >= 0.000001:
			surface_normal = panel_normal
	if not surface_normal.is_finite() or surface_normal.length_squared() < 0.000001:
		surface_normal = Vector3.BACK
	else:
		surface_normal = surface_normal.normalized()
	if ray_direction.is_finite() \
			and ray_direction.length_squared() >= 0.000001 \
			and surface_normal.dot(ray_direction) > 0.0:
		surface_normal = -surface_normal
	return surface_normal


static func _find_window_surface_node(candidate: Node) -> Node3D:
	# XR Tools delivers pointer events to the StaticBody3D child of each
	# Viewport2Din3D. Walking a few ancestors also covers customized spatial
	# window scenes that wrap that body.
	var current := candidate
	for _depth in range(5):
		if current == null:
			return null
		if current is Node3D \
				and current.has_signal("pointer_event") \
				and current.has_method("global_to_viewport"):
			return current as Node3D
		current = current.get_parent()
	return null


static func build_cone_beam_mesh(
	p_near_radius: float,
	p_far_radius: float,
	p_near_alpha: float,
	p_far_alpha: float,
	p_radial_segments: int
) -> ArrayMesh:
	var sides := maxi(p_radial_segments, 3)
	var start_radius := maxf(p_near_radius, MIN_RADIUS)
	var end_radius := maxf(minf(p_far_radius, start_radius), MIN_RADIUS)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	for ring_index in range(2):
		var taper_progress := float(ring_index)
		var radius := lerpf(start_radius, end_radius, taper_progress)
		var alpha := lerpf(
			clampf(p_near_alpha, 0.0, 1.0),
			clampf(p_far_alpha, 0.0, 1.0),
			taper_progress
		)
		for side_index in range(sides):
			var angle := TAU * float(side_index) / float(sides)
			var radial := Vector3(cos(angle), sin(angle), 0.0)
			vertices.append(Vector3(
				radial.x * radius,
				radial.y * radius,
				-taper_progress
			))
			normals.append(radial)
			colors.append(Color(1.0, 1.0, 1.0, alpha))

	for side_index in range(sides):
		var next_side := (side_index + 1) % sides
		var far_index := sides + side_index
		var far_next := sides + next_side
		indices.append(side_index)
		indices.append(far_index)
		indices.append(far_next)
		indices.append(side_index)
		indices.append(far_next)
		indices.append(next_side)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func make_beam_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = color
	material.vertex_color_use_as_albedo = true
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 1.15
	material.no_depth_test = false
	return material


static func make_ring_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = Color(color.r, color.g, color.b, 0.96)
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 1.5
	# The ring is only shown for the nearest pointer target, so rendering it as
	# an overlay cannot expose a hidden target. It does prevent the transparent
	# viewport quad from intermittently winning the depth/sort order.
	material.no_depth_test = true
	material.render_priority = RING_RENDER_PRIORITY
	return material


static func stabilize_aim_direction(
	current_direction: Vector3,
	target_direction: Vector3,
	delta: float,
	follow_speed: float,
	deadzone_degrees: float,
	snap_angle_degrees: float
) -> Vector3:
	var target := target_direction.normalized()
	if not target.is_finite() or target.length_squared() < 0.000001:
		return Vector3.FORWARD
	var current := current_direction.normalized()
	if not current.is_finite() or current.length_squared() < 0.000001:
		return target

	var angle := current.angle_to(target)
	var deadzone := deg_to_rad(maxf(deadzone_degrees, 0.0))
	if angle <= deadzone:
		return current
	var snap_angle := deg_to_rad(maxf(snap_angle_degrees, deadzone_degrees))
	if angle >= snap_angle:
		return target

	# Remove the noise-sized portion of the motion before filtering. This gives
	# a soft angular deadzone without introducing a discontinuity at its edge.
	var effective_target := current.slerp(
		target,
		(angle - deadzone) / angle
	).normalized()
	var follow_weight := 1.0 - exp(
		-maxf(follow_speed, 0.0) * maxf(delta, 0.0)
	)
	return current.slerp(effective_target, follow_weight).normalized()


static func _basis_from_forward(direction: Vector3, up_hint: Vector3) -> Basis:
	var normalized_direction := direction.normalized()
	if not normalized_direction.is_finite() \
			or normalized_direction.length_squared() < 0.000001:
		normalized_direction = Vector3.FORWARD
	var z_axis := -normalized_direction
	var safe_up := up_hint.normalized()
	if not safe_up.is_finite() or safe_up.length_squared() < 0.000001:
		safe_up = Vector3.UP
	var x_axis := safe_up.cross(z_axis)
	if x_axis.length_squared() < 0.000001:
		x_axis = Vector3.RIGHT.cross(z_axis)
	if x_axis.length_squared() < 0.000001:
		x_axis = Vector3.FORWARD.cross(z_axis)
	x_axis = x_axis.normalized()
	var y_axis := z_axis.cross(x_axis).normalized()
	return Basis(x_axis, y_axis, z_axis).orthonormalized()


static func _basis_from_up(up: Vector3) -> Basis:
	var normalized_up := up.normalized()
	var tangent := Vector3.FORWARD.cross(normalized_up)
	if tangent.length_squared() < 0.000001:
		tangent = Vector3.RIGHT.cross(normalized_up)
	tangent = tangent.normalized()
	var forward := tangent.cross(normalized_up).normalized()
	return Basis(tangent, normalized_up, forward).orthonormalized()
