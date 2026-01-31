extends Node2D

# References to the circle sprites
@onready var circles: Array[Sprite2D] = [
	$Circle_1,
	$Circle_2,
	$Circle_3,
	$Circle_4,
	$Circle_5,
]

func _ready() -> void:
	visible = false

# Update circle positions between start and current drag position
# Circle_1 (largest) is closest to ball/start, Circle_5 (smallest) closest to drag position
func update_positions(start_pos: Vector2, drag_pos: Vector2) -> void:
	var count = circles.size()
	for i in range(count):
		# t goes from 0.0 (at start_pos) to 1.0 (at drag_pos)
		# We want circles spread between them, not at the endpoints
		var t = float(i + 1) / float(count + 1)
		circles[i].global_position = start_pos.lerp(drag_pos, t)

func show_indicator() -> void:
	visible = true

func hide_indicator() -> void:
	visible = false
