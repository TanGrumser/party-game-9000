extends Node2D

const BROADCAST_INTERVAL = 0.1  # 100ms
const SPAWN_RADIUS = 150.0  # Distance from main ball to spawn player balls
const SPAWN_OFFSET = 80.0  # Offset between player ball spawn points to prevent overlap

@onready var ball_scene = preload("res://scenes/player_ball.tscn")
@onready var main_ball = $MainBall
@onready var game_camera = $GameCamera

var _balls: Dictionary = {}  # player_id -> RigidBody2D
var _broadcast_timer: float = 0.0

func _ready() -> void:
	print("[Game] Scene loaded")
	print("[Game] Connected to lobby: %s" % LobbyManager.get_lobby_id())
	print("[Game] Player ID: %s" % LobbyManager.get_player_id())
	print("[Game] Is host: %s" % LobbyManager.is_host())

	LobbyManager.game_state_received.connect(_on_game_state_received)
	LobbyManager.ball_shot_received.connect(_on_ball_shot_received)
	LobbyManager.ball_death_received.connect(_on_ball_death_received)
	LobbyManager.ball_respawn_received.connect(_on_ball_respawn_received)
	LobbyManager.player_left.connect(_on_player_left)

	# Check if we have a lobby connection, otherwise spawn debug ball
	if LobbyManager.get_lobby_id().is_empty():
		print("[Game] DEBUG MODE - No lobby connection, spawning test ball")
		%LobbyLabel.text = "DEBUG MODE"
		_spawn_debug_ball()
	else:
		%LobbyLabel.text = "Lobby: %s | %s" % [
			LobbyManager.get_lobby_id(),
			"HOST" if LobbyManager.is_host() else "PLAYER"
		]
		# Spawn balls for all players in the lobby
		_spawn_all_player_balls()

func _spawn_debug_ball() -> void:
	var ball = ball_scene.instantiate()
	ball.player_id = "debug_player"
	ball.is_local = true

	# Set spawn position
	var spawn_pos = main_ball.global_position + Vector2(SPAWN_RADIUS, 0)
	ball.global_position = spawn_pos
	ball.set_spawn_position(spawn_pos)

	add_child(ball)
	_balls["debug_player"] = ball
	print("[Game] DEBUG: Spawned test ball at %s" % ball.global_position)

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

func _process(delta: float) -> void:
	if not LobbyManager.is_host():
		return

	_broadcast_timer += delta
	if _broadcast_timer >= BROADCAST_INTERVAL:
		_broadcast_timer = 0.0
		_broadcast_game_state()

func _broadcast_game_state() -> void:
	var balls_data: Array = []

	# Include main ball state
	balls_data.append({
		"playerId": "main",
		"position": {"x": main_ball.global_position.x, "y": main_ball.global_position.y},
		"velocity": {"x": main_ball.linear_velocity.x, "y": main_ball.linear_velocity.y},
	})

	# Include player balls
	for player_id in _balls:
		var ball: RigidBody2D = _balls[player_id]
		balls_data.append({
			"playerId": player_id,
			"position": {"x": ball.global_position.x, "y": ball.global_position.y},
			"velocity": {"x": ball.linear_velocity.x, "y": ball.linear_velocity.y},
		})

	LobbyManager.send_game_state(balls_data)

func _on_game_state_received(state: Dictionary) -> void:
	# Non-host players sync state from host
	if LobbyManager.is_host():
		return

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
	print("[Game] ball_shot_received: player_id=%s, is_host=%s, my_id=%s" % [player_id, LobbyManager.is_host(), LobbyManager.get_player_id()])
	print("[Game] Known balls: %s" % [_balls.keys()])

	# Host applies shots from other players to physics
	if not LobbyManager.is_host():
		print("[Game] SKIPPED - not host")
		return

	# Don't apply our own shots (already applied locally)
	if player_id == LobbyManager.get_player_id():
		print("[Game] SKIPPED - own shot")
		return

	var ball = _balls.get(player_id)
	if ball == null:
		print("[Game] ERROR: No ball found for player %s in _balls" % player_id)
		return

	var dir = shot_data.get("direction", {})
	var power = shot_data.get("power", 0.0)
	var direction = Vector2(dir.get("x", 0), dir.get("y", 0))
	var impulse = direction * power

	ball.apply_central_impulse(impulse)
	print("[Game] SUCCESS: Applied shot from %s: %s" % [player_id, impulse])

func _on_ball_death_received(player_id: String, ball_id: String) -> void:
	print("[Game] ball_death received: player_id=%s, ball_id=%s" % [player_id, ball_id])

	# Handle main ball death
	if ball_id == "main":
		# Only non-host handles remote main ball death
		if not LobbyManager.is_host():
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
		# Only non-host handles remote main ball respawn
		if not LobbyManager.is_host():
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

func _on_back_pressed() -> void:
	LobbyManager.return_to_lobby()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
