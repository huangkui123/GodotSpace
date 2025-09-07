extends MultiplayerSpawner

@export var network_player: PackedScene

func _ready():
	multiplayer.peer_connected.connect(spawn_player)


func spawn_player(id: int):
	if not multiplayer.is_server(): return
	
	print("Spawning player for ID:" + str(id))

	var player: Node = network_player.instantiate()
	player.name = str(id)

	get_node(spawn_path).call_deferred("add_child", player)
