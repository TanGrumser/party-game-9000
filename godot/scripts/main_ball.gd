extends RigidBody2D

@export var respawn_delay: float = 2.0  # Seconds before respawn

@onready var burnt_sound: AudioStreamPlayer = $BurntSound
@onready var clack_sound: AudioStreamPlayer = $ClackSound
@onready var wall_sound: AudioStreamPlayer = $WallSound

var _spawn_position: Vector2

func _ready() -> void:
	can_sleep = false  # Never sleep - we need _integrate_forces for network sync
	_spawn_position = global_position
	_visual_position = global_position
	# Connect body_entered only if not already connected (scene may have it connected)
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)

	# Check if running as dedicated server
	var is_server = _detect_server_mode()

	if is_server:
		# Server runs physics - keep unfrozen
		freeze = false
		print("[MainBall] SERVER mode - physics enabled")
	elif not LobbyManager.get_lobby_id().is_empty():
		# Client connected to lobby - freeze physics, use interpolation from server
		freeze = true
		print("[MainBall] CLIENT mode - physics frozen, using interpolation from server")
	# else: Debug mode (no lobby) - keep physics for local testing

func _detect_server_mode() -> bool:
	if DisplayServer.get_name() == "headless":
		return true
	# Check both regular args and user args (after --)
	var all_args = OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for arg in all_args:
		if arg == "--server" or arg == "--dedicated":
			return true
	return false

# Network interpolation for smooth movement
var _interpolator: NetworkInterpolator = NetworkInterpolator.new()

# Visual smoothing - sprite smoothly follows physics body
var _visual_position: Vector2 = Vector2.ZERO
const VISUAL_SMOOTH_SPEED: float = 15.0  # How fast visual catches up

# Respawn state (applied in _integrate_forces)
var _respawn_pending: bool = false

# Called by game.gd to sync state from network
func sync_from_network(pos: Vector2, vel: Vector2, timestamp: int = 0) -> void:
	# Add to interpolation buffer (only non-host uses this)
	_interpolator.add_state(pos, vel, timestamp)

func _process(delta: float) -> void:
	var sprite = get_node_or_null("Sprite2D")

	# Debug mode (no lobby) - visual smoothing only
	if LobbyManager.get_lobby_id().is_empty():
		_visual_position = _visual_position.lerp(global_position, VISUAL_SMOOTH_SPEED * delta)
		if sprite:
			sprite.global_position = _visual_position
		return

	# With dedicated server: all clients use interpolation from server state
	_interpolator.update()

	if _interpolator.has_valid_state:
		global_position = _interpolator.interpolated_position
		_visual_position = global_position
		if sprite:
			sprite.global_position = _visual_position

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

	# Send DEATH event (server will handle physics)
	LobbyManager.send_ball_death("main")

	# Create respawn timer
	var timer = get_tree().create_timer(respawn_delay)
	timer.timeout.connect(_do_respawn)

func _do_respawn() -> void:
	# Restore collision
	collision_layer = _stored_collision_layer
	collision_mask = _stored_collision_mask

	# Show but stay frozen (server runs physics)
	visible = true
	_respawn_pending = true
	_visual_position = _spawn_position
	print("[MainBall] Respawned at %s" % _spawn_position)

	# Send RESPAWN event (server will update state)
	LobbyManager.send_ball_respawn("main", _spawn_position)

# Apply network sync during physics step (only runs on host - non-host is frozen)
func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	if _respawn_pending:
		_respawn_pending = false
		state.transform.origin = _spawn_position
		state.linear_velocity = Vector2.ZERO
		_visual_position = _spawn_position  # Snap visual too
		return

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

	# Hide ball (already frozen for non-host)
	visible = false
	global_position = Vector2(-99999, -99999)
	_visual_position = global_position

func handle_remote_respawn(spawn_pos: Vector2) -> void:
	"""Called when server reports the main ball respawned."""
	print("[MainBall] Remote respawn at %s" % spawn_pos)

	# Clear interpolation buffer to prevent sliding
	_interpolator.clear()

	# Update spawn position if provided
	if spawn_pos != Vector2.ZERO:
		_spawn_position = spawn_pos

	# Directly set position
	global_position = spawn_pos
	_visual_position = spawn_pos

	# Restore visibility and collision
	visible = true
	# Stay frozen - server runs physics
	if _stored_collision_layer != 0:
		collision_layer = _stored_collision_layer
		collision_mask = _stored_collision_mask

const MIN_SOUND_SPEED: float = 50.0  # Below this, no sound
const MAX_SOUND_SPEED: float = 500.0  # At this speed, full volume

func _get_collision_volume(speed: float) -> float:
	if speed < MIN_SOUND_SPEED:
		return -80.0  # Effectively silent
	var t = clampf((speed - MIN_SOUND_SPEED) / (MAX_SOUND_SPEED - MIN_SOUND_SPEED), 0.0, 1.0)
	return lerpf(-20.0, 0.0, t)  # -20 dB at min speed, 0 dB at max speed

func _on_body_entered(body: Node) -> void:
	var speed = linear_velocity.length()
	if body is RigidBody2D:
		# Use relative velocity for ball-to-ball collisions
		speed = (linear_velocity - body.linear_velocity).length()

	var volume = _get_collision_volume(speed)

	# Ball collision sounds play for everyone
	if body is RigidBody2D:
		clack_sound.volume_db = volume
		clack_sound.play()
	elif body is StaticBody2D and body.name.begins_with("Wall"):
		wall_sound.volume_db = volume
		wall_sound.play()

	# On clients: physics is frozen, so this won't be called for collisions
	# On server: this handles collision detection
	# Debug mode (no lobby): handle locally
	if LobbyManager.get_lobby_id().is_empty():
		# Debug mode - handle locally
		if body.name.begins_with("Fire") or body.is_in_group("fire"):
			respawn()
	# Note: On dedicated server, collisions are handled by server_game.gd
