"use client";

import { Music } from "lucide-react";
import { useEffect, useState } from "react";
import { formatTime } from "@/lib/format-time";
import { AlbumArt } from "./AlbumArt";
import { demoVisibilityRef, pauseDemo, resumeDemo, useCyclingTrack } from "./useCyclingTrack";

/** A single now-playing preview, using the shared demo clock. */
export function HeroPlayer() {
  const { track, elapsedSec, progress } = useCyclingTrack();
  const [paused, setPaused] = useState(false);
  useEffect(() => {
    if (!paused) return;
    pauseDemo();
    return resumeDemo;
  }, [paused]);
  return (
    <div>
    <div className="ww-product-window" ref={demoVisibilityRef} role="group" aria-label="WolfWave app demo">
      <div className="ww-product-header">
        <div className="ww-window-dots" aria-hidden="true"><span /><span /><span /></div>
        <div className="ww-window-brand">
          <span className="ww-window-brand-icon"><Music className="w-4 h-4" aria-hidden="true" /></span>
          WolfWave
        </div>
      </div>
      <div className="ww-player-body">
        <p className="ww-player-overline">NOW PLAYING FROM APPLE MUSIC</p>
        <div className="ww-player-track">
          <AlbumArt gradient={track.gradient} glyph={track.glyph} size={80} radius={12} />
          <div className="ww-player-metadata">
            <strong>{track.title}</strong>
            <span>{track.artist}</span>
            <span className="ww-player-album">{track.album}</span>
          </div>
        </div>
        <div className="ww-player-progress" aria-hidden="true">
          <span style={{ width: "100%", transformOrigin: "left", transform: `scaleX(${progress})` }} />
        </div>
        <div className="ww-player-time" aria-hidden="true"><span>{formatTime(elapsedSec)}</span><span>{formatTime(track.durationSec)}</span></div>
      </div>
    </div>
    <div className="ww-hero-demo-footer">
      <span>Illustrative preview · Fictional song</span>
      <button type="button" onClick={() => setPaused(!paused)}>
        {paused ? "Resume preview" : "Pause preview"}
      </button>
    </div>
    </div>
  );
}
