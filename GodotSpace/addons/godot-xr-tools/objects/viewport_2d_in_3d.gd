@tool
class_name XRToolsViewport2DIn3D
extends Node3D

const DEBUG_LOGS := false
const WINDOW_TRANSFORM_SYNC_INTERVAL_MSEC := 33
const SERVER_PEER_ID := 1

## XR ToolsViewport 2D in 3D
##
## This script manages a 2D scene rendered as a texture on a 3D quad.
##
## Pointer and keyboard input are mapped into the 2D scene.


## Signal for pointer events
signal pointer_event(event)


## Transparent property
enum TransparancyMode {
	OPAQUE,				## Render opaque
	TRANSPARENT,		## Render transparent
	SCISSOR,			## Render using alpha-scissor
}

## Viewport Update Mode
enum UpdateMode {
	UPDATE_ONCE, 		## Update once (redraw triggered if set again to UPDATE_ONCE)
	UPDATE_ALWAYS,		## Update on every frame
	UPDATE_THROTTLED,	## Update at throttled rate
}


# The following dirty flags are private (leading _) to suppress them in the
# generated documentation. Unfortunately gdlint complaints on private constants
# (see https://github.com/Scony/godot-gdscript-toolkit/issues/223). Until this
# is fixed we suppress the rule.
# gdlint: disable=constant-name

# State dirty flags
const _DIRTY_NONE			:= 0x0000	# Everything up to date
const _DIRTY_MATERIAL		:= 0x0001	# Material needs update
const _DIRTY_SCENE			:= 0x0002	# Scene needs update
const _DIRTY_SIZE			:= 0x0004	# Viewport size needs update
const _DIRTY_ALBEDO			:= 0x0008	# Albedo texture needs update
const _DIRTY_UPDATE			:= 0x0010	# Update mode needs update
const _DIRTY_TRANSPARENCY	:= 0x0020	# Transparency needs update
const _DIRTY_ALPHA_SCISSOR	:= 0x0040	# Alpha scissor needs update
const _DIRTY_UNSHADED		:= 0x0080	# Shade mode needs update
const _DIRTY_FILTERED		:= 0x0100	# Filter mode needs update
const _DIRTY_SURFACE		:= 0x0200	# Surface material needs update
const _DIRTY_REDRAW			:= 0x0400	# Redraw required
const _DIRTY_ALL			:= 0x07FF	# All dirty

# Default layer of 1:static-world, 21:pointable, 23:ui-objects
const DEFAULT_LAYER := 0b0000_0000_0101_0000_0000_0000_0000_0001


# Physics property group
@export_group("Physics")

## Physical screen size property
@export var screen_size : Vector2 = Vector2(3.0, 2.0): set = set_screen_size

## Viewport collision enabled property
@export var enabled : bool = true: set = set_enabled

## Collision layer
@export_flags_3d_physics var collision_layer : int = DEFAULT_LAYER: set = set_collision_layer

# Content property group
@export_group("Content")

## Scene property
@export var scene : PackedScene: set = set_scene

## Viewport size property
@export var viewport_size : Vector2 = Vector2(300.0, 200.0): set = set_viewport_size

## Update Mode property
@export var update_mode : UpdateMode = UpdateMode.UPDATE_ALWAYS: set = set_update_mode

## Update throttle property
@export var throttle_fps : float = 30.0

# Input property group
@export_group("Input")

## Allow physical keyboard input to viewport
@export var input_keyboard : bool = true

## Allow gamepad input to viewport
@export var input_gamepad : bool = false

## Allow dragging window with grip button
@export var allow_window_drag : bool = true

## Grip action name for dragging
@export var grip_action : String = "grip"

## Minimum grip pressure to start dragging
@export var grip_threshold : float = 0.7

# Rendering property group
@export_group("Rendering")

## Custom material template
@export var material : StandardMaterial3D = null: set = set_material

## Transparent property
@export var transparent : TransparancyMode = TransparancyMode.TRANSPARENT: set = set_transparent

## Alpha Scissor Threshold property (ignored when custom material provided)
var alpha_scissor_threshold : float = 0.25: set = set_alpha_scissor_threshold

