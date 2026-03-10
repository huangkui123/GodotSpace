extends Control

@export var toggle_label_button: Button
@export var toggle_orbit_button: Button
@export var planets: Array[OrbitalObject3D]

var _labels_visible: bool = true
var _orbits_visible: bool = true

func _ready() -> void:
	if toggle_label_button:
		toggle_label_button.pressed.connect(_on_toggle_label_pressed)
		toggle_label_button.text = "隐藏星球名称"
	if toggle_orbit_button:
		toggle_orbit_button.pressed.connect(_on_toggle_orbit_pressed)
		toggle_orbit_button.text = "隐藏轨道"

func _on_toggle_label_pressed() -> void:
	_labels_visible = !_labels_visible
	for planet in planets:
		for child in planet.get_children():
			if child is Label3D:
				child.label_enabled = _labels_visible
	toggle_label_button.text = "隐藏星球名称" if _labels_visible else "显示星球名称"

func _on_toggle_orbit_pressed() -> void:
	_orbits_visible = !_orbits_visible
	for planet in planets:
		var orbit_node = planet.get_parent().get_node_or_null(planet.name + "Orbit")
		if orbit_node:
			orbit_node.visible = _orbits_visible
		else:
			print("找不到轨道节点：", planet.name + "Orbit")
	toggle_orbit_button.text = "隐藏轨道" if _orbits_visible else "显示轨道"
