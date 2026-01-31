extends Control

func _ready() -> void:
	LobbyManager.lobby_created.connect(_on_lobby_created)
	LobbyManager.lobby_joined.connect(_on_lobby_joined)
	LobbyManager.connection_error.connect(_on_connection_error)

	%StartGame.visible = false

func _on_create_game_pressed() -> void:
	var player_name = %NameInput.text.strip_edges()
	if player_name.is_empty():
		player_name = "Player"

	%NameInput.set_meta("stored_name", player_name)
	%StatusLabel.text = "Creating lobby..."
	LobbyManager.create_lobby()

func _on_join_game_pressed() -> void:
	var player_name = %NameInput.text.strip_edges()
	var lobby_code = %LobbyCodeInput.text.strip_edges().to_upper()

	if player_name.is_empty():
		player_name = "Player"

	if lobby_code.is_empty():
		%StatusLabel.text = "Please enter a lobby code"
		return

	%StatusLabel.text = "Joining lobby..."
	LobbyManager.join_lobby(lobby_code, player_name)

func _on_start_game_pressed() -> void:
	# This button is hidden, but kept for backwards compatibility
	if LobbyManager.is_host():
		LobbyManager.start_game()

# ============ SIGNAL HANDLERS ============

func _on_lobby_created(lobby_id: String) -> void:
	var player_name = %NameInput.get_meta("stored_name", "Player")
	%StatusLabel.text = "Lobby created: %s\nJoining..." % lobby_id
	LobbyManager.join_lobby(lobby_id, player_name)

func _on_lobby_joined(_lobby_id: String, _player_id: String, _is_host: bool) -> void:
	# Transition to lobby scene
	get_tree().change_scene_to_file("res://lobby.tscn")

func _on_connection_error(message: String) -> void:
	%StatusLabel.text = "Error: %s" % message
