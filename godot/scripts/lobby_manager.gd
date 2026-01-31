extends Node

# Autoload singleton for lobby management
# Add to Project Settings > Autoload as "LobbyManager"

signal lobby_created(lobby_id: String)
signal lobby_checked(lobby_id: String, exists: bool, player_count: int)
signal lobby_joined(lobby_id: String, player_id: String, is_host: bool)
signal connection_error(message: String)
signal player_joined(player_id: String, player_name: String, is_host: bool)
signal player_left(player_id: String, player_name: String)
signal player_ready_changed(player_id: String, is_ready: bool)
signal all_players_ready()
signal game_started(host_id: String)
signal returned_to_lobby()
signal game_state_received(state: Dictionary)
signal ball_shot_received(player_id: String, shot_data: Dictionary)

const DEFAULT_SERVER_URL = "http://localhost:3000/api"
const DEFAULT_WS_URL = "ws://localhost:3000/ws"

var _server_url: String = DEFAULT_SERVER_URL
var _ws_url: String = DEFAULT_WS_URL

var _http_request: HTTPRequest
var _socket: WebSocketPeer
var _player_name: String = ""
var _player_id: String = ""
var _lobby_id: String = ""
var _is_host: bool = false
var _connected: bool = false
var _players: Array = []  # List of {id, name, isHost}

func _ready() -> void:
	_http_request = HTTPRequest.new()
	add_child(_http_request)
	_http_request.request_completed.connect(_on_request_completed)

	_socket = WebSocketPeer.new()
	_resolve_backend_urls()

func _process(_delta: float) -> void:
	if _socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		return

	_socket.poll()

	var state = _socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		while _socket.get_available_packet_count() > 0:
			var packet = _socket.get_packet()
			_handle_message(packet.get_string_from_utf8())
	elif state == WebSocketPeer.STATE_CLOSING:
		pass
	elif state == WebSocketPeer.STATE_CLOSED:
		var code = _socket.get_close_code()
		var reason = _socket.get_close_reason()
		print("[LobbyManager] WebSocket closed with code: %d, reason: %s" % [code, reason])
		_connected = false

# ============ PUBLIC API ============

func create_lobby() -> void:
	print("[LobbyManager] Creating lobby...")
	var error = _http_request.request(
		_server_url + "/lobby/create",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		""
	)
	if error != OK:
		connection_error.emit("Failed to send create lobby request")

func check_lobby(lobby_id: String) -> void:
	print("[LobbyManager] Checking lobby: %s" % lobby_id)
	var error = _http_request.request(
		_server_url + "/lobby/" + lobby_id.to_upper(),
		[],
		HTTPClient.METHOD_GET
	)
	if error != OK:
		connection_error.emit("Failed to send check lobby request")

func join_lobby(lobby_id: String, player_name: String) -> void:
	_lobby_id = lobby_id.to_upper()
	_player_name = player_name

	print("[LobbyManager] Joining lobby %s as %s" % [_lobby_id, _player_name])

	var url = "%s?lobby=%s&name=%s" % [_ws_url, _lobby_id, _player_name.uri_encode()]
	var error = _socket.connect_to_url(url)
	if error != OK:
		connection_error.emit("Failed to connect to WebSocket")

func send_ball_shot(ball_id: String, direction: Vector2, power: float) -> void:
	if not _connected:
		print("[LobbyManager] send_ball_shot SKIPPED - not connected")
		return
	var data = {
		"type": "ball_shot",
		"ballId": ball_id,
		"direction": {"x": direction.x, "y": direction.y},
		"power": power
	}
	print("[LobbyManager] send_ball_shot: ball_id=%s, my_player_id=%s" % [ball_id, _player_id])
	_socket.send_text(JSON.stringify(data))

func send_game_state(balls: Array) -> void:
	if not _connected or not _is_host:
		return
	var data = {
		"type": "game_state",
		"balls": balls,
		"timestamp": Time.get_ticks_msec()
	}
	_socket.send_text(JSON.stringify(data))

func start_game() -> void:
	if not _connected or not _is_host:
		return
	var data = {"type": "start_game"}
	_socket.send_text(JSON.stringify(data))

func return_to_lobby() -> void:
	if not _connected or not _is_host:
		return
	var data = {"type": "return_to_lobby"}
	_socket.send_text(JSON.stringify(data))

func set_ready(is_ready: bool) -> void:
	if not _connected:
		return
	var data = {"type": "player_ready", "isReady": is_ready}
	_socket.send_text(JSON.stringify(data))

func toggle_ready() -> void:
	if not _connected:
		return
	var data = {"type": "player_ready"}
	_socket.send_text(JSON.stringify(data))

func are_all_players_ready() -> bool:
	if _players.size() < 1:
		return false
	for p in _players:
		if not p.get("isReady", false):
			return false
	return true

func get_player_name() -> String:
	return _player_name

func is_host() -> bool:
	return _is_host

func is_lobby_connected() -> bool:
	return _connected

func get_player_id() -> String:
	return _player_id

func get_lobby_id() -> String:
	return _lobby_id

func get_players() -> Array:
	return _players