## Unshaded flag (ignored when custom material provided)
var unshaded : bool = false: set = set_unshaded

## Filtering flag (ignored when custom material provided)
var filter : bool = true: set = set_filter


var is_ready : bool = false
var scene_node : Node
var scene_properties_keys: PackedStringArray = []
var scene_properties : Array[Dictionary] = []
# Needed to apply custom properties of the scene before it is instanced, as these are set on ready,
# But at this point in time the scene is not instanced yet
var scene_proxy_configuration: Dictionary = {}
var viewport_texture : ViewportTexture
var time_since_last_update : float = 0.0
var _screen_material : StandardMaterial3D
var _dirty := _DIRTY_ALL

# Dragging state variables
var _is_dragging : bool = false
var _drag_controller : XRController3D = null
var _drag_start_controller_transform : Transform3D = Transform3D.IDENTITY
var _drag_start_window_transform : Transform3D = Transform3D.IDENTITY
var _drag_offset_transform : Transform3D = Transform3D.IDENTITY
var _drag_pointer : Node3D = null
var _last_window_transform_sync_msec : int = 0

# Child visibility tracking
var _child_visible : bool = false
var _visibility_tracked_child : Node = null

# Window positioning tracking
var _was_visible_last_frame : bool = false


# Add support for is_xr_class on XRTools classes
func is_xr_class(p_name : String) -> bool:
	return p_name == "XRToolsViewport2DIn3D"


# Called when the node enters the scene tree for the first time.
func _ready():
	is_ready = true

	# Listen for pointer events on the screen body
	$StaticBody3D.connect("pointer_event", _on_pointer_event)

	# Update enabled based on visibility
	visibility_changed.connect(_on_visibility_changed)

	# Apply physics properties
	_update_screen_size()
	_update_enabled()
	_update_collision_layer()

	# Update the render objects
	_update_render()
	
	# Initialize child visibility tracking
	_update_child_visibility_tracking()
	
	# Initialize visibility state tracking
	_was_visible_last_frame = is_visible_in_tree() and _child_visible


# Provide custom property information
func _get_property_list() -> Array[Dictionary]:
	# Select visibility of properties
	var show_alpha_scissor := not material and transparent == TransparancyMode.SCISSOR
	var show_unshaded := not material
	var show_filter := not material

	var extra_properties : Array[Dictionary] = [
		{
			name = "Rendering",
			type = TYPE_NIL,
			usage = PROPERTY_USAGE_GROUP
		},
		{
			name = "alpha_scissor_threshold",
			type = TYPE_FLOAT,
			usage = PROPERTY_USAGE_DEFAULT if show_alpha_scissor else PROPERTY_USAGE_NO_EDITOR,
			hint = PROPERTY_HINT_RANGE,
			hint_string = "0.0,1.0"
		},
		{
			name = "unshaded",
			type = TYPE_BOOL,
			usage = PROPERTY_USAGE_DEFAULT if show_unshaded else PROPERTY_USAGE_NO_EDITOR
		},
		{
			name = "filter",
			type = TYPE_BOOL,
			usage = PROPERTY_USAGE_DEFAULT if show_filter else PROPERTY_USAGE_NO_EDITOR
		},
		# Store the scene property keys on the disk, so that even before the scene is loaded we
		# know about the custom properties
		{
			name = "scene_properties_keys",
			type = TYPE_PACKED_STRING_ARRAY,
			usage = PROPERTY_USAGE_NO_EDITOR | PROPERTY_USAGE_STORAGE
		}
	]

	# Add all the custom properties of the subscene so they show up in the editor
	if scene_properties_keys.size() > 0:
		extra_properties.append_array(scene_properties)

	return extra_properties


# Forward setting and getting of custom properties of the child scene
func _get(property: StringName) -> Variant:
	if scene_properties_keys.has(property):

		var return_value: Variant = null

		# If our scene is already instanced then get the property directly
		if is_instance_valid(scene_node):
			return_value = scene_node.get(property)
		# If it is not instanced, we use the proxy configuration
		elif scene_proxy_configuration.has(property):
			return_value = scene_proxy_configuration[property]

		# Special handling is required for NodePaths, as they are relative to the scene
		if return_value is NodePath and !return_value.is_absolute():
			var path_string : String = str(return_value)
			# Remove the additional leading ../../
			return_value = NodePath(path_string.substr(6, -1))

		return return_value
	# Keep normal behaviour
	return null


