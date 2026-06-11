@tool

class_name OrbitalObject3D
extends Area3D

signal orbit_changed()
signal orbiter_added(orbiter:OrbitalObject3D)
signal orbiter_removed(orbiter:OrbitalObject3D)
signal has_new_attractor()

@export var mass: float = 1.0
@export var radius: float = 0.5
@export var _initial_position: Vector3= Vector3.ZERO: set = _set_initial_position
@export var _initial_velocity: Vector3 = Vector3.ZERO: set = _set_initial_velocity
@export var spin_axis: Vector3 = Vector3.UP
@export var spin_rate: float = 0.0
@export var visual: Node3D

var orbit_type: ORBITS_TYPES = ORBITS_TYPES.INDETERMINATE
var _initial_time: float

func _set_initial_position(v:Vector3):
	_initial_position = v
	if Engine.is_editor_hint():
		position = _initial_position
		orbit_type = ORBITS_TYPES.INDETERMINATE

func _set_initial_velocity(v:Vector3):
	_initial_velocity = v
	if Engine.is_editor_hint(): orbit_type = ORBITS_TYPES.INDETERMINATE

enum ORBITS_TYPES {
	INDETERMINATE,
	RADIAL,
	ELIPTIC,
	PARABOLIC,
	HYPERBOLIC,
	CENTRAL_OBJECT
}

@onready var influence_zone: CollisionShape3D = $InfluenceZone

var orbiters: Array[Node]:
	get:
		return _orbiters.duplicate(true)
var _orbiters: Array[Node]
var influence_radius: float = 0.0
var attractor: OrbitalObject3D
var _last_transform: Transform3D

func _enter_tree() -> void:
	_setup_collider()
	if not area_entered.is_connected(_on_area_entered):
		area_entered.connect(_on_area_entered)
	if not area_exited.is_connected(_on_area_exited):
		area_exited.connect(_on_area_exited)

func _setup_collider():
	var influence_zone = get_node_or_null("InfluenceZone")
	if not influence_zone:
		influence_zone = CollisionShape3D.new()
		influence_zone.name = "InfluenceZone"
		add_child(influence_zone)
		influence_zone.owner = get_tree().edited_scene_root if get_tree() else null
		influence_zone.shape = SphereShape3D.new()

func _ready() -> void:
	if not is_instance_valid(OrbitalManager):
		push_error("El Autoload 'OrbitalManager' no está configurado.")
		return

	var children: Array[Node] = get_children()
	_orbiters = children.filter(_orbiters_filter)
	for orbiter:OrbitalObject3D in _orbiters:
		var orb_pos:Vector3 = orbiter._initial_position
		var orb_vel:Vector3 = orbiter._initial_velocity

		# 只在运行时随机，编辑器保持原样
		if not Engine.is_editor_hint():
			var random_angle = randf() * 2.0 * PI
			var orbit_normal = orb_pos.cross(orb_vel).normalized()
			if orbit_normal.length() < 0.01:
				orbit_normal = Vector3.UP
			var rotation_quat = Quaternion(orbit_normal, random_angle)
			orb_pos = rotation_quat * orb_pos
			orb_vel = rotation_quat * orb_vel

		add_orbiter(orbiter, orb_pos, orb_vel)

	set_notify_transform(true)
	_last_transform = global_transform

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and Engine.is_editor_hint():
		if _last_transform != global_transform:
			orbit_type = ORBITS_TYPES.INDETERMINATE
			_initial_position = position
			_last_transform = global_transform

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		if not attractor and get_parent() is OrbitalObject3D:
			attractor = get_parent()
		if not orbit_type:
			orbit_type = calcule_orbit(_initial_position, _initial_velocity)
			position = _initial_position
		return

	if not orbit_type:
		orbit_type = calcule_orbit(_initial_position, _initial_velocity)
	if orbit_type != ORBITS_TYPES.INDETERMINATE and orbit_type != ORBITS_TYPES.CENTRAL_OBJECT:
		var current_time = OrbitalManager.simulation_time - _initial_time
		position = _get_position_at_time(current_time)
	if spin_rate != 0.0 and visual:
		visual.rotate(spin_axis.normalized(), spin_rate * delta * OrbitalManager.time_scale)

