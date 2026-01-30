import { useState } from "react";
import { Home } from "./pages/Home";
import { Lobby } from "./pages/Lobby";
import "./index.css";

type Screen = "home" | "lobby";

export function App() {
  const [screen, setScreen] = useState<Screen>("home");
  const [lobbyId, setLobbyId] = useState("");

  const handleCreateGame = async (): Promise<string | null> => {
    console.log("[CLIENT] Creating new lobby...");
    try {
      const response = await fetch("/api/lobby/create", { method: "POST" });
      const data = await response.json();
      console.log(`[CLIENT] Lobby created: ${data.lobbyId}`);
      setLobbyId(data.lobbyId);
      setScreen("lobby");
      return data.lobbyId;
    } catch (e) {
      console.error("[CLIENT] Error creating lobby:", e);
      return null;
    }
  };

  const handleJoinGame = async (code: string): Promise<boolean> => {
    console.log(`[CLIENT] Checking if lobby ${code} exists...`);
    try {
      const response = await fetch(`/api/lobby/${code}`);
      const data = await response.json();
      if (data.exists) {
        console.log(`[CLIENT] Joining lobby: ${code}`);
        setLobbyId(code);
        setScreen("lobby");
        return true;
      }
      return false;
    } catch (e) {
      console.error("[CLIENT] Error joining lobby:", e);
      return false;
    }
  };

  const handleLeave = () => {
    setScreen("home");
    setLobbyId("");
  };

  if (screen === "lobby" && lobbyId) {
    return <Lobby lobbyId={lobbyId} onLeave={handleLeave} />;
  }

  return <Home onCreateGame={handleCreateGame} onJoinGame={handleJoinGame} />;
}
