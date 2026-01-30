import { useState } from "react";

interface HomeProps {
  onCreateGame: () => Promise<string | null>;
  onJoinGame: (code: string) => Promise<boolean>;
}

export function Home({ onCreateGame, onJoinGame }: HomeProps) {
  const [joinCode, setJoinCode] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const handleCreate = async () => {
    setError("");
    setLoading(true);
    const lobbyId = await onCreateGame();
    if (!lobbyId) {
      setError("Failed to create game");
    }
    setLoading(false);
  };

  const handleJoin = async () => {
    setError("");
    const code = joinCode.toUpperCase().trim();

    if (!code) {
      setError("Please enter a lobby code");
      return;
    }

    setLoading(true);
    const success = await onJoinGame(code);
    if (!success) {
      setError("Lobby not found");
    }
    setLoading(false);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter") {
      handleJoin();
    }
  };

  return (
    <div className="page home">
      <h1>Party Game 9000</h1>
      <p className="subtitle">A collaborative chaotic party game</p>

      <div className="menu">
        <button
          className="btn btn-primary"
          onClick={handleCreate}
          disabled={loading}
        >
          {loading ? "Loading..." : "Create Game"}
        </button>

        <div className="divider">or</div>

        <div className="join-section">
          <input
            type="text"
            placeholder="Enter lobby code"
            value={joinCode}
            onChange={(e) => setJoinCode(e.target.value.toUpperCase())}
            onKeyDown={handleKeyDown}
            maxLength={4}
            className="input-code"
            disabled={loading}
          />
          <button
            className="btn btn-secondary"
            onClick={handleJoin}
            disabled={loading}
          >
            Join Game
          </button>
        </div>

        {error && <p className="error">{error}</p>}
      </div>
    </div>
  );
}
