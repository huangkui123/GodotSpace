extends XRToolsMovementProvider

## Keeps the non-colliding XR player at a stable height. XRTools samples the
## world's gravity before invoking movement providers, so this business-layer
## provider clears it without changing the vendored player-body implementation.

@export var order: int = 100
@export_range(0.0, 1.0, 0.01) var stop_input_threshold: float = 0.1


func physics_pre_movement(_delta: float, player_body: XRToolsPlayerBody) -> void:
	if player_body != null:
		player_body.gravity = Vector3.ZERO


func physics_movement(
	_delta: float,
	player_body: XRToolsPlayerBody,
	disabled: bool
) -> bool:
	if disabled \
			or player_body == null \
			or player_body.ground_control_velocity.length() >= stop_input_threshold:
		return false
	# XRTools normally decelerates through ground drag after moving the body,
	# which produces a short coast. The ghost player has no ground contact, so
	# stop its horizontal velocity before movement is applied in this frame.
	var up_direction := player_body.up_player.normalized()
	player_body.velocity = up_direction * player_body.velocity.dot(up_direction)
	return false
