extends RefCounted

## Missing Unity UI sprites retained as empty Node3Ds by the scene migration.
## Audited from WorkEffect.prefab in SpaceProject V2.0.2, 2026-11-12.
## Keep the imported basis/Z; restore RectTransform anchored X/Y (mirrored X).
const SymbolShader := preload("res://Assets/ARSpace/Shader/guidance_symbol.gdshader")
# Unity ARSpace + dashiyangui.prefab both place the authored cabinet at Y=0.18.
# Godot's cabinet is at Y=0. Keep its accepted placement and move its guides.
const AUTHORED_CABINET := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.18, 0.1))
const TEXTURES := [
	preload("res://Assets/Modern UI Pack/Textures/Border/Radial/1024px/Radial Outline 1024px - 6x.png"),
	preload("res://Assets/Sprite/Arrow Right.png"),
	preload("res://Assets/ARSpace/Textures/二期交互修改（0808）/Rectangle 1388.png"),
	preload("res://Assets/Modern UI Pack/Textures/Icon/Navigation/Subtract.png"),
]
# Step, canvas, anchored position, image position, image size, texture, tint.
const SYMBOLS := [
	[6, "Canvas", Vector2(0.239, 1.7138), Vector3(0, 0, 0), Vector2(100, 100), 0, Color(0.9607843, 0, 0, 1)],
	[6, "Canvas (1)", Vector2(0.239, 1.7117), Vector3(0, 0, 0), Vector2(100, 100), 0, Color(0.9607843, 0, 0, 1)],
	[6, "Canvas (2)", Vector2(0.239, 1.6219), Vector3(0, 0, 0), Vector2(100, 100), 0, Color(0.9607843, 0, 0, 1)],
	[6, "Canvas (3)", Vector2(0.239, 1.4582), Vector3(0, 0, 0), Vector2(100, 100), 0, Color(0.9607843, 0, 0, 1)],
	[6, "Canvas (4)", Vector2(0.239, 1.357), Vector3(0, 0, 0), Vector2(100, 100), 0, Color(0.9607843, 0, 0, 1)],
	[6, "Canvas (5)", Vector2(0.239, 1.357), Vector3(0, 0, 0), Vector2(100, 100), 0, Color(0.9607843, 0, 0, 1)],
	[6, "Canvas (6)", Vector2(0.239, 1.433), Vector3(0, 0, 0), Vector2(100, 100), 0, Color(0.9607843, 0, 0, 1)],
	[6, "Canvas (7)", Vector2(0.239, 1.616), Vector3(0, 0, 0), Vector2(100, 100), 0, Color(0.9607843, 0, 0, 1)],
	[9, "Canvas", Vector2(0.323, 1.6354), Vector3(0, 0, 0), Vector2(50, 50), 0, Color(0.9607843, 0, 0, 1)],
	[9, "Canvas (1)", Vector2(0.323, 1.634), Vector3(0, 0, 0), Vector2(50, 50), 0, Color(0.9607843, 0, 0, 1)],
	[9, "Canvas (2)", Vector2(0.323, 1.5429), Vector3(0, 0, 0), Vector2(50, 50), 0, Color(0.9607843, 0, 0, 1)],
	[9, "Canvas (3)", Vector2(0.32299998, 1.4549), Vector3(0, 0, 0), Vector2(50, 50), 0, Color(0.9607843, 0, 0, 1)],
	[9, "Canvas (4)", Vector2(0.323, 1.4566), Vector3(0, 0, 0), Vector2(50, 50), 0, Color(0.9607843, 0, 0, 1)],
	[9, "Canvas (5)", Vector2(0.323, 1.5445), Vector3(0, 0, 0), Vector2(50, 50), 0, Color(0.9607843, 0, 0, 1)],
	[12, "Canvas", Vector2(-0.2265, 1.61), Vector3(0, 0, 0), Vector2(50, 50), 1, Color(1, 0.18431373, 0, 1)],
	[12, "Canvas (1)", Vector2(-0.2265, 1.61), Vector3(0, 0, 0), Vector2(115, 50), 3, Color(0.9607843, 0, 0, 1)],
	[12, "Canvas (2)", Vector2(-0.2265, 1.609), Vector3(0, 0, 0), Vector2(50, 50), 1, Color(1, 0.16078432, 0, 1)],
	[13, "Canvas (1)", Vector2(-0.198, 1.618), Vector3(3.5, 11.8, -46.2), Vector2(115, 50), 2, Color(0.9607843, 0, 0, 1)],
	[13, "Canvas (1)2", Vector2(-0.20170003, 1.7519001), Vector3(0, 0, 0), Vector2(115, 50), 3, Color(0.9607843, 0, 0, 1)],
	[16, "Canvas (2)", Vector2(0.356, 1.651), Vector3(0, 0, 4), Vector2(50, 50), 0, Color(1, 0, 0, 1)],
	[17, "Canvas", Vector2(0.32400003, 1.6335), Vector3(0, 0, 0), Vector2(50, 50), 0, Color(0.9607843, 0, 0, 1)],
	[17, "Canvas (1)", Vector2(0.324, 1.6335), Vector3(0, 0, 0), Vector2(50, 50), 0, Color(0.9607843, 0, 0, 1)],
	[17, "Canvas (2)", Vector2(0.324, 1.5461), Vector3(0, 0, 0), Vector2(50, 50), 0, Color(0.9607843, 0, 0, 1)],
	[17, "Canvas (3)", Vector2(0.324, 1.4542), Vector3(0, 0, 0), Vector2(50, 50), 0, Color(0.9607843, 0, 0, 1)],
	[17, "Canvas (4)", Vector2(0.324, 1.4523), Vector3(0, 0, 0), Vector2(50, 50), 0, Color(0.9607843, 0, 0, 1)],
	[17, "Canvas (5)", Vector2(0.324, 1.5439), Vector3(0, 0, 0), Vector2(50, 50), 0, Color(0.9607843, 0, 0, 1)],
	[19, "Canvas", Vector2(0.239, 1.71), Vector3(0, 0, 0), Vector2(100, 100), 0, Color(0.9607843, 0, 0, 1)],
	[19, "Canvas (1)", Vector2(0.239, 1.713), Vector3(0, 0, 0), Vector2(100, 100), 0, Color(0.9607843, 0, 0, 1)],
	[19, "Canvas (2)", Vector2(0.239, 1.622), Vector3(0, 0, 0), Vector2(100, 100), 0, Color(0.9607843, 0, 0, 1)],
	[19, "Canvas (3)", Vector2(0.239, 1.457), Vector3(0, 0, 0), Vector2(100, 100), 0, Color(0.9607843, 0, 0, 1)],
	[19, "Canvas (4)", Vector2(0.239, 1.3574), Vector3(0, 0, 0), Vector2(100, 100), 0, Color(0.9607843, 0, 0, 1)],
	[19, "Canvas (5)", Vector2(0.239, 1.355), Vector3(0, 0, 0), Vector2(100, 100), 0, Color(0.9607843, 0, 0, 1)],
	[19, "Canvas (6)", Vector2(0.239, 1.432), Vector3(0, 0, 0), Vector2(100, 100), 0, Color(0.9607843, 0, 0, 1)],
	[19, "Canvas (7)", Vector2(0.239, 1.616), Vector3(0, 0, 0), Vector2(100, 100), 0, Color(0.9607843, 0, 0, 1)],
]


