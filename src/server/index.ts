import { serve } from "bun";
import type { ServerWebSocket } from "bun";
import { startGameServer, stopGameServer } from "./game_server_manager";

interface ClientData {
  lobbyId: string;
  playerId: string;
  playerName: string;
  isGameServer: boolean;  // true if this is the dedicated Godot server
}

interface Player {
  id: string;
  name: string;
  isHost: boolean;
  isReady: boolean;
}

interface Lobby {
  id: string;
  players: Map<string, { ws: ServerWebSocket<ClientData>; player: Player }>;
  hostId: string | null;
  gameStarted: boolean;
  gameServerWs: ServerWebSocket<ClientData> | null;  // Dedicated Godot server connection
}

const lobbies = new Map<string, Lobby>();

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders,
    },
  });
}

function generateLobbyCode(): string {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  let code = "";
  for (let i = 0; i < 4; i++) {
    code += chars[Math.floor(Math.random() * chars.length)];
  }
  return code;
}

function generatePlayerId(): string {
  return Math.random().toString(36).substring(2, 10);
}

function broadcast(lobby: Lobby, message: string, excludePlayerId?: string) {
  for (const [playerId, { ws }] of lobby.players) {
    if (playerId !== excludePlayerId) {
      ws.send(message);
    }
  }
}

function getPlayerList(lobby: Lobby): Player[] {
  return Array.from(lobby.players.values()).map(({ player }) => player);
}

