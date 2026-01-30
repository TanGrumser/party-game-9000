interface GameOverProps {
  explodedPlayerName: string;
  explodedEmoji: string;
  survivedTime: number;
  onBack: () => void;
}

export function GameOver({ explodedPlayerName, explodedEmoji, survivedTime, onBack }: GameOverProps) {
  const formatTime = (seconds: number): string => {
    const mins = Math.floor(seconds / 60);
    const secs = seconds % 60;
    return `${mins}:${secs.toString().padStart(2, "0")}`;
  };

  return (
    <div className="page game-over-page">
      <div className="game-over-content">
        <h1 className="game-over-title">BOOM!</h1>
        <div className="game-over-emoji">{explodedEmoji}</div>
        <p className="game-over-text">
          <strong>{explodedPlayerName}</strong>'s bomb exploded!
        </p>
        <p className="game-over-time">Survived: {formatTime(survivedTime)}</p>
        <button className="btn btn-primary btn-large" onClick={onBack}>
          Back to Menu
        </button>
      </div>
    </div>
  );
}