func _set(property: StringName, value: Variant):
	if scene_properties_keys.has(property):

		# Special handling is required for NodePaths, as they are relative to the scene
		if value is NodePath and !value.is_absolute():
			# Add the additional leading ../../
			value = NodePath("../../" + str(value))

		# If our scene is already instanced then set the property directly
		if is_instance_valid(scene_node):
			scene_node.set(property, value)
		# If it is not instanced yet, store it to the proxy configuration,
		# which will get applied on scene load
		else:
			scene_proxy_configuration[property] = value
		return true
	# Keep normal behaviour
	return false


# Allow revert of custom properties
func _property_can_revert(property : StringName) -> bool:
	match property:
		"alpha_scissor_threshold":
			return true
		"unshaded":
			return true
		"filter":
			return true
		_:
			return false


# Provide revert values for custom properties
func _property_get_revert(property : StringName): # Variant
	match property:
		"alpha_scissor_threshold":
			return 0.25
		"unshaded":
			return false
		"filter":
			return true


# When the scene_node changes, update the property list
func _update_scene_property_list():
	scene_properties = []
	scene_properties_keys = []
	if is_instance_valid(scene_node):

		# If the scene is queued for deletion, clear the scene proxy configuration
		if scene_node.is_queued_for_deletion():
			scene_proxy_configuration = {}
		else:
			# Extract relevant properties of the provided scene to display in the editor (forwarded)
			var node_script: Script = scene_node.get_script() as Script
			if node_script:
				var all_properties := node_script.get_script_property_list()

				# Join this with the custom property list of the object created by the script
				if scene_node.has_method("_get_property_list"):
					all_properties.append_array(scene_node.call("_get_property_list"))

				for property in all_properties:
					# Filter out only the properties that are supposed to be stored, or are used for grouping
					if property["usage"] & (PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_GROUP \
					| PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_SUBGROUP):
						scene_properties.append(property)
						scene_properties_keys.append(property["name"])

	notify_property_list_changed()


## Get the 2D scene instance
func get_scene_instance():
	return scene_node


## Connect a 2D scene signal
func connect_scene_signal(which : String, callback : Callable, flags : int = 0):
	if scene_node:
		scene_node.connect(which, callback, flags)


# Handle pointer event from screen-body
func _on_pointer_event(event: XRToolsPointerEvent):
	if not is_inside_tree() \
			or multiplayer == null \
			or not is_instance_valid(event) \
			or not is_instance_valid(event.pointer) \
			or not is_instance_valid(event.target):
		return
	if multiplayer.is_server():
		# 如果自己就是服务器，直接处理事件
		pass
		# _handle_pointer_event(multiplayer.get_unique_id(), event)
	else:
		# 如果是客户端，把事件信息发给服务器
		var controller = _get_controller_from_pointer(event.pointer)
		var grip_value : float = 0
		if controller:
			grip_value = controller.get_float(grip_action)
		var data = {
			"event_type": event.event_type,
			"pointer_name": event.pointer.get_path(),
			"target_name": event.target.get_path(),
			"position": event.position,
			"last_position": event.last_position,
			"grip_value": grip_value
		}
		# print("客户端发送点击事件到服务器: ", data)
		rpc_id(1, "server_receive_pointer_event", data)
		_handle_pointer_event(multiplayer.get_unique_id(), event, grip_value)


@rpc("any_peer")
func server_receive_pointer_event(data: Dictionary):
	# 这里一定只会在服务器跑
	var sender_id = multiplayer.get_remote_sender_id()

	var pointer_node : Node3D = null
	if data.has("pointer_name") and data.pointer_name != NodePath(""):
		pointer_node = get_node_or_null(data.pointer_name)
	var target_node : Node3D = null
	if data.has("target_name") and data.target_name != NodePath(""):
		target_node = get_node_or_null(data.target_name)

	# 如果想在服务器端复现事件，可以构造一个假的 XRToolsPointerEvent
	var fake_event = XRToolsPointerEvent.new(
		data.get("event_type", XRToolsPointerEvent.Type.PRESSED),
		pointer_node,
		target_node,
		data.get("position", Vector3.ZERO),
		data.get("last_position", Vector3.ZERO),
	)

	if data.get("event_type") == 2:
		if DEBUG_LOGS: print("服务器收到来自 %s 的点击事件: %s" % [sender_id, data.get("event_type", "unknown")])
		if DEBUG_LOGS: print("pointer_node: ", pointer_node)
		if DEBUG_LOGS: print("target_node: ", target_node)

	_handle_pointer_event(sender_id, fake_event, data.get("grip_value", 0.0))

