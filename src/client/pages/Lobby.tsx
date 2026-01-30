import { useState, useEffect, useRef } from "react";

interface ChatMessage {
  type: string;
  playerId: string;
  message: string;
  timestamp: number;
}

interface LobbyProps {
  lobbyId: string;
  onLeave: () => void;
}

export function Lobby({ lobbyId, onLeave }: LobbyProps) {
  const [playerId, setPlayerId] = useState("");
  const [playerCount, setPlayerCount] = useState(0);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [inputMessage, setInputMessage] = useState("");
  const [copied, setCopied] = useState(false);
  const [connected, setConnected] = useState(false);

  const wsRef = useRef<WebSocket | null>(null);
  const messagesEndRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  useEffect(() => {
    const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    const wsUrl = `${protocol}//${window.location.host}/ws?lobby=${lobbyId}`;
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
    };

    ws.onclose = () => {
      console.log("[CLIENT] WebSocket closed");
      setConnected(false);
    };

    return () => {
      ws.close();
    };
  }, [lobbyId]);

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
          <span>Players: {playerCount}</span>
          <span>You: {playerId || "..."}</span>
          <button className="btn btn-small" onClick={handleLeave}>
            Leave
          </button>
        </div>
      </header>

      <div className="chat-container">
        <div className="messages">
          {messages.length === 0 && (
            <p className="empty-state">No messages yet. Say hello!</p>
          )}
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
                  <span className="sender">
                    {msg.playerId === playerId ? "You" : msg.playerId}:
                  </span>
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
            disabled={!connected}
          />
          <button
            type="submit"
            className="btn btn-primary"
            disabled={!connected}
          >
            Send
          </button>
        </form>
      </div>
    </div>
  );
}
