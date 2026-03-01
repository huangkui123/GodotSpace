@tool

## Keplerian Orbital Simulation Node
##
## OrbitalObject3D extends Area3D and serves as the core component for gravity-based orbital simulation.
## It implements the Patched Conics Approximation within a hierarchical reference frame. Orbital propagation is performed in the local coordinate space (transform) of the current attractor using the six Classic Orbital Elements (COEs).
## Position updates occur every _physics_process(delta) via analytical solutions (Kepler’s Equation solved with Newton-Raphson for elliptical orbits) and numerical fallbacks for singular cases (radial or parabolic motion).
## Attractor switching is handled automatically through gravitational Sphere of Influence (SOI) validation inside the _on_area_entered and _on_area_exited callbacks.
## Important: this model deliberately ignores perturbations from bodies other than the current attractor, preserving the simplicity and performance of the restricted two-body problem at every time step.

class_name OrbitalObject3D
extends Area3D

## Emitted whenever the orbital elements or trajectory of this body are updated.
signal orbit_changed()
## Emitted when a new satellite/orbiter enters this body's Sphere of Influence and becomes its child.
signal orbiter_added(orbiter:OrbitalObject3D)
## Emitted when a satellite/orbiter leaves this body's Sphere of Influence and is no longer its child.
signal orbiter_removed(orbiter:OrbitalObject3D)
## Emitted when this body changes its current gravitational attractor (parent body).
signal has_new_attractor()

# --- Propiedades Exportables ---
## The gravitational mass (μ) of this body, used in all orbital calculations (e.g., specific orbital energy, acceleration, and time period).
@export var mass: float = 1.0
@export var radius: float = 0.5
@export var _initial_position: Vector3= Vector3.ZERO: set = _set_initial_position
@export var _initial_velocity: Vector3 = Vector3.ZERO: set = _set_initial_velocity
@export var spin_axis: Vector3 = Vector3.UP
@export var spin_rate: float = 0.0  # 弧度/秒
@export var visual: Node3D
## The classification of the current trajectory determined by the calculated eccentricity ($e$) and specific energy. This is an enum value (ORBITS_TYPES) indicating whether the orbit is radial, elliptic, parabolic, or hyperbolic.
var orbit_type: ORBITS_TYPES = ORBITS_TYPES.INDETERMINATE
var _initial_time:float

func _set_initial_position(v:Vector3):
	_initial_position = v
	if Engine.is_editor_hint():
		position = _initial_position
		orbit_type = ORBITS_TYPES.INDETERMINATE
func _set_initial_velocity(v:Vector3):
	_initial_velocity = v
	if Engine.is_editor_hint(): orbit_type = ORBITS_TYPES.INDETERMINATE

##This enumeration defines the possible classifications of a body's trajectory, determined by its eccentricity and specific orbital energy relative to its current attractor.
enum ORBITS_TYPES {
	INDETERMINATE, ## Initial state or temporary state where the orbital elements have not yet been successfully calculated or classified. This state forces an immediate call to the orbit calculation
	RADIAL,
	ELIPTIC,
	PARABOLIC,
	HYPERBOLIC,
	CENTRAL_OBJECT ## State assigned to a body that has no attractor (i.e., the root of the orbital hierarchy). Indicates the body is considered stationary in its own frame of reference.
}

## The CollisionShape3D component that defines the geometric boundary of this body's Sphere of Influence (SOI). This node is used by the game engine to detect when another orbiter enters or exits the boundary, triggering the necessary frame of reference transfer logic.
@onready var influence_zone: CollisionShape3D = $InfluenceZone

## An array containing references to all OrbitalBody3D nodes currently using this body as their gravitational attractor. This list is actively managed during sphere of influence (SOI) transfers.
var orbiters: Array[Node]:
	get:
		return _orbiters.duplicate(true)
var _orbiters: Array[Node]
## The calculated radius (in world units) of this body's Sphere of Influence (SOI) relative to its own attractor. Orbiters will use this value to detect when to transition their frame of reference to this body.
var influence_radius: float = 0.0
## The current central gravitational body that this node is orbiting. All position and velocity state vectors of this body are calculated relative to the attractor's local coordinate system.
var attractor: OrbitalObject3D # Referencia al cuerpo central