func _get_position_at_time(t: float) -> Vector3:
	if not orbit_type:
		return position

	var pos_perifocal: Vector3
	var a = semi_major_axis
	var e = eccentricity
	var mu = mu_attractor
	var n = sqrt(mu / abs(pow(a, 3)))
	var mean_anomaly = _mean_anomaly_at_t0 + n * t

	match orbit_type:
		ORBITS_TYPES.RADIAL:
			var r_unit: Vector3 = _initial_position.normalized()
			var result = _solve_radial_motion(t, _initial_position.length(), _initial_velocity.dot(r_unit), mu)
			pos_perifocal = r_unit * result.position_magnitude

		ORBITS_TYPES.ELIPTIC:
			mean_anomaly = fmod(mean_anomaly, 2.0 * PI)
			if mean_anomaly < 0.0: mean_anomaly += 2.0 * PI
			var E = _solve_kepler_newton_raphson(mean_anomaly, e)
			var xp = a * (cos(E) - e)
			var yp = a * sqrt(1.0 - e*e) * sin(E)
			pos_perifocal = Vector3(xp, yp, 0.0)

		ORBITS_TYPES.HYPERBOLIC:
			var F = _solve_kepler_hyperbolic(mean_anomaly, e)
			var abs_a = abs(a)
			var xp = abs_a * (e - cosh(F))
			var yp = abs_a * sqrt(e*e - 1.0) * sinh(F)
			pos_perifocal = Vector3(xp, yp, 0.0)

		ORBITS_TYPES.PARABOLIC:
			return position

	return transform.basis * pos_perifocal

func _get_velocity_at_time(t: float) -> Vector3:
	if not orbit_type:
		return get_velocity()

	var vel_perifocal: Vector3
	var a = semi_major_axis
	var e = eccentricity
	var mu = mu_attractor
	var n = sqrt(mu / abs(pow(a, 3)))
	var mean_anomaly = _mean_anomaly_at_t0 + n * t

	match orbit_type:
		ORBITS_TYPES.RADIAL:
			var r_unit: Vector3 = _initial_position.normalized()
			var result = _solve_radial_motion(t, _initial_position.length(), _initial_velocity.dot(r_unit), mu)
			vel_perifocal = r_unit * result.velocity_magnitude

		ORBITS_TYPES.ELIPTIC:
			mean_anomaly = fmod(mean_anomaly, 2.0 * PI)
			if mean_anomaly < 0.0: mean_anomaly += 2.0 * PI
			var E = _solve_kepler_newton_raphson(mean_anomaly, e)
			var Edot = n / (1.0 - e * cos(E))
			var xp_dot = -a * sin(E) * Edot
			var yp_dot = a * sqrt(1.0 - e*e) * cos(E) * Edot
			vel_perifocal = Vector3(xp_dot, yp_dot, 0.0)

		ORBITS_TYPES.HYPERBOLIC:
			var F = _solve_kepler_hyperbolic(mean_anomaly, e)
			var abs_a = abs(a)
			var F_dot = n / (e * cosh(F) - 1.0)
			var xp_dot = -abs_a * sinh(F) * F_dot
			var yp_dot = abs_a * sqrt(e*e - 1.0) * cosh(F) * F_dot
			vel_perifocal = Vector3(xp_dot, yp_dot, 0.0)

		ORBITS_TYPES.PARABOLIC:
			return get_velocity()

	return transform.basis * vel_perifocal

func _calculate_influence_radius(M:float, m:float) -> float:
	if not m > 0.0:
		return 0.0
	var a = abs(semi_major_axis)
	var mass_ratio:float = m / M
	if mass_ratio > 0.17: mass_ratio = 0.17
	var r:float = a * pow(mass_ratio, (2.0/5.0))
	if r < 1.0: r = 0.1
	if influence_zone.shape is SphereShape3D:
		var shape:SphereShape3D = influence_zone.shape
		shape.radius = r
	influence_zone.disabled = false
	print(name, ". Radio de influencia: ", r)
	return r

func _orbiters_filter(node: Node) -> bool:
	return node is OrbitalObject3D

var mu_attractor: float
var semi_major_axis: float
var eccentricity: float
var inclination: float
var raan: float
var argument_of_periapsis: float
var true_anomaly: float
var period: float
var _mean_anomaly_at_t0: float = 0.0
var _eliptic: bool

