extends "res://addons/godot-xr-tools/objects/viewport_2d_in_3d_body.gd"

## Keep 2D pointer input local. Shared business state is synchronized by the
## SpatialWindowStateManager after Server-side validation; raw pointer paths
## are never accepted over RPC.


func _on_pointer_event(event: XRToolsPointerEvent) -> void:
	_handle_pointer_event(multiplayer.get_unique_id(), event)


@rpc("any_peer", "call_remote", "reliable", 0)
func server_receive_pointer_event(_data: Dictionary) -> void:
	# Deliberately ignore legacy raw pointer replication.
	pass
