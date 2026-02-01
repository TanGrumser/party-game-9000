extends Node2D

# Dedicated server game logic
# Runs physics for all balls and broadcasts state to clients

const BROADCAST_INTERVAL = 0.05  # 50ms = 20 ticks per second
const SPAWN_RADIUS = 150.0
const SPAWN_OFFSET = 80.0

@onready var ball_scene = preload("res://scenes/player_ball.tscn")

var main_ball: RigidBody2D
var _balls: Dictionary = {}  # player_id -> RigidBody2D
var _broadcast_timer: float = 0.0
var _players: Array = []

func _ready() -> void:
	print("[ServerGame] Dedicated server game started")

	# Connect to network events
	ServerNetwork.game_started.connect(_on_game_started)
	ServerNetwork.player_joined.connect(_on_player_joined)
	ServerNetwork.player_left.connect(_on_player_left)
	ServerNetwork.ball_shot_received.connect(_on_ball_shot_received)
	ServerNetwork.ball_death_received.connect(_on_ball_death_received)
	ServerNetwork.ball_respawn_received.connect(_on_ball_respawn_received)

	# Find main ball in the scene
	main_ball = get_node_or_null("MainBall")
	if main_ball == null:
		push_error("[ServerGame] MainBall not found in scene!")

func _on_game_started(lobby_id: String, players: Array) -> void:
	print("[ServerGame] Game started in lobby %s with %d players" % [lobby_id, players.size()])
	_players = players
	_spawn_all_player_balls()

func _spawn_all_player_balls() -> void:
	if main_ball == null:
		return

	print("[ServerGame] Spawning %d player balls" % _players.size())

	for i in range(_players.size()):
		var player = _players[i]
		var player_id = player.get("id", "")
		_spawn_ball_at_index(player_id, i, _players.size())

func _spawn_ball_at_index(player_id: String, index: int, total: int) -> void:
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

	print("[ServerGame] Spawned ball for %s at %s" % [player_id, spawn_pos])

func _on_player_joined(player_id: String, player_name: String) -> void:
	print("[ServerGame] Player joined mid-game: %s" % player_id)
	# Spawn ball for late joiner
	var index = _balls.size()
	_spawn_ball_at_index(player_id, index, index + 1)

func _on_player_left(player_id: String) -> void:
	print("[ServerGame] Player left: %s" % player_id)
	if _balls.has(player_id):
		var ball = _balls[player_id]
		ball.queue_free()
		_balls.erase(player_id)

func _on_ball_shot_received(player_id: String, direction: Vector2, power: float) -> void:
	print("[ServerGame] Received shot from %s: dir=%s, power=%.2f" % [player_id, direction, power])

	var ball = _balls.get(player_id)
	if ball == null:
		print("[ServerGame] WARNING: No ball for player %s" % player_id)
		return

	var impulse = direction.normalized() * power
	ball.apply_central_impulse(impulse)
	print("[ServerGame] Applied impulse %s to %s" % [impulse, player_id])

	# Broadcast state immediately after shot for responsiveness
	_broadcast_game_state()

func _on_ball_death_received(player_id: String, ball_id: String) -> void:
	print("[ServerGame] Ball death: %s (from %s)" % [ball_id, player_id])

	if ball_id == "main":
		if main_ball:
			main_ball.respawn()
		return

	var ball = _balls.get(ball_id)
	if ball:
		ball.respawn()

func _on_ball_respawn_received(ball_id: String, spawn_pos: Vector2) -> void:
	print("[ServerGame] Ball respawn: %s at %s" % [ball_id, spawn_pos])
	# Respawn is handled by the ball's respawn() method
	# This message is informational

func _process(delta: float) -> void:
	_broadcast_timer += delta
	if _broadcast_timer >= BROADCAST_INTERVAL:
		_broadcast_timer = 0.0
		_broadcast_game_state()

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
