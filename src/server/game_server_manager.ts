import { spawn, type Subprocess } from "bun";
import { join, dirname } from "path";

const IS_PRODUCTION = process.platform === "linux";

// Path configuration - auto-detect based on environment
function getGodotPath(): string {
  if (process.env.GODOT_PATH) return process.env.GODOT_PATH;
  if (IS_PRODUCTION) return "/usr/local/bin/godot";
  // macOS app bundle location
  return "/Applications/Godot.app/Contents/MacOS/Godot";
}

function getProjectPath(): string {
  if (process.env.GODOT_PROJECT_PATH) return process.env.GODOT_PROJECT_PATH;
  if (IS_PRODUCTION) return "/app/godot";
  // Development: relative to this file (src/server -> ../../godot)
  return join(dirname(import.meta.path), "../../godot");
}

const GODOT_PATH = getGodotPath();
const PROJECT_PATH = getProjectPath();
const LEVEL_SCENE = "res://scenes/level_1.tscn";

// Store the subprocesses in a Map
// Note: Bun's spawn returns a 'Subprocess' object
const gameServers = new Map<string, Subprocess>();

/**
 * Reads a ReadableStream until it closes, logging each line of output.
 * Uses the standards-compliant `getReader()` method to satisfy TypeScript.
 */
async function logStream(stream: ReadableStream<Uint8Array>, prefix: string) {
  const reader = stream.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const text = Buffer.from(value).toString();
      text.trim().split('\n').forEach(line => {
        if (line) console.log(`${prefix}: ${line}`);
      });
    }
  } catch (err) {
    console.error(`Error while reading stream for ${prefix}:`, err);
  } finally {
    reader.releaseLock();
  }
}

export function startGameServer(lobbyId: string): boolean {
  if (gameServers.has(lobbyId)) {
    console.log(`[GameServerManager] Server already running for lobby ${lobbyId}`);
    return true;
  }

  console.log(`[GameServerManager] Starting Godot server for lobby ${lobbyId}`);
  
  try {    
    const proc = spawn({

      cmd: [
        GODOT_PATH,
        "--headless",
        "--path", PROJECT_PATH,
        "--scene", LEVEL_SCENE,
        "--",
        "--server",
        "--lobby", lobbyId,
      ],
      cwd: PROJECT_PATH,
      stdout: "pipe",
      stderr: "pipe",
    });

    console.log(`[GameServerManager] Godot process spawned (PID: ${proc.pid}) for lobby ${lobbyId}`);
    gameServers.set(lobbyId, proc);

    // Lifecycle and logging manager
    const manageProcess = async () => {
      const logStdout = logStream(proc.stdout, `[Godot STDOUT ${lobbyId}]`);
      const logStderr = logStream(proc.stderr, `[Godot STDERR ${lobbyId}]`);

      const exitCode = await proc.exited;
      console.log(`[GameServerManager] Godot server for lobby ${lobbyId} exited with code: ${exitCode}`);
      
      await Promise.all([logStdout, logStderr]);
      gameServers.delete(lobbyId);
    };

    manageProcess().catch(err => {
      console.error(`[GameServerManager] Error in process manager for ${lobbyId}:`, err);
    });

    return true;
  } catch (error) {
    console.error(`[GameServerManager] Failed to spawn Godot:`, error);
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
  // In Bun, you call .kill() directly on the subprocess object
  server.kill(); 
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
// We wrap the cleanup in a reusable function
const cleanupServers = () => {
  if (gameServers.size === 0) return;
  console.log(`[GameServerManager] Killing ${gameServers.size} active game servers...`);
  for (const [lobbyId, server] of gameServers) {
    console.log(`[GameServerManager] Killing server for ${lobbyId}`);
    server.kill();
  }
  gameServers.clear();
};

process.on("exit", cleanupServers);

process.on("SIGINT", () => {
  console.log("[GameServerManager] Received SIGINT, cleaning up...");
  cleanupServers();
  process.exit(0);
});

process.on("SIGTERM", () => {
  console.log("[GameServerManager] Received SIGTERM, cleaning up...");
  cleanupServers();
  process.exit(0);
});