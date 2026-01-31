extends RigidBody2D

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

func respawn() -> void:
	_respawn_pending = true
	sleeping = false
	burnt_sound.play()
	print("[MainBall] Respawning at %s" % _spawn_position)

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
