extends Node2D

@export var rotation_speed: float = 1.0  # Radians per second (positive = clockwise)
@export var arm_length: float = 400.0  # Total length of the arm
@export var flame_count: int = 5  # Number of flames (for reference, actual count is in scene)

func _process(delta: float) -> void:
	rotation += rotation_speed * delta
