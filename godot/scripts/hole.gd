extends Node2D

@export var gravity_strength: float = 500.0  # Pull force
@export var gravity_radius: float = 150.0  # How far the gravity effect reaches
@export var fall_radius: float = 20.0  # How close to center before ball falls in
@export var respawn_delay: float = 2.0  # Seconds before respawn

var _balls_in_range: Array[RigidBody2D] = []

@onready var gravity_area: Area2D = $GravityArea

func _ready() -> void:
	# Connect area signals
	gravity_area.body_entered.connect(_on_body_entered)
	gravity_area.body_exited.connect(_on_body_exited)

	# Update the collision shape radius to match gravity_radius
	var collision_shape = gravity_area.get_node("CollisionShape2D")
	if collision_shape and collision_shape.shape is CircleShape2D:
		collision_shape.shape.radius = gravity_radius

func _on_body_entered(body: Node2D) -> void:
	if body is RigidBody2D and body not in _balls_in_range:
		_balls_in_range.append(body)

func _on_body_exited(body: Node2D) -> void:
	if body in _balls_in_range:
		_balls_in_range.erase(body)

func _physics_process(delta: float) -> void:
	var hole_center = global_position

	# Process each ball in range
	for ball in _balls_in_range.duplicate():  # Duplicate to avoid modification during iteration
		if not is_instance_valid(ball):
			_balls_in_range.erase(ball)
			continue

		var to_hole = hole_center - ball.global_position
		var distance = to_hole.length()

		# Check if ball fell into the hole
		if distance < fall_radius:
			_ball_fell_in(ball)
			continue

		# Apply gravitational pull (stronger when closer)
		var pull_direction = to_hole.normalized()
		var pull_factor = clampf(1.0 - distance / gravity_radius, 0.0, 1.0)
		var pull_strength = gravity_strength * pull_factor
		ball.apply_central_force(pull_direction * pull_strength)

func _ball_fell_in(ball: RigidBody2D) -> void:
	# Remove from tracking
	_balls_in_range.erase(ball)

	# Only trigger respawn for locally-controlled balls
	# Player balls: only if is_local
	# Main ball: only if we're the host
	var should_respawn = false
	if ball.has_method("respawn"):
		if "is_local" in ball:
			# Player ball - only respawn if local
			should_respawn = ball.is_local
		else:
			# Main ball - only respawn if host
			should_respawn = LobbyManager.is_host()

	if should_respawn:
		print("[Hole] Ball fell in, using ball.respawn()")
		ball.respawn()
	elif not ball.has_method("respawn"):
		# Fallback for balls without respawn method
		print("[Hole] Ball fell in (no respawn method), respawning in %.1f seconds" % respawn_delay)
		ball.visible = false
		ball.set_deferred("freeze", true)
		var timer = get_tree().create_timer(respawn_delay)
		timer.timeout.connect(_respawn_ball_fallback.bind(ball))

func _respawn_ball_fallback(ball: RigidBody2D) -> void:
	if not is_instance_valid(ball):
		return

	# Get spawn position from ball if it has the method, otherwise use origin
	var respawn_pos = Vector2.ZERO
	if ball.has_method("get_spawn_position"):
		respawn_pos = ball.get_spawn_position()

	# Respawn at spawn position with zero velocity
	ball.freeze = false
	ball.linear_velocity = Vector2.ZERO
	ball.angular_velocity = 0.0
	ball.global_position = respawn_pos
	ball.visible = true

	print("[Hole] Ball respawned (fallback) at %s" % respawn_pos)
