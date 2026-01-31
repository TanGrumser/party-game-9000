import { serve } from "bun";
import type { ServerWebSocket } from "bun";
import index from "../client/index.html";

const PLAYER_COLORS = ["#ff6b6b", "#4ecdc4", "#ffe66d", "#95e1d3", "#f38181", "#aa96da"];

interface ClientData {
  lobbyId: string;
  playerId: string;
  playerName: string;
}

interface Player {
  id: string;
  name: string;
  connected: boolean;
  color: string;
  colorIndex: number;
}

interface Ball {
  id: string;
  targetPlayerId: string; // The player this ball should go to (by color match)
  targetColor: string;
  holderId: string | null; // Who currently has the ball
  x: number;
  y: number;
  status: "held" | "incoming" | "collected";
  sentFromId?: string; // Who sent this ball (for returning on timeout)
  incomingTimestamp?: number; // When the ball arrived (for timeout)
}

interface InputField {
  id: string;
  emoji: string;
  code: string;
  codeExpiresAt: number;
  timerDuration: number;
  timerEndsAt: number;
}

interface PlayerGameState {
  playerId: string;
  playerName: string;
  inputs: InputField[];
}

interface GameState {
  lobbyId: string;
  startedAt: number;
  gameOver: boolean;
  lives: number;
  playerStates: Map<string, PlayerGameState>;
  // Maps playerId -> Set of inputIds they can see (codes distributed among players)
  codeAssignments: Map<string, Set<string>>;
  tickInterval: Timer | null;
}

interface Lobby {
  id: string;
  players: Map<string, { ws: ServerWebSocket<ClientData>; player: Player }>;
  createdAt: number;
  gameState: GameState | null;
  gameStarted: boolean;
  stage: number; // 1 = code game only, 2 = ball game
  balls: Ball[];
  collectedBalls: Map<string, number>; // playerId -> count of collected balls
}

// ============ CONSTANTS ============

const EMOJIS = [
  // Food
  "🍎", "🍕", "🍦", "🍩", "🍔", "🌮", "🍣", "🧁", "🍪", "🥨",
  // Animals
  "🦊", "🦋", "🐙", "🦄", "🐸", "🦁", "🐧", "🦀", "🐝", "🦉",
  // Nature
  "🌙", "🌈", "🌺", "🌴", "🌵", "🍀", "🌸", "⭐", "🌊", "❄️",
  // Objects
  "🚀", "🎸", "🔥", "🎯", "🎲", "🎪", "🎭", "🎵", "🎨", "💎",
  "⚡", "🔔", "🎈", "🎁", "🏆", "👑", "💡", "🔮", "🎀", "🧲",
  // Symbols
  "❤️", "💜", "💚", "🧡", "💙", "☀️", "🌟", "✨", "💫", "🎉",
];
const TIMER_DURATIONS = [48000, 64000, 80000]; // 48-80 seconds
const CODE_REFRESH_MIN = 15000; // 15 seconds
const CODE_REFRESH_MAX = 20000; // 20 seconds
const DIFFICULTY_TICK = 60000; // 30 seconds
const DIFFICULTY_INCREASE = 0.1; // 10% faster each tick
const TICK_INTERVAL = 500; // 500ms
const MIN_PLAYERS = 2;
const STARTING_LIVES = 5;

// ============ STATE ============

const lobbies = new Map<string, Lobby>();
const INCOMING_TIMEOUT = 5000; // 5 seconds to accept a ball

// ============ HELPER FUNCTIONS ============

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

function generateCode(): string {
  let code = "";
  for (let i = 0; i < 4; i++) {
    code += Math.floor(Math.random() * 10).toString();
  }
  return code;
}

function generateCodeExpiry(): number {
  return Date.now() + CODE_REFRESH_MIN + Math.random() * (CODE_REFRESH_MAX - CODE_REFRESH_MIN);
}

