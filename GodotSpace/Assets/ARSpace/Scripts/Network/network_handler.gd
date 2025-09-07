extends Node

const IP_ADDRESS: String = "localhost"
const PORT: int = 42069

signal network_ready

var peer: ENetMultiplayerPeer

func _ready():
	multiplayer.connected_to_server.connect(_on_connected_to_server)

func start_server():
	peer = ENetMultiplayerPeer.new()
	peer.create_server(PORT)
	multiplayer.multiplayer_peer = peer
	print("服务器已启动...")
	network_ready.emit()


func start_client():
	peer = ENetMultiplayerPeer.new()
	peer.create_client(IP_ADDRESS, PORT)
	multiplayer.multiplayer_peer = peer
	print("客户端正在连接到 ", IP_ADDRESS)
	
func _on_connected_to_server():
	print("已成功连接到服务器！")
	network_ready.emit()
