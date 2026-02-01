extends Node2D

# Handles both DEDICATED SERVER and CLIENT modes:
# - Server: Runs physics for all balls, broadcasts state via ServerNetwork
# - Client: Freezes physics, receives state from server via LobbyManager

const SPAWN_RADIUS = 150.0  # Distance from main ball to spawn player balls
const SPAWN_OFFSET = 80.0  # Offset between player ball spawn points to prevent overlap
const BROADCAST_INTERVAL = 0.05  # 50ms = 20 ticks per second (server only)

@export var next_level_path: String = ""  # Path to next level scene

@onready var ball_scene = preload("res://scenes/player_ball.tscn")
@onready var main_ball = $MainBall
@onready var game_camera = $GameCamera

const LevelCompleteOverlayScene = preload("res://scenes/level_complete_overlay.tscn")

var _balls: Dictionary = {}  # player_id -> RigidBody2D
var _is_server: bool = false
var _broadcast_timer: float = 0.0
var _server_players: Array = []  # Players list for server mode
var _level_complete_overlay: CanvasLayer = null
var _level_completed: bool = false

func _ready() -> void:
	_is_server = _detect_server_mode()

	if _is_server:
		_setup_server_mode()
	else:
		_setup_client_mode()

func _detect_server_mode() -> bool:
	# Debug: print detection info
	var display_name = DisplayServer.get_name()
	var args = OS.get_cmdline_args()
	var user_args = OS.get_cmdline_user_args()
	print("[Game] Server mode detection:")
	print("[Game]   DisplayServer.get_name() = '%s'" % display_name)
	print("[Game]   OS.get_cmdline_args() = %s" % [args])
	print("[Game]   OS.get_cmdline_user_args() = %s" % [user_args])

	# Check if running headless (dedicated server)
	if display_name == "headless":
		print("[Game]   -> Detected HEADLESS mode")
		return true

	# Check command line args (both regular and user args after --)
	var all_args = args + user_args
	for arg in all_args:
		if arg == "--server" or arg == "--dedicated":
			print("[Game]   -> Detected --server flag")
			return true

	print("[Game]   -> No server mode detected")
	return false

func _setup_server_mode() -> void:
	print("[Game] === DEDICATED SERVER MODE ===")

	# Connect to ServerNetwork signals
	ServerNetwork.game_started.connect(_on_server_game_started)
	ServerNetwork.player_joined.connect(_on_server_player_joined)
	ServerNetwork.player_left.connect(_on_server_player_left)
	ServerNetwork.ball_shot_received.connect(_on_server_ball_shot)
	ServerNetwork.ball_death_received.connect(_on_server_ball_death)
	ServerNetwork.ball_respawn_received.connect(_on_server_ball_respawn)
	ServerNetwork.level_started.connect(_on_server_level_started)

	# Server runs physics - unfreeze main ball
	main_ball.freeze = false

	# Check if already connected (level transition case)
	if ServerNetwork.is_relay_connected():
		print("[Game] Server already connected, spawning balls for existing players")
		_server_players = ServerNetwork.get_players()
		_spawn_server_balls()
	else:
		# Connect to Bun server
		ServerNetwork.connect_to_relay()
		print("[Game] Server connecting to relay...")

func _setup_client_mode() -> void:
	print("[Game] Scene loaded (CLIENT MODE - dedicated server handles physics)")
	print("[Game] Connected to lobby: %s" % LobbyManager.get_lobby_id())
	print("[Game] Player ID: %s" % LobbyManager.get_player_id())

	LobbyManager.game_state_received.connect(_on_game_state_received)
	LobbyManager.ball_shot_received.connect(_on_ball_shot_received)
	LobbyManager.ball_death_received.connect(_on_ball_death_received)
	LobbyManager.ball_respawn_received.connect(_on_ball_respawn_received)
	LobbyManager.player_left.connect(_on_player_left)
	LobbyManager.goal_reached.connect(_on_goal_reached)

	# Check if we have a lobby connection, otherwise spawn debug ball
	if LobbyManager.get_lobby_id().is_empty():
		print("[Game] DEBUG MODE - No lobby connection, spawning test ball")
		%LobbyLabel.text = "DEBUG MODE"
		_spawn_debug_ball()
	else:
		%LobbyLabel.text = "Lobby: %s" % LobbyManager.get_lobby_id()
		# Spawn balls for all players in the lobby
		_spawn_all_player_balls()

