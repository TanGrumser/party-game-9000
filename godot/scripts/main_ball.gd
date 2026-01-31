extends RigidBody2D

@export var respawn_delay: float = 2.0  # Seconds before respawn

@onready var burnt_sound: AudioStreamPlayer = $BurntSound

var _spawn_position: Vector2

func _ready() -> void:
	can_sleep = false  # Never sleep - we need _integrate_forces for network sync
	_spawn_position = global_position

# Network sync state (applied in _integrate_forces)
var _sync_pending: bool = false
var _sync_position: Vector2
var _sync_velocity: Vector2

# Respawn state (applied in _integrate_forces)
var _respawn_pending: bool = false

# Called by game.gd to sync state from network
func sync_from_network(pos: Vector2, vel: Vector2) -> void:
	_sync_position = pos
	_sync_velocity = vel
	_sync_pending = true
	sleeping = false  # Wake up body so _integrate_forces gets called

func get_spawn_position() -> Vector2:
	return _spawn_position

func set_spawn_position(pos: Vector2) -> void:
	_spawn_position = pos

var _stored_collision_layer: int = 0
var _stored_collision_mask: int = 0

func respawn() -> void:
	burnt_sound.play()
	print("[MainBall] Died, respawning in %.1f seconds at %s" % [respawn_delay, _spawn_position])

	# Store collision settings and disable
	_stored_collision_layer = collision_layer
	_stored_collision_mask = collision_mask
	collision_layer = 0
	collision_mask = 0

	# Hide, freeze, and move far away
	visible = false
	freeze = true
	global_position = Vector2(-99999, -99999)

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

# Apply network sync during physics step (safe way to modify RigidBody2D)
func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	if _respawn_pending:
		_respawn_pending = false
		state.transform.origin = _spawn_position
		state.linear_velocity = Vector2.ZERO
		return

	if _sync_pending:
		_sync_pending = false
		state.transform.origin = _sync_position
		state.linear_velocity = _sync_velocity

func _on_body_entered(body: Node) -> void:
	print("[MainBall] Touched: %s" % body.name)
	# Check if it's a fire obstacle (by name or group)
	if body.name.begins_with("Fire") or body.is_in_group("fire"):
		respawn()
