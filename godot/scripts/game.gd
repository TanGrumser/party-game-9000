extends Node2D

const BROADCAST_INTERVAL = 0.1  # 100ms
const SPAWN_RADIUS = 150.0  # Distance from main ball to spawn player balls

@onready var ball_scene = preload("res://scenes/player_ball.tscn")
@onready var main_ball = $MainBall

var _balls: Dictionary = {}  # player_id -> RigidBody2D
var _broadcast_timer: float = 0.0

func _ready() -> void:
	print("[Game] Scene loaded")
	print("[Game] Connected to lobby: %s" % LobbyManager.get_lobby_id())
	print("[Game] Player ID: %s" % LobbyManager.get_player_id())
	print("[Game] Is host: %s" % LobbyManager.is_host())

	LobbyManager.game_state_received.connect(_on_game_state_received)
	LobbyManager.ball_shot_received.connect(_on_ball_shot_received)
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
	ball.global_position = main_ball.global_position + Vector2(SPAWN_RADIUS, 0)
	add_child(ball)
	_balls["debug_player"] = ball
	print("[Game] DEBUG: Spawned test ball at %s" % ball.global_position)

func _spawn_all_player_balls() -> void:
	var players = LobbyManager.get_players()
	var my_id = LobbyManager.get_player_id()
	var total_players = players.size()

	print("[Game] Spawning balls for %d players" % total_players)

	for i in range(total_players):
		var player = players[i]
		var player_id = player.get("id", "")
		var is_local = (player_id == my_id)

		_spawn_ball_at_index(player_id, i, total_players, is_local)

func _spawn_ball_at_index(player_id: String, index: int, total: int, is_local: bool) -> RigidBody2D:
	var ball = ball_scene.instantiate()
	ball.player_id = player_id
	ball.is_local = is_local

	# Calculate position around main ball - evenly distributed
	var angle = (float(index) / float(total)) * TAU  # TAU = 2*PI
	var offset = Vector2(cos(angle), sin(angle)) * SPAWN_RADIUS
	ball.global_position = main_ball.global_position + offset

	add_child(ball)
	_balls[player_id] = ball

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
			main_ball.sync_from_network(new_pos, new_vel)
			continue

		# Handle player balls (including our own - host is authoritative)
		var ball = _balls.get(player_id)
		if ball == null:
			print("[Game] Warning: No ball for player %s" % player_id)
			continue

		ball.sync_from_network(new_pos, new_vel)

func _on_ball_shot_received(player_id: String, shot_data: Dictionary) -> void:
	# Host applies shots from other players to physics
	if not LobbyManager.is_host():
		return

	# Don't apply our own shots (already applied locally)
	if player_id == LobbyManager.get_player_id():
		return

	var ball = _balls.get(player_id)
	if ball == null:
		print("[Game] No ball found for player %s" % player_id)
		return

	var dir = shot_data.get("direction", {})
	var power = shot_data.get("power", 0.0)
	var direction = Vector2(dir.get("x", 0), dir.get("y", 0))
	var impulse = direction * power

	ball.apply_central_impulse(impulse)
	print("[Game] Applied shot from %s: %s" % [player_id, impulse])

func _on_player_left(player_id: String, player_name: String) -> void:
	print("[Game] Player left: %s (%s)" % [player_name, player_id])

	if _balls.has(player_id):
		var ball = _balls[player_id]
		ball.queue_free()
		_balls.erase(player_id)

func _on_back_pressed() -> void:
	LobbyManager.return_to_lobby()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
