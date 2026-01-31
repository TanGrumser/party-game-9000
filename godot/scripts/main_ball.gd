extends RigidBody2D

func _ready() -> void:
	can_sleep = false  # Never sleep - we need _integrate_forces for network sync

# Network sync state (applied in _integrate_forces)
var _sync_pending: bool = false
var _sync_position: Vector2
var _sync_velocity: Vector2

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