func _calculate_orbital_elements(r_vec: Vector3, v_vec:Vector3, attractor: OrbitalObject3D) -> int:
	if not attractor:
		print(name, ": Cuerpo sin atractor, sin órbita definida.")
		semi_major_axis = INF
		return ORBITS_TYPES.INDETERMINATE

	mu_attractor = OrbitalManager.G * attractor.mass
	var r = r_vec.length()
	var v = v_vec.length()
	var mu = mu_attractor

	var h_vec = r_vec.cross(v_vec)
	var h = h_vec.length()

	const H_MAGNITUDE_TOLERANCE = 0.001
	if r * v > 0.0:
		var relative_h = h / (r * v)
		if relative_h < H_MAGNITUDE_TOLERANCE:
			transform = get_parent().transform
			return ORBITS_TYPES.RADIAL
	if v < 1e-6:
		transform = get_parent().transform
		return ORBITS_TYPES.RADIAL

	var e_vec = ((v_vec.cross(h_vec)) / mu) - (r_vec.normalized())
	eccentricity = e_vec.length()
	transform = _calculate_orbital_transform(h_vec, e_vec, attractor)

	var epsilon = (v*v / 2.0) - (mu / r)
	if abs(epsilon) < 1e-6:
		semi_major_axis = INF
		eccentricity = 1.0
		print("Órbita Parabólica")
		var dv:float = 0.001
		var result: int
		if _eliptic:
			result = calcule_orbit(r_vec, v_vec * (1.0 + dv))
		else:
			result = calcule_orbit(r_vec, v_vec * (1.0 - dv))
		return result
	elif epsilon < 0:
		semi_major_axis = -mu / (2.0 * epsilon)
		period = 2.0 * PI * sqrt(pow(semi_major_axis, 3) / mu)
		_eliptic = true
		print(name, ": Órbita Elíptica. Período: ", period, " s, e: ", eccentricity)
	else:
		semi_major_axis = -mu / (2.0 * epsilon)
		period = INF
		_eliptic = false
		print(name, ": Órbita Hiperbólica. Trayectoria de escape. e=", eccentricity)

	inclination = acos(h_vec.z / h)

	var k = Vector3(0, 0, 1)
	var n_vec = k.cross(h_vec)
	var n = n_vec.length()

	if n == 0:
		raan = 0.0
	else:
		raan = acos(n_vec.x / n)
		if n_vec.y < 0:
			raan = (2.0 * PI) - raan

	if eccentricity == 0:
		argument_of_periapsis = 0.0
	elif n == 0:
		argument_of_periapsis = acos(e_vec.x / eccentricity)
		if e_vec.y < 0:
			argument_of_periapsis = (2.0 * PI) - argument_of_periapsis
	else:
		argument_of_periapsis = acos(n_vec.dot(e_vec) / (n * eccentricity))
		if e_vec.z < 0:
			argument_of_periapsis = (2.0 * PI) - argument_of_periapsis

	true_anomaly = acos(e_vec.dot(r_vec) / (eccentricity * r))
	if r_vec.dot(v_vec) < 0:
		if eccentricity > 1.0:
			true_anomaly = -true_anomaly
		else:
			true_anomaly = (2.0 * PI) - true_anomaly

	_mean_anomaly_at_t0 = _true_to_mean_anomaly(true_anomaly, eccentricity)

	if _eliptic:
		return ORBITS_TYPES.ELIPTIC
	return ORBITS_TYPES.HYPERBOLIC

func _calculate_orbital_transform(h_vec: Vector3, e_vec: Vector3, attractor: OrbitalObject3D) -> Transform3D:
	var k_axis: Vector3 = h_vec.normalized()
	var i_axis: Vector3 = e_vec.normalized()
	var j_axis: Vector3 = k_axis.cross(i_axis)
	var basis = Basis(i_axis, j_axis, k_axis)
	return Transform3D(basis, attractor.position)

func _true_to_mean_anomaly(nu: float, e: float) -> float:
	if e == 1.0:
		return 0.0
	if e < 1.0:
		var E_y = sin(nu) * sqrt(1.0 - e*e)
		var E_x = cos(nu) + e
		var E = atan2(E_y, E_x)
		E = fmod(E, 2.0 * PI)
		if E < 0.0: E += 2.0 * PI
		var M = E - e * sin(E)
		M = fmod(M, 2.0 * PI)
		if M < 0.0: M += 2.0 * PI
		return M
	else:
		var cos_nu = cos(nu)
		var arg = (e + cos_nu) / (1.0 + e * cos_nu)
		var F_magnitude = log(arg + sqrt(arg * arg - 1.0))
		var F = F_magnitude
		if nu < 0.0:
			F = -F_magnitude
		var M = e * sinh(F) - F
		return M