var _last_transform: Transform3D

# ====================================================================

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
		influence_zone.shape = SphereShape3D.new()  # Asignar un shape

func _ready() -> void:
	# Asegurar que el autoload existe
	if not is_instance_valid(OrbitalManager):
		push_error("El Autoload 'OrbitalManager' no está configurado.")
		return
	
	var children: Array[Node] = get_children()
	_orbiters = children.filter(_orbiters_filter)
	for orbiter:OrbitalObject3D in _orbiters:
		var orb_pos:Vector3 = orbiter._initial_position
		var orb_vel:Vector3 = orbiter._initial_velocity
		add_orbiter(orbiter, orb_pos, orb_vel)
	
	set_notify_transform(true)
	_last_transform = global_transform

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and Engine.is_editor_hint():
		if _last_transform != global_transform:
			orbit_type = ORBITS_TYPES.INDETERMINATE
			_initial_position = position
			_last_transform = global_transform

func _process(_delta: float) -> void:
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
		var current_time = (Time.get_ticks_msec() / 1000.0 - _initial_time) * OrbitalManager.time_scale
		# Obtener posición
		position = _get_position_at_time(current_time)
	if spin_rate != 0.0:
		visual.rotate(spin_axis.normalized(), spin_rate * _delta * OrbitalManager.time_scale)

func _get_position_at_time(t: float) -> Vector3:
	if not orbit_type:
		return position
	
	var pos_perifocal: Vector3
	
	var a = semi_major_axis
	var e = eccentricity
	var mu = mu_attractor
	var n = sqrt( mu / abs(pow(a, 3)))
	# 1. Calcular la Anomalía Media (M)
	var mean_anomaly = _mean_anomaly_at_t0 + n * (t)
	
	match orbit_type:
		ORBITS_TYPES.RADIAL:
			# La dirección es constante (dada por la posición inicial)
			var r_unit: Vector3 = _initial_position.normalized()
			
			# Necesitas una función que resuelva el movimiento radial unidimensional
			var result = _solve_radial_motion(t, _initial_position.length(), _initial_velocity.dot(r_unit), mu)
			
			var pos_magnitude = result.position_magnitude
			
			#La posición final es solo la magnitud a lo largo de la dirección unitaria
			pos_perifocal = r_unit * pos_magnitude
	
		ORBITS_TYPES.ELIPTIC:
			mean_anomaly = fmod(mean_anomaly, 2.0 * PI)
			if mean_anomaly < 0.0: mean_anomaly += 2.0 * PI
			
			# 2. M -> E (Anomalía Excéntrica)
			var E = _solve_kepler_newton_raphson(mean_anomaly, e)
			
			# 3. Posición (r_vec) en el Plano Perifocal (Xp, Yp, Zp=0)
			var xp = a * (cos(E) - e)
			var yp = a * sqrt(1.0 - e*e) * sin(E)
			pos_perifocal = Vector3(xp, yp, 0.0) # Plano orbital XY
		
		ORBITS_TYPES.HYPERBOLIC:
			# 2. M -> F (Anomalía Excéntrica Hiperbólica)
			var F = _solve_kepler_hyperbolic(mean_anomaly, e) # ¡CORRECCIÓN APLICADA!
			
			# Nota: En hiperbólica, 'a' debe ser usado con valor absoluto
			# Aunque lo calculamos como positivo, aseguramos la definición
			var abs_a = abs(a) 
			
			# Posición Hiperbólica
			# r = a(e*cosh(F) - 1). La definición de xp e yp es la correcta
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
	var n = sqrt( mu / abs(pow(a, 3)))
	# 1. Calcular la Anomalía Media (M)
	var mean_anomaly = _mean_anomaly_at_t0 + n * (t)
	
	match orbit_type:
		ORBITS_TYPES.RADIAL:
			# La dirección es constante (dada por la posición inicial)
			var r_unit: Vector3 = _initial_position.normalized()
			
			# Necesitas una función que resuelva el movimiento radial unidimensional
			var result = _solve_radial_motion(t, _initial_position.length(), _initial_velocity.dot(r_unit), mu)
			
			var vel_magnitude = result.velocity_magnitude
			vel_perifocal = r_unit * vel_magnitude
	
		ORBITS_TYPES.ELIPTIC:
			mean_anomaly = fmod(mean_anomaly, 2.0 * PI)
			if mean_anomaly < 0.0: mean_anomaly += 2.0 * PI
			
			# 2. M -> E (Anomalía Excéntrica)
			var E = _solve_kepler_newton_raphson(mean_anomaly, e)
			
			# 4. Velocidad (v_vec) en el Plano Perifocal (xp_dot, yp_dot)
			var Edot = n / (1.0 - e * cos(E)) # Derivada de E respecto al tiempo
			
			var xp_dot = -a * sin(E) * Edot
			var yp_dot = a * sqrt(1.0 - e*e) * cos(E) * Edot
			vel_perifocal = Vector3(xp_dot, yp_dot, 0.0)
		
		ORBITS_TYPES.HYPERBOLIC:
			# 2. M -> F (Anomalía Excéntrica Hiperbólica)
			var F = _solve_kepler_hyperbolic(mean_anomaly, e) # ¡CORRECCIÓN APLICADA!
			
			# Nota: En hiperbólica, 'a' debe ser usado con valor absoluto
			# Aunque lo calculamos como positivo, aseguramos la definición
			var abs_a = abs(a) 
		
			# Velocidad Hiperbólica (se usa n / (e * cosh(F) - 1.0) para F_dot)
			var F_dot = n / (e * cosh(F) - 1.0)
		
			var xp_dot = -abs_a * sinh(F) * F_dot 
			var yp_dot = abs_a * sqrt(e*e - 1.0) * cosh(F) * F_dot
			vel_perifocal = Vector3(xp_dot, yp_dot, 0.0)
			#if name == "Comet": print(vel_perifocal)
		
		ORBITS_TYPES.PARABOLIC:
			return get_velocity()
			
	#if name=="Comet": print(pos_perifocal)
	return transform.basis * vel_perifocal

