import { useState, useEffect, useRef } from "react";

// ============ TYPES ============

interface InputFieldState {
  id: string;
  emoji: string;
  timerDuration: number;
  timeRemaining: number;
}

interface VisibleCode {
  targetPlayerId: string;
  targetPlayerName: string;
  inputId: string;
  emoji: string;
  code: string;
  codeExpiresIn: number;
}

// Store codes with the timestamp when we received them
interface VisibleCodeWithTimestamp extends VisibleCode {
  receivedAt: number;
}

interface ExplosionEvent {
  playerName: string;
  emoji: string;
  timestamp: number;
}

interface GameProps {
  lobbyId: string;
  playerName: string;
  playerId: string;
  wsRef: React.RefObject<WebSocket | null>;
  initialInputs: InputFieldState[];
  initialVisibleCodes: VisibleCode[];
  initialLives: number;
  onGameOver: (data: GameOverData) => void;
}

export interface GameOverData {
  winner: boolean;
  explodedPlayerName: string;
  explodedEmoji: string;
  survivedTime: number;
}

// ============ COMPONENT ============

export function Game({ lobbyId, playerName, playerId, wsRef, initialInputs, initialVisibleCodes, initialLives, onGameOver }: GameProps) {
  const [inputs, setInputs] = useState<InputFieldState[]>(initialInputs);
  const [survivedTime, setSurvivedTime] = useState(0);
  const [difficultyMultiplier, setDifficultyMultiplier] = useState(1);
  const [lives, setLives] = useState(initialLives);
  const [explosions, setExplosions] = useState<ExplosionEvent[]>([]);

  // Store visible codes with timestamp when received
  const [visibleCodes, setVisibleCodes] = useState<VisibleCodeWithTimestamp[]>(() => {
    const now = Date.now();
    return initialVisibleCodes.map((code) => ({ ...code, receivedAt: now }));
  });

  // Current time for calculating code expiry (updates frequently)
  const [now, setNow] = useState(Date.now());

  // Code input state - initialize from inputs
  const [codeInputs, setCodeInputs] = useState<Record<string, string>>(() => {
    const initial: Record<string, string> = {};
    for (const input of initialInputs) {
      initial[input.id] = "";
    }
    return initial;
  });
  const [codeResults, setCodeResults] = useState<Record<string, { success: boolean; message: string }>>({});

  // Update "now" every 100ms for smooth timer animation
  useEffect(() => {
    const interval = setInterval(() => {
      setNow(Date.now());
    }, 100);
    return () => clearInterval(interval);
  }, []);

  // Clear code results after 2 seconds
  useEffect(() => {
    const timeouts: NodeJS.Timeout[] = [];
    for (const inputId of Object.keys(codeResults)) {
      const timeout = setTimeout(() => {
        setCodeResults((prev) => {
          const next = { ...prev };
          delete next[inputId];
          return next;
        });
      }, 2000);
      timeouts.push(timeout);
    }
    return () => timeouts.forEach(clearTimeout);
  }, [codeResults]);

  // Clear explosions after 3 seconds
  useEffect(() => {
    if (explosions.length === 0) return;
    const timeout = setTimeout(() => {
      const now = Date.now();
      setExplosions((prev) => prev.filter((e) => now - e.timestamp < 3000));
    }, 3000);
    return () => clearTimeout(timeout);
  }, [explosions]);

  // Listen for game messages
  useEffect(() => {
    const ws = wsRef.current;
    if (!ws) return;

    const handleMessage = (event: MessageEvent) => {
      try {
        const data = JSON.parse(event.data);

        switch (data.type) {
          case "game_tick":
            setInputs((prev) =>
              prev.map((input) => {
                const update = data.inputs.find((i: { id: string }) => i.id === input.id);
                return update ? { ...input, timeRemaining: update.timeRemaining } : input;
              })
            );
            setSurvivedTime(data.survivedTime);
            setDifficultyMultiplier(data.difficultyMultiplier);
            if (data.lives !== undefined) {
              setLives(data.lives);
            }
            if (data.visibleCodes) {
              // Add timestamp to new codes
              const receivedAt = Date.now();
              setVisibleCodes(
                data.visibleCodes.map((code: VisibleCode) => ({ ...code, receivedAt }))
              );
            }
            break;

          case "bomb_exploded":
            setLives(data.livesRemaining);
            setExplosions((prev) => [
              ...prev,
              {
                playerName: data.explodedPlayerName,
                emoji: data.explodedEmoji,
                timestamp: Date.now(),
              },
            ]);
            break;

          case "code_result":
            setCodeResults((prev) => ({
              ...prev,
              [data.inputId]: { success: data.success, message: data.message },
            }));
            if (data.success) {
              setCodeInputs((prev) => ({ ...prev, [data.inputId]: "" }));
            }
            break;

          case "game_over":
            onGameOver({
              winner: data.winner,
              explodedPlayerName: data.explodedPlayerName,
              explodedEmoji: data.explodedEmoji,
              survivedTime: data.survivedTime,
            });
            break;
        }
      } catch (e) {
        console.error("[GAME] Error parsing message:", e);
      }
    };

    ws.addEventListener("message", handleMessage);
    return () => ws.removeEventListener("message", handleMessage);
  }, [wsRef, onGameOver]);

  // ============ HANDLERS ============

  const handleCodeChange = (inputId: string, value: string) => {
    const cleaned = value.replace(/[^0-9]/g, "").slice(0, 4);
    setCodeInputs((prev) => ({ ...prev, [inputId]: cleaned }));

    // Auto-submit when 4 digits entered
    if (cleaned.length === 4 && wsRef.current) {
      wsRef.current.send(JSON.stringify({ type: "submit_code", inputId, code: cleaned }));
    }
  };

  // ============ RENDER HELPERS ============

  const formatTime = (seconds: number): string => {
    const mins = Math.floor(seconds / 60);
    const secs = seconds % 60;
    return `${mins}:${secs.toString().padStart(2, "0")}`;
  };

  const getTimerProgress = (input: InputFieldState): number => {
    return Math.max(0, Math.min(100, (input.timeRemaining / input.timerDuration) * 100));
  };

  const getTimerColor = (progress: number): string => {
    if (progress > 50) return "#4ade80";
    if (progress > 25) return "#facc15";
    return "#ef4444";
  };

  // Calculate remaining time for a code based on when we received it
  const getCodeTimeRemaining = (code: VisibleCodeWithTimestamp): number => {
    const elapsed = now - code.receivedAt;
    return Math.max(0, code.codeExpiresIn - elapsed);
  };

  // Group visible codes by player
  const codesByPlayer = new Map<string, VisibleCodeWithTimestamp[]>();
  for (const code of visibleCodes) {
    const existing = codesByPlayer.get(code.targetPlayerId) || [];
    existing.push(code);
    codesByPlayer.set(code.targetPlayerId, existing);
  }

  // ============ RENDER ============

  return (
    <div className="page game-page">
      <header className="game-header">
        <span className="lobby-code">{lobbyId}</span>
        <span className="lives">{lives}x❤️</span>
        <span className="survived-time">⏱ {formatTime(survivedTime)}</span>
        <span className="difficulty">
          {difficultyMultiplier > 1 ? `${Math.round((difficultyMultiplier - 1) * 100)}% faster` : "Normal"}
        </span>
      </header>

      {/* Explosion overlay */}
      {explosions.map((explosion, index) => (
        <div key={explosion.timestamp + index} className="explosion-overlay">
          <div className="explosion-content">
            <div className="explosion-emoji">{explosion.emoji}</div>
            <div className="explosion-text">
              <strong>{explosion.playerName}</strong>'s bomb exploded!
            </div>
          </div>
        </div>
      ))}

      <div className="game-content">
        {/* Player's input fields */}
        <section className="inputs-section">
          <h2>Enter Codes</h2>
          <div className="inputs-grid">
            {inputs.map((input) => {
              const progress = getTimerProgress(input);
              const color = getTimerColor(progress);
              const result = codeResults[input.id];

              return (
                <div
                  key={input.id}
                  className={`input-card ${result?.success ? "success" : ""} ${result && !result.success ? "error" : ""}`}
                >
                  <div className="input-emoji">{input.emoji}</div>
                  <input
                    type="tel"
                    inputMode="numeric"
                    pattern="[0-9]*"
                    value={codeInputs[input.id] || ""}
                    onChange={(e) => handleCodeChange(input.id, e.target.value)}
                    placeholder="____"
                    className="code-input"
                    maxLength={4}
                  />
                  <div className="timer-bar">
                    <div
                      className="timer-fill"
                      style={{
                        width: `${progress}%`,
                        backgroundColor: color,
                      }}
                    />
                  </div>
                  {result && (
                    <div className={`input-result ${result.success ? "success" : "error"}`}>
                      {result.message}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </section>

        {/* Visible codes for other players */}
        <section className="codes-section">
          <h2>Codes to Share</h2>
          <div className="codes-list">
            {Array.from(codesByPlayer.entries()).map(([targetPlayerId, codes]) => (
              <div key={targetPlayerId} className="player-codes">
                <h3>{codes[0].targetPlayerName}</h3>
                <div className="codes-row">
                  {codes.map((code) => {
                    // Calculate progress based on elapsed time since we received the code
                    const timeRemaining = getCodeTimeRemaining(code);
                    const maxExpiry = 20000; // Max code expiry time (20s)
                    const progress = Math.min(100, (timeRemaining / maxExpiry) * 100);

                    return (
                      <div key={code.inputId} className="code-card">
                        <span className="code-emoji">{code.emoji}</span>
                        <span className="code-value">{code.code}</span>
                        <svg className="code-timer" viewBox="0 0 20 20">
                          <circle
                            className="code-timer-bg"
                            cx="10"
                            cy="10"
                            r="8"
                          />
                          <circle
                            className="code-timer-progress"
                            cx="10"
                            cy="10"
                            r="8"
                            strokeDasharray={`${progress * 0.502} 50.2`}
                          />
                        </svg>
                      </div>
                    );
                  })}
                </div>
              </div>
            ))}
          </div>
        </section>
      </div>
    </div>
  );
}
