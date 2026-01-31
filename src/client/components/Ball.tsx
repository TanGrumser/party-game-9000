import { useRef, useEffect, useCallback, useState } from "react";

interface BallProps {
  id: string;
  x: number;
  y: number;
  color: string;
  status: "held" | "incoming";
  onMove: (x: number, y: number) => void;
  onRelease: () => void;
  onCollect: () => void;
  onDragStart?: () => void;
  onDragEnd?: () => void;
  animateEntry?: boolean;
}

// Helper to darken a color
function darkenColor(hex: string, percent: number): string {
  const num = parseInt(hex.replace("#", ""), 16);
  const amt = Math.round(2.55 * percent);
  const R = Math.max((num >> 16) - amt, 0);
  const G = Math.max((num >> 8 & 0x00FF) - amt, 0);
  const B = Math.max((num & 0x0000FF) - amt, 0);
  return `#${(1 << 24 | R << 16 | G << 8 | B).toString(16).slice(1)}`;
}

export function Ball({ id, x, y, color, status, onMove, onRelease, onCollect, animateEntry = false }: BallProps) {
  const ballRef = useRef<HTMLDivElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const [isDragging, setIsDragging] = useState(false);
  const [entryProgress, setEntryProgress] = useState(animateEntry ? 0 : 1);
  const isEntering = entryProgress < 1;

  // Animate ball entering from top on mount (only for incoming balls)
  useEffect(() => {
    if (!animateEntry) return;

    const startTime = Date.now();
    const duration = 600;

    const animate = () => {
      const elapsed = Date.now() - startTime;
      const progress = Math.min(elapsed / duration, 1);
      const eased = 1 - Math.pow(1 - progress, 3);
      setEntryProgress(eased);

      if (progress < 1) {
        requestAnimationFrame(animate);
      }
    };

    requestAnimationFrame(animate);
  }, [animateEntry]);

  const getRelativePosition = useCallback((clientX: number, clientY: number) => {
    const container = containerRef.current;
    if (!container) return { x: 0.5, y: 0.5 };

    const rect = container.getBoundingClientRect();
    const relX = (clientX - rect.left) / rect.width;
    const relY = (clientY - rect.top) / rect.height;

    return {
      x: Math.max(0, Math.min(1, relX)),
      y: relY,
    };
  }, []);

  const handleStart = useCallback(() => {
    setIsDragging(true);
    onDragStart?.();
  }, [onDragStart]);

  const handleMove = useCallback((clientX: number, clientY: number) => {
    const pos = getRelativePosition(clientX, clientY);
    onMove(pos.x, pos.y);
  }, [getRelativePosition, onMove]);

  const handleEnd = useCallback(() => {
    if (!isDragging) return;
    setIsDragging(false);

    if (status === "held" && y < 0) {
      // Release ball over top edge (send to target player)
      onRelease();
    } else if (status === "incoming" && y > 0.85) {
      // Collect ball by moving to bottom (ball house)
      onCollect();
    }
    onDragEnd?.();
  }, [isDragging, y, status, onRelease, onCollect, onDragEnd]);

  // Mouse events
  useEffect(() => {
    const handleMouseMove = (e: MouseEvent) => {
      if (!isDragging) return;
      handleMove(e.clientX, e.clientY);
    };

    const handleMouseUp = () => {
      if (!isDragging) return;
      handleEnd();
    };

    window.addEventListener("mousemove", handleMouseMove);
    window.addEventListener("mouseup", handleMouseUp);

    return () => {
      window.removeEventListener("mousemove", handleMouseMove);
      window.removeEventListener("mouseup", handleMouseUp);
    };
  }, [isDragging, handleMove, handleEnd]);

  // Touch events
  useEffect(() => {
    const ball = ballRef.current;
    if (!ball) return;

    const handleTouchStart = (e: TouchEvent) => {
      e.preventDefault();
      const touch = e.touches[0];
      if (!touch) return;
      handleStart();
    };

    ball.addEventListener("touchstart", handleTouchStart, { passive: false });

    return () => {
      ball.removeEventListener("touchstart", handleTouchStart);
    };
  }, [handleStart]);

  // Global touch move/end events
  useEffect(() => {
    if (!isDragging) return;

    const handleTouchMove = (e: TouchEvent) => {
      e.preventDefault();
      const touch = e.touches[0];
      if (!touch) return;
      handleMove(touch.clientX, touch.clientY);
    };

    const handleTouchEnd = (e: TouchEvent) => {
      e.preventDefault();
      handleEnd();
    };

    window.addEventListener("touchmove", handleTouchMove, { passive: false });
    window.addEventListener("touchend", handleTouchEnd, { passive: false });

    return () => {
      window.removeEventListener("touchmove", handleTouchMove);
      window.removeEventListener("touchend", handleTouchEnd);
    };
  }, [isDragging, handleMove, handleEnd]);

  // Entry animation
  const entryStartY = -0.25;
  const displayY = isEntering ? entryStartY + (y - entryStartY) * entryProgress : y;

  const darkerColor = darkenColor(color, 20);

  const ballStyle: React.CSSProperties = {
    position: "absolute",
    left: `${x * 100}%`,
    top: `${displayY * 100}%`,
    transform: "translate(-50%, -50%)",
    width: "120px",
    height: "120px",
    borderRadius: "50%",
    background: `linear-gradient(135deg, ${color} 0%, ${darkerColor} 100%)`,
    boxShadow: `0 4px 20px ${color}80`,
    cursor: isDragging ? "grabbing" : "grab",
    userSelect: "none",
    touchAction: "none",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    border: status === "incoming" ? "4px dashed white" : "none",
    transition: isDragging || isEntering ? "none" : "left 0.05s, top 0.05s",
    zIndex: isDragging ? 1001 : 1000,
  };

  return (
    <div
      ref={containerRef}
      className="ball-container"
      style={{
        position: "absolute",
        inset: 0,
        overflow: "visible",
        pointerEvents: "none",
      }}
    >
      <div
        ref={ballRef}
        style={{ ...ballStyle, pointerEvents: "auto" }}
        onMouseDown={handleStart}
      />

      {/* Release zone indicator (top) - for held balls */}
      {status === "held" && y < 0.15 && (
        <div
          style={{
            position: "absolute",
            top: 0,
            left: 0,
            right: 0,
            height: "40px",
            background: `linear-gradient(to bottom, ${color}50, transparent)`,
            pointerEvents: "none",
            borderBottom: `2px dashed ${color}`,
          }}
        />
      )}

      {/* Collect zone indicator (bottom) - for incoming balls */}
      {status === "incoming" && y > 0.75 && (
        <div
          style={{
            position: "absolute",
            bottom: 0,
            left: 0,
            right: 0,
            height: "60px",
            background: `linear-gradient(to top, ${color}50, transparent)`,
            pointerEvents: "none",
            borderTop: `2px dashed ${color}`,
          }}
        />
      )}

      {/* Entry animation indicator */}
      {isEntering && (
        <div
          style={{
            position: "absolute",
            top: 0,
            left: 0,
            right: 0,
            height: "60px",
            background: `linear-gradient(to bottom, ${color}60, transparent)`,
            pointerEvents: "none",
          }}
        />
      )}
    </div>
  );
}