# ============================================================================
# SERVER MODE - Physics authority
# ============================================================================

func _on_server_game_started(lobby_id: String, players: Array) -> void:
	print("[Game:Server] Game started in lobby %s with %d players" % [lobby_id, players.size()])
	_server_players = players
	_spawn_server_balls()

func _spawn_server_balls() -> void:
	print("[Game:Server] Spawning %d player balls" % _server_players.size())

	for i in range(_server_players.size()):
		var player = _server_players[i]
		var player_id = player.get("id", "")
		_spawn_server_ball(player_id, i, _server_players.size())

func _spawn_server_ball(player_id: String, index: int, total: int) -> void:
	if _balls.has(player_id):
		return  # Already spawned

	var ball = ball_scene.instantiate()
	ball.player_id = player_id
	ball.is_local = false  # Server treats all balls as remote (no input handling)

	# Calculate spawn position
	var spawn_pos = main_ball.global_position + Vector2(SPAWN_RADIUS + index * SPAWN_OFFSET, 0)
	ball.global_position = spawn_pos
	ball.set_spawn_position(spawn_pos)

	# Server runs physics for ALL balls - don't freeze
	ball.freeze = false

	add_child(ball)
	_balls[player_id] = ball

	print("[Game:Server] Spawned ball for %s at %s" % [player_id, spawn_pos])

func _on_server_player_joined(player_id: String, player_name: String) -> void:
	print("[Game:Server] Player joined mid-game: %s (%s)" % [player_name, player_id])
	var index = _balls.size()
	_spawn_server_ball(player_id, index, index + 1)

func _on_server_player_left(player_id: String) -> void:
	print("[Game:Server] Player left: %s" % player_id)
	if _balls.has(player_id):
		var ball = _balls[player_id]
		ball.queue_free()
		_balls.erase(player_id)

func _on_server_ball_shot(player_id: String, direction: Vector2, power: float) -> void:
	print("[Game:Server] Received shot from %s: dir=%s, power=%.2f" % [player_id, direction, power])

	var ball = _balls.get(player_id)
	if ball == null:
		print("[Game:Server] WARNING: No ball for player %s" % player_id)
		return

	var impulse = direction.normalized() * power
	ball.apply_central_impulse(impulse)
	print("[Game:Server] Applied impulse %s to %s" % [impulse, player_id])

	# Broadcast state immediately after shot for responsiveness
	_broadcast_game_state()

func _on_server_ball_death(player_id: String, ball_id: String) -> void:
	print("[Game:Server] Ball death: %s (from %s)" % [ball_id, player_id])

	if ball_id == "main":
		if main_ball:
			main_ball.respawn()
		return

	var ball = _balls.get(ball_id)
	if ball:
		ball.respawn()

func _on_server_ball_respawn(ball_id: String, spawn_pos: Vector2) -> void:
	print("[Game:Server] Ball respawn: %s at %s" % [ball_id, spawn_pos])
	# Respawn is handled by the ball's respawn() method

func _on_server_level_started(next_level: String, players: Array) -> void:
	print("[Game:Server] Level started: %s with %d players" % [next_level, players.size()])
	_server_players = players

	# Load the new level
	if next_level.is_empty():
		print("[Game:Server] No next level specified, staying on current level")
		return

	print("[Game:Server] Loading next level: %s" % next_level)
	get_tree().change_scene_to_file(next_level)

func _process(delta: float) -> void:
	if not _is_server:
		return  # Client doesn't broadcast

	_broadcast_timer += delta
	if _broadcast_timer >= BROADCAST_INTERVAL:
		_broadcast_timer = 0.0
		_broadcast_game_state()

