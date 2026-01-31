extends RigidBody2D

@export var max_impulse: float = 800.0  # Maximum shot power
@export var min_drag: float = 20.0  # Minimum drag distance to register a shot
@export var max_drag: float = 200.0  # Maximum drag distance (clamped)
@export var local_color: Color = Color(0.2, 0.8, 0.4)  # Green for local player
@export var remote_color: Color = Color(0.8, 0.3, 0.3)  # Red for other players

var player_id: String = ""
var is_local: bool = false:
	set(value):
		is_local = value
		_update_color()

# Drag state
var _is_dragging: bool = false
var _drag_start_pos: Vector2 = Vector2.ZERO
var _current_drag_pos: Vector2 = Vector2.ZERO

# Drag indicator reference
var _drag_indicator: Node2D = null
const DRAG_INDICATOR_SCENE = preload("res://scenes/drag_indicator.tscn")

func _ready() -> void:
	can_sleep = false  # Never sleep - we need _integrate_forces for network sync
	_update_color()

	# Instantiate drag indicator (only for local player, done when needed)

func _update_color() -> void:
	var sprite = get_node_or_null("Sprite2D")
	if sprite:
		sprite.modulate = local_color if is_local else remote_color

# Network sync state (applied in _integrate_forces)
var _sync_pending: bool = false
var _sync_position: Vector2
var _sync_velocity: Vector2

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

	print("[PlayerBall] Drag shot: %s, impulse: %s (strength: %.2f)" % [pos, impulse, strength])

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
