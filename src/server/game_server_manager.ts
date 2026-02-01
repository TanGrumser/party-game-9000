import { spawn, type Subprocess } from "bun";
import { join } from "path";

interface GameServer {
  process: Subprocess;
  lobbyId: string;
  startTime: number;
}

// Active game servers (one per lobby)
const gameServers = new Map<string, GameServer>();

// Path to Godot executable (configurable via env)
const GODOT_PATH = "/usr/local/bin/godot";
const PROJECT_PATH = join(import.meta.dir, "../../godot");

// Level scene to load (can be made dynamic later)
const LEVEL_SCENE = "res://scenes/level_1.tscn";

export function startGameServer(lobbyId: string): boolean {
  if (gameServers.has(lobbyId)) {
    console.log(`[GameServerManager] Server already running for lobby ${lobbyId}`);
    return true;
  }

  console.log(`[GameServerManager] Starting Godot server for lobby ${lobbyId}`);
  console.log(`[GameServerManager] Godot path: ${GODOT_PATH}`);
  console.log(`[GameServerManager] Project path: ${PROJECT_PATH}`);

  try {
    const proc = spawn({
      cmd: [
        GODOT_PATH,
        "--headless",
        "--path", PROJECT_PATH,
        "--scene", LEVEL_SCENE,
        "--", // Godot passes args after this to the game
        "--server",
        "--lobby", lobbyId,
      ],
      stdout: "pipe",
      stderr: "pipe",
      cwd: PROJECT_PATH,
    });

    // Log stdout
    (async () => {
      const reader = proc.stdout.getReader();
      const decoder = new TextDecoder();
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        const text = decoder.decode(value);
        console.log(`[Godot:${lobbyId}] ${text.trim()}`);
      }
    })();

    // Log stderr
    (async () => {
      const reader = proc.stderr.getReader();
      const decoder = new TextDecoder();
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        const text = decoder.decode(value);
        console.error(`[Godot:${lobbyId}:ERR] ${text.trim()}`);
      }
    })();

    gameServers.set(lobbyId, {
      process: proc,
      lobbyId,
      startTime: Date.now(),
    });

    // Monitor process exit
    proc.exited.then((exitCode) => {
      console.log(`[GameServerManager] Godot server for ${lobbyId} exited with code ${exitCode}`);
      gameServers.delete(lobbyId);
    });

    console.log(`[GameServerManager] Godot server started for lobby ${lobbyId} (PID: ${proc.pid})`);
    return true;
  } catch (error) {
    console.error(`[GameServerManager] Failed to start Godot server:`, error);
    return false;
  }
}

export function stopGameServer(lobbyId: string): boolean {
  const server = gameServers.get(lobbyId);
  if (!server) {
    console.log(`[GameServerManager] No server running for lobby ${lobbyId}`);
    return false;
  }

  console.log(`[GameServerManager] Stopping Godot server for lobby ${lobbyId}`);
  server.process.kill();
  gameServers.delete(lobbyId);
  return true;
}

export function isGameServerRunning(lobbyId: string): boolean {
  return gameServers.has(lobbyId);
}

export function getActiveServers(): string[] {
  return Array.from(gameServers.keys());
}

// Cleanup all servers on process exit
process.on("exit", () => {
  console.log("[GameServerManager] Cleaning up game servers...");
  for (const [lobbyId, server] of gameServers) {
    console.log(`[GameServerManager] Killing server for ${lobbyId}`);
    server.process.kill();
  }
});

process.on("SIGINT", () => {
  console.log("[GameServerManager] Received SIGINT, cleaning up...");
  for (const [lobbyId, server] of gameServers) {
    server.process.kill();
  }
  process.exit(0);
});

process.on("SIGTERM", () => {
  console.log("[GameServerManager] Received SIGTERM, cleaning up...");
  for (const [lobbyId, server] of gameServers) {
    server.process.kill();
  }
  process.exit(0);
});
