extends CanvasLayer

signal closed()

var _player_boxes: Dictionary = {}  # player_id -> HBoxContainer
var _is_ready: bool = false
var _next_level_path: String = ""
var _is_local_mode: bool = false

func _ready() -> void:
	_is_local_mode = LobbyManager.get_lobby_id().is_empty()

	if _is_local_mode:
		_setup_local_mode()
	else:
		_setup_network_mode()

func _setup_local_mode() -> void:
	"""Simplified UI for debug/local play."""
	%ReadyButton.visible = false
	%NextLevelButton.visible = true
	%StatusLabel.text = "Debug Mode"
	# Hide player list in local mode
	%PlayersLabel.visible = false
	%PlayersContainer.visible = false

func _setup_network_mode() -> void:
	"""Full multiplayer UI."""
	LobbyManager.level_ready_changed.connect(_on_level_ready_changed)
	LobbyManager.all_players_level_ready.connect(_on_all_players_level_ready)
	LobbyManager.level_started.connect(_on_level_started)

	_rebuild_player_list()
	_update_ui()

func set_next_level_path(path: String) -> void:
	_next_level_path = path
	if _next_level_path.is_empty():
		%NextLevelButton.text = "Back to Menu"
	else:
		%NextLevelButton.text = "Next Level"

func _rebuild_player_list() -> void:
	# Clear existing
	for child in %PlayersContainer.get_children():
		child.queue_free()
	_player_boxes.clear()

	# Build from current players
	for player in LobbyManager.get_players():
		_add_player_box(player.id, player.name, player.get("isHost", false), player.get("isLevelReady", false))

	_update_ui()

func _add_player_box(player_id: String, player_name: String, is_host: bool, is_level_ready: bool) -> void:
	var hbox = HBoxContainer.new()
	hbox.name = "Player_" + player_id

	# Ready indicator
	var ready_indicator = Label.new()
	ready_indicator.name = "ReadyIndicator"
	ready_indicator.custom_minimum_size = Vector2(30, 0)
	ready_indicator.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ready_indicator.text = "✓" if is_level_ready else "○"
	ready_indicator.add_theme_color_override("font_color", Color.GREEN if is_level_ready else Color.GRAY)
	hbox.add_child(ready_indicator)

	# Player name
	var name_label = Label.new()
	name_label.name = "NameLabel"
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var display_name = player_name
	if is_host:
		display_name += " (Host)"
	if player_id == LobbyManager.get_player_id():
		display_name += " (You)"
	name_label.text = display_name
	hbox.add_child(name_label)

	# Status
	var status_label = Label.new()
	status_label.name = "StatusLabel"
	status_label.text = "Ready" if is_level_ready else "Not Ready"
	status_label.add_theme_color_override("font_color", Color.GREEN if is_level_ready else Color.ORANGE)
	hbox.add_child(status_label)

	%PlayersContainer.add_child(hbox)
	_player_boxes[player_id] = hbox

func _update_player_box(player_id: String, is_level_ready: bool) -> void:
	if not _player_boxes.has(player_id):
		return

	var hbox = _player_boxes[player_id]
	var ready_indicator = hbox.get_node("ReadyIndicator")
	var status_label = hbox.get_node("StatusLabel")

	ready_indicator.text = "✓" if is_level_ready else "○"
	ready_indicator.add_theme_color_override("font_color", Color.GREEN if is_level_ready else Color.GRAY)
	status_label.text = "Ready" if is_level_ready else "Not Ready"
	status_label.add_theme_color_override("font_color", Color.GREEN if is_level_ready else Color.ORANGE)

func _update_ui() -> void:
	_update_ready_button()
	_update_next_level_button()

func _update_ready_button() -> void:
	%ReadyButton.text = "Cancel Ready" if _is_ready else "Ready for Next Level"

func _update_next_level_button() -> void:
	var is_host = LobbyManager.is_host()
	var all_ready = LobbyManager.are_all_players_level_ready()

	%NextLevelButton.visible = is_host and all_ready

	if is_host and not all_ready:
		%StatusLabel.text = "Waiting for all players to be ready..."
	elif not is_host:
		%StatusLabel.text = "Waiting for host to start next level..."
	else:
		%StatusLabel.text = ""

# Button handlers
func _on_ready_button_pressed() -> void:
	_is_ready = not _is_ready
	LobbyManager.set_level_ready(_is_ready)
	_update_ready_button()

func _on_next_level_button_pressed() -> void:
	if _is_local_mode:
		# Local mode - transition immediately
		_do_level_transition()
	else:
		# Network mode - host triggers transition
		if LobbyManager.is_host() and LobbyManager.are_all_players_level_ready():
			LobbyManager.start_next_level(_next_level_path)

# Signal handlers
func _on_level_ready_changed(player_id: String, is_level_ready: bool) -> void:
	_update_player_box(player_id, is_level_ready)
	_update_ui()

func _on_all_players_level_ready() -> void:
	_update_ui()

func _on_level_started(next_level: String) -> void:
	# Use the level from server if provided, otherwise use local path
	var level_to_load = next_level if not next_level.is_empty() else _next_level_path
	_do_level_transition(level_to_load)

func _do_level_transition(level_path: String = "") -> void:
	var target = level_path if not level_path.is_empty() else _next_level_path
	if target.is_empty():
		target = "res://scenes/main_menu.tscn"

	closed.emit()
	get_tree().change_scene_to_file(target)
