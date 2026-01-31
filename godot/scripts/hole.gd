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
		var pull_strength = gravity_strength * (1.0 - distance / gravity_radius)
		ball.apply_central_force(pull_direction * pull_strength)

func _ball_fell_in(ball: RigidBody2D) -> void:
	# Remove from tracking
	_balls_in_range.erase(ball)

	# Hide and disable the ball
	ball.visible = false
	ball.set_deferred("freeze", true)

	# Create respawn timer
	var timer = get_tree().create_timer(respawn_delay)
	timer.timeout.connect(_respawn_ball.bind(ball))

	print("[Hole] Ball fell in, respawning in %.1f seconds" % respawn_delay)

func _respawn_ball(ball: RigidBody2D) -> void:
	if not is_instance_valid(ball):
		return

	# Respawn at origin with zero velocity
	ball.freeze = false
	ball.linear_velocity = Vector2.ZERO
	ball.angular_velocity = 0.0
	ball.global_position = Vector2.ZERO
	ball.visible = true

	print("[Hole] Ball respawned at origin")