@rpc("any_peer", "call_remote", "unreliable")
func server_receive_window_transform(window_transform: Transform3D):
	_receive_window_transform_from_client(window_transform, false)


@rpc("any_peer", "call_remote", "reliable")
func server_receive_window_transform_reliable(window_transform: Transform3D):
	_receive_window_transform_from_client(window_transform, true)


@rpc("authority", "call_remote", "unreliable")
func client_receive_window_transform(window_transform: Transform3D):
	_apply_synced_window_transform(window_transform)


@rpc("authority", "call_remote", "reliable")
func client_receive_window_transform_reliable(window_transform: Transform3D):
	_apply_synced_window_transform(window_transform)


func _receive_window_transform_from_client(window_transform: Transform3D, reliable: bool):
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	_apply_synced_window_transform(window_transform)

	for peer_id in multiplayer.get_peers():
		var id := int(peer_id)
		if id == sender_id:
			continue
		if reliable:
			rpc_id(id, "client_receive_window_transform_reliable", window_transform)
		else:
			rpc_id(id, "client_receive_window_transform", window_transform)


func _apply_synced_window_transform(window_transform: Transform3D):
	if _is_dragging:
		return

	global_transform = window_transform
	_last_drag_position = window_transform.origin

func _handle_pointer_event(player_id: int, event: XRToolsPointerEvent, grip_value: float):
	# 记录窗口被点击的位置（当按下时）
	# 只有在没有窗口正在被拖动时才设置焦点，避免拖动时切换焦点
	if event.event_type == XRToolsPointerEvent.Type.PRESSED:
		# 使用 Global 单例记录当前窗口的位置
		if Global and Global.has_method("set_last_clicked_window"):
			# 检查是否有窗口正在被拖动
			var has_dragging_window = Global.dragging_window != null
			if not has_dragging_window:
				Global.set_last_clicked_window(self)
	
	# Handle dragging functionality if enabled
	if allow_window_drag:
		_handle_drag_input(event, grip_value)
	
	pointer_event.emit(event)


# Handler for input events
func _input(event):
	# Map keyboard events to the viewport if enabled
	if input_keyboard and (event is InputEventKey or event is InputEventShortcut):
		$Viewport.push_input(event)
		return

	# Map gamepad events to the viewport if enable
	if input_gamepad and (event is InputEventJoypadButton or event is InputEventJoypadMotion):
		$Viewport.push_input(event)
		return


# Process event
func _process(delta):
	# Update dragging if active
	
	# Process screen refreshing
	if Engine.is_editor_hint():
		# Perform periodic material refreshes to handle the user modifying the
		# material properties in the editor
		time_since_last_update += delta
		if time_since_last_update > 1.0:
			time_since_last_update = 0.0
			# Trigger material refresh
			_dirty = _DIRTY_MATERIAL
			_update_render()
	elif update_mode == UpdateMode.UPDATE_THROTTLED:
		# Perform throttled updates of the viewport
		var frame_time = 1.0 / throttle_fps
		time_since_last_update += delta
		if time_since_last_update > frame_time:
			time_since_last_update = 0.0
			# Trigger update
			$Viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	elif not _is_dragging and not allow_window_drag:
		# Only disable process if we're not dragging and drag is disabled
		set_process(false)


# Handle visibility changed
func _on_visibility_changed():
	# Fire visibility changed in scene
	if scene_node:
		scene_node.propagate_notification(
			CanvasItem.NOTIFICATION_VISIBILITY_CHANGED)


	# Update collision and rendering based on visibility
	_update_enabled()
	_dirty |= _DIRTY_UPDATE
	_update_render()


