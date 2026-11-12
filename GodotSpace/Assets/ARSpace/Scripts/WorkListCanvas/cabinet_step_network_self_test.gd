extends SceneTree

const State := preload("res://Assets/ARSpace/Scripts/WorkListCanvas/shared_work_step_state.gd")
const Controller := preload("res://Assets/ARSpace/Scenes/SpaceBox.gd")
const Cabinet := preload("res://Assets/ARSpace/Prefabs/UI/MaterialCanvas/dashiyangui.prefab.tscn")
const CorePath := NodePath("zhouxinjigou/zhouxinjigou_a")
var branches: Array[Dictionary] = []
var failures: Array[String] = []

class Authority extends Node:
	func can_peer_control_work_steps(_peer_id: int) -> bool:
		return true

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var server := ENetMultiplayerPeer.new()
	var port := 0
	for candidate in range(43420,43440):
		if server.create_server(candidate,3,3) == OK:
			port = candidate
			break
	if port == 0:
		push_error("Unable to bind work-step test port")
		quit(1)
		return
	var s := _branch(server)
	s.state.request_work_step(15)
	var client := ENetMultiplayerPeer.new()
	_expect(client.create_client("127.0.0.1",port) == OK,"first client starts")
	var c := _branch(client)
	await _wait_step(15)
	for b in branches: b.rig.anim_player.advance(1.1)
	_expect(c.state.request_work_step(16),"client requests next step during insertion")
	await _wait_step(16)
	_check_core(Vector3(-0.976,0,0),"interrupted insertion settles on all peers")
	var late := ENetMultiplayerPeer.new()
	_expect(late.create_client("127.0.0.1",port) == OK,"late client starts")
	var l := _branch(late)
	await _wait_step(16)
	_check_core(Vector3(-0.976,0,0),"late join restores inserted core")
	_expect(l.state.request_work_step(12),"second client requests reverse navigation")
	await _wait_step(12)
	_check_core(Vector3(-0.3,0,0.5),"reverse navigation restores withdrawn core")
	var revision: int = s.state.get_state_revision()
	c.state.request_work_step(12)
	for i in 200:
		if int(s.state.get_state_revision()) > revision: break
		await create_timer(0.01).timeout
	_expect(int(s.state.get_state_revision()) > revision,"same-step replay reaches server")
	s.state.request_worklist_visibility(false)
	await _wait_step(0)
	for b in branches:
		_expect(not b.rig.anim_player.is_playing(),"closing stops every animation")
		_expect(not b.rig.get_node("xiaoshiyangui/xiaoshiyangui_b").visible,"closing hides parts")
	s.state.request_worklist_visibility(true)
	await _wait_step(12)
	late.close()
	_remove_branch(l)
	await create_timer(0.1).timeout
	var reconnect := ENetMultiplayerPeer.new()
	_expect(reconnect.create_client("127.0.0.1",port) == OK,"client reconnects")
	_branch(reconnect)
	await _wait_step(12)
	_check_core(Vector3(-0.3,0,0.5),"reconnect restores task pose")
	s.state.request_work_step(20)
	await _wait_step(20)
	for b in branches:
		_expect(not b.rig.get_node("zhouxinjigou/zhouxinjigou_a/MeshRenderer").visible,"final step removes core guide")
	for b in branches.duplicate(): _remove_branch(b)
	await process_frame
	for failure in failures: push_error(failure)
	print("CABINET STEP NETWORK TEST ","PASS" if failures.is_empty() else "FAIL"," (server, two clients, interruption, replay, late join, reconnect, close)")
	quit(0 if failures.is_empty() else 1)

func _branch(peer: ENetMultiplayerPeer) -> Dictionary:
	var branch := Node3D.new()
	branch.name = "Peer%d" % Time.get_ticks_usec()
	root.add_child(branch)
	var api := SceneMultiplayer.new()
	api.multiplayer_peer = peer
	set_multiplayer(api,branch.get_path())
	var authority := Authority.new()
	authority.name = "Authority"
	branch.add_child(authority)
	var rig := Cabinet.instantiate()
	branch.add_child(rig)
	var controller := Controller.new()
	controller.dashiyangui = rig
	var effects := Node3D.new()
	for step in range(1,21):
		var info := Node3D.new()
		info.name = "WorkInfo%d" % step
		effects.add_child(info)
	var shell := Node3D.new()
	shell.name = "SpaceBox"
	controller.add_child(shell)
	var effect_root := Node3D.new()
	effect_root.name = "WorkEffect"
	shell.add_child(effect_root)
	effects.name = "WorkList1"
	effect_root.add_child(effects)
	controller.worklist1 = effects
	var state := State.new()
	state.name = "State"
	state.peer_authority_path = NodePath("../Authority")
	state.work_step_state_changed.connect(controller._on_shared_work_step_state_changed)
	branch.add_child(state)
	var record := {"node":branch,"api":api,"peer":peer,"state":state,"rig":rig,"controller":controller}
	branches.append(record)
	return record

func _wait_step(step: int) -> void:
	for i in 250:
		var ready := true
		for b in branches:
			if int(b.rig.get_active_step()) != step: ready = false
		if ready: return
		await create_timer(0.01).timeout
	_expect(false,"all peers reach step%d" % step)

func _check_core(position: Vector3, message: String) -> void:
	for b in branches: _expect(b.rig.get_node(CorePath).position.is_equal_approx(position),message)

func _remove_branch(b: Dictionary) -> void:
	b.state.work_step_state_changed.disconnect(b.controller._on_shared_work_step_state_changed)
	b.controller.free()
	b.peer.close()
	root.remove_child(b.node)
	set_multiplayer(null, NodePath("/root/" + str(b.node.name)))
	b.node.queue_free()
	branches.erase(b)

func _expect(value: bool, message: String) -> void:
	if not value: failures.append(message)
