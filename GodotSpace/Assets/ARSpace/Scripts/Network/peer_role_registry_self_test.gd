extends SceneTree

const TOKEN_ENV: String = "GODOTSPACE_GROUND_VR_TOKEN"
const ROLE_PC_GROUND: String = "pc_ground"
const ROLE_GROUND_VR: String = "ground_vr"
const ROLE_SKY: String = "sky"

var _failures: Array[String] = []
var _previous_token: String = ""
var _rejections: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var network_handler := root.get_node_or_null("NetworkHandler")
	_expect(network_handler != null, "NetworkHandler autoload must exist.")
	if network_handler == null:
		_finish()
		return

	_previous_token = OS.get_environment(TOKEN_ENV)
	OS.unset_environment(TOKEN_ENV)
	if not network_handler.peer_role_request_rejected.is_connected(_on_role_rejected):
		network_handler.peer_role_request_rejected.connect(_on_role_rejected)
	network_handler.call("_reset_peer_roles", true)
	_expect(str(network_handler.call("get_peer_role", 1)) == ROLE_PC_GROUND, "Peer 1 must remain the PC Ground authority.")
	_expect(bool(network_handler.call("can_peer_annotate", 1)), "PC Ground must retain local annotation permission.")

	var first_ground := str(network_handler.call("_assign_requested_role", 7, ROLE_GROUND_VR, ""))
	var competing_ground := str(network_handler.call("_assign_requested_role", 8, ROLE_GROUND_VR, ""))
	_expect(first_ground == ROLE_GROUND_VR, "The first approved Ground VR request should fill the unique slot.")
	_expect(competing_ground == "unknown", "A second Ground VR request must remain unregistered.")
	_expect(bool(network_handler.call("can_peer_annotate", 7)), "The Server-assigned Ground VR peer should annotate.")
	_expect(not bool(network_handler.call("can_peer_annotate", 8)), "A rejected Ground VR claimant must not annotate.")
	_expect(_has_rejection(8, "ground_vr_slot_occupied"), "The competing Ground VR request needs an explicit rejection reason.")

	var attempted_role_switch := str(network_handler.call("_assign_requested_role", 8, ROLE_GROUND_VR, ""))
	_expect(attempted_role_switch == "unknown", "A peer must not change its rejected role with a later request.")
	var forged_pc_ground := str(network_handler.call("_assign_requested_role", 9, ROLE_PC_GROUND, ""))
	_expect(forged_pc_ground == "unknown", "A Client request for PC Ground must remain unregistered.")
	_expect(not bool(network_handler.call("can_peer_annotate", 9)), "A forged PC Ground request must not grant annotation permission.")

	network_handler.call("_remove_peer_role", 7)
	var replacement_ground := str(network_handler.call("_assign_requested_role", 10, ROLE_GROUND_VR, ""))
	_expect(replacement_ground == ROLE_GROUND_VR, "Disconnecting Ground VR should release its unique slot.")

	var first_sky := str(network_handler.call("_assign_requested_role", 20, ROLE_SKY, ""))
	var competing_sky := str(network_handler.call("_assign_requested_role", 21, ROLE_SKY, ""))
	_expect(first_sky == ROLE_SKY, "The first valid Sky request should fill the unique slot.")
	_expect(int(network_handler.call("get_sky_peer_id")) == 20, "The Sky query should return the authoritative peer.")
	_expect(competing_sky == "unknown", "A second Sky request must remain unregistered.")
	_expect(_has_rejection(21, "sky_slot_occupied"), "A second Sky request needs the sky_slot_occupied reason.")
	network_handler.call("_remove_peer_role", 20)
	_expect(int(network_handler.call("get_sky_peer_id")) == 0, "Disconnecting Sky should release the unique slot.")
	var replacement_sky := str(network_handler.call("_assign_requested_role", 22, ROLE_SKY, ""))
	_expect(replacement_sky == ROLE_SKY, "A replacement Sky should receive the released slot.")
	_expect(int(network_handler.call("get_sky_peer_id")) == 22, "The Sky query should follow the replacement peer.")

	OS.set_environment(TOKEN_ENV, "test-pairing-token")
	network_handler.call("_reset_peer_roles", true)
	var bad_token_role := str(network_handler.call("_assign_requested_role", 11, ROLE_GROUND_VR, "wrong-token"))
	var authenticated_role := str(network_handler.call("_assign_requested_role", 12, ROLE_GROUND_VR, "test-pairing-token"))
	_expect(bad_token_role == "unknown", "An invalid pairing token must remain unregistered.")
	_expect(authenticated_role == ROLE_GROUND_VR, "A matching pairing token should receive the Ground VR slot.")
	_expect(not bool(network_handler.call("can_peer_annotate", 11)), "Invalid-token peers must remain unable to annotate.")
	_expect(bool(network_handler.call("can_peer_annotate", 12)), "Authenticated Ground VR should be allowed to annotate.")

	var duplicate_ground_snapshot := {
		1: ROLE_PC_GROUND,
		12: ROLE_GROUND_VR,
		13: ROLE_GROUND_VR,
	}
	_expect(
		not bool(network_handler.call("_validate_peer_role_snapshot", duplicate_ground_snapshot)),
		"Clients must reject a role snapshot containing multiple Ground VR peers."
	)
	var duplicate_sky_snapshot := {
		1: ROLE_PC_GROUND,
		12: ROLE_GROUND_VR,
		20: ROLE_SKY,
		21: ROLE_SKY,
	}
	_expect(
		not bool(network_handler.call("_validate_peer_role_snapshot", duplicate_sky_snapshot)),
		"Clients must reject a role snapshot containing multiple Sky peers."
	)

	network_handler.call("_reset_peer_roles", false)
	_restore_token()
	_finish()


func _restore_token() -> void:
	if _previous_token.is_empty():
		OS.unset_environment(TOKEN_ENV)
	else:
		OS.set_environment(TOKEN_ENV, _previous_token)


func _on_role_rejected(peer_id: int, requested_role: String, reason: String) -> void:
	_rejections.append({
		"peer_id": peer_id,
		"requested_role": requested_role,
		"reason": reason,
	})


func _has_rejection(peer_id: int, reason: String) -> bool:
	for rejection in _rejections:
		if int(rejection.get("peer_id", 0)) == peer_id \
				and str(rejection.get("reason", "")) == reason:
			return true
	return false


func _finish() -> void:
	if _failures.is_empty():
		print("Peer role registry self-test passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