# 将窗口定位到上一个被点击的窗口的右侧
func _position_window_relative_to_last_clicked():
	if Global and Global.has_method("get_new_window_transform"):
		var new_transform = Global.get_new_window_transform()
		# 只在有有效的上一个窗口位置时才应用新位置
		if Global.last_clicked_window_position != Vector3.ZERO:
			global_transform = new_transform
			if DEBUG_LOGS: print("✅ 窗口已定位到上一个被点击窗口的右侧: ", global_position)


# Update child visibility tracking
func _update_child_visibility_tracking():
	# Try to get the target child node
	var target_child = _get_target_child_node()
	
	# Disconnect previous target if the tracked child changed
	if is_instance_valid(_visibility_tracked_child) and _visibility_tracked_child != target_child:
		if _visibility_tracked_child.has_signal("visibility_changed"):
			if _visibility_tracked_child.visibility_changed.is_connected(_on_child_visibility_changed):
				_visibility_tracked_child.visibility_changed.disconnect(_on_child_visibility_changed)
	
	_visibility_tracked_child = target_child
	
	if target_child and target_child.has_signal("visibility_changed"):
		# Connect to the visibility changed signal
		if not target_child.visibility_changed.is_connected(_on_child_visibility_changed):
			target_child.visibility_changed.connect(_on_child_visibility_changed)
		# Update current visibility state
		_child_visible = target_child.visible

	else:
		# If no target child, assume visible
		_child_visible = true
	
	# Update collision state
	if is_ready:
		_update_enabled()


# Get the target child node (Viewport.get_child(0).get_child(0))
func _get_target_child_node():
	if not $Viewport or $Viewport.get_child_count() == 0:
		return null
	
	var first_child = $Viewport.get_child(0)
	if not first_child or first_child.get_child_count() == 0:
		return null
	
	return first_child.get_child(0)


# Handle child visibility changes
func _on_child_visibility_changed():
	var target_child = _get_target_child_node()
	if target_child:
		_child_visible = target_child.visible
		_update_enabled()


## Set screen size property
func set_screen_size(new_size: Vector2):
	screen_size = new_size
	if is_ready:
		_update_screen_size()


## Set enabled property
func set_enabled(is_enabled: bool):
	enabled = is_enabled
	if is_ready:
		_update_enabled()


## Set collision layer property
func set_collision_layer(new_layer: int):
	collision_layer = new_layer
	if is_ready:
		_update_collision_layer()


## Set scene property
func set_scene(new_scene: PackedScene):
	scene = new_scene
	_dirty |= _DIRTY_SCENE
	if is_ready:
		_update_render()


## Set viewport size property
func set_viewport_size(new_size: Vector2):
	viewport_size = new_size
	_dirty |= _DIRTY_SIZE
	if is_ready:
		_update_render()


## Set update mode property
func set_update_mode(new_update_mode: UpdateMode):
	update_mode = new_update_mode
	_dirty |= _DIRTY_UPDATE
	if is_ready:
		_update_render()


## Set material property
func set_material(new_material: StandardMaterial3D):
	material = new_material
	notify_property_list_changed()
	_dirty |= _DIRTY_MATERIAL
	if is_ready:
		_update_render()


## Set transparent property
func set_transparent(new_transparent: TransparancyMode):
	transparent = new_transparent
	notify_property_list_changed()
	_dirty |= _DIRTY_TRANSPARENCY
	if is_ready:
		_update_render()


## Set the alpha scisser threshold
func set_alpha_scissor_threshold(new_threshold: float):
	alpha_scissor_threshold = new_threshold
	_dirty |= _DIRTY_ALPHA_SCISSOR
	if is_ready:
		_update_render()


## Set the unshaded property
func set_unshaded(new_unshaded : bool):
	unshaded = new_unshaded
	_dirty |= _DIRTY_UNSHADED
	if is_ready:
		_update_render()


## Set filter property
func set_filter(new_filter: bool):
	filter = new_filter
	_dirty |= _DIRTY_FILTERED
	if is_ready:
		_update_render()