func _calculate_influence_radius(M:float, m:float) -> float:
	if not m > 0.0:
		return 0.0
	var a = abs(semi_major_axis)
	var mass_ratio:float = m / M
	if mass_ratio > 0.17: mass_ratio = 0.17
	var r:float = a * pow(mass_ratio, (2.0/5.0))
	if r < 1.0: r=0.1
	if influence_zone.shape is SphereShape3D:
		var shape:SphereShape3D = influence_zone.shape
		shape.radius = r
	influence_zone.disabled = false
	print(name,". Radio de influencia: ",r)
	return r

func _orbiters_filter(node: Node) -> bool:
	return node is OrbitalObject3D

#--------------------------------------- Calculo Orbital ------------------------------------------#
# --- Elementos Orbitales ---
var mu_attractor: float # μ = G * Mass_attractor
var semi_major_axis: float
var eccentricity: float
var inclination: float
## Longitude of the ascending node
var raan: float # Longitud del nodo ascendente (Ω)
var argument_of_periapsis: float # Argumento del periapsis (ω)
var true_anomaly: float # Anomalía verdadera (ν)
var period: float # Período orbital (solo para órbitas cerradas)

var _mean_anomaly_at_t0: float = 0.0 # El offset M0
var _eliptic: bool

# ====================================================================
# --- LÓGICA ORBITAL ---
# ====================================================================