# ============ INTERNAL ============

var _pending_action: String = ""

func _resolve_backend_urls() -> void:
	_server_url = DEFAULT_SERVER_URL
	_ws_url = DEFAULT_WS_URL

	if not OS.has_feature("web"):
		return

	var origin = JavaScriptBridge.eval("window.location && window.location.origin ? window.location.origin : ''", true)
	if typeof(origin) != TYPE_STRING or origin == "":
		return

	# Local development: keep defaults (localhost:3000)
	if origin.begins_with("file://") or origin.find("localhost") != -1 or origin.find("127.0.0.1") != -1:
		print("[LobbyManager] Local dev, using defaults: http=%s ws=%s" % [_server_url, _ws_url])
		return

	# Production: infer from origin (same-origin deployment behind reverse proxy)
	_server_url = origin + "/api"
	_ws_url = _derive_ws_url(_server_url)
	print("[LobbyManager] Production, using origin: http=%s ws=%s" % [_server_url, _ws_url])

func _derive_ws_url(server_url: String) -> String:
	var base = server_url
	if base.ends_with("/api"):
		base = base.substr(0, base.length() - 4)

	if base.begins_with("https://"):
		base = "wss://" + base.substr(8)
	elif base.begins_with("http://"):
		base = "ws://" + base.substr(7)

	if not base.ends_with("/ws"):
		base = base.rstrip("/") + "/ws"

	return base

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		connection_error.emit("HTTP request failed with result: %d" % result)
		return

	var json = JSON.parse_string(body.get_string_from_utf8())
	if json == null:
		connection_error.emit("Failed to parse server response")
		return

	print("[LobbyManager] Response (code %d): %s" % [response_code, json])

	# Handle create lobby response
	if json.has("lobbyId") and response_code == 200:
		var lobby_id = json["lobbyId"]
		print("[LobbyManager] Lobby created: %s" % lobby_id)
		lobby_created.emit(lobby_id)

	# Handle check lobby response
	elif json.has("exists"):
		if json["exists"]:
			lobby_checked.emit(json.get("lobbyId", ""), true, json.get("playerCount", 0))
		else:
			lobby_checked.emit("", false, 0)

func _handle_message(message: String) -> void:
	var data = JSON.parse_string(message)
	if data == null:
		print("[LobbyManager] Failed to parse message: %s" % message)
		return

	print("[LobbyManager] Received: %s" % data.get("type", "unknown"))

	match data.get("type"):
		"welcome":
			_player_id = data.get("playerId", "")
			_is_host = data.get("isHost", false)
			_connected = true
			lobby_joined.emit(_lobby_id, _player_id, _is_host)
			print("[LobbyManager] Joined as %s (host: %s)" % [_player_id, _is_host])

			# Store and emit player_joined for all existing players (including ourselves)
			_players.clear()
			var players = data.get("players", [])
			for p in players:
				var player_data = {
					"id": p.get("id", ""),
					"name": p.get("name", ""),
					"isHost": p.get("isHost", false),
					"isReady": p.get("isReady", false)
				}
				_players.append(player_data)
				player_joined.emit(player_data.id, player_data.name, player_data.isHost)

		"player_joined":
			var player_id = data.get("playerId", "")
			var player_name = data.get("playerName", "")
			var is_host = data.get("isHost", false)

			# Add to players list if not already there
			var found = false
			for p in _players:
				if p.id == player_id:
					found = true
					break
			if not found:
				_players.append({"id": player_id, "name": player_name, "isHost": is_host, "isReady": false})

			player_joined.emit(player_id, player_name, is_host)

		"player_left":
			var player_id = data.get("playerId", "")
			var player_name = data.get("playerName", "")

			# Remove from players list
			_players = _players.filter(func(p): return p.id != player_id)

			player_left.emit(player_id, player_name)

			# Check if we became host
			if data.get("newHostId", "") == _player_id:
				_is_host = true
				print("[LobbyManager] We are now the host!")

		"game_started":
			game_started.emit(data.get("hostId", ""))

		"game_state":
			game_state_received.emit(data)

		"ball_shot":
			var shot_player_id = data.get("playerId", "")
			print("[LobbyManager] ball_shot received: from player_id=%s, ballId=%s" % [shot_player_id, data.get("ballId", "")])
			ball_shot_received.emit(shot_player_id, data)

		"player_ready_changed":
			var player_id = data.get("playerId", "")
			var is_ready = data.get("isReady", false)

			# Update player's ready state in local list
			for p in _players:
				if p.id == player_id:
					p.isReady = is_ready
					break

			player_ready_changed.emit(player_id, is_ready)

			# Check if all players are ready
			if are_all_players_ready():
				all_players_ready.emit()

		"returned_to_lobby":
			# Update players list with reset ready states
			var players = data.get("players", [])
			_players.clear()
			for p in players:
				_players.append({
					"id": p.get("id", ""),
					"name": p.get("name", ""),
					"isHost": p.get("isHost", false),
					"isReady": p.get("isReady", false)
				})
			returned_to_lobby.emit()

		"error":
			connection_error.emit(data.get("message", "Unknown error"))