static func install(work_effect: Node3D) -> void:
	for row: Array in SYMBOLS:
		var path := "WorkList1/WorkInfo%d/ZonePoint/Model/%s" % [row[0], row[1]]
		var canvas := work_effect.get_node_or_null(path) as Node3D
		if canvas == null:
			push_error("Missing cabinet guidance anchor: " + path)
			continue
		var image := canvas.get_node_or_null("Image") as Node3D
		if image == null or image.has_node("RestoredSymbol"):
			continue
		var anchored: Vector2 = row[2]
		canvas.position.x = anchored.x
		canvas.position.y = anchored.y
		image.position = row[3]
		var mesh := MeshInstance3D.new()
		mesh.name = "RestoredSymbol"
		var quad := QuadMesh.new()
		quad.size = row[4]
		mesh.mesh = quad
		var material := ShaderMaterial.new()
		material.shader = SymbolShader
		material.set_shader_parameter("symbol_texture", TEXTURES[row[5]])
		material.set_shader_parameter("symbol_color", row[6])
		mesh.material_override = material
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		image.add_child(mesh)
	# Only these original TextMesh numbers were enabled. The M6 steps' old
	# 51..56 labels were disabled in Unity; do not revive those incorrect labels.
	for step in [6, 19]:
		for index in 8:
			var parent_name := "New Text" if index == 0 else "New Text (%d)" % index
			var path := "WorkList1/WorkInfo%d/ZonePoint/Model/%s" % [step, parent_name]
			var anchor := work_effect.get_node_or_null(path) as Node3D
			if anchor == null or anchor.has_node("RestoredNumber"):
				continue
			var label := Label3D.new()
			label.name = "RestoredNumber"
			label.text = str(51 + index)
			label.rotation.y = PI
			label.pixel_size = 0.1
			label.font_size = 60
			label.outline_size = 4
			label.modulate = Color(1.0, 0.835294, 0.0)
			anchor.add_child(label)
	# Step12 alone retained the default millimetre-sized, backward Label3D.
	var press_label := work_effect.get_node_or_null("WorkList1/WorkInfo12/ZonePoint/Model/New Text/Label3D") as Label3D
	if press_label != null:
		press_label.rotation.y = PI
		press_label.pixel_size = 0.2
		press_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		press_label.modulate = Color.YELLOW
	# Instruction text must remain legible where it extends over the cabinet rim.
	for label: Label3D in work_effect.get_node("WorkList1").find_children("*", "Label3D", true, false):
		label.no_depth_test = true
	align_to_cabinet(work_effect)


static func align_to_cabinet(work_effect: Node3D) -> void:
	var rig := work_effect.get_node_or_null("../dashiyangui") as Node3D
	if rig == null:
		return
	var correction := work_effect.transform.affine_inverse() * rig.transform * AUTHORED_CABINET.affine_inverse() * work_effect.transform
	# Preparation/return routes 1,2,20 refer to cabin locations, not the cabinet.
	for step in range(3,20):
		var branch := work_effect.get_node_or_null("WorkList1/WorkInfo%d" % step) as Node3D
		if branch == null:
			continue
		if not branch.has_meta("authored_guidance_transform"):
			branch.set_meta("authored_guidance_transform", branch.transform)
		var authored: Transform3D = branch.get_meta("authored_guidance_transform")
		branch.transform = correction * authored
