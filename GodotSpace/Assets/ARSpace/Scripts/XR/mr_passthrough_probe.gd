extends Node

## A local, temporary blank-frame comparison. Hide drawing, not nodes or
## processing: XR tracking, networking, collisions and animations keep running.
signal finished

enum Mode { BLANK, HIDE_CABINET, ONLY_CABINET }

var duration: float = 5.0
var active: bool = false
var _mode: Mode = Mode.BLANK
var _scene: Node
var _geometry: Dictionary = {}
var _canvas: Dictionary = {}
var _timer: SceneTreeTimer


func start(scene: Node, mode: Mode = Mode.BLANK) -> bool:
	if active or not is_instance_valid(scene) or not scene.is_inside_tree():
		return false
	if mode < Mode.BLANK or mode > Mode.ONLY_CABINET:
		return false
	if mode != Mode.BLANK:
		var found := false
		for cabinet in get_tree().get_nodes_in_group("independent_cabinet_visuals"):
			if cabinet == scene or scene.is_ancestor_of(cabinet):
				found = true
		if not found:
			return false
	_scene = scene
	_mode = mode
	active = true
	_apply(scene)
	get_tree().node_added.connect(_node_added)
	_timer = get_tree().create_timer(duration)
	_timer.timeout.connect(finish)
	print("MR blank-frame probe started: geometry=", _geometry.size(),
		" canvas=", _canvas.size(), " transparent_bg=", scene.get_viewport().transparent_bg,
		" mode=", Mode.keys()[_mode])
	return true


func _apply(node: Node) -> void:
	if node.get_viewport() == _scene.get_viewport() and _should_hide(node):
		if node is GeometryInstance3D and not _geometry.has(node):
			_geometry[node] = node.layers
			node.layers = 0
		elif node is CanvasItem and not _canvas.has(node):
			_canvas[node] = node.visible
			node.visible = false
	for child in node.get_children():
		_apply(child)


func _should_hide(node: Node) -> bool:
	if _mode == Mode.BLANK:
		return true
	var in_cabinet := false
	var ancestor := node
	while ancestor != null:
		if ancestor.is_in_group("independent_cabinet_visuals"):
			in_cabinet = true
			break
		if ancestor == _scene:
			break
		ancestor = ancestor.get_parent()
	return in_cabinet if _mode == Mode.HIDE_CABINET else not in_cabinet


func _node_added(node: Node) -> void:
	_apply_added.call_deferred(weakref(node))


func _apply_added(reference: WeakRef) -> void:
	var node := reference.get_ref() as Node
	if active and is_instance_valid(node) and _scene.is_ancestor_of(node):
		_apply(node)


func finish() -> void:
	if not active:
		return
	active = false
	if _timer != null and _timer.timeout.is_connected(finish):
		_timer.timeout.disconnect(finish)
	_timer = null
	if get_tree() != null and get_tree().node_added.is_connected(_node_added):
		get_tree().node_added.disconnect(_node_added)
	for geometry in _geometry:
		if is_instance_valid(geometry):
			geometry.layers = _geometry[geometry]
	for canvas in _canvas:
		if is_instance_valid(canvas):
			canvas.visible = _canvas[canvas]
	_geometry.clear()
	_canvas.clear()
	print("MR blank-frame probe finished; original drawing restored")
	finished.emit()


func _exit_tree() -> void:
	finish()