function shuffleArray<T>(array: T[]): T[] {
  const result = [...array];
  for (let i = result.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [result[i], result[j]] = [result[j]!, result[i]!];
  }
  return result;
}

function generateBallId(): string {
  return "ball-" + Math.random().toString(36).substring(2, 8);
}

function broadcast(lobby: Lobby, message: string) {
  for (const { ws } of lobby.players.values()) {
    ws.send(message);
  }
}

function sendToPlayer(lobby: Lobby, playerId: string, message: string) {
  const playerData = lobby.players.get(playerId);
  if (playerData) {
    playerData.ws.send(message);
  }
}

function getPlayerList(lobby: Lobby): Player[] {
  return Array.from(lobby.players.values()).map(({ player }) => player);
}

function getDifficultyMultiplier(gameState: GameState): number {
  const elapsed = Date.now() - gameState.startedAt;
  const ticks = Math.floor(elapsed / DIFFICULTY_TICK);
  return 1 + ticks * DIFFICULTY_INCREASE;
}

function getTimeRemaining(input: InputField): number {
  return Math.max(0, input.timerEndsAt - Date.now());
}

// ============ GAME LOGIC ============

function initializeGameState(lobby: Lobby): GameState {
  const playerIds = Array.from(lobby.players.keys());
  const playerStates = new Map<string, PlayerGameState>();

  // Get shuffled emojis for all players
  const allEmojis = shuffleArray(EMOJIS);
  let emojiIndex = 0;

  // First, create all player inputs
  for (const [playerId, { player }] of lobby.players) {
    const inputs: InputField[] = [];
    const shuffledDurations = shuffleArray(TIMER_DURATIONS);

    for (let i = 0; i < 3; i++) {
      inputs.push({
        id: `${playerId}-${i}`,
        emoji: allEmojis[emojiIndex++ % allEmojis.length]!,
        code: generateCode(),
        codeExpiresAt: generateCodeExpiry(),
        timerDuration: shuffledDurations[i]!,
        timerEndsAt: Date.now() + shuffledDurations[i]!,
      });
    }

    playerStates.set(playerId, {
      playerId,
      playerName: player.name,
      inputs,
    });
  }

  // Now distribute codes: each player sees codes for OTHER players' inputs
  // Each player should see the same number of codes as they have inputs (3)
  // Codes are distributed so no one player sees all codes for another player
  const codeAssignments = new Map<string, Set<string>>();

  // Initialize empty sets for each player
  for (const playerId of playerIds) {
    codeAssignments.set(playerId, new Set());
  }

  // Collect all inputs with their owner info
  const allInputs: Array<{ inputId: string; ownerId: string }> = [];
  for (const [ownerId, playerState] of playerStates) {
    for (const input of playerState.inputs) {
      allInputs.push({ inputId: input.id, ownerId });
    }
  }

  // Shuffle inputs for random distribution
  const shuffledInputs = shuffleArray(allInputs);

  // Distribute each input to a player who is NOT the owner
  // Use round-robin among eligible players, prioritizing those with fewer codes
  for (const { inputId, ownerId } of shuffledInputs) {
    // Find eligible players (not the owner) sorted by how many codes they have
    const eligiblePlayers = playerIds
      .filter(pid => pid !== ownerId)
      .sort((a, b) => {
        const aCount = codeAssignments.get(a)?.size ?? 0;
        const bCount = codeAssignments.get(b)?.size ?? 0;
        return aCount - bCount;
      });

    if (eligiblePlayers.length > 0) {
      // Assign to the player with the fewest codes
      codeAssignments.get(eligiblePlayers[0]!)!.add(inputId);
    }
  }

  return {
    lobbyId: lobby.id,
    startedAt: Date.now(),
    gameOver: false,
    lives: STARTING_LIVES,
    playerStates,
    codeAssignments,
    tickInterval: null,
  };
}