# Screen size update handler
func _update_screen_size():
	$Screen.mesh.size = screen_size
	$StaticBody3D.screen_size = screen_size
	$StaticBody3D/CollisionShape3D.shape.size = Vector3(
			screen_size.x,
			screen_size.y,
			0.02)


# Enabled update handler
func _update_enabled():
	if Engine.is_editor_hint():
		return

	# 如果窗口从隐藏变为可见，设置新的位置
	var is_currently_visible = _child_visible
	if DEBUG_LOGS: print("窗口可见性状态: ", is_currently_visible, _was_visible_last_frame)
	if is_currently_visible and not _was_visible_last_frame:
		_position_window_relative_to_last_clicked()
	
	# 更新可见性状态
	_was_visible_last_frame = is_currently_visible

	$StaticBody3D/CollisionShape3D.disabled = !enabled or not is_visible_in_tree() or not _child_visible


# Collision layer update handler
func _update_collision_layer():
	$StaticBody3D.collision_layer = collision_layer


# This complex function processes the render dirty flags and performs the
# minimal number of updates to get the render objects into the correct state.
func _update_render():
	# Handle material change
	if _dirty & _DIRTY_MATERIAL:
		_dirty &= ~_DIRTY_MATERIAL

		# Construct the new screen material
		if material:
			# Copy custom material
			_screen_material = material.duplicate()
		else:
			# Create new local material
			_screen_material = StandardMaterial3D.new()

			# Disable culling
			_screen_material.params_cull_mode = StandardMaterial3D.CULL_DISABLED

			# Ensure local material is configured
			_dirty |= _DIRTY_TRANSPARENCY |	\
					_DIRTY_ALPHA_SCISSOR |	\
					_DIRTY_UNSHADED |		\
					_DIRTY_FILTERED

		# Ensure new material renders viewport onto surface
		_dirty |= _DIRTY_ALBEDO | _DIRTY_SURFACE

	# If we have no screen material then skip everything else
	if not _screen_material:
		return

	# Handle scene change
	if _dirty & _DIRTY_SCENE:
		_dirty &= ~_DIRTY_SCENE

		# Out with the old
		if is_instance_valid(scene_node):
			if scene_node.property_list_changed.is_connected(_update_scene_property_list):
				scene_node.property_list_changed.disconnect(_update_scene_property_list)
			$Viewport.remove_child(scene_node)
			scene_node.queue_free()
			_update_scene_property_list()

		# In with the new
		if scene:
			# Instantiate provided scene
			scene_node = scene.instantiate()
			_update_scene_property_list()
			scene_node.property_list_changed.connect(_update_scene_property_list)

			# Apply the scene proxy configuration on the first load
			for key in scene_properties_keys:
				if scene_proxy_configuration.has(key):
					scene_node.set(key, scene_proxy_configuration[key])

			# Finally add it to the scene, so values are available in _ready
			$Viewport.add_child(scene_node)
			
			# Update child visibility tracking after scene is added
			_update_child_visibility_tracking()
		elif $Viewport.get_child_count() == 1:
			# Use already-provided scene
			scene_node = $Viewport.get_child(0)
			
			# Update child visibility tracking for existing scene
			_update_child_visibility_tracking()

		# Ensure the new scene is rendered at least once
		_dirty |= _DIRTY_REDRAW

	# Handle viewport size change
	if _dirty & _DIRTY_SIZE:
		_dirty &= ~_DIRTY_SIZE

		# Set the viewport size
		$Viewport.size = viewport_size
		$StaticBody3D.viewport_size = viewport_size

		# Update our viewport texture, it will have changed
		_dirty |= _DIRTY_ALBEDO

	# Handle albedo change:
	if _dirty & _DIRTY_ALBEDO:
		_dirty &= ~_DIRTY_ALBEDO

		# Set the screen material to use the viewport for the albedo channel
		viewport_texture = $Viewport.get_texture()
		_screen_material.albedo_texture = viewport_texture

	# Handle update mode change
	if _dirty & _DIRTY_UPDATE:
		_dirty &= ~_DIRTY_UPDATE

		# Apply update rules
		if Engine.is_editor_hint():
			# Update once. Process function used for editor refreshes
			$Viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
			set_process(true)
		elif update_mode == UpdateMode.UPDATE_ONCE or not is_visible_in_tree():
			# Update once. Process function may be needed for dragging
			$Viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
			set_process(allow_window_drag)
		elif update_mode == UpdateMode.UPDATE_ALWAYS:
			# Update always. Process function may be needed for dragging
			$Viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			set_process(allow_window_drag)
		elif update_mode == UpdateMode.UPDATE_THROTTLED:
			# Update once. Process function triggers periodic refresh
			$Viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
			set_process(true)

	# Handle transparency update
	if _dirty & _DIRTY_TRANSPARENCY:
		_dirty &= ~_DIRTY_TRANSPARENCY

		# If using a temporary material then update transparency
		if _screen_material and not material:
			# Set the transparancy mode
			match transparent:
				TransparancyMode.OPAQUE:
					_screen_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
				TransparancyMode.TRANSPARENT:
					_screen_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				TransparancyMode.SCISSOR:
					_screen_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR

		# Set the viewport background transparency mode and force a redraw
		$Viewport.transparent_bg = transparent != TransparancyMode.OPAQUE
		_dirty |= _DIRTY_REDRAW

	# Handle alpha scissor update
	if _dirty & _DIRTY_ALPHA_SCISSOR:
		_dirty &= ~_DIRTY_ALPHA_SCISSOR

		# If using a temporary material with alpha-scissor then update
		if _screen_material and not material and transparent == TransparancyMode.SCISSOR:
			_screen_material.params_alpha_scissor_threshold = alpha_scissor_threshold

	# Handle unshaded update
	if _dirty & _DIRTY_UNSHADED:
		_dirty &= ~_DIRTY_UNSHADED

		# If using a temporary material then update the shading mode and force a redraw
		if _screen_material and not material:
			_screen_material.shading_mode = (
				BaseMaterial3D.SHADING_MODE_UNSHADED if unshaded else
				BaseMaterial3D.SHADING_MODE_PER_PIXEL)
			#_dirty |= _DIRTY_REDRAW

	# Handle filter update
	if _dirty & _DIRTY_FILTERED:
		_dirty &= ~_DIRTY_FILTERED

		# If using a temporary material then update the filter mode and force a redraw
		if _screen_material and not material:
			_screen_material.texture_filter = (
				BaseMaterial3D.TEXTURE_FILTER_LINEAR if filter else
				BaseMaterial3D.TEXTURE_FILTER_NEAREST)
			#_dirty |= _DIRTY_REDRAW

	# Handle surface material update
	if _dirty & _DIRTY_SURFACE:
		_dirty &= ~_DIRTY_SURFACE

		# Set the screen to render using the new screen material
		$Screen.set_surface_override_material(0, _screen_material)

	# Handle forced redraw of the viewport
	if _dirty & _DIRTY_REDRAW:
		_dirty &= ~_DIRTY_REDRAW

		# Force a redraw of the viewport
		if Engine.is_editor_hint() or update_mode == UpdateMode.UPDATE_ONCE:
			$Viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


