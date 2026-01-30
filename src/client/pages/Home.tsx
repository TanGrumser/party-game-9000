import { useState, useEffect } from "react";

const STORAGE_KEY = "party-game-9000-name";

interface HomeProps {
  onCreateGame: (name: string) => Promise<string | null>;
  onJoinGame: (code: string, name: string) => Promise<boolean>;
}

export function Home({ onCreateGame, onJoinGame }: HomeProps) {
  const [playerName, setPlayerName] = useState("");

  // Load name from localStorage on mount
  useEffect(() => {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved) {
      setPlayerName(saved);
    }
  }, []);

  // Save name to localStorage when changed
  const handleNameChange = (name: string) => {
    setPlayerName(name);
    console.log("Saving name to localStorage:", name);
    if (name.trim()) {
      localStorage.setItem(STORAGE_KEY, name.trim());
    }
  };
  const [joinCode, setJoinCode] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const validateName = (): boolean => {
    if (!playerName.trim()) {
      setError("Please enter your name");
      return false;
    }
    return true;
  };

  const handleCreate = async () => {
    setError("");
    if (!validateName()) return;

    setLoading(true);
    const lobbyId = await onCreateGame(playerName.trim());
    if (!lobbyId) {
      setError("Failed to create game");
    }
    setLoading(false);
  };

  const handleJoin = async () => {
    setError("");
    if (!validateName()) return;

    const code = joinCode.toUpperCase().trim();
    if (!code) {
      setError("Please enter a lobby code");
      return;
    }

    setLoading(true);
    const success = await onJoinGame(code, playerName.trim());
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
        <input
          type="text"
          placeholder="Enter your name"
          value={playerName}
          onChange={(e) => handleNameChange(e.target.value)}
          maxLength={20}
          className="input-name"
          disabled={loading}
        />

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
