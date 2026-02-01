extends RigidBody2D

# Player ball with PURE SERVER AUTHORITY
# - All physics runs on dedicated server
# - Clients freeze physics and use interpolation only
# - Input (shots) sent to server, not applied locally
# - LOCAL MODE: When no lobby, physics runs locally for debug/testing

@export var max_impulse: float = 800.0  # Maximum shot power
@export var min_drag: float = 20.0  # Minimum drag distance to register a shot
@export var max_drag: float = 200.0  # Maximum drag distance (clamped)
@export var local_color: Color = Color(0.2, 0.8, 0.4)  # Green for local player
@export var remote_color: Color = Color(0.8, 0.3, 0.3)  # Red for other players
@export var local_texture: Texture2D  # Texture for local player (optional)
@export var remote_texture: Texture2D  # Texture for other players (optional)
@export var respawn_delay: float = 2.0  # Seconds before respawn

@onready var burnt_sound: AudioStreamPlayer = $BurntSound
@onready var clack_sound: AudioStreamPlayer = $ClackSound
@onready var wall_sound: AudioStreamPlayer = $WallSound
@onready var shoot_sound: AudioStreamPlayer = $ShootSound

var player_id: String = ""
var is_local: bool = false:
	set(value):
		is_local = value
		_update_appearance()

# Spawn point (can be updated for checkpoints)
var spawn_position: Vector2 = Vector2.ZERO

# Drag state (input handling)
var _is_dragging: bool = false
var _drag_start_pos: Vector2 = Vector2.ZERO
var _current_drag_pos: Vector2 = Vector2.ZERO

# Drag indicator reference
var _drag_indicator: Node2D = null
const DRAG_INDICATOR_SCENE = preload("res://scenes/drag_indicator.tscn")

# Network interpolation for smooth movement from server
var _interpolator: NetworkInterpolator = NetworkInterpolator.new()

# Visual smoothing
var _visual_position: Vector2 = Vector2.ZERO
const VISUAL_SMOOTH_SPEED: float = 20.0

# Respawn state
var _stored_collision_layer: int = 0
var _stored_collision_mask: int = 0

func _ready() -> void:
	_visual_position = global_position
	_update_appearance()
	body_entered.connect(_on_body_entered)

func is_local_mode() -> bool:
	"""Returns true when running in local debug mode (no server connection)."""
	return LobbyManager.get_lobby_id().is_empty()

func _setup_for_network() -> void:
	"""Called after spawning to configure for network play."""
	# With dedicated server: ALL client balls are frozen
	# Physics runs only on the server
	if not LobbyManager.get_lobby_id().is_empty():
		freeze = true
		can_sleep = false
		print("[PlayerBall] %s frozen - pure interpolation from server (is_local=%s)" % [player_id, is_local])

func _update_appearance() -> void:
	var sprite = get_node_or_null("Sprite2D")
	if sprite:
		sprite.modulate = local_color if is_local else remote_color
		var texture = local_texture if is_local else remote_texture
		if texture:
			sprite.texture = texture

# ============================================================================
# INPUT HANDLING (local player only - sends to server, no local physics)
# ============================================================================

func _input(event: InputEvent) -> void:
	if not is_local:
		return

	# Mouse input
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_start_drag(event.position)
			else:
				_end_drag(event.position)
	elif event is InputEventMouseMotion:
		if _is_dragging:
			_update_drag(event.position)

	# Touch input
	elif event is InputEventScreenTouch:
		if event.pressed:
			_start_drag(event.position)
		else:
			_end_drag(event.position)
	elif event is InputEventScreenDrag:
		if _is_dragging:
			_update_drag(event.position)

func _start_drag(pos: Vector2) -> void:
	_is_dragging = true
	_drag_start_pos = pos
	_current_drag_pos = pos

	# Create indicator if not exists
	if _drag_indicator == null:
		_drag_indicator = DRAG_INDICATOR_SCENE.instantiate()
		get_tree().current_scene.add_child(_drag_indicator)

	_drag_indicator.show_indicator()
	_update_indicator_positions(pos)

func _update_drag(pos: Vector2) -> void:
	_current_drag_pos = pos
	if _drag_indicator:
		_update_indicator_positions(pos)

