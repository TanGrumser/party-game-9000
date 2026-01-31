extends RigidBody2D

@export var respawn_delay: float = 2.0  # Seconds before respawn

@onready var burnt_sound: AudioStreamPlayer = $BurntSound

var _spawn_position: Vector2

func _ready() -> void:
	can_sleep = false  # Never sleep - we need _integrate_forces for network sync
	_spawn_position = global_position

# Network interpolation for smooth movement
var _interpolator: NetworkInterpolator = NetworkInterpolator.new()

# Network sync state (applied in _integrate_forces)
var _sync_pending: bool = false
var _sync_position: Vector2
var _sync_velocity: Vector2

# Correction rate for smooth transitions
const CORRECTION_RATE: float = 0.3

# Respawn state (applied in _integrate_forces)
var _respawn_pending: bool = false

# Called by game.gd to sync state from network
func sync_from_network(pos: Vector2, vel: Vector2, timestamp: int = 0) -> void:
	# Add to interpolation buffer (only non-host uses this)
	_interpolator.add_state(pos, vel, timestamp)

func _process(delta: float) -> void:
	# Host doesn't interpolate - they are authoritative
	if LobbyManager.is_host():
		return

	# Update interpolator and get interpolated values
	_interpolator.update()

	if _interpolator.has_valid_state:
		_sync_position = _interpolator.interpolated_position
		_sync_velocity = _interpolator.interpolated_velocity
		_sync_pending = true
		sleeping = false

func get_spawn_position() -> Vector2:
	return _spawn_position

func set_spawn_position(pos: Vector2) -> void:
	_spawn_position = pos

var _stored_collision_layer: int = 0
var _stored_collision_mask: int = 0

func respawn() -> void:
	burnt_sound.play()
	print("[MainBall] Died, respawning in %.1f seconds at %s" % [respawn_delay, _spawn_position])

	# Clear interpolation buffer to prevent sliding from old position
	_interpolator.clear()

	# Store collision settings and disable
	_stored_collision_layer = collision_layer
	_stored_collision_mask = collision_mask
	collision_layer = 0
	collision_mask = 0

	# Hide, freeze, and move far away
	visible = false
	freeze = true
	global_position = Vector2(-99999, -99999)

	# Send DEATH event immediately (only host triggers this for main ball)
	if LobbyManager.is_host():
		LobbyManager.send_ball_death("main")

	# Create respawn timer
	var timer = get_tree().create_timer(respawn_delay)
	timer.timeout.connect(_do_respawn)

func _do_respawn() -> void:
	# Restore collision
	collision_layer = _stored_collision_layer
	collision_mask = _stored_collision_mask

	# Unfreeze and show
	freeze = false
	visible = true
	_respawn_pending = true
	sleeping = false
	print("[MainBall] Respawned at %s" % _spawn_position)

	# Send RESPAWN event after timer (only host triggers this for main ball)
	if LobbyManager.is_host():
		LobbyManager.send_ball_respawn("main", _spawn_position)

# Apply network sync during physics step (safe way to modify RigidBody2D)
func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	if _respawn_pending:
		_respawn_pending = false
		state.transform.origin = _spawn_position
		state.linear_velocity = Vector2.ZERO
		return

	if _sync_pending:
		_sync_pending = false

		# Smooth correction toward interpolated target
		var pos_error = _sync_position - state.transform.origin
		var vel_error = _sync_velocity - state.linear_velocity

		state.transform.origin += pos_error * CORRECTION_RATE
		state.linear_velocity += vel_error * CORRECTION_RATE

func handle_remote_death() -> void:
	"""Called when host reports the main ball died."""
	print("[MainBall] Remote death")

	# Clear interpolation buffer to prevent sliding from old position
	_interpolator.clear()

	# Store collision settings and disable
	if collision_layer != 0:
		_stored_collision_layer = collision_layer
		_stored_collision_mask = collision_mask
	collision_layer = 0
	collision_mask = 0

	# Hide and freeze
	visible = false
	freeze = true
	global_position = Vector2(-99999, -99999)

func handle_remote_respawn(spawn_pos: Vector2) -> void:
	"""Called when host reports the main ball respawned."""
	print("[MainBall] Remote respawn at %s" % spawn_pos)

	# Clear interpolation buffer to prevent sliding
	_interpolator.clear()

	# Update spawn position if provided
	if spawn_pos != Vector2.ZERO:
		_spawn_position = spawn_pos

	# Immediately snap to spawn position (no interpolation)
	_respawn_pending = true
	sleeping = false

	# Restore visibility and collision
	visible = true
	freeze = false
	if _stored_collision_layer != 0:
		collision_layer = _stored_collision_layer
		collision_mask = _stored_collision_mask

func _on_body_entered(body: Node) -> void:
	# Only host handles main ball collision (or debug mode with no lobby)
	if not LobbyManager.is_host() and not LobbyManager.get_lobby_id().is_empty():
		return

	print("[MainBall] Touched: %s" % body.name)
	# Check if it's a fire obstacle (by name or group)
	if body.name.begins_with("Fire") or body.is_in_group("fire"):
		respawn()