func _solve_radial_motion(t_total: float, r0: float, v0: float, mu: float) -> Dictionary:
	var time_remaining = t_total
	var r = r0
	var v = v0
	var dt = 0.1
	while time_remaining > 0.0:
		var step = min(time_remaining, dt)
		var a = -mu / (r * r)
		r += v * step
		v += a * step
		time_remaining -= step
		if r <= 0.0:
			r = 0.0
			v = 0.0
			break
	return {"position_magnitude": r, "velocity_magnitude": v}

func _solve_kepler_newton_raphson(mean_anomaly: float, e: float) -> float:
	const MAX_ITERATIONS = 10
	const TOLERANCE = 1e-12
	const MIN_F_PRIME = 0.001
	const MAX_DELTA_E = 1.0
	var M = fmod(mean_anomaly, 2.0 * PI)
	if M < 0.0: M += 2.0 * PI
	var E = M
	for i in range(MAX_ITERATIONS):
		var sin_E = sin(E)
		var cos_E = cos(E)
		var f_E = E - e * sin_E - M
		if abs(f_E) < TOLERANCE: break
		var f_prime_E = 1.0 - e * cos_E
		if abs(f_prime_E) < MIN_F_PRIME:
			f_prime_E = MIN_F_PRIME if f_prime_E >= 0.0 else -MIN_F_PRIME
		var delta_E = f_E / f_prime_E
		if abs(delta_E) > MAX_DELTA_E:
			delta_E = sign(delta_E) * MAX_DELTA_E
		E -= delta_E
	E = fmod(E, 2.0 * PI)
	if E < 0.0: E += 2.0 * PI
	return E

func _solve_kepler_hyperbolic(mean_anomaly: float, e: float) -> float:
	const MAX_ITERATIONS = 15
	const TOLERANCE = 1e-12
	var M = mean_anomaly
	var F = M
	if e > 1.0:
		F = log(abs(M / e) + 1.0)
	if M < 0.0:
		F *= -1.0
	for i in range(MAX_ITERATIONS):
		var sinh_F = sinh(F)
		var cosh_F = cosh(F)
		var f_F = e * sinh_F - F - M
		var f_prime_F = e * cosh_F - 1.0
		var delta_F = f_F / f_prime_F
		if abs(delta_F) < TOLERANCE: break
		F -= delta_F
	return F

func _is_eliptic() -> bool:
	return _eliptic

func get_velocity() -> Vector3:
	if Engine.is_editor_hint():
		return Vector3.ZERO
	var current_time = OrbitalManager.simulation_time - _initial_time
	return _get_velocity_at_time(current_time)

func get_eccentricity() -> float:
	return eccentricity

func get_period() -> float:
	return period

func get_semi_major_axis() -> float:
	return semi_major_axis

func get_perifocal_vector() -> Vector3:
	return transform.basis * Vector3.RIGHT

func get_normal_vector() -> Vector3:
	return transform.basis * Vector3.BACK

func get_orbit_type() -> ORBITS_TYPES:
	return orbit_type

func get_attractor() -> OrbitalObject3D:
	return attractor

func add_orbiter(orbiter:OrbitalObject3D, new_position:Vector3, new_velocity:Vector3) -> void:
	orbiter.attractor = self
	orbiter._initial_position = new_position
	orbiter._initial_velocity = new_velocity
	orbiter.orbit_type = ORBITS_TYPES.INDETERMINATE
	if orbiter.get_parent() != self:
		if orbiter.get_parent():
			orbiter.get_parent().remove_orbiter(orbiter)
		add_child(orbiter)
		_orbiters.append(orbiter)
	print(orbiter.name, " agregado como orbitador de ", self.name)
	orbiter_added.emit(orbiter)
	orbiter.has_new_attractor.emit()

func remove_orbiter(orbiter:OrbitalObject3D) -> void:
	if orbiter.get_parent() != self: return
	remove_child(orbiter)
	_orbiters.erase(orbiter)
	orbiter_removed.emit(orbiter)

func has_orbiters() -> bool:
	return orbiters.size() > 0

func get_orbiters() -> Array:
	return orbiters