func _calculate_orbital_elements(r_vec: Vector3, v_vec:Vector3, attractor: OrbitalObject3D) -> int:
	if not attractor:
		print(name, ": Cuerpo sin atractor, sin órbita definida.")
		semi_major_axis = INF
		return ORBITS_TYPES.INDETERMINATE
		
	# Calcular mu_attractor a partir de la masa del atractor y G global
	mu_attractor = OrbitalManager.G * attractor.mass
	var r = r_vec.length()
	var v = v_vec.length()
	var mu = mu_attractor

	# 1. Momento Angular Específico (h)
	var h_vec = r_vec.cross(v_vec)
	var h = h_vec.length()
	
	# Caso de orbita Radial, v alineado con r o v es nulo
	const H_MAGNITUDE_TOLERANCE = 0.001
	
	if r * v > 0.0:
		var relative_h = h / (r * v)
		if relative_h < H_MAGNITUDE_TOLERANCE:
			transform = get_parent().transform
			return ORBITS_TYPES.RADIAL
	if v < 1e-6:
		transform = get_parent().transform
		return ORBITS_TYPES.RADIAL
	
	# 2. Vector de Excentricidad (e)
	var e_vec = ((v_vec.cross(h_vec)) / mu) - (r_vec.normalized())
	eccentricity = e_vec.length()
	# Rotar el nodo al plano perifocal
	transform = _calculate_orbital_transform(h_vec, e_vec, attractor)

	# 3. Energía Orbital Específica (epsilon) y Eje Semimayor (a)
	var epsilon = (v*v / 2.0) - (mu / r)
	# Lógica para manejar los tres tipos de órbita basados en epsilon:
	if abs(epsilon) < 1e-6:
		# **Órbita Parabólica (Escape Justo):** a = INF
		semi_major_axis = INF
		eccentricity = 1.0
		print("Órbita Parabólica")
		var dv:float = 0.001
		var result: int
		if _eliptic:
			result = calcule_orbit(r_vec,v_vec * (1.0 + dv))
		else:
			result = calcule_orbit(r_vec,v_vec * (1.0 - dv))
		return result
	elif epsilon < 0:
		# **Órbita Elíptica (Cerrada):** a > 0
		semi_major_axis = -mu / (2.0 * epsilon)
		period = 2.0 * PI * sqrt(pow(semi_major_axis, 3) / mu)
		_eliptic = true
		print(name, ": Órbita Elíptica. Período: ", period, " s, e: ", eccentricity)
	else: # epsilon > 0
		# **Órbita Hiperbólica (Abierta):** a < 0
		semi_major_axis = -mu / (2.0 * epsilon) # Nota: 'a' es negativo  en esta definición hiperbólica
		period = INF # Abierta
		_eliptic = false
		print(name, ": Órbita Hiperbólica. Trayectoria de escape. e=", eccentricity)

	# 4. Inclinación (i)
	inclination = acos(h_vec.z / h)

	# 5. Longitud del Nodo Ascendente (Ω)
	# Vector del nodo ascendente (n_vec)
	var k = Vector3(0, 0, 1) # Vector unitario z
	var n_vec = k.cross(h_vec)
	var n = n_vec.length()
	
	if n == 0:
		# Órbita ecuatorial, Ω no está definido, se asume 0.
		raan = 0.0
	else:
		raan = acos(n_vec.x / n)
		if n_vec.y < 0:
			raan = (2.0 * PI) - raan
	# 6. Argumento del Periapsis (ω)
	if eccentricity == 0:
		# Órbita circular, ω no está definido
		argument_of_periapsis = 0.0
	elif n == 0:
		# --- CASO SINGULAR: ÓRBITA ECUATORIAL (n = 0) ---
		# Usamos el vector de excentricidad directamente, asumiendo RAAN=0
		# Longitud del Periapsis: ω + Ω
		argument_of_periapsis = acos(e_vec.x / eccentricity)
		if e_vec.y < 0:
			argument_of_periapsis = (2.0 * PI) - argument_of_periapsis
	else:
		argument_of_periapsis = acos(n_vec.dot(e_vec) / (n * eccentricity))
		if e_vec.z < 0:
			argument_of_periapsis = (2.0 * PI) - argument_of_periapsis
	
	# 7. Anomalía Verdadera (ν)
	true_anomaly = acos(e_vec.dot(r_vec) / (eccentricity * r))
	
	if r_vec.dot(v_vec) < 0:
		# Si r.v < 0, el cuerpo se acerca al periapsis. nu debe ser negativo para hiperbólicas.
		if eccentricity > 1.0:
			true_anomaly = -true_anomaly # Rango correcto para F (negativo antes del periapsis)
		else:
			true_anomaly = (2.0 * PI) - true_anomaly # Mantiene el rango [0, 2pi] para elípticas
	
	# Calcular M0 (Anomalía Media Inicial)
	_mean_anomaly_at_t0 = _true_to_mean_anomaly(true_anomaly, eccentricity)
	
	if _eliptic:
		return ORBITS_TYPES.ELIPTIC
	return ORBITS_TYPES.HYPERBOLIC

