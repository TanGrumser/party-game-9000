import { useState, useEffect, useRef } from "react";
import { Game, type GameOverData } from "./Game";
import { GameOver } from "./GameOver";

// ============ TYPES ============
import { useState, useEffect, useRef, useCallback } from "react";
import { Ball } from "../components/Ball";

interface Player {
  id: string;
  name: string;
  connected: boolean;
  color: string;
  colorIndex: number;
}

interface BallState {
  id: string;
  targetPlayerId: string;
  targetColor: string;
  holderId: string | null;
  x: number;
  y: number;
  status: "held" | "incoming" | "collected";
  sentFromId?: string;
  incomingTimestamp?: number;
}

interface ChatMessage {
  id: string;
  playerId: string;
  playerName: string;
  message: string;
  timestamp: number;
}

interface LobbyProps {
  lobbyId: string;
  playerName: string;
  onLeave: () => void;
}

// ============ COMPONENT ============

export function Lobby({ lobbyId, playerName, onLeave }: LobbyProps) {
  // Connection state
  const [playerId, setPlayerId] = useState("");
  const [players, setPlayers] = useState<Player[]>([]);
  const [connected, setConnected] = useState(false);

  // Chat state
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [inputMessage, setInputMessage] = useState("");
  const [copied, setCopied] = useState(false);

  // Game state
  const [gameStarted, setGameStarted] = useState(false);
  const [gameOver, setGameOver] = useState(false);
  const [gameOverData, setGameOverData] = useState<GameOverData | null>(null);
  const [initialGameData, setInitialGameData] = useState<{ inputs: unknown[]; visibleCodes: unknown[]; lives: number } | null>(null);

  // Error state
  const [error, setError] = useState("");
  const [balls, setBalls] = useState<BallState[]>([]);
  const [collectedBalls, setCollectedBalls] = useState<Record<string, number>>({});
  const [incomingBallIds, setIncomingBallIds] = useState<Set<string>>(new Set());
  const [previewBalls, setPreviewBalls] = useState<Map<string, { color: string; x: number; y: number }>>(new Map());

  const wsRef = useRef<WebSocket | null>(null);
  const messageIdRef = useRef(0);
  const previewGrabRequestedRef = useRef<Set<string>>(new Set());
  const previewGrabConfirmedRef = useRef<Set<string>>(new Set());
  const previewDragActiveRef = useRef<string | null>(null);

  // Get current player's color
  const myPlayer = players.find(p => p.id === playerId);
  const myColor = myPlayer?.color ?? "#646cff";

  // Ball handlers
  const handleBallMove = useCallback((ballId: string, x: number, y: number, status: BallState["status"]) => {
    let shouldSend = false;
    setBalls(prev => {
      const ball = prev.find(b => b.id === ballId);
      if (!ball || ball.holderId !== playerId || ball.status !== status) {
        return prev;
      }
      shouldSend = true;
      return prev.map(b =>
        b.id === ballId ? { ...b, x, y } : b
      );
    });
    if (shouldSend && wsRef.current) {
      wsRef.current.send(JSON.stringify({ type: "ball_update", ballId, x, y }));
    }
  }, [playerId]);

  // const handleBallRelease = useCallback((ballId: string) => {
  //   if (wsRef.current) {
  //     wsRef.current.send(JSON.stringify({ type: "ball_release", ballId }));
  //   }
  // }, []);

  const handleBallCollect = useCallback((ballId: string) => {
    if (wsRef.current) {
      wsRef.current.send(JSON.stringify({ type: "ball_collect", ballId }));
    }
  }, []);

  const handleGrabPreview = useCallback((ballId: string, x: number, y: number) => {
    if (wsRef.current) {
      wsRef.current.send(JSON.stringify({ type: "ball_grab_preview", ballId, x, y }));
    }
  }, []);

  const handlePreviewMove = useCallback((ballId: string, x: number, y: number) => {
    setPreviewBalls(prev => {
      if (!prev.has(ballId)) return prev;
      const next = new Map(prev);
      const current = next.get(ballId);
      if (!current) return prev;
      next.set(ballId, { ...current, x, y });
      return next;
    });
  }, []);

  // Remove old chat messages after they fade
  useEffect(() => {
    const interval = setInterval(() => {
      const now = Date.now();
      setMessages((prev) => prev.filter((m) => now - m.timestamp < 5000));
    }, 500);
    return () => clearInterval(interval);
  }, []);

  // WebSocket connection
  useEffect(() => {
    const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    const encodedName = encodeURIComponent(playerName);
    const wsUrl = `${protocol}//${window.location.host}/ws?lobby=${lobbyId}&name=${encodedName}`;
    console.log(`[CLIENT] Connecting to WebSocket: ${wsUrl}`);

    const ws = new WebSocket(wsUrl);
    wsRef.current = ws;

    ws.onopen = () => {
      console.log("[CLIENT] WebSocket connected");
      setConnected(true);
    };

    ws.onmessage = (event) => {
      console.log(`[CLIENT] Received: ${event.data}`);
      try {
        const data = JSON.parse(event.data);

        switch (data.type) {
          case "welcome":
            setPlayerId(data.playerId);
            setPlayers(data.players || []);
            setGameStarted(data.gameStarted || false);
            setBalls(data.balls || []);
            setCollectedBalls(data.collectedBalls || {});
            console.log(`[CLIENT] Welcome! Player ID: ${data.playerId}`);
            break;

          case "player_joined":
            setPlayers(data.players || []);
            break;

          case "player_left":
            setPlayers(data.players || []);
            break;

          case "chat":
            setMessages((prev) => [
              ...prev,
              {
                id: `msg-${messageIdRef.current++}`,
                playerId: data.playerId,
                playerName: data.playerName,
                message: data.message,
                timestamp: data.timestamp,
              },
            ]);
            break;

          case "error":
            setError(data.message);
            setTimeout(() => setError(""), 3000);
            break;

          case "game_start":
            setInitialGameData({ inputs: data.inputs, visibleCodes: data.visibleCodes, lives: data.lives });
            setGameStarted(true);
            setBalls(data.balls || []);
            setCollectedBalls(data.collectedBalls || {});
            setIncomingBallIds(new Set());
            setPreviewBalls(new Map());
            previewGrabRequestedRef.current = new Set();
            previewGrabConfirmedRef.current = new Set();
            previewDragActiveRef.current = null;
            setGameOver(false);
            break;

          case "ball_update":
            setBalls(prev => prev.map(b =>
              b.id === data.ballId ? { ...b, x: data.x, y: data.y } : b
            ));
            break;

          case "ball_incoming":
            setBalls(prev => prev.map(b =>
              b.id === data.ball.id ? data.ball : b
            ));
            // Track this as a new incoming ball for animation
            setIncomingBallIds(prev => new Set(prev).add(data.ball.id));
            // Clear preview since ball is now fully transferred
            setPreviewBalls(prev => {
              const next = new Map(prev);
              next.delete(data.ball.id);
              return next;
            });
            break;

          case "ball_preview":
            // Show preview of ball coming from another player
            setPreviewBalls(prev => {
              const next = new Map(prev);
              next.set(data.ballId, {
                color: data.targetColor,
                x: data.x,
                y: data.y,
              });
              return next;
            });
            break;

          case "ball_preview_cancel":
            // Remove preview when sender pulls ball back
            setPreviewBalls(prev => {
              const next = new Map(prev);
              next.delete(data.ballId);
              return next;
            });
            previewGrabRequestedRef.current.delete(data.ballId);
            previewGrabConfirmedRef.current.delete(data.ballId);
            if (previewDragActiveRef.current === data.ballId) {
              previewDragActiveRef.current = null;
            }
            break;

          case "balls_update":
            setBalls(data.balls || []);
            break;

          case "ball_grabbed_from_preview":
            setBalls(prev => prev.map(b =>
              b.id === data.ball.id ? data.ball : b
            ));
            previewGrabConfirmedRef.current.add(data.ball.id);
            setIncomingBallIds(prev => {
              const next = new Set(prev);
              next.delete(data.ball.id);
              return next;
            });
            if (previewDragActiveRef.current !== data.ball.id) {
              setPreviewBalls(prev => {
                const next = new Map(prev);
                next.delete(data.ball.id);
                return next;
              });
            }
            break;

          case "ball_collected":
            setBalls(prev => prev.map(b =>
              b.id === data.ballId ? { ...b, status: "collected", holderId: null } : b
            ));
            setCollectedBalls(data.collectedBalls || {});
            break;

          case "game_won":
            setCollectedBalls(data.collectedBalls || {});
            // Could show a win screen here
            break;

          case "game_over":
            setGameOver(true);
            setGameOverData({
              winner: data.winner,
              explodedPlayerName: data.explodedPlayerName,
              explodedEmoji: data.explodedEmoji,
              survivedTime: data.survivedTime,
            });
        }
      } catch (e) {
        console.error("[CLIENT] Error parsing message:", e);
      }
    };

    ws.onerror = (error) => {
      console.error("[CLIENT] WebSocket error:", error);
    };

    ws.onclose = () => {
      console.log("[CLIENT] WebSocket closed");
      setConnected(false);
    };

    return () => {
      ws.close();
    };
  }, [lobbyId, playerName]);

  // ============ HANDLERS ============

  const handleSendMessage = (e: React.FormEvent) => {
    e.preventDefault();
    if (!inputMessage.trim() || !wsRef.current) return;

    wsRef.current.send(JSON.stringify({ type: "chat", message: inputMessage.trim() }));
    setInputMessage("");
  };

  const handleCopyCode = async () => {
    await navigator.clipboard.writeText(lobbyId);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const handleLeave = () => {
    wsRef.current?.close();
    onLeave();
  };

  const handleStartGame = () => {
    if (wsRef.current) {
      wsRef.current.send(JSON.stringify({ type: "start_game" }));
    }
  };

  const handleGameOver = (data: GameOverData) => {
    setGameOver(true);
    setGameOverData(data);
  };

  const handleBackToLobby = () => {
    setGameOver(false);
    setGameOverData(null);
    setGameStarted(false);
    setInitialGameData(null);
    setIncomingBallIds(new Set());
    setPreviewBalls(new Map());
  };

  // ============ RENDER ============

  // Game Over Screen
  if (gameOver && gameOverData) {
    return (
      <GameOver
        explodedPlayerName={gameOverData.explodedPlayerName}
        explodedEmoji={gameOverData.explodedEmoji}
        survivedTime={gameOverData.survivedTime}
        onBack={handleBackToLobby}
      />
    );
  }

  // Code Game Screen (Stage 1)
  if (gameStarted && initialGameData) {
    return (
      <Game
        lobbyId={lobbyId}
        playerName={playerName}
        playerId={playerId}
        wsRef={wsRef}
        initialInputs={initialGameData.inputs}
        initialVisibleCodes={initialGameData.visibleCodes}
        initialLives={initialGameData.lives}
        onGameOver={handleGameOver}
      />
    );
  }

  // Get balls I'm holding (to send out)
  const myHeldBalls = balls.filter(b => b.holderId === playerId && b.status === "held");
  // Get balls incoming to me (to collect)
  const myIncomingBalls = balls.filter(b => b.holderId === playerId && b.status === "incoming" && !previewBalls.has(b.id));

  // Ball Game Screen (Stage 2)
  if (gameStarted) {
    return (
      <div className="page lobby">
        <header className="lobby-header">
          <div className="lobby-code-section">
            <h2>
              Lobby: <span className="lobby-code">{lobbyId}</span>
            </h2>
            <button className="btn btn-copy" onClick={handleCopyCode}>
              {copied ? "Copied!" : "Copy"}
            </button>
          </div>
          <div className="header-info">
            <span className={`status ${connected ? "connected" : "disconnected"}`}>
              {connected ? "Connected" : "Disconnected"}
            </span>
            <span>Players: {players.length}</span>
            <span style={{ color: myColor }}>You: {playerName}</span>
          </div>
        </header>

        {/* Player colors legend */}
        <div className="players-legend">
          {players.map(p => (
            <div key={p.id} className="player-legend-item">
              <div
                className="player-color-dot"
                style={{ backgroundColor: p.color }}
              />
              <span className={p.id === playerId ? "you" : ""}>
                {p.name}{p.id === playerId ? " (You)" : ""}
              </span>
              <span className="collected-count">
                {collectedBalls[p.id] || 0} collected
              </span>
            </div>
          ))}
        </div>

        <div className="game-container">
          <div className="game-area">
            {/* Held balls - drag to top to send */}
            {myHeldBalls.map(ball => (
              <Ball
                key={ball.id}
                id={ball.id}
                x={ball.x}
                y={ball.y}
                color={ball.targetColor}
                status="held"
                onMove={(x, y) => handleBallMove(ball.id, x, y, "held")}
                onRelease={() => {}}
                onCollect={() => {}}
              />
            ))}

            {/* Preview balls - coming from other players (grabbable) */}
            {Array.from(previewBalls.entries()).map(([ballId, preview]) => (
              <Ball
                key={`preview-${ballId}`}
                id={ballId}
                x={preview.x}
                y={preview.y}
                color={preview.color}
                status="incoming"
                onMove={(x, y) => handlePreviewMove(ballId, x, y)}
                onRelease={() => {}}
                onCollect={() => handleBallCollect(ballId)}
                onDragStart={() => {
                  previewDragActiveRef.current = ballId;
                  if (!previewGrabRequestedRef.current.has(ballId)) {
                    previewGrabRequestedRef.current.add(ballId);
                    handleGrabPreview(ballId, preview.x, preview.y);
                  }
                }}
                onDragEnd={() => {
                  if (previewDragActiveRef.current === ballId) {
                    previewDragActiveRef.current = null;
                  }
                  if (previewGrabConfirmedRef.current.has(ballId)) {
                    setPreviewBalls(prev => {
                      const next = new Map(prev);
                      next.delete(ballId);
                      return next;
                    });
                  }
                }}
              />
            ))}

            {/* Incoming balls - drag to bottom to collect */}
            {myIncomingBalls.map(ball => (
              <Ball
                key={ball.id}
                id={ball.id}
                x={ball.x}
                y={ball.y}
                color={ball.targetColor}
                status="incoming"
                onMove={(x, y) => handleBallMove(ball.id, x, y, "incoming")}
                onRelease={() => {}}
                onCollect={() => handleBallCollect(ball.id)}
                animateEntry={incomingBallIds.has(ball.id)}
              />
            ))}

            {/* Instructions */}
            <div className="game-instructions">
              {myHeldBalls.length > 0 && (
                <p>Drag colored balls to the TOP to send them!</p>
              )}
              {myIncomingBalls.length > 0 && (
                <p>Drag incoming balls to the BOTTOM to collect!</p>
              )}
              {myHeldBalls.length === 0 && myIncomingBalls.length === 0 && (
                <p>Waiting for balls...</p>
              )}
            </div>

            {/* Ball house indicator at bottom */}
            <div className="ball-house">
              <span>Ball House</span>
            </div>
          </div>
        </div>

        {/* Floating chat bubbles */}
        <div className="chat-bubbles">
          {messages.map((msg) => (
            <div
              key={msg.id}
              className={`chat-bubble ${msg.playerId === playerId ? "own" : ""}`}
            >
              <span className="bubble-sender">
                {msg.playerId === playerId ? "You" : msg.playerName}:
              </span>
              <span className="bubble-text">{msg.message}</span>
            </div>
          ))}
        </div>

        <form className="message-form" onSubmit={handleSendMessage}>
          <input
            type="text"
            placeholder="Type a message..."
            value={inputMessage}
            onChange={(e) => setInputMessage(e.target.value)}
            className="message-input"
            disabled={!connected}
          />
          <button type="submit" className="btn btn-primary" disabled={!connected}>
            Send
          </button>
        </form>
      </div>
  );
  }

  // Pre-game Lobby
  return (
    <div className="page lobby">
      <header className="lobby-header">
        <div className="lobby-code-section">
          <h2>
            Lobby: <span className="lobby-code">{lobbyId}</span>
          </h2>
          <button className="btn btn-copy" onClick={handleCopyCode}>
            {copied ? "Copied!" : "Copy"}
          </button>
        </div>
        <div className="header-info">
          <span className={`status ${connected ? "connected" : "disconnected"}`}>
            {connected ? "Connected" : "Disconnected"}
          </span>
          <span>Players: {players.length}</span>
          <span style={{ color: myColor }}>You: {playerName}</span>
          <button className="btn btn-small" onClick={handleLeave}>
            Leave
          </button>
        </div>
      </header>

      <div className="pre-game-container">
        <div className="players-waiting">
          <h3>Waiting for players...</h3>
          <div className="player-list">
            {players.map((player) => (
              <div
                key={player.id}
                className={`player-card ${player.id === playerId ? "you" : ""}`}
                style={{ borderColor: player.color }}
              >
                <div
                  className="player-color-indicator"
                  style={{ backgroundColor: player.color }}
                />
                <span className="player-name">{player.name}</span>
                {player.id === playerId && <span className="you-badge">You</span>}
              </div>
            ))}
          </div>
          {error && <p className="error-message">{error}</p>}
          <p className="min-players-hint">
            {players.length < 2 ? "Need at least 2 players to start" : "Ready to start!"}
          </p>
          <button
            className="btn btn-primary btn-large start-btn"
            onClick={handleStartGame}
            disabled={!connected || players.length < 2}
          >
            {players.length < 2 ? "Need 2+ players" : "Start Game"}
          </button>
        </div>
      </div>

      {/* Floating chat bubbles */}
      <div className="chat-bubbles">
        {messages.map((msg) => (
          <div key={msg.id} className={`chat-bubble ${msg.playerId === playerId ? "own" : ""}`}>
            <span className="bubble-sender">{msg.playerId === playerId ? "You" : msg.playerName}:</span>
            <span className="bubble-text">{msg.message}</span>
          </div>
        ))}
      </div>

      <form className="message-form" onSubmit={handleSendMessage}>
        <input
          type="text"
          placeholder="Type a message..."
          value={inputMessage}
          onChange={(e) => setInputMessage(e.target.value)}
          className="message-input"
          disabled={!connected}
        />
        <button type="submit" className="btn btn-primary" disabled={!connected}>
          Send
        </button>
      </form>
    </div>
  );
}