function getVisibleCodesForPlayer(gameState: GameState, playerId: string) {
  const visibleCodes: Array<{
    inputId: string;
    emoji: string;
    code: string;
    codeExpiresIn: number;
  }> = [];

  const now = Date.now();
  const assignedInputIds = gameState.codeAssignments.get(playerId);
  if (!assignedInputIds) return visibleCodes;

  // Only show codes that are assigned to this player (no player names - anonymous codes)
  for (const [otherPlayerId, playerState] of gameState.playerStates) {
    if (otherPlayerId === playerId) continue; // Don't show own codes

    for (const input of playerState.inputs) {
      // Only include if this input is assigned to this player
      if (assignedInputIds.has(input.id)) {
        visibleCodes.push({
          inputId: input.id,
          emoji: input.emoji,
          code: input.code,
          codeExpiresIn: Math.max(0, input.codeExpiresAt - now),
        });
      }
    }
  }
  return visibleCodes;
}

function createGameBalls(lobby: Lobby): Ball[] {
  const players = Array.from(lobby.players.values()).map(p => p.player);
  const balls: Ball[] = [];

  // Each player gets balls of OTHER players' colors
  for (const holder of players) {
    for (const target of players) {
      if (holder.id !== target.id) {
        balls.push({
          id: generateBallId(),
          targetPlayerId: target.id,
          targetColor: target.color,
          holderId: holder.id,
          x: 0.2 + Math.random() * 0.6, // Random x position
          y: 0.3 + Math.random() * 0.4, // Random y position
          status: "held",
        });
      }
    }
  }
  return balls;
}



// Reassign a code to a different player after successful submission
function reassignCode(gameState: GameState, inputId: string, ownerId: string, currentHolderId: string): void {
  const playerIds = Array.from(gameState.playerStates.keys());

  // Find eligible players: not the owner, and preferably not the current holder
  const eligiblePlayers = playerIds.filter(pid => pid !== ownerId);

  if (eligiblePlayers.length === 0) return;

  // Remove from current holder
  gameState.codeAssignments.get(currentHolderId)?.delete(inputId);

  // If more than one eligible player, prefer someone other than current holder
  let newHolder: string;
  if (eligiblePlayers.length === 1) {
    // Only one other player (2 player game) - must be them
    newHolder = eligiblePlayers[0]!;
  } else {
    // Multiple eligible players - pick someone other than current holder
    const preferredPlayers = eligiblePlayers.filter(pid => pid !== currentHolderId);
    // Pick randomly from preferred players
    newHolder = preferredPlayers[Math.floor(Math.random() * preferredPlayers.length)]!;
  }

  // Assign to new holder
  gameState.codeAssignments.get(newHolder)?.add(inputId);

  console.log(`[GAME] Reassigned code for ${inputId} from ${currentHolderId} to ${newHolder}`);
}

function getPlayerInputsState(gameState: GameState, playerId: string) {
  const playerState = gameState.playerStates.get(playerId);
  if (!playerState) return [];

  return playerState.inputs.map((input) => ({
    id: input.id,
    emoji: input.emoji,
    timerDuration: input.timerDuration,
    timeRemaining: getTimeRemaining(input),
  }));
}

function refreshExpiredCodes(gameState: GameState): void {
  const now = Date.now();

  for (const playerState of gameState.playerStates.values()) {
    for (const input of playerState.inputs) {
      if (now >= input.codeExpiresAt) {
        input.code = generateCode();
        input.codeExpiresAt = generateCodeExpiry();
      }
    }
  }
}
        

function checkIncomingTimeouts(lobby: Lobby) {
  const now = Date.now();
  let changed = false;

  for (const ball of lobby.balls) {
    if (ball.status === "incoming" && ball.incomingTimestamp && ball.sentFromId) {
      if (now - ball.incomingTimestamp > INCOMING_TIMEOUT) {
        // Return ball to sender
        ball.status = "held";
        ball.holderId = ball.sentFromId;
        ball.x = 0.5;
        ball.y = 0.5;
        ball.sentFromId = undefined;
        ball.incomingTimestamp = undefined;
        changed = true;
        console.log(`[SERVER] Ball ${ball.id} timed out, returning to sender`);
      }
    }
  }
  if (changed) {
    broadcast(lobby, JSON.stringify({
      type: "balls_update",
      balls: lobby.balls,
    }));
  }
}

