import { spawn } from "bun";
import { join } from "path";

// Assuming gameServers is defined elsewhere, e.g.:
const gameServers = new Map<string, ReturnType<typeof spawn>>();

// Path to Godot executable (configurable via env)
const GODOT_PATH = "/usr/local/bin/godot";
const PROJECT_PATH = join(import.meta.dir, "../../godot");

// Level scene to load (can be made dynamic later)
const LEVEL_SCENE = "res://scenes/level_1.tscn";

/**
 * Reads a ReadableStream until it closes, logging each line of output.
 * This uses the standards-compliant `getReader()` method which is correctly
 * typed in Bun's environment.
 */
async function logStream(stream: ReadableStream<Uint8Array>, prefix: string) {
  const reader = stream.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        // The stream has finished
        break;
      }
      const text = Buffer.from(value).toString();
      text.trim().split('\n').forEach(line => console.log(`${prefix}: ${line}`));
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
  console.log(`[GameServerManager] Godot path: ${GODOT_PATH}`);
  console.log(`[GameServerManager] Project path: ${PROJECT_PATH}`);

  try {
    const command = `${GODOT_PATH} --headless --path ${PROJECT_PATH} --scene ${LEVEL_SCENE} -- --server --lobby ${lobbyId}`;
    console.log(`[GameServerManager] Executing via shell: /bin/sh -c "${command}"`);

    const proc = spawn({
      cmd: ["/bin/sh", "-c", command],
      cwd: PROJECT_PATH,
      stdout: "pipe",
      stderr: "pipe",
    });

    console.log(`[GameServerManager] Godot server process spawned with PID: ${proc.pid}`);
    gameServers.set(lobbyId, proc);

    const manageProcess = async () => {
      // Start logging stdout and stderr concurrently
      const logStdout = logStream(proc.stdout, `[Godot STDOUT ${lobbyId}]`);
      const logStderr = logStream(proc.stderr, `[Godot STDERR ${lobbyId}]`);

      const exitCode = await proc.exited;
      console.log(`[GameServerManager] Godot server for lobby ${lobbyId} exited with code: ${exitCode}`);
      
      await Promise.all([logStdout, logStderr]); // Wait for logs to flush
      gameServers.delete(lobbyId);
    };

    manageProcess().catch(err => {
      console.error(`[GameServerManager] CRITICAL ERROR in process manager for lobby ${lobbyId}:`, err);
    });

    return true;

  } catch (error) {
    console.error(`[GameServerManager] The 'spawn' call itself threw a critical error:`, error);
    if (error instanceof Error) {
        console.error(`[GameServerManager] Error Details: code=${(error as any).code}, errno=${(error as any).errno}`);
    }
    return false;
  }
}