extends Control

var _players: Array = []

func _ready() -> void:
	LobbyManager.lobby_created.connect(_on_lobby_created)
	LobbyManager.lobby_joined.connect(_on_lobby_joined)
	LobbyManager.connection_error.connect(_on_connection_error)
	LobbyManager.player_joined.connect(_on_player_joined)
	LobbyManager.player_left.connect(_on_player_left)
	LobbyManager.game_started.connect(_on_game_started)

	%StartGame.visible = false

func _on_create_game_pressed() -> void:
	var player_name = %NameInput.text.strip_edges()
	if player_name.is_empty():
		player_name = "Player"

	%NameInput.set_meta("stored_name", player_name)
	LobbyManager.create_lobby()

func _on_join_game_pressed() -> void:
	var player_name = %NameInput.text.strip_edges()
	var lobby_code = %LobbyCodeInput.text.strip_edges().to_upper()

	if player_name.is_empty():
		player_name = "Player"

	if lobby_code.is_empty():
		%StatusLabel.text = "Please enter a lobby code"
		return

	LobbyManager.join_lobby(lobby_code, player_name)

func _on_start_game_pressed() -> void:
	if LobbyManager.is_host():
		LobbyManager.start_game()

func _update_ui() -> void:
	var lobby_id = LobbyManager.get_lobby_id()
	var is_host = LobbyManager.is_host()
	var player_count = _players.size()

	var status = "Lobby: %s\n" % lobby_id
	status += "Players (%d):\n" % player_count
	for p in _players:
		var host_marker = " (Host)" if p.get("isHost", false) else ""
		status += "  - %s%s\n" % [p.get("name", "Unknown"), host_marker]

	if is_host:
		if player_count >= 2:
			status += "\nReady to start!"
		else:
			status += "\nWaiting for more players..."
	else:
		status += "\nWaiting for host to start..."

	%StatusLabel.text = status

	# Show start button only for host with 2+ players
	%StartGame.visible = is_host and player_count >= 2

# ============ SIGNAL HANDLERS ============

func _on_lobby_created(lobby_id: String) -> void:
	var player_name = %NameInput.get_meta("stored_name", "Player")
	LobbyManager.join_lobby(lobby_id, player_name)

func _on_lobby_joined(lobby_id: String, player_id: String, is_host: bool) -> void:
	print("[MainMenu] Joined lobby %s as %s (host: %s)" % [lobby_id, player_id, is_host])

func _on_player_joined(player_id: String, player_name: String, is_host: bool) -> void:
	# Update or add player
	var found = false
	for p in _players:
		if p.id == player_id:
			found = true
			break
	if not found:
		_players.append({"id": player_id, "name": player_name, "isHost": is_host})
	_update_ui()

func _on_player_left(player_id: String, _player_name: String) -> void:
	_players = _players.filter(func(p): return p.id != player_id)
	_update_ui()

func _on_connection_error(message: String) -> void:
	%StatusLabel.text = "Error: %s" % message

func _on_game_started(_host_id: String) -> void:
	get_tree().change_scene_to_file("res://scenes/Game.tscn")
