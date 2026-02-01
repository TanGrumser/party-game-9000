extends RigidBody2D

# Main ball with PURE SERVER AUTHORITY
# - Server runs physics, clients use interpolation
# - No client-side physics on clients
# - LOCAL MODE: When no lobby, physics runs locally for debug/testing

@export var respawn_delay: float = 2.0

@onready var burnt_sound: AudioStreamPlayer = $BurntSound
@onready var clack_sound: AudioStreamPlayer = $ClackSound
@onready var wall_sound: AudioStreamPlayer = $WallSound

var _spawn_position: Vector2
var _is_server: bool = false

# Network interpolation for smooth movement
var _interpolator: NetworkInterpolator = NetworkInterpolator.new()

# Visual smoothing
var _visual_position: Vector2 = Vector2.ZERO
const VISUAL_SMOOTH_SPEED: float = 20.0

# Respawn state
var _stored_collision_layer: int = 0
var _stored_collision_mask: int = 0

func _ready() -> void:
	_spawn_position = global_position
	_visual_position = global_position

	# Connect body_entered only if not already connected
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)

	_is_server = _detect_server_mode()

	if _is_server:
		# Server runs physics
		freeze = false
		can_sleep = false
		print("[MainBall] SERVER mode - physics enabled")
	elif not LobbyManager.get_lobby_id().is_empty():
		# Client: freeze physics, use interpolation
		freeze = true
		can_sleep = false
		print("[MainBall] CLIENT mode - pure interpolation from server")
	# else: Debug mode - keep physics for local testing

func _detect_server_mode() -> bool:
	if DisplayServer.get_name() == "headless":
		return true
	var all_args = OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for arg in all_args:
		if arg == "--server" or arg == "--dedicated":
			return true
	return false

func is_local_mode() -> bool:
	"""Returns true when running in local debug mode (no server connection)."""
	return LobbyManager.get_lobby_id().is_empty()

# ============================================================================
# NETWORK SYNC (pure interpolation from server)
# ============================================================================

func sync_from_network(pos: Vector2, vel: Vector2, timestamp: int = 0) -> void:
	_interpolator.add_state(pos, vel, timestamp)

func _process(delta: float) -> void:
	var sprite = get_node_or_null("Sprite2D")

	# Debug mode (no lobby) - visual smoothing only
	if LobbyManager.get_lobby_id().is_empty():
		_visual_position = _visual_position.lerp(global_position, VISUAL_SMOOTH_SPEED * delta)
		if sprite:
			sprite.global_position = _visual_position
		return

	# Server mode - no interpolation needed, physics runs directly
	if _is_server:
		return

	# Client mode: pure interpolation from server state
	_interpolator.update()
	if _interpolator.has_valid_state:
		global_position = _interpolator.interpolated_position
		_visual_position = global_position
		if sprite:
			sprite.global_position = _visual_position

# ============================================================================
# SPAWN / RESPAWN
# ============================================================================

func get_spawn_position() -> Vector2:
	return _spawn_position

func set_spawn_position(pos: Vector2) -> void:
	_spawn_position = pos

func respawn() -> void:
	burnt_sound.play()
	print("[MainBall] Died, respawning in %.1f seconds" % respawn_delay)

	_interpolator.clear()

	# Store collision settings and disable (guard against storing zeroed values)
	if collision_layer != 0:
		_stored_collision_layer = collision_layer
		_stored_collision_mask = collision_mask
	collision_layer = 0
	collision_mask = 0

	# Hide and move away
	visible = false
	global_position = Vector2(-99999, -99999)

	# Send DEATH event (skip in local mode)
	if not is_local_mode():
		LobbyManager.send_ball_death("main")

	# Create respawn timer
	var timer = get_tree().create_timer(respawn_delay)
	timer.timeout.connect(_do_respawn)

func _do_respawn() -> void:
	# Restore collision (use stored values, fallback to defaults if zero)
	if _stored_collision_layer != 0:
		collision_layer = _stored_collision_layer
		collision_mask = _stored_collision_mask
	else:
		# Fallback to default collision settings
		collision_layer = 1
		collision_mask = 1

	# Set position directly
	global_position = _spawn_position
	_visual_position = _spawn_position
	visible = true

	# Reset velocity in local mode
	if is_local_mode():
		linear_velocity = Vector2.ZERO
		angular_velocity = 0.0

	# Clear interpolation for clean start
	_interpolator.clear()

	print("[MainBall] Respawned at %s (collision_layer=%d)" % [_spawn_position, collision_layer])

	# Send RESPAWN event (skip in local mode)
	if not is_local_mode():
		LobbyManager.send_ball_respawn("main", _spawn_position)

func handle_remote_death() -> void:
	"""Called when server reports this ball died."""
	print("[MainBall] Remote death")

	_interpolator.clear()

	if collision_layer != 0:
		_stored_collision_layer = collision_layer
		_stored_collision_mask = collision_mask
	collision_layer = 0
	collision_mask = 0

	visible = false
	global_position = Vector2(-99999, -99999)
	_visual_position = global_position

func handle_remote_respawn(spawn_pos: Vector2) -> void:
	"""Called when server reports this ball respawned."""
	print("[MainBall] Remote respawn at %s" % spawn_pos)

	_interpolator.clear()

	if spawn_pos != Vector2.ZERO:
		_spawn_position = spawn_pos

	global_position = spawn_pos
	_visual_position = spawn_pos
	visible = true

	if _stored_collision_layer != 0:
		collision_layer = _stored_collision_layer
		collision_mask = _stored_collision_mask

# ============================================================================
# COLLISION SOUNDS
# ============================================================================

const MIN_SOUND_SPEED: float = 50.0
const MAX_SOUND_SPEED: float = 500.0

func _get_collision_volume(speed: float) -> float:
	if speed < MIN_SOUND_SPEED:
		return -80.0
	var t = clampf((speed - MIN_SOUND_SPEED) / (MAX_SOUND_SPEED - MIN_SOUND_SPEED), 0.0, 1.0)
	return lerpf(-20.0, 0.0, t)

func _on_body_entered(body: Node) -> void:
	var speed = linear_velocity.length()
	if body is RigidBody2D:
		speed = (linear_velocity - body.linear_velocity).length()

	var volume = _get_collision_volume(speed)

	if body is RigidBody2D:
		clack_sound.volume_db = volume
		clack_sound.play()
	elif body is StaticBody2D and body.name.begins_with("Wall"):
		wall_sound.volume_db = volume
		wall_sound.play()

	# Fire collision - only in debug mode
	if LobbyManager.get_lobby_id().is_empty():
		if body.name.begins_with("Fire") or body.is_in_group("fire"):
			respawn()
	
func _on_goal_body_entered(_body: Node2D) -> void:
	print("[MainBall] Goal hit!")
	var game = get_parent()
	if game.has_method("on_goal_hit"):
		game.on_goal_hit()
