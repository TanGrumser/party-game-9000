extends RigidBody2D

@export var max_impulse: float = 800.0
@export var min_distance: float = 20.0  # Closest click distance for max power
@export var max_distance: float = 300.0  # Farthest click still registers

var player_id: String = ""
var is_local: bool = false  # Only local player sends input

func _ready() -> void:
	can_sleep = false  # Never sleep - we need _integrate_forces for network sync

# Network sync state (applied in _integrate_forces)
var _sync_pending: bool = false
var _sync_position: Vector2
var _sync_velocity: Vector2

func _input(event: InputEvent) -> void:
	if not is_local:
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_handle_click(event.position)
	elif event is InputEventScreenTouch:
		if event.pressed:
			_handle_click(event.position)

func _handle_click(click_pos: Vector2) -> void:
	var ball_pos = global_position
	var direction = ball_pos - click_pos  # Opposite direction (away from click)
	var distance = direction.length()

	if distance < 1.0:
		return  # Clicked exactly on ball, ignore

	# Closer = stronger impulse
	var strength = inverse_lerp(max_distance, min_distance, distance)
	strength = clampf(strength, 0.0, 1.0)

	if strength <= 0.0:
		return  # Too far away

	var impulse = direction.normalized() * max_impulse * strength
	apply_central_impulse(impulse)

	print("[PlayerBall] Click at %s, impulse: %s (strength: %.2f)" % [click_pos, impulse, strength])

	# Send shot to other players
	LobbyManager.send_ball_shot(
		player_id,
		direction.normalized(),
		max_impulse * strength
	)

# Called by game.gd to sync state from network
func sync_from_network(pos: Vector2, vel: Vector2) -> void:
	_sync_position = pos
	_sync_velocity = vel
	_sync_pending = true
	sleeping = false  # Wake up body so _integrate_forces gets called

# Apply network sync during physics step (safe way to modify RigidBody2D)
func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	if _sync_pending:
		_sync_pending = false
		state.transform.origin = _sync_position
		state.linear_velocity = _sync_velocity
