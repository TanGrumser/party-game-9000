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
	_update_appearance()
	body_entered.connect(_on_body_entered)

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

# Correction settings for local player
const LOCAL_CORRECTION_THRESHOLD: float = 50.0  # Pixels before correcting local player
const LOCAL_CORRECTION_RATE: float = 0.2  # Gentle correction rate
const REMOTE_CORRECTION_RATE: float = 0.3  # Correction rate for remote entities

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

	# Send respawn event to network (only local player triggers this)
	if is_local:
		LobbyManager.send_ball_respawn(player_id, spawn_position)

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
	print("[PlayerBall] %s respawned at %s" % [player_id, spawn_position])

# Called by game.gd to sync state from network
func sync_from_network(pos: Vector2, vel: Vector2, timestamp: int = 0) -> void:
	if is_local:
		# Local player: only correct if significantly diverged
		var pos_diff = (pos - global_position).length()
		if pos_diff > LOCAL_CORRECTION_THRESHOLD:
			# Queue gentle correction
			_sync_position = global_position.lerp(pos, LOCAL_CORRECTION_RATE)
			_sync_velocity = linear_velocity.lerp(vel, LOCAL_CORRECTION_RATE)
			_sync_pending = true
			sleeping = false
		return

	# Remote players: add to interpolation buffer
	_interpolator.add_state(pos, vel, timestamp)

func _process(delta: float) -> void:
	# Skip interpolation for local player or host
	if is_local or LobbyManager.is_host():
		return

	# Update interpolator and get interpolated values
	_interpolator.update()

	if _interpolator.has_valid_state:
		_sync_position = _interpolator.interpolated_position
		_sync_velocity = _interpolator.interpolated_velocity
		_sync_pending = true
		sleeping = false

# Apply network sync during physics step (safe way to modify RigidBody2D)
func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	if _respawn_pending:
		_respawn_pending = false
		state.transform.origin = spawn_position
		state.linear_velocity = Vector2.ZERO
		return

	if _sync_pending:
		_sync_pending = false

		if is_local:
			# Local player: already lerped in sync_from_network, apply directly
			state.transform.origin = _sync_position
			state.linear_velocity = _sync_velocity
		else:
			# Remote players: smooth correction toward interpolated target
			var pos_error = _sync_position - state.transform.origin
			var vel_error = _sync_velocity - state.linear_velocity

			state.transform.origin += pos_error * REMOTE_CORRECTION_RATE
			state.linear_velocity += vel_error * REMOTE_CORRECTION_RATE

func handle_remote_respawn(spawn_pos: Vector2) -> void:
	"""Called when another client reports this ball respawned."""
	print("[PlayerBall] %s remote respawn at %s" % [player_id, spawn_pos])

	# Clear interpolation buffer to prevent sliding
	_interpolator.clear()

	# Update spawn position if provided
	if spawn_pos != Vector2.ZERO:
		spawn_position = spawn_pos

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
	# Only local player handles their own collision
	if not is_local:
		return

	print("[PlayerBall] %s touched: %s" % [player_id, body.name])
	# Check if it's a fire obstacle (by name or group)
	if body.name.begins_with("Fire") or body.is_in_group("fire"):
		respawn()
