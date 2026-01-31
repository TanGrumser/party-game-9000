extends Control

var _player_boxes: Dictionary = {}  # player_id -> HBoxContainer
var _is_ready: bool = false

func _ready() -> void:
	LobbyManager.player_joined.connect(_on_player_joined)
	LobbyManager.player_left.connect(_on_player_left)
	LobbyManager.player_ready_changed.connect(_on_player_ready_changed)
	LobbyManager.all_players_ready.connect(_on_all_players_ready)
	LobbyManager.game_started.connect(_on_game_started)
	LobbyManager.connection_error.connect(_on_connection_error)

	%StartGameButton.visible = false
	_update_title()
	_rebuild_player_list()

func _update_title() -> void:
	%Title.text = "Lobby: %s" % LobbyManager.get_lobby_id()
	_update_subtitle()

func _update_subtitle() -> void:
	var player_count = LobbyManager.get_players().size()
	if player_count < 2:
		%Subtitle.text = "Waiting for more players..."
	elif LobbyManager.are_all_players_ready():
		%Subtitle.text = "All players ready!"
	else:
		%Subtitle.text = "Waiting for players to ready up..."

func _rebuild_player_list() -> void:
	# Clear existing player boxes
	for child in %PlayersContainer.get_children():
		child.queue_free()
	_player_boxes.clear()

	# Create player boxes for all current players
	for player in LobbyManager.get_players():
		_add_player_box(player.id, player.name, player.get("isHost", false), player.get("isReady", false))

	_update_ui()

func _add_player_box(player_id: String, player_name: String, is_host: bool, is_ready: bool) -> void:
	var hbox = HBoxContainer.new()
	hbox.name = "Player_" + player_id
	hbox.set_meta("player_id", player_id)

	# Ready indicator
	var ready_indicator = Label.new()
	ready_indicator.name = "ReadyIndicator"
	ready_indicator.custom_minimum_size = Vector2(30, 0)
	ready_indicator.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ready_indicator.text = "✓" if is_ready else "○"
	ready_indicator.add_theme_color_override("font_color", Color.GREEN if is_ready else Color.GRAY)
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

	# Ready status text
	var status_label = Label.new()
	status_label.name = "StatusLabel"
	status_label.text = "Ready" if is_ready else "Not Ready"
	status_label.add_theme_color_override("font_color", Color.GREEN if is_ready else Color.ORANGE)
	hbox.add_child(status_label)

	%PlayersContainer.add_child(hbox)
	_player_boxes[player_id] = hbox

func _update_player_box(player_id: String, is_ready: bool) -> void:
	if not _player_boxes.has(player_id):
		return

	var hbox = _player_boxes[player_id]
	var ready_indicator = hbox.get_node("ReadyIndicator")
	var status_label = hbox.get_node("StatusLabel")

	ready_indicator.text = "✓" if is_ready else "○"
	ready_indicator.add_theme_color_override("font_color", Color.GREEN if is_ready else Color.GRAY)

	status_label.text = "Ready" if is_ready else "Not Ready"
	status_label.add_theme_color_override("font_color", Color.GREEN if is_ready else Color.ORANGE)

func _update_ui() -> void:
	_update_subtitle()
	_update_ready_button()
	_update_start_button()

func _update_ready_button() -> void:
	%ReadyButton.text = "Cancel Ready" if _is_ready else "Ready"

func _update_start_button() -> void:
	var is_host = LobbyManager.is_host()
	var all_ready = LobbyManager.are_all_players_ready()

	%StartGameButton.visible = is_host and all_ready

	if is_host and not all_ready:
		%StatusLabel.text = "Waiting for all players to be ready..."
	elif not is_host:
		%StatusLabel.text = "Waiting for host to start the game..."
	else:
		%StatusLabel.text = ""

# ============ BUTTON HANDLERS ============

func _on_ready_button_pressed() -> void:
	_is_ready = not _is_ready
	LobbyManager.set_ready(_is_ready)
	_update_ready_button()

func _on_start_game_pressed() -> void:
	if LobbyManager.is_host() and LobbyManager.are_all_players_ready():
		LobbyManager.start_game()

# ============ SIGNAL HANDLERS ============

func _on_player_joined(player_id: String, player_name: String, is_host: bool) -> void:
	if not _player_boxes.has(player_id):
		_add_player_box(player_id, player_name, is_host, false)
	_update_ui()

func _on_player_left(player_id: String, _player_name: String) -> void:
	if _player_boxes.has(player_id):
		var box = _player_boxes[player_id]
		box.queue_free()
		_player_boxes.erase(player_id)
	_update_ui()

func _on_player_ready_changed(player_id: String, is_ready: bool) -> void:
	_update_player_box(player_id, is_ready)
	_update_ui()

func _on_all_players_ready() -> void:
	_update_ui()

func _on_game_started(_host_id: String) -> void:
	get_tree().change_scene_to_file("res://scenes/Game.tscn")

func _on_connection_error(message: String) -> void:
	%StatusLabel.text = "Error: %s" % message