func _calculate_orbital_transform(h_vec: Vector3, e_vec: Vector3, attractor: OrbitalObject3D) -> Transform3D:
	# 1. Ejes del Sistema Perifocal
	var k_axis: Vector3 = h_vec.normalized()  # Z (Normal al plano)
	var i_axis: Vector3 = e_vec.normalized()  # X (Al Periapsis)
	var j_axis: Vector3 = k_axis.cross(i_axis) # Y (Complementario)
	#print(k_axis,i_axis,j_axis)
	# 2. Construir la Basis (Rotación)
	var basis = Basis(i_axis, j_axis, k_axis)
	
	return Transform3D(basis, attractor.position)

# Convierte la Anomalía Verdadera (nu) a Anomalía Media (M)
func _true_to_mean_anomaly(nu: float, e: float) -> float:
	if e == 1.0: 
		return 0.0 # Parabólica no tiene M definido
	
	if e < 1.0: # Órbita Elíptica (nu -> E -> M)
		# 1. nu -> E (Anomalía Excéntrica) usando ATAN2
		var E_y = sin(nu) * sqrt(1.0 - e*e)
		var E_x = cos(nu) + e
		var E = atan2(E_y, E_x)
		
		# Asegurar que E esté en el rango [0, 2PI]
		E = fmod(E, 2.0 * PI)
		if E < 0.0: E += 2.0 * PI
		
		# 2. E -> M (Anomalía Media)
		var M = E - e * sin(E)
		
		# Asegurar que M esté en el rango [0, 2PI]
		M = fmod(M, 2.0 * PI)
		if M < 0.0: M += 2.0 * PI
		
		return M

	else: # Órbita Hiperbólica (e > 1.0): (nu -> F -> M)
		# 1. nu -> F (Anomalía Excéntrica Hiperbólica)
		# Usando la fórmula F = acosh((e + cos(nu)) / (1 + e * cos(nu)))
		var cos_nu = cos(nu)
		var arg = (e + cos_nu) / (1.0 + e * cos_nu)
		
		# acosh(x) = log(x + sqrt(x*x - 1))
		var F_magnitude = log(arg + sqrt(arg * arg - 1.0))
		# El signo de F debe ser el mismo que el signo de nu (o r_vec.dot(v_vec))
		# Como corregimos nu a negativo si r.v < 0, podemos usar nu.
		var F = F_magnitude
		if nu < 0.0: # Si estamos acercándonos al periapsis (nu negativo)
			F = -F_magnitude
		
		# 2. F -> M (Anomalía Media)
		var M = e * sinh(F) - F
		
		return M

func _solve_radial_motion(t_total: float, r0: float, v0: float, mu: float) -> Dictionary:
	
	var time_remaining = t_total
	var r = r0
	var v = v0
	
	# Usaremos el paso de tiempo fijo del motor de Godot para la integración.
	var dt = 0.1
	
	# 🚨 Es crucial que dt sea pequeño, aquí usamos el paso de tiempo del motor
	
	while time_remaining > 0.0:
		var step = min(time_remaining, dt)
		
		# Calcula la aceleración
		var a = -mu / (r * r)
		
		# Integración de Euler (simple)
		r += v * step
		v += a * step
		
		time_remaining -= step
		
		# Evitar r <= 0 (Impacto o Paso Excesivo)
		if r <= 0.0:
			r = 0.0
			v = 0.0
			break
		
	return {
	"position_magnitude": r, 
	"velocity_magnitude": v
	}