function checkForExplosions(gameState: GameState): Array<{ playerName: string; playerId: string; emoji: string; inputId: string }> {
  const explosions: Array<{ playerName: string; playerId: string; emoji: string; inputId: string }> = [];

  for (const playerState of gameState.playerStates.values()) {
    for (const input of playerState.inputs) {
      const timeRemaining = getTimeRemaining(input);
      if (timeRemaining <= 0) {
        explosions.push({
          playerName: playerState.playerName,
          playerId: playerState.playerId,
          emoji: input.emoji,
          inputId: input.id,
        });
      }
    }
  }

  return explosions;
}

function handleExplosion(gameState: GameState, explosion: { playerId: string; inputId: string }): void {
  // Reset the timer for the exploded input
  const playerState = gameState.playerStates.get(explosion.playerId);
  if (!playerState) return;

  const input = playerState.inputs.find(i => i.id === explosion.inputId);
  if (!input) return;

  // Reset timer with current difficulty multiplier
  const multiplier = getDifficultyMultiplier(gameState);
  input.timerEndsAt = Date.now() + (input.timerDuration / multiplier);

  // Generate new code
  input.code = generateCode();
  input.codeExpiresAt = generateCodeExpiry();
}

function handleCodeSubmission(
  lobby: Lobby,
  playerId: string,
  inputId: string,
  submittedCode: string
): { success: boolean; message: string } {
  const gameState = lobby.gameState;
  if (!gameState || gameState.gameOver) {
    return { success: false, message: "Game not active" };
  }

  const playerState = gameState.playerStates.get(playerId);
  if (!playerState) {
    return { success: false, message: "Player not found" };
  }

  const input = playerState.inputs.find((i) => i.id === inputId);
  if (!input) {
    return { success: false, message: "Input not found" };
  }

  // Check if code matches (case-insensitive)
  if (input.code.toUpperCase() === submittedCode.toUpperCase()) {
    // Find who currently has this code assigned
    let currentHolder: string | null = null;
    for (const [holderId, inputIds] of gameState.codeAssignments) {
      if (inputIds.has(inputId)) {
        currentHolder = holderId;
        break;
      }
    }

    // Reset timer - apply current difficulty multiplier to new timer
    const multiplier = getDifficultyMultiplier(gameState);
    input.timerEndsAt = Date.now() + (input.timerDuration / multiplier);
    // Generate new code
    input.code = generateCode();
    input.codeExpiresAt = generateCodeExpiry();

    // Reassign the code to a different player
    if (currentHolder) {
      reassignCode(gameState, inputId, playerId, currentHolder);
    }

    console.log(`[GAME] Player ${playerState.playerName} entered correct code for ${input.emoji}`);
    return { success: true, message: "Correct!" };
  } else {
    console.log(`[GAME] Player ${playerState.playerName} entered wrong code for ${input.emoji}: ${submittedCode} (expected ${input.code})`);
    return { success: false, message: "Wrong code!" };
  }
}

