extends RigidBody2D

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

# Drag state
var _is_dragging: bool = false
var _drag_start_pos: Vector2 = Vector2.ZERO
var _current_drag_pos: Vector2 = Vector2.ZERO

# Drag indicator reference
var _drag_indicator: Node2D = null
const DRAG_INDICATOR_SCENE = preload("res://scenes/drag_indicator.tscn")

func _ready() -> void:
	can_sleep = false  # Never sleep - we need _integrate_forces for network sync
	_visual_position = global_position
	_update_appearance()
	body_entered.connect(_on_body_entered)

func _setup_for_network() -> void:
	"""Called after is_local is set to configure physics appropriately."""
	# Host runs physics for ALL balls (is authoritative)
	# Non-host only runs physics for local ball, freezes others for pure interpolation
	if not is_local and not LobbyManager.is_host():
		freeze = true
		print("[PlayerBall] %s is remote on non-host - physics frozen, using pure interpolation" % player_id)

func _update_appearance() -> void:
	var sprite = get_node_or_null("Sprite2D")
	if sprite:
		sprite.modulate = local_color if is_local else remote_color
		var texture = local_texture if is_local else remote_texture
		if texture:
			sprite.texture = texture

# Network interpolation for smooth remote entity movement
var _interpolator: NetworkInterpolator = NetworkInterpolator.new()

# Network sync state (applied in _integrate_forces)
var _sync_pending: bool = false
var _sync_position: Vector2
var _sync_velocity: Vector2

# Visual smoothing - sprite smoothly follows physics body
var _visual_position: Vector2 = Vector2.ZERO
const VISUAL_SMOOTH_SPEED: float = 15.0  # How fast visual catches up (higher = faster)

# Respawn state (applied in _integrate_forces)
var _respawn_pending: bool = false

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
	# Show indicator on top of ball, extending in the drag direction
	var drag_offset = drag_pos - _drag_start_pos  # How far we've dragged from start
	# Clamp drag offset to max_drag
	if drag_offset.length() > max_drag:
		drag_offset = drag_offset.normalized() * max_drag
	var indicator_end = global_position + drag_offset  # Ball position + drag offset
	_drag_indicator.update_positions(global_position, indicator_end)

func _end_drag(pos: Vector2) -> void:
	if not _is_dragging:
		return

	_is_dragging = false
	_current_drag_pos = pos

	# Hide indicator
	if _drag_indicator:
		_drag_indicator.hide_indicator()

	# Calculate shot: direction from current drag position toward start position
	# (drag away = shoot in opposite direction of drag)
	var drag_offset = pos - _drag_start_pos
	var distance = drag_offset.length()

	if distance < min_drag:
		return  # Too short a drag, ignore

	# Clamp distance to max_drag and calculate strength (0 to 1)
	var clamped_distance = minf(distance, max_drag)
	var strength = inverse_lerp(min_drag, max_drag, clamped_distance)

	# Direction is opposite of drag
	var direction = -drag_offset.normalized()
	var impulse = direction * max_impulse * strength
	apply_central_impulse(impulse)

	# Play shoot sound with volume based on strength
	shoot_sound.volume_db = lerpf(-20.0, -10.0, strength)
	shoot_sound.play()

	print("[PlayerBall] Drag shot: player_id=%s, impulse=%s (strength: %.2f)" % [player_id, impulse, strength])

	# Send shot to other players
	LobbyManager.send_ball_shot(
		player_id,
		direction.normalized(),
		max_impulse * strength
	)
	print("[PlayerBall] Sent ball_shot for player_id=%s" % player_id)

func get_spawn_position() -> Vector2:
	return spawn_position

func set_spawn_position(pos: Vector2) -> void:
	spawn_position = pos

var _stored_collision_layer: int = 0
var _stored_collision_mask: int = 0

func respawn() -> void:
	burnt_sound.play()
	print("[PlayerBall] %s died, respawning in %.1f seconds at %s" % [player_id, respawn_delay, spawn_position])

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

	# Send DEATH event immediately (only local player triggers this)
	if is_local:
		LobbyManager.send_ball_death(player_id)

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
	_visual_position = spawn_position  # Snap visual to spawn position
	sleeping = false
	print("[PlayerBall] %s respawned at %s" % [player_id, spawn_position])

	# Send RESPAWN event after timer (only local player triggers this)
	if is_local:
		LobbyManager.send_ball_respawn(player_id, spawn_position)

# Called by game.gd to sync state from network
func sync_from_network(pos: Vector2, vel: Vector2, timestamp: int = 0) -> void:
	if is_local:
		# Local player: hard snap physics, visual will smooth catch up
		# Only correct if significantly diverged (>50px)
		var pos_diff = (pos - global_position).length()
		if pos_diff > 50.0:
			_sync_position = pos
			_sync_velocity = vel
			_sync_pending = true
			sleeping = false
		return

	# Remote players: add to interpolation buffer (physics is frozen)
	_interpolator.add_state(pos, vel, timestamp)

func _process(delta: float) -> void:
	var sprite = get_node_or_null("Sprite2D")

	# Host runs physics for all balls - just do visual smoothing
	if LobbyManager.is_host():
		_visual_position = _visual_position.lerp(global_position, VISUAL_SMOOTH_SPEED * delta)
		if sprite:
			sprite.global_position = _visual_position
		return

	# Non-host: local player runs physics with visual smoothing
	if is_local:
		_visual_position = _visual_position.lerp(global_position, VISUAL_SMOOTH_SPEED * delta)
		if sprite:
			sprite.global_position = _visual_position
		return

	# Non-host remote players: pure interpolation (physics is frozen)
	_interpolator.update()

	if _interpolator.has_valid_state:
		# Directly set position - no physics simulation to fight
		global_position = _interpolator.interpolated_position
		# Visual follows directly since we're not doing physics correction
		_visual_position = global_position
		if sprite:
			sprite.global_position = _visual_position

# Apply network sync during physics step (safe way to modify RigidBody2D)
func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	if _respawn_pending:
		_respawn_pending = false
		state.transform.origin = spawn_position
		state.linear_velocity = Vector2.ZERO
		_visual_position = spawn_position  # Snap visual too
		return

	if _sync_pending:
		_sync_pending = false
		# Hard snap physics to authoritative state
		# Visual will smoothly catch up in _process()
		state.transform.origin = _sync_position
		state.linear_velocity = _sync_velocity

func handle_remote_death() -> void:
	"""Called when another client reports this ball died."""
	print("[PlayerBall] %s remote death" % player_id)

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
	freeze = true  # Freeze on both host and non-host during death
	global_position = Vector2(-99999, -99999)
	_visual_position = global_position

func handle_remote_respawn(spawn_pos: Vector2) -> void:
	"""Called when another client reports this ball respawned."""
	print("[PlayerBall] %s remote respawn at %s" % [player_id, spawn_pos])

	# Clear interpolation buffer to prevent sliding
	_interpolator.clear()

	# Update spawn position if provided
	if spawn_pos != Vector2.ZERO:
		spawn_position = spawn_pos

	# Directly set position
	global_position = spawn_pos
	_visual_position = spawn_pos

	# Restore visibility and collision
	visible = true

	# Host unfreezes (runs physics for all balls)
	# Non-host keeps remote balls frozen (pure interpolation)
	if LobbyManager.is_host():
		freeze = false

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

	# Only local player handles their own collision logic
	if not is_local:
		return

	print("[PlayerBall] %s touched: %s" % [player_id, body.name])
	# Check if it's a fire obstacle (by name or group)
	if body.name.begins_with("Fire") or body.is_in_group("fire"):
		respawn()