func _physics_process(_delta: float) -> void:
	if not _is_server:
		return

	# Server-side goal detection (Area2D signals may not work in headless mode)
	if _level_completed:
		return

	var goal = get_node_or_null("Goal")
	if goal and main_ball and main_ball.visible:
		var overlapping = goal.get_overlapping_bodies()
		if main_ball in overlapping:
			print("[Game:Server] Goal collision detected via physics check")
			on_goal_hit()

func _broadcast_game_state() -> void:
	var balls_data: Array = []

	# Include main ball state
	if main_ball and main_ball.visible:
		balls_data.append({
			"playerId": "main",
			"position": {"x": main_ball.global_position.x, "y": main_ball.global_position.y},
			"velocity": {"x": main_ball.linear_velocity.x, "y": main_ball.linear_velocity.y},
		})

	# Include player balls
	for player_id in _balls:
		var ball: RigidBody2D = _balls[player_id]
		if not ball.visible:
			continue
		balls_data.append({
			"playerId": player_id,
			"position": {"x": ball.global_position.x, "y": ball.global_position.y},
			"velocity": {"x": ball.linear_velocity.x, "y": ball.linear_velocity.y},
		})

	ServerNetwork.send_game_state(balls_data)

# ============================================================================
# CLIENT MODE - Receive and interpolate
# ============================================================================

func _spawn_debug_ball() -> void:
	var ball = ball_scene.instantiate()
	ball.player_id = "debug_player"
	ball.is_local = true

	# Set spawn position
	var spawn_pos = main_ball.global_position + Vector2(SPAWN_RADIUS, 0)
	ball.global_position = spawn_pos
	ball.set_spawn_position(spawn_pos)

	# LOCAL MODE: Enable physics for debug play
	ball.freeze = false
	ball.can_sleep = false

	add_child(ball)
	_balls["debug_player"] = ball
	print("[Game] DEBUG: Spawned test ball at %s (physics enabled)" % ball.global_position)

	# Ensure main ball also has physics in local mode
	main_ball.freeze = false
	main_ball.can_sleep = false

	# Set up camera targets
	game_camera.add_target(main_ball)
	game_camera.add_target(ball)

func _spawn_all_player_balls() -> void:
	var players = LobbyManager.get_players()
	var my_id = LobbyManager.get_player_id()
	var total_players = players.size()

	print("[Game] Spawning balls for %d players, my_id=%s" % [total_players, my_id])
	print("[Game] Players from LobbyManager: %s" % [players])

	# Add main ball as camera target
	game_camera.add_target(main_ball)

	for i in range(total_players):
		var player = players[i]
		var player_id = player.get("id", "")
		var is_local = (player_id == my_id)

		var ball = _spawn_ball_at_index(player_id, i, total_players, is_local)
		game_camera.add_target(ball)

func _spawn_ball_at_index(player_id: String, index: int, total: int, is_local: bool) -> RigidBody2D:
	var ball = ball_scene.instantiate()
	ball.player_id = player_id
	ball.is_local = is_local

	# Calculate spawn position - offset horizontally to prevent overlap
	# Players spawn in a row to the right of the main ball
	var spawn_pos = main_ball.global_position + Vector2(SPAWN_RADIUS + index * SPAWN_OFFSET, 0)
	ball.global_position = spawn_pos
	ball.set_spawn_position(spawn_pos)

	add_child(ball)
	_balls[player_id] = ball

	# Configure network behavior (freeze remote players for pure interpolation)
	ball._setup_for_network()

	print("[Game] Spawned ball for %s (local: %s) at index %d/%d, pos %s" % [
		player_id, is_local, index, total, ball.global_position
	])
	return ball

func _on_game_state_received(state: Dictionary) -> void:
	# All clients receive authoritative state from dedicated server

	var timestamp = state.get("timestamp", 0)
	var balls_data = state.get("balls", [])

	for ball_data in balls_data:
		var player_id = ball_data.get("playerId", "")
		if player_id.is_empty():
			continue

		var pos = ball_data.get("position", {})
		var vel = ball_data.get("velocity", {})
		var new_pos = Vector2(pos.get("x", 0), pos.get("y", 0))
		var new_vel = Vector2(vel.get("x", 0), vel.get("y", 0))

		# Handle main ball
		if player_id == "main":
			main_ball.sync_from_network(new_pos, new_vel, timestamp)
			continue

		# Handle player balls (including our own - host is authoritative)
		var ball = _balls.get(player_id)
		if ball == null:
			print("[Game] Warning: No ball for player %s" % player_id)
			continue

		ball.sync_from_network(new_pos, new_vel, timestamp)

