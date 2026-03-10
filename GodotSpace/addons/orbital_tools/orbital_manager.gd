extends Node
# Constante Gravitacional Universal G en m 3 kg−1 s−2
# El valor dependerá de tus unidades de distancia.
# Si usas metros y kilogramos (Sistema SI), G ≈ 6.674e-11
# Si usas kilómetros y kilogramos, G ≈ 6.674e-20 (o debes ajustar las masas).
# Usaremos una unidad más conveniente para juegos (ej: la Tierra tiene masa 5.972e24 kg)
# 真实的G值
const G: float = 0.000000000066743
var time_scale: float = 0.1
var simulation_time: float = 0.1

func _process(delta: float) -> void:
	simulation_time += delta * time_scale
