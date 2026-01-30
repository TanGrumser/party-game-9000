import { useState, useEffect, useRef } from "react";

interface Player {
  id: string;
  name: string;
  connected: boolean;
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

export function Lobby({ lobbyId, playerName, onLeave }: LobbyProps) {
  const [playerId, setPlayerId] = useState("");
  const [players, setPlayers] = useState<Player[]>([]);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [inputMessage, setInputMessage] = useState("");
  const [copied, setCopied] = useState(false);
  const [connected, setConnected] = useState(false);
  const [gameStarted, setGameStarted] = useState(false);

  const wsRef = useRef<WebSocket | null>(null);
  const messageIdRef = useRef(0);

  // Remove old messages after they fade
  useEffect(() => {
    const interval = setInterval(() => {
      const now = Date.now();
      setMessages((prev) => prev.filter((m) => now - m.timestamp < 5000));
    }, 500);
    return () => clearInterval(interval);
  }, []);

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
            setPlayers(data.players);
            setGameStarted(data.gameStarted);
            console.log(`[CLIENT] Welcome! Player ID: ${data.playerId}`);
            break;

          case "player_joined":
            setPlayers(data.players);
            break;

          case "player_left":
            setPlayers(data.players);
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

          case "game_started":
            setGameStarted(true);
            break;
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

  const handleSendMessage = (e: React.FormEvent) => {
    e.preventDefault();
    if (!inputMessage.trim() || !wsRef.current) return;

    const message = { type: "chat", message: inputMessage.trim() };
    console.log(`[CLIENT] Sending: ${JSON.stringify(message)}`);
    wsRef.current.send(JSON.stringify(message));
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
            <span>You: {playerName}</span>
          </div>
        </header>

        <div className="game-container">
          <div className="game-area">
            <p>Game is running...</p>
            <p>Players: {players.map((p) => p.name).join(", ")}</p>
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

  // Pre-game lobby
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
          <span>You: {playerName}</span>
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
              <div key={player.id} className={`player-card ${player.id === playerId ? "you" : ""}`}>
                <span className="player-name">{player.name}</span>
                {player.id === playerId && <span className="you-badge">You</span>}
              </div>
            ))}
          </div>
          <button
            className="btn btn-primary btn-large start-btn"
            onClick={handleStartGame}
            disabled={!connected || players.length < 1}
          >
            Start Game
          </button>
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
