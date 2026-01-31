extends Camera2D

@export var padding: float = 300.0  # Extra space around the targets
@export var min_bounds: float = 600.0  # Minimum bounds size (prevents over-zooming)
@export var min_zoom: float = 0.3  # Don't zoom out too much
@export var max_zoom: float = 1.5  # Don't zoom in too much
@export var smooth_speed: float = 12.0  # Camera movement smoothness

var _targets: Array[Node2D] = []

func _ready() -> void:
	# Start with default zoom
	zoom = Vector2.ONE

func set_targets(targets: Array[Node2D]) -> void:
	_targets = targets

func add_target(target: Node2D) -> void:
	if target not in _targets:
		_targets.append(target)

func remove_target(target: Node2D) -> void:
	_targets.erase(target)

func _process(delta: float) -> void:
	if _targets.is_empty():
		return

	# Filter out freed targets
	_targets = _targets.filter(func(t): return is_instance_valid(t))

	if _targets.is_empty():
		return

	# Get visible targets only (ignore dead/respawning balls)
	var visible_targets = _targets.filter(func(t): return t.visible)

	if visible_targets.is_empty():
		return

	# Calculate bounding rect of all visible targets
	var bounds = _calculate_bounds(visible_targets)

	# Target position is center of bounds
	var target_pos = bounds.get_center()

	# Smoothly move camera
	global_position = global_position.lerp(target_pos, smooth_speed * delta)

	# Calculate zoom to fit bounds with padding
	var target_zoom = _calculate_zoom(bounds)
	zoom = zoom.lerp(target_zoom, smooth_speed * delta)

func _calculate_bounds(targets: Array) -> Rect2:
	var min_pos = targets[0].global_position
	var max_pos = targets[0].global_position

	for target in targets:
		min_pos.x = minf(min_pos.x, target.global_position.x)
		min_pos.y = minf(min_pos.y, target.global_position.y)
		max_pos.x = maxf(max_pos.x, target.global_position.x)
		max_pos.y = maxf(max_pos.y, target.global_position.y)

	# Add padding
	min_pos -= Vector2(padding, padding)
	max_pos += Vector2(padding, padding)

	# Enforce minimum bounds size
	var size = max_pos - min_pos
	var center = (min_pos + max_pos) / 2.0

	if size.x < min_bounds:
		min_pos.x = center.x - min_bounds / 2.0
		max_pos.x = center.x + min_bounds / 2.0
	if size.y < min_bounds:
		min_pos.y = center.y - min_bounds / 2.0
		max_pos.y = center.y + min_bounds / 2.0

	return Rect2(min_pos, max_pos - min_pos)

func _calculate_zoom(bounds: Rect2) -> Vector2:
	var viewport_size = get_viewport_rect().size

	# Calculate zoom needed to fit bounds
	var zoom_x = viewport_size.x / bounds.size.x
	var zoom_y = viewport_size.y / bounds.size.y

	# Use the smaller zoom to ensure everything fits
	var target_zoom = minf(zoom_x, zoom_y)

	# Clamp zoom
	target_zoom = clampf(target_zoom, min_zoom, max_zoom)

	return Vector2(target_zoom, target_zoom)
