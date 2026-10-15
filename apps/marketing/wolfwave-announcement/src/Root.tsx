import React from 'react';
import { Composition } from 'remotion';
import { MainVideo } from './MainVideo';

/**
 * Registers the single `WolfWaveV1` composition: 1920x1080 at 30fps, 390 frames
 * (13 seconds). Keep `durationInFrames` equal to the sum of the scene lengths in
 * `MainVideo.tsx`.
 */
export const RemotionRoot: React.FC = () => (
  <Composition
    id="WolfWaveV1"
    component={MainVideo}
    durationInFrames={390}
    fps={30}
    width={1920}
    height={1080}
  />
);