func _solve_kepler_newton_raphson(mean_anomaly: float, e: float) -> float:
	
	const MAX_ITERATIONS = 10
	const TOLERANCE = 1e-12
	const MIN_F_PRIME = 0.001 # Nuevo: Mínimo para el denominador
	const MAX_DELTA_E = 1.0   # Nuevo: Máximo paso permitido
	
	var M = fmod(mean_anomaly, 2.0 * PI)
	if M < 0.0:
		M += 2.0 * PI

	# 2. Aproximación Inicial (E = M es un buen punto de partida seguro)
	var E = M
	
	# 3. Bucle de Iteración de Newton-Raphson
	for i in range(MAX_ITERATIONS):
		
		var sin_E = sin(E)
		var cos_E = cos(E)
		
		# La función de Kepler: f(E) = E - e*sin(E) - M
		var f_E = E - e * sin_E - M
		
		# 4. Comprobar la Convergencia (¡Usar f_E para la salida!)
		if abs(f_E) < TOLERANCE:
			break
			
		# La derivada: f'(E) = 1 - e*cos(E)
		var f_prime_E = 1.0 - e * cos_E
		
		# 5. 🚨 Seguridad y Limitación del Denominador
		# Si f'(E) se acerca mucho a cero (problema de alta excentricidad), lo limitamos
		if abs(f_prime_E) < MIN_F_PRIME:
			f_prime_E = MIN_F_PRIME if f_prime_E >= 0.0 else -MIN_F_PRIME
		
		# Cálculo del cambio (delta E)
		var delta_E = f_E / f_prime_E
		
		# 6. 🚨 Limitar el tamaño del paso (para asegurar convergencia)
		if abs(delta_E) > MAX_DELTA_E:
			delta_E = sign(delta_E) * MAX_DELTA_E
		
		# Aplicar la Corrección
		E -= delta_E
		
	# 7. Normalizar el resultado (Mantener entre 0 y 2PI)
	E = fmod(E, 2.0 * PI)
	if E < 0.0:
		E += 2.0 * PI
		
	return E

# Resuelve la Ecuación de Kepler Hiperbólica (M = e*sinh(F) - F) 
func _solve_kepler_hyperbolic(mean_anomaly: float, e: float) -> float:
	
	# Parámetros de Precisión y Límite
	const MAX_ITERATIONS = 15     # Se permite más iteraciones ya que la convergencia puede ser más lenta.
	const TOLERANCE = 1e-12        # Tolerancia para la convergencia
	
	var M = mean_anomaly 
	
	# 1. Aproximación Inicial (Guess F0)
	# Una aproximación común para M grande o e cerca de 1 es usar la misma M.
	# Usaremos una aproximación robusta simple.
	var F = M 
	
	# Una mejor aproximación inicial para F:
	# F = log(2 * M / e + 1.8) (o log(2*M/e + 1) si M es grande, pero M puede ser pequeño)
	if e > 1.0:
		F = log(abs(M / e) + 1.0) # Mejor aproximación para M>0
	
	# Si M es negativo (viaja en la rama opuesta), F también debería serlo.
	if M < 0.0:
		F *= -1.0
	# 2. Bucle de Iteración de Newton-Raphson
	for i in range(MAX_ITERATIONS):
		var sinh_F = sinh(F)
		var cosh_F = cosh(F)
		# La función a resolver: f(F) = e*sinh(F) - F - M
		var f_F = e * sinh_F - F - M
		
		# La derivada: f'(F) = e*cosh(F) - 1
		var f_prime_F = e * cosh_F - 1.0
		
		# Cálculo del cambio (delta F): dF = f(F) / f'(F)
		var delta_F = f_F / f_prime_F
		
		# 3. Comprobar la Convergencia
		if abs(delta_F) < TOLERANCE:
			break
		
		# 4. Aplicar la Corrección
		F -= delta_F
	#print(parent.name,": ",count)
	return F

func _is_eliptic() -> bool:
	return _eliptic

#--------------------------- Fin Calculo Orbital ----------------------------------#

## Returns the body's current orbital velocity, calculated as a Vector3
func get_velocity() -> Vector3:
	var current_time = (Time.get_ticks_msec() / 1000.0 - _initial_time) * OrbitalManager.time_scale
	return _get_velocity_at_time(current_time)

