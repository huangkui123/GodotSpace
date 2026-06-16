extends MultiplayerSpawner

@export var network_player: PackedScene

func _ready():
	multiplayer.peer_connected.connect(spawn_player)
	multiplayer.peer_disconnected.connect(remove_player)


func spawn_player(id: int):
	if not multiplayer.is_server(): return

	var parent := get_node(spawn_path)
	var player_name := str(id)
	var existing_player := parent.get_node_or_null(player_name)
	if existing_player != null:
		parent.remove_child(existing_player)
		existing_player.queue_free()

	var player: Node = network_player.instantiate()
	player.name = player_name

	parent.call_deferred("add_child", player)

func remove_player(id: int) -> void:
	if not multiplayer.is_server(): return

	var parent := get_node(spawn_path)
	var player := parent.get_node_or_null(str(id))
	if player != null:
		player.queue_free()