# Handle dragging input
func _handle_drag_input(event : XRToolsPointerEvent, grip_value: float):
	# Get the controller from the pointer
	var controller = _get_controller_from_pointer(event.pointer)
	if not controller:
		return
	
	# Get current grip value
	var is_grip_pressed = grip_value >= grip_threshold
	# if multiplayer.is_server():
	# 	print("grip_value: ", grip_value)
	
	match event.event_type:
		XRToolsPointerEvent.Type.ENTERED:
			# Pointer entered, but don't start dragging yet
			pass
			
		XRToolsPointerEvent.Type.MOVED:
			# If we're dragging, update the window position
			if _is_dragging and _drag_controller == controller:
				_update_drag_position(event.position)
		
		XRToolsPointerEvent.Type.EXITED:
			# If this was our dragging pointer, stop dragging
			if _is_dragging and _drag_controller == controller:
				_stop_dragging()
	
	# Check grip state changes regardless of event type
	if is_grip_pressed and not _is_dragging and (
		event.event_type == XRToolsPointerEvent.Type.ENTERED or
		event.event_type == XRToolsPointerEvent.Type.MOVED):
		# Start dragging
		_start_dragging(controller, event.pointer, event.position)
	elif not is_grip_pressed and _is_dragging and _drag_controller == controller:
		# Stop dragging
		_stop_dragging()