## Returns the eccentricity e of the current orbit as a float. This value determines the shape of the conic section (e.g., e < 1.0 for elliptic, e = 1.0 for parabolic).
func get_eccentricity() -> float:
	return eccentricity

## Returns the orbital period in seconds. Only valid for closed elliptical orbits.
func get_period() -> float:
	return period

## Returns the semi-major axis a of the current orbit as a float. This value determines the size of the orbit and is critical for calculating the period and energy.
func get_semi_major_axis() -> float:
	return semi_major_axis

## Returns the perifocal vector as a Vector3 normalized. This vector defines the X-axis of the body's local orbital frame (perifocal system), pointing toward the periapsis.
func get_perifocal_vector() -> Vector3:
	return transform.basis * Vector3.RIGHT

## Returns the orbital normal vector as a Vector3. This vector defines the Z-axis of the body's local orbital frame (perifocal system).
func get_normal_vector() -> Vector3:
	return transform.basis * Vector3.BACK

## Returns the currently active orbital classification of the body as an ORBITS_TYPES enum value.
func get_orbit_type() -> ORBITS_TYPES:
	return orbit_type

## Returns the current gravitational center of reference (the primary body) as an OrbitalBody3D instance. This is the node the body is currently orbiting.
func get_attractor() -> OrbitalObject3D:
	return attractor

## Registers a new OrbitalBody3D as a child orbiter of this node and sets its initial conditions for the two-body problem. This function performs the necessary transformation to switch the orbiter's frame of reference, setting its attractor property to the current node, and defining its state via new_position and new_velocity vectors relative to the new attractor.
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

## Removes the specified OrbitalBody3D from this node's list of controlled orbiters. This is typically called when an orbiter is exiting the current gravitational sphere of influence (SOI) and transferring to a new attractor. Note that this function only updates the internal list and does not automatically change the orbiter's attractor property.
func remove_orbiter(orbiter:OrbitalObject3D) -> void:
	if orbiter.get_parent() != self : return
	remove_child(orbiter)
	_orbiters.erase(orbiter)
	orbiter_removed.emit(orbiter)

## Returns true if this body currently has at least one satellite/orbiter inside its Sphere of Influence.
func has_orbiters() -> bool:
	return orbiters.size() > 0

## Returns an array containing all bodies currently orbiting this object (inside its Sphere of Influence).
func get_orbiters() -> Array:
	return orbiters

## Initializes and calculates all Classical Orbital Elements (COEs) for the body's new state relative to its current attractor. This function is used when the body enters a new sphere of influence or is instantiated, and it establishes the necessary parameters (e.g., eccentricity, semi-major axis, energy) required for the subsequent propagation of the orbit. It automatically starts the orbital simulation time counter and updates the body's influence radius. Returns the ORBITS_TYPES classification of the trajectory established by the given state vectors.
func calcule_orbit(new_position: Vector3, new_velocity: Vector3) -> ORBITS_TYPES:
	if not attractor:
		print(name, ": Cuerpo sin atractor, cuerpo central.")
		return ORBITS_TYPES.CENTRAL_OBJECT
	
	var o_t:ORBITS_TYPES = _calculate_orbital_elements(new_position, new_velocity, attractor)
	
	if o_t:
		_initial_time = Time.get_ticks_msec() / 1000.0
		influence_radius = _calculate_influence_radius(attractor.mass, mass)
		orbit_changed.emit()
	return o_t

## Calculates the position of the orbital path and returns it as a sequence of coordinates in the current attractor's frame of reference. This method propagates the body's current orbit into a list of points suitable for 3D rendering. The number of points returned is defined by the segments parameter, which controls the graphical resolution of the trajectory path.
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
			# Ángulo máximo de la asíntota (en radianes)
			var nu_max = acos(-1.0 / e) * 0.99
			# Queremos puntos simétricos: desde -nu_max hasta +nu_max
			for i in range(segments + 1):  # +1 para cerrar el último punto si quieres
				var t = float(i) / float(segments)           # 0.0 → 1.0
				var nu = -nu_max + 2.0 * nu_max * t          # ν de -nu_max a +nu_max
				
				var r = a * (e * e - 1.0) / (1.0 + e * cos(nu))
				
				# Posición en el plano orbital (pericentro en X)
				var xp = r * cos(nu)
				var yp = r * sin(nu)
				point = transform.basis * Vector3(xp, yp, 0.0)
				if central or point.length() <= SOI_radius:
					result.append(point)
			return result
	return result

