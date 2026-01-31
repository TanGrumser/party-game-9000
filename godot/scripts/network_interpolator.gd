class_name NetworkInterpolator
extends RefCounted

# Configuration
const BUFFER_SIZE: int = 20  # ~2 seconds at 100ms intervals
const INTERPOLATION_DELAY_MS: float = 100.0  # Render 100ms behind latest state
const MAX_EXTRAPOLATION_MS: float = 200.0  # Max time to extrapolate
const TIME_OFFSET_SAMPLES: int = 10  # Samples for smoothing time offset

# State buffer: [{timestamp, position, velocity}, ...]
var _state_buffer: Array[Dictionary] = []

# Time synchronization
var _time_offset: float = 0.0  # local_time - host_time
var _time_offset_samples: Array[float] = []

# Result of interpolation
var interpolated_position: Vector2 = Vector2.ZERO
var interpolated_velocity: Vector2 = Vector2.ZERO
var has_valid_state: bool = false

func add_state(pos: Vector2, vel: Vector2, host_timestamp: int) -> void:
	# Update time offset estimate
	_update_time_offset(host_timestamp)

	var state = {
		"timestamp": host_timestamp,
		"position": pos,
		"velocity": vel
	}

	# Insert maintaining timestamp order
	var inserted = false
	for i in range(_state_buffer.size()):
		if _state_buffer[i].timestamp > host_timestamp:
			_state_buffer.insert(i, state)
			inserted = true
			break

	if not inserted:
		_state_buffer.append(state)

	# Prune old states
	while _state_buffer.size() > BUFFER_SIZE:
		_state_buffer.pop_front()

func _update_time_offset(host_timestamp: int) -> void:
	var local_time = Time.get_ticks_msec()
	var offset = float(local_time - host_timestamp)

	_time_offset_samples.append(offset)
	if _time_offset_samples.size() > TIME_OFFSET_SAMPLES:
		_time_offset_samples.pop_front()

	# Use median for robustness against outliers
	var sorted = _time_offset_samples.duplicate()
	sorted.sort()
	_time_offset = sorted[sorted.size() / 2]

func update() -> void:
	"""Call this every frame to update interpolated values."""
	has_valid_state = false

	if _state_buffer.is_empty():
		return

	# Calculate render time (current time minus delay, adjusted for time offset)
	var render_time = Time.get_ticks_msec() - _time_offset - INTERPOLATION_DELAY_MS

	# Find two states to interpolate between
	var state_before: Dictionary = {}
	var state_after: Dictionary = {}

	for i in range(_state_buffer.size() - 1):
		if _state_buffer[i].timestamp <= render_time and _state_buffer[i + 1].timestamp >= render_time:
			state_before = _state_buffer[i]
			state_after = _state_buffer[i + 1]
			break

	if state_before.is_empty() or state_after.is_empty():
		# Not enough data - extrapolate from latest state
		if _state_buffer.size() > 0:
			_extrapolate(_state_buffer.back(), render_time)
		return

	# Calculate interpolation factor (0 to 1)
	var time_range = state_after.timestamp - state_before.timestamp
	var t = 0.0
	if time_range > 0:
		t = (render_time - state_before.timestamp) / float(time_range)
	t = clampf(t, 0.0, 1.0)

	# Interpolate
	interpolated_position = state_before.position.lerp(state_after.position, t)
	interpolated_velocity = state_before.velocity.lerp(state_after.velocity, t)
	has_valid_state = true

func _extrapolate(last_state: Dictionary, render_time: float) -> void:
	var time_since = render_time - last_state.timestamp

	# Clamp extrapolation time
	if time_since > MAX_EXTRAPOLATION_MS:
		time_since = MAX_EXTRAPOLATION_MS

	if time_since < 0:
		# Render time is before our oldest state - just use that state
		interpolated_position = last_state.position
		interpolated_velocity = last_state.velocity
		has_valid_state = true
		return

	# Simple physics extrapolation: position += velocity * time
	interpolated_position = last_state.position + last_state.velocity * (time_since / 1000.0)
	interpolated_velocity = last_state.velocity
	has_valid_state = true

func get_latest_state() -> Dictionary:
	"""Get the most recent state (for fallback or local player correction)."""
	if _state_buffer.is_empty():
		return {}
	return _state_buffer.back()

func clear() -> void:
	"""Clear all buffered states."""
	_state_buffer.clear()
	_time_offset_samples.clear()
	has_valid_state = false
