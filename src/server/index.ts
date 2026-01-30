import { serve } from "bun";
import type { ServerWebSocket } from "bun";
import index from "../client/index.html";

interface ClientData {
  lobbyId: string;
  playerId: string;
  playerName: string;
}

interface Player {
  id: string;
  name: string;
  connected: boolean;
}

interface Lobby {
  id: string;
  players: Map<string, { ws: ServerWebSocket<ClientData>; player: Player }>;
  createdAt: number;
  gameStarted: boolean;
}

const lobbies = new Map<string, Lobby>();

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

function broadcast(lobby: Lobby, message: string) {
  for (const { ws } of lobby.players.values()) {
    ws.send(message);
  }
}

function getPlayerList(lobby: Lobby): Player[] {
  return Array.from(lobby.players.values()).map(({ player }) => player);
}

const server = serve({
  routes: {
    "/*": index,

    "/api/lobby/create": {
      POST() {
        const lobbyId = generateLobbyCode();
        lobbies.set(lobbyId, {
          id: lobbyId,
          players: new Map(),
          createdAt: Date.now(),
          gameStarted: false,
        });
        console.log(`[SERVER] Created lobby: ${lobbyId}`);
        return Response.json({ lobbyId });
      },
    },

    "/api/lobby/:id": {
      GET(req) {
        const lobbyId = req.params.id.toUpperCase();
        const lobby = lobbies.get(lobbyId);
        if (lobby) {
          console.log(`[SERVER] Lobby ${lobbyId} found, ${lobby.players.size} players`);
          return Response.json({ exists: true, playerCount: lobby.players.size });
        }
        console.log(`[SERVER] Lobby ${lobbyId} not found`);
        return Response.json({ exists: false }, { status: 404 });
      },
    },
  },

  websocket: {
    open(ws: ServerWebSocket<ClientData>) {
      const { lobbyId, playerId, playerName } = ws.data;
      console.log(`[WS] Player "${playerName}" (${playerId}) connected to lobby ${lobbyId}`);

      const lobby = lobbies.get(lobbyId);
      if (!lobby) return;

      const player: Player = { id: playerId, name: playerName, connected: true };
      lobby.players.set(playerId, { ws, player });

      // Broadcast player joined to all
      broadcast(lobby, JSON.stringify({
        type: "player_joined",
        playerId,
        playerName,
        players: getPlayerList(lobby),
      }));

      // Send welcome message to the new player
      ws.send(JSON.stringify({
        type: "welcome",
        playerId,
        playerName,
        lobbyId,
        players: getPlayerList(lobby),
        gameStarted: lobby.gameStarted,
      }));
    },

    message(ws: ServerWebSocket<ClientData>, message: string | Buffer) {
      const { lobbyId, playerId, playerName } = ws.data;
      const messageStr = typeof message === "string" ? message : message.toString();
      console.log(`[WS] Message from "${playerName}" in ${lobbyId}: ${messageStr}`);

      try {
        const data = JSON.parse(messageStr);

        const lobby = lobbies.get(lobbyId);
        if (!lobby) return;

        if (data.type === "chat") {
          broadcast(lobby, JSON.stringify({
            type: "chat",
            playerId,
            playerName,
            message: data.message,
            timestamp: Date.now(),
          }));
          console.log(`[WS] Broadcasted chat to ${lobby.players.size} players`);
        }

        if (data.type === "start_game") {
          if (!lobby.gameStarted) {
            lobby.gameStarted = true;
            console.log(`[SERVER] Game started in lobby ${lobbyId}`);
            broadcast(lobby, JSON.stringify({
              type: "game_started",
              timestamp: Date.now(),
            }));
          }
        }
      } catch (e) {
        console.error(`[WS] Error parsing message: ${e}`);
      }
    },

    close(ws: ServerWebSocket<ClientData>) {
      const { lobbyId, playerId, playerName } = ws.data;
      console.log(`[WS] Player "${playerName}" (${playerId}) disconnected from lobby ${lobbyId}`);

      const lobby = lobbies.get(lobbyId);
      if (!lobby) return;

      lobby.players.delete(playerId);

      broadcast(lobby, JSON.stringify({
        type: "player_left",
        playerId,
        playerName,
        players: getPlayerList(lobby),
      }));

      if (lobby.players.size === 0) {
        lobbies.delete(lobbyId);
        console.log(`[SERVER] Deleted empty lobby: ${lobbyId}`);
      }
    },
  },

  fetch(req, server) {
    const url = new URL(req.url);

    if (url.pathname === "/ws") {
      const lobbyId = url.searchParams.get("lobby")?.toUpperCase();
      const playerName = url.searchParams.get("name") || "Anonymous";

      if (!lobbyId || !lobbies.has(lobbyId)) {
        console.log(`[WS] Rejected connection - invalid lobby: ${lobbyId}`);
        return new Response("Invalid lobby", { status: 400 });
      }

      const playerId = generatePlayerId();
      const success = server.upgrade(req, {
        data: { lobbyId, playerId, playerName },
      });

      if (success) {
        console.log(`[WS] Upgraded connection for "${playerName}" (${playerId}) to lobby ${lobbyId}`);
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

console.log(`Server running at ${server.url}`);