function startGameTick(lobby: Lobby) {
  const gameState = lobby.gameState;
  if (!gameState) return;

  gameState.tickInterval = setInterval(() => {
    if (gameState.gameOver) {
      if (gameState.tickInterval) {
        clearInterval(gameState.tickInterval);
      }
      return;
    }

    // Check for explosions
    const explosions = checkForExplosions(gameState);
    for (const explosion of explosions) {
      // Decrement lives
      gameState.lives--;

      console.log(`[GAME] ${explosion.playerName}'s ${explosion.emoji} exploded! Lives remaining: ${gameState.lives}`);

      // Handle the explosion (reset timer)
      handleExplosion(gameState, explosion);

      const survivedTime = Math.floor((Date.now() - gameState.startedAt) / 1000);

      if (gameState.lives <= 0) {
        // Game over!
        gameState.gameOver = true;

        broadcast(
          lobby,
          JSON.stringify({
            type: "game_over",
            winner: false,
            explodedPlayerName: explosion.playerName,
            explodedEmoji: explosion.emoji,
            survivedTime,
          })
        );

        console.log(`[GAME] Game over in ${lobby.id}! No lives remaining after ${survivedTime}s`);

        if (gameState.tickInterval) {
          clearInterval(gameState.tickInterval);
        }
        return;
      } else {
        // Send bomb_exploded message to all players
        broadcast(
          lobby,
          JSON.stringify({
            type: "bomb_exploded",
            explodedPlayerName: explosion.playerName,
            explodedEmoji: explosion.emoji,
            livesRemaining: gameState.lives,
          })
        );
      }
    }

    // Refresh expired codes
    refreshExpiredCodes(gameState);

    // Send tick update to each player
    const multiplier = getDifficultyMultiplier(gameState);
    const serverTime = Date.now();

    for (const [playerId] of lobby.players) {
      const playerState = gameState.playerStates.get(playerId);
      if (!playerState) continue;

      const inputs = playerState.inputs.map((input) => ({
        id: input.id,
        timeRemaining: getTimeRemaining(input),
      }));

      const tickMessage = {
        type: "game_tick",
        serverTime,
        difficultyMultiplier: multiplier,
        survivedTime: Math.floor((serverTime - gameState.startedAt) / 1000),
        lives: gameState.lives,
        inputs,
        visibleCodes: getVisibleCodesForPlayer(gameState, playerId),
      };

      sendToPlayer(lobby, playerId, JSON.stringify(tickMessage));
    }
  }, TICK_INTERVAL);
}

function startGame(lobby: Lobby): boolean {
  if (lobby.players.size < MIN_PLAYERS) {
    console.log(`[GAME] Cannot start game - need at least ${MIN_PLAYERS} players`);
    return false;
  }

  if (lobby.gameState) {
    console.log(`[GAME] Game already started in ${lobby.id}`);
    return false;
  }

  // Initialize game state
  lobby.gameState = initializeGameState(lobby);

  console.log(`[GAME] Starting game in ${lobby.id} with ${lobby.players.size} players`);

  // Send game_start to each player with their specific view
  for (const [playerId] of lobby.players) {
    const inputs = getPlayerInputsState(lobby.gameState, playerId);
    const visibleCodes = getVisibleCodesForPlayer(lobby.gameState, playerId);

    sendToPlayer(
      lobby,
      playerId,
      JSON.stringify({
        type: "game_start",
        inputs,
        visibleCodes,
        lives: lobby.gameState.lives,
      })
    );
  }

  // Start the game tick loop
  startGameTick(lobby);

  return true;
}