# Get controller from pointer node
func _get_controller_from_pointer(pointer : Node3D):
	# Try to find controller in the pointer's hierarchy
	var current = pointer
	while current:
		if current is XRController3D:
			return current as XRController3D
		current = current.get_parent()
	
	# If not found directly, try using XRHelpers
	return XRHelpers.get_xr_controller(pointer)


# Start dragging the window
func _start_dragging(controller : XRController3D, pointer : Node3D, position : Vector3):
	_is_dragging = true
	_drag_controller = controller
	_drag_pointer = pointer
	
	# 在Global中记录当前正在被拖动的窗口
	if Global:
		Global.dragging_window = self
	
	# 锁定pointer的target到当前窗口，防止射线切换到其他窗口
	if pointer and pointer.has_method("set"):
		pointer.target = $StaticBody3D
	
	# Record the initial transforms
	_drag_start_controller_transform = controller.global_transform
	_drag_start_window_transform = global_transform
	
	# Calculate the offset transform from controller to window
	# This represents how the window is positioned relative to the controller when grabbing starts
	_drag_offset_transform = _drag_start_controller_transform.affine_inverse() * _drag_start_window_transform
	
	# Optionally provide haptic feedback
	if controller.has_method("pulse"):
		controller.pulse(0.3, 0.1)

var _last_drag_position : Vector3 = Vector3.ZERO

# Update window position during drag
func _update_drag_position(current_position : Vector3):
	if not _is_dragging:
		return

	var current_controller_transform = _drag_controller.global_transform
	var new_transform = global_transform
	new_transform.origin = (current_controller_transform * _drag_offset_transform).origin

	# 使用线性插值平滑位置变化
	if _last_drag_position != Vector3.ZERO:
		new_transform.origin = _last_drag_position.lerp(new_transform.origin, 0.3) # 调整插值因子以控制平滑程度

	# 让窗口朝向XRCamera3D
	var camera = get_tree().root.find_child("XRCamera3D", true, false)
	if camera:
		var to_camera = (camera.global_transform.origin - new_transform.origin).normalized()
		var up = Vector3.UP
		# 让Z轴朝向摄像机
		var new_basis = Basis()
		new_basis.z = to_camera
		new_basis.x = up.cross(to_camera).normalized()
		new_basis.y = to_camera.cross(new_basis.x).normalized()
		# 保留原来的缩放
		var scale = new_transform.basis.get_scale()
		new_basis = new_basis.scaled(scale)
		new_transform.basis = new_basis

	global_transform = new_transform

	# 更新上一次的位置
	_last_drag_position = new_transform.origin
	_sync_window_transform_to_server(false)


# Stop dragging the window
func _stop_dragging():
	if not _is_dragging:
		return
		
	_sync_window_transform_to_server(true)
	_is_dragging = false
	
	# 解锁pointer的target
	if _drag_pointer and _drag_pointer.has_method("set"):
		_drag_pointer.target = null
	
	# 在Global中清除正在被拖动的窗口记录
	if Global and Global.dragging_window == self:
		Global.dragging_window = null
	
	# Optionally provide haptic feedback
	if _drag_controller and _drag_controller.has_method("pulse"):
		_drag_controller.pulse(0.2, 0.05)
	
	# Clear dragging state
	_drag_controller = null
	_drag_pointer = null
	_drag_start_controller_transform = Transform3D.IDENTITY
	_drag_start_window_transform = Transform3D.IDENTITY
	_drag_offset_transform = Transform3D.IDENTITY


func _sync_window_transform_to_server(reliable: bool):
	if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
		return

	var now_msec := Time.get_ticks_msec()
	if not reliable and now_msec - _last_window_transform_sync_msec < WINDOW_TRANSFORM_SYNC_INTERVAL_MSEC:
		return

	_last_window_transform_sync_msec = now_msec
	if reliable:
		rpc_id(SERVER_PEER_ID, "server_receive_window_transform_reliable", global_transform)
	else:
		rpc_id(SERVER_PEER_ID, "server_receive_window_transform", global_transform)
