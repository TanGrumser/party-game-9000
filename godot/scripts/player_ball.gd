extends RigidBody2D

@export var max_impulse: float = 800.0
@export var min_distance: float = 20.0  # Closest click distance for max power
@export var max_distance: float = 300.0  # Farthest click still registers

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_handle_click(event.position)
	elif event is InputEventScreenTouch:
		if event.pressed:
			_handle_click(event.position)

func _handle_click(click_pos: Vector2) -> void:
	var ball_pos = global_position
	var direction = ball_pos - click_pos  # Opposite direction (away from click)
	var distance = direction.length()

	if distance < 1.0:
		return  # Clicked exactly on ball, ignore

	# Closer = stronger impulse
	# Map distance: min_distance -> max_impulse, max_distance -> 0
	var strength = inverse_lerp(max_distance, min_distance, distance)
	strength = clampf(strength, 0.0, 1.0)

	if strength <= 0.0:
		return  # Too far away

	var impulse = direction.normalized() * max_impulse * strength
	apply_central_impulse(impulse)

	print("[PlayerBall] Click at %s, impulse: %s (strength: %.2f)" % [click_pos, impulse, strength])

	# Send shot to other players
	LobbyManager.send_ball_shot(
		name,
		direction.normalized(),
		max_impulse * strength
	)
