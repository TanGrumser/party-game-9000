extends Node

# Dedicated server network handler (autoload as "ServerNetwork")
# Connects to Bun WebSocket server and handles game messages

signal connected()
signal disconnected()
signal player_joined(player_id: String, player_name: String)
signal player_left(player_id: String)
signal ball_shot_received(player_id: String, direction: Vector2, power: float)
signal ball_death_received(player_id: String, ball_id: String)
signal ball_respawn_received(ball_id: String, spawn_pos: Vector2)
signal game_started(lobby_id: String, players: Array)
signal level_started(next_level: String, players: Array)

const DEFAULT_WS_URL = "ws://localhost:3000/ws"

var _socket: WebSocketPeer
var _lobby_id: String = ""
var _connected: bool = false
var _players: Array = []  # [{id, name}, ...]

func _ready() -> void:
	_socket = WebSocketPeer.new()

func _process(_delta: float) -> void:
	if _socket == null:
		return

	var state = _socket.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED:
		if _connected:
			print("[ServerNetwork] Connection lost")
			_connected = false
			disconnected.emit()
		return

	_socket.poll()

	state = _socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		while _socket.get_available_packet_count() > 0:
			var packet = _socket.get_packet()
			_handle_message(packet.get_string_from_utf8())

func connect_to_relay(lobby_id: String = "") -> void:
	"""Connect to Bun server as the dedicated game server for a lobby."""
	_lobby_id = lobby_id

	# Get lobby from command line args if not provided
	# Check both regular args and user args (after --)
	if _lobby_id.is_empty():
		var all_args = OS.get_cmdline_args() + OS.get_cmdline_user_args()
		for i in range(all_args.size()):
			if all_args[i] == "--lobby" and i + 1 < all_args.size():
				_lobby_id = all_args[i + 1]
				print("[ServerNetwork] Found lobby ID from args: %s" % _lobby_id)
				break

	if _lobby_id.is_empty():
		print("[ServerNetwork] ERROR: No lobby ID provided")
		return

	var url = "%s?lobby=%s&name=__GAME_SERVER__&server=true" % [DEFAULT_WS_URL, _lobby_id]
	print("[ServerNetwork] Connecting to relay: %s" % url)

	var error = _socket.connect_to_url(url)
	if error != OK:
		print("[ServerNetwork] Failed to connect: %d" % error)

func _handle_message(message: String) -> void:
	var data = JSON.parse_string(message)
	if data == null:
		print("[ServerNetwork] Failed to parse: %s" % message)
		return

	var msg_type = data.get("type", "")

	match msg_type:
		"welcome":
			_connected = true
			_players = data.get("players", [])
			print("[ServerNetwork] Connected to lobby %s with %d players" % [_lobby_id, _players.size()])
			connected.emit()

		"server_start":
			# Bun tells us to start the game with these players
			var players = data.get("players", [])
			_players = players
			print("[ServerNetwork] Game start signal received with %d players" % players.size())
			game_started.emit(_lobby_id, players)

		"player_joined":
			var player_id = data.get("playerId", "")
			var player_name = data.get("playerName", "")
			_players.append({"id": player_id, "name": player_name})
			print("[ServerNetwork] Player joined: %s (%s)" % [player_name, player_id])
			player_joined.emit(player_id, player_name)

		"player_left":
			var player_id = data.get("playerId", "")
			_players = _players.filter(func(p): return p.get("id") != player_id)
			print("[ServerNetwork] Player left: %s" % player_id)
			player_left.emit(player_id)

		"ball_shot":
			var player_id = data.get("playerId", "")
			var dir_data = data.get("direction", {})
			var direction = Vector2(dir_data.get("x", 0), dir_data.get("y", 0))
			var power = data.get("power", 0.0)
			print("[ServerNetwork] Ball shot from %s" % player_id)
			ball_shot_received.emit(player_id, direction, power)

		"ball_death":
			var player_id = data.get("playerId", "")
			var ball_id = data.get("ballId", "")
			print("[ServerNetwork] Ball death: %s" % ball_id)
			ball_death_received.emit(player_id, ball_id)

		"ball_respawn":
			var ball_id = data.get("ballId", "")
			var pos_data = data.get("spawnPosition", {})
			var spawn_pos = Vector2(pos_data.get("x", 0), pos_data.get("y", 0))
			print("[ServerNetwork] Ball respawn: %s at %s" % [ball_id, spawn_pos])
			ball_respawn_received.emit(ball_id, spawn_pos)

		"level_started":
			var next_level = data.get("nextLevel", "")
			var players = data.get("players", [])
			print("[ServerNetwork] Level started: %s with %d players" % [next_level, players.size()])
			level_started.emit(next_level, players)

func send_game_state(balls: Array) -> void:
	"""Broadcast game state to all clients."""
	if not _connected:
		return

	var data = {
		"type": "game_state",
		"balls": balls,
		"timestamp": Time.get_ticks_msec()
	}
	_socket.send_text(JSON.stringify(data))

func send_ball_death(ball_id: String) -> void:
	if not _connected:
		return
	var data = {
		"type": "ball_death",
		"ballId": ball_id,
		"playerId": "__SERVER__"
	}
	_socket.send_text(JSON.stringify(data))

func send_ball_respawn(ball_id: String, spawn_pos: Vector2) -> void:
	if not _connected:
		return
	var data = {
		"type": "ball_respawn",
		"ballId": ball_id,
		"spawnPosition": {"x": spawn_pos.x, "y": spawn_pos.y},
		"playerId": "__SERVER__"
	}
	_socket.send_text(JSON.stringify(data))

func send_goal_reached() -> void:
	if not _connected:
		return
	var data = {
		"type": "goal_reached",
		"playerId": "__SERVER__"
	}
	_socket.send_text(JSON.stringify(data))
	print("[ServerNetwork] send_goal_reached")

func get_players() -> Array:
	return _players

func get_lobby_id() -> String:
	return _lobby_id

func is_relay_connected() -> bool:
	return _connected
