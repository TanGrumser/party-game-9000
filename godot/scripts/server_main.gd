extends Node

# Dedicated server main script
# Detects headless mode and runs as authoritative physics server

const TICK_RATE: float = 0.05  # 50ms = 20 ticks per second (faster than client's 100ms)

var _is_dedicated_server: bool = false
var _tick_timer: float = 0.0

func _ready() -> void:
	_is_dedicated_server = _detect_headless_mode()

	if _is_dedicated_server:
		print("[Server] Running in DEDICATED SERVER mode")
		_setup_dedicated_server()
	else:
		print("[Server] Running in CLIENT mode")

func _detect_headless_mode() -> bool:
	# Check if running headless (no display)
	var display_name = DisplayServer.get_name()
	if display_name == "headless":
		return true

	# Also check command line args for --server flag
	var args = OS.get_cmdline_args()
	for arg in args:
		if arg == "--server" or arg == "--dedicated":
			return true

	return false

func _setup_dedicated_server() -> void:
	# Disable rendering-related features
	RenderingServer.render_loop_enabled = false

	# Connect to the Bun WebSocket server as a "game server" client
	ServerNetwork.connect_to_relay()

	print("[Server] Dedicated server initialized, tick rate: %.0fms" % (TICK_RATE * 1000))

func is_dedicated_server() -> bool:
	return _is_dedicated_server

static func is_server() -> bool:
	# Static helper to check if running as dedicated server from anywhere
	var display_name = DisplayServer.get_name()
	if display_name == "headless":
		return true
	var args = OS.get_cmdline_args()
	for arg in args:
		if arg == "--server" or arg == "--dedicated":
			return true
	return false