func _on_ball_shot_received(player_id: String, shot_data: Dictionary) -> void:
	# With dedicated server, shots are applied server-side.
	# This callback is informational only (e.g., for sound effects).
	# The authoritative state will arrive via game_state messages.

	# Skip our own shots (already handled locally with prediction)
	if player_id == LobbyManager.get_player_id():
		return

	# Could play shot sound effect for other players here if desired
	print("[Game] Shot received from %s (server will apply physics)" % player_id)

func _on_ball_death_received(player_id: String, ball_id: String) -> void:
	print("[Game] ball_death received: player_id=%s, ball_id=%s" % [player_id, ball_id])

	# Handle main ball death
	if ball_id == "main":
		main_ball.handle_remote_death()
		return

	# Handle player ball death
	var ball = _balls.get(ball_id)
	if ball == null:
		print("[Game] Warning: No ball for death player %s" % ball_id)
		return

	# Don't handle our own death (we triggered it locally)
	if ball_id == LobbyManager.get_player_id():
		return

	ball.handle_remote_death()

func _on_ball_respawn_received(ball_id: String, spawn_pos_data: Dictionary) -> void:
	var spawn_pos = Vector2(spawn_pos_data.get("x", 0), spawn_pos_data.get("y", 0))
	print("[Game] ball_respawn received: ball_id=%s, spawn_pos=%s" % [ball_id, spawn_pos])

	# Handle main ball respawn
	if ball_id == "main":
		main_ball.handle_remote_respawn(spawn_pos)
		return

	# Handle player ball respawn
	var ball = _balls.get(ball_id)
	if ball == null:
		print("[Game] Warning: No ball for respawn ball_id %s" % ball_id)
		return

	# Don't handle our own respawn (we triggered it locally)
	if ball_id == LobbyManager.get_player_id():
		return

	ball.handle_remote_respawn(spawn_pos)

func _on_player_left(player_id: String, player_name: String) -> void:
	print("[Game] Player left: %s (%s)" % [player_name, player_id])

	if _balls.has(player_id):
		var ball = _balls[player_id]
		game_camera.remove_target(ball)
		ball.queue_free()
		_balls.erase(player_id)

# ============================================================================
# LEVEL COMPLETE
# ============================================================================

func on_goal_hit() -> void:
	"""Called by main_ball when it collides with the goal."""
	if _level_completed:
		return  # Already completed

	print("[Game] Goal hit!")
	_level_completed = true

	if _is_server:
		# Server mode - broadcast to all clients
		ServerNetwork.send_goal_reached()
	elif LobbyManager.get_lobby_id().is_empty():
		# Local mode - show overlay directly
		_show_level_complete_overlay()
	else:
		# Client mode - send goal reached to server
		LobbyManager.send_goal_reached()

func _on_goal_reached() -> void:
	"""Called when server broadcasts goal_reached."""
	print("[Game] Goal reached signal received")
	_level_completed = true
	_show_level_complete_overlay()

func _show_level_complete_overlay() -> void:
	if _level_complete_overlay != null:
		return  # Already showing

	_level_complete_overlay = LevelCompleteOverlayScene.instantiate()
	_level_complete_overlay.set_next_level_path(next_level_path)
	_level_complete_overlay.closed.connect(_on_level_complete_overlay_closed)
	add_child(_level_complete_overlay)
	print("[Game] Showing level complete overlay (next: %s)" % next_level_path)

func _on_level_complete_overlay_closed() -> void:
	if _level_complete_overlay:
		_level_complete_overlay.queue_free()
		_level_complete_overlay = null

func _on_back_pressed() -> void:
	LobbyManager.return_to_lobby()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
