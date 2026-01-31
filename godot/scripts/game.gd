extends Node2D

func _ready() -> void:
	print("[Game] Scene loaded")
	print("[Game] Connected to lobby: %s" % LobbyManager.get_lobby_id())
	print("[Game] Player ID: %s" % LobbyManager.get_player_id())
	print("[Game] Is host: %s" % LobbyManager.is_host())

	# Connect to game signals
	LobbyManager.game_state_received.connect(_on_game_state_received)
	LobbyManager.ball_shot_received.connect(_on_ball_shot_received)

	%LobbyLabel.text = "Lobby: %s | %s" % [
		LobbyManager.get_lobby_id(),
		"HOST" if LobbyManager.is_host() else "PLAYER"
	]

func _on_game_state_received(state: Dictionary) -> void:
	# Host sends this, other players receive it
	if not LobbyManager.is_host():
		print("[Game] Received game state: %s" % state)
		# TODO: Update ball positions from state

func _on_ball_shot_received(player_id: String, shot_data: Dictionary) -> void:
	print("[Game] Ball shot from %s: %s" % [player_id, shot_data])
	# TODO: Apply shot to physics

func _on_back_pressed() -> void:
	LobbyManager.return_to_lobby()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