func calcule_orbit(new_position: Vector3, new_velocity: Vector3) -> ORBITS_TYPES:
	if not attractor:
		print(name, ": Cuerpo sin atractor, cuerpo central.")
		return ORBITS_TYPES.CENTRAL_OBJECT
	var o_t:ORBITS_TYPES = _calculate_orbital_elements(new_position, new_velocity, attractor)
	if o_t:
		if Engine.is_editor_hint():
			_initial_time = 0.0
		else:
			_initial_time = OrbitalManager.simulation_time
		influence_radius = _calculate_influence_radius(attractor.mass, mass)
		orbit_changed.emit()
	return o_t

func get_trajectory(segments: int) -> Array[Vector3]:
	var result:Array[Vector3] = []
	var a = abs(semi_major_axis)
	var e = eccentricity
	var point:Vector3
	var SOI_radius:float = attractor.influence_radius
	var central:bool = attractor.orbit_type == ORBITS_TYPES.CENTRAL_OBJECT
	match orbit_type:
		ORBITS_TYPES.ELIPTIC:
			var E:float = -PI
			var dE: float = 2 * PI / float(segments)
			while E < PI:
				var xp = a * (cos(E) - e)
				var yp = a * sqrt(1.0 - e*e) * sin(E)
				point = transform.basis * Vector3(xp, yp, 0.0)
				if central or point.length() <= SOI_radius:
					result.append(point)
				E += dE
			point = transform.basis * Vector3(a*(-1 - e), 0.0, 0.0)
			if central or point.length() <= SOI_radius:
				result.append(point)
			return result
		ORBITS_TYPES.HYPERBOLIC:
			var nu_max = acos(-1.0 / e) * 0.99
			for i in range(segments + 1):
				var t = float(i) / float(segments)
				var nu = -nu_max + 2.0 * nu_max * t
				var r = a * (e * e - 1.0) / (1.0 + e * cos(nu))
				var xp = r * cos(nu)
				var yp = r * sin(nu)
				point = transform.basis * Vector3(xp, yp, 0.0)
				if central or point.length() <= SOI_radius:
					result.append(point)
			return result
	return result

func inclination_to(other_orbiter:OrbitalObject3D) -> float:
	if not other_orbiter.attractor == attractor:
		return 0.0
	return other_orbiter.get_normal_vector().angle_to(get_normal_vector())

func nodal_axis_to(other_orbiter:OrbitalObject3D) -> Vector3:
	if not other_orbiter.attractor == attractor:
		return Vector3.ZERO
	return other_orbiter.get_normal_vector().cross(get_normal_vector())

func get_periapsis() -> Vector3:
	var result:Vector3 = Vector3.ZERO
	var a = semi_major_axis
	var e = eccentricity
	match orbit_type:
		ORBITS_TYPES.ELIPTIC:
			result = transform.basis * Vector3(a * (1 - e), 0.0, 0.0)
		ORBITS_TYPES.HYPERBOLIC:
			result = transform.basis * Vector3(a * (e * e - 1.0) / (1.0 + e), 0.0, 0.0)
	return result

func get_apoapsis() -> Vector3:
	var result:Vector3 = Vector3.ZERO
	if orbit_type == ORBITS_TYPES.ELIPTIC:
		var a = semi_major_axis
		var e = eccentricity
		result = transform.basis * Vector3(a * (-1 - e), 0.0, 0.0)
	return result

func _on_area_entered(area: Area3D) -> void:
	if not area is OrbitalObject3D: return
	var new_orbiter: OrbitalObject3D = area
	if not new_orbiter.orbit_type: return
	if new_orbiter.mass >= mass: return
	if new_orbiter.attractor == attractor:
		var new_pos:Vector3 = transform.inverse() * new_orbiter.position
		var new_vel:Vector3 = new_orbiter.get_velocity() - get_velocity()
		new_vel = basis.inverse() * new_vel
		add_orbiter(new_orbiter, new_pos, new_vel)
		print(new_orbiter.name, " entrando en orbita de ", name)

func _on_area_exited(area: Area3D) -> void:
	if not area is OrbitalObject3D: return
	if not is_instance_valid(attractor): return
	var orbiter:OrbitalObject3D = area
	if not orbiter.orbit_type: return
	if not orbiter.attractor == self: return
	var new_attractor: OrbitalObject3D = attractor
	var new_pos:Vector3 = transform * orbiter.position
	var new_vel:Vector3 = basis * orbiter.get_velocity()
	new_vel = new_vel + get_velocity()
	new_attractor.add_orbiter(orbiter, new_pos, new_vel)
	print(area.name, " saliendo de la orbita de ", name)