// ============ SERVER ============

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
          gameState: null,
          gameStarted: false,
          stage: 1, // Start with level 1 (code game only)
          balls: [],
          collectedBalls: new Map(),
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

      // Assign color based on join order
      const colorIndex = lobby.players.size % PLAYER_COLORS.length;
      const player: Player = {
        id: playerId,
        name: playerName,
        connected: true,
        color: PLAYER_COLORS[colorIndex] ?? "#646cff",
        colorIndex,
      };
      lobby.players.set(playerId, { ws, player });

      // Broadcast player joined to all
      broadcast(
        lobby,
        JSON.stringify({
          type: "player_joined",
          playerId,
          playerName,
          players: getPlayerList(lobby),
        })
      );

      // Send welcome message to the new player
      ws.send(
        JSON.stringify({
          type: "welcome",
          playerId,
          playerName,
          lobbyId,
          players: getPlayerList(lobby),
          gameStarted: lobby.gameState !== null,
        })
      );

      ws.send(JSON.stringify({
        type: "welcome",
        playerId,
        playerName,
        lobbyId,
        players: getPlayerList(lobby),
        gameStarted: lobby.gameStarted,
        stage: lobby.stage,
        // Ball game data only sent for stage 2
        ...(lobby.stage >= 2 ? {
          balls: lobby.balls,
          collectedBalls: Object.fromEntries(lobby.collectedBalls),
        } : {}),
      }));
    },

    message(ws: ServerWebSocket<ClientData>, message: string | Buffer) {
      const { lobbyId, playerId, playerName } = ws.data;
      const messageStr = typeof message === "string" ? message : message.toString();

      try {
        const data = JSON.parse(messageStr);
        const lobby = lobbies.get(lobbyId);
        if (!lobby) return;

        if (data.type === "chat") {
          broadcast(
            lobby,
            JSON.stringify({
              type: "chat",
              playerId,
              playerName,
              message: data.message,
              timestamp: Date.now(),
            })
          );
          console.log(`[WS] Broadcasted chat to ${lobby.players.size} players`);
        }

        if (data.type === "start_game") {
          const success = startGame(lobby);
          if (!success && lobby.players.size < MIN_PLAYERS) {
            sendToPlayer(
              lobby,
              playerId,
              JSON.stringify({
                type: "error",
                message: `Need at least ${MIN_PLAYERS} players to start`,
              })
            );
          }
        }

        if (data.type === "submit_code") {
          const result = handleCodeSubmission(lobby, playerId, data.inputId, data.code);
          sendToPlayer(
            lobby,
            playerId,
            JSON.stringify({
              type: "code_result",
              inputId: data.inputId,
              success: result.success,
              message: result.message,
            })
          );
        }


        // Ball game logic - only for stage 2
        if (data.type === "start_game" && lobby.stage >= 2) {
          if (!lobby.gameStarted && lobby.players.size >= 2) {
            lobby.gameStarted = true;
            lobby.balls = createGameBalls(lobby);
            lobby.collectedBalls = new Map();

            // Initialize collected balls count for each player
            for (const pid of lobby.players.keys()) {
              lobby.collectedBalls.set(pid, 0);
            }

            console.log(`[SERVER] Game started in lobby ${lobbyId} with ${lobby.balls.length} balls`);
            broadcast(lobby, JSON.stringify({
              type: "game_started",
              balls: lobby.balls,
              collectedBalls: Object.fromEntries(lobby.collectedBalls),
              timestamp: Date.now(),
            }));

            // Start timeout checker
            const intervalId = setInterval(() => {
              const l = lobbies.get(lobbyId);
              if (!l || !l.gameStarted) {
                clearInterval(intervalId);
                return;
              }
              checkIncomingTimeouts(l);
            }, 1000);
          }
        }

        // ============ BALL GAME HANDLERS (Stage 2 only) ============
        if (lobby.stage >= 2) {
          // Ball position update from holder
          if (data.type === "ball_update") {
            const ball = lobby.balls.find(b => b.id === data.ballId);
            if (ball && ball.holderId === playerId && ball.status === "held") {
              ball.x = data.x;
              ball.y = data.y;

              // When ball is near the top edge, show preview to target player
              if (data.y < 0.2) {
                // Send preview to the target player - ball appears at their top
                const targetPlayer = lobby.players.get(ball.targetPlayerId);
                if (targetPlayer) {
                  // Mirror the y position: as ball goes from 0.2 to -0.1 on sender,
                  // it appears from -0.1 to 0.3 on receiver
                  const previewY = -data.y + 0.1;
                  targetPlayer.ws.send(JSON.stringify({
                    type: "ball_preview",
                    ballId: ball.id,
                    targetColor: ball.targetColor,
                    x: data.x,
                    y: previewY,
                    fromPlayerId: playerId,
                  }));
                }
              } else {
                // Ball moved away from edge, cancel preview
                const targetPlayer = lobby.players.get(ball.targetPlayerId);
                if (targetPlayer) {
                  targetPlayer.ws.send(JSON.stringify({
                    type: "ball_preview_cancel",
                    ballId: ball.id,
                  }));
                }
              }
            }
          }

          // // Ball released over edge - send to target player
          // if (data.type === "ball_release") {
          //   const ball = lobby.balls.find(b => b.id === data.ballId);
          //   if (ball && ball.holderId === playerId && ball.status === "held") {
          //     // Send to the target player (the one whose color matches)
          //     ball.status = "incoming";
          //     ball.sentFromId = playerId;
          //     ball.holderId = ball.targetPlayerId;
          //     ball.x = 0.5;
          //     ball.y = 0.5;
          //     ball.incomingTimestamp = Date.now();

          //     console.log(`[SERVER] Ball ${ball.id} sent from ${playerId} to ${ball.targetPlayerId}`);
          //     broadcast(lobby, JSON.stringify({
          //       type: "ball_incoming",
          //       ball,
          //       fromPlayerId: playerId,
          //     }));
          //   }
          // }

          // Player grabs a preview ball (takes ownership while it's being sent)
          if (data.type === "ball_grab_preview") {
            const ball = lobby.balls.find(b => b.id === data.ballId);
            // Only allow if this player is the target and ball is still held by sender
            if (ball && ball.targetPlayerId === playerId && ball.status === "held") {
              const previousHolder = ball.holderId;
              ball.status = "incoming";
              ball.sentFromId = previousHolder ?? undefined;
              ball.holderId = playerId;
              ball.x = data.x;
              ball.y = data.y;
              ball.incomingTimestamp = Date.now();

              console.log(`[SERVER] Ball ${ball.id} grabbed by target ${playerId} from preview`);
              broadcast(lobby, JSON.stringify({
                type: "ball_grabbed_from_preview",
                ball,
                fromPlayerId: previousHolder,
                toPlayerId: playerId,
              }));
            }
          }

          // Player accepts incoming ball (moves it to ball house)
          if (data.type === "ball_collect") {
            const ball = lobby.balls.find(b => b.id === data.ballId);
            if (ball && ball.holderId === playerId && ball.status === "incoming") {
              ball.status = "collected";
              ball.holderId = null;
              ball.sentFromId = undefined;
              ball.incomingTimestamp = undefined;

              // Increment collected count
              const count = lobby.collectedBalls.get(playerId) || 0;
              lobby.collectedBalls.set(playerId, count + 1);

              console.log(`[SERVER] Ball ${ball.id} collected by ${playerId}. Total: ${count + 1}`);
              broadcast(lobby, JSON.stringify({
                type: "ball_collected",
                ballId: ball.id,
                playerId,
                collectedBalls: Object.fromEntries(lobby.collectedBalls),
              }));

              // Check win condition - all balls collected
              const activeBalls = lobby.balls.filter(b => b.status !== "collected");
              if (activeBalls.length === 0) {
                broadcast(lobby, JSON.stringify({
                  type: "game_won",
                  collectedBalls: Object.fromEntries(lobby.collectedBalls),
                }));
              }
            }
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

      broadcast(
        lobby,
        JSON.stringify({
          type: "player_left",
          playerId,
          playerName,
          players: getPlayerList(lobby),
        })
      );

      // If game is in progress and a player leaves, end the game
      if (lobby.gameState && !lobby.gameState.gameOver) {
        lobby.gameState.gameOver = true;
        if (lobby.gameState.tickInterval) {
          clearInterval(lobby.gameState.tickInterval);
        }
        broadcast(
          lobby,
          JSON.stringify({
            type: "game_over",
            winner: false,
            explodedPlayerName: playerName,
            explodedEmoji: "disconnected",
            survivedTime: Math.floor((Date.now() - lobby.gameState.startedAt) / 1000),
          })
        );
      }

      if (lobby.players.size === 0) {
        if (lobby.gameState?.tickInterval) {
          clearInterval(lobby.gameState.tickInterval);
        }
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