const server = serve({
  websocket: {
    open(ws: ServerWebSocket<ClientData>) {
      const { lobbyId, playerId, playerName, isGameServer } = ws.data;
      console.log(`[WS] ${isGameServer ? "Game server" : `Player "${playerName}"`} (${playerId}) connected to lobby ${lobbyId}`);

      const lobby = lobbies.get(lobbyId);
      if (!lobby) return;

      // Handle dedicated game server connection
      if (isGameServer) {
        lobby.gameServerWs = ws;
        console.log(`[WS] Game server registered for lobby ${lobbyId}`);

        // Send welcome with current players so server can spawn balls
        ws.send(
          JSON.stringify({
            type: "welcome",
            playerId: "__GAME_SERVER__",
            lobbyId,
            isGameServer: true,
            players: getPlayerList(lobby),
            gameStarted: lobby.gameStarted,
          })
        );

        // If game already started, tell server to begin
        if (lobby.gameStarted) {
          ws.send(
            JSON.stringify({
              type: "server_start",
              players: getPlayerList(lobby),
            })
          );
        }
        return;
      }

      // First player becomes host (for UI/lobby purposes, not physics authority)
      const isHost = lobby.players.size === 0;
      const player: Player = {
        id: playerId,
        name: playerName,
        isHost,
        isReady: false,
      };

      if (isHost) {
        lobby.hostId = playerId;
      }

      lobby.players.set(playerId, { ws, player });

      // Broadcast player joined to all (including game server)
      const joinMessage = JSON.stringify({
        type: "player_joined",
        playerId,
        playerName,
        isHost,
        players: getPlayerList(lobby),
      });
      broadcast(lobby, joinMessage);
      if (lobby.gameServerWs) {
        lobby.gameServerWs.send(joinMessage);
      }

      // Send welcome message to the new player
      ws.send(
        JSON.stringify({
          type: "welcome",
          playerId,
          playerName,
          lobbyId,
          isHost,
          hostId: lobby.hostId,
          players: getPlayerList(lobby),
          gameStarted: lobby.gameStarted,
        })
      );
    },

    message(ws: ServerWebSocket<ClientData>, message: string | Buffer) {
      const { lobbyId, playerId } = ws.data;
      const messageStr = typeof message === "string" ? message : message.toString();

      try {
        const data = JSON.parse(messageStr);
        const lobby = lobbies.get(lobbyId);
        if (!lobby) return;

        // Game state broadcast from authoritative source
        // In dedicated server mode: only game server can send
        // In player-host mode (fallback): host player can send
        if (data.type === "game_state") {
          const isFromGameServer = ws.data.isGameServer;
          const isFromHost = playerId === lobby.hostId;

          // Accept from game server OR from host (if no game server)
          if (!isFromGameServer && !isFromHost) {
            console.log(`[WS] Rejected game_state from non-authority ${playerId}`);
            return;
          }

          // Broadcast to all players (not back to game server)
          broadcast(lobby, messageStr, isFromGameServer ? undefined : playerId);
        }

        // Ball shot message - player executed a shot
        // Contains: playerId, ballId, direction (x, y), power
        if (data.type === "ball_shot") {
          console.log(`[WS] Ball shot from ${playerId}`);
          const shotMessage = JSON.stringify({ ...data, playerId });

          // Forward to game server (it will apply physics and broadcast state)
          if (lobby.gameServerWs) {
            lobby.gameServerWs.send(shotMessage);
          }

          // Broadcast to all players for immediate visual feedback
          broadcast(lobby, shotMessage);
        }

        // Ball respawn message - player's ball respawned
        // Contains: playerId, spawnPosition {x, y}
        if (data.type === "ball_respawn") {
          console.log(`[WS] Ball respawn from ${playerId}`);
          const respawnMessage = JSON.stringify({ ...data, playerId });

          // Forward to game server
          if (lobby.gameServerWs) {
            lobby.gameServerWs.send(respawnMessage);
          }

          // Broadcast to all players
          broadcast(lobby, respawnMessage);
        }

        // Ball death message - player's ball died (before respawn delay)
        // Contains: playerId, ballId
        if (data.type === "ball_death") {
          console.log(`[WS] Ball death from ${playerId}`);
          const deathMessage = JSON.stringify({ ...data, playerId });

          // Forward to game server
          if (lobby.gameServerWs) {
            lobby.gameServerWs.send(deathMessage);
          }

          // Broadcast to all players
          broadcast(lobby, deathMessage);
        }

        // Start game message
        if (data.type === "start_game") {
          if (playerId !== lobby.hostId) {
            ws.send(JSON.stringify({ type: "error", message: "Only host can start game" }));
            return;
          }
          lobby.gameStarted = true;
          // Reset all players' ready state for next time
          for (const [, { player }] of lobby.players) {
            player.isReady = false;
          }

          // Spawn dedicated Godot server for this lobby
          const serverStarted = startGameServer(lobbyId);
          console.log(`[WS] Dedicated server spawn: ${serverStarted ? "success" : "failed"}`);

          // If game server already connected, tell it to start
          if (lobby.gameServerWs) {
            lobby.gameServerWs.send(
              JSON.stringify({
                type: "server_start",
                players: getPlayerList(lobby),
              })
            );
          }

          broadcast(lobby, JSON.stringify({ type: "game_started", hostId: lobby.hostId }));
          // Also send to host
          ws.send(JSON.stringify({ type: "game_started", hostId: lobby.hostId }));
        }

        // Return to lobby
        if (data.type === "return_to_lobby") {
          if (playerId !== lobby.hostId) {
            ws.send(JSON.stringify({ type: "error", message: "Only host can return to lobby" }));
            return;
          }
          lobby.gameStarted = false;

          // Stop the dedicated game server
          stopGameServer(lobbyId);

          // Reset all players' ready state
          for (const [, { player }] of lobby.players) {
            player.isReady = false;
          }
          broadcast(lobby, JSON.stringify({ type: "returned_to_lobby", players: getPlayerList(lobby) }));
        }

        // Player ready state toggle
        if (data.type === "player_ready") {
          const playerEntry = lobby.players.get(playerId);
          if (playerEntry) {
            playerEntry.player.isReady = data.isReady ?? !playerEntry.player.isReady;
            console.log(`[WS] Player ${playerId} ready: ${playerEntry.player.isReady}`);

            // Broadcast ready state change to all players
            broadcast(lobby, JSON.stringify({
              type: "player_ready_changed",
              playerId,
              isReady: playerEntry.player.isReady,
              players: getPlayerList(lobby),
            }));

            // Also send to the player who changed their state
            ws.send(JSON.stringify({
              type: "player_ready_changed",
              playerId,
              isReady: playerEntry.player.isReady,
              players: getPlayerList(lobby),
            }));
          }
        }

      } catch (e) {
        console.error(`[WS] Error parsing message: ${e}`);
      }
    },

    close(ws: ServerWebSocket<ClientData>) {
      const { lobbyId, playerId, playerName, isGameServer } = ws.data;
      console.log(`[WS] ${isGameServer ? "Game server" : `Player "${playerName}"`} (${playerId}) disconnected from lobby ${lobbyId}`);

      const lobby = lobbies.get(lobbyId);
      if (!lobby) return;

      // Handle game server disconnect
      if (isGameServer) {
        lobby.gameServerWs = null;
        console.log(`[WS] Game server disconnected from lobby ${lobbyId}`);
        return;
      }

      const wasHost = lobby.hostId === playerId;
      lobby.players.delete(playerId);

      // Notify game server of player leaving
      if (lobby.gameServerWs) {
        lobby.gameServerWs.send(
          JSON.stringify({
            type: "player_left",
            playerId,
            playerName,
          })
        );
      }

      // If host left, assign new host
      if (wasHost && lobby.players.size > 0) {
        const newHost = lobby.players.values().next().value;
        if (newHost) {
          lobby.hostId = newHost.player.id;
          newHost.player.isHost = true;
        }
      }

      broadcast(
        lobby,
        JSON.stringify({
          type: "player_left",
          playerId,
          playerName,
          players: getPlayerList(lobby),
          newHostId: lobby.hostId,
        })
      );

      // Delete empty lobby and stop game server
      if (lobby.players.size === 0) {
        stopGameServer(lobbyId);
        lobbies.delete(lobbyId);
        console.log(`[SERVER] Deleted empty lobby: ${lobbyId}`);
      }
    },
  },

  async fetch(req, server) {
    const url = new URL(req.url);

    // Handle CORS preflight
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    // Create lobby
    if (url.pathname === "/api/lobby/create" && req.method === "POST") {
      const lobbyId = generateLobbyCode();
      lobbies.set(lobbyId, {
        id: lobbyId,
        players: new Map(),
        hostId: null,
        gameStarted: false,
        gameServerWs: null,
      });
      console.log(`[SERVER] Created lobby: ${lobbyId}`);
      return jsonResponse({ lobbyId });
    }

    // Check if lobby exists
    if (url.pathname.startsWith("/api/lobby/") && req.method === "GET") {
      const lobbyId = url.pathname.split("/").pop()?.toUpperCase();
      if (lobbyId && lobbies.has(lobbyId)) {
        const lobby = lobbies.get(lobbyId)!;
        return jsonResponse({ exists: true, playerCount: lobby.players.size });
      }
      return jsonResponse({ exists: false }, 404);
    }

    // WebSocket upgrade
    if (url.pathname === "/ws") {
      const lobbyId = url.searchParams.get("lobby")?.toUpperCase();
      const playerName = url.searchParams.get("name") || "Anonymous";
      const isGameServer = url.searchParams.get("server") === "true";

      if (!lobbyId || !lobbies.has(lobbyId)) {
        console.log(`[WS] Rejected connection - invalid lobby: ${lobbyId}`);
        return new Response("Invalid lobby", { status: 400, headers: corsHeaders });
      }

      const playerId = isGameServer ? "__GAME_SERVER__" : generatePlayerId();
      const success = server.upgrade(req, {
        data: { lobbyId, playerId, playerName, isGameServer },
      });

      if (success) {
        console.log(`[WS] Upgraded connection for "${playerName}" (${playerId}) to lobby ${lobbyId}${isGameServer ? " [GAME SERVER]" : ""}`);
        return undefined;
      }

      return new Response("WebSocket upgrade failed", { status: 500, headers: corsHeaders });
    }

    // Serve static files from /build in dev mode
    if (process.env.NODE_ENV !== "production") {
      const filePath = url.pathname === "/" ? "/index.html" : url.pathname;
      const file = Bun.file(`${import.meta.dir}/../../build${filePath}`);
      if (await file.exists()) {
        return new Response(file, {
          headers: {
            "Cross-Origin-Opener-Policy": "same-origin",
            "Cross-Origin-Embedder-Policy": "require-corp",
          },
        });
      }
    }

    return new Response("Not found", { status: 404, headers: corsHeaders });
  },

  development: process.env.NODE_ENV !== "production" && {
    hmr: true,
    console: true,
  },
});

console.log(`Server running at ${server.url}`);
