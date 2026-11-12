extends RefCounted

## Private complete step clips, preserving authored motion without modifying
## imported animation resources, model hierarchy or shared materials.
const COVER := "xiaoshiyangui/xiaoshiyangui_b"
const COVER_BOLTS := "xiaoshiyangui/xiaoshiyangui_c"
const CORE_BOLTS := "zhouxinjigou/dingzi"
const CORE := "zhouxinjigou/zhouxinjigou_a"
const OLD_SAMPLE := CORE + "/xiaoshiyangui_d"
const NEW_SAMPLE := CORE + "/xiaoshiyangui_d_new"
const TOOL := "gongju"
# First meaningful motion supplies installed/prepared positions instead of
# the exploded-view overrides saved in ARSpace.tscn.
const INITIAL_POSITION_STEPS := {
	COVER: 7, COVER_BOLTS: 6, CORE_BOLTS: 9, CORE: 11,
	OLD_SAMPLE: 12, NEW_SAMPLE: 13, TOOL: 5,
}


static func build(rig: Node3D, source: AnimationLibrary) -> AnimationLibrary:
	var library := AnimationLibrary.new()
	var pose: Dictionary = {}
	for path: String in INITIAL_POSITION_STEPS:
		var part := rig.get_node(NodePath(path)) as Node3D
		pose[path] = part.transform
		var reference := source.get_animation("Step%d" % INITIAL_POSITION_STEPS[path])
		for track in reference.get_track_count():
			if _node_path(reference.track_get_path(track)) == path and _component(reference, track) == "position":
				var transform: Transform3D = pose[path]
				transform.origin = reference.track_get_key_value(track, 0)
				pose[path] = transform
	var idle := Animation.new()
	_complete_pose(idle, pose)
	_set_visibility(idle, 0)
	library.add_animation("Idle", idle)
	for step in range(1, 21):
		var clip := source.get_animation("Step%d" % step).duplicate(true) as Animation
		clip.loop_mode = Animation.LOOP_NONE
		for track in range(clip.get_track_count() - 1, -1, -1):
			var path := clip.track_get_path(track)
			var node := _node_path(path)
			# Imported clips repeatedly show unrelated removed parts.
			if str(path).ends_with(":visible"):
				clip.remove_track(track)
			# Step16 parks the replacement at (10,-10,-10) AFTER installation.
			# Preserve its installed pose from Step14 instead.
			elif node == NEW_SAMPLE and (step < 13 or step > 14):
				clip.remove_track(track)
		_complete_pose(clip, pose)
		_set_visibility(clip, step)
		if step in [6, 19]:
			_copy_visibility_cue(source.get_animation("Step%d" % step), clip, TOOL)
		elif step == 11:
			_copy_visibility_cue(source.get_animation("Step11"), clip, CORE + "/zhongxinjigouTips")
		library.add_animation("Step%d" % step, clip)
		# Inherit COMPLETED transforms, independent of user playback history.
		for track in clip.get_track_count():
			var node := _node_path(clip.track_get_path(track))
			if pose.has(node):
				_update_pose(pose, node, clip, track)
	return library


static func _node_path(path: NodePath) -> String:
	return str(path.get_concatenated_names()).trim_suffix("/.")


static func _component(clip: Animation, track: int) -> String:
	match clip.track_get_type(track):
		Animation.TYPE_POSITION_3D: return "position"
		Animation.TYPE_ROTATION_3D: return "quaternion"
		Animation.TYPE_SCALE_3D: return "scale"
		Animation.TYPE_VALUE: return str(clip.track_get_path(track).get_concatenated_subnames())
	return ""


static func _complete_pose(clip: Animation, pose: Dictionary) -> void:
	for node: String in pose:
		var transform: Transform3D = pose[node]
		var values := {"position": transform.origin, "quaternion": transform.basis.get_rotation_quaternion(), "scale": transform.basis.get_scale()}
		var found: Dictionary = {}
		for track in clip.get_track_count():
			if _node_path(clip.track_get_path(track)) != node:
				continue
			var component := _component(clip, track)
			var canonical := "quaternion" if component == "rotation" else component
			if not values.has(canonical):
				continue
			found[canonical] = true
			if clip.track_get_key_count(track) == 0 or clip.track_get_key_time(track, 0) > 0.0:
				clip.track_insert_key(track, 0.0, transform.basis.get_euler() if component == "rotation" else values[canonical])
		for component: String in values:
			if found.has(component):
				continue
			var type: int = {"position": Animation.TYPE_POSITION_3D, "quaternion": Animation.TYPE_ROTATION_3D, "scale": Animation.TYPE_SCALE_3D}[component]
			var track := clip.add_track(type)
			clip.track_set_path(track, NodePath(node))
			clip.track_insert_key(track, 0.0, values[component])


static func _update_pose(pose: Dictionary, node: String, clip: Animation, track: int) -> void:
	var transform: Transform3D = pose[node]
	var value: Variant = clip.track_get_key_value(track, clip.track_get_key_count(track) - 1)
	match _component(clip, track):
		"position": transform.origin = value
		"quaternion": transform.basis = Basis(value as Quaternion).scaled(transform.basis.get_scale())
		"rotation": transform.basis = Basis.from_euler(value as Vector3).scaled(transform.basis.get_scale())
		"scale": transform.basis = Basis(transform.basis.get_rotation_quaternion()).scaled(value as Vector3)
	pose[node] = transform


static func _set_visibility(clip: Animation, step: int) -> void:
	var visibility := {
		COVER: step in [5, 6, 7, 19],
		COVER_BOLTS: step in [6, 7, 19],
		CORE_BOLTS: step in [9, 10, 11, 16, 17, 18],
		CORE: true, # Container for independently visible samples.
		CORE + "/MeshRenderer": step >= 8 and step <= 18,
		OLD_SAMPLE: step >= 8 and step <= 12,
		NEW_SAMPLE: step >= 13 and step <= 18,
		TOOL: step in [2, 6, 9, 17, 19],
		CORE + "/zhongxinjigouTips": step == 11,
		OLD_SAMPLE + "/OldTips": step == 12,
		NEW_SAMPLE + "/NewTips": step in [13, 14],
		"zhouxinjigou/zhouxinjigou_a (1)": false,
	}
	for path: String in visibility:
		var track := clip.add_track(Animation.TYPE_VALUE)
		clip.track_set_path(track, NodePath(path + ":visible"))
		clip.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)
		clip.track_insert_key(track, 0.0, visibility[path])


static func _copy_visibility_cue(source: Animation, target: Animation, node: String) -> void:
	var target_track := target.find_track(NodePath(node + ":visible"), Animation.TYPE_VALUE)
	for track in source.get_track_count():
		if _node_path(source.track_get_path(track)) != node or _component(source, track) != "visible":
			continue
		for key in source.track_get_key_count(track):
			target.track_insert_key(target_track, source.track_get_key_time(track, key), bool(source.track_get_key_value(track, key)))