func _update_indicator_positions(drag_pos: Vector2) -> void:
	var drag_offset = drag_pos - _drag_start_pos
	if drag_offset.length() > max_drag:
		drag_offset = drag_offset.normalized() * max_drag
	var indicator_end = global_position + drag_offset
	_drag_indicator.update_positions(global_position, indicator_end)

func _end_drag(pos: Vector2) -> void:
	if not _is_dragging:
		return

	_is_dragging = false
	_current_drag_pos = pos

	# Hide indicator
	if _drag_indicator:
		_drag_indicator.hide_indicator()

	# Calculate shot
	var drag_offset = pos - _drag_start_pos
	var distance = drag_offset.length()

	if distance < min_drag:
		return  # Too short a drag, ignore

	# Clamp distance and calculate strength
	var clamped_distance = minf(distance, max_drag)
	var strength = inverse_lerp(min_drag, max_drag, clamped_distance)

	# Direction is opposite of drag
	var direction = -drag_offset.normalized()
	var power = max_impulse * strength

	# Play shoot sound locally for immediate feedback
	shoot_sound.volume_db = lerpf(-20.0, -10.0, strength)
	shoot_sound.play()

	print("[PlayerBall] Shot: dir=%s, power=%.2f" % [direction, power])

	# LOCAL MODE: Apply physics directly
	if is_local_mode():
		var impulse = direction.normalized() * power
		apply_central_impulse(impulse)
		print("[PlayerBall] LOCAL: Applied impulse %s" % impulse)
		return

	# NETWORK MODE: Send to server - do NOT apply locally
	# Server will apply physics and broadcast result
	LobbyManager.send_ball_shot(player_id, direction.normalized(), power)

# ============================================================================
# NETWORK SYNC (pure interpolation from server)
# ============================================================================

func sync_from_network(pos: Vector2, vel: Vector2, timestamp: int = 0) -> void:
	# All balls use interpolation - no special handling for local
	_interpolator.add_state(pos, vel, timestamp)

func _process(delta: float) -> void:
	var sprite = get_node_or_null("Sprite2D")

	# Debug mode (no lobby) - local physics for testing
	if LobbyManager.get_lobby_id().is_empty():
		_visual_position = _visual_position.lerp(global_position, VISUAL_SMOOTH_SPEED * delta)
		if sprite:
			sprite.global_position = _visual_position
		return

	# Network mode: pure interpolation from server state
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
	return spawn_position

func set_spawn_position(pos: Vector2) -> void:
	spawn_position = pos

func respawn() -> void:
	burnt_sound.play()
	print("[PlayerBall] %s died, respawning in %.1f seconds" % [player_id, respawn_delay])

	# Clear interpolation buffer
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

	# Send DEATH event (only local player triggers, skip in local mode)
	if is_local and not is_local_mode():
		LobbyManager.send_ball_death(player_id)

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

	# Show and set position
	visible = true
	global_position = spawn_position
	_visual_position = spawn_position

	# Reset velocity in local mode
	if is_local_mode():
		linear_velocity = Vector2.ZERO
		angular_velocity = 0.0

	# Clear interpolation for clean start
	_interpolator.clear()

	print("[PlayerBall] %s respawned at %s (collision_layer=%d)" % [player_id, spawn_position, collision_layer])

	# Send RESPAWN event (only local player triggers, skip in local mode)
	if is_local and not is_local_mode():
		LobbyManager.send_ball_respawn(player_id, spawn_position)

func handle_remote_death() -> void:
	"""Called when server reports this ball died."""
	print("[PlayerBall] %s remote death" % player_id)

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
	print("[PlayerBall] %s remote respawn at %s" % [player_id, spawn_pos])

	_interpolator.clear()

	if spawn_pos != Vector2.ZERO:
		spawn_position = spawn_pos

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
	# On clients, physics is frozen so this won't be called for real collisions
	# Sounds are triggered based on interpolated velocity instead
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

	# Fire collision - only in debug mode (no lobby)
	if is_local and LobbyManager.get_lobby_id().is_empty():
		if body.name.begins_with("Fire") or body.is_in_group("fire"):
			respawn()
