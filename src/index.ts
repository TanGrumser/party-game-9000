import { serve } from "bun";
import type { ServerWebSocket } from "bun";
import index from "./index.html";

// Types
interface ClientData {
  lobbyId: string;
  playerId: string;
}

interface Lobby {
  id: string;
  players: Map<string, ServerWebSocket<ClientData>>;
  createdAt: number;
}

// Store active lobbies
const lobbies = new Map<string, Lobby>();

// Generate a random lobby code
function generateLobbyCode(): string {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  let code = "";
  for (let i = 0; i < 4; i++) {
    code += chars[Math.floor(Math.random() * chars.length)];
  }
  return code;
}

// Generate a random player ID
function generatePlayerId(): string {
  return Math.random().toString(36).substring(2, 10);
}

const server = serve({
  routes: {
    // Serve index.html for all unmatched routes
    "/*": index,

    // Create a new lobby
    "/api/lobby/create": {
      async POST(req) {
        const lobbyId = generateLobbyCode();
        const lobby: Lobby = {
          id: lobbyId,
          players: new Map(),
          createdAt: Date.now(),
        };
        lobbies.set(lobbyId, lobby);
        console.log(`[SERVER] Created lobby: ${lobbyId}`);
        return Response.json({ lobbyId });
      },
    },

    // Check if a lobby exists
    "/api/lobby/:id": {
      async GET(req) {
        const lobbyId = req.params.id.toUpperCase();
        const lobby = lobbies.get(lobbyId);
        if (lobby) {
          console.log(`[SERVER] Lobby ${lobbyId} found, ${lobby.players.size} players`);
          return Response.json({
            exists: true,
            playerCount: lobby.players.size,
          });
        }
        console.log(`[SERVER] Lobby ${lobbyId} not found`);
        return Response.json({ exists: false }, { status: 404 });
      },
    },
  },

  websocket: {
    open(ws: ServerWebSocket<ClientData>) {
      const { lobbyId, playerId } = ws.data;
      console.log(`[WS] Player ${playerId} connected to lobby ${lobbyId}`);

      const lobby = lobbies.get(lobbyId);
      if (lobby) {
        lobby.players.set(playerId, ws);

        // Notify all players in the lobby
        const joinMessage = JSON.stringify({
          type: "player_joined",
          playerId,
          playerCount: lobby.players.size,
        });

        for (const [id, client] of lobby.players) {
          client.send(joinMessage);
        }

        // Send welcome message to the new player
        ws.send(
          JSON.stringify({
            type: "welcome",
            playerId,
            lobbyId,
            playerCount: lobby.players.size,
          })
        );
      }
    },

    message(ws: ServerWebSocket<ClientData>, message: string | Buffer) {
      const { lobbyId, playerId } = ws.data;
      const messageStr = typeof message === "string" ? message : message.toString();

      console.log(`[WS] Message from ${playerId} in ${lobbyId}: ${messageStr}`);

      try {
        const data = JSON.parse(messageStr);

        // Handle chat messages
        if (data.type === "chat") {
          const lobby = lobbies.get(lobbyId);
          if (lobby) {
            const broadcastMessage = JSON.stringify({
              type: "chat",
              playerId,
              message: data.message,
              timestamp: Date.now(),
            });

            // Broadcast to all players in the lobby
            for (const [id, client] of lobby.players) {
              client.send(broadcastMessage);
            }
            console.log(`[WS] Broadcasted chat to ${lobby.players.size} players`);
          }
        }
      } catch (e) {
        console.error(`[WS] Error parsing message: ${e}`);
      }
    },

    close(ws: ServerWebSocket<ClientData>) {
      const { lobbyId, playerId } = ws.data;
      console.log(`[WS] Player ${playerId} disconnected from lobby ${lobbyId}`);

      const lobby = lobbies.get(lobbyId);
      if (lobby) {
        lobby.players.delete(playerId);

        // Notify remaining players
        const leaveMessage = JSON.stringify({
          type: "player_left",
          playerId,
          playerCount: lobby.players.size,
        });

        for (const [id, client] of lobby.players) {
          client.send(leaveMessage);
        }

        // Clean up empty lobbies
        if (lobby.players.size === 0) {
          lobbies.delete(lobbyId);
          console.log(`[SERVER] Deleted empty lobby: ${lobbyId}`);
        }
      }
    },
  },

  fetch(req, server) {
    const url = new URL(req.url);

    // Handle WebSocket upgrade
    if (url.pathname === "/ws") {
      const lobbyId = url.searchParams.get("lobby")?.toUpperCase();

      if (!lobbyId || !lobbies.has(lobbyId)) {
        console.log(`[WS] Rejected connection - invalid lobby: ${lobbyId}`);
        return new Response("Invalid lobby", { status: 400 });
      }

      const playerId = generatePlayerId();
      const success = server.upgrade(req, {
        data: { lobbyId, playerId },
      });

      if (success) {
        console.log(`[WS] Upgraded connection for player ${playerId} to lobby ${lobbyId}`);
        return undefined;
      }

      return new Response("WebSocket upgrade failed", { status: 500 });
    }

    return undefined;
  },

  development: process.env.NODE_ENV !== "production" && {
    hmr: true,
    console: true,
  },
});

console.log(`🚀 Server running at ${server.url}`);