## Returns the relative inclination between this body's orbital plane and the plane of the other_orbiter in radians. This value is the angle between their respective orbital normal vectors. Returns 0.0 if the two orbiters do not share the same gravitational attractor.
func inclination_to(other_orbiter:OrbitalObject3D) -> float:
	if not other_orbiter.attractor == attractor:
		return 0.0
	var other_normal:Vector3 = other_orbiter.get_normal_vector()
	return other_normal.angle_to(get_normal_vector())

## Calculates and returns the nodal axis (or Line of Nodes) between this orbit and the orbit of the other_orbiter as a Vector3. The line of nodes is the vector defined by the intersection of the two orbital planes. Returns Vector3.ZERO if the two orbiters do not share the same gravitational attractor.
func nodal_axis_to(other_orbiter:OrbitalObject3D) -> Vector3:
	if not other_orbiter.attractor == attractor:
		return Vector3.ZERO
	var other_normal:Vector3 = other_orbiter.get_normal_vector()
	return other_normal.cross(get_normal_vector())

## Returns the position of the periapsis (closest point to the attractor) for the current orbit. Returns Vector3.ZERO for circular, parabolic, or invalid orbits.
func get_periapsis() -> Vector3:
	var result:Vector3 = Vector3.ZERO
	var a = semi_major_axis
	var e = eccentricity
	match orbit_type:
		ORBITS_TYPES.ELIPTIC:
			var xp = a * (1 - e)
			result = transform.basis * Vector3(xp, 0.0, 0.0)
			return result
		ORBITS_TYPES.HYPERBOLIC:
			var xp = a * (e * e - 1.0) / (1.0 + e)
			result = transform.basis * Vector3(xp, 0.0, 0.0)
			return result
	return result

## Returns the position of the apoapsis (farthest point from the attractor) for the current orbit. Only valid for elliptical orbits. Returns Vector3.ZERO for all other orbit types.
func get_apoapsis() -> Vector3:
	var result:Vector3 = Vector3.ZERO
	match orbit_type:
		ORBITS_TYPES.ELIPTIC:
			var a = semi_major_axis
			var e = eccentricity
			var xp = a * (-1 - e)
			result = transform.basis * Vector3(xp, 0.0, 0.0)
			return result
	return result

func _on_area_entered(area: Area3D) -> void:
	if not area is OrbitalObject3D:
		return
	var new_orbiter: OrbitalObject3D = area
	if not new_orbiter.orbit_type:
		return
	if new_orbiter.mass >= mass:
		return
	if new_orbiter.attractor == attractor:
		var new_pos:Vector3 = transform.inverse() * new_orbiter.position
		var new_vel:Vector3 = new_orbiter.get_velocity() - get_velocity()
		new_vel = basis.inverse() * new_vel
		
		add_orbiter(new_orbiter, new_pos, new_vel)

		print(new_orbiter.name," entrando en orbita de ",name)
	return

func _on_area_exited(area: Area3D) -> void:
	if not area is OrbitalObject3D:
		return
	if not is_instance_valid(attractor):
		return
	var orbiter:OrbitalObject3D = area
	if not orbiter.orbit_type:
		return
	if not orbiter. attractor == self:
		return
	var new_attractor: OrbitalObject3D = attractor
	var new_pos:Vector3 = transform * orbiter.position
	var new_vel:Vector3 = basis * orbiter.get_velocity()
	new_vel = new_vel + get_velocity()
	
	new_attractor.add_orbiter(orbiter,new_pos, new_vel)
	
	print(area.name," saliendo de la orbita de ", name)
