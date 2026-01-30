import { useState, useEffect, useRef } from "react";
import "./index.css";

type Screen = "home" | "game";

interface ChatMessage {
  type: string;
  playerId: string;
  message: string;
  timestamp: number;
}

export function App() {
  const [screen, setScreen] = useState<Screen>("home");
  const [lobbyId, setLobbyId] = useState("");
  const [joinCode, setJoinCode] = useState("");
  const [error, setError] = useState("");
  const [playerId, setPlayerId] = useState("");
  const [playerCount, setPlayerCount] = useState(0);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [inputMessage, setInputMessage] = useState("");

  const wsRef = useRef<WebSocket | null>(null);
  const messagesEndRef = useRef<HTMLDivElement>(null);

  // Auto-scroll messages
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  // Cleanup WebSocket on unmount
  useEffect(() => {
    return () => {
      if (wsRef.current) {
        wsRef.current.close();
      }
    };
  }, []);

  const connectToLobby = (code: string) => {
    const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    const wsUrl = `${protocol}//${window.location.host}/ws?lobby=${code}`;
    console.log(`[CLIENT] Connecting to WebSocket: ${wsUrl}`);

    const ws = new WebSocket(wsUrl);
    wsRef.current = ws;

    ws.onopen = () => {
      console.log("[CLIENT] WebSocket connected");
    };

    ws.onmessage = (event) => {
      console.log(`[CLIENT] Received: ${event.data}`);
      try {
        const data = JSON.parse(event.data);

        switch (data.type) {
          case "welcome":
            setPlayerId(data.playerId);
            setLobbyId(data.lobbyId);
            setPlayerCount(data.playerCount);
            console.log(`[CLIENT] Welcome! Player ID: ${data.playerId}`);
            break;

          case "player_joined":
            setPlayerCount(data.playerCount);
            setMessages((prev) => [
              ...prev,
              {
                type: "system",
                playerId: data.playerId,
                message: `Player ${data.playerId} joined`,
                timestamp: Date.now(),
              },
            ]);
            break;

          case "player_left":
            setPlayerCount(data.playerCount);
            setMessages((prev) => [
              ...prev,
              {
                type: "system",
                playerId: data.playerId,
                message: `Player ${data.playerId} left`,
                timestamp: Date.now(),
              },
            ]);
            break;

          case "chat":
            setMessages((prev) => [...prev, data]);
            break;
        }
      } catch (e) {
        console.error("[CLIENT] Error parsing message:", e);
      }
    };

    ws.onerror = (error) => {
      console.error("[CLIENT] WebSocket error:", error);
      setError("Connection error");
    };

    ws.onclose = () => {
      console.log("[CLIENT] WebSocket closed");
    };
  };

  const handleCreateGame = async () => {
    setError("");
    console.log("[CLIENT] Creating new lobby...");

    try {
      const response = await fetch("/api/lobby/create", { method: "POST" });
      const data = await response.json();
      console.log(`[CLIENT] Lobby created: ${data.lobbyId}`);

      connectToLobby(data.lobbyId);
      setScreen("game");
    } catch (e) {
      console.error("[CLIENT] Error creating lobby:", e);
      setError("Failed to create game");
    }
  };

  const handleJoinGame = async () => {
    setError("");
    const code = joinCode.toUpperCase().trim();

    if (!code) {
      setError("Please enter a lobby code");
      return;
    }

    console.log(`[CLIENT] Checking if lobby ${code} exists...`);

    try {
      const response = await fetch(`/api/lobby/${code}`);
      const data = await response.json();

      if (data.exists) {
        console.log(`[CLIENT] Joining lobby: ${code}`);
        connectToLobby(code);
        setScreen("game");
      } else {
        setError("Lobby not found");
      }
    } catch (e) {
      console.error("[CLIENT] Error joining lobby:", e);
      setError("Failed to join game");
    }
  };

  const handleSendMessage = (e: React.FormEvent) => {
    e.preventDefault();

    if (!inputMessage.trim() || !wsRef.current) return;

    const message = {
      type: "chat",
      message: inputMessage.trim(),
    };

    console.log(`[CLIENT] Sending: ${JSON.stringify(message)}`);
    wsRef.current.send(JSON.stringify(message));
    setInputMessage("");
  };

  const handleLeaveGame = () => {
    if (wsRef.current) {
      wsRef.current.close();
      wsRef.current = null;
    }
    setScreen("home");
    setLobbyId("");
    setPlayerId("");
    setPlayerCount(0);
    setMessages([]);
    setJoinCode("");
  };

  const [copied, setCopied] = useState(false);

  const handleCopyCode = async () => {
    await navigator.clipboard.writeText(lobbyId);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  if (screen === "home") {
    return (
      <div className="app">
        <h1>Party Game 9000</h1>
        <p className="subtitle">A collaborative chaotic party game</p>

        <div className="menu">
          <button className="btn btn-primary" onClick={handleCreateGame}>
            Create Game
          </button>

          <div className="divider">or</div>

          <div className="join-section">
            <input
              type="text"
              placeholder="Enter lobby code"
              value={joinCode}
              onChange={(e) => setJoinCode(e.target.value.toUpperCase())}
              maxLength={4}
              className="input-code"
            />
            <button className="btn btn-secondary" onClick={handleJoinGame}>
              Join Game
            </button>
          </div>

          {error && <p className="error">{error}</p>}
        </div>
      </div>
    );
  }

  return (
    <div className="app game-screen">
      <header className="game-header">
        <div className="lobby-code-section">
          <h2>Lobby: <span className="lobby-code">{lobbyId}</span></h2>
          <button className="btn btn-copy" onClick={handleCopyCode}>
            {copied ? "Copied!" : "Copy"}
          </button>
        </div>
        <div className="header-info">
          <span>Players: {playerCount}</span>
          <span>You: {playerId}</span>
          <button className="btn btn-small" onClick={handleLeaveGame}>
            Leave
          </button>
        </div>
      </header>

      <div className="chat-container">
        <div className="messages">
          {messages.map((msg, i) => (
            <div
              key={i}
              className={`message ${msg.type === "system" ? "system" : ""} ${
                msg.playerId === playerId ? "own" : ""
              }`}
            >
              {msg.type === "system" ? (
                <span className="system-text">{msg.message}</span>
              ) : (
                <>
                  <span className="sender">{msg.playerId === playerId ? "You" : msg.playerId}:</span>
                  <span className="text">{msg.message}</span>
                </>
              )}
            </div>
          ))}
          <div ref={messagesEndRef} />
        </div>

        <form className="message-form" onSubmit={handleSendMessage}>
          <input
            type="text"
            placeholder="Type a message..."
            value={inputMessage}
            onChange={(e) => setInputMessage(e.target.value)}
            className="message-input"
          />
          <button type="submit" className="btn btn-primary">
            Send
          </button>
        </form>
      </div>
    </div>
  );
}

export default App;
